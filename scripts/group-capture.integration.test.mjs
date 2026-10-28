import test from 'node:test';
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {spawn} from 'node:child_process';
import {mkdtemp,readFile,rm,access} from 'node:fs/promises';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {setTimeout as delay} from 'node:timers/promises';
import {browserEndpoint,connect} from './call-context.mjs';
const root=new URL('../',import.meta.url);
const vi=n=>{const a=[];do{a.push((n&127)|(n>127?128:0));n=Math.floor(n/128);}while(n);return a;};
const field=(n,v)=>[...vi(n*8+2),...vi(v.length),...v];
const text=(n,v)=>field(n,[...Buffer.from(v)]);
const user=(id,name,self=false)=>[...text(1,id),...text(2,name),...(self?text(7,'self'):[])];
const output=(id,csrc)=>[16,1,...text(4,csrc),...text(6,id)];
const packet=Buffer.from(field(1,field(2,[...field(13,field(1,[...field(2,user('self','Morgan',true)),...field(2,user('a','Taylor')),...field(2,user('d','Jordan'))])),...field(3,[...field(2,output('a','101')),...field(2,output('d','102'))])]))).toString('base64');

test('isolated Chromium three-party WebRTC: source reuse, activity correction and durable chunk evidence', {timeout:50000},async()=>{
 const executable=process.env.CALL_CONTEXT_TEST_CHROME;assert.ok(executable,'Set an explicit isolated test Chrome executable');await access(executable);
 let capture=(await Promise.all(['meet-presence.js','meet-speakers.js','meet-routing.js','call-media.js'].map(f=>readFile(new URL(f,root),'utf8')))).join('\n');
 // Local test provider supplies CSRC metadata/participant tiles; no real Meet session or user profile is accessed.
 capture=capture.replace("location.hostname==='meet.google.com'","true");
 const html=`<!doctype html><title>Isolated group fixture</title>
 <button aria-label='Leave call'>call_end</button><div data-participant-id='a' data-display-name='Taylor'><i data-is-speaking='true' style='display:block;width:10px;height:10px'></i></div>
 <div data-participant-id='d' data-display-name='Jordan'><i data-is-speaking='true' style='display:block;width:10px;height:10px'></i></div>
 <script>
 const originalStreams=RTCRtpReceiver.prototype.createEncodedStreams;
 RTCRtpReceiver.prototype.createEncodedStreams=function(){const receiver=this,result=originalStreams.call(this);return {...result,readable:result.readable.pipeThrough(new TransformStream({transform(frame,controller){const metadata=frame.getMetadata();Object.defineProperty(frame,'getMetadata',{value:()=>({...metadata,contributingSources:receiver.fixtureCSRC || []})});controller.enqueue(frame);}}))};};
 window.records=[];addEventListener('message',e=>{if(e.data?.source!=='call-assistant-media')return;const m=e.data;if(m.event==='audio'){const f=m.frame,x=new Float32Array(Uint8Array.from(atob(f.pcm),c=>c.charCodeAt(0)).buffer);let sum=0,cross=0;for(let i=0;i<x.length;i++){sum+=x[i]*x[i];if(i && x[i-1]<=0 && x[i]>0)cross++;}records.push({event:'audio',source:f.source,speaker:f.speaker,method:f.attribution,trackID:f.trackID,samples:x.length,rms:Math.sqrt(sum/x.length),frequency:cross*16000/x.length,history:f.mappingHistory,range:f.packetRange});}else records.push(m);});
 </script><script>${capture}</script><script>
 window.fixture={hosts:[],guests:[],receivers:[],tracks:[],tones:[]};
 async function run(){
  postMessage({source:'call-assistant-control',enabled:true},location.origin);
  const ctx=new AudioContext();await ctx.resume();
  function tone(f){const osc=ctx.createOscillator(),dest=ctx.createMediaStreamDestination();osc.frequency.value=f;osc.connect(dest);osc.start();fixture.tones.push(osc);return dest.stream;}
  const local=tone(220);fixture.local=local.getAudioTracks()[0];
  for(let i=0;i<2;i++){
   const iframe=document.createElement('iframe');const loaded=new Promise(r=>iframe.onload=r);iframe.src='/guest';document.body.append(iframe);await loaded;
   const remote=tone(i===0?440:880),remoteTrack=remote.getAudioTracks()[0];fixture.tracks.push(remoteTrack);
   const host=new RTCPeerConnection({iceServers:[],encodedInsertableStreams:true});const guest=new iframe.contentWindow.RTCPeerConnection({iceServers:[],encodedInsertableStreams:true});fixture.hosts.push(host);fixture.guests.push(guest);
   host.addEventListener('icecandidate',e=>{if(e.candidate)guest.addIceCandidate(e.candidate)});guest.addEventListener('icecandidate',e=>{if(e.candidate)host.addIceCandidate(e.candidate)});
   host.addEventListener('track',e=>{e.receiver.fixtureCSRC=[101+i];fixture.receivers[i]=e.receiver;const s=e.receiver.createEncodedStreams();s.readable.pipeTo(s.writable);});
   guest.addEventListener('track',e=>{const s=e.receiver.createEncodedStreams();s.readable.pipeTo(s.writable);});
   guest.addEventListener('datachannel',e=>e.channel.addEventListener('open',()=>e.channel.send(Uint8Array.from(atob('${packet}'),c=>c.charCodeAt(0)))));host.createDataChannel('collections');
   for(const [peer,track,stream] of [[host,fixture.local,local],[guest,remoteTrack,remote]]){const sender=peer.addTrack(track,stream),s=sender.createEncodedStreams();s.readable.pipeTo(s.writable);}
   await host.setLocalDescription(await host.createOffer());await guest.setRemoteDescription(host.localDescription);await guest.setLocalDescription(await guest.createAnswer());await host.setRemoteDescription(guest.localDescription);
   while(host.connectionState!=='connected' || guest.connectionState!=='connected')await new Promise(r=>setTimeout(r,20));
  }
  return true;
 }
 </script>`;
 const server=createServer((req,res)=>{res.setHeader('Content-Type','text/html');res.end(req.url==='/guest'?'<!doctype html><title>Guest fixture</title>':html);});await new Promise(r=>server.listen(0,'127.0.0.1',r));
 const profile=await mkdtemp(join(tmpdir(),'call-assistant-group-')),url='http://127.0.0.1:'+server.address().port;
 const chrome=spawn(executable,[`--user-data-dir=${profile}`,'--remote-debugging-port=0','--headless=new','--no-first-run','--disable-extensions','--autoplay-policy=no-user-gesture-required',url],{stdio:'ignore'});let client;
 try{
  let endpoint;for(let i=0;i<120;i++){try{endpoint=await browserEndpoint(join(profile,'DevToolsActivePort'));break;}catch(e){if(e.code!=='ENOENT')throw e;}await delay(50);}assert.ok(endpoint);
  client=await connect(endpoint);const target=(await client.send('Target.getTargets')).targetInfos.find(t=>t.url===url+'/');assert.ok(target);
  const {sessionId}=await client.send('Target.attachToTarget',{targetId:target.targetId,flatten:true});
  const evaluate=async expression=>{const r=await client.send('Runtime.evaluate',{expression,awaitPromise:true,returnByValue:true,timeout:10000},sessionId);assert.equal(r.exceptionDetails,undefined,JSON.stringify(r.exceptionDetails));return r.result.value;};
  for(let i=0;i<80 && !await evaluate('typeof run==="function"');i++)await delay(50);
  await evaluate('run()');
  let audio=[];for(let i=0;i<120;i++){audio=await evaluate('records.filter(r=>r.event==="audio")');if(['Taylor','Jordan'].every(n=>audio.some(r=>r.speaker===n && r.samples>=32000)))break;await delay(100);}
  for(const [name,hz] of [['Taylor',440],['Jordan',880]])assert.ok(audio.some(r=>r.speaker===name && r.method==='meet-rtp' && Math.abs(r.frequency-hz)<20 && r.rms>.02),JSON.stringify(audio));
  assert.ok(audio.some(r=>r.source==='local' && Math.abs(r.frequency-220)<20),JSON.stringify(audio));
  await evaluate('fixture.tracks[0].enabled=false;document.querySelector("[data-participant-id=a] i").setAttribute("data-is-speaking","false");fixture.receivers[1].fixtureCSRC=[101];true');
  for(let i=0;i<120;i++){audio=await evaluate('records.filter(r=>r.event==="audio")');if(audio.some(r=>r.speaker==='Jordan' && r.method==='meet-activity' && r.samples>=32000))break;await delay(100);}
  const corrected=audio.filter(r=>r.method==='meet-activity' && r.speaker==='Jordan');assert.ok(corrected.length,JSON.stringify(audio));
  assert.ok(corrected.every(r=>Math.abs(r.frequency-880)<20 && r.history[0].protocol.rawDeviceID==='a' && r.history[0].contributors[0]==='101'),JSON.stringify(corrected));
  await evaluate('postMessage({source:"call-assistant-control",enabled:false},location.origin);true');await delay(200);
  const state=await evaluate('({peers:[...fixture.hosts,...fixture.guests].map(p=>p.connectionState),tracks:[fixture.local,...fixture.tracks].map(t=>t.readyState),errors:records.filter(r=>r.event==="error")})');
  assert.ok(state.peers.every(s=>s==='connected'));assert.ok(state.tracks.every(s=>s==='live'));assert.deepEqual(state.errors,[]);
  console.info('Three-party RTC verified: separate 440/880 Hz remote identities, 220 Hz microphone, recycled-source activity correction, original calls still connected');
 }finally{client?.close();if(chrome.exitCode===null){const ended=new Promise(r=>chrome.once('exit',r));chrome.kill('SIGTERM');await ended;}await new Promise(r=>server.close(r));await rm(profile,{recursive:true,force:true});}
});
