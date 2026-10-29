import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import {readFile} from 'node:fs/promises';

test('WebRTC adapter captures connected call tracks, respects outgoing mute, and never stops originals',async()=>{
  const players=[],events=[],listeners={},contexts=[],intervals=[],timers=[];
  class Track {kind='audio';readyState='live';enabled=true;muted=false;stopped=false;clone(){const clone=new Track();this.copy=clone;return clone;}stop(){this.stopped=true;}addEventListener(){}}
  const incoming=new Track(),outgoing=new Track();
  class Peer {connectionState='new';iceConnectionState='new';getReceivers(){return [{track:incoming}];}getSenders(){return [{track:outgoing,getParameters:()=>({encodings:[{active:true}]})}];}listeners={};addEventListener(type,fn){this.listeners[type]=fn;}}
  class Context {sampleRate=48000;state='running';destination={};constructor(){contexts.push(this);}createMediaStreamSource(stream){this.stream=stream;return {connect(){},disconnect(){}};}createGain(){return {gain:{},connect(){},disconnect(){}};}createScriptProcessor(){return this.node={connect(){},disconnect(){}};}async resume(){}async close(){this.closed=true;}}
  const window={RTCPeerConnection:Peer,addEventListener:(type,fn)=>{listeners[type]=fn;},postMessage:message=>events.push(message)};
  const scope=vm.createContext({window,RTCPeerConnection:Peer,AudioContext:Context,Audio:class{constructor(){players.push(this);}async play(){}pause(){this.paused=true;}},MediaStream:class{},location:{origin:'https://call.example'},crypto,Date,Float32Array,Uint8Array,btoa,console,setInterval:fn=>intervals.push(fn),setTimeout:fn=>{timers.push(fn);return timers.length;},clearTimeout(){}});
  vm.runInContext(await readFile(new URL('../call-media.js',import.meta.url),'utf8'),scope);
  const peer=new window.RTCPeerConnection();const providerStream={getAudioTracks:()=>[incoming]};peer.listeners.track({track:incoming,streams:[providerStream]});intervals[0]();assert.equal(events.length,0,'A non-connected peer is not a call');
  listeners.message({source:window,origin:'https://call.example',data:{source:'call-assistant-control',enabled:true}});
  peer.connectionState='connected';intervals[0]();assert.equal(events[0].event,'start');assert.equal(contexts.length,2);assert.equal(contexts[0].stream,providerStream,'Preserve the provider receiver stream');
  const process=context=>{const output=new Float32Array(48000).fill(1);context.node.onaudioprocess({inputBuffer:{getChannelData:()=>new Float32Array(48000).fill(.3)},outputBuffer:{getChannelData:()=>output}});assert.ok(output.every(x=>x===0),'Capture must not play a second copy of the call');};
  for(let i=0;i<4;i++)for(const context of contexts)process(context);
  assert.deepEqual(events.filter(e=>e.event==='audio').map(e=>e.frame.source).sort(),['local','remote']);
  const local=contexts[1];outgoing.enabled=false;
  const count=events.filter(e=>e.event==='audio' && e.frame.source==='local').length;
  for(let i=0;i<5;i++)process(local);
  assert.equal(events.filter(e=>e.event==='audio' && e.frame.source==='local').length,count,'Muted outgoing audio is not captured');
  peer.connectionState='closed';intervals[0]();timers.forEach(fn=>fn());
  assert.equal(events.at(-1).event,'end');assert.ok(contexts.every(c=>c.closed));
  assert.equal(players.length,1);assert.equal(players[0].volume,0);assert.equal(players[0].srcObject,null);assert.equal(players[0].paused,true);assert.equal(incoming.stopped,false);assert.equal(outgoing.stopped,false);
  assert.equal(incoming.copy,undefined,'Receiver tracks must not be cloned or stopped');assert.equal(outgoing.copy.stopped,true);
});

