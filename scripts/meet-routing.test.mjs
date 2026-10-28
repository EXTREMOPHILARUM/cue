import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import {readFile} from 'node:fs/promises';
const files=await Promise.all(['meet-speakers.js','meet-routing.js'].map(f=>readFile(new URL('../'+f,import.meta.url),'utf8')));
function setup(){const scope=vm.createContext({TextDecoder,Uint8Array,ArrayBuffer,atob});files.forEach(s=>vm.runInContext(s,scope));const names=new scope.CallAssistantMeetSpeakers(),router=new scope.CallAssistantMeetRouter(names);names.update({users:[{deviceId:'self',fullName:'Morgan',isCurrentUser:true},{deviceId:'a',fullName:'Taylor'},{deviceId:'d',fullName:'Jordan'},{deviceId:'share',fullName:'Presentation',parentDeviceId:'a'}]});return {scope,names,router};}
const active=id=>[{id,name:id==='a'?'Taylor':'Jordan',isSelf:false}];
function context(router,t,id='a',contributors=['101'],track='track'){const c=router.context({contributingSources:contributors,synchronizationSource:999,rtpTimestamp:t},track,t,t);c.active=id?active(id):[];return c;}
test('exact protocol ownership, presentation parent and reused CSRCs take effect without track changes',()=>{
 const {names,router}=setup();names.update({deviceOutputs:[{deviceId:'share',streamId:'101',outputType:1}]});
 assert.equal(router.resolve(context(router,1000,'a'),.2).identity.speaker,'Taylor');
 names.update({deviceOutputs:[{deviceId:'d',streamId:'101',outputType:1}]});
 assert.equal(router.resolve(context(router,1020,'d'),.2).identity.speaker,'Jordan');
 assert.equal(router.resolve(context(router,1040,null,['101','102']),.2).identity.attribution,'mixed');
 assert.equal(router.resolve(context(router,1060,'a',[]),.2).identity.speaker,'Unknown');
 assert.equal(router.resolve(context(router,1080,'a',['42']),.2).identity.speaker,'Unknown');
});
test('unknown and stale ownership need sustained exclusive activity with real audio',()=>{
 const {names,router}=setup();names.update({deviceOutputs:[{deviceId:'d',streamId:'101',outputType:1}]});
 let decision;
 for(let i=0;i<=30;i++){decision=router.resolve(context(router,1000+i*20),.2);if(i<30)assert.equal(decision.action,'hold');}
 assert.equal(decision.action,'rebind');assert.equal(decision.identity.speaker,'Taylor');assert.equal(decision.identity.attribution,'meet-activity');
 assert.equal(decision.identity.sourceEvidence.protocol.rawDeviceID,'d');assert.equal(decision.identity.sourceEvidence.vote.samples,31);
 assert.equal(router.resolve(context(router,1620),.2).identity.speaker,'Taylor');
 const ambiguity=context(router,1640);ambiguity.active=[...active('a'),...active('d')];
 assert.equal(router.resolve(ambiguity,.2).identity.speaker,'Unknown','A stale protocol owner must not reappear during ambiguity');
 assert.equal(router.resolve(context(router,3000),0).identity.speaker,'Unknown','Silence cannot establish identity');
 assert.equal(router.resolve(context(router,3100),.2).action,'hold','A lease cannot survive a long gap');
 names.generation++;names.sources.clear();
 assert.equal(router.resolve(context(router,3120,null),.2).identity.speaker,'Unknown');
});
test('one active person cannot claim two simultaneous unknown sources; switches and out-of-order contexts remain uncertain',()=>{
 const {router}=setup();
 for(let i=0;i<=30;i++)router.resolve(context(router,1000+i*20),.2);
 assert.equal(router.resolve(context(router,1620,'a',['102'],'other'),.2).identity.speaker,'Unknown');
 assert.equal(router.resolve(context(router,1620,'d'),.2).action,'hold');
 assert.equal(router.resolve(context(router,1610,'a'),.2).identity.sourceEvidence.reason,'out-of-order-context');
 assert.equal(router.resolve(context(router,1640,null),.2).identity.speaker,'Unknown');
 assert.equal(router.resolve(context(router,1660,'d'),.2).action,'hold');
});
test('DOM roster includes a missing participant, ignores hidden activity and deduplicates screen shares',()=>{
 const {scope,names,router}=setup();
 const tile=(id,name,speaks,visible=true)=>({getAttribute:key=>({'data-participant-id':id,'data-display-name':name}[key] || ''),matches:selector=>selector.includes('data-is-speaking')?speaks:false,querySelector:()=>null,getClientRects:()=>visible?[{}]:[]});
 scope.document={querySelectorAll:()=>[tile('self','Morgan',false),tile('a','Taylor Smith',true),tile('share','Taylor Smith',true),tile('d','Jordan',true,false)]};scope.getComputedStyle=()=>({visibility:'visible',display:'block'});
 const c=router.context({contributingSources:[101]},'track',0,1000);
 assert.equal(c.active.length,1);assert.equal(c.active[0].id,'a');assert.equal(c.active[0].name,'Taylor Smith');
 assert.equal(router.roster(1000).filter(p=>p.id==='a').length,1);assert.equal(router.roster(1000).find(p=>p.id==='self').isSelf,true);
 names.users.delete('a');assert.ok(router.roster(1100).find(p=>p.id==='a'));
});

test('a presentation cannot overwrite its parent name or local identity',()=>{
 const {names,router}=setup();
 names.update({users:[{deviceId:'my-share',fullName:'Presentation',parentDeviceId:'self'}],deviceOutputs:[{deviceId:'my-share',streamId:'101',outputType:1}]});
 const roster=router.roster(1000);assert.equal(roster.find(p=>p.id==='a').name,'Taylor');assert.equal(roster.find(p=>p.id==='self').name,'Morgan');assert.equal(roster.find(p=>p.id==='self').isSelf,true);
 let result;for(let i=0;i<40;i++)result=router.resolve(context(router,1000+i*20,'d'),.2);
 assert.equal(result.identity.speaker,'Unknown');assert.equal(result.identity.sourceEvidence.reason,'self-owned-remote-source');
});

test('a newly arrived protocol owner requires a fresh challenge instead of inheriting an old activity lease',()=>{
 const {names,router}=setup();
 for(let i=0;i<=30;i++)router.resolve(context(router,1000+i*20),.2);
 names.update({deviceOutputs:[{deviceId:'d',streamId:'101',outputType:1}]});
 assert.equal(router.resolve(context(router,1620),.2).action,'hold');
 names.update({deviceOutputs:[{deviceId:'a',streamId:'101',outputType:1}]});
 const result=router.resolve(context(router,1640),.2);
 assert.equal(result.identity.speaker,'Taylor');assert.equal(result.identity.attribution,'meet-rtp');
});

test('duplicate protocol-owned tracks remain valid evidence while an unowned duplicate cannot claim their participant',()=>{
 const {names,router}=setup();names.update({deviceOutputs:[{deviceId:'a',streamId:'101',outputType:1},{deviceId:'share',streamId:'102',outputType:1}]});
 assert.equal(router.resolve(context(router,1000,'a',['101'],'one'),.2).identity.attribution,'meet-rtp');
 assert.equal(router.resolve(context(router,1001,'a',['102'],'two'),.2).identity.attribution,'meet-rtp','A presentation or duplicate transport is not evidence of a different speaker');
 const uncertain=router.resolve(context(router,1002,'a',['103'],'three'),.2);
 assert.equal(uncertain.identity.speaker,'Unknown');assert.equal(uncertain.identity.sourceEvidence.reason,'participant-already-claimed-by-another-source');
});
