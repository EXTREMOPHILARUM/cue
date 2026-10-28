import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync, readFileSync, existsSync, readdirSync, rmSync, writeFileSync, mkdirSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {execFileSync} from 'node:child_process';
import {bundleExtension} from './bundle-extension.mjs';
import {JSDOM, ResourceLoader, VirtualConsole} from '../canvas/node_modules/jsdom/lib/api.js';

test('bundle contains manifest assets and local script/page dependencies',()=>{
  const folder=mkdtempSync(path.join(tmpdir(),'cue-extension-'));
  try {
    execFileSync(process.execPath,['scripts/bundle-extension.mjs',folder]);
    const manifest=JSON.parse(readFileSync(path.join(folder,'manifest.json')));
    assert.equal(manifest.name,'Cue');
    assert.equal(manifest.action.default_title,'Cue');
    for(const file of ['extension-ui.css','popup.css','settings.css'])assert.ok(existsSync(path.join(folder,file)),file);
    const assets=[manifest.background.service_worker,manifest.action.default_popup,
      ...Object.values(manifest.icons),...manifest.content_scripts.flatMap(item=>item.js),
      ...manifest.web_accessible_resources.flatMap(item=>item.resources)];
    for(const asset of assets)assert.ok(existsSync(path.join(folder,asset)),asset);
    for(const file of readdirSync(folder).filter(name=>/\.(js|html)$/.test(name))) {
      const text=readFileSync(path.join(folder,file),'utf8');
      for(const match of text.matchAll(/['"]([\w-]+\.(?:js|html|css))['"]/g)) {
        assert.ok(existsSync(path.join(folder,match[1])),`${file}: ${match[1]}`);
      }
    }
    assert.ok(existsSync(path.join(folder,'licenses')));
    assert.ok(!existsSync(path.join(folder,'native')));
  } finally { rmSync(folder,{recursive:true,force:true}); }
});

test('repackaging removes obsolete files and a failed staging copy preserves the previous bundle',()=>{
  const root=mkdtempSync(path.join(tmpdir(),'cue-bundle-update-'));
  try {
    const source=path.join(root,'source'),destination=path.join(root,'output');
    mkdirSync(path.join(source,'icons'),{recursive:true});
    mkdirSync(path.join(source,'docs/licenses'),{recursive:true});
    writeFileSync(path.join(source,'manifest.json'),'{}');
    writeFileSync(path.join(source,'obsolete.js'),'old');
    bundleExtension(destination,source);
    rmSync(path.join(source,'obsolete.js'));
    writeFileSync(path.join(source,'current.js'),'new');
    bundleExtension(destination,source);
    assert.ok(!existsSync(path.join(destination,'obsolete.js')));
    assert.equal(readFileSync(path.join(destination,'current.js'),'utf8'),'new');
    rmSync(path.join(source,'docs/licenses'),{recursive:true});
    assert.throws(()=>bundleExtension(destination,source));
    assert.equal(readFileSync(path.join(destination,'current.js'),'utf8'),'new');
    assert.deepEqual(readdirSync(root).sort(),['output','source']);
  } finally {rmSync(root,{recursive:true,force:true});}
});

test('packaged background completes an isolated mocked bridge reconnect and durable intake',()=>{
  const folder=mkdtempSync(path.join(tmpdir(),'cue-packaged-bridge-'));
  try {
    bundleExtension(folder);
    const environment={...process.env,CALL_CONTEXT_EXTENSION_ROOT:folder};
    delete environment.NODE_TEST_CONTEXT;
    const output=execFileSync(process.execPath,['--test','--test-reporter=tap','scripts/native-extension.test.mjs'],{
      env:environment,timeout:15000,
    }).toString();
    assert.match(output,/# pass 1/);
    assert.match(output,/# fail 0/);
  } finally {rmSync(folder,{recursive:true,force:true});}
});

test('packaged popup and settings load their real scripts and show mocked desktop connection',async()=>{
  const folder=mkdtempSync(path.join(tmpdir(),'cue-packaged-pages-'));
  try {
    bundleExtension(folder);
    const manifest=JSON.parse(readFileSync(path.join(folder,'manifest.json')));
    for(const page of [manifest.action.default_popup,'settings.html']) {
      const errors=[];
      class Assets extends ResourceLoader {
        fetch(url) {
          const resource=new URL(url);
          assert.equal(resource.origin,'https://extension.test');
          return Promise.resolve(readFileSync(path.join(folder,resource.pathname)));
        }
      }
      const console=new VirtualConsole();
      console.on('jsdomError',error=>errors.push(error.message));
      const dom=new JSDOM(readFileSync(path.join(folder,page),'utf8'),{
        url:`https://extension.test/${page}`,runScripts:'dangerously',resources:new Assets(),virtualConsole:console,
        beforeParse(window) {
          window.setInterval=()=>0;
          window.chrome={runtime:{id:'fixture',getManifest:()=>manifest,sendMessage(message,callback) {
            const result=message.type==='LIST_CALLS' ? [] : message.type==='NATIVE_STATUS' ? {connected:true,pending:0} : {};
            callback?.(result);return Promise.resolve(result);
          }},tabs:{query:async()=>[]},storage:{local:{get:(key,callback)=>{callback?.({});return Promise.resolve({});},set:async()=>{}}}};
        },
      });
      try {
        await new Promise(resolve=>dom.window.addEventListener('load',resolve,{once:true}));
        await new Promise(resolve=>setImmediate(resolve));
        assert.deepEqual(errors,[],page);
        assert.match(dom.window.document.getElementById('native-status').textContent,/Desktop connected/,page);
      } finally {dom.window.close();}
    }
  } finally {rmSync(folder,{recursive:true,force:true});}
});