test('receiver processor attaches at ontrack, drains warm frames, mixes channels and never stops the original',async()=>{
  const events=[],listeners={},intervals=[],readers=[];let closed=0,cancelled=0;
  const track={id:'receiver',kind:'audio',readyState:'live',enabled:true,muted:false,stopped:false,stop(){this.stopped=true;},addEventListener(){}};
  class Peer{connectionState='new';iceConnectionState='new';listeners={};addEventListener(type,fn){this.listeners[type]=fn;}getReceivers(){return [{track}];}getSenders(){return [];}}
  class Processor{constructor({track:input}){assert.equal(input,track);this.readable=new ReadableStream({start:controller=>readers.push(controller),cancel:()=>cancelled++});}}
  class AudioFrame{numberOfFrames=64000;numberOfChannels=2;sampleRate=16000;copyTo(plane,{planeIndex}){plane.fill(planeIndex===0?.2:.4);}close(){closed++;}}
  const window={RTCPeerConnection:Peer,addEventListener:(type,fn)=>listeners[type]=fn,postMessage:message=>events.push(message)};
  const scope=vm.createContext({window,RTCPeerConnection:Peer,MediaStreamTrackProcessor:Processor,AudioData:AudioFrame,Audio:class{async play(){}pause(){}},MediaStream:class{},location:{origin:'https://call.example'},crypto,Date,Float32Array,Uint8Array,btoa,setInterval:fn=>intervals.push(fn),setTimeout:()=>1,clearTimeout(){}});
  vm.runInContext(await readFile(new URL('../call-media.js',import.meta.url),'utf8'),scope);
  const control=enabled=>listeners.message({source:window,origin:'https://call.example',data:{source:'call-assistant-control',enabled}});
  control(true);const peer=new window.RTCPeerConnection();peer.listeners.track({track,streams:[]});
  assert.equal(readers.length,1,'Attach before the connection becomes active');
  readers[0].enqueue(new AudioFrame());await new Promise(setImmediate);
  assert.equal(closed,1);assert.equal(events.filter(e=>e.event==='audio').length,0,'Prewarm must not save audio');
  peer.connectionState='connected';intervals[0]();readers[0].enqueue(new AudioFrame());await new Promise(setImmediate);
  const frame=events.find(e=>e.event==='audio').frame;assert.equal(frame.captureMethod,'track-processor');assert.equal(frame.source,'remote');
  const pcm=new Float32Array(Uint8Array.from(atob(frame.pcm),x=>x.charCodeAt(0)).buffer);assert.equal(pcm.length,64000);assert.ok(pcm.every(x=>Math.abs(x-.3)<.00001));
  control(false);await new Promise(setImmediate);assert.equal(cancelled,1);assert.equal(track.stopped,false);assert.equal(closed,2);
  peer.connectionState='closed';intervals[0]();assert.equal(events.at(-1).event,'end');
});

test('negotiated Opus/RED parsing rejects malformed or unnegotiated payloads',async()=>{
  const source=await readFile(new URL('../call-media.js',import.meta.url),'utf8');
  const window={RTCPeerConnection:class{},addEventListener(){}};
  const point=source.lastIndexOf('})();');
  vm.runInNewContext(source.slice(0,point)+'window.testOpus=meetPrimaryOpusPayload;window.testDuration=opusDuration;'+source.slice(point),{window,RTCPeerConnection:window.RTCPeerConnection,setInterval(){},Uint8Array,ArrayBuffer});
  const parse=window.testOpus,codecs=[{payloadType:109,mimeType:'audio/opus'},{payloadType:121,mimeType:'audio/red'}];
  assert.deepEqual([...parse(new Uint8Array([1,2]),{payloadType:109},codecs)],[1,2]);
  assert.deepEqual([...parse(new Uint8Array([109,1,2]),{payloadType:121},codecs)],[1,2]);
  assert.deepEqual([...parse(new Uint8Array([128|109,0,0,2,109,9,9,1,2]),{payloadType:121},codecs)],[1,2]);
  for(const data of [[128|109],[109],[128|109,0,3,255,109,1]])assert.equal(parse(new Uint8Array(data),{payloadType:121},codecs),null);
  assert.equal(parse(new Uint8Array([1,2]),{payloadType:99},codecs),null);
  assert.equal(parse(new Uint8Array([99,1,2]),{payloadType:121},codecs),null);
  for(const [toc,expected] of [[0,10000],[8,20000],[16,40000],[24,60000],[96,10000],[104,20000],[128,2500],[136,5000],[144,10000],[152,20000]])assert.equal(window.testDuration(new Uint8Array([toc,9])),expected);
  assert.equal(window.testDuration(new Uint8Array([27,2,9])),120000);
  for(const payload of [[3,0],[27,3],[131]])assert.equal(window.testDuration(new Uint8Array(payload)),0);
});

