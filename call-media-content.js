(() => {
  let enabled=false, queue=Promise.resolve(), callStarted=false, generation=0,pausedByApp=false,presenceConfirmed=false;
  function control(){window.postMessage({source:'call-assistant-control',enabled},location.origin);}
  function refresh(){chrome.storage.local.get(['auto_capture_enabled','capture_consent_granted','desktop_capture_paused'],value=>{
    const next=value.capture_consent_granted===true && value.auto_capture_enabled!==false && value.desktop_capture_paused!==true && !pausedByApp;
    // First permission may arrive after Meet's start event was refused by the background.
    if(next && !enabled && callStarted)queue=queue.then(async()=>{
      const result=await chrome.runtime.sendMessage({type:'NATIVE_CALL_EVENT',event:'start',presenceConfirmed});
      if(result?.error)throw new Error(result.error);
    }).catch(error=>{enabled=false;control();notice(`Cue stopped: ${error.message}`);});
    enabled=next;control();
  });}
  refresh();
  chrome.storage.onChanged.addListener((changes,area)=>{if(area==='local' && ['auto_capture_enabled','capture_consent_granted','desktop_capture_paused'].some(key=>changes[key]))refresh();});
  chrome.runtime.onMessage.addListener(message=>{if(message.type==='NATIVE_CAPTURE_PAUSE'){pausedByApp=true;refresh();}if(message.type==='NATIVE_CAPTURE_RESUME'){pausedByApp=false;refresh();}});
  function notice(text){let node=document.getElementById('call-assistant-recording-status');if(!node){node=document.createElement('div');node.id='call-assistant-recording-status';node.style.cssText='position:fixed;bottom:12px;left:12px;z-index:2147483646;background:#17354a;color:#fff;padding:7px 11px;border-radius:8px;font:12px system-ui;pointer-events:none;';(document.body || document.documentElement).append(node);}node.textContent=text;}
  window.addEventListener('message',event=>{
    if(event.source!==window || event.origin!==location.origin || event.data?.source!=='call-assistant-media')return;
    const message=event.data;
    if(message.event==='warning'){notice('Cue: '+String(message.message).slice(0,120));return;}
    if(message.event==='error'){enabled=false;control();notice(`Cue: ${String(message.message).slice(0,100)}`);return;}
    if(message.event==='start'){callStarted=true;presenceConfirmed=message.presenceConfirmed===true;generation++;notice(enabled?'Cue · saving this call locally':'Cue · capture paused; check app Setup');}
    const callGeneration=generation;
    if(!callStarted || (!enabled && message.event==='audio'))return;
    const payload={type:'NATIVE_CALL_EVENT',event:message.event,frame:message.frame,participants:message.participants,presenceConfirmed:message.presenceConfirmed===true};
    queue=queue.then(async()=>{
      const result=await chrome.runtime.sendMessage(payload);
      if(result?.error)throw new Error(result.error);
      if(message.event==='end' && callGeneration===generation){callStarted=false;document.getElementById('call-assistant-recording-status')?.remove();}
    }).catch(error=>{enabled=false;control();notice(`Cue stopped: ${error.message}`);});
  });
  window.addEventListener('DOMContentLoaded',control,{once:true});
})();
