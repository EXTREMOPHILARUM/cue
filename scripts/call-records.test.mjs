import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import {readFile} from 'node:fs/promises';
import {IDBFactory} from '../canvas/node_modules/fake-indexeddb/build/esm/index.js';
async function setup(original={id:'abc-defg-hij',topic:'Weekly sync',captions:[{t:1000,text:'First',speaker:'Sam'},{t:86401000,text:'Next',speaker:'Sam'}],notes:[]},saved) {
  const listeners=[];let tabRemoved;
  const storage=saved?structuredClone(saved.storage):{call_index:[original.id],['call:'+original.id]:structuredClone(original)},session=structuredClone(saved?.session || {});
  const files={};for(const name of ['background.js','native-background.js','browser-outbox.js','call-history.js'])files[name]=await readFile(new URL('../'+name,import.meta.url),'utf8');
  const context=vm.createContext({crypto,TextEncoder,indexedDB:new IDBFactory(),console,URL,WebSocket:{OPEN:1},setInterval,clearInterval,setTimeout:()=>0,clearTimeout,chrome:{runtime:{id:'fixture',onMessage:{addListener:listener=>listeners.push(listener)},getURL:path=>'chrome-extension://fixture/'+path},storage:{local:{get:async key=>typeof key==='string'?{[key]:structuredClone(storage[key])}:structuredClone(storage),set:async values=>Object.assign(storage,structuredClone(values))},session:{get:async key=>({[key]:session[key]}),set:async values=>Object.assign(session,structuredClone(values))},onChanged:{addListener(){}}},tabs:{onRemoved:{addListener:listener=>tabRemoved=listener}},alarms:{create(){},onAlarm:{addListener(){}}}}});
  context.importScripts=(...names)=>names.forEach(name=>vm.runInContext(files[name],context));
  vm.runInContext(files['background.js'],context);
  vm.runInContext('nativeFlush=async()=>{};nativeState=async()=>{};',context);
  const send=(message,sender)=>new Promise(resolve=>{for(const listener of listeners)if(listener(message,sender,resolve))return;resolve({ignored:true});});
  return {context,storage,session,send,removeTab:id=>tabRemoved(id)};
}
test('historical migration creates permanent records once; each new call gets a different ID on the same link',async()=>{
  const original={id:'abc-defg-hij',topic:'Weekly sync',captions:[{t:1000,text:'First',speaker:'Sam'},{t:86401000,text:'Next',speaker:'Sam'}],notes:[]};
  const {context,storage}=await setup(original);
  await vm.runInContext('migrateHistoricalCalls()',context);
  assert.equal(storage.call_index.length,2);
  assert.ok(storage.call_index.every(id=>id.startsWith('call-') && !id.includes('~')));
  assert.equal(storage['call:'+original.id].source_backup,true);
  assert.deepEqual(storage['call:'+original.id].captions,original.captions);
  assert.equal(storage.call_index.reduce((count,id)=>count+storage['call:'+id].captions.length,0),2);
  const stable=storage.call_index.slice();await vm.runInContext('migrateHistoricalCalls()',context);assert.deepEqual(storage.call_index,stable);
  context.sender={id:'fixture',url:'https://meet.google.com/abc-defg-hij',tab:{id:5,url:'https://meet.google.com/abc-defg-hij',title:'Weekly sync'},frameId:0,documentId:'document-a',documentLifecycle:'active'};
  const [first,duplicate]=await Promise.all([vm.runInContext('nativeEnsureBrowserCall(sender)',context),vm.runInContext('nativeEnsureBrowserCall(sender)',context)]);
  assert.equal(first.id,duplicate.id,'Concurrent audio and caption start must share one call');
  await context.updateMeta(first.id,{ended_at:Date.now()});
  await context.updateMeta(first.id,{title:'Wrong next meeting',participants:['Someone else']});
  assert.equal(storage['call:'+first.id].title,'Weekly sync','Ended calls reject late title updates');
  assert.deepEqual(storage['call:'+first.id].participants,[],'Ended calls reject late participant updates');
  const second=await vm.runInContext('nativeEnsureBrowserCall(sender)',context);
  assert.notEqual(first.id,second.id);
  assert.equal(first.series_id,second.series_id);
  assert.equal(first.independent_call,true);assert.equal(second.independent_call,true);
  assert.equal(storage.call_index.length,4);
  context.sender={...context.sender,tab:{id:6,url:'https://meet.google.com/meet/abc-defg-hij?authuser=6',title:'Meet – abc-defg-hij'}};
  const recurring=await vm.runInContext('nativeEnsureBrowserCall(sender)',context);
  assert.equal(recurring.meeting_code,'abc-defg-hij');assert.equal(recurring.series_id,first.series_id);
  assert.equal(recurring.title,'Weekly sync');assert.equal(recurring.source,'meet');
  assert.notEqual(recurring.id,first.id);
  assert.equal(await vm.runInContext('contentCallID("abc-defg-hij",sender)',context),recurring.id);
  await context.updateMeta(recurring.id,{title:'Meet – abc-defg-hij'});
  assert.equal(storage['call:'+recurring.id].title,'Weekly sync','A generic page title cannot erase the recurring title');
  context.sender={...context.sender,url:'https://meet.google.com/xyz-abcd-efg',documentId:'document-b',tab:{...context.sender.tab,url:'https://meet.google.com/xyz-abcd-efg',title:'Different meeting'}};
  assert.equal(await vm.runInContext('contentCallID("xyz-abcd-efg",sender)',context),null,'A reused tab cannot route metadata to another meeting');
  const different=await vm.runInContext('nativeEnsureBrowserCall(sender)',context);
  assert.notEqual(different.id,recurring.id,'A different meeting starts a separate call even before the previous end arrives');
  assert.equal(different.meeting_code,'xyz-abcd-efg');
  for(const url of ['https://evil.test/abc-defg-hij','https://meet.google.com/abc-defg-hij-suffix','http://meet.google.com/abc-defg-hij']) {
    context.invalidURL=url;assert.equal(vm.runInContext('meetCodeFromURL(invalidURL)',context),null);
  }
});

