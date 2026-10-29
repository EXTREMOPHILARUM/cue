import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import {readFile} from 'node:fs/promises';
import {pathToFileURL} from 'node:url';
import path from 'node:path';
import {IDBFactory} from '../canvas/node_modules/fake-indexeddb/build/esm/index.js';
import ws from '../canvas/node_modules/ws/index.js';
const {WebSocketServer}=ws;
const root=process.env.CALL_CONTEXT_EXTENSION_ROOT ? pathToFileURL(path.resolve(process.env.CALL_CONTEXT_EXTENSION_ROOT)+path.sep) : new URL('../',import.meta.url);
const wait=async condition=>{for(let i=0;i<150;i++){if(await condition())return;await new Promise(r=>setTimeout(r,20));}assert.fail('Bridge did not settle');};
test('automatic bridge retains offline audio, reconnects without tab selection and ACKs durable intake',async()=>{
  const server=new WebSocketServer({host:'127.0.0.1',port:0});await new Promise(resolve=>server.once('listening',resolve));
  const received=[],sessions=new Set();let online=false,listener;
  server.on('connection',socket=>socket.on('message',data=>{
    const message=JSON.parse(data);received.push(message);
    if(message.method==='snapshot')sessions.add(message.session);
    const valid=message.method!=='ingest-audio' || sessions.has(message.session);
    socket.send(JSON.stringify({id:message.id,ok:valid,result:message.method==='status'?{captureConsentGranted:true,paused:false}:{stored:true},error:'Missing session'}));
  }));
  class Socket extends WebSocket {constructor(){super(`ws://127.0.0.1:${online?server.address().port:9}`);}}
  const records=new Map(),sessionStorage={},localStorage={capture_consent_granted:true};
  const chrome={runtime:{id:'fixture',getURL:x=>`chrome-extension://fixture/${x}`,onMessage:{addListener:fn=>listener=fn}},storage:{local:{get:async key=>typeof key==='string'?{[key]:localStorage[key]}:{...localStorage},set:async value=>Object.assign(localStorage,value)},session:{get:async key=>({[key]:sessionStorage[key]}),set:async data=>Object.assign(sessionStorage,data)},onChanged:{addListener(){}}},action:{setBadgeText:async()=>{},setBadgeBackgroundColor:async()=>{},setTitle:async()=>{}},tabs:{query:async()=>[],onRemoved:{addListener(){}}},alarms:{create(){},onAlarm:{addListener(){}}}};
  const context=vm.createContext({indexedDB:new IDBFactory(),crypto,Date,Promise,WebSocket:Socket,URL,console,chrome,setInterval,clearInterval,setTimeout:(fn,ms)=>ms===500?0:setTimeout(fn,ms),clearTimeout,
    withCallLock:async(key,operation)=>operation(),migrateHistoricalCalls:async()=>{},getIndex:async()=>[...records.keys()],getCall:async id=>records.get(id),putCall:async record=>records.set(record.id,record),ensureCall:async(id,meta)=>{const record={id,...meta,captions:[],notes:[]};records.set(id,record);return record;},updateMeta:async()=>{}});
  context.importScripts=()=>{};
  vm.runInContext(await readFile(new URL('browser-outbox.js',root),'utf8'),context);
  vm.runInContext(await readFile(new URL('call-history.js',root),'utf8'),context);
  vm.runInContext(await readFile(new URL('native-background.js',root),'utf8'),context);
  const sender={id:'fixture',url:'https://meet.google.com/abc-defg-hij',tab:{id:1,url:'https://meet.google.com/abc-defg-hij',title:'Fixture call'},frameId:0,documentId:'document-a',documentLifecycle:'active'};
  const send=(message,origin=sender)=>new Promise(resolve=>listener(message,origin,resolve));
  try {
    const start=await send({type:'NATIVE_CALL_EVENT',event:'start',presenceConfirmed:true});assert.match(start.id,/^call-/);
    await send({type:'NATIVE_CALL_EVENT',event:'participants',participants:[{id:'casey',name:'Casey Rivera',isSelf:false}]});
    const frame={id:'frame-one',source:'remote',participantID:'casey',speaker:'Casey Rivera',attribution:'meet-rtp',contributors:['101'],startedAt:1,sampleRate:16000,pcm:'AAAAAA==',mappingHistory:[{version:1,observedAt:1,contributors:['101'],active:[],method:'meet-rtp',protocol:{rawDeviceID:'casey',participantID:'casey',speaker:'Casey Rivera',disabled:false,isSelf:false}}],packetRange:{firstObservedAt:1,lastObservedAt:1}};
    assert.equal((await send({type:'NATIVE_CALL_EVENT',event:'audio',frame})).saved,true);
    await wait(()=>vm.runInContext('nativeFlushing===null && nativeConnecting===null',context));
    assert.equal(await vm.runInContext('outbox.count()',context),2);
    online=true;
    const result=await send({type:'NATIVE_IMPORT'},{id:'fixture',url:'chrome-extension://fixture/popup.html'});assert.equal(result.synced,true);
    assert.equal(await vm.runInContext('outbox.count()',context),0);
    assert.equal(received.filter(message=>message.method==='ingest-audio').length,1);
    assert.equal(received.find(message=>message.method==='ingest-audio').session,'chrome-'+start.id);
    assert.equal(received.find(message=>message.method==='ingest-audio').frame.participantID,'casey');
    assert.deepEqual(received.find(message=>message.method==='ingest-audio').frame.mappingHistory,frame.mappingHistory,'Mapping evidence must survive offline queueing and ACK-based reconnect');
    assert.equal(received.find(message=>message.method==='snapshot').record.speaker_roster[0].name,'Casey Rivera');
    assert.equal(received.find(message=>message.method==='snapshot').record.presence_confirmed,true);
    assert.equal(received[0].token,undefined,'No pairing code is required');
    assert.match((await send({type:'NATIVE_IMPORT'})).error,/Extension controls/);
  }finally{
    vm.runInContext('nativeSocket?.close(); clearInterval(nativeHeartbeat)',context);
    for(const client of server.clients)client.terminate();await new Promise(resolve=>server.close(resolve));
  }
});
