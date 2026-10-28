importScripts('native-background.js');

// Service worker. Owns chrome.storage.local.
// Schema: one record per call instance; meeting_code/series_id group recurring links.
// {
//   id: 'call-<UUID>',
//   meeting_code: 'hzs-oiur-mtq', series_id: 'hzs-oiur-mtq', independent_call: true,
//   url: 'https://meet.google.com/hzs-oiur-mtq',
//   title: '...',
//   started_at: <ms>,
//   ended_at: <ms>|null,
//   participants: [name, ...],
//   topic: '',
//   notes: [{t, text}, ...],
//   captions: [{t, speaker, text, rowId?}, ...]
// }
//
// Two caption write paths exist:
//   ADD_CAPTIONS  — legacy polling capture. The content script re-snapshots the
//                   whole panel, so the same utterance arrives many times and is
//                   deduped here by fuzzy collapse (findCollapseTarget).
//   UPSERT_CAPTIONS — event-based capture (v0.1.19+). The content script watches
//                   the caption DOM with a MutationObserver and tags each caption
//                   block with a stable client-generated `rowId`. One block == one
//                   row, so there is nothing to guess: we upsert by rowId. New
//                   rowId → append; seen rowId → update that row in place.

const STORAGE_PREFIX = 'call:';
const INDEX_KEY = 'call_index';
const callOperations = new Map();

async function withCallLock(key, operation) {
  const previous = callOperations.get(key) || Promise.resolve();
  // A failed write rejects its caller, but must not block later operations.
  const next = previous.catch(() => {}).then(operation);
  callOperations.set(key, next);
  try { return await next; }
  finally { if (callOperations.get(key) === next) callOperations.delete(key); }
}

async function getIndex() {
  const { [INDEX_KEY]: idx } = await chrome.storage.local.get(INDEX_KEY);
  return idx || [];
}

async function setIndex(idx) {
  await chrome.storage.local.set({ [INDEX_KEY]: idx });
}

async function getCall(id) {
  const key = STORAGE_PREFIX + id;
  const { [key]: rec } = await chrome.storage.local.get(key);
  return rec || null;
}

async function putCall(rec) {
  const key = STORAGE_PREFIX + rec.id;
  await chrome.storage.local.set({ [key]: rec });
  await withCallLock('index', async () => {
    const idx = await getIndex();
    if (!idx.includes(rec.id)) {
      idx.push(rec.id);
      await setIndex(idx);
    }
  });
}

let historyMigration;
async function migrateHistoricalCalls() {
  if(historyMigration)return historyMigration;
  historyMigration=(async()=>{
    const {call_records_v1:done}=await chrome.storage.local.get('call_records_v1');
    if(done)return;
    const original=await getIndex(),next=[],updates={},backups=[];
    for(const id of original){
      const record=await getCall(id);if(!record)continue;
      const calls=await materializeSavedCalls(record);
      if(calls.length>1){updates['call:'+id]={...record,source_backup:true};backups.push(id);}
      for(const call of calls){updates['call:'+call.id]=call;next.push(call.id);}
    }
    // Commit new records and the index together; source keys remain as backups.
    await chrome.storage.local.set({...updates,call_index:next,call_source_backups:backups,call_records_v1:true});
  })();
  try{await historyMigration;}finally{historyMigration=null;}
}
async function activeCallID(tabID,includeEnded=false) {
  await nativeReady;const id=autoCallTabs[`${tabID}:0`];if(!id)return null;
  const record=await getCall(id);return record && (includeEnded || !record.ended_at) ? id : null;
}
async function contentCallID(id,sender,create=false) {
  if(!sender.tab)return id;
  if(meetCodeFromURL(sender.url)!==id || meetCodeFromURL(sender.tab.url)!==id || !sender.documentId || (sender.documentLifecycle && sender.documentLifecycle!=='active'))return null;
  const current=await activeCallID(sender.tab.id,true);
  if(current) {
    const record=await getCall(current);
    if(record.capture_document_id!==sender.documentId)return null;
    if(meetCodeFromURL(record.url)===id)return current;
  }
  if(create)return (await nativeEnsureBrowserCall(sender)).id;
  return null;
}
async function ensureCall(id, meta) {
  return withCallLock(`call:${id}`, async () => {
    let rec = await getCall(id);
    if (!rec) {
      rec = {
        id,
        url: meta.url || `https://meet.google.com/${id}`,
        title: meta.title || '',
        started_at: Date.now(),
        ended_at: null,
        participants: meta.participants || [],
        topic: '',
        notes: [],
        captions: []
      };
      await putCall(rec);
    } else if (!rec.ended_at && meta.title && !rec.title) {
      rec.title = meta.title;
      await putCall(rec);
    }
    return rec;
  });
}

