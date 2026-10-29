importScripts('browser-outbox.js','call-history.js');
const nativeStateKey='native_bridge_state';
const outbox=new BrowserOutbox();
let nativeSocket, nativeConnecting, nativeFlushing, nativeSequence=0, nativeHeartbeat;
const nativePending=new Map();
const syncedSessions=new Set();
let autoCallTabs={};
let retiredCallDocuments={};
const nativeReady=chrome.storage.session.get('auto_call_tabs').then(async value=>{
  autoCallTabs=value.auto_call_tabs || {};
  const retired=await chrome.storage.session.get('retired_call_documents');
  retiredCallDocuments=retired.retired_call_documents || {};
});
async function nativeState(error='') {
  const connected=nativeSocket?.readyState===WebSocket.OPEN;
  const pending=await outbox.count();
  const permission=await chrome.storage.local.get(['capture_consent_granted','desktop_capture_paused']);
  const state={connected,pending,error,permissionRequired:permission.capture_consent_granted!==true,capturePaused:permission.desktop_capture_paused===true};
  await chrome.storage.session.set({[nativeStateKey]:state});
  await chrome.action.setBadgeText({text:connected?(pending?'…':''): 'OFF'});
  await chrome.action.setBadgeBackgroundColor({color:connected?'#2358bf':'#a66100'});
  await chrome.action.setTitle({title:connected?'Cue · desktop connected':'Cue · desktop offline; saving in Chrome'});
  return state;
}
function nativeRequest(method,args={}) {
  return new Promise((resolve,reject)=>{
    if(nativeSocket?.readyState!==WebSocket.OPEN){reject(new Error('Desktop app offline'));return;}
    const id=String(++nativeSequence);
    const timer=setTimeout(()=>{nativePending.delete(id);reject(new Error('Desktop did not acknowledge; data retained in Chrome'));nativeSocket?.close();},5000);
    nativePending.set(id,{resolve,reject,timer});
    nativeSocket.send(JSON.stringify({id,method,...args}));
  });
}
async function nativeCaptureStatus(status) {
  await chrome.storage.local.set({capture_consent_granted:status.captureConsentGranted===true,desktop_capture_paused:status.paused!==false});
  const tabs=await chrome.tabs.query({});
  await Promise.allSettled(tabs.map(tab=>chrome.tabs.sendMessage(tab.id,{type:status.captureConsentGranted===true && status.paused===false?'NATIVE_CAPTURE_RESUME':'NATIVE_CAPTURE_PAUSE'})));
}
async function nativeConnect() {
  if(nativeSocket?.readyState===WebSocket.OPEN)return;
  if(nativeConnecting)return nativeConnecting;
  nativeConnecting=(async()=>{
    const ws=new WebSocket('ws://127.0.0.1:17373');nativeSocket=ws;
    ws.onmessage=event=>{
      let response;try{response=JSON.parse(event.data);}catch{ws.close();return;}
      if(['paused','capture-failed','resumed'].includes(response.event)) {
        void nativeRequest('status').then(nativeCaptureStatus).catch(()=>nativeState());return;
      }
      const entry=nativePending.get(response.id);if(!entry)return;
      nativePending.delete(response.id);clearTimeout(entry.timer);response.ok?entry.resolve(response.result):entry.reject(new Error(response.error));
    };
    ws.onclose=()=>{
      if(nativeSocket!==ws)return;
      clearInterval(nativeHeartbeat);
      for(const entry of nativePending.values()){clearTimeout(entry.timer);entry.reject(new Error('Desktop disconnected; data retained in Chrome'));}nativePending.clear();
      void nativeState();
    };
    await new Promise((resolve,reject)=>{const timer=setTimeout(()=>{ws.close();reject(new Error('Desktop app offline'));},3000);ws.onopen=()=>{clearTimeout(timer);resolve();};ws.onerror=()=>{clearTimeout(timer);reject(new Error('Desktop app offline'));};});
    await nativeRequest('hello',{role:'extension'});syncedSessions.clear();
    await nativeCaptureStatus(await nativeRequest('status'));
    nativeHeartbeat=setInterval(()=>{void nativeRequest('status').then(async status=>{await nativeCaptureStatus(status);await nativeFlush();}).catch(()=>nativeState());},20000);
    await nativeState();
  })();
  try{await nativeConnecting;}finally{nativeConnecting=null;}
}
async function nativeFlush() {
  if(nativeFlushing)return nativeFlushing;
  nativeFlushing=(async()=>{
    await nativeConnect();
    while(true){
    const batch=await outbox.list();if(!batch.length)break;
    for(const entry of batch) {
      if(entry.payload.method==='ingest-audio' && !syncedSessions.has(entry.payload.args.session)) {
        const record=await getCall(entry.payload.args.session.slice('chrome-'.length));
        if(!record)throw new Error('Audio metadata missing; data retained in Chrome');
        const ack=await nativeRequest('snapshot',{session:entry.payload.args.session,record});
        if(ack.paused){await nativeState();return;}
        syncedSessions.add(entry.payload.args.session);
      }
      const result=await nativeRequest(entry.payload.method,entry.payload.args);
      if(entry.payload.method==='snapshot' && !result.paused)syncedSessions.add(entry.payload.args.session);
      if(result.paused){await nativeState();return;}
      await outbox.acknowledge(entry);
    }
    }
    await nativeState();
  })();
  try{await nativeFlushing;}finally{nativeFlushing=null;}
}
async function queueRecord(record) {
  await outbox.put(`0-record:${record.id}`,{method:'snapshot',args:{session:`chrome-${record.id}`,record}});
}
async function nativeEnsureBrowserCall(sender) {
  await nativeReady;await migrateHistoricalCalls();
  if(!sender.documentId || (sender.documentLifecycle && sender.documentLifecycle!=='active'))throw new Error('Expected active browser document');
  const url=new URL(sender.url || sender.tab.url);
  const meeting=meetCodeFromURL(url.href);
  if(meeting && meetCodeFromURL(sender.tab.url)!==meeting)throw new Error('Meeting document no longer matches its tab');
  const tabKey=`${sender.tab.id}:${meeting ? 0 : sender.frameId || 0}`;
  return withCallLock(`tab:${tabKey}`,async()=>{
    if(retiredCallDocuments[tabKey]?.includes(sender.documentId))throw new Error('Stale browser document');
    const existing=autoCallTabs[tabKey] && await getCall(autoCallTabs[tabKey]);
    if(existing && !existing.ended_at && existing.capture_document_id===sender.documentId && (meeting ? meetCodeFromURL(existing.url)===meeting : existing.url===url.href))return existing;
    if(existing && !existing.ended_at)await queueRecord(await updateMeta(existing.id,{ended_at:Date.now()}));
    if(existing?.capture_document_id && existing.capture_document_id!==sender.documentId) {
      retiredCallDocuments[tabKey]=[...(retiredCallDocuments[tabKey] || []),existing.capture_document_id];
      await chrome.storage.session.set({retired_call_documents:retiredCallDocuments});
    }
    const id=`call-${crypto.randomUUID()}`;
    await ensureCall(id,{url:url.href,title:sender.tab.title || url.hostname});
    const record=await withCallLock(`call:${id}`,async()=>{
      const record=await getCall(id);
      record.capture_document_id=sender.documentId;
      record.independent_call=true;record.meeting_code=meeting || url.origin;record.series_id=record.meeting_code;
      if(!meeting)record.source='browser';
      await nativeRepairMeeting(record);await putCall(record);return record;
    });
    autoCallTabs[tabKey]=id;await chrome.storage.session.set({auto_call_tabs:autoCallTabs});
    return record;
  });
}
async function nativeRepairMeeting(record) {
  const code=meetCodeFromURL(record.url);if(!code)return record;
  record.meeting_code=code;record.series_id=code;record.source='meet';
  if(genericCallTitle(record.title)) {
    const matches=[];
    for(const id of await getIndex()) {
      const other=await getCall(id);
      if(other && !other.source_backup && meetCodeFromURL(other.url)===code && !genericCallTitle(other.title))matches.push(other);
    }
    matches.sort((a,b)=>(b.started_at || 0)-(a.started_at || 0));
    if(matches.length)record.title=matches[0].title;
  }
  return record;
}
async function nativeSyncHistory() {
  await migrateHistoricalCalls();
  const {call_source_backups:backups=[]}=await chrome.storage.local.get('call_source_backups');
  for(const id of [...backups,...await getIndex()])await withCallLock(`call:${id}`,async()=>{const record=await getCall(id);if(record){const before=JSON.stringify(record);await nativeRepairMeeting(record);if(JSON.stringify(record)!==before)await putCall(record);await queueRecord(record);}});
  await nativeFlush();
}
chrome.runtime.onMessage.addListener((message,sender,reply)=>{
  if(!message.type?.startsWith('NATIVE_'))return false;
  (async()=>{
    if(message.type==='NATIVE_CALL_EVENT') {
      if(sender.id!==chrome.runtime.id || !sender.tab || !/^https:\/\//.test(sender.url || ''))throw new Error('Expected browser call content script');
      await nativeReady;
      const permission=await chrome.storage.local.get('capture_consent_granted');
      if(permission.capture_consent_granted!==true && message.event!=='end')return {permissionRequired:true};
      const settings=await chrome.storage.local.get('auto_capture_enabled');
      if(settings.auto_capture_enabled===false && message.event==='audio')return {disabled:true};
      if(!sender.documentId || (sender.documentLifecycle && sender.documentLifecycle!=='active'))return {ignored:true};
      const url=new URL(sender.url);
      const meeting=meetCodeFromURL(url.href);
      if(meeting && meetCodeFromURL(sender.tab.url)!==meeting)return {ignored:true};
      const tabID=`${sender.tab.id}:${meeting ? 0 : sender.frameId || 0}`;
      if(retiredCallDocuments[tabID]?.includes(sender.documentId))return {ignored:true};
      if(message.event==='start') {
        const record=await nativeEnsureBrowserCall(sender);
        await withCallLock(`call:${record.id}`,async()=>{
          const current=await getCall(record.id);
          if(message.presenceConfirmed===true && !current.presence_confirmed){current.presence_confirmed=true;await putCall(current);}
          await queueRecord(current);
        });
        void nativeFlush().catch(()=>nativeState());return {id:record.id};
      }
      const id=autoCallTabs[tabID];if(!id)return {ignored:true};
      return withCallLock(`call:${id}`,async()=>{
        const record=await getCall(id);
        if(!record || record.ended_at || record.capture_document_id!==sender.documentId || (meeting ? meetCodeFromURL(record.url)!==meeting : record.url!==url.href))return {ignored:true};
        if(message.event==='audio') {
          const frame=message.frame;
          if(!frame || typeof frame.id!=='string' || !/^[a-zA-Z0-9_-]{1,100}$/.test(frame.id) || typeof frame.pcm!=='string' || frame.pcm.length>700000 || !['local','remote'].includes(frame.source))throw new Error('Invalid browser audio');
          if(frame.mappingHistory!==undefined && (!Array.isArray(frame.mappingHistory) || !frame.mappingHistory.length || frame.mappingHistory.length>16 || JSON.stringify(frame.mappingHistory).length>32000))throw new Error('Invalid mapping history');
          await outbox.put(`audio:${frame.id}`,{method:'ingest-audio',args:{session:`chrome-${id}`,frame:{...frame,sampleRate:16000}}});
        } else if(message.event==='participants') {
          const people=message.participants;
          if(!Array.isArray(people) || people.length>500 || people.some(person=>!person || typeof person.id!=='string' || !person.id || person.id.length>500 || typeof person.name!=='string' || person.name.length>500 || typeof person.isSelf!=='boolean'))throw new Error('Invalid Meet participants');
          record.speaker_roster=people;
          record.participants=[...new Set([...(record.participants || []),...people.map(person=>person.name)])];
          await putCall(record);await queueRecord(record);
        } else if(message.event==='end') {
          record.ended_at=Date.now();await putCall(record);
          await queueRecord(record);
        } else throw new Error('Unknown call event');
        void nativeFlush().catch(()=>nativeState());return {saved:true};
      });
    }
    if(sender.id!==chrome.runtime.id || sender.tab || !sender.url?.startsWith(chrome.runtime.getURL('')))throw new Error('Extension controls only');
    if(message.type==='NATIVE_STATUS'){void nativeFlush().catch(()=>nativeState());return nativeState();}
    if(message.type==='NATIVE_IMPORT'){await nativeSyncHistory();return {synced:true};}
    throw new Error('Unknown native command');
  })().then(reply,error=>reply({error:error.message}));return true;
});
chrome.storage.onChanged.addListener((changes,area)=>{
  if(area!=='local')return;
  for(const [key,value]of Object.entries(changes))if(key.startsWith('call:') && value.newValue)void queueRecord(value.newValue).then(()=>nativeFlush()).catch(()=>nativeState());
});
chrome.alarms.onAlarm.addListener(alarm=>{if(alarm.name==='native-reconnect')void nativeFlush().catch(()=>nativeState());});
chrome.alarms.create('native-reconnect',{periodInMinutes:0.5});
chrome.tabs.onRemoved.addListener(async tabID=>{
  await nativeReady;
  for(const key of Object.keys(autoCallTabs))if(key.startsWith(`${tabID}:`)){
    await withCallLock(`tab:${key}`,async()=>{
      const id=autoCallTabs[key];if(!id)return;
      await updateMeta(id,{ended_at:Date.now()});await queueRecord(await getCall(id));delete autoCallTabs[key];delete retiredCallDocuments[key];
    });
  }
  await chrome.storage.session.set({auto_call_tabs:autoCallTabs,retired_call_documents:retiredCallDocuments});void nativeFlush().catch(()=>nativeState());
});
setTimeout(()=>{void nativeSyncHistory().catch(()=>nativeState());},500);
