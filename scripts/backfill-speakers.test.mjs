import test from 'node:test';
import assert from 'node:assert/strict';
import {DatabaseSync} from 'node:sqlite';
import {captionAttribution,pcmHasSpeech,planBackfill,applyPlan} from './backfill-speakers.mjs';
const phrase='The production verification requires company documents before activation';
const segment={id:'browser-frame',source:'whisper-remote',speaker:'Unknown',text:phrase,t:1000,trackID:'track',attribution:'unresolved',revision:1};
const caption={id:'meet-0',source:'meet',speaker:'Sam',text:phrase,t:4500};
const span={start:1000,end:5000};
const pcm=new Float32Array(16000*4).fill(0.1);const encoded=Buffer.from(pcm.buffer).toString('base64');
function fixture() {
 const db=new DatabaseSync(':memory:');
 db.exec('CREATE TABLE sessions(id TEXT PRIMARY KEY,meta TEXT);CREATE TABLE segments(session TEXT,id TEXT,body TEXT,PRIMARY KEY(session,id));CREATE TABLE audio_archive(id TEXT PRIMARY KEY,session TEXT,body TEXT);CREATE TABLE events(cursor INTEGER PRIMARY KEY,session TEXT,kind TEXT,body TEXT)');
 const meta={ended:true,title:'Meet – abc-defg-hij',url:'https://meet.google.com/meet/abc-defg-hij',meetingCode:'https://meet.google.com',seriesID:'https://meet.google.com',source:'browser',startedAt:1000};
 db.prepare('INSERT INTO sessions VALUES(?,?)').run('one',JSON.stringify(meta));
 db.prepare('INSERT INTO sessions VALUES(?,?)').run('old',JSON.stringify({...meta,title:'Meet – Weekly sync with Alex',url:'https://meet.google.com/abc-defg-hij',meetingCode:'abc-defg-hij',seriesID:'abc-defg-hij',source:'meet',startedAt:1}));
 for(const s of [segment,caption])db.prepare('INSERT INTO segments VALUES(?,?,?)').run('one',s.id,JSON.stringify(s));
 db.prepare('INSERT INTO audio_archive VALUES(?,?,?)').run('frame','one',JSON.stringify({id:'frame',source:'remote',startedAt:1000,trackID:'track',attribution:'unresolved',sampleRate:16000,pcm:encoded}));
 return db;
}
test('caption backfill requires wording, audio interval, and one unambiguous remote speaker',()=>{
 assert.equal(captionAttribution(segment,span,[caption],['You']).speaker,'Sam');
 assert.equal(captionAttribution({...segment,text:'Yes sir'},span,[caption]),null);
 assert.equal(captionAttribution(segment,null,[caption]),null);
 assert.equal(captionAttribution(segment,span,[{...caption,t:90000}]),null);
 assert.equal(captionAttribution(segment,span,[caption,{...caption,id:'meet-1',speaker:'Other',text:'Another speaker',t:3000}]),null);
 assert.equal(captionAttribution(segment,span,[{...caption,speaker:'You'}],['You']),null);
 assert.equal(captionAttribution({...segment,attribution:'mixed'},span,[caption]),null);
 assert.equal(captionAttribution({...segment,contributors:[101,102]},span,[caption]),null);
 assert.equal(captionAttribution({...segment,speaker:'Already known'},span,[caption]),null);
 assert.equal(pcmHasSpeech(encoded),true);
 assert.equal(pcmHasSpeech(Buffer.alloc(16000).toString('base64')),false);
 const invalid=new Float32Array([NaN]);assert.equal(pcmHasSpeech(Buffer.from(invalid.buffer).toString('base64')),false);
});
test('applying backfill preserves audio, caption text, timing, call identities and revisions',()=>{
 const db=fixture();try {
  const originalAudio=db.prepare('SELECT body FROM audio_archive').get().body;
  const plan=planBackfill(db);assert.equal(plan.segments.length,1);
  const stats=applyPlan(db,plan);assert.equal(stats.segments,1);
  const updated=JSON.parse(db.prepare('SELECT body FROM segments WHERE id=?').get(segment.id).body);
  for(const key of ['id','text','t','source','trackID'])assert.deepEqual(updated[key],segment[key]);
  assert.equal(updated.speaker,'Sam');assert.equal(updated.revision,2);assert.equal(updated.speakerEvidence.captionID,'meet-0');
  assert.equal(db.prepare('SELECT body FROM audio_archive').get().body,originalAudio);
  assert.deepEqual(JSON.parse(db.prepare('SELECT body FROM segments WHERE id=?').get(caption.id).body),caption);
  const meta=JSON.parse(db.prepare('SELECT meta FROM sessions WHERE id=?').get('one').meta);
  assert.equal(meta.meetingCode,'abc-defg-hij');assert.equal(meta.seriesID,'abc-defg-hij');assert.equal(meta.title,'Meet – Weekly sync with Alex');
  assert.equal(db.prepare('SELECT count(*) AS n FROM sessions').get().n,2);
  const rerun=planBackfill(db);assert.equal(rerun.segments.length,0);assert.equal(rerun.metadata.length,0);
 }finally{db.close()}
});
test('missing/silent audio remains Unknown and an edited source aborts the transaction',()=>{
 const db=fixture();try {
  const plan=planBackfill(db);
  db.prepare('UPDATE segments SET body=? WHERE id=?').run(JSON.stringify({...segment,text:'Edited'}),segment.id);
  assert.throws(()=>applyPlan(db,plan),/changed after planning/);
  assert.equal(db.prepare('SELECT count(*) AS n FROM events').get().n,0);
  db.exec('DELETE FROM audio_archive');assert.equal(planBackfill(db).segments.length,0);
 }finally{db.close()}
});
test('user confirmation is call scoped, corroborated by captions, and cannot name mixed audio',()=>{
 const db=fixture();try {
  db.prepare('UPDATE segments SET body=? WHERE id=?').run(JSON.stringify({...segment,text:'Yah hamara agla vishay hai'}),segment.id);
  assert.equal(planBackfill(db).segments.length,0);
  const confirmations=new Map([['one',{speaker:'Sam',note:'Only other participant, shared screen'}]]);
  const plan=planBackfill(db,confirmations);assert.equal(plan.segments.length,1);
  assert.equal(JSON.parse(plan.segments[0].after).speakerEvidence.confirmedByUser,true);
  assert.throws(()=>planBackfill(db,new Map([['one',{speaker:'Wrong person',note:'Wrong'}]])),/conflicts/);
  db.prepare('UPDATE segments SET body=? WHERE id=?').run(JSON.stringify({...segment,text:'Yah hamara agla vishay hai',attribution:'mixed'}),segment.id);
  assert.equal(planBackfill(db,confirmations).segments.length,0);
 }finally{db.close()}
});