test('concurrent end, title, caption and note mutations retain closure and data; failures do not poison the queue',async()=>{
  const {context,storage}=await setup();
  await context.ensureCall('fixture',{title:'Original'});
  await Promise.all([
    context.updateMeta('fixture',{ended_at:123}),
    context.updateMeta('fixture',{title:'Next meeting',participants:['Wrong person']}),
    context.upsertCaptions('fixture',[{rowId:'row',speaker:'Fixture',text:'Final caption',t:1}]),
    context.addNote('fixture','Keep this note')
  ]);
  const record=storage['call:fixture'];
  assert.equal(record.ended_at,123);
  assert.equal(record.title,'Original');
  assert.deepEqual(record.participants,[]);
  assert.equal(record.captions[0].text,'Final caption');
  assert.equal(record.notes[0].text,'Keep this note');
  const set=context.chrome.storage.local.set;
  context.chrome.storage.local.set=async()=>{throw new Error('Storage failure');};
  await assert.rejects(context.setTopic('fixture','Must fail'),/Storage failure/);
  context.chrome.storage.local.set=set;
  await context.setTopic('fixture','Recovered');
  assert.equal(storage['call:fixture'].topic,'Recovered');
  await Promise.all(['parallel-a','parallel-b'].map(id=>context.ensureCall(id,{})));
  assert.ok(storage.call_index.includes('parallel-a') && storage.call_index.includes('parallel-b'));
});

