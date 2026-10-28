import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { JSDOM } from '../canvas/node_modules/jsdom/lib/api.js';
const root = new URL('../',import.meta.url);
const calls = [
  {id:'first',topic:'Meet – Weekly sync with Alex',started_at:100,participants:['Alex'],caption_count:2},
  {id:'second',topic:'Weekly sync with Alex',started_at:300,participants:['Alex'],caption_count:3},
  {id:'third',topic:'Weekly sync with Robin',started_at:200,participants:['Robin'],caption_count:1},
  {id:'fourth',topic:'Untitled',started_at:50,caption_count:0},
  {id:'fifth',started_at:40,caption_count:0}
];
async function fixture(page, automatic=false, records=calls) {
  const dom = new JSDOM(await readFile(new URL(page,root),'utf8'),{url:'https://extension.test/'+page,runScripts:'outside-only'});
  const messages=[];
  dom.window.chrome={runtime:{id:'fixture',getManifest:()=>({version:'test',content_scripts:[{js:automatic?['call-media.js']:['cue-content.js']}]}),sendMessage(message,callback){messages.push(message);const value=message.type==='LIST_CALLS'?records:message.type==='GET_CALL'?{...records.find(call=>call.id===message.id),captions:records.find(call=>call.id===message.id)?.captions || []}:message.type==='GET_SETTING'?{value:true}:message.type==='NATIVE_STATUS'?{connected:false}:{};callback?.(value);return Promise.resolve(value);}},downloads:{download:async options=>{messages.push({type:'DOWNLOAD',...options});return 1;}},tabs:{query:async()=>[]},storage:{local:{get:(key,cb)=>cb({}),set:async()=>{}}}};
  for (const script of dom.window.document.querySelectorAll('script[src]')) dom.window.eval(await readFile(new URL(script.getAttribute('src'),root),'utf8'));
  await new Promise(resolve=>setTimeout(resolve,20));
  return {dom,document:dom.window.document,messages};
}
for(const automatic of [false,true]) test(`settings loads and saves captions; automatic=${automatic}`,async()=>{
  const {dom,document,messages}=await fixture('settings.html',automatic);
  try {
    assert.equal(document.getElementById('manual-controls').hidden,automatic);
    assert.equal(document.getElementById('automatic-controls').hidden,!automatic);
    const toggle=document.getElementById('hide-captions-toggle');assert.equal(toggle.checked,true);
    toggle.checked=false;toggle.dispatchEvent(new dom.window.Event('change'));
    await new Promise(resolve=>setTimeout(resolve,0));
    assert.ok(messages.some(m=>m.type==='SET_SETTING' && m.value===false));
    document.getElementById('native-import').click();
    await new Promise(resolve=>setTimeout(resolve,0));
    assert.ok(messages.some(m=>m.type==='NATIVE_IMPORT'));
  } finally { dom.window.close(); }
});

test('timestamp splitting preserves captions, isolates missing times, and does not mutate originals',async()=>{
  const {dom}=await fixture('popup.html');
  dom.window.eval(await readFile(new URL('call-history.js',root),'utf8'));
  try {
    const record={id:'meeting',captions:[{t:7200002,text:'later'},{t:1,text:'first'},{t:2,text:'second'},{text:'unknown'}]};
    dom.window.record=record;
    const split=dom.window.eval('splitSavedCall(record)');
    assert.equal(split.length,3);
    assert.deepEqual(Array.from(split[0].captions,c=>c.text),['first','second']);
    assert.equal(split[1].captions[0].text,'later');
    assert.equal(split[2].started_at,null);
    assert.equal(split[2].captions[0].text,'unknown');
    assert.equal(split.flatMap(s=>s.captions).length,record.captions.length);
    assert.equal(record.captions[0].text,'later');
    assert.equal(dom.window.eval('splitSavedCall({id:"gap",captions:[{t:1},{t:3600001}]}).length'),2);
    assert.equal(dom.window.eval('splitSavedCall({id:"short",captions:[{t:1},{t:3600000}]}).length'),1);
  } finally {dom.window.close();}
});
