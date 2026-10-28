import test from 'node:test';
import assert from 'node:assert/strict';
import ws from '../canvas/node_modules/ws/index.js';
const { WebSocketServer } = ws;
import { connect, main } from './call-assistant.mjs';
import {connect as cueConnect, main as cueMain} from './cue.mjs';

test('the legacy CLI preserves the Cue API',()=>{
  assert.equal(connect,cueConnect);
  assert.equal(main,cueMain);
});

test('CLI connects without pairing and passes session/cursor without browser commands',async () => {
  const server=new WebSocketServer({host:'127.0.0.1',port:0});
  await new Promise(resolve=>server.once('listening',resolve));
  const methods=[];
  server.on('connection',socket=>socket.on('message',data=>{
    const message=JSON.parse(data); methods.push(message);
    socket.send(JSON.stringify({id:message.id,ok:true,result:message.method==='read'?{cursor:7,hasMore:false}:{protocol:1}}));
  }));
  let client;
  try {
    client=await connect({port:server.address().port});
    assert.equal((await client.request('read',{session:'exact-session',after:6})).cursor,7);
    assert.equal(methods[0].method,'hello');assert.equal(methods[0].role,'assistant');
    assert.equal(methods[1].session,'exact-session');assert.equal(methods[1].after,6);
    assert.deepEqual(methods.map(x=>x.method),['hello','read']);
  } finally { client?.close(); for(const socket of server.clients) socket.terminate(); await new Promise(resolve=>server.close(resolve)); }
});
test('CLI fails on handshake rejection and requires explicit session/deletion confirmation',async () => {
  const server=new WebSocketServer({host:'127.0.0.1',port:0});
  await new Promise(resolve=>server.once('listening',resolve));
  server.on('connection',socket=>socket.on('message',data=>socket.send(JSON.stringify({id:JSON.parse(data).id,ok:false,error:'Invalid client role'}))));
  try { await assert.rejects(connect({port:server.address().port}),/Invalid client role/); }
  finally { for(const socket of server.clients) socket.terminate(); await new Promise(resolve=>server.close(resolve)); }
  await assert.rejects(main(['delete','--session','one']),/--confirm/);
  await assert.rejects(main(['read']),/--session/);
  await assert.rejects(main(['read','--session','one','--after','-1']),/Invalid cursor/);
});
