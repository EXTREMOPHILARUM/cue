let socket, identity, capture, keepalive, connecting;
let nextID = 0;
const pending = new Map();
let sendingAudio = Promise.resolve();
let sequence = 0;
let nextAudioTime = 0;
let flushingCapture;
async function publish(error = '') {
  await chrome.runtime.sendMessage({type:'NATIVE_STATE',state:{...identity,connected:socket?.readyState === WebSocket.OPEN,capturing:!!capture,error}});
}
function request(method,args = {}) {
  return new Promise((resolve,reject) => {
    if (socket?.readyState !== WebSocket.OPEN) { reject(new Error('Mac app disconnected')); return; }
    const id = String(++nextID);
    const timer = setTimeout(() => { pending.delete(id); reject(new Error('Native app request timed out')); socket?.close(); },5000);
    pending.set(id,{resolve,reject,timer});
    socket.send(JSON.stringify({id,method,session:identity?.session,...args}));
  });
}
async function stopCapture(notify = true) {
  const old = capture;
  capture = null;
  let failure;
  if (old) {
    flushingCapture = old;
    try {
      await new Promise((resolve,reject) => {
        const timer = setTimeout(() => reject(new Error('Audio worklet did not flush')),1000);
        old.flushed = () => { clearTimeout(timer); resolve(); };
        old.node.port.postMessage('flush');
      });
    } catch (error) { failure = error; }
    finally {
      flushingCapture = null;
      old.node.disconnect(); old.playbackSource.disconnect(); old.input.disconnect();
      old.stream.getTracks().forEach(track => track.stop());
      await Promise.all([old.processing.close(),old.playback.close()]);
    }
    await sendingAudio;
    if (notify && socket?.readyState === WebSocket.OPEN) await request('capture-stop');
  }
  await publish();
  if (failure) throw failure;
}
function encodePCM(buffer) {
  const bytes = new Uint8Array(buffer);
  let binary = '';
  for (let offset=0;offset<bytes.length;offset+=8192) binary += String.fromCharCode(...bytes.subarray(offset,offset+8192));
  return btoa(binary);
}
async function startCapture(streamID) {
  if (capture || flushingCapture) throw new Error('Capture is running or still stopping');
  const status = await request('status');
  if (!status.audioReady || status.paused) throw new Error('Load the speech model in the Mac app and unpause first');
  let stream, processing, playback;
  let started = false;
  try {
    stream = await navigator.mediaDevices.getUserMedia({audio:{mandatory:{chromeMediaSource:'tab',chromeMediaSourceId:streamID}},video:false});
    // Preserve Chrome's normal output rate for playback; only the analysis graph is 16 kHz.
    playback = new AudioContext();
    const playbackSource = playback.createMediaStreamSource(stream);
    playbackSource.connect(playback.destination);
    await playback.resume();
    processing = new AudioContext({sampleRate:16000});
    await processing.audioWorklet.addModule(chrome.runtime.getURL('audio-worklet.js'));
    const input = processing.createMediaStreamSource(stream);
    const node = new AudioWorkletNode(processing,'pcm-collector');
    input.connect(node); node.connect(processing.destination);
    sequence = 0; nextAudioTime = Date.now(); sendingAudio = Promise.resolve();
    await request('capture-start'); started = true;
    node.port.onmessage = event => {
      if (event.data?.type === 'flushed') { flushingCapture?.flushed?.(); return; }
      const buffer = event.data;
      const startedAt = nextAudioTime;
      nextAudioTime += buffer.byteLength / 4 / 16;
      const frame = {sequence:sequence++,sampleRate:16000,startedAt,pcm:encodePCM(buffer)};
      if (sequence > 1 && socket?.bufferedAmount > 1024*1024) { void stopCapture(false).finally(() => socket?.close()).then(() => publish('Audio connection is behind; capture stopped'),error => publish(error.message)); return; }
      sendingAudio = sendingAudio.then(() => request('audio',frame)).catch(async error => {
        // Stop immediately; never reconnect or silently skip an audio frame.
        const active = capture; capture = null;
        if (active) { active.stream.getTracks().forEach(track => track.stop()); await Promise.all([active.processing.close(),active.playback.close()]); }
        socket?.close();
        await publish(error.message);
      });
    };
    capture = {stream,processing,playback,input,node,playbackSource};
    stream.getAudioTracks()[0].addEventListener('ended',() => { if (capture) void stopCapture().catch(error => publish(error.message)); },{once:true});
    await processing.resume(); await publish();
  } catch (error) {
    capture = null;
    stream?.getTracks().forEach(track => track.stop());
    if (processing) await processing.close();
    if (playback) await playback.close();
    if (started) await request('capture-stop');
    throw error;
  }
}
async function disconnect() {
  await stopCapture(); clearInterval(keepalive);
  socket?.close(); socket = null; await publish();
}
async function openConnection(message) {
  if (capture || flushingCapture) throw new Error('Stop capture and wait before reconnecting');
  if (socket) await disconnect();
  identity = {session:message.session,callID:message.callID,tabID:message.tabID};
  const ws = new WebSocket('ws://127.0.0.1:17373'); socket = ws;
  ws.onmessage = event => {
    let response;
    try { response = JSON.parse(event.data); } catch { ws.close(); return; }
    if (response.event === 'capture-failed') { void stopCapture(false).finally(() => socket?.close()).catch(error => publish(error.message)); return; }
    if (response.event === 'paused') { void stopCapture().catch(error => publish(error.message)); return; }
    const entry = pending.get(response.id);
    if (!entry) return;
    clearTimeout(entry.timer); pending.delete(response.id);
    response.ok ? entry.resolve(response.result) : entry.reject(new Error(response.error));
  };
  ws.onclose = () => {
    if (socket !== ws) return;
    clearInterval(keepalive);
    for (const entry of pending.values()) { clearTimeout(entry.timer); entry.reject(new Error('Mac app disconnected')); } pending.clear();
    void stopCapture(false).then(() => publish('Mac app disconnected. Reconnect explicitly.'));
  };
  await new Promise((resolve,reject) => {
    const timer = setTimeout(() => { ws.close(); reject(new Error('Mac app connection timed out')); },5000);
    ws.onopen = () => { clearTimeout(timer); resolve(); };
    ws.onerror = () => { clearTimeout(timer); reject(new Error('Start the Mac app, check the extension ID, and try connecting again')); };
  });
  await request('hello',{role:'extension'});
  keepalive = setInterval(() => { void request('status').then(status => { if (!status.paused) return chrome.runtime.sendMessage({type:'NATIVE_REFRESH'}); }).catch(error => publish(error.message)); },20000);
  await publish();
}
async function connect(message = {}) {
  if (connecting) await connecting;
  if (socket?.readyState === WebSocket.OPEN && (!message.session || message.session === identity?.session)) return;
  connecting = openConnection(message);
  try { await connecting; } finally { connecting = null; }
}
chrome.runtime.onMessage.addListener((message,sender,reply) => {
  if (message.type !== 'NATIVE_OFFSCREEN') return false;
  if (sender.id !== chrome.runtime.id || sender.tab) { reply({error:'Extension only'}); return false; }
  (async () => {
    switch (message.command) {
      case 'status': {
        await connect();
        const status = await request('status');
        await publish();
        return {...status,connected:true,capturing:!!capture,session:identity?.session};
      }
      case 'connect': await connect(message); break;
      case 'snapshot': return request('snapshot',{session:message.session || identity?.session,record:message.record});
      case 'start': await startCapture(message.streamID); break;
      case 'stop': await stopCapture(); break;
      case 'disconnect': await disconnect(); break;
      default: throw new Error('Unknown capture command');
    }
    return {ok:true};
  })().then(reply,error => { void publish(error.message); reply({error:error.message}); });
  return true;
});
