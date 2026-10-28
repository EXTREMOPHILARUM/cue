import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import {readFile} from 'node:fs/promises';
import {deflateSync,gzipSync} from 'node:zlib';
const source=await readFile(new URL('../meet-speakers.js',import.meta.url),'utf8');
function setup(){const scope=vm.createContext({TextDecoder,Uint8Array,ArrayBuffer,Blob,DecompressionStream,Response,atob});vm.runInContext(source,scope);return scope;}
const varint=n=>{const out=[];do{out.push((n&127)|(n>127?128:0));n=Math.floor(n/128);}while(n);return out;};
const message=(...parts)=>new Uint8Array(parts.flatMap(part=>[...part]));
const field=(n,value)=>message(varint(n*8+2),varint(value.length),value);
const text=(n,value)=>field(n,new TextEncoder().encode(value));
const user=(id,name,self=false)=>message(text(1,id),text(2,name),self?text(7,'self'):[]);
const output=(id,stream)=>message([16,1],text(4,stream),text(6,id));
const packet=(users,outputs=[])=>field(1,field(2,message(field(13,field(1,message(...users.map(u=>field(2,u))))),field(3,message(...outputs.map(o=>field(2,o)))))));

test('Meet names bind to exact RTP contributors, including changing group-call ownership',async()=>{
 const scope=setup(),rosters=[];const names=new scope.CallAssistantMeetSpeakers(r=>rosters.push(r));
 await names.readCollection(deflateSync(packet([user('self','Morgan',true),user('casey','Casey Rivera'),user('riley','Riley')],[output('casey','101'),output('riley','102')])));
 assert.equal(names.local().speaker,'Morgan');
 assert.equal(names.identity({contributingSources:[101]}).speaker,'Casey Rivera');
 assert.equal(names.identity({contributingSources:[{source:102}]}).speaker,'Riley');
 assert.equal(names.identity({contributingSources:[101,102]}).attribution,'mixed');
 assert.equal(names.identity({contributingSources:[999]}).speaker,'Unknown');
 assert.equal(names.identity({contributingSources:[42]}).speaker,'Unknown');
 names.update({deviceOutputs:[{deviceId:'casey',streamId:'111',outputType:1},{deviceId:'riley',streamId:'101',outputType:1}]});
 assert.equal(names.identity({contributingSources:[101]}).speaker,'Riley','Recycled sources must not retain the previous participant');
 assert.equal(names.identity({contributingSources:[102]}).speaker,'Unknown');
 assert.equal(names.identity({contributingSources:[111]}).speaker,'Casey Rivera');
 names.update({deviceOutputs:[{deviceId:'casey',streamId:'111',outputType:1,disabled:true}]});
 assert.equal(names.identity({contributingSources:[111]}).speaker,'Unknown');assert.equal(rosters.at(-1).length,3);
});

test('collection listener preserves channel behavior and ordered decoding survives malformed packets',async()=>{
 const scope=setup(),warnings=[],names=new scope.CallAssistantMeetSpeakers(()=>{},x=>warnings.push(x));
 const handlers=[];const original=()=>{};const channel={label:'collections',binaryType:'blob',onmessage:original,addEventListener:(type,fn)=>handlers.push(fn)};
 names.observe(channel);names.observe(channel);assert.equal(handlers.length,1);assert.equal(channel.binaryType,'blob');assert.equal(channel.onmessage,original);
 await names.readCollection(new Uint8Array([0,1,2]));assert.equal(warnings.length,1);
 await Promise.all([names.readCollection(deflateSync(packet([user('a','Old name')]))),names.readCollection(deflateSync(packet([user('a','Updated name')],[output('a','101')])))]);
 assert.equal(names.identity({contributingSources:[101]}).speaker,'Updated name');
 await assert.rejects(scope.KualiMeetProtocol.decodeCollectionPacket(new Uint8Array(2*1024*1024+1)),/limit/);
 await assert.rejects(scope.KualiMeetProtocol.decodeCollectionPacket(deflateSync(new Uint8Array(8*1024*1024+1))),/limit/);
});

test('bootstrap names are read from a response copy without consuming Meet response data',async()=>{
 const scope=setup(),names=new scope.CallAssistantMeetSpeakers();
 const encoded=Buffer.from(field(2,field(2,field(2,user('self','Morgan',true))))).toString('base64');
 const response=new Response(encoded);Object.defineProperty(response,'url',{value:'https://meet.google.com/$rpc/google.rtc.meetings.v1.MeetingSpaceService/SyncMeetingSpaceCollections'});
 names.observeFetch(response);
 for(let i=0;i<50 && !names.roster().length;i++)await new Promise(setImmediate);
 assert.equal(names.local().speaker,'Morgan');assert.equal(response.bodyUsed,false);assert.equal(await response.text(),encoded);
});

test('unchanged collection packets do not resend rosters and Unicode names fit native fields',()=>{
 const scope=setup(),rosters=[],names=new scope.CallAssistantMeetSpeakers(roster=>rosters.push(roster));
 const update={users:[{deviceId:'self',displayName:'😀'.repeat(300),isCurrentUser:true}]};
 names.update(update);names.update(update);names.update({deviceOutputs:[{deviceId:'self',streamId:'101',outputType:1}]});
 assert.equal(rosters.length,1,'Frequent audio-source updates must not enqueue duplicate history snapshots');
 assert.ok(Buffer.byteLength(names.local().speaker)<=500);assert.equal(names.local().speaker,rosters[0][0].name);
});


test('participant packets accept gzip and uncompressed protobuf alongside zlib',async()=>{
 const scope=setup(),warnings=[],names=new scope.CallAssistantMeetSpeakers(()=>{},message=>warnings.push(message));
 const body=packet([user('remote','Jordan')],[output('remote','101')]);
 for(const payload of [gzipSync(body),body,deflateSync(body)]) {
  await names.readCollection(payload);
  assert.equal(names.identity({contributingSources:[101]}).speaker,'Jordan');
 }
 assert.equal(warnings.length,0);
 await assert.rejects(scope.KualiMeetProtocol.decodeCollectionPacket(new Uint8Array([10,20,1])),/Truncated/);
 await assert.rejects(scope.KualiMeetProtocol.decodeCollectionPacket(gzipSync(new Uint8Array(8*1024*1024+1))),/limit/);
 await names.readCollection(new Uint8Array([0,1,2]));
 assert.equal(names.identity({contributingSources:[101]}).speaker,'Unknown','Unusable updates must not leave potentially stale speaker ownership');
 assert.match(warnings[0],/audio capture continues/);
 await names.readCollection(gzipSync(body));
 assert.equal(names.identity({contributingSources:[101]}).speaker,'Jordan','A later valid packet must restore attribution');
});

test('overflow invalidation cannot restore stale source ownership from older queued packets',async()=>{
 const scope=setup(),names=new scope.CallAssistantMeetSpeakers();
 const body=packet([user('remote','Stale owner')],[output('remote','101')]);
 await Promise.all(Array.from({length:33},()=>names.readCollection(body)));
 assert.equal(names.identity({contributingSources:[101]}).speaker,'Unknown');
 assert.ok(names.generation>0);
 await names.readCollection(packet([user('new','New owner')],[output('new','101')]));
 assert.equal(names.identity({contributingSources:[101]}).speaker,'New owner');
});