test('encoded observer always forwards the exact original frame even if observation throws',async()=>{
  let controller;const forwarded=[];
  class Receiver{track={kind:'audio'};createEncodedStreams(){return {readable:new ReadableStream({start:value=>controller=value}),writable:{original:true}};}}
  const window={RTCPeerConnection:class{},addEventListener(){}};
  let source=await readFile(new URL('../call-media.js',import.meta.url),'utf8');
  source=source.replace('function observeEncoded(receiver,frame){','function observeEncoded(receiver,frame){throw new Error("deliberate observer failure");');
  vm.runInNewContext(source,{window,RTCPeerConnection:window.RTCPeerConnection,RTCRtpReceiver:Receiver,AudioDecoder:class{},TransformStream,setInterval(){}});
  const streams=new Receiver().createEncodedStreams();assert.equal(streams.writable.original,true);
  const frame={data:new Uint8Array([1,2,3]).buffer};controller.enqueue(frame);controller.close();
  await streams.readable.pipeTo(new WritableStream({write:value=>forwarded.push(value)}));
  assert.equal(forwarded[0],frame);assert.deepEqual([...new Uint8Array(frame.data)],[1,2,3]);
});

test('encoded group-call audio keeps delayed decoder outputs bound to their own Meet participant',async()=>{
  const events=[],listeners={},intervals=[],pending=[];let controller,names;
  const track={id:'shared-receiver',kind:'audio',readyState:'live',enabled:true,muted:false,addEventListener(){}};
  class Receiver{track=track;getParameters(){return {codecs:[{payloadType:109,mimeType:'audio/opus'}]};}createEncodedStreams(){return {readable:new ReadableStream({start:c=>controller=c}),writable:{original:true}};}}
  const receiver=new Receiver();
  class Peer{connectionState='connected';iceConnectionState='connected';listeners={};addEventListener(type,fn){this.listeners[type]=fn;}getReceivers(){return [receiver];}getSenders(){return [];}createDataChannel(){return channel;}}
  const channel={label:'collections',binaryType:'blob',addEventListener(){}};
  class Decoder{state='configured';decodeQueueSize=0;constructor(callbacks){this.callbacks=callbacks;}configure(){}decode(chunk){pending.push(()=>this.callbacks.output({timestamp:chunk.timestamp,numberOfFrames:320,numberOfChannels:1,sampleRate:16000,copyTo:plane=>plane.fill(.2),close(){}}));}close(){this.state='closed';}}
  class Processor{constructor(){this.readable=new ReadableStream();}}
  const originalResponse={url:'https://meet.google.com/unrelated',untouched:true};const originalPromise=Promise.resolve(originalResponse);
  const window={RTCPeerConnection:Peer,fetch:()=>originalPromise,addEventListener:(type,fn)=>listeners[type]=fn,postMessage:message=>events.push(message)};
  const scope=vm.createContext({window,location:{origin:'https://meet.google.com',hostname:'meet.google.com'},RTCPeerConnection:Peer,RTCRtpReceiver:Receiver,MediaStreamTrackProcessor:Processor,AudioData:class{},AudioDecoder:Decoder,EncodedAudioChunk:class{constructor(value){Object.assign(this,value);}},Audio:class{async play(){}pause(){}},MediaStream:class{},ReadableStream,TransformStream,TextDecoder,Uint8Array,Float32Array,ArrayBuffer,Blob,DecompressionStream,Response,atob,btoa,crypto,Date,setInterval:fn=>intervals.push(fn),setTimeout:()=>1,clearTimeout(){}});
  vm.runInContext(await readFile(new URL('../meet-speakers.js',import.meta.url),'utf8'),scope);
  vm.runInContext(await readFile(new URL('../meet-routing.js',import.meta.url),'utf8'),scope);
  const Resolver=scope.CallAssistantMeetSpeakers;scope.CallAssistantMeetSpeakers=class extends Resolver{constructor(...args){super(...args);names=this;}};
  vm.runInContext(await readFile(new URL('../call-media.js',import.meta.url),'utf8'),scope);
  names.update({users:[{deviceId:'a',fullName:'Casey Rivera'},{deviceId:'b',fullName:'Riley'}],deviceOutputs:[{deviceId:'a',streamId:'101',outputType:1},{deviceId:'b',streamId:'102',outputType:1}]});
  assert.equal(window.fetch('https://meet.google.com/unrelated'),originalPromise,'The observer must return the exact original fetch Promise');
  const control=enabled=>listeners.message({source:window,origin:'https://meet.google.com',data:{source:'call-assistant-control',enabled}});
  control(true);const peer=new window.RTCPeerConnection();assert.equal(peer.createDataChannel(),channel);assert.equal(channel.binaryType,'blob');intervals[0]();
  const streams=receiver.createEncodedStreams(),forwarded=[];const drain=streams.readable.pipeTo(new WritableStream({write:frame=>forwarded.push(frame)}));
  const frames=[[101],[102],[101,102],[101]].map(contributingSources=>({data:new Uint8Array([1,2]).buffer,getMetadata:()=>({payloadType:109,contributingSources})}));
  for(const frame of frames)controller.enqueue(frame);controller.close();await drain;
  assert.deepEqual(forwarded,frames,'All original encoded frames must reach Meet unchanged');
  assert.equal(pending.length,4);for(const output of pending)output();control(false);
  const audio=events.filter(e=>e.event==='audio').map(e=>e.frame);
  assert.deepEqual(audio.map(frame=>frame.speaker),['Casey Rivera','Riley','Multiple speakers','Casey Rivera']);
  assert.deepEqual(audio.map(frame=>frame.attribution),['meet-rtp','meet-rtp','mixed','meet-rtp']);
  assert.ok(audio.every(frame=>frame.trackID==='shared-receiver'));
});

