import test from 'node:test';
import assert from 'node:assert/strict';
import { build } from 'esbuild';
import { JSDOM } from 'jsdom';
import { readFile } from 'node:fs/promises';

const bundle = await build({entryPoints:['src/main.jsx'],bundle:true,write:false,platform:'browser',define:{'process.env.NODE_ENV':'"production"'}});
test('OpenUI canvas renders coaching, emits feedback and persists without network access',async () => {
  const dom = new JSDOM('<div id="root"></div>',{runScripts:'dangerously',url:'file:///canvas/index.html'});
  dom.window.ResizeObserver=class {observe() {} disconnect() {}};
  const events=[];
  let expiryTick;
  dom.window.setInterval=callback => { expiryTick=callback; return 1; };
  dom.window.webkit={messageHandlers:{ready:{postMessage: value => events.push(value)},feedback:{postMessage:value => events.push(value)}}};
  dom.window.eval(bundle.outputFiles[0].text);
  const wait = async condition => { for(let i=0;i<100;i++){if(condition()) return; await new Promise(r=>setTimeout(r,20));} assert.fail('Canvas did not settle'); };
  await wait(() => dom.window.callAssistant);
  assert.equal(dom.window.document.querySelector('.brand strong').textContent,'Cue');
  assert.match(dom.window.callAssistant.prompt,/Coach/);
  dom.window.document.querySelector('[aria-label="Collapse coaching panel"]').click();
  assert.equal(events.at(-1).action,'collapse');
  dom.window.document.querySelector('[aria-label="Hide coaching panel"]').click();
  assert.equal(events.at(-1).action,'hide');
  dom.window.callAssistant.update({id:'one',program:'root = Canvas(Coach("Clarify the outcome", "What would success look like?", ["Listen first."], "Evidence from this call"), [Checklist("Next steps", ["Confirm pilot"])])',fallback:'Fallback',expiresAt:Date.now()+5000});
  await wait(() => dom.window.document.body.textContent.includes('What would success'));
  assert.match(dom.window.document.body.textContent,/Listen first/);
  assert.equal(dom.window.document.querySelectorAll('h1').length,1);
  assert.equal(dom.window.document.querySelector('.question-label').textContent,'Suggested response');
  assert.equal(dom.window.document.querySelector('.points h2').textContent,'Keep in mind');
  [...dom.window.document.querySelectorAll('button')].find(b=>b.textContent==='Covered').click();
  assert.equal(events.at(-1).action,'asked');
  assert.equal(events.at(-1).coachingID,'one');
  const checkbox=dom.window.document.querySelector('input[type=checkbox]');
  assert.ok(checkbox); checkbox.click(); assert.equal(events.at(-1).action,'check');
  dom.window.callAssistant.update({id:'invalid',program:'root = Forbidden("bad")',fallback:'Readable fallback',expiresAt:Date.now()+5000});
  await wait(() => dom.window.document.body.textContent.includes('Readable fallback'));
  dom.window.callAssistant.update({id:'two',program:'root = Canvas(Coach("Persistent suggestion", "", [], ""), [])',expiresAt:Date.now()-1});
  await wait(() => dom.window.document.body.textContent.includes('Persistent suggestion'));
  expiryTick?.();
  await new Promise(resolve=>setTimeout(resolve,20));
  assert.match(dom.window.document.body.textContent,/Persistent suggestion/);
  dom.window.callAssistant.update(null);
  await wait(() => dom.window.document.body.textContent.includes('Ready when you are'));
  const html = await readFile('src/index.html','utf8');
  assert.match(html,/connect-src 'none'/);
  assert.match(html,/frame-src 'none'/);
  dom.window.close();
});

test('coaching text and action colors meet contrast in both themes',async () => {
  const css=await readFile('src/canvas.css','utf8');
  const palettes=[...css.matchAll(/:root\s*\{([^}]+)\}/g)].map(match => Object.fromEntries(
    [...match[1].matchAll(/--([\w-]+):\s*(#[\da-f]{6})/g)].map(value => [value[1],value[2]])
  ));
  assert.equal(palettes.length,2);
  const luminance=hex => {
    const rgb=hex.slice(1).match(/../g).map(value => parseInt(value,16)/255)
      .map(value => value<=0.04045 ? value/12.92:((value+0.055)/1.055)**2.4);
    return rgb[0]*0.2126+rgb[1]*0.7152+rgb[2]*0.0722;
  };
  for(const palette of palettes) {
    for(const [foreground,background] of [['text','surface'],['secondary','surface'],['text','button'],['text','hover'],['on-accent','accent']]) {
      const values=[luminance(palette[foreground]),luminance(palette[background])];
      assert.ok((Math.max(...values)+0.05)/(Math.min(...values)+0.05)>=4.5,`${foreground} on ${background}`);
    }
  }
});

test('coaching keeps bounded read-only history, preserves feedback ownership, and clears on another call',async()=>{
  const dom=new JSDOM('<div id="root"></div>',{runScripts:'dangerously',url:'file:///canvas/index.html'});
  dom.window.ResizeObserver=class{observe(){}disconnect(){}};
  const events=[];dom.window.webkit={messageHandlers:{ready:{postMessage(){}},feedback:{postMessage:value=>events.push(value)}}};
  dom.window.eval(bundle.outputFiles[0].text);
  const wait=async test=>{for(let i=0;i<100;i++){if(test())return;await new Promise(resolve=>setTimeout(resolve,10));}assert.fail('History did not settle');};
  await wait(()=>dom.window.callAssistant);
  const update=(id,session='call-a')=>dom.window.callAssistant.update({id,session,headline:id,fallback:'Useful response '+id,points:['Concrete next step'],program:`root = Canvas(Coach("${id}", "Useful response ${id}", [], ""), [])`},session);
  update('first');await wait(()=>dom.window.document.querySelector('.coach h1')?.textContent==='first');
  update('second');await wait(()=>dom.window.document.querySelector('.coaching-history'));
  assert.match(dom.window.document.querySelector('.coaching-history').textContent,/Useful response first/);
  assert.equal(dom.window.document.querySelectorAll('.coaching-history button').length,0);
  dom.window.document.querySelector('.coach button').click();assert.equal(events.at(-1).coachingID,'second');
  dom.window.callAssistant.update(null,'call-a');await wait(()=>dom.window.document.querySelectorAll('.coaching-history article').length===2);
  update('another','call-b');await wait(()=>dom.window.document.querySelector('.coach h1')?.textContent==='another');
  assert.equal(dom.window.document.querySelector('.coaching-history'),null);
  for(let i=0;i<15;i++){update('item-'+i,'call-b');await wait(()=>dom.window.document.querySelector('.coach h1')?.textContent==='item-'+i);}
  assert.equal(dom.window.document.querySelectorAll('.coaching-history article').length,12);
  dom.window.close();
});
