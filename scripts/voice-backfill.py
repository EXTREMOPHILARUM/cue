"""Local, dry-run speaker backfill. Never writes to the call archive."""
import argparse
import base64
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import sqlite3

import numpy as np


def pcm(frame):
    data = base64.b64decode(frame['pcm'], validate=True)
    if frame.get('sampleRate') != 16000 or not data or len(data) % 4 or len(data) > 16000 * 8 * 4:
        raise ValueError('Expected 16 kHz float32 audio')
    samples = np.frombuffer(data, dtype='<f4')
    if not np.isfinite(samples).all():
        raise ValueError('Non-finite audio')
    return samples


def windows(samples):
    # Full frame plus overlapping two-second windows veto short speaker changes.
    if len(samples) < 32000:
        return []
    starts = sorted(set([*range(0, len(samples) - 32000 + 1, 16000), len(samples) - 32000]))
    parts = [samples] + [samples[i:i + 32000] for i in starts]
    result = []
    for part in parts:
        blocks = part[:len(part) // 1600 * 1600].reshape(-1, 1600)
        active = np.flatnonzero(np.sqrt(np.mean(blocks ** 2, axis=1)) >= .005)
        if len(active) >= 8:
            result.append(np.ascontiguousarray(part[active[0] * 1600:(active[-1] + 1) * 1600]))
    return result


def scores(vector, references, exclude=None):
    return {name: max(float(vector @ item) for key, item in entries if key != exclude)
            for name, entries in references.items()}


def decide(results, minimum=.55, margin=.12):
    if not results:
        return None
    names = []
    for result in results:
        ordered = sorted(result, key=result.get, reverse=True)
        if len(ordered) < 2 or not all(np.isfinite(list(result.values()))):
            return None
        first, second = ordered[:2]
        if result[first] < minimum or result[first] - result[second] < margin:
            return None
        names.append(first)
    return names[0] if len(set(names)) == 1 else None


class Model:
    def __init__(self, path):
        import sherpa_onnx
        self.path = Path(path)
        self.hash = hashlib.sha256(self.path.read_bytes()).hexdigest()
        config = sherpa_onnx.SpeakerEmbeddingExtractorConfig(model=str(path), num_threads=2, provider='cpu')
        if not config.validate():
            raise ValueError('Invalid speaker model')
        self.extractor = sherpa_onnx.SpeakerEmbeddingExtractor(config)
        self.references = {}
        self.cache = {}

    def embed(self, samples):
        stream = self.extractor.create_stream()
        stream.accept_waveform(sample_rate=16000, waveform=np.ascontiguousarray(samples))
        stream.input_finished()
        if not self.extractor.is_ready(stream):
            raise ValueError('Insufficient audio for speaker model')
        vector = np.asarray(self.extractor.compute(stream))
        norm = np.linalg.norm(vector)
        if not np.isfinite(vector).all() or not norm > 0:
            raise ValueError('Invalid speaker embedding')
        return vector / norm

    def enroll(self, references, audio):
        self.references = {name: [(key, self.embed(pcm(audio[key]))) for key in keys]
                           for name, keys in references.items()}
        checks = []
        for name, keys in references.items():
            for key in keys:
                # Neither the held-out frame nor any part of it is enrolled for this check.
                samples = pcm(audio[key])
                for part in [samples, *np.array_split(samples, 2)]:
                    result = scores(self.embed(part), self.references, exclude=key)
                    predicted = max(result, key=result.get)
                    checks.append({'frameID': key, 'samples': len(part), 'expected': name,
                                   'predicted': predicted, 'scores': result,
                                   'accepted': decide([result])})
        return checks

    def frame(self, frame):
        key = frame['id']
        if key not in self.cache:
            self.cache[key] = [scores(self.embed(part), self.references) for part in windows(pcm(frame))]
        return self.cache[key]


def batch(segment, frames, next_time):
    first_id = segment['id'].removeprefix('browser-')
    start = next((i for i, f in enumerate(frames) if f['id'] == first_id), None)
    if start is None:
        return []
    first = frames[start]
    if abs(first['startedAt'] - segment['t']) > 1 or first.get('trackID') != segment.get('trackID'):
        return []
    result, duration, end = [], 0, first['startedAt']
    for frame in frames[start:]:
        if frame.get('trackID') != first.get('trackID'):
            continue
        if frame['startedAt'] >= next_time:
            break
        if result and (abs(frame['startedAt'] - end) > 1000 or any(
                frame.get(k) != first.get(k) for k in ['participantID', 'speaker', 'attribution', 'contributors'])):
            break
        if frame.get('attribution') == 'mixed' or len(frame.get('contributors', [])) > 1:
            return []
        seconds = len(pcm(frame)) / 16000
        result.append(frame)
        duration += seconds
        end = frame['startedAt'] + seconds * 1000
        if duration >= 16 or len(result) == 8:
            break
    return result


def one_voice(classes, step_seconds):
    counts = Counter(int(c) for c in classes)
    speech = sum(n for c, n in counts.items() if c > 0) * step_seconds
    overlap = sum(n for c, n in counts.items() if c > 3) * step_seconds
    single = sorted((n * step_seconds for c, n in counts.items() if 1 <= c <= 3), reverse=True)
    return speech >= .8 and overlap < .1 and (len(single) < 2 or single[1] < .2)


class Segmentation:
    def __init__(self, path):
        import onnxruntime as ort
        options = ort.SessionOptions()
        options.intra_op_num_threads = 2
        options.inter_op_num_threads = 1
        self.model = ort.InferenceSession(str(path), sess_options=options, providers=['CPUExecutionProvider'])
        self.hash = hashlib.sha256(Path(path).read_bytes()).hexdigest()
        meta = self.model.get_modelmeta().custom_metadata_map
        if any(int(meta[key]) != value for key, value in
               [('sample_rate', 16000), ('num_speakers', 3), ('powerset_max_classes', 2), ('num_classes', 7)]):
            raise ValueError('Unsupported segmentation powerset')
        self.size = int(meta['window_size'])
        self.field = int(meta['receptive_field_size'])
        self.shift = int(meta['receptive_field_shift'])

    def clean(self, samples):
        # Powerset 0 is silence, 1..3 individual voices, 4..6 overlapping pairs.
        starts = sorted(set([*range(0, max(1, len(samples) - self.size + 1), self.size // 2),
                             max(0, len(samples) - self.size)]))
        for start in starts:
            part = samples[start:start + self.size]
            valid = max(0, (len(part) - self.field) // self.shift + 1)
            if not valid:
                return False
            padded = np.pad(part, (0, self.size - len(part))).reshape(1, 1, -1)
            output = self.model.run(None, {self.model.get_inputs()[0].name: padded})[0]
            if not np.isfinite(output).all() or output.shape[-1] != 7:
                raise ValueError('Invalid segmentation output')
            if not one_voice(np.argmax(output[0, :valid], axis=-1), self.shift / 16000):
                return False
        return True


def confirmed(db, session):
    result = {}
    for row in db.execute("SELECT body FROM events WHERE session=? AND kind='speaker-reference-confirmation'", (session,)):
        event = json.loads(row[0])
        if event.get('confirmedByUser') is not True:
            continue
        refs = event.get('references', [])
        if isinstance(refs, dict):
            for ids in refs.values():
                for key in ids:
                    result[key] = event['speaker']
        else:
            for ref in refs:
                result[ref['frameID']] = ref['speaker']
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for key in ['db', 'session', 'references', 'report']:
        parser.add_argument('--' + key, required=True)
    parser.add_argument('--model', action='append', required=True)
    parser.add_argument('--segmentation', required=True)
    args = parser.parse_args()
    if len(set(args.model)) < 2:
        parser.error('At least two independently trained models are required')
    db = sqlite3.connect(Path(args.db).resolve().as_uri() + '?mode=ro', uri=True)
    meta = json.loads(db.execute('SELECT meta FROM sessions WHERE id=?', (args.session,)).fetchone()[0])
    if not meta.get('ended') or meta.get('archived'):
        raise ValueError('Only ended, non-archived calls may be backfilled')
    frames = [json.loads(r[0]) for r in db.execute(
        "SELECT body FROM audio_archive WHERE session=? AND json_extract(body,'$.source')='remote' ORDER BY rowid", (args.session,))]
    audio = {f['id']: f for f in frames}
    references = json.loads(Path(args.references).read_text())
    verified = confirmed(db, args.session)
    keys = [key for ids in references.values() for key in ids]
    if len(references) < 2 or any(len(ids) < 3 for ids in references.values()) or len(keys) != len(set(keys)):
        raise ValueError('Need three distinct user-confirmed frames per speaker')
    if any(verified.get(key) != name or key not in audio for name, ids in references.items() for key in ids):
        raise ValueError('Reference identity lacks a saved user confirmation for this call')
    segmentation = Segmentation(args.segmentation)
    models, benchmark = [], []
    for path in args.model:
        model = Model(path)
        checks = model.enroll(references, audio)
        if any(c['predicted'] != c['expected'] for c in checks):
            raise ValueError('Model failed held-out reference classification: ' + path)
        benchmark.append({'model': model.path.name, 'sha256': model.hash, 'checks': checks})
        models.append(model)
        print(json.dumps({'model': model.path.name, 'heldOutCorrect': len(checks), 'heldOutTotal': len(checks)}), flush=True)
    if len({m.hash for m in models}) < 2:
        raise ValueError('Duplicate model weights')
    rows = [(r[0], json.loads(r[0])) for r in db.execute(
        "SELECT body FROM segments WHERE session=? ORDER BY json_extract(body,'$.t')", (args.session,))]
    remote = [s for raw, s in rows if s.get('source') == 'whisper-remote']
    plan = {'version': 1, 'session': args.session, 'segments': [], 'metadata': [], 'confirmations': [],
            'benchmark': benchmark, 'references': references, 'rejections': [],
            'segmentation': {'sha256': segmentation.hash, 'maxOverlapSeconds': .1, 'maxSecondVoiceSeconds': .2},
            'policy': {'minimumCosine': .55, 'minimumMargin': .12, 'allModelsAndWindowsAgree': True}}
    counts = Counter()
    evaluated = 0
    for raw, segment in rows:
        if segment.get('source') != 'whisper-remote' or segment.get('speaker') != 'Unknown':
            continue
        evaluated += 1
        if evaluated % 100 == 0:
            print(json.dumps({'evaluated': evaluated, 'accepted': sum(counts.values())}), flush=True)
        next_time = min((s['t'] for s in remote if s.get('trackID') == segment.get('trackID') and s['t'] > segment['t']), default=float('inf'))
        group = batch(segment, frames, next_time)
        evidence, decisions = [], []
        for frame in group:
            frame_results = []
            for model in models:
                values = model.frame(frame)
                if not values:
                    break
                frame_results.extend(values)
            else:
                speaker = decide(frame_results)
                decisions.append(speaker)
                evidence.append({'frameID': frame['id'], 'pcmSHA256': hashlib.sha256(base64.b64decode(frame['pcm'], validate=True)).hexdigest(), 'scores': frame_results})
                continue
            decisions.append(None)
        # Even a silent/unusable frame is a veto: never skip speech we cannot evaluate.
        speaker = decisions[0] if decisions and None not in decisions and len(set(decisions)) == 1 else None
        if speaker and any(f.get('speaker') not in [None, '', 'Unknown', speaker] for f in group):
            speaker = None
        if speaker and not segmentation.clean(np.concatenate([pcm(f) for f in group])):
            speaker = None
        if not speaker or segment.get('attribution') == 'mixed' or len(segment.get('contributors', [])) > 1:
            plan['rejections'].append(segment['id'])
            continue
        after = {**segment, 'speaker': speaker, 'attribution': 'verified-voice-backfill',
                 'revision': segment.get('revision', 0) + 1,
                 'speakerEvidence': {'method': 'two-model-user-reference-voice-v1', 'references': references,
                                     'models': [{'name': m.path.name, 'sha256': m.hash} for m in models],
                                     'policy': plan['policy'], 'segmentation': plan['segmentation'], 'audioFrames': evidence,
                                     'audioStart': group[0]['startedAt'],
                                     'audioEnd': group[-1]['startedAt'] + len(pcm(group[-1])) / 16}}
        plan['segments'].append({'session': args.session, 'id': segment['id'], 'before': raw,
                                 'after': json.dumps(after, ensure_ascii=False, separators=(',', ':'))})
        counts[speaker] += 1
    output = Path(args.report)
    with open(output, 'w', opener=lambda p, flags: os.open(p, flags, 0o600)) as file:
        json.dump(plan, file, ensure_ascii=False, indent=2)
    output.chmod(0o600)
    print(json.dumps({'attributed': dict(counts), 'leftUnknown': len(plan['rejections']), 'report': str(output)}), flush=True)


if __name__ == '__main__':
    main()
