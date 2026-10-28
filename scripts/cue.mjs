#!/usr/bin/env node
import { readFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';

export async function connect({ port = 17373, timeout = 5000 } = {}) {
  if (!Number.isInteger(port) || port < 1024 || port > 65535) throw new Error('Invalid loopback port');
  const socket = new WebSocket(`ws://127.0.0.1:${port}`);
  const pending = new Map();
  let sequence = 0;
  let opened = false;
  function fail(error) { for (const entry of pending.values()) { clearTimeout(entry.timer); entry.reject(error); } pending.clear(); }
  socket.addEventListener('close', () => fail(new Error('Local app disconnected')));
  socket.addEventListener('error', () => fail(new Error('Local app connection failed')));
  socket.addEventListener('message', event => {
    let message;
    try { message = JSON.parse(event.data); } catch { fail(new Error('Invalid response from local app')); socket.close(); return; }
    const entry = pending.get(message.id);
    if (!entry) return;
    clearTimeout(entry.timer); pending.delete(message.id);
    if (message.ok) entry.resolve(message.result); else entry.reject(new Error(message.error || 'Request failed'));
  });
  await new Promise((resolve,reject) => {
    const timer = setTimeout(() => { socket.close(); reject(new Error('Local app connection timed out')); },timeout);
    socket.addEventListener('open', () => { opened = true; clearTimeout(timer); resolve(); },{once:true});
    socket.addEventListener('error', () => { clearTimeout(timer); reject(new Error('Start Cue before using the CLI')); },{once:true});
    socket.addEventListener('close', () => { if (!opened) { clearTimeout(timer); reject(new Error('Local app rejected connection')); } },{once:true});
  });
  function request(method, args = {}) {
    return new Promise((resolve,reject) => {
      const id = String(++sequence);
      const timer = setTimeout(() => { pending.delete(id); reject(new Error('Request timed out; no retry performed')); socket.close(); },timeout);
      pending.set(id,{ resolve,reject,timer });
      socket.send(JSON.stringify({ ...args, id, method }));
    });
  }
  try { await request('hello',{ role:'assistant' }); } catch (error) { socket.close(); throw error; }
  return { request, close: () => socket.close() };
}
export async function main(args) {
  const [method,...rest] = args;
  const options = {};
  for (let i=0;i<rest.length;i+=2) {
    if (!['--session','--after','--file','--text','--confirm'].includes(rest[i]) || rest[i+1] === undefined) throw new Error('Unknown or incomplete option');
    options[rest[i].slice(2)] = rest[i+1];
  }
  if (!['status','list','prompt','read','events','coach','note','import','export','delete'].includes(method)) throw new Error('Usage: cue.mjs status|list|prompt|read|events|coach|note|import|export|delete [--session ID] [--after CURSOR] [--file FILE] [--text TEXT]');
  if (['read','events','coach','note','import','export','delete'].includes(method) && !options.session) throw new Error('--session is required');
  if (method === 'delete' && options.confirm !== options.session) throw new Error('Deletion requires --confirm with the exact session ID');
  const payload = { session:options.session };
  if (options.after !== undefined) { payload.after = Number(options.after); if (!Number.isSafeInteger(payload.after) || payload.after < 0) throw new Error('Invalid cursor'); }
  if (method === 'note') { if (!options.text) throw new Error('--text is required'); payload.text = options.text; }
  if (method === 'coach') {
    if (!options.file) throw new Error('--file is required (JSON with program and fallback)');
    const data = JSON.parse(await readFile(options.file,'utf8'));
    if (typeof data.program !== 'string' || typeof data.fallback !== 'string') throw new Error('Coaching JSON needs program and fallback strings');
    Object.assign(payload,{ program:data.program, fallback:data.fallback });
  }
  if (method === 'import') { if (!options.file) throw new Error('--file is required'); payload.record = JSON.parse(await readFile(options.file,'utf8')); }
  const client = await connect();
  try { console.log(JSON.stringify(await client.request(method,payload),null,2)); } finally { client.close(); }
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) main(process.argv.slice(2)).catch(error => { console.error(error.message); process.exitCode = 1; });
