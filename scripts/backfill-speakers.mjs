import {DatabaseSync,backup} from 'node:sqlite';
import {writeFile,mkdir,chmod} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {pathToFileURL} from 'node:url';

const stop=new Set('a an the and or but to of in on at for is it its this that with as by be was were are have has had not do does did we you i he she they them us my your our their so from if then than can could would should will just also some what which when how there here sir yes no okay ok right like yeah hai hain haan nahi nahin ka ki ke ko se mein main to aur vah yah bhi ek sir'.split(' '));
const tokens=text=>(String(text || '').normalize('NFKC').toLowerCase().match(/[\p{L}\p{N}]+/gu) || []);
const content=text=>new Set(tokens(text).filter(t=>t.length>=3 && !stop.has(t)));
const name=value=>String(value || '').trim().normalize('NFKC').toLowerCase();
function shared(a,b){return [...a].filter(w=>b.has(w));}
function phrase(a,b){const set=new Set();for(let i=0;i+3<b.length;i++)set.add(b.slice(i,i+4).join(' '));for(let i=0;i+3<a.length;i++)if(set.has(a.slice(i,i+4).join(' ')))return true;return false;}

// Caption times are final DOM-update times, not precise word boundaries: require lexical evidence too.
export function captionAttribution(segment,span,captions,selfNames=[]) {
  if(segment.source!=='whisper-remote' || segment.speaker!=='Unknown' || segment.attribution==='mixed' || segment.contributors?.length>1 || !span || span.end<=span.start || span.end-span.start>32_000)return null;
  const words=content(segment.text);if(words.size<5)return null;
  const self=new Set(['you','me',...selfNames.map(name)]);
  const nearby=captions.filter(c=>Number.isFinite(c.t) && c.t>=span.start-1000 && c.t<=span.end+8000 && c.text);
  const scored=nearby.map(c=>{const matches=shared(words,content(c.text));return {caption:c,matches,coverage:matches.length/words.size};});
  const candidates=scored.filter(c=>c.caption.speaker && !['unknown','multiple speakers'].includes(name(c.caption.speaker)) && !self.has(name(c.caption.speaker)) && c.matches.length>=5 && c.coverage>=0.8 && phrase(tokens(segment.text),tokens(c.caption.text)));
  candidates.sort((a,b)=>b.coverage-a.coverage || b.matches.length-a.matches.length);
  const best=candidates[0];if(!best)return null;
  // Never infer ownership across a track or from a roster; even one plausible second speaker vetoes a segment.
  if(scored.some(c=>name(c.caption.speaker)!==name(best.caption.speaker) && ((c.caption.t>=span.start-1000 && c.caption.t<=span.end+2000) || c.matches.length>=2 && c.coverage>=0.4)))return null;
  return {speaker:best.caption.speaker,captionID:best.caption.id,captionTime:best.caption.t,audioStart:span.start,audioEnd:span.end,coverage:best.coverage,matchedWords:best.matches};
}
export function pcmHasSpeech(pcm) {
  const bytes=Buffer.from(pcm || '', 'base64');if(!bytes.length || bytes.length%4)return false;
  let active=0,total=0;
  for(let begin=0;begin<bytes.length;begin+=6400){let sum=0,n=0;for(let i=begin;i<Math.min(begin+6400,bytes.length);i+=4){const x=bytes.readFloatLE(i);if(!Number.isFinite(x))return false;sum+=x*x;n++;}if(n && Math.sqrt(sum/n)>=0.003)active++;total++;}
  return active>=2 && active/total>=0.05;
}
const code=value=>{try{const u=new URL(value);return u.protocol==='https:' && u.hostname==='meet.google.com' ? u.pathname.match(/^\/(?:meet\/)?([a-z]{3}-[a-z]{4}-[a-z]{3})(?:\/|$)/)?.[1]:null;}catch{return null;}};
const generic=value=>!value || /^(meet|untitled(?: call)?|[a-z]{3}-[a-z]{4}-[a-z]{3})$/i.test(value.replace(/^Meet\s*[–—-]\s*/i,'').trim());

