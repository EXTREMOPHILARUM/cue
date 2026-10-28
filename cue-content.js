// Content script — isolated world.
// Responsibilities:
// 1. Inject bridge.js into the page world so window.__cue becomes callable.
// 2. Proxy postMessage requests from the page world to the background service worker.
// 3. Continuously scrape Meet captions/participants and push to background.

(function () {
  const MEET_CODE_RE = /^\/(?:meet\/)?([a-z]{3}-[a-z]{4}-[a-z]{3})(?:\/|$)/;

  function currentMeetingId() {
    const m = location.pathname.match(MEET_CODE_RE);
    return m ? m[1] : null;
  }

  function inMeeting() {return typeof CallAssistantMeetPresence!=='function' || CallAssistantMeetPresence(document);}

  function readTitle() {
    // Meet pages: document.title contains the meeting name when joined.
    const t = document.title || '';
    return t.replace(/^Meet[–—\-]\s*/, '').trim();
  }

  function readParticipants() {
    // Best-effort. Names appear in caption blocks (own + others).
    const names = new Set();
    document.querySelectorAll('div.nMcdL').forEach(d => {
      const lines = (d.innerText || '').split('\n');
      if (lines[0]) names.add(lines[0].trim());
    });
    return [...names];
  }

  // Parse a single Meet caption block (div.nMcdL) into {speaker, text}.
  // Block layout is "<speaker>\n<spoken text...>". Returns null if empty.
  function parseBlock(node) {
    const txt = (node.innerText || '').trim();
    if (!txt) return null;
    const lines = txt.split('\n');
    const speaker = lines[0];
    const text = lines.slice(1).join(' ').trim();
    if (!text) return null;
    return { speaker, text };
  }


  // ---------- bridge injection ----------
  const s = document.createElement('script');
  s.src = chrome.runtime.getURL('bridge.js');
  s.onload = () => s.remove();
  (document.head || document.documentElement).appendChild(s);

  // ---------- visual captions hide ----------
  // We always need the caption DOM to *exist* so we can scrape it. But the
  // visible captions overlay often blocks a portion of someone's shared
  // screen during interviews. The CSS below hides the overlay visually
  // (opacity:0, pointer-events:none, transform:scale(0)) without removing
  // the nodes — captures keep working as normal.
  const HIDE_STYLE_ID = 'rf-hide-captions-style';
  // Pulls the Meet captions panel out of layout flow without removing it
  // from the rendering tree — descendants stay rendered so innerText still
  // works for our scrape.
  //
  // Selector strategy: target the panel by walking up from the semantic
  // [aria-label="Captions"][role="region"] anchor (most stable across Meet
  // redesigns) and fall back to the .a4cQT class for older builds.
  //
  // Why position:fixed + opacity:0 + z-index:-1:
  //   - position:fixed takes the element out of normal layout flow → screen
  //     space released, no more empty 216px strip at the bottom.
  //   - We keep dimensions so descendants render normally; innerText reads
  //     from rendered text, which requires the element to be in the layout
  //     tree (display:none would break it).
  //   - opacity:0 + pointer-events:none make it invisible and click-through
  //     so it can't block screen share interaction.
  //   - z-index:-1 sits it behind everything else as a final safety net.
  const HIDE_CSS = `
    div:has(> div > div > div[aria-label="Captions"]),
    div:has(> div > div[aria-label="Captions"]),
    div.a4cQT {
      position: fixed !important;
      top: -2000px !important;
      left: 0 !important;
      width: 800px !important;
      height: 200px !important;
      opacity: 0 !important;
      pointer-events: none !important;
      z-index: -1 !important;
    }
  `;

  function applyHide(hidden) {
    let style = document.getElementById(HIDE_STYLE_ID);
    if (hidden) {
      if (!style) {
        style = document.createElement('style');
        style.id = HIDE_STYLE_ID;
        style.textContent = HIDE_CSS;
        (document.head || document.documentElement).appendChild(style);
      }
    } else if (style) {
      style.remove();
    }
  }

  try {
    chrome.storage.local.get('captions_hidden', ({ captions_hidden }) => applyHide(!!captions_hidden));
    chrome.storage.onChanged.addListener((changes, area) => {
      if (area === 'local' && changes.captions_hidden) applyHide(!!changes.captions_hidden.newValue);
    });
  } catch (err) {
    // Extension context already dead before content script finished initialising.
    // Silently swallow — the rest of the script will short-circuit on the next tick.
  }

  // ---------- page-world → content-script proxy ----------
  // Page world calls postMessage({source: 'cue', reqId, type, ...args})
  // We answer with postMessage({source: 'cue-reply', reqId, result})
  window.addEventListener('message', (ev) => {
    if (ev.source !== window) return;
    const m = ev.data;
    if (!m || m.source !== 'cue') return;
    if (extensionContextDead) {
      window.postMessage({
        source: 'cue-reply',
        reqId: m.reqId,
        result: null,
        error: 'extension context invalidated — reload the tab'
      }, '*');
      return;
    }
    try {
      chrome.runtime.sendMessage({ type: m.type, ...m.args }, (response) => {
        window.postMessage({
          source: 'cue-reply',
          reqId: m.reqId,
          result: response,
          error: chrome.runtime.lastError ? chrome.runtime.lastError.message : null
        }, '*');
      });
    } catch (err) {
      if (isContextInvalidationError(err)) tearDownOrphanedScript();
      window.postMessage({
        source: 'cue-reply',
        reqId: m.reqId,
        result: null,
        error: err && err.message || String(err)
      }, '*');
    }
  });

  // ---------- live capture ----------
  // Captions are captured *event-driven* via a MutationObserver (see below);
  // only call/meta bookkeeping (ENSURE_CALL, title, participants) runs on a
  // slow timer, since those rarely change and aren't worth observing.
  let lastMeetingId = null;
  let lastTitle = '';
  let lastParticipants = '';

  // When the user reloads the extension at chrome://extensions, the old
  // content script remains injected in any already-open tab but its
  // chrome.runtime handle now points at a dead context. Every sendMessage
  // will reject with "Extension context invalidated." We catch that once,
  // tear down all our timers and the observer, and go silent — otherwise the
  // console fills up with rejected-promise spam.
  let metaIntervalId = null;
  let captionEnableIntervalId = null;
  let captionObserver = null;
  let extensionContextDead = false;

  function tearDownOrphanedScript() {
    if (extensionContextDead) return;
    extensionContextDead = true;
    if (metaIntervalId !== null) clearInterval(metaIntervalId);
    if (captionEnableIntervalId !== null) clearInterval(captionEnableIntervalId);
    if (captionObserver) captionObserver.disconnect();
    console.log('[cue] extension context invalidated — stopping content-script loops. Reload the tab to reconnect.');
  }

  function isContextInvalidationError(err) {
    return err && typeof err.message === 'string' &&
      err.message.includes('Extension context invalidated');
  }

  function safeSendMessage(payload) {
    if (extensionContextDead) return Promise.resolve();
    try {
      const p = chrome.runtime.sendMessage(payload);
      if (p && typeof p.catch === 'function') {
        p.catch((err) => {
          if (isContextInvalidationError(err)) tearDownOrphanedScript();
        });
      }
      return p;
    } catch (err) {
      if (isContextInvalidationError(err)) tearDownOrphanedScript();
      return Promise.resolve();
    }
  }

  // Call existence + metadata only. Captions are handled by the observer.
  function metaTick() {
    if (extensionContextDead) return;
    const id = currentMeetingId();
    if (!id || !inMeeting()) return;

    if (id !== lastMeetingId) {
      lastMeetingId = id;
      safeSendMessage({
        type: 'ENSURE_CALL',
        id,
        meta: { url: location.href, title: readTitle() }
      });
    }

    const title = readTitle();
    const participants = readParticipants();
    const partsKey = participants.sort().join('|');

    if (title !== lastTitle || partsKey !== lastParticipants) {
      lastTitle = title;
      lastParticipants = partsKey;
      safeSendMessage({
        type: 'UPDATE_META',
        id,
        meta: { title, participants }
      });
    }
  }

  // Title/participants drift slowly; 3s is plenty and keeps the call record
  // alive before the first caption arrives.
  metaIntervalId = setInterval(metaTick, 3000);
  metaTick();

  // ---------- event-based caption capture ----------
  // Instead of re-reading the whole caption panel on a timer, we watch the
  // caption DOM and react only to what actually changes. Each Meet caption
  // block (div.nMcdL) is one utterance; Meet mutates the block's text in place
  // as the speaker talks, then recycles the node. We give each block a stable
  // rowId on first sight and the background upserts by that id — so a growing
  // utterance updates one row and an unchanged block emits nothing. The DOM
  // node *is* the row identity, which removes the need to guess at re-scrapes.

  // node -> { rowId, speaker, text }. The DOM node IS the row identity: Meet
  // starts a new caption block (a new div.nMcdL) for every speaker turn, so each
  // block maps 1:1 to one utterance and we never have to guess whether incoming
  // text is a re-scrape or a continuation — a node we've seen is the same
  // utterance still growing, a node we haven't is a new one. Plain Map (not
  // WeakMap) so we can sweep out entries whose node has left the DOM; bounded by
  // Meet's small on-screen caption set plus its scrollback, so it never grows.
  const blockRows = new Map();
  // rowId -> {rowId, speaker, text, t}; coalesces a burst of mutations into one
  // message per flush so we don't post per-character.
  const pending = new Map();
  let flushTimer = null;

  function makeRowId() {
    return (crypto.randomUUID && crypto.randomUUID()) ||
      (Date.now().toString(36) + Math.random().toString(36).slice(2));
  }

  function flushPending() {
    flushTimer = null;
    if (extensionContextDead || !pending.size) return;
    const id = currentMeetingId();
    if (!id) { pending.clear(); return; }
    const captions = [...pending.values()];
    pending.clear();
    safeSendMessage({ type: 'UPSERT_CAPTIONS', id, captions });
  }

  // Walk the currently-rendered caption blocks and diff each against what we
  // last emitted for that node. Cheap: only runs after a mutation, and only
  // over the handful of blocks Meet keeps in the DOM.
  function reconcileCaptions() {
    if (extensionContextDead || !inMeeting()) return;
    for (const node of document.querySelectorAll('div.nMcdL')) {
      const parsed = parseBlock(node);
      if (!parsed) continue;
      let row = blockRows.get(node);
      if (!row) {
        // First time we've seen this block — new utterance.
        row = { rowId: makeRowId(), speaker: parsed.speaker, text: '' };
        blockRows.set(node, row);
      } else if (row.speaker !== parsed.speaker) {
        // Meet won't change the speaker within a block, so a speaker change means
        // it reused this DOM node for a new turn — start a new row. (No text
        // matching: the same node + same speaker is always the same utterance,
        // even as Meet rewrites earlier words, so growth needs no heuristic.)
        row = { rowId: makeRowId(), speaker: parsed.speaker, text: '' };
        blockRows.set(node, row);
      } else if (row.text === parsed.text) {
        continue; // unchanged since last reconcile — emit nothing
      }
      row.speaker = parsed.speaker;
      row.text = parsed.text;
      pending.set(row.rowId, { rowId: row.rowId, speaker: parsed.speaker, text: parsed.text, t: Date.now() });
    }
    // Drop nodes Meet has removed so the Map stays bounded.
    for (const node of blockRows.keys()) {
      if (!node.isConnected) blockRows.delete(node);
    }
    if (pending.size && flushTimer === null) {
      flushTimer = setTimeout(flushPending, 250);
    }
  }

  // The caption panel is created only once captions are on, and Meet may
  // rebuild it, so we (re)bind the observer to the current container. The
  // caption-enable interval below drives this check.
  let observedContainer = null;
  function findCaptionsContainer() {
    return document.querySelector('[aria-label="Captions"][role="region"]') ||
      document.querySelector('div.a4cQT') ||
      (document.querySelector('div.nMcdL') || {}).parentElement ||
      null;
  }
  function ensureCaptionObserver() {
    if (extensionContextDead) return;
    const container = findCaptionsContainer();
    if (!container || container === observedContainer) return;
    if (!captionObserver) captionObserver = new MutationObserver(reconcileCaptions);
    captionObserver.disconnect();
    captionObserver.observe(container, { childList: true, subtree: true, characterData: true });
    observedContainer = container;
    reconcileCaptions(); // capture whatever is already on screen
  }

  // ---------- auto-enable captions ----------
  // Meet only renders caption DOM when captions are turned on. We can't
  // capture what isn't rendered, so we keep trying to enable them while the
  // user is on a Meet page. No attempt cap — the user may join the call
  // long after the extension loads, and once captions are on the check is
  // a no-op. Two strategies, tried in order:
  //   1. Find the CC button by aria-label / data-tooltip / data-tooltip-id
  //      keyword sniff, then click if it reads as "off".
  //   2. Fallback: simulate the 'c' keyboard shortcut that Meet itself
  //      binds for caption toggle, if we've waited long enough and still
  //      haven't seen captions appear.
  function findCaptionButton() {
    const candidates = document.querySelectorAll(
      'button[aria-label], button[data-tooltip], button[data-tooltip-id], div[role="button"][aria-label]'
    );
    // Rank candidates instead of returning the first label match — Meet has
    // multiple caption-related buttons (toggle, settings, jump-to-recent),
    // and the toggle is the only one we want to click.
    //   3 = explicit "turn on/off captions" or "enable/disable captions"
    //   2 = label mentions caption but not settings/options/jump
    //   0 = excluded (settings, jump-to-recent, preferences, etc.)
    let best = null;
    let bestScore = 0;
    for (const el of candidates) {
      const labels = [
        el.getAttribute('aria-label') || '',
        el.getAttribute('data-tooltip') || '',
        el.getAttribute('data-tooltip-id') || ''
      ].join(' ').toLowerCase();

      const mentionsCaption =
        labels.includes('caption') ||
        labels.includes('subtitle') ||
        /\bcc\b/.test(labels) ||
        labels.includes('字幕') ||
        labels.includes('untertitel') ||
        labels.includes('sous-titre');
      if (!mentionsCaption) continue;

      // Hard excludes: these match the caption keyword but are NOT the toggle.
      if (
        labels.includes('settings') ||
        labels.includes('options') ||
        labels.includes('preferences') ||
        labels.includes('language') ||
        labels.includes('jump to') ||
        labels.includes('go to') ||
        labels.includes('open')
      ) continue;

      const isToggle =
        labels.includes('turn on') || labels.includes('turn off') ||
        labels.includes('enable') || labels.includes('disable') ||
        labels.includes('start') || labels.includes('stop');

      const score = isToggle ? 3 : 2;
      if (score > bestScore) {
        best = el;
        bestScore = score;
      }
    }
    return best;
  }

  function captionsAreOn(btn) {
    if (!btn) return null;
    const lbl = ((btn.getAttribute('aria-label') || '') + ' ' + (btn.getAttribute('data-tooltip') || '')).toLowerCase();
    if (lbl.includes('turn off') || lbl.includes('disable')) return true;
    if (lbl.includes('turn on') || lbl.includes('enable')) return false;
    const pressed = btn.getAttribute('aria-pressed');
    if (pressed === 'true') return true;
    if (pressed === 'false') return false;
    return null;
  }

  function captionsVisibleInDom() {
    return document.querySelectorAll('div.nMcdL').length > 0;
  }

  function sendCKeyShortcut() {
    // Meet binds 'c' to caption toggle. Dispatch a synthetic keydown on the
    // document — this works whether or not the page is focused.
    const ev = new KeyboardEvent('keydown', {
      key: 'c', code: 'KeyC', keyCode: 67, which: 67,
      bubbles: true, cancelable: true
    });
    document.dispatchEvent(ev);
    document.body && document.body.dispatchEvent(ev);
  }

  let captionsEnabledByUs = false;
  let buttonAttempts = 0;
  function maybeEnableCaptions() {
    if (extensionContextDead || !inMeeting()) return;
    // Keep the caption observer bound to the current panel (cheap no-op once
    // attached; re-binds if Meet rebuilds the container).
    ensureCaptionObserver();
    // Stop trying to turn captions on once blocks are in the DOM.
    if (captionsVisibleInDom()) return;

    const btn = findCaptionButton();
    if (btn) {
      const state = captionsAreOn(btn);
      if (state === false || state === null) {
        btn.click();
        captionsEnabledByUs = true;
        console.log('[cue] clicked CC button to enable captions');
      }
      return;
    }

    // No button found yet. After ~30s of trying, fall back to the 'c'
    // shortcut on the chance the user is in the call but the button is
    // hidden behind a collapsed toolbar.
    buttonAttempts++;
    if (buttonAttempts > 15 && !captionsEnabledByUs) {
      sendCKeyShortcut();
      console.log('[cue] sent "c" keyboard shortcut as caption-toggle fallback');
    }
  }

  captionEnableIntervalId = setInterval(maybeEnableCaptions, 2000);
  setTimeout(maybeEnableCaptions, 1500);

  // ---------- end-of-call marker ----------
  window.addEventListener('beforeunload', () => {
    const id = currentMeetingId();
    if (id) chrome.runtime.sendMessage({ type: 'UPDATE_META', id, meta: { ended_at: Date.now() } });
  });
})();