test('activity correlation buffers first syllables and persists uncertain tails without touching Meet frames',async()=>{
  const events=[],listeners={},intervals=[],forwarded=[];let controller,names,router,clock=1000;
  const track={id:'shared',kind:'audio',readyState:'live',enabled:true,muted:false,addEventListener(){},stop(){assert.fail('Original receiver stopped');}};
  class Receiver{track=track;getParameters(){return {codecs:[{payloadType:109,mimeType:'audio/opus'}]};}createEncodedStreams(){return {readable:new ReadableStream({start:c=>controller=c}),writable:{}};}}
  const receiver=new Receiver();
  class Peer{connectionState='connected';listeners={};addEventListener(t,f){this.listeners[t]=f;}getReceivers(){return [receiver];}getSenders(){return [];}}
  class Processor{constructor(){this.readable=new ReadableStream();}}
  class Decoder{state='configured';decodeQueueSize=0;constructor(callbacks){this.callbacks=callbacks;}configure(){}decode(chunk){this.callbacks.output({timestamp:chunk.timestamp,numberOfFrames:320,numberOfChannels:1,sampleRate:16000,copyTo:p=>p.fill(.2),close(){}});}close(){this.state='closed';}}
  class Clock extends Date{static now(){return clock;}}
  const window={RTCPeerConnection:Peer,addEventListener:(t,f)=>listeners[t]=f,postMessage:m=>events.push(m)};
  const scope=vm.createContext({window,location:{hostname:'meet.google.com',origin:'https://meet.google.com'},RTCPeerConnection:Peer,RTCRtpReceiver:Receiver,MediaStreamTrackProcessor:Processor,AudioData:class{},AudioDecoder:Decoder,EncodedAudioChunk:class{constructor(x){Object.assign(this,x);}},Audio:class{async play(){}pause(){}},MediaStream:class{},ReadableStream,TransformStream,TextDecoder,Uint8Array,Float32Array,ArrayBuffer,atob,btoa,crypto,Date:Clock,setInterval:f=>intervals.push(f),setTimeout:()=>1,clearTimeout(){}});
  for(const path of ['meet-speakers.js','meet-routing.js'])vm.runInContext(await readFile(new URL('../'+path,import.meta.url),'utf8'),scope);
  const Names=scope.CallAssistantMeetSpeakers,Router=scope.CallAssistantMeetRouter;
  scope.CallAssistantMeetSpeakers=class extends Names{constructor(...args){super(...args);names=this;}};
  scope.CallAssistantMeetRouter=class extends Router{constructor(...args){super(...args);router=this;}scan(){}};
  vm.runInContext(await readFile(new URL('../call-media.js',import.meta.url),'utf8'),scope);
  names.update({users:[{deviceId:'a',fullName:'Taylor'},{deviceId:'d',fullName:'Jordan'}]});
  listeners.message({source:window,origin:'https://meet.google.com',data:{source:'call-assistant-control',enabled:true}});
  const peer=new window.RTCPeerConnection();intervals[0]();
  const streams=receiver.createEncodedStreams(),drain=streams.readable.pipeTo(new WritableStream({write:f=>forwarded.push(f)}));
  const originals=[];
  for(let i=0;i<41;i++){
    const frame={data:new Uint8Array([1,2]).buffer,timestamp:i*20000,getMetadata(){clock=1000+i*20;router.active=[{id:i<31?'a':'d',name:i<31?'Taylor':'Jordan',isSelf:false}];return {payloadType:109,contributingSources:[101],synchronizationSource:999,rtpTimestamp:i*960};}};
    originals.push(frame);controller.enqueue(frame);
  }
  controller.close();await drain;
  listeners.message({source:window,origin:'https://meet.google.com',data:{source:'call-assistant-control',enabled:false}});
  const audio=events.filter(e=>e.event==='audio').map(e=>e.frame);
  assert.deepEqual(forwarded,originals,'Meet must receive every original frame unchanged');
  assert.deepEqual(audio.map(f=>f.speaker),['Taylor','Unknown']);
  assert.deepEqual(audio.map(f=>f.attribution),['meet-activity','unresolved']);
  assert.equal(audio.reduce((n,f)=>n+Buffer.from(f.pcm,'base64').length/4,0),41*320,'Held audio, including the uncertain tail, must not be lost on pause');
  assert.equal(audio[0].startedAt,1000,'Buffering must preserve the original capture time');
  assert.equal(audio[0].mappingHistory[0].confirmedAt,1600);
  assert.equal(audio[0].mappingHistory[0].observedAt,1000);
  assert.equal(audio[0].packetRange.lastObservedAt,1600);
  assert.equal(audio[1].mappingHistory[0].active[0].id,'d');
  assert.equal(audio[1].mappingHistory[0].synchronizationSource,'999');
  assert.equal(peer.connectionState,'connected');assert.equal(track.readyState,'live');
});

