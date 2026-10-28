import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { browserEndpoint, connect, expressionFor } from './call-context.mjs';

test('isolated Chromium: async reads, coaching, notes, worker heartbeat and detach', { timeout: 25000 }, async () => {
  const executable = process.env.CALL_CONTEXT_TEST_CHROME;
  assert.ok(executable, 'Set CALL_CONTEXT_TEST_CHROME to a separate test Chromium executable');
  const profile = await mkdtemp(join(tmpdir(), 'call-context-chrome-'));
  const bridge = await readFile(new URL('../bridge.js', import.meta.url), 'utf8');
  const call = 'abc-defg-hij';
  const fixture = `<!doctype html><title>Isolated call fixture</title><script>
    window.ticks=0;setInterval(()=>window.ticks++,10);
    const worker=new Worker(URL.createObjectURL(new Blob(['setInterval(()=>postMessage(1),10)'],{type:'text/javascript'})));
    window.workerTicks=0;worker.onmessage=()=>window.workerTicks++;
    const record={id:'${call}',ended_at:null,participants:['Test'],notes:[],captions:[{t:1,speaker:'Test',text:'Fixture caption'}]};
    addEventListener('message',event=>{
      const m=event.data;if(!m || m.source!=='cue')return;
      let result;
      if(m.type==='GET_CALL')result=record;
      else if(m.type==='ADD_NOTE'){record.notes.push({t:Date.now(),text:m.args.text});result=record;}
      else return;
      setTimeout(()=>postMessage({source:'cue-reply',reqId:m.reqId,result},'*'),5);
    });
  </script><script src='/bridge.js'></script>`;
  const server = createServer((req, res) => {
    res.setHeader('Content-Type', req.url === '/bridge.js' ? 'text/javascript' : 'text/html');
    res.end(req.url === '/bridge.js' ? bridge : fixture);
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const fixtureURL = `http://127.0.0.1:${server.address().port}/${call}`;
  const chrome = spawn(executable, [`--user-data-dir=${profile}`, '--remote-debugging-port=0', '--headless=new', '--no-first-run', '--no-default-browser-check', '--disable-extensions', fixtureURL], { stdio: 'ignore' });
  let launchError;
  chrome.on('error', error => { launchError = error; });
  let client;
  try {
    const portFile = join(profile, 'DevToolsActivePort');
    let endpoint;
    for (let attempt = 0; attempt < 100; attempt++) {
      if (launchError) throw launchError;
      if (chrome.exitCode !== null) throw new Error(`Test Chrome exited: ${chrome.exitCode}`);
      try { endpoint = await browserEndpoint(portFile); break; }
      catch (error) { if (error.code !== 'ENOENT') throw error; }
      await delay(100);
    }
    assert.ok(endpoint, 'Separate test Chrome must expose its own CDP endpoint');
    client = await connect(endpoint);
    const { targetInfos } = await client.send('Target.getTargets');
    const target = targetInfos.find(info => info.url === fixtureURL);
    assert.ok(target, 'Local fixture tab exists');
    let { sessionId } = await client.send('Target.attachToTarget', { targetId: target.targetId, flatten: true });
    async function evaluate(expression) {
      const response = await client.send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true, timeout: 3000 }, sessionId);
      assert.equal(response.exceptionDetails, undefined, JSON.stringify(response.exceptionDetails));
      return response.result.value;
    }
    for (let attempt = 0; attempt < 30; attempt++) {
      if (await evaluate('typeof window.__cue === "object"')) break;
      await delay(50);
    }
    const before = await evaluate('({ticks:window.ticks,workerTicks:window.workerTicks})');
    for (let index = 0; index < 60; index++) {
      await client.send('Target.detachFromTarget', { sessionId });
      client.close();
      client = await connect(endpoint);
      const currentTarget = (await client.send('Target.getTargets')).targetInfos.find(info => info.targetId === target.targetId);
      assert.equal(currentTarget?.url, fixtureURL, 'Pinned test tab has not changed');
      ({ sessionId } = await client.send('Target.attachToTarget', { targetId: target.targetId, flatten: true }));
      const record = await evaluate(expressionFor('read', call));
      assert.equal(record.captions[0].text, 'Fixture caption');
      if (index % 10 === 0) {
        assert.equal((await evaluate(expressionFor('render', call, `<p>Coaching ${index}</p>`))).ok, true);
      }
    }
    await evaluate(expressionFor('note', call, 'Fixture decision'));
    assert.equal((await evaluate(expressionFor('read', call))).notes[0].text, 'Fixture decision');
    const after = await evaluate('({ticks:window.ticks,workerTicks:window.workerTicks,coaching:document.querySelector("#rf-agent").textContent,url:location.href})');
    assert.ok(after.ticks > before.ticks, 'Page stays responsive');
    assert.ok(after.workerTicks > before.workerTicks, 'Worker keeps running');
    assert.equal(after.coaching, 'Coaching 50');
    assert.equal(after.url, fixtureURL);
    await client.send('Target.detachFromTarget', { sessionId });
    assert.ok((await client.send('Target.getTargets')).targetInfos.some(info => info.targetId === target.targetId), 'Detach leaves the tab open');
  } finally {
    client?.close();
    const exited = new Promise(resolve => chrome.once('exit', resolve));
    if (chrome.exitCode === null) { chrome.kill('SIGTERM'); await exited; }
    await new Promise(resolve => server.close(resolve));
    await rm(profile, { recursive: true, force: true });
  }
});