// Meet emits rolling-partial captions: one spoken utterance arrives as a
// sequence of progressively-longer strings from the same speaker. We collapse
// at write time — if the new text "looks like an extension of" the previous
// entry (same speaker), we replace the last entry instead of appending.
// Speaker change ends a run.
//
// Matching is case-insensitive and tolerates minor punctuation drift, because
// Meet auto-capitalises mid-utterance and toggles trailing punctuation as it
// rewrites earlier words.
function normalizeForMatch(s) {
  return (s || '').toLowerCase().replace(/[.,;:!?]/g, '').replace(/\s+/g, ' ').trim();
}

function isRollingExtensionOf(prev, next) {
  if (!prev || !next || prev.length === 0) return false;
  const a = normalizeForMatch(prev);
  const b = normalizeForMatch(next);
  if (a === b) return true;
  if (b.length < a.length) return false;
  // True rolling partial: full normalised previous text is a prefix of the new one.
  if (b.startsWith(a)) return true;
  // Looser fallback: the first ~60 chars of previous appear at the start of new.
  const probe = a.slice(0, Math.min(60, a.length));
  return probe.length >= 20 && b.startsWith(probe);
}

// Meet renders several caption blocks at once (one per active utterance), and
// our snapshot sends them as a batch, so consecutive same-speaker blocks are
// interleaved with other speakers'. Collapsing only against the very last row
// therefore misses the block being extended — the matching row may be several
// entries back. We instead scan a bounded window of recent rows for the block
// this caption belongs to. The window must be larger than Meet's on-screen
// caption scrollback panel (observed up to ~85 blocks re-emitted per tick on
// legacy captures), so the matching row is always in range. 100 collapses such
// data cleanly without over-merging distinct utterances; for live captures the
// content script no longer re-emits unchanged blocks, so batches are tiny and
// this only ever scans a handful of genuinely-active rows.
const COLLAPSE_WINDOW = 100;

// Find the recent row this caption continues/duplicates, or null to append.
//   'extend' — new text is a longer rolling-partial of an existing row → grow it
//   'dup'    — exact repeat, or a shorter stale partial of an existing row → drop
function findCollapseTarget(captions, speaker, text) {
  const start = Math.max(0, captions.length - COLLAPSE_WINDOW);
  for (let i = captions.length - 1; i >= start; i--) {
    const e = captions[i];
    if (e.speaker !== speaker) continue;
    if (e.text === text) return { idx: i, mode: 'dup' };
    if (isRollingExtensionOf(e.text, text)) return { idx: i, mode: 'extend' };
    // Reverse case: existing row is already longer and the incoming text is a
    // shorter prefix of it (a stale/again-scraped partial) — drop, don't regress.
    if (isRollingExtensionOf(text, e.text)) return { idx: i, mode: 'dup' };
  }
  return null;
}

async function addCaptions(id, captions) {
  return withCallLock(`call:${id}`, async () => {
    const rec = await getCall(id);
    if (!rec) return { added: 0 };
    let added = 0;
    let updated = 0;
    for (const c of captions) {
      const text = c.text;
      const speaker = c.speaker;
      if (!text || !speaker) continue;
      const tgt = findCollapseTarget(rec.captions, speaker, text);
      if (tgt) {
        if (tgt.mode === 'extend') {
          rec.captions[tgt.idx].text = text;
          rec.captions[tgt.idx].t = c.t || Date.now();
          updated++;
        }
        // 'dup' → drop silently
        continue;
      }
      rec.captions.push({ t: c.t || Date.now(), speaker, text });
      added++;
    }
    if (added || updated) await putCall(rec);
    return { added, updated, total: rec.captions.length };
  });
}

// Event-based write path. Each caption is keyed by a stable `rowId` minted by
// the content script when it first sees the caption block. Because the DOM block
// has a 1:1 relationship with an utterance, there is no re-scrape and no fuzzy
// matching: an unseen rowId is a new utterance (append), a seen rowId is the same
// utterance growing (update in place). `rowIndex` (rowId → array position) is kept
// on the record so repeated upserts stay O(1) and survive service-worker restarts.
async function upsertCaptions(id, captions) {
  return withCallLock(`call:${id}`, async () => {
    const rec = await getCall(id);
    if (!rec) return { added: 0, updated: 0 };
    if (!rec.rowIndex) {
      rec.rowIndex = {};
      rec.captions.forEach((c, i) => { if (c.rowId) rec.rowIndex[c.rowId] = i; });
    }
    let added = 0;
    let updated = 0;
    for (const c of captions) {
      if (!c.rowId || !c.text || !c.speaker) continue;
      const idx = rec.rowIndex[c.rowId];
      if (idx === undefined) {
        rec.captions.push({ t: c.t || Date.now(), speaker: c.speaker, text: c.text, rowId: c.rowId });
        rec.rowIndex[c.rowId] = rec.captions.length - 1;
        added++;
      } else {
        rec.captions[idx].text = c.text;
        rec.captions[idx].speaker = c.speaker;
        rec.captions[idx].t = c.t || Date.now();
        updated++;
      }
    }
    if (added || updated) await putCall(rec);
    return { added, updated, total: rec.captions.length };
  });
}

