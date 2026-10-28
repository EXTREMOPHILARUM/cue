import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { readFile } from 'node:fs/promises';
import { indexedDB } from '../canvas/node_modules/fake-indexeddb/build/esm/index.js';

test('browser outbox survives restart and deletes only acknowledged versions in bounded batches',async()=>{
  const context=vm.createContext({indexedDB,crypto,Date,Promise});
  vm.runInContext(await readFile(new URL('../browser-outbox.js',import.meta.url),'utf8'),context);
  const queue=vm.runInContext('new BrowserOutbox()',context);
  const old=await queue.put('record:one',{text:'old'});
  await queue.put('record:one',{text:'new'});
  await queue.acknowledge(old);
  assert.equal(await queue.count(),1,'ACK for old snapshot must not remove a new revision');
  for(let i=0;i<25;i++)await queue.put(`audio:${i}`,{pcm:'fixture'});
  const reopened=vm.runInContext('new BrowserOutbox()',context);
  assert.equal(await reopened.count(),26);
  const batch=await reopened.list();assert.equal(batch.length,20,'Do not load an entire offline call into memory');
  for(const entry of batch)await reopened.acknowledge(entry);
  assert.equal(await reopened.count(),6);
});
