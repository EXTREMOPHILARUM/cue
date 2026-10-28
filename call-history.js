function meetCodeFromURL(value) {
  try {const url=new URL(value);return url.protocol==='https:' && url.hostname==='meet.google.com' ? url.pathname.match(/^\/(?:meet\/)?([a-z]{3}-[a-z]{4}-[a-z]{3})(?:\/|$)/)?.[1] || null:null;} catch {return null;}
}
function genericCallTitle(value) {
  const title=String(value || '').replace(/^Meet\s*[–—-]\s*/i,'').trim();
  return !title || /^(meet|untitled(?: call)?|[a-z]{3}-[a-z]{4}-[a-z]{3})$/i.test(title);
}
// Group by meeting series; titles are only a fallback for older records.
function groupSavedCalls(calls, nameForCall) {
  const groups = new Map();
  for (const call of calls) {
    const title = nameForCall(call).replace(/^Meet\s*[–—-]\s*/i, '').trim();
    const key = call.series_id ? 'series:' + call.series_id : title && !/^(untitled(?: call)?|meet|[a-z]{3}-[a-z]{4}-[a-z]{3})$/i.test(title)
      ? 'title:' + title.toLocaleLowerCase().replace(/\s+/g, ' ')
      : 'id:' + (call.record_id || call.id);
    if (!groups.has(key)) groups.set(key, { key, title: title || call.record_id || call.id, calls: [] });
    groups.get(key).calls.push(call);
  }
  for (const group of groups.values()) group.calls.sort((a,b) => (b.started_at || 0) - (a.started_at || 0));
  return [...groups.values()].sort((a,b) => (b.calls[0].started_at || 0) - (a.calls[0].started_at || 0));
}

// shortcut: historical boundaries are inferred from silence; prefer explicit call events for new recordings.
const SESSION_GAP_MS = 60 * 60 * 1000;
function splitSavedCall(record) {
  const timestamp = value => Number.isFinite(value) && value > 0 && value <= 8640000000000000;
  const dated = (record.captions || []).filter(c => timestamp(c.t)).slice().sort((a,b) => a.t-b.t);
  const undated = (record.captions || []).filter(c => !timestamp(c.t));
  const batches = [];
  for (const caption of dated) {
    const last = batches.at(-1);
    if (!last || caption.t-last.at(-1).t >= SESSION_GAP_MS) batches.push([caption]);
    else last.push(caption);
  }
  if (undated.length) batches.push(undated);
  if (batches.length <= 1) return [{...record, started_at:dated[0]?.t || record.started_at, captions: dated.concat(undated), caption_count: (record.captions || []).length}];
  return batches.map(captions => {
    const start = timestamp(captions[0].t) ? captions[0].t : null;
    const end = start ? captions.at(-1).t : null;
    return {...record, id:record.id+'~'+(start || 'undated'), record_id:record.id,
      inferred_session:true, started_at:start, ended_at:end, captions,
      caption_count:captions.length,
      notes:(record.notes || []).filter(note => start ? timestamp(note.t) && note.t>=start && note.t<=end : !timestamp(note.t))};
  });
}

async function materializeSavedCalls(record) {
  if (record.independent_call) return [record];
  const calls=splitSavedCall(record);
  const series=record.series_id || record.meeting_code || record.id;
  if(calls.length===1)return [{...calls[0],independent_call:true,meeting_code:series,series_id:series}];
  const digest=await crypto.subtle.digest('SHA-256',new TextEncoder().encode('chrome-'+record.id));
  const key=[...new Uint8Array(digest).slice(0,16)].map(byte=>byte.toString(16).padStart(2,'0')).join('');
  return calls.map(call=>{
    const result={...call,id:`call-${key}-${record.captions.indexOf(call.captions[0])}`,source_record_id:record.id,independent_call:true,meeting_code:series,series_id:series};
    delete result.record_id;delete result.inferred_session;delete result.rowIndex;
    return result;
  });
}