// Meet caps each caption block (~700-900 chars) and starts a fresh block for
// the same speaker when a turn runs long, so one spoken turn can span several
// stored rows. The chunks are clean continuations (no overlap), so we present a
// turn-level view by concatenating consecutive same-speaker rows. This is a
// READ-ONLY view: storage keeps one row per Meet block (faithful + reversible),
// and merging happens only on the way out (GET_CALL, EXPORT_CALL, captions
// queries) — never write it back, or read-modify-write paths would collapse the
// raw rows permanently. The turn keeps the first chunk's timestamp (turn start).
function mergeTurns(captions) {
  const out = [];
  for (const c of captions || []) {
    const last = out[out.length - 1];
    if (last && last.speaker === c.speaker) {
      last.text = (last.text + ' ' + c.text).trim();
    } else {
      out.push({ t: c.t, speaker: c.speaker, text: c.text });
    }
  }
  return out;
}

// Settings live in their own key (not under a call). Used today for
// captions_hidden (toggle the visual overlay on the Meet page while the
// scrape continues in the background).
const ALLOWED_SETTINGS = new Set(['captions_hidden']);

async function getSetting(key) {
  if (!ALLOWED_SETTINGS.has(key)) return { error: 'unknown setting: ' + key };
  const { [key]: value } = await chrome.storage.local.get(key);
  return { key, value: value === undefined ? null : value };
}

async function setSetting(key, value) {
  if (!ALLOWED_SETTINGS.has(key)) return { error: 'unknown setting: ' + key };
  await chrome.storage.local.set({ [key]: value });
  return { key, value };
}

// One-shot backfill — walks every stored call's caption list and collapses
// runs of same-speaker rolling partials using the same logic as the write
// path. Safe to run repeatedly; idempotent on already-normalised data.
async function normalizeAllCalls() {
  const idx = await getIndex();
  const summary = [];
  for (const id of idx) {
    await withCallLock(`call:${id}`, async () => {
      const rec = await getCall(id);
      if (!rec) return;
      const before = rec.captions.length;
      const out = [];
      for (const c of rec.captions) {
        const tgt = findCollapseTarget(out, c.speaker, c.text);
        if (tgt) {
          if (tgt.mode === 'extend') {
            out[tgt.idx].text = c.text;
            out[tgt.idx].t = c.t;
          }
          // 'dup' → drop
          continue;
        }
        out.push(c);
      }
      rec.captions = out;
      await putCall(rec);
      summary.push({ id, title: rec.title, before, after: out.length, removed: before - out.length });
    });
  }
  return summary;
}

async function updateMeta(id, meta) {
  return withCallLock(`call:${id}`, async () => {
    const rec = await getCall(id);
    if (!rec) return null;
    // A reused Meet tab can publish its next meeting's metadata after this call ends.
    if (rec.ended_at) return rec;
    if (meta.title && (!genericCallTitle(meta.title) || genericCallTitle(rec.title))) rec.title = meta.title;
    if (meta.participants) rec.participants = [...new Set([...meta.participants,...(rec.speaker_roster || []).map(person=>person.name)])];
    if (meta.ended_at) rec.ended_at = meta.ended_at;
    await putCall(rec);
    return rec;
  });
}

async function setTopic(id, text) {
  return withCallLock(`call:${id}`, async () => {
    const rec = await getCall(id);
    if (!rec) return null;
    rec.topic = text || '';
    await putCall(rec);
    return rec;
  });
}

async function addNote(id, text) {
  return withCallLock(`call:${id}`, async () => {
    const rec = await getCall(id);
    if (!rec) return null;
    rec.notes.push({ t: Date.now(), text });
    await putCall(rec);
    return rec;
  });
}

