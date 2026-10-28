import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import {readFile} from 'node:fs/promises';
import ws from '../canvas/node_modules/ws/index.js';
const {WebSocketServer}=ws;
test('desktop status connects without a call, never captures audio, and reconnects after app restart',async()=>{
  const server=new WebSocketServer({host:'127.0.0.1',port:0});await new Promise(resolve=>server.once('listening',resolve));
  const requests=[],states=[];let online=false,listener;
  server.on('connection',socket=>socket.on('message',data=>{const request=JSON.parse(data);requests.push(request);socket.send(JSON.stringify({id:request.id,ok:true,result:request.method==='status'?{audioReady:true,paused:false}:{protocol:1}}));}));
  class Socket extends WebSocket {constructor(){super(`ws://127.0.0.1:${online?server.address().port:9}`);}}
  const context=vm.createContext({WebSocket:Socket,console,setTimeout,clearTimeout,setInterval,clearInterval,Map,Promise,chrome:{runtime:{id:'fixture',onMessage:{addListener:fn=>listener=fn},sendMessage:async message=>{states.push(message.state);return {saved:true};}}},navigator:{mediaDevices:{getUserMedia(){throw new Error('Status must not start recording');}}}});
  vm.runInContext(await readFile(new URL('../native-offscreen.js',import.meta.url),'utf8'),context);
  const command=command=>new Promise(resolve=>listener({type:'NATIVE_OFFSCREEN',command},{id:'fixture'},resolve));
  try {
    assert.ok((await command('status')).error);
    online=true;
    const statuses=await Promise.all([command('status'),command('status')]);
    assert.ok(statuses.every(s=>s.connected && s.audioReady && !s.capturing));
    assert.equal(requests.filter(r=>r.method==='hello').length,1);
    assert.ok(requests.every(r=>['hello','status'].includes(r.method)));
    assert.ok(requests.every(r=>r.session===undefined));
    for(const client of server.clients)client.close();
    for(let i=0;i<100;i++){if(states.at(-1)?.connected===false)break;await new Promise(resolve=>setTimeout(resolve,10));}
    assert.equal(states.at(-1).connected,false);
    assert.equal((await command('status')).connected,true);
    assert.equal(requests.filter(r=>r.method==='hello').length,2);
  } finally {
    vm.runInContext('clearInterval(keepalive); socket?.close()',context);
    for(const client of server.clients)client.terminate();await new Promise(resolve=>server.close(resolve));
  }
});
