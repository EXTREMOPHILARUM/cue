import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { mkdtemp, readFile, rm, access, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { setTimeout as delay } from 'node:timers/promises';
import { browserEndpoint, connect } from './call-context.mjs';
const root=new URL('../',import.meta.url);
test('isolated Chromium: real WebRTC media capture and usable capture popup', {timeout:35000},async()=>{
  const executable=process.env.CALL_CONTEXT_TEST_CHROME;
  assert.ok(executable,'Set an explicit test Chrome executable');
  await access(executable);
  const speech=process.env.CALL_ASSISTANT_SPEECH_OUTPUT;
  const encodedTest=process.env.CALL_ASSISTANT_ENCODED_TEST==='1';
  const media=(await readFile(new URL('meet-presence.js',root),'utf8'))+'\n'+(await readFile(new URL('meet-speakers.js',root),'utf8'))+'\n'+(await readFile(new URL('meet-routing.js',root),'utf8'))+'\n'+(await readFile(new URL('call-media.js',root),'utf8'));
  const mock=`<script>
    const calls=Array.from({length:93},(_,i)=>({id:'call-'+i,topic:i===0?'Pilot review':'Saved call '+i,participants:['Fixture'],caption_count:3,started_at:Date.now()}));
    window.chrome={runtime:{id:'fixture',getManifest:()=>({version:'test',content_scripts:[{js:['call-media.js']}]}),sendMessage(message,callback){const value=message.type==='LIST_CALLS'?calls:message.type==='GET_CALL'?{...calls.find(c=>c.id===message.id),captions:[]}:message.type==='NATIVE_STATUS'?{connected:true,pending:0}:message.type==='GET_SETTING'?{value:false}:{};callback?.(value);return Promise.resolve(value);}},tabs:{query:async()=>[]},storage:{local:{get:(key,callback)=>callback({}),set:async()=>{}}}};
  </script>`;
  let popup=await readFile(new URL('popup.html',root),'utf8');popup=popup.replace('<script src="popup.js">',mock+'<script src="popup.js">');
  let rtc=`<!doctype html><title>Local WebRTC fixture</title><script>
    window.mediaEvents=[];addEventListener('message',event=>{
      if(event.data?.source!=='call-assistant-media')return;
      const message=event.data;
      if(message.event==='audio'){
        const frame=message.frame,pcm=new Float32Array(Uint8Array.from(atob(frame.pcm),c=>c.charCodeAt(0)).buffer);
        let sum=0,crossings=0;for(let i=0;i<pcm.length;i++){sum+=pcm[i]*pcm[i];if(i && pcm[i-1]<0 && pcm[i]>=0)crossings++;}
        message.summary={source:frame.source,trackID:frame.trackID,method:frame.captureMethod,bytes:frame.pcm.length,rms:Math.sqrt(sum/pcm.length),frequency:crossings*16000/pcm.length};
      }
      mediaEvents.push(message);
    });
  </script><script>${media}</script><script>
    async function gathered(pc){if(pc.iceGatheringState==='complete')return;await new Promise(resolve=>pc.addEventListener('icegatheringstatechange',()=>{if(pc.iceGatheringState==='complete')resolve();}));}
    window.run=async()=>{window.postMessage({source:'call-assistant-control',enabled:true},location.origin);const audio=new AudioContext();const oscillator=audio.createOscillator();oscillator.frequency.value=440;const dest=audio.createMediaStreamDestination();oscillator.connect(dest);oscillator.start();const other=audio.createOscillator();other.frequency.value=880;const otherDest=audio.createMediaStreamDestination();other.connect(otherDest);other.start();window.otherTrack=otherDest.stream.getAudioTracks()[0];await audio.resume();window.track=dest.stream.getAudioTracks()[0];window.a=new RTCPeerConnection({iceServers:[]});window.b=new RTCPeerConnection({iceServers:[]});a.addTrack(track,dest.stream);b.addTrack(otherTrack,otherDest.stream);await a.setLocalDescription(await a.createOffer());await gathered(a);await b.setRemoteDescription(a.localDescription);await b.setLocalDescription(await b.createAnswer());await gathered(b);await a.setRemoteDescription(b.localDescription);return true;};
  </script>`;
  if(speech)rtc=rtc.replace('const oscillator=audio.createOscillator();oscillator.frequency.value=440;', 'const oscillator=audio.createBufferSource();oscillator.buffer=await audio.decodeAudioData(await (await fetch("/local.wav")).arrayBuffer());').replace('const other=audio.createOscillator();other.frequency.value=880;', 'const other=audio.createBufferSource();other.buffer=await audio.decodeAudioData(await (await fetch("/remote.wav")).arrayBuffer());');
  if(speech)rtc=rtc.replace('oscillator.start();','').replace('other.start();','').replace('await a.setRemoteDescription(b.localDescription);return true;', 'await a.setRemoteDescription(b.localDescription);while(a.connectionState!=="connected" || b.connectionState!=="connected")await new Promise(resolve=>setTimeout(resolve,20));await new Promise(resolve=>setTimeout(resolve,600));oscillator.start();other.start();return true;');
  if(encodedTest)rtc=rtc.replaceAll('new RTCPeerConnection({iceServers:[]})','new RTCPeerConnection({iceServers:[],encodedInsertableStreams:true})').replace('a.addTrack(track,dest.stream);b.addTrack(otherTrack,otherDest.stream);','for(const peer of [a,b])peer.addEventListener("track",event=>{const streams=event.receiver.createEncodedStreams();void streams.readable.pipeTo(streams.writable);});const sa=a.addTrack(track,dest.stream),sb=b.addTrack(otherTrack,otherDest.stream);for(const sender of [sa,sb]){const streams=sender.createEncodedStreams();void streams.readable.pipeTo(streams.writable);}');
  const server=createServer(async(req,res)=>{try{if(speech && ['/local.wav','/remote.wav'].includes(req.url)){res.setHeader('Content-Type','audio/wav');res.end(await readFile('/tmp/call-assistant-'+req.url.slice(1)));}else if(req.url==='/rtc'){res.setHeader('Content-Type','text/html');res.end(rtc);}else if(req.url==='/popup'){res.setHeader('Content-Type','text/html');res.end(popup);}else{const name=req.url.slice(1);if(!['popup.js','call-history.js','native-popup.js','icons/icon32.png','extension-ui.css','popup.css'].includes(name)){res.writeHead(404);res.end();return;}res.setHeader('Content-Type',name.endsWith('.png')?'image/png':name.endsWith('.css')?'text/css':'text/javascript');res.end(await readFile(new URL(name,root)));}}catch(error){res.writeHead(500);res.end(error.message);}});
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  const profile=await mkdtemp(join(tmpdir(),'call-assistant-auto-'));
  const url=`http://127.0.0.1:${server.address().port}`;
  const chrome=spawn(executable,[`--user-data-dir=${profile}`,'--remote-debugging-port=0','--headless=new','--no-first-run','--disable-extensions','--autoplay-policy=no-user-gesture-required',url+'/rtc'],{stdio:'ignore'});
  let launchError;chrome.on('error',error=>{launchError=error;});
  let client;
  try{
    let endpoint;for(let i=0;i<100;i++){if(launchError)throw launchError;try{endpoint=await browserEndpoint(join(profile,'DevToolsActivePort'));break;}catch(error){if(error.code!=='ENOENT')throw error;}await delay(50);}
    assert.ok(endpoint);client=await connect(endpoint);
    const target=(await client.send('Target.getTargets')).targetInfos.find(t=>t.url===url+'/rtc');assert.ok(target);
    const {sessionId}=await client.send('Target.attachToTarget',{targetId:target.targetId,flatten:true});
    const evaluate=async expression=>{const response=await client.send('Runtime.evaluate',{expression,awaitPromise:true,returnByValue:true,timeout:10000},sessionId);assert.equal(response.exceptionDetails,undefined,JSON.stringify(response.exceptionDetails));return response.result.value;};
    for(let i=0;i<100;i++){if(await evaluate('typeof run === "function"'))break;await delay(50);}
    assert.equal(await evaluate('typeof run'),'function');
    const attribution=await evaluate(`(async()=>{
      const warnings=[],names=new CallAssistantMeetSpeakers(()=>{},message=>warnings.push(message));
      const plain=Uint8Array.from(atob('CigSJmoRCg8SDQoGcmVtb3RlEgNTYW0aERIPEAEiAzEwMTIGcmVtb3Rl'),c=>c.charCodeAt(0));
      const speakers=[];
      for(const format of ['deflate','gzip',null]) {
        const data=format ? new Uint8Array(await new Response(new Blob([plain]).stream().pipeThrough(new CompressionStream(format))).arrayBuffer()):plain;
        await names.readCollection(data);speakers.push(names.identity({contributingSources:[101]}).speaker);
      }
      return {speakers,warnings};
    })()`);
    assert.deepEqual(attribution,{speakers:['Sam','Sam','Sam'],warnings:[]},'Real Chrome must decode zlib, gzip and plain participant updates');
    await evaluate('run()');
    console.info('Isolated RTC fixture connected');
    let stats;const began=Date.now();
    const readStats=()=>evaluate('({state:a.connectionState,frames:mediaEvents.filter(e=>e.event==="audio").map(e=>e.summary),errors:mediaEvents.filter(e=>e.event==="error"),original:track.readyState})');
    for(let i=0;i<220;i++){stats=await readStats();if(speech ? Date.now()-began>=16500 : stats.frames.filter(f=>f.source==='remote').length>=2 && stats.frames.filter(f=>f.source==='local').length>=2)break;await delay(100);}
    if(speech){await evaluate('window.postMessage({source:"call-assistant-control",enabled:false},location.origin);true');await delay(200);stats=await readStats();}
    console.info('Capture methods:',[...new Set(stats.frames.map(f=>f.method))]);
    if(encodedTest)assert.ok(stats.frames.some(f=>f.method==='encoded-opus'),JSON.stringify(stats));
    assert.equal(stats.state,'connected');assert.ok(stats.frames.some(f=>f.source==='remote'),JSON.stringify(stats));assert.ok(stats.frames.some(f=>f.source==='local'),JSON.stringify(stats));for(const track of new Set(stats.frames.map(f=>f.trackID)))assert.ok(stats.frames.some(f=>f.trackID===track && f.rms>(speech?.005:.05)),JSON.stringify(stats));assert.equal(stats.original,'live');assert.deepEqual(stats.errors,[]);
    if(speech){const frames=[];for(let i=0;i<stats.frames.length;i++)frames.push(await evaluate(`mediaEvents.filter(e=>e.event==="audio")[${i}].frame`));await writeFile(speech,JSON.stringify(frames));}
    else for(const source of ['local','remote'])for(const frequency of [440,880])assert.ok(stats.frames.some(f=>f.source===source && Math.abs(f.frequency-frequency)<20),JSON.stringify(stats));
    await evaluate('window.postMessage({source:"call-assistant-control",enabled:false},location.origin);true');await delay(300);
    assert.deepEqual(await evaluate('({a:a.connectionState,b:b.connectionState,local:track.readyState,other:otherTrack.readyState})'),{a:'connected',b:'connected',local:'live',other:'live'});
    const disabledCount=await evaluate('mediaEvents.filter(e=>e.event==="audio").length');await delay(500);
    assert.equal(await evaluate('mediaEvents.filter(e=>e.event==="audio").length'),disabledCount);
    await evaluate('window.postMessage({source:"call-assistant-control",enabled:true},location.origin);true');await delay(4500);
    assert.ok(await evaluate('mediaEvents.filter(e=>e.event==="audio").length')>disabledCount,'Capture must resume without reconnecting the call');
    await evaluate('a.close();b.close();true');await delay(3500);
    assert.equal(await evaluate('track.readyState'),'live','Our cleanup must not stop the meeting’s original track');
    assert.ok(await evaluate('mediaEvents.some(e=>e.event==="end")'));
    await client.send('Page.navigate',{url:url+'/popup'},sessionId);
    for(let i=0;i<50;i++){if(await evaluate('!!document.getElementById("call-name")'))break;await delay(50);}
    await delay(100);
    const layout=await evaluate('({library:!!document.getElementById("calls"),banner:document.getElementById("native-status").getBoundingClientRect().height,title:document.getElementById("call-name").textContent})');
    assert.equal(layout.library,false);assert.ok(layout.banner<60);assert.equal(layout.title,'No active Meet call');
    await client.send('Target.detachFromTarget',{sessionId});
  }finally{client?.close();const exited=new Promise(resolve=>chrome.once('exit',resolve));if(chrome.pid && chrome.exitCode===null){chrome.kill('SIGTERM');await exited;}await new Promise(resolve=>server.close(resolve));await rm(profile,{recursive:true,force:true});}
});