async function listCalls() {
  const idx = await getIndex();
  const out = [];
  for (const id of idx) {
    const rec = await getCall(id);
    if (rec) {
      out.push({
        id: rec.id,
        url: rec.url,
        series_id: rec.series_id,
        meeting_code: rec.meeting_code,
        independent_call: rec.independent_call,
        title: rec.title,
        topic: rec.topic,
        started_at: rec.started_at,
        ended_at: rec.ended_at,
        participants: rec.participants,
        caption_count: rec.captions.length,
        note_count: rec.notes.length
      });
    }
  }
  out.sort((a, b) => (b.started_at || 0) - (a.started_at || 0));
  return out;
}

async function getCaptionsSince(id, since) {
  const rec = await getCall(id);
  if (!rec) return [];
  const sinceT = Number(since) || 0;
  return rec.captions.filter(c => c.t > sinceT);
}

async function deleteCall(id) {
  return withCallLock(`call:${id}`, async () => {
    const key = STORAGE_PREFIX + id;
    await chrome.storage.local.remove(key);
    await withCallLock('index', async () => {
      const idx = await getIndex();
      await setIndex(idx.filter(x => x !== id));
    });
    return { deleted: true };
  });
}

// Export a call as a downloaded JSON file. Persists the transcript outside
// chrome.storage.local so it survives extension reinstalls, profile resets,
// or moving to a different machine.
function safeFilename(s) {
  return (s || 'untitled').toLowerCase().replace(/[^a-z0-9-]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 80) || 'call';
}

async function exportCall(id) {
  const rec = await getCall(id);
  if (!rec) return { error: 'call not found: ' + id };
  const startedISO = rec.started_at ? new Date(rec.started_at).toISOString().slice(0, 10) : 'undated';
  const topicSlug = safeFilename(rec.topic) || rec.id;
  const filename = `Cue/${startedISO}_${topicSlug}_${rec.id}.json`;
  // Export the turn-level view (consecutive same-speaker blocks concatenated),
  // not the raw per-block rows. Build a copy so the stored record is untouched.
  const exported = { ...rec, captions: mergeTurns(rec.captions) };
  delete exported.rowIndex;
  const dataUrl = 'data:application/json;charset=utf-8,' + encodeURIComponent(JSON.stringify(exported, null, 2));
  const downloadId = await chrome.downloads.download({
    url: dataUrl,
    filename,
    saveAs: false,
    conflictAction: 'uniquify'
  });
  return { downloadId, filename };
}

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (msg.type?.startsWith('NATIVE_')) return false;
  (async () => {
    try {
      switch (msg.type) {
        case 'ACTIVE_CALL':
          sendResponse({id:await activeCallID(msg.tabId)});
          break;
        case 'ENSURE_CALL': {
          const id=await contentCallID(msg.id,sender);
          sendResponse(id ? await ensureCall(id,msg.meta || {}) : {waiting:true});
        }
          break;
        case 'ADD_CAPTIONS':
          sendResponse(await addCaptions(await contentCallID(msg.id,sender,true), msg.captions || []));
          break;
        case 'UPSERT_CAPTIONS':
          sendResponse(await upsertCaptions(await contentCallID(msg.id,sender,true), msg.captions || []));
          break;
        case 'UPDATE_META':
          sendResponse(await updateMeta(await contentCallID(msg.id,sender), msg.meta || {}));
          break;
        case 'SET_TOPIC':
          sendResponse(await setTopic(msg.id, msg.text || ''));
          break;
        case 'ADD_NOTE':
          sendResponse(await addNote(msg.id, msg.text || ''));
          break;
        case 'LIST_CALLS':
          sendResponse(await listCalls());
          break;
        case 'GET_CALL': {
          const id=await contentCallID(msg.id,sender);
          const rec = id ? await getCall(id) : null;
          sendResponse(rec ? { ...rec, captions: mergeTurns(rec.captions) } : rec);
          break;
        }
        case 'GET_CAPTIONS_SINCE':
          sendResponse(mergeTurns(await getCaptionsSince(await contentCallID(msg.id,sender), msg.since || 0)));
          break;
        case 'DELETE_CALL':
          sendResponse(await deleteCall(msg.id));
          break;
        case 'EXPORT_CALL':
          sendResponse(await exportCall(msg.id));
          break;
        case 'NORMALIZE_ALL':
          sendResponse(await normalizeAllCalls());
          break;
        case 'GET_SETTING':
          sendResponse(await getSetting(msg.key));
          break;
        case 'SET_SETTING':
          sendResponse(await setSetting(msg.key, msg.value));
          break;
        default:
          sendResponse({ error: 'unknown message type: ' + msg.type });
      }
    } catch (e) {
      sendResponse({ error: String(e && e.message || e) });
    }
  })();
  return true;
});
