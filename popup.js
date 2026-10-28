const MEET_CODE_RE = /^\/(?:meet\/)?([a-z]{3}-[a-z]{4}-[a-z]{3})(?:\/|$)/;

// Show the real manifest version so the UI can never drift from manifest.json.
(() => {
  const el = document.getElementById('version');
  if (el) el.textContent = 'v' + chrome.runtime.getManifest().version;
})();

function send(type, args = {}) {
  return new Promise((resolve, reject) => {
    chrome.runtime.sendMessage({ type, ...args }, result => {
      if (chrome.runtime.lastError) reject(new Error(chrome.runtime.lastError.message));
      else resolve(result);
    });
  });
}

async function getActiveTabMeetId() {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (!tab || !tab.url) return null;
  try {
    const u = new URL(tab.url);
    if (u.host !== 'meet.google.com') return null;
    const m = u.pathname.match(MEET_CODE_RE);
    if(!m)return null;
    const active=await send('ACTIVE_CALL',{tabId:tab.id});
    return active?.id || null;
  } catch {
    return null;
  }
}

async function refresh() {
  const name = document.getElementById('call-name');
  const meta = document.getElementById('current-meta');
  const pill = document.getElementById('status-pill');
  const status = document.getElementById('status-text');
  try {
    const id = await getActiveTabMeetId();
    if (!id) return;
    const record = await send('GET_CALL', { id });
    if (!record || record.error) throw new Error('Could not load current call. Reopen Cue to try again.');
    name.textContent = record.topic || record.title || 'Untitled call';
    const captions = record.captions?.length || 0;
    const participants = record.participants?.length || 0;
    meta.textContent = `${captions} caption${captions === 1 ? '' : 's'} · ${participants} participant${participants === 1 ? '' : 's'}`;
    pill.classList.add('live');
    status.textContent = 'Meet tab open';
  } catch (error) {
    meta.textContent = error.message;
  }
}
void refresh();