test('Meet lifecycle ignores pre/post-call peers, survives transport reconnects, and starts a new occurrence only on rejoin',async()=>{
 const events=[],intervals=[];let joined=false,clock=1000;
 class Peer{connectionState='connected';addEventListener(){}getReceivers(){return [{track:{id:'audio',kind:'audio',readyState:'live'}}];}getSenders(){return [];}}
 class Clock extends Date{static now(){return clock;}}
 const window={RTCPeerConnection:Peer,addEventListener(){},postMessage:m=>events.push(m)};
 const scope=vm.createContext({window,RTCPeerConnection:Peer,location:{hostname:'meet.google.com',origin:'https://meet.google.com'},CallAssistantMeetSpeakers:class{roster(){return [];}},CallAssistantMeetRouter:class{presence(){return joined;}roster(){return [];}},Date:Clock,setInterval:f=>intervals.push(f),setTimeout:()=>1,clearTimeout(){}});
 vm.runInContext(await readFile(new URL('../call-media.js',import.meta.url),'utf8'),scope);
 let peer=new window.RTCPeerConnection();intervals[0]();assert.equal(events.length,0,'Warm-up peers are not calls');
 joined=true;intervals[0]();assert.equal(events.filter(e=>e.event==='start').length,1);assert.equal(events.find(e=>e.event==='start').presenceConfirmed,true);
 peer.connectionState='closed';intervals[0]();assert.equal(events.filter(e=>e.event==='end').length,0,'A transport reconnect while still joined is the same call');
 peer=new window.RTCPeerConnection();intervals[0]();assert.equal(events.filter(e=>e.event==='start').length,1);
 joined=false;intervals[0]();clock+=2100;intervals[0]();assert.equal(events.filter(e=>e.event==='end').length,1);
 clock+=5000;intervals[0]();assert.equal(events.filter(e=>e.event==='start').length,1,'Lingering post-call receivers cannot create a second record');
 joined=true;intervals[0]();assert.equal(events.filter(e=>e.event==='start').length,2,'An actual rejoin is a new call occurrence');
});

