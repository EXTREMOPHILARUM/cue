import importlib.util
from pathlib import Path
import unittest
import numpy as np

spec = importlib.util.spec_from_file_location('voice', Path(__file__).with_name('voice-backfill.py'))
voice = importlib.util.module_from_spec(spec)
spec.loader.exec_module(voice)


class VoiceTests(unittest.TestCase):
    def test_every_model_and_window_must_agree(self):
        a, b = {'Taylor': .8, 'Jordan': .3}, {'Taylor': .7, 'Jordan': .4}
        self.assertEqual(voice.decide([a, b]), 'Taylor')
        for values in [[], [a, {'Taylor': .3, 'Jordan': .8}], [a, {'Taylor': .8, 'Jordan': .75}],
                       [a, {'Taylor': .4, 'Jordan': .1}], [{'Taylor': float('nan'), 'Jordan': .1}]]:
            self.assertIsNone(voice.decide(values))

    def test_held_out_audio_cannot_match_itself(self):
        refs = {'Taylor': [('one', np.array([1., 0.])), ('two', np.array([0., 1.]))],
                'Jordan': [('three', np.array([.5, .5]))]}
        result = voice.scores(np.array([1., 0.]), refs, exclude='one')
        self.assertEqual(result['Taylor'], 0)
        self.assertEqual(max(result, key=result.get), 'Jordan')

    def test_audio_windows_include_boundaries_and_reject_invalid_pcm(self):
        self.assertEqual(voice.windows(np.zeros(64000, dtype=np.float32)), [])
        x = np.full(64000, .1, dtype=np.float32)
        self.assertEqual([len(a) for a in voice.windows(x)], [64000, 32000, 32000, 32000])
        import base64
        for samples in [np.array([np.nan], dtype='<f4'), np.array([np.inf], dtype='<f4')]:
            with self.assertRaisesRegex(ValueError, 'Non-finite'):
                voice.pcm({'sampleRate': 16000, 'pcm': base64.b64encode(samples).decode()})

    def test_segmentation_vetoes_overlap_second_voice_and_silence(self):
        self.assertTrue(voice.one_voice([0] * 10 + [1] * 100, .01))
        self.assertFalse(voice.one_voice([1] * 100 + [4] * 11, .01))
        self.assertFalse(voice.one_voice([1] * 100 + [2] * 21, .01))
        self.assertFalse(voice.one_voice([0] * 100, .01))

    def test_batch_keeps_all_frames_and_vetoes_mixed_audio(self):
        import base64
        raw = base64.b64encode(np.full(64000, .1, dtype='<f4')).decode()
        frames = [{'id': str(i), 'startedAt': 1000 + i * 4000, 'source': 'remote',
                   'trackID': 'track', 'sampleRate': 16000, 'pcm': raw} for i in range(5)]
        s = {'id': 'browser-0', 't': 1000, 'trackID': 'track'}
        self.assertEqual([f['id'] for f in voice.batch(s, frames, 99999)], ['0', '1', '2', '3'])
        self.assertEqual(len(voice.batch(s, frames, 9000)), 2)
        frames[0]['contributors'] = ['a', 'b']
        self.assertEqual(voice.batch(s, frames, 99999), [])
        self.assertEqual(voice.batch({**s, 'trackID': 'other'}, frames, 99999), [])

    def test_end_to_end_dry_run_writes_private_plan_without_touching_archive(self):
        import base64
        import json
        import sqlite3
        import sys
        import tempfile
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            db = sqlite3.connect(root / 'calls.sqlite3')
            db.executescript('CREATE TABLE sessions(id,meta); CREATE TABLE segments(session,body); '
                             'CREATE TABLE events(session,kind,body); CREATE TABLE audio_archive(session,body);')
            db.execute('INSERT INTO sessions VALUES(?,?)', ('call', json.dumps({'ended': True})))
            refs = {'Taylor': ['a0', 'a1', 'a2'], 'Jordan': ['b0', 'b1', 'b2']}
            raw = base64.b64encode(np.full(32000, .1, dtype='<f4')).decode()
            confirmations = []
            for i, (name, key) in enumerate((n, k) for n, ids in refs.items() for k in ids):
                frame = {'id': key, 'source': 'remote', 'startedAt': 1000 + i * 10000,
                         'trackID': 'track', 'sampleRate': 16000, 'pcm': raw}
                db.execute('INSERT INTO audio_archive VALUES(?,?)', ('call', json.dumps(frame)))
                confirmations.append({'frameID': key, 'speaker': name})
            db.execute('INSERT INTO events VALUES(?,?,?)', ('call', 'speaker-reference-confirmation',
                       json.dumps({'confirmedByUser': True, 'references': confirmations})))
            segment = {'id': 'browser-a0', 'source': 'whisper-remote', 'speaker': 'Unknown',
                       't': 1000, 'trackID': 'track', 'text': 'Original words'}
            db.execute('INSERT INTO segments VALUES(?,?)', ('call', json.dumps(segment)))
            db.commit()
            (root / 'references.json').write_text(json.dumps(refs))
            class FakeModel:
                def __init__(self, path):
                    self.path, self.hash = Path(path), path
                def enroll(self, references, audio):
                    return [{'expected': 'Taylor', 'predicted': 'Taylor'}]
                def frame(self, frame):
                    return [{'Taylor': .9, 'Jordan': .2}]
            class FakeSegmentation:
                hash = 'segmentation'
                def __init__(self, path):
                    pass
                def clean(self, samples):
                    return True
            args = ['voice-backfill', '--db', str(root / 'calls.sqlite3'), '--session', 'call',
                    '--references', str(root / 'references.json'), '--report', str(root / 'plan.json'),
                    '--model', 'one', '--model', 'two', '--segmentation', 'seg']
            before = db.execute('SELECT body FROM segments').fetchone()[0]
            with patch.object(sys, 'argv', args), patch.object(voice, 'Model', FakeModel), \
                    patch.object(voice, 'Segmentation', FakeSegmentation):
                voice.main()
            plan = json.loads((root / 'plan.json').read_text())
            self.assertEqual(len(plan['segments']), 1)
            after = json.loads(plan['segments'][0]['after'])
            self.assertEqual(after['speaker'], 'Taylor')
            self.assertEqual(after['text'], segment['text'])
            self.assertEqual(db.execute('SELECT body FROM segments').fetchone()[0], before)
            self.assertEqual((root / 'plan.json').stat().st_mode & 0o777, 0o600)
            db.close()


if __name__ == '__main__':
    unittest.main()
