// Shared by the isolated caption script and page-world audio observer.
(() => {
  if(globalThis.CallAssistantMeetPresence)return;
  globalThis.CallAssistantMeetPresence=(document,selfPresent=false)=>{
    const visible=node=>node && node.getClientRects().length>0 && getComputedStyle(node).display!=='none' && getComputedStyle(node).visibility!=='hidden';
    if(selfPresent)return true;
    for(const marker of document.querySelectorAll('[data-participant-id] [data-self-name],[data-participant-id][data-self-name],[data-participant-id][data-is-self="true"]'))if(visible(marker))return true;
    for(const button of document.querySelectorAll('button,[role="button"]')) {
      if(!visible(button))continue;
      const label=[button.getAttribute('aria-label'),button.getAttribute('data-tooltip')].filter(Boolean).join(' ');
      if(/\b(?:leave|end) (?:the )?(?:call|meeting)\b/i.test(label) || /\bcall_end\b/.test(button.textContent || ''))return true;
    }
    return false;
  };
})();