// Each fixture has a separate VM and synthetic tracks; no Chrome or meeting data is accessed.
async function decoderFixture(){
 const events=[],listeners={},timers=new Map(),decoders=[],readers=[];let controller,clock=1000,timerID=0;
 const track={id:'remote',kind:'audio',readyState:'live',enabled:true,muted:false,addEventListener(){},stop(){assert.fail('Original track stopped');}};
 class Receiver{track=track;getParameters(){return {codecs:[{payloadType:109,mimeType:'audio/opus'}]};}createEncodedStreams(){return {readable:new ReadableStream({start:c=>controller=c}),writable:{}};}}
 const receiver=new Receiver();
 class Peer{connectionState='connected';addEventListener(){}getReceivers(){return [receiver];}getSenders(){return [];}}
 class Processor{constructor(){this.readable=new ReadableStream({start:c=>readers.push(c)});}}
 const audio=(timestamp,frames=320)=>({timestamp,numberOfFrames:frames,numberOfChannels:1,sampleRate:16000,copyTo:p=>p.fill(.2),close(){}});
 class Decoder{state='configured';decodeQueueSize=0;chunks=[];constructor(callbacks){this.callbacks=callbacks;decoders.push(this);}addEventListener(t,f){this.dequeue=f;}configure(){}decode(chunk){if(this.throwing)throw Error('sync decode failure');this.chunks.push(chunk);}close(){this.state='closed';}output(timestamp,frames){this.callbacks.output(audio(timestamp,frames));}}
 class Clock extends Date{static now(){return clock;}}
 const window={RTCPeerConnection:Peer,addEventListener:(t,f)=>listeners[t]=f,postMessage:m=>events.push(m)};
 const scope=vm.createContext({window,location:{hostname:'meet.google.com',origin:'https://meet.google.com'},RTCPeerConnection:Peer,RTCRtpReceiver:Receiver,MediaStreamTrackProcessor:Processor,AudioData:class{},AudioDecoder:Decoder,EncodedAudioChunk:class{constructor(x){Object.assign(this,x);}},Audio:class{async play(){}pause(){}},MediaStream:class{},ReadableStream,TransformStream,TextDecoder,Uint8Array,Float32Array,ArrayBuffer,atob,btoa,crypto,Date:Clock,performance:{now:()=>clock},setInterval(){},setTimeout:(f,ms)=>{timers.set(++timerID,{f,at:clock+ms});return timerID;},clearTimeout:id=>timers.delete(id)});
 for(const file of ['meet-speakers.js','meet-routing.js','call-media.js'])vm.runInContext(await readFile(new URL('../'+file,import.meta.url),'utf8'),scope);
 listeners.message({source:window,origin:'https://meet.google.com',data:{source:'call-assistant-control',enabled:true}});
 new window.RTCPeerConnection();
 // The control scan creates the tap after the peer exists.
 const control=enabled=>listeners.message({source:window,origin:'https://meet.google.com',data:{source:'call-assistant-control',enabled}});control(true);
 const forwarded=[],streams=receiver.createEncodedStreams(),drain=streams.readable.pipeTo(new WritableStream({write:f=>forwarded.push(f)}));
 const send=async(payload=[1,2])=>{const frame={data:new Uint8Array(payload).buffer,getMetadata:()=>({payloadType:109,contributingSources:[101],rtpTimestamp:clock*48})};controller.enqueue(frame);await new Promise(setImmediate);return frame;};
 return {events,decoders,timers,forwarded,send,scope,control,setClock:n=>clock=n,async native(){readers[0].enqueue(audio(0,64000));await new Promise(setImmediate);},async finish(){controller.close();await drain;control(false);},audioFrames:()=>events.filter(e=>e.event==='audio').map(e=>e.frame)};
}

test('saturation and both decoder exception paths restore native capture, save gap evidence and ignore stale outputs',async()=>{
 for(const failure of ['queue','sync','async','pending']){
  const f=await decoderFixture();const original=await f.send();const decoder=f.decoders[0];decoder.output(0);
  if(failure==='queue'){decoder.decodeQueueSize=50;for(let i=0;i<=100;i++)await f.send();}
  if(failure==='sync'){decoder.throwing=true;await f.send();}
  if(failure==='async')decoder.callbacks.error(Error('async decode failure'));
  if(failure==='pending')for(let i=0;i<=100;i++)await f.send();
  assert.equal(decoder.state,'closed',failure);decoder.output(0); // Late callback must not reselect the failed decoder.
  await f.native();f.setClock(2200);await f.send();const replacement=f.decoders[1];assert.ok(replacement,failure);replacement.output(0);decoder.output(0);await f.finish();
  assert.equal(f.forwarded[0],original);assert.ok(f.audioFrames().some(x=>x.captureMethod==='track-processor'),failure);
  const recovery=f.audioFrames().find(x=>x.captureDiscontinuities?.length);
  assert.ok(recovery,failure);assert.ok(recovery.captureDiscontinuities[0].reason);
  assert.ok(f.events.some(x=>x.event==='warning' && x.message.includes('discontinuity')),failure);
 }
});

test('decoder stall deadline follows oldest outstanding packet and recovers without another encoded packet',async()=>{
 const f=await decoderFixture();await f.send();const decoder=f.decoders[0];decoder.output(0);
 f.setClock(1500);await f.send();f.setClock(1800);await f.send();decoder.output(20000);
 assert.equal([...f.timers.values()][0].at,2800,'Progress must move the deadline to the next outstanding packet');
 f.setClock(2800);[...f.timers.values()][0].f();assert.equal(decoder.state,'closed');
 await f.native();await f.finish();assert.ok(f.audioFrames().some(x=>x.captureMethod==='track-processor' && x.captureDiscontinuities?.[0].reason==='decoder-stalled'));
});

