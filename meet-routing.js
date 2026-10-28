/* Capture-time routing informed by Kuali page-capture.js, Copyright 2026 Kuali
 * contributors, Apache-2.0. See docs/licenses/kuali-NOTICE.txt. */
(() => {
  const clean=value=>String(value || '').trim();
  const bounded=value=>Array.from(clean(value)).slice(0,120).join('');
  const source=value=>/^\d+$/.test(String(value)) && String(value)!=='42' ? String(value):'';
  const speaking="[data-is-speaking='true'],[data-speaking='true'],.Oaajhc,.HX2H7,.wEsLMd,.OgVli";
  globalThis.CallAssistantMeetRouter=class {
    constructor(speakers) {this.speakers=speakers;this.routes=new Map();this.claims=new Map();this.dom=new Map();this.active=[];this.scanned=-Infinity;}
    canonical(id) {
      const seen=new Set();
      while(id && !seen.has(id) && seen.size<8){seen.add(id);const parent=this.speakers.users.get(id)?.parentDeviceId;if(!parent)return id;id=parent;}
      return '';
    }
    scan(now) {
      if(now-this.scanned<250)return;
      this.scanned=now;this.active=[];this.selfPresent=false;
      if(typeof document==='undefined')return;
      const active=new Map();
      const visible=node=>node && node.getClientRects().length>0 && getComputedStyle(node).visibility!=='hidden' && getComputedStyle(node).display!=='none';
      for(const tile of [...document.querySelectorAll('[data-participant-id]')].slice(0,500)) {
        const raw=clean(tile.getAttribute('data-participant-id')),id=this.canonical(raw);if(!id || id.length>500)continue;
        const user=this.speakers.users.get(id),previous=this.dom.get(id);
        const marker=tile.querySelector('[data-self-name]');
        const rawName=marker?.getAttribute('data-self-name') || tile.getAttribute('data-display-name') || tile.getAttribute('data-participant-name') || tile.querySelector('span.notranslate')?.textContent;
        const name=bounded((raw!==id && ((previous?.rawID===id && previous.name) || user?.displayName || user?.fullName)) || rawName || user?.displayName || user?.fullName || previous?.name);
        const isSelf=user?.isCurrentUser===true || !!marker || tile.matches('[data-is-self="true"],[data-self-name]');
        if(isSelf && visible(tile))this.selfPresent=true;
        if(name && (this.dom.size<500 || this.dom.has(id)))this.dom.set(id,{id,name,isSelf,seenAt:now,rawID:raw===id?id:previous?.rawID || raw});
        const activity=tile.matches(speaking)?tile:tile.querySelector(speaking);
        if(name && !isSelf && visible(tile) && visible(activity))active.set(id,{id,name,isSelf:false});
      }
      this.active=[...active.values()];
    }
    presence(now=Date.now()) {
      this.scan(now);
      return typeof document==='undefined' || typeof CallAssistantMeetPresence!=='function'?null:CallAssistantMeetPresence(document,this.selfPresent);
    }
    roster(now=Date.now()) {
      this.scan(now);
      const result=new Map();
      for(const person of this.speakers.roster()){const id=this.canonical(person.id);if(!id)continue;const parent=this.speakers.users.get(id);result.set(id,{id,name:bounded(parent?.displayName || parent?.fullName || person.name),isSelf:parent?.isCurrentUser===true || person.isSelf || result.get(id)?.isSelf===true});}
      for(const [id,p] of this.dom)if(now-p.seenAt<5000)result.set(id,{id,name:p.name,isSelf:p.isSelf || result.get(id)?.isSelf===true});
      return [...result.values()];
    }
    context(metadata={},trackID='',encodedTimestamp=null,now=Date.now()) {
      const roster=new Map(this.roster(now).map(p=>[p.id,p]));
      const contributors=[...new Set((metadata.contributingSources || []).map(v=>source(typeof v==='object'?v?.source:v)).filter(Boolean))].slice(0,32).sort();
      const output=contributors.length===1?this.speakers.sources.get(contributors[0]):null;
      const id=output && !output.disabled?this.canonical(output.deviceId):'';
      const person=roster.get(id);
      return {observedAt:now,trackID,encodedTimestamp:Number.isFinite(encodedTimestamp)?encodedTimestamp:null,
        rtpTimestamp:Number.isFinite(metadata.rtpTimestamp)?metadata.rtpTimestamp:null,
        synchronizationSource:source(metadata.synchronizationSource),contributors,
        generation:this.speakers.generation || 0,active:this.active.slice(0,32).map(p=>({...p})),
        protocol:output?{rawDeviceID:output.deviceId,participantID:id,speaker:person?.name || '',isSelf:person?.isSelf===true,disabled:!!output.disabled}:null,
        protocolError:this.speakers.lastError || ''};
    }
    resolve(context,peak) {
      const c=context,now=c.observedAt;
      const identity=(person,method,reason,vote)=>({speaker:person?.name || 'Unknown',...(person?.id?{participantID:person.id}:{}),
        attribution:method,contributors:c.contributors,
        sourceEvidence:{version:1,...c,method,reason,...(vote?{vote:{firstAt:vote.firstAt,lastAt:vote.lastAt,samples:vote.samples}}:{})}});
      const unresolved=reason=>({action:'send',identity:identity(null,'unresolved',reason)});
      if(c.contributors.length!==1)return {action:'send',identity:identity(c.contributors.length>1?{name:'Multiple speakers'}:null,c.contributors.length>1?'mixed':'unresolved','non-exclusive-contributors')};
      const key=c.trackID+':'+c.contributors[0];
      let route=this.routes.get(key);
      if(!route || route.generation!==c.generation){if(this.routes.size>=1000)this.routes.delete(this.routes.keys().next().value);route={generation:c.generation};this.routes.set(key,route);}
      if(now<(route.lastAt ?? -Infinity))return unresolved('out-of-order-context');route.lastAt=now;
      if(c.protocol?.isSelf)return unresolved('self-owned-remote-source');
      const protocol=c.protocol && !c.protocol.disabled && !c.protocol.isSelf && c.protocol.speaker?{id:c.protocol.participantID,name:c.protocol.speaker}:null;
      const rawProtocol=c.protocol?.rawDeviceID || '';
      if(route.protocolRaw!==undefined && route.protocolRaw!==rawProtocol){route.bound=null;route.overridden=null;route.vote=null;}
      route.protocolRaw=rawProtocol;
      const usable=protocol && (!route.overridden || route.overridden!==c.protocol.rawDeviceID);
      const candidate=c.active.length===1?c.active[0]:null;
      if(!candidate || peak<.01){route.vote=null;return usable?{action:'send',identity:identity(protocol,'meet-rtp','protocol-output')}:unresolved(candidate?'quiet-unconfirmed-audio':'no-exclusive-active-participant');}
      if(usable && protocol.id===candidate.id){route.vote=null;this.claims.set(candidate.id,{key,at:now});return {action:'send',identity:identity(protocol,'meet-rtp','protocol-and-activity-agree')};}
      const claim=this.claims.get(candidate.id);
      if(claim && claim.key!==key && now>=claim.at && now-claim.at<750){route.vote=null;return unresolved('participant-already-claimed-by-another-source');}
      if(route.bound?.id===candidate.id && now-(route.boundAt || 0)<=750){route.boundAt=now;this.claims.set(candidate.id,{key,at:now});return {action:'send',identity:identity(candidate,'meet-activity','sustained-exclusive-activity',route.confirmation)};}
      const old=route.vote,continuing=old?.id===candidate.id && now>=old.lastAt && now-old.lastAt<=250;
      const vote=route.vote=continuing?{...old,lastAt:now,samples:old.samples+1}:{id:candidate.id,firstAt:now,lastAt:now,samples:1};
      if(vote.samples<8 || vote.lastAt-vote.firstAt<600)return {action:'hold',candidate:candidate.id,identity:identity(null,'unresolved','awaiting-sustained-activity',vote)};
      route.bound={...candidate};route.boundAt=now;route.overridden=c.protocol?.rawDeviceID || '';route.confirmation={...vote};route.vote=null;
      this.claims.set(candidate.id,{key,at:now});
      return {action:'rebind',candidate:candidate.id,identity:identity(candidate,'meet-activity','sustained-exclusive-activity',vote)};
    }
  };
})();
