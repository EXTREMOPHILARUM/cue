// Page-world bridge. Runs in the same JS world as Meet (and as
// chrome-devtools `evaluate_script`), so Claude can call window.__cue.*
// directly. All methods round-trip through postMessage → content script →
// background → chrome.storage.local.

(function () {
  if (window.__cue) return;

  const MEET_CODE_RE = /^\/(?:meet\/)?([a-z]{3}-[a-z]{4}-[a-z]{3})(?:\/|$)/;

  function call(type, args = {}) {
    return new Promise((resolve, reject) => {
      const reqId = 'r_' + Math.random().toString(36).slice(2) + '_' + Date.now();
      const onMessage = (ev) => {
        if (ev.source !== window) return;
        const m = ev.data;
        if (!m || m.source !== 'cue-reply' || m.reqId !== reqId) return;
        window.removeEventListener('message', onMessage);
        if (m.error) reject(new Error(m.error));
        else resolve(m.result);
      };
      window.addEventListener('message', onMessage);
      window.postMessage({ source: 'cue', reqId, type, args }, '*');
      // 10s timeout so callers never hang the agent loop.
      setTimeout(() => {
        window.removeEventListener('message', onMessage);
        reject(new Error('cue bridge timeout: ' + type));
      }, 10000);
    });
  }

  // ---------- feedback canvas ----------
  // A raw-HTML surface the agent writes to and the user interacts with. Lives
  // entirely in the page world: the agent calls render()/getUIEvents()/popout()
  // through the same evaluate_script world these run in, so there's no bridge
  // round-trip. Two mounts, same element: a Document Picture-in-Picture window
  // (always-on-top, survives tab switches) when available, else a fixed in-page
  // overlay. Interaction flows back through a simple event queue the agent
  // drains just like it drains captions.
  const RF_CANVAS = (function () {
    let rootEl = null;         // the canvas container (one element, re-parented between mounts)
    let pipWindow = null;      // active Document PiP window, if any
    let lastAgentHTML = '<p class="rf-empty">Waiting for the agent…</p>';
    const events = [];         // {id, t, action, value, targetId}
    let seq = 0;

    // Meet enforces Trusted Types (require-trusted-types-for 'script'), which
    // makes any raw `el.innerHTML = string` throw. A named TT policy is allowed
    // by Meet's CSP, so we route all HTML writes through one. Falls back to a
    // plain string on pages without Trusted Types.
    let ttPolicy = null;
    try {
      if (window.trustedTypes && window.trustedTypes.createPolicy) {
        ttPolicy = window.trustedTypes.createPolicy('rf-canvas', { createHTML: (s) => s });
      }
    } catch (_) { ttPolicy = null; }
    function setHTML(el, html) {
      const s = html == null ? '' : String(html);
      el.innerHTML = ttPolicy ? ttPolicy.createHTML(s) : s;
    }

    const CSS = `
      #rf-canvas-root, #rf-canvas-root * { box-sizing: border-box; }
      #rf-canvas-root {
        position: fixed; top: 16px; right: 16px; width: 360px; height: 520px; max-height: 90vh;
        min-width: 240px; min-height: 120px; resize: both;
        display: flex; flex-direction: column; z-index: 2147483647;
        font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
        color: #e8eaed; background: #202124; border: 1px solid #3c4043;
        border-radius: 12px; box-shadow: 0 8px 32px rgba(0,0,0,.45); overflow: hidden;
      }
      #rf-canvas-root.rf-pip { position: static; top: auto; right: auto;
        width: 100%; height: 100%; max-height: none; min-width: 0; min-height: 0; resize: none;
        border: none; border-radius: 0; box-shadow: none; }
      /* Collapsed: show only the title bar; disable resize while minimized. */
      #rf-canvas-root.rf-collapsed { height: auto !important; max-height: none; resize: none; }
      #rf-canvas-root.rf-collapsed .rf-agent, #rf-canvas-root.rf-collapsed .rf-notes-wrap { display: none; }
      #rf-canvas-root .rf-head {
        display: flex; align-items: center; gap: 8px; padding: 10px 14px;
        background: #292a2d; border-bottom: 1px solid #3c4043; font-size: 13px; font-weight: 600;
        cursor: move; user-select: none; flex: 0 0 auto;
      }
      #rf-canvas-root.rf-pip .rf-head { cursor: default; }
      #rf-canvas-root .rf-dot { width: 8px; height: 8px; border-radius: 50%; background: #34a853; margin-left: auto; }
      #rf-canvas-root .rf-btn {
        cursor: pointer; background: transparent; border: none; color: #9aa0a6;
        font-size: 15px; line-height: 1; padding: 2px 7px; border-radius: 6px; font-weight: 700;
      }
      #rf-canvas-root .rf-btn:hover { background: #3c4043; color: #e8eaed; }
      #rf-canvas-root .rf-agent { padding: 14px; overflow-y: auto; font-size: 14px; line-height: 1.5; flex: 1 1 auto; }
      #rf-canvas-root .rf-agent .rf-empty { color: #9aa0a6; font-style: italic; }
      #rf-canvas-root .rf-agent h1, #rf-canvas-root .rf-agent h2, #rf-canvas-root .rf-agent h3 { margin: 0 0 8px; font-size: 15px; }
      #rf-canvas-root .rf-agent p { margin: 0 0 10px; }
      #rf-canvas-root .rf-agent ul { margin: 0 0 10px; padding-left: 20px; }
      #rf-canvas-root .rf-agent button, #rf-canvas-root .rf-agent [data-rf-action] {
        cursor: pointer;
      }
      #rf-canvas-root .rf-agent button {
        background: #8ab4f8; color: #202124; border: none; border-radius: 8px;
        padding: 7px 12px; font-size: 13px; font-weight: 600; margin: 2px 4px 2px 0;
      }
      #rf-canvas-root .rf-agent button:hover { background: #aecbfa; }
      #rf-canvas-root .rf-nudge { background: #3c2f1c; border-left: 3px solid #fbbc04; padding: 10px 12px; border-radius: 6px; margin: 0 0 10px; }
      #rf-canvas-root .rf-notes-wrap { border-top: 1px solid #3c4043; padding: 10px 12px; background: #292a2d; }
      #rf-canvas-root .rf-notes-wrap label { display: block; font-size: 11px; color: #9aa0a6; margin-bottom: 5px; text-transform: uppercase; letter-spacing: .5px; }
      #rf-canvas-root textarea#rf-notes {
        width: 100%; min-height: 54px; resize: vertical; background: #202124; color: #e8eaed;
        border: 1px solid #3c4043; border-radius: 8px; padding: 8px; font: inherit; font-size: 13px;
      }
    `;

    function debounce(fn, ms) {
      let t = null;
      return (...a) => { clearTimeout(t); t = setTimeout(() => fn(...a), ms); };
    }

    function pushEvent(action, value, targetId) {
      events.push({ id: ++seq, t: Date.now(), action, value, targetId: targetId || null });
      if (events.length > 500) events.splice(0, events.length - 500);
    }

    function onInteraction(e) {
      const el = e.target.closest('[data-rf-action]');
      if (!el) return;
      const action = el.getAttribute('data-rf-action');
      const value = ('value' in el && el.value !== undefined && el.value !== '')
        ? el.value
        : (el.getAttribute('data-rf-value') || (el.textContent || '').trim());
      pushEvent(action, value, el.id || null);
    }

    function buildRoot() {
      const root = document.createElement('div');
      root.id = 'rf-canvas-root';
      setHTML(root,
        '<div class="rf-head"><span class="rf-title">Cue · live</span><span class="rf-dot"></span>' +
        '<button class="rf-btn rf-min" title="Minimize" aria-label="Minimize">–</button></div>' +
        '<div id="rf-agent" class="rf-agent">' + lastAgentHTML + '</div>' +
        '<div class="rf-notes-wrap"><label for="rf-notes">Your notes</label>' +
        '<textarea id="rf-notes" placeholder="Type notes — the agent can read these…"></textarea></div>');

      // Event delegation: anything with data-rf-action reports back to the agent.
      root.addEventListener('click', onInteraction);
      root.addEventListener('change', onInteraction);

      const notes = root.querySelector('#rf-notes');
      const report = debounce(() => {
        pushEvent('note', notes.value, 'rf-notes');
        // Also persist to the call record so notes survive the tab.
        try { window.__cue.addNote(notes.value); } catch (_) {}
      }, 700);
      notes.addEventListener('input', report);

      // Minimize: collapse to just the title bar. No-op in PiP (window has its
      // own controls). Uses a data-rf-action so the agent also sees the toggle.
      const head = root.querySelector('.rf-head');
      const minBtn = root.querySelector('.rf-min');
      minBtn.addEventListener('click', (e) => {
        e.stopPropagation();               // don't start a drag
        const collapsed = root.classList.toggle('rf-collapsed');
        minBtn.textContent = collapsed ? '+' : '–';
        minBtn.title = collapsed ? 'Expand' : 'Minimize';
        pushEvent(collapsed ? 'minimize' : 'expand', '', 'rf-min');
      });

      // Drag by the title bar (overlay only). Switches the element from its
      // top/right anchor to explicit top/left on first grab, then follows the
      // pointer; clamped so it can't be dragged fully off-screen.
      makeDraggable(root, head, minBtn);
      return root;
    }

    function makeDraggable(root, handle, ...ignore) {
      let dragging = false, startX = 0, startY = 0, baseLeft = 0, baseTop = 0;
      handle.addEventListener('pointerdown', (e) => {
        if (root.classList.contains('rf-pip')) return;   // native window handles it
        if (ignore.some((el) => el === e.target || el.contains(e.target))) return;
        const r = root.getBoundingClientRect();
        baseLeft = r.left; baseTop = r.top;
        // Pin to left/top so movement is unambiguous regardless of initial anchor.
        root.style.left = baseLeft + 'px';
        root.style.top = baseTop + 'px';
        root.style.right = 'auto'; root.style.bottom = 'auto';
        startX = e.clientX; startY = e.clientY;
        dragging = true;
        handle.setPointerCapture(e.pointerId);
        e.preventDefault();
      });
      handle.addEventListener('pointermove', (e) => {
        if (!dragging) return;
        const w = root.offsetWidth, h = root.offsetHeight;
        let left = baseLeft + (e.clientX - startX);
        let top = baseTop + (e.clientY - startY);
        // Keep at least 40px of the panel on-screen on every edge.
        left = Math.max(-(w - 40), Math.min(left, window.innerWidth - 40));
        top = Math.max(0, Math.min(top, window.innerHeight - 40));
        root.style.left = left + 'px';
        root.style.top = top + 'px';
      });
      const end = (e) => { if (dragging) { dragging = false; try { handle.releasePointerCapture(e.pointerId); } catch (_) {} } };
      handle.addEventListener('pointerup', end);
      handle.addEventListener('pointercancel', end);
    }

    function ensureRoot() {
      if (!rootEl) rootEl = buildRoot();
      return rootEl;
    }

    function injectStyle(doc) {
      if (doc.getElementById('rf-canvas-style')) return;
      const st = doc.createElement('style');
      st.id = 'rf-canvas-style';
      st.textContent = CSS;
      (doc.head || doc.documentElement).appendChild(st);
    }

    function mountOverlay() {
      ensureRoot();
      injectStyle(document);
      rootEl.classList.remove('rf-pip');
      if (rootEl.ownerDocument !== document || !rootEl.isConnected) {
        document.body.appendChild(rootEl);
      }
    }

    async function popout() {
      ensureRoot();
      if (window.documentPictureInPicture && documentPictureInPicture.requestWindow) {
        try {
          pipWindow = await documentPictureInPicture.requestWindow({ width: 380, height: 560 });
          injectStyle(pipWindow.document);
          // Clear any drag/resize inline styles so PiP fills its own window
          // (inline styles would otherwise beat the .rf-pip stylesheet rules).
          ['left', 'top', 'right', 'bottom', 'width', 'height'].forEach((p) => rootEl.style.removeProperty(p));
          rootEl.classList.remove('rf-collapsed');
          rootEl.classList.add('rf-pip');
          pipWindow.document.body.style.margin = '0';
          pipWindow.document.body.appendChild(rootEl);
          pipWindow.addEventListener('pagehide', () => { pipWindow = null; mountOverlay(); });
          return { mode: 'pip' };
        } catch (err) {
          mountOverlay();
          return { mode: 'overlay', note: 'PiP needs a user gesture; fell back to overlay', error: String(err && err.message || err) };
        }
      }
      mountOverlay();
      return { mode: 'overlay', note: 'Document Picture-in-Picture unavailable in this browser' };
    }

    function render(html) {
      ensureRoot();
      lastAgentHTML = String(html == null ? '' : html);
      const agent = rootEl.querySelector('#rf-agent');
      if (agent) setHTML(agent, lastAgentHTML);
      if (!rootEl.isConnected) mountOverlay();  // auto-show on first render
      return { ok: true, mounted: pipWindow ? 'pip' : 'overlay' };
    }

    function getUIEvents(since = 0) {
      return events.filter((e) => e.id > since);
    }

    function close() {
      if (pipWindow) { try { pipWindow.close(); } catch (_) {} pipWindow = null; }
      if (rootEl && rootEl.isConnected) rootEl.remove();
      return { ok: true };
    }

    return { render, getUIEvents, popout, close };
  })();

  window.__cue = {
    version: '0.2.1',

    // ---- feedback canvas ----
    // render(html): write raw HTML into the canvas agent-region (auto-shows it).
    render(html) { return RF_CANVAS.render(html); },
    // popout(): upgrade the canvas into an always-on-top Picture-in-Picture
    // window. Needs a user gesture; falls back to an in-page overlay otherwise.
    popout() { return RF_CANVAS.popout(); },
    // getUIEvents(since): drain user interactions (clicks on [data-rf-action]
    // elements, notes typing) with id > since — same drain-loop shape as getCaptions.
    getUIEvents(since = 0) { return RF_CANVAS.getUIEvents(since); },
    // closeCanvas(): tear the canvas down.
    closeCanvas() { return RF_CANVAS.close(); },

    currentCallId() {
      const m = location.pathname.match(MEET_CODE_RE);
      return m ? m[1] : null;
    },

    listCalls() {
      return call('LIST_CALLS');
    },

    getCall(id) {
      return call('GET_CALL', { id: id || this.currentCallId() });
    },

    getCaptions(id, since = 0) {
      return call('GET_CAPTIONS_SINCE', { id: id || this.currentCallId(), since });
    },

    setTopic(text, id) {
      return call('SET_TOPIC', { id: id || this.currentCallId(), text });
    },

    addNote(text, id) {
      return call('ADD_NOTE', { id: id || this.currentCallId(), text });
    },

    deleteCall(id) {
      return call('DELETE_CALL', { id });
    },

    exportCall(id) {
      return call('EXPORT_CALL', { id: id || this.currentCallId() });
    },

    // One-shot backfill: walks every stored call and collapses rolling-partial
    // duplicates left over from older writes. Idempotent on clean data.
    normalize() {
      return call('NORMALIZE_ALL');
    },

    // Visual captions overlay control. Storage scrape continues regardless —
    // this only affects what the user sees on the Meet page.
    async hideCaptions() {
      await call('SET_SETTING', { key: 'captions_hidden', value: true });
      return { captions_hidden: true };
    },

    async showCaptions() {
      await call('SET_SETTING', { key: 'captions_hidden', value: false });
      return { captions_hidden: false };
    },

    async toggleCaptions() {
      const { value } = await call('GET_SETTING', { key: 'captions_hidden' });
      const next = !value;
      await call('SET_SETTING', { key: 'captions_hidden', value: next });
      return { captions_hidden: next };
    }
  };

  // Convenience: small log so Claude can verify the bridge is alive.
  console.log('[cue] bridge ready on', location.pathname,
              '— window.__cue.currentCallId() =', window.__cue.currentCallId());
})();