test('microsecond rounding in real decoder timestamps retires packets without false stalls or lost identity',async()=>{
 for(const rounding of [-1,1]){
  const f=await decoderFixture();
  for(let i=0;i<16;i++){
   await f.send();f.decoders[0].output(i===0?0:i*20000+rounding);
  }
  assert.equal(f.timers.size,0,'Completed packets must not retain the stall watchdog');
  await f.finish();
  assert.equal(f.audioFrames().reduce((n,x)=>n+Buffer.from(x.pcm,'base64').length/4,0),16*320);
  assert.ok(f.audioFrames().every(x=>x.mappingHistory.every(e=>e.reason!=='decoder-metadata-miss')));
  assert.equal(f.events.filter(e=>e.event==='warning').length,0);
 }
});

test('variable Opus durations and split outputs retain packet identity until its final output',async()=>{
 const f=await decoderFixture();
 // 10 ms, 40 ms, 60 ms, 2.5 ms and a two-frame 20 ms packet.
 for(const payload of [[0,9],[16,9],[24,9],[128,9],[3,2,9]])await f.send(payload);
 const decoder=f.decoders[0];assert.deepEqual(decoder.chunks.map(c=>c.timestamp),[0,10000,50000,110000,112500]);
 decoder.output(0,160);decoder.output(10000,320);decoder.output(30000,320);decoder.output(50000,960);decoder.output(110000,40);decoder.output(112500,320);
 await f.finish();const frames=f.audioFrames();
 assert.equal(frames.reduce((n,x)=>n+Buffer.from(x.pcm,'base64').length/4,0),2120);
 assert.ok(frames.every(x=>x.mappingHistory.every(e=>!['decoder-metadata-miss','out-of-order-context'].includes(e.reason))));
 assert.equal(f.timers.size,0,'Completed packets must not leave a stall timer');
});

test('mapping transitions are retained with bounded sample offsets and chunks split before evidence overflows',async()=>{
 const source=await readFile(new URL('../call-media.js',import.meta.url),'utf8');
 const point=source.indexOf('    tap.pending=[];');assert.ok(point>0);
 // Expose only the existing capture closure to the fixture, without adding a production test API.
 const exposed=source.slice(0,point)+'    window.consumeEvidence=tap.consume;\n'+source.slice(point);
 const events=[],listeners={};let now=1000;
 class Track{kind='audio';id='t';readyState='live';enabled=true;muted=false;addEventListener(){}}
 const track=new Track();class Peer{connectionState='connected';addEventListener(){}getReceivers(){return [{track}];}getSenders(){return [];}}
 class Context{destination={};createMediaStreamSource(){return {connect(){},disconnect(){}};}createScriptProcessor(){return {connect(){},disconnect(){}};}async resume(){}async close(){}}
 const window={RTCPeerConnection:Peer,addEventListener:(t,f)=>listeners[t]=f,postMessage:m=>events.push(m)};
 vm.runInNewContext(exposed,{window,RTCPeerConnection:Peer,AudioContext:Context,Audio:class{async play(){}pause(){}},MediaStream:class{},location:{origin:'https://fixture'},crypto,Float32Array,Uint8Array,btoa,Date:class extends Date{static now(){return now;}},setInterval(){},setTimeout(){},clearTimeout(){}});
 new window.RTCPeerConnection();const control=enabled=>listeners.message({source:window,origin:'https://fixture',data:{source:'call-assistant-control',enabled}});control(true);
 for(let i=0;i<18;i++){now=1000+i*20;window.consumeEvidence(new Float32Array(320).fill(.2),16000,false,{speaker:'A',attribution:'meet-rtp',sourceEvidence:{version:1,observedAt:now,trackID:'t',contributors:['101'],active:[],protocolError:'',method:'meet-rtp',reason:'transition-'+i}});}
 control(false);const frames=events.filter(e=>e.event==='audio').map(e=>e.frame);
 assert.deepEqual(frames.map(x=>x.mappingHistory.length),[16,2]);assert.equal(frames[0].mappingHistory[15].sampleOffset,4800);assert.equal(frames[1].mappingHistory[0].sampleOffset,0);
 assert.equal(frames.reduce((n,x)=>n+Buffer.from(x.pcm,'base64').length/4,0),18*320);
 control(true);
 const before=events.length;
 for(let i=0;i<8;i++){now=2000+i*20;window.consumeEvidence(new Float32Array(320).fill(.2),16000,false,{speaker:'A',attribution:'meet-rtp',sourceEvidence:{version:1,observedAt:now,trackID:'t',contributors:['101'],active:Array.from({length:32},(_,id)=>({id:String(id),name:'ग'.repeat(100),isSelf:false})),protocolError:'',method:'meet-rtp',reason:'transition-'+i}});}
 control(false);
 const bounded=events.slice(before).filter(e=>e.event==='audio').map(e=>e.frame);
 assert.ok(bounded.length>1,'Flush by UTF-8 size before hitting the native evidence bound');
 assert.ok(bounded.every(f=>Buffer.byteLength(JSON.stringify(f.mappingHistory))<=32000));
 assert.equal(bounded.reduce((n,f)=>n+Buffer.from(f.pcm,'base64').length/4,0),8*320);
});

