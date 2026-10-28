const nativeStatus = document.getElementById('native-status');
const automaticCapture = chrome.runtime.getManifest().content_scripts.some(script => script.js.includes('call-media.js'));
async function nativeCommand(type,args = {}) {
  const result = await chrome.runtime.sendMessage({type,...args});
  if (result?.error) throw new Error(result.error);
  return result;
}
async function refreshNative() {
  try {
    const state = await nativeCommand('NATIVE_STATUS');
    nativeStatus.classList.toggle('offline',!state.connected);
    nativeStatus.textContent = state.error || (state.capturing ? 'Capturing remote audio locally' : state.connected
      ? `Desktop connected${automaticCapture ? ' · ' + (state.pending || 0) + ' waiting to sync' : ' · no audio capture'}`
      : automaticCapture ? 'Desktop app offline · saving in Chrome' : 'Desktop app unavailable');
  } catch (error) { nativeStatus.classList.add('offline'); nativeStatus.textContent = error.message; }
}
for (const [id,type] of [['native-connect','NATIVE_CONNECT'],['native-start','NATIVE_START'],['native-stop','NATIVE_STOP'],['native-disconnect','NATIVE_DISCONNECT'],['native-import','NATIVE_IMPORT']]) {
  document.getElementById(id)?.addEventListener('click',async event => {
    event.target.disabled = true;
    try { const result = await nativeCommand(type); await refreshNative(); if (result.imported !== undefined) nativeStatus.textContent = `Copied ${result.imported} calls; browser originals retained`; }
    catch (error) { nativeStatus.textContent = error.message; }
    finally { event.target.disabled = false; }
  });
}
const autoCapture = document.getElementById('auto-capture-toggle');
if (autoCapture) {
  document.getElementById('automatic-controls').hidden = !automaticCapture;
  document.getElementById('manual-controls').hidden = automaticCapture;
  chrome.storage.local.get('auto_capture_enabled',value => { autoCapture.checked = value.auto_capture_enabled !== false; });
  autoCapture.addEventListener('change',() => chrome.storage.local.set({auto_capture_enabled:autoCapture.checked}));
  document.getElementById('native-extension-id').textContent = chrome.runtime.id;
}
void refreshNative();
setInterval(refreshNative,3000);