const browserSender=(code,documentId)=>({id:'fixture',url:'https://meet.google.com/'+code,tab:{id:10,url:'https://meet.google.com/'+code,title:'Fixture '+code},frameId:0,documentId,documentLifecycle:'active'});
const event=(kind,extra={})=>({type:'NATIVE_CALL_EVENT',event:kind,...extra});
test('navigation closes the old call and rejects delayed native events and legacy metadata, including after worker restart',async()=>{
  const fixture=await setup();
  const {context,storage,send}=fixture;
  const a=browserSender('abc-defg-hij','document-a'),b=browserSender('xyz-abcd-efg','document-b');
  const first=await send(event('start',{presenceConfirmed:true}),a);
  const second=await send(event('start',{presenceConfirmed:true}),b);
  assert.ok(storage['call:'+first.id].ended_at,'The displaced occurrence must close');
  assert.ok(!storage['call:'+second.id].ended_at);
  const before=structuredClone(storage);
  for(const kind of ['start','end','participants','audio']) {
    const message=event(kind,{participants:[{id:'wrong',name:'Wrong',isSelf:false}],frame:{id:'stale',source:'remote',pcm:'AAAA'}});
    assert.equal((await send(message,a)).ignored,true,kind+' from a retired document');
    assert.equal((await send(message,{...a,tab:b.tab})).ignored,true,kind+' with a mismatched current tab URL');
  }
  for(const message of [
    {type:'UPDATE_META',id:'abc-defg-hij',meta:{title:'Wrong',ended_at:999}},
    {type:'UPSERT_CAPTIONS',id:'abc-defg-hij',captions:[{rowId:'bad',text:'Wrong',speaker:'Wrong'}]},
    {type:'ENSURE_CALL',id:'abc-defg-hij',meta:{title:'Wrong'}},
    {type:'UPDATE_META',id:second.id,meta:{title:'Wrong'}}
  ])await send(message,{...a,tab:b.tab});
  assert.equal(await send({type:'GET_CALL',id:'abc-defg-hij'},{...a,tab:b.tab}),null);
  assert.deepEqual(storage,before,'Stale documents cannot alter either occurrence or a legacy placeholder');
  const restarted=await setup(undefined,fixture);
  assert.equal((await restarted.send(event('start'),a)).ignored,true,'Retired document protection survives a worker restart');
  await restarted.send(event('participants',{participants:[{id:'current',name:'Current',isSelf:false}]}),b);
  assert.equal(restarted.storage['call:'+second.id].participants[0],'Current','The current document remains usable after restart');
  const queued=await vm.runInContext('outbox.list()',context);
  assert.equal(queued.find(entry=>entry.payload.args.session==='chrome-'+first.id).payload.args.record.ended_at,storage['call:'+first.id].ended_at,'Closure is queued for native import');
});
test('a new document on the same link gets a new occurrence; simultaneous starts cannot share another document record',async()=>{
  const {context,storage,send}=await setup();
  const a=browserSender('abc-defg-hij','document-a'),b=browserSender('abc-defg-hij','document-b');
  const [first,second]=await Promise.all([send(event('start'),a),send(event('start'),b)]);
  assert.notEqual(first.id,second.id);
  assert.ok(storage['call:'+first.id].ended_at);
  assert.ok(!storage['call:'+second.id].ended_at);
  assert.equal((await send(event('end'),a)).ignored,true);
  assert.ok(!storage['call:'+second.id].ended_at);
  assert.equal(await context.contentCallID('abc-defg-hij',a,true),null);
  assert.equal(await context.contentCallID('abc-defg-hij',b,true),second.id);
  assert.equal((await send(event('start'),{...b,documentId:undefined})).ignored,true);
  assert.equal((await send(event('start'),{...b,documentLifecycle:'cached'})).ignored,true);
});

test('native events, history repair and legacy mutations serialize together; tab close clears document ownership',async()=>{
  const {context,storage,session,send,removeTab}=await setup();
  const sender=browserSender('abc-defg-hij','document-a');
  const started=await send(event('start'),sender);
  await Promise.all([
    send(event('participants',{participants:[{id:'current',name:'Current',isSelf:false}]}),sender),
    send({type:'UPDATE_META',id:'abc-defg-hij',meta:{participants:['Caption name']}},sender),
    context.nativeSyncHistory()
  ]);
  assert.deepEqual(new Set(storage['call:'+started.id].participants),new Set(['Caption name','Current']));
  await Promise.all([
    send(event('end'),sender),
    send({type:'UPDATE_META',id:'abc-defg-hij',meta:{title:'Wrong late title'}},sender),
    context.nativeSyncHistory(),
    context.normalizeAllCalls()
  ]);
  assert.ok(storage['call:'+started.id].ended_at);
  assert.equal(storage['call:'+started.id].title,sender.tab.title);
  const next=await send(event('start'),{...sender,documentId:'document-b'});
  await removeTab(sender.tab.id);
  assert.ok(storage['call:'+next.id].ended_at);
  assert.deepEqual(session.auto_call_tabs,{});
  assert.deepEqual(session.retired_call_documents,{});
});