test('temporary decoder backpressure queues copies and drains every packet without blocking original frames',async()=>{
 const f=await decoderFixture();await f.send();const decoder=f.decoders[0];decoder.output(0);decoder.decodeQueueSize=50;
 const originals=[];for(let i=0;i<20;i++)originals.push(await f.send());
 assert.equal(decoder.chunks.length,1);assert.equal(f.forwarded.length,21,'Meet must not wait for our decoder');
 decoder.decodeQueueSize=0;decoder.dequeue();assert.equal(decoder.chunks.length,21,'All queued copies must be decoded');
 for(const chunk of decoder.chunks.slice(1))decoder.output(chunk.timestamp);
 await f.finish();assert.equal(f.events.filter(x=>x.event==='warning').length,0);
 assert.equal(f.audioFrames().reduce((n,x)=>n+Buffer.from(x.pcm,'base64').length/4,0),21*320);
 assert.ok(originals.every(x=>f.forwarded.includes(x)));
});

test('unexpected decoder timestamps preserve audio as Unknown, while malformed Opus durations fail over explicitly',async()=>{
 const f=await decoderFixture();const original=await f.send();const decoder=f.decoders[0];decoder.output(9999999);
 await f.send([3,0]);await f.native();await f.finish();
 assert.equal(f.forwarded[0],original);assert.equal(f.forwarded.length,2);
 assert.ok(f.audioFrames().some(x=>x.speaker==='Unknown' && x.mappingHistory.some(e=>e.reason==='decoder-metadata-miss')));
 assert.ok(f.audioFrames().some(x=>x.captureDiscontinuities?.some(g=>g.reason==='invalid-opus-duration')));
});

test('audio content bridge stays disabled before consent and honors app pause and revocation',async()=>{
 const state={},controls=[],storageListeners=[],runtimeListeners=[],listeners={},messages=[];
 const window={postMessage:message=>controls.push(message),addEventListener:(type,fn)=>listeners[type]=fn};
 const chrome={storage:{local:{get:(keys,callback)=>callback({...state})},onChanged:{addListener:fn=>storageListeners.push(fn)}},runtime:{onMessage:{addListener:fn=>runtimeListeners.push(fn)},sendMessage:async message=>{messages.push(message);return {};}}};
 const document={getElementById:()=>null,createElement:()=>({style:{}}),body:{append(){}}};
 const context=vm.createContext({window,document,chrome,location:{origin:'https://meet.google.com'},Promise});
 vm.runInContext(await readFile(new URL('../call-media-content.js',import.meta.url),'utf8'),context);
 const update=values=>{Object.assign(state,values);storageListeners[0](Object.fromEntries(Object.entries(values).map(([key,value])=>[key,{newValue:value}])),'local');};
 assert.equal(controls.at(-1).enabled,false);
 update({auto_capture_enabled:true});assert.equal(controls.at(-1).enabled,false);
 listeners.message({source:window,origin:'https://meet.google.com',data:{source:'call-assistant-media',event:'start',presenceConfirmed:true}});
 await new Promise(setImmediate);assert.equal(messages.length,1);
 update({capture_consent_granted:true,desktop_capture_paused:false});assert.equal(controls.at(-1).enabled,true);
 await new Promise(setImmediate);assert.equal(messages.length,2);assert.equal(messages[1].event,'start');
 runtimeListeners[0]({type:'NATIVE_CAPTURE_PAUSE'});assert.equal(controls.at(-1).enabled,false);
 update({capture_consent_granted:true});assert.equal(controls.at(-1).enabled,false);
 runtimeListeners[0]({type:'NATIVE_CAPTURE_RESUME'});assert.equal(controls.at(-1).enabled,true);
 update({capture_consent_granted:false});assert.equal(controls.at(-1).enabled,false);
});
