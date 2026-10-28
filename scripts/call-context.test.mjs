import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { browserEndpoint, callFromTarget, connect, expressionFor, run } from './call-context.mjs';

const call = 'abc-defg-hij';
const target = { type: 'page', url: `https://meet.google.com/${call}?authuser=6`, targetId: 'meet', title: 'Meet' };

test('only exact Meet page URLs are eligible', () => {
  assert.equal(callFromTarget(target), call);
  assert.equal(callFromTarget({ ...target, url: `https://meet.google.com/meet/${call}?authuser=6` }), call);
  for (const url of ['', 'https://meet.google.com.evil.test/abc-defg-hij', 'http://meet.google.com/abc-defg-hij', 'https://meet.google.com/home', 'https://meet.google.com/abc-defg-hij/extra']) {
    assert.equal(callFromTarget({ ...target, url }), null);
  }
  assert.equal(callFromTarget({ ...target, type: 'worker' }), null);
});

test('discovery never attaches; reads touch one pinned target and detach', async () => {
  const sent = [];
  const client = { async send(method, params, sessionId) {
    sent.push({ method, params, sessionId });
    if (method === 'Target.getTargets') return { targetInfos: [target, { ...target, targetId: 'other', url: 'https://example.com/' }] };
    if (method === 'Target.attachToTarget') return { sessionId: 'pinned' };
    if (method === 'Runtime.evaluate') return { result: { value: { id: call } } };
    return {};
  } };
  assert.equal((await run(client, 'list')).length, 1);
  assert.deepEqual(sent.map(x => x.method), ['Target.getTargets']);
  sent.length = 0;
  assert.deepEqual(await run(client, 'read', call), { id: call });
  assert.deepEqual(sent.map(x => x.method), ['Target.getTargets', 'Target.attachToTarget', 'Runtime.evaluate', 'Target.detachFromTarget']);
  assert.equal(sent[1].params.targetId, 'meet');
  assert.equal(sent[2].sessionId, 'pinned');
  assert.equal(sent[2].params.awaitPromise, true);
  assert.equal(sent[2].params.timeout, 3000);
});

test('missing, ambiguous and invalid calls fail before attaching', async () => {
  for (const targets of [[], [target, { ...target, targetId: 'duplicate' }]]) {
    const methods = [];
    const client = { async send(method) { methods.push(method); return { targetInfos: targets }; } };
    await assert.rejects(run(client, 'read', call), /exactly one/);
    assert.deepEqual(methods, ['Target.getTargets']);
  }
  await assert.rejects(run({}, 'read', 'invalid'), /exact --call/);
});

test('page exceptions detach without a recovery or retry', async () => {
  const sent = [];
  const client = { async send(method) {
    sent.push(method);
    if (method === 'Target.getTargets') return { targetInfos: [target] };
    if (method === 'Target.attachToTarget') return { sessionId: 'pinned' };
    if (method === 'Runtime.evaluate') return { exceptionDetails: { text: 'bridge unavailable' } };
    return {};
  } };
  await assert.rejects(run(client, 'read', call), /bridge unavailable/);
  assert.equal(sent.filter(x => x === 'Runtime.evaluate').length, 1);
  assert.equal(sent.at(-1), 'Target.detachFromTarget');
});

test('text stays data and a changed call is rejected inside the page', async () => {
  const saved = [];
  const api = { currentCallId: () => call, addNote: async text => saved.push(text) };
  const malicious = "'); throw new Error('injected'); //";
  const evaluate = expression => Function('window', `return ${expression}`)({ __cue: api });
  await evaluate(expressionFor('note', call, malicious));
  assert.deepEqual(saved, [malicious]);
  api.currentCallId = () => 'xyz-abcd-efg';
  await assert.rejects(evaluate(expressionFor('note', call, 'wrong call')), /call changed/);
  assert.equal(saved.length, 1);
});

test('endpoint discovery accepts only a loopback port and browser path', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'call-context-test-'));
  const path = join(dir, 'DevToolsActivePort');
  try {
    await writeFile(path, '9222\n/devtools/browser/abc-123\n');
    assert.equal(await browserEndpoint(path), 'ws://127.0.0.1:9222/devtools/browser/abc-123');
    for (const value of ['0\n/devtools/browser/x', '99999\n/devtools/browser/x', '9222\n//evil.test/path']) {
      await writeFile(path, value);
      await assert.rejects(browserEndpoint(path), /Invalid/);
    }
  } finally { await rm(dir, { recursive: true }); }
});

test('silent CDP times out once and closes; later requests fail immediately', async () => {
  const OriginalWebSocket = globalThis.WebSocket;
  let socket;
  class SilentSocket extends EventTarget {
    sent = [];
    closed = false;
    constructor() { super(); socket = this; queueMicrotask(() => this.dispatchEvent(new Event('open'))); }
    send(message) { this.sent.push(JSON.parse(message)); }
    close() { this.closed = true; }
  }
  globalThis.WebSocket = SilentSocket;
  try {
    const client = await connect('ws://127.0.0.1:1/test', 20);
    await assert.rejects(client.send('Target.getTargets'), /timed out/);
    assert.equal(socket.closed, true);
    await assert.rejects(client.send('Target.getTargets'), /timed out/);
    assert.equal(socket.sent.length, 1);
  } finally { globalThis.WebSocket = OriginalWebSocket; }
});

test('target crash aborts requests without reattachment', async () => {
  const OriginalWebSocket = globalThis.WebSocket;
  let socket;
  class CrashedSocket extends EventTarget {
    sent = [];
    constructor() { super(); socket = this; queueMicrotask(() => this.dispatchEvent(new Event('open'))); }
    send(message) {
      this.sent.push(JSON.parse(message));
      queueMicrotask(() => this.dispatchEvent(new MessageEvent('message', { data: JSON.stringify({ method: 'Inspector.targetCrashed' }) })));
    }
    close() {}
  }
  globalThis.WebSocket = CrashedSocket;
  try {
    const client = await connect('ws://127.0.0.1:1/test', 100);
    await assert.rejects(client.send('Runtime.evaluate'), /crashed/);
    await assert.rejects(client.send('Target.attachToTarget'), /crashed/);
    assert.equal(socket.sent.length, 1);
    client.close();
  } finally { globalThis.WebSocket = OriginalWebSocket; }
});
