const captionsToggle = document.getElementById('hide-captions-toggle');
(async () => {
  try {
    const result = await chrome.runtime.sendMessage({type:'GET_SETTING',key:'captions_hidden'});
    if (result?.error) throw new Error(result.error);
    captionsToggle.checked = !!result?.value;
  } catch (error) { nativeStatus.textContent = error.message; captionsToggle.disabled = true; }
})();
captionsToggle.addEventListener('change',async () => {
  try {
    const result = await chrome.runtime.sendMessage({type:'SET_SETTING',key:'captions_hidden',value:captionsToggle.checked});
    if (result?.error) throw new Error(result.error);
  } catch (error) { captionsToggle.checked = !captionsToggle.checked; nativeStatus.textContent = error.message; }
});
