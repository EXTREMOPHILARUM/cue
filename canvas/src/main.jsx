import React, { useState } from 'react';
import { createRoot } from 'react-dom/client';
import { Renderer } from '@openuidev/react-lang';
import { library, prompt, feedback } from './library.jsx';

export function Canvas() {
  const [coaching, setCoaching] = useState(null);
  const [invalid, setInvalid] = useState(false);
  React.useEffect(() => {
    window.callAssistant = { update: value => { window.callAssistant.currentID = value?.id; setInvalid(false); setCoaching(value); }, prompt, currentID: null };
    window.webkit?.messageHandlers?.ready?.postMessage({ prompt });
    const observer = new ResizeObserver(() => window.webkit?.messageHandlers?.resize?.postMessage({ height: document.querySelector('main').getBoundingClientRect().height }));
    observer.observe(document.querySelector('main'));
    return () => { observer.disconnect(); delete window.callAssistant; };
  }, []);
  return <main><header><div className="brand"><svg className="brand-mark" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" aria-hidden="true"><path d="M4 10v4m4-8v12m4-15v18m4-15v12m4-8v4" /></svg><div><strong>Cue</strong><span>Live coaching</span></div></div><div className="panel-controls"><button className="panel-close" title="Collapse coaching" aria-label="Collapse coaching panel" onClick={() => feedback('collapse', '')}><svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true"><path d="m3 10.5 5-5 5 5" /></svg></button><button className="panel-close" title="Hide coaching" aria-label="Hide coaching panel" onClick={() => feedback('hide', '')}><svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" aria-hidden="true"><path d="m4 4 8 8m0-8-8 8" /></svg></button></div></header>{!coaching ? <div className="empty"><p className="eyebrow">Room to think</p><h1>Ready when you are.</h1><p>A useful question. A timely reminder.<br />Your next suggestion will appear here.</p><div className="empty-note">Keep your attention on the conversation.</div></div> : invalid ? <article role="status"><h1>{coaching.fallback || 'This suggestion could not be displayed.'}</h1><p>Canvas format error. Ask the assistant for a new suggestion.</p></article> : <Renderer key={coaching.id} library={library} response={coaching.program} isStreaming={false} onError={errors => { if (errors.length) { setInvalid(true); feedback('render-error', errors.map(e => e.code).slice(0,10)); } }} />}</main>;
}
createRoot(document.getElementById('root')).render(<Canvas />);
