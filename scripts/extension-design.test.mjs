import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';

const root=new URL('../',import.meta.url);
test('extension text and action palettes meet contrast in light and dark themes',async()=>{
  const css=await readFile(new URL('extension-ui.css',root),'utf8');
  assert.match(css,/html\s*\{\s*min-width:\s*400px;/);
  assert.match(css,/body\s*\{[^}]*min-width:\s*400px;/);
  assert.doesNotMatch(css,/max-width:\s*100vw/);
  const palettes=[...css.matchAll(/:root\s*\{([^}]+)\}/g)].map(match=>Object.fromEntries(
    [...match[1].matchAll(/--([\w-]+):\s*(#[\da-f]{6})/g)].map(value=>[value[1],value[2]])
  ));
  assert.equal(palettes.length,2);
  const luminance=hex=>{
    const rgb=hex.slice(1).match(/../g).map(value=>parseInt(value,16)/255)
      .map(value=>value<=0.04045 ? value/12.92:((value+0.055)/1.055)**2.4);
    return rgb[0]*.2126+rgb[1]*.7152+rgb[2]*.0722;
  };
  for(const palette of palettes) {
    for(const [foreground,background] of [['text','bg'],['text','surface'],['muted','bg'],['muted','surface'],['on-accent','accent'],['warning','warning-bg'],['success','success-bg'],['danger','surface']]) {
      const values=[luminance(palette[foreground]),luminance(palette[background])];
      assert.ok((Math.max(...values)+.05)/(Math.min(...values)+.05)>=4.5,`${foreground} on ${background}`);
    }
  }
});
test('popup and settings share Cue styles and named icon controls',async()=>{
  for(const name of ['popup.html','settings.html']) {
    const html=await readFile(new URL(name,root),'utf8');
    assert.match(html,/href="extension-ui.css"/);
    assert.match(html,/<h1>/);
    assert.match(html,/aria-label="(?:Settings|Back to Cue)"/);
    assert.doesNotMatch(html,/<style>/);
  }
});

test('capture companion removes library actions and avoids viewport-dependent popup sizing',async()=>{
  const html=await readFile(new URL('popup.html',root),'utf8');
  const js=await readFile(new URL('popup.js',root),'utf8');
  assert.doesNotMatch(html,/id="(?:calls|copy-prompt|call-search|transcript-dialog|row-menu)"/);
  assert.doesNotMatch(js,/LIST_CALLS|DELETE_CALL|SET_TOPIC|clipboard/);
  for(const name of ['popup.css','settings.css']) {
    const css=await readFile(new URL(name,root),'utf8');
    assert.doesNotMatch(css,/100dvh/);
  }
  assert.match(await readFile(new URL('settings.css',root),'utf8'),/height: 600px/);
});