export function planBackfill(db,confirmations=new Map()) {
  const sessions=db.prepare('SELECT id,meta FROM sessions').all().map(row=>({...row,value:JSON.parse(row.meta)}));
  const plan={version:1,segments:[],metadata:[],calls:[],confirmations:[]};
  const segmentRows=db.prepare('SELECT id,body FROM segments WHERE session=? ORDER BY json_extract(body,\'$.t\')');
  const frameRows=db.prepare("SELECT id,json_extract(body,'$.startedAt') AS t,json_extract(body,'$.trackID') AS track,json_extract(body,'$.attribution') AS attribution,json_extract(body,'$.contributors') AS contributors,json_extract(body,'$.participantID') AS participantID,length(json_extract(body,'$.pcm')) AS bytes,substr(json_extract(body,'$.pcm'),-2) AS padding FROM audio_archive WHERE session=? AND json_extract(body,'$.source')='remote' ORDER BY rowid");
  const audio=db.prepare('SELECT body FROM audio_archive WHERE id=? AND session=?');
  for(const session of sessions) {
    const meta=session.value,meeting=code(meta.url);
    if(meeting) {
      const next={...meta,meetingCode:meeting,seriesID:meeting,source:'meet'};
      if(generic(meta.title)) {
        const previous=sessions.filter(s=>!s.value.archived && code(s.value.url)===meeting && !generic(s.value.title)).sort((a,b)=>(b.value.startedAt || 0)-(a.value.startedAt || 0))[0];
        if(previous)next.title=previous.value.title;
      }
      if(["meetingCode","seriesID","source","title"].some(key=>next[key]!==meta[key]))plan.metadata.push({session:session.id,before:session.meta,after:JSON.stringify(next)});
    }
    if(!meta.ended || meta.archived)continue;
    const rows=segmentRows.all(session.id).map(row=>({...row,value:JSON.parse(row.body)}));
    const unknown=rows.filter(s=>s.value.source==='whisper-remote' && s.value.speaker==='Unknown');if(!unknown.length)continue;
    const captions=rows.map(r=>r.value).filter(s=>s.source==='meet');
    const localNames=[...(meta.speakerRoster || []).filter(p=>p.isSelf).map(p=>p.name),...rows.map(r=>r.value).filter(s=>s.source==='whisper-local').map(s=>s.speaker)];
    const frames=frameRows.all(session.id),index=new Map(frames.map((f,i)=>[f.id,i]));
    const confirmed=confirmations.get(session.id);
    if(confirmed) {
      const others=new Set(captions.map(c=>name(c.speaker)).filter(n=>n && !['you','unknown',...localNames.map(name)].includes(n)));
      if(others.size!==1 || !others.has(name(confirmed.speaker)))throw new Error('User-confirmed remote speaker conflicts with saved captions: '+session.id);
    }
    let changed=0;
    for(const row of unknown) {
      const s=row.value,firstIndex=index.get(s.id.replace(/^browser-/,''));if(firstIndex===undefined)continue;
      const first=frames[firstIndex];if(Math.abs(first.t-s.t)>1 || first.attribution==='mixed' || JSON.parse(first.contributors || '[]').length>1)continue;
      const next=rows.find(r=>r.value.source==='whisper-remote' && r.value.trackID===s.trackID && r.value.t>s.t)?.value.t ?? Infinity;
      let end=first.t;const ids=[];
      for(const f of frames.slice(firstIndex)) {
        if(f.track!==first.track)continue;
        if(ids.length>=8 || f.t>=next || f.attribution!==first.attribution || f.participantID!==first.participantID || f.contributors!==first.contributors || ids.length && Math.abs(f.t-end)>1000)break;
        if(!Number.isFinite(f.bytes) || f.bytes<=0)break;
        // Base64 stores float32 mono samples at 16 kHz.
        const padding=f.padding==='==' ? 2:f.padding?.endsWith('=') ? 1:0;
        const duration=(f.bytes*3/4-padding)/4/16000*1000;
        end=f.t+duration;ids.push(f.id);if(end-first.t>=16_000)break;
      }
      let evidence=captionAttribution(s,{start:first.t,end},captions,localNames);
      if(!evidence && confirmed && ids.length && end>first.t && end-first.t<=32_000 && s.attribution!=='mixed' && !(s.contributors?.length>1)) {
        evidence={speaker:confirmed.speaker,confirmedByUser:true,confirmationNote:confirmed.note,audioStart:first.t,audioEnd:end,corroboratingCaptionIDs:captions.filter(c=>name(c.speaker)===name(confirmed.speaker)).slice(0,3).map(c=>c.id)};
      }
      if(!evidence)continue;
      const firstAudio=JSON.parse(audio.get(first.id,session.id).body);
      if(!pcmHasSpeech(firstAudio.pcm))continue;
      const after={...s,speaker:evidence.speaker,attribution:'meet-caption-backfill',speakerEvidence:{...evidence,audioFrames:ids,method:evidence.confirmedByUser ? 'user-confirmed-two-person-and-saved-audio-v1':'caption-text-and-saved-audio-v1'},revision:(s.revision || 0)+1};
      plan.segments.push({session:session.id,id:s.id,before:row.body,after:JSON.stringify(after)});changed++;
    }
    if(confirmed && changed)plan.confirmations.push({session:session.id,...confirmed});
    plan.calls.push({session:session.id,title:meta.title,unknown:unknown.length,attributed:changed,leftUnknown:unknown.length-changed,captions:captions.length});
  }
  return plan;
}
export function applyPlan(db,plan) {
  const update=db.prepare('UPDATE segments SET body=? WHERE session=? AND id=? AND body=?');
  const metadata=db.prepare('UPDATE sessions SET meta=? WHERE id=? AND meta=?');
  const event=db.prepare('INSERT INTO events(session,kind,body) VALUES(?,?,?)');
  let segments=0,calls=0;
  db.exec('PRAGMA foreign_keys=ON;PRAGMA busy_timeout=5000;BEGIN IMMEDIATE');
  try {
    for(const row of plan.segments) {
      const before=JSON.parse(row.before),after=JSON.parse(row.after);
      if(before.speaker!=='Unknown' || before.source!=='whisper-remote' || ['id','text','t','source','trackID'].some(k=>JSON.stringify(before[k])!==JSON.stringify(after[k])))throw new Error('Invalid backfill: transcript content or existing attribution would change');
      if(update.run(row.after,row.session,row.id,row.before).changes!==1)throw new Error('Stored transcript changed after planning; rerun dry run');
      event.run(row.session,'segment',row.after);segments++;
    }
    for(const confirmed of plan.confirmations || [])event.run(confirmed.session,'speaker-backfill-confirmation',JSON.stringify(confirmed));
    for(const row of plan.metadata) {
      if(metadata.run(row.after,row.session,row.before).changes!==1)throw new Error('Meeting metadata changed after planning; rerun dry run');
      event.run(row.session,'session',row.after);calls++;
    }
    db.exec('COMMIT');return {segments,metadata:calls};
  } catch(error){db.exec('ROLLBACK');throw error;}
}
async function main() {
  const args=process.argv.slice(2),path=args[args.indexOf('--db')+1],report=args[args.indexOf('--report')+1],apply=args.includes('--apply');
  if(!args.includes('--db') || !args.includes('--report') || !path || !report)throw new Error('Usage: node scripts/backfill-speakers.mjs --db PATH --report PATH [--apply]');
  const db=new DatabaseSync(resolve(path),{readOnly:!apply});
  try {
    const confirmations=new Map();
    for(let i=0;i<args.length;i++)if(args[i]==='--confirmed-two-person') {
      const value=args[++i],equal=value?.indexOf('=');if(!(equal>0))throw new Error('Expected --confirmed-two-person SESSION=NAME');
      const noteIndex=args.indexOf('--confirmation-note');if(noteIndex<0 || !args[noteIndex+1])throw new Error('A confirmation note is required');
      confirmations.set(value.slice(0,equal),{speaker:value.slice(equal+1),note:args[noteIndex+1]});
    }
    const plan=planBackfill(db,confirmations);
    await mkdir(dirname(resolve(report)),{recursive:true});
    await writeFile(report,JSON.stringify(plan,null,2),{mode:0o600});
    if(apply) {
      const copy=resolve(report)+'.before.sqlite3';await backup(db,copy);await chmod(copy,0o600);
      console.log({backup:copy,applied:applyPlan(db,plan)});
    }
    console.log({calls:plan.calls,metadata:plan.metadata.length,segments:plan.segments.length,report});
  }finally{db.close();}
}
if(process.argv[1] && import.meta.url===pathToFileURL(resolve(process.argv[1])).href)await main();
