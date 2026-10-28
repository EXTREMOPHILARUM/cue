#!/usr/bin/env node
// Attach only to the chosen Meet page; never initialize a general browser controller.
import { readFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { parseArgs } from 'node:util';
import { pathToFileURL } from 'node:url';

const CALL_RE = /^[a-z]{3}-[a-z]{4}-[a-z]{3}$/;
const DEFAULT_PORT_FILE = join(homedir(), 'Library/Application Support/Google/Chrome/DevToolsActivePort');

export async function browserEndpoint(portFile) {
  const [port, path] = (await readFile(portFile, 'utf8')).trim().split(/\r?\n/);
  if (!/^\d+$/.test(port) || Number(port) < 1 || Number(port) > 65535 ||
      !/^\/devtools\/browser\/[a-zA-Z0-9-]+$/.test(path || '')) {
    throw new Error('Invalid Chrome DevToolsActivePort file');
  }
  return `ws://127.0.0.1:${port}${path}`;
}

export function callFromTarget(target) {
  if (target.type !== 'page') return null;
  if (!URL.canParse(target.url)) return null;
  const url = new URL(target.url);
  const id = url.pathname.replace(/^\/(?:meet\/)?/, '');
  return url.origin === 'https://meet.google.com' && CALL_RE.test(id) ? id : null;
}

export async function connect(endpoint, timeout = 5000) {
  const socket = new WebSocket(endpoint);
  const pending = new Map();
  const detaching = new Set();
  let sequence = 0;
  let failure;
  function fail(error) {
    failure = error;
    for (const request of pending.values()) {
      clearTimeout(request.timer);
      request.reject(error);
    }
    pending.clear();
  }
  socket.addEventListener('message', event => {
    let message;
    try { message = JSON.parse(event.data); }
    catch { fail(new Error('Invalid CDP response')); socket.close(); return; }
    if (message.method === 'Target.detachedFromTarget' && detaching.delete(message.params?.sessionId)) return;
    if (message.method === 'Inspector.targetCrashed' || message.method === 'Inspector.detached' ||
        message.method === 'Target.detachedFromTarget') {
      fail(new Error('Meet target disconnected or crashed. Stop; do not retry during the call.'));
      return;
    }
    const request = pending.get(message.id);
    if (!request) return;
    pending.delete(message.id);
    clearTimeout(request.timer);
    if (message.error) request.reject(new Error(message.error.message));
    else request.resolve(message.result);
  });
  socket.addEventListener('close', () => fail(new Error('CDP connection closed; no reconnect attempted')));
  socket.addEventListener('error', () => fail(new Error('CDP connection failed; no reconnect attempted')));
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => { socket.close(); reject(new Error('CDP connection timed out')); }, timeout);
    socket.addEventListener('open', () => { clearTimeout(timer); resolve(); }, { once: true });
    socket.addEventListener('error', () => { clearTimeout(timer); reject(new Error('Cannot connect to Chrome CDP')); }, { once: true });
  });
  return {
    send(method, params = {}, sessionId) {
      if (failure) return Promise.reject(failure);
      return new Promise((resolve, reject) => {
        if (method === 'Target.detachFromTarget') detaching.add(params.sessionId);
        const id = ++sequence;
        const timer = setTimeout(() => {
          fail(new Error(`CDP timed out: ${method}. Stop; do not retry during the call.`));
          socket.close();
        }, timeout);
        pending.set(id, { resolve, reject, timer });
        socket.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
      });
    },
    close() { socket.close(); }
  };
}

export function expressionFor(action, callId, text) {
  const args = JSON.stringify(callId);
  let operation;
  switch (action) {
    case 'read': operation = `const {rowIndex, ...record} = await api.getCall(${args}); return record;`; break;
    case 'events': operation = 'return api.getUIEvents();'; break;
    case 'render': operation = `return api.render(${JSON.stringify(text)});`; break;
    case 'note': operation = `await api.addNote(${JSON.stringify(text)}, ${args}); return {ok:true};`; break;
    case 'topic': operation = `await api.setTopic(${JSON.stringify(text)}, ${args}); return {ok:true};`; break;
    default: throw new Error('Unknown command');
  }
  return `(async()=>{const api=window.__cue;if(!api || api.currentCallId()!==${args}) throw new Error('Cue bridge missing or call changed');${operation}})()`;
}

export async function run(client, action, callId, text) {
  if (action !== 'list' && !CALL_RE.test(callId || '')) throw new Error('An exact --call meeting code is required');
  const { targetInfos } = await client.send('Target.getTargets');
  const calls = targetInfos.map(target => ({ target, id: callFromTarget(target) })).filter(item => item.id);
  if (action === 'list') return calls.map(({ target, id }) => ({ id, targetId: target.targetId, title: target.title }));
  const matching = calls.filter(item => item.id === callId);
  if (matching.length !== 1) throw new Error('Expected exactly one matching Meet tab; no attachment attempted');
  const { sessionId } = await client.send('Target.attachToTarget', { targetId: matching[0].target.targetId, flatten: true });
  try {
    const result = await client.send('Runtime.evaluate', {
      expression: expressionFor(action, callId, text), awaitPromise: true, returnByValue: true,
      timeout: 3000
    }, sessionId);
    if (result.exceptionDetails) throw new Error(result.exceptionDetails.exception?.description || result.exceptionDetails.text);
    if (!Object.hasOwn(result.result, 'value')) throw new Error('Cue returned no serializable result');
    return result.result.value;
  } finally {
    // Detach this session only. Closing the socket is the fallback if the target has died.
    await client.send('Target.detachFromTarget', { sessionId });
  }
}

async function main() {
  const { values, positionals } = parseArgs({ options: {
    call: { type: 'string' }, text: { type: 'string' }, file: { type: 'string' },
    'port-file': { type: 'string', default: DEFAULT_PORT_FILE }
  }, allowPositionals: true });
  const [action] = positionals;
  if (positionals.length !== 1 || !['list', 'read', 'render', 'note', 'topic', 'events'].includes(action)) {
    throw new Error('Usage: node scripts/call-context.mjs list | read/events --call CODE | render --call CODE --file HTML | note/topic --call CODE --text TEXT');
  }
  if (action !== 'list' && !CALL_RE.test(values.call || '')) throw new Error('An exact --call meeting code is required');
  if (action === 'render' && !values.file) throw new Error('render requires --file');
  if (['note', 'topic'].includes(action) && !values.text?.trim()) throw new Error(`${action} requires --text`);
  const text = action === 'render' ? await readFile(values.file, 'utf8') : values.text;
  const client = await connect(await browserEndpoint(values['port-file']));
  try { console.log(JSON.stringify(await run(client, action, values.call, text))); }
  finally { client.close(); }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch(error => { console.error(error.message); process.exitCode = 1; });
}
