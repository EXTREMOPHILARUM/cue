// Read copies of connected WebRTC audio tracks. Never stop, replace, or mute the meeting's tracks.
(() => {
  if(window.__callAssistantMedia || typeof RTCPeerConnection!=='function')return;
  window.__callAssistantMedia=true;
  const Original=window.RTCPeerConnection, peers=new Set(), taps=new Map(), streams=new WeakMap();
  let enabled=false, active=false, endedTimer,presenceLostAt=null;
  const post=(event,extra={})=>window.postMessage({source:'call-assistant-media',event,...extra},location.origin);
  const speakers=typeof CallAssistantMeetSpeakers==='function' && location.hostname==='meet.google.com'
    ? new CallAssistantMeetSpeakers(roster=>{if(active)post('participants',{participants:router?router.roster():roster});},message=>post('warning',{message})):null;
  const router=speakers && typeof CallAssistantMeetRouter==='function'?new CallAssistantMeetRouter(speakers):null;
  let rosterKey='';
  if(speakers && typeof window.fetch==='function'){
    const originalFetch=window.fetch;
    window.fetch=function(...args){const result=Reflect.apply(originalFetch,this,args);void result.then(response=>speakers.observeFetch(response)).catch(error=>speakers.warn(error));return result;};
  }
  function encoded(buffer){const bytes=new Uint8Array(buffer);let binary='';for(let i=0;i<bytes.length;i+=8192)binary+=String.fromCharCode(...bytes.subarray(i,i+8192));return btoa(binary);}
  // Adapted from Kuali capture-policy.js, Copyright 2026 Kuali contributors, Apache-2.0.
  // License and attribution: docs/licenses/kuali-apache-2.0.txt and kuali-NOTICE.txt.
  function meetPrimaryOpusPayload(data, metadata = {}, codecs = []) {
    const bytes = data instanceof Uint8Array
      ? data
      : (ArrayBuffer.isView(data)
        ? new Uint8Array(data.buffer, data.byteOffset, data.byteLength)
        : new Uint8Array(data));
    const codecByPayloadType = new Map();
    for (const codec of codecs || []) {
      const payloadType = Number(codec?.payloadType);
      const mimeType = String(codec?.mimeType || "").trim().toLocaleLowerCase();
      if (Number.isInteger(payloadType) && mimeType) codecByPayloadType.set(payloadType, mimeType);
    }
    const metadataPayloadType = Number(metadata?.payloadType);
    const metadataMimeType = String(metadata?.mimeType || "").trim().toLocaleLowerCase();
    const outerMimeType = metadataMimeType
      || codecByPayloadType.get(metadataPayloadType)
      || "";
    if (!outerMimeType) {
      // Older encoded-transform implementations exposed no RTP codec metadata,
      // so keep the raw-Opus fallback only when no negotiation table exists.
      // With a populated table an unknown PT usually means renegotiation; the
      // caller must refresh getParameters() instead of feeding RED to Opus.
      if (!codecByPayloadType.size) return bytes;
      if (!Number.isInteger(metadataPayloadType)) {
        const negotiatedMimeTypes = new Set(codecByPayloadType.values());
        if (negotiatedMimeTypes.size === 1 && negotiatedMimeTypes.has("audio/opus")) return bytes;
      }
      return null;
    }
    if (outerMimeType === "audio/opus") return bytes;
    if (outerMimeType !== "audio/red") return null;

    let offset = 0;
    let redundantLength = 0;
    let primaryPayloadType = null;
    while (offset < bytes.length) {
      const header = bytes[offset];
      const follows = (header & 0x80) !== 0;
      const payloadType = header & 0x7f;
      if (!follows) {
        primaryPayloadType = payloadType;
        offset += 1;
        break;
      }
      if (offset + 4 > bytes.length) return null;
      redundantLength += ((bytes[offset + 2] & 0x03) << 8) | bytes[offset + 3];
      offset += 4;
    }
    const payloadOffset = offset + redundantLength;
    if (primaryPayloadType === null || payloadOffset >= bytes.length) return null;
    const negotiatedPrimary = codecByPayloadType.get(primaryPayloadType) || "";
    const hasNegotiatedOpus = [...codecByPayloadType.values()].includes("audio/opus");
    if ((negotiatedPrimary && negotiatedPrimary !== "audio/opus")
      || (!negotiatedPrimary && hasNegotiatedOpus)) return null;
    return bytes.subarray(payloadOffset);
  }

  // RFC 6716 TOC duration; decoder outputs may split a packet into several AudioData objects.
  function opusDuration(payload){
    const config=payload[0]>>3,code=payload[0]&3;
    const frame=config>=16?2500*(1<<(config&3)):config>=12?10000*(1<<(config&1)):[10000,20000,40000,60000][config&3];
    const count=code===0?1:code===3?(payload[1] || 0)&63:2,duration=frame*count;
    return count && duration<=120000?duration:0;
  }
  function decoderFailure(tap,reason){
    const pending=tap.identities.size;
    tap.drainPending();tap.flush();clearTimeout(tap.decoderTimer);tap.decoderTimer=null;
    const decoder=tap.decoder;tap.decoder=null;if(decoder?.state!=='closed')decoder?.close();
    tap.identities.clear();tap.encodedQueue=[];tap.useEncoded=undefined;tap.decoderRetryAt=Date.now()+1000;
    tap.decodeErrors=(tap.decodeErrors || 0)+1;
    // Missing packets cannot be reconstructed from a silent native receiver; retain the gap in the next archive frame.
    tap.discontinuities=[...(tap.discontinuities || []).slice(-7),{observedAt:Date.now(),reason,pendingPackets:pending}];
    post('warning',{message:'Remote capture discontinuity: '+reason+'; retrying with native audio.',pendingPackets:pending});
  }
  function jsonBytes(value){
    let bytes=0;for(const ch of JSON.stringify(value)){const point=ch.codePointAt(0);bytes+=point<128?1:point<2048?2:point<65536?3:4;}return bytes;
  }
  function release(track){
    const tap=taps.get(track);if(!tap)return;
    taps.delete(track);clearTimeout(tap.decoderTimer);tap.drainPending?.();tap.flush();if(tap.decoder?.state!=='closed')tap.decoder?.close();
    if(tap.reader)void tap.reader.cancel().catch(()=>{});
    tap.node?.disconnect();tap.input?.disconnect();
    if(tap.player){tap.player.pause();tap.player.srcObject=null;}
    tap.clone?.stop();if(tap.context)void tap.context.close();
  }
  function capture(track,source,peer,receiver){
    if(taps.has(track))return;
    const tap={peer,receiver,gate:false,identities:new Map()};taps.set(track,tap);
    let samples=[],offset=0,startedAt=Date.now();
    tap.flush=()=>{const samplesSaved=samples.length>0;if(samplesSaved)post('audio',{frame:{id:crypto.randomUUID(),startedAt,source,trackID:track.id,...tap.binding,
      ...(tap.firstEvidence?{mappingHistory:tap.history,packetRange:{firstObservedAt:tap.firstEvidence.observedAt,lastObservedAt:tap.lastEvidence.observedAt,firstRtpTimestamp:tap.firstEvidence.rtpTimestamp,lastRtpTimestamp:tap.lastEvidence.rtpTimestamp}}:{}),
      ...(tap.discontinuities?.length?{captureDiscontinuities:tap.discontinuities}:{}),captureMethod:tap.useEncoded?'encoded-opus':tap.reader?'track-processor':'webaudio',encodedFrames:tap.encodedFrames||0,decodeErrors:tap.decodeErrors||0,pcm:encoded(new Float32Array(samples).buffer)}});samples=[];tap.firstEvidence=null;tap.history=[];tap.evidenceKey=null;if(samplesSaved)tap.discontinuities=[];startedAt=Date.now();};
    const consume=(data,sampleRate,encodedCopy=false,identity,buffered=false)=>{
      if(tap.useEncoded!==undefined && tap.useEncoded!==encodedCopy)return;
      if(!buffered && (!enabled || !active || !tap.gate || !track.enabled || track.muted)){tap.flush();offset=0;return;}
      const binding=identity || (source==='local'?speakers?.local():null) || {speaker:source==='local'?'You':'Unknown',attribution:source==='local'?'local':'unresolved'};
      const {sourceEvidence,...identityFields}=binding;
      const key=JSON.stringify({...identityFields,synchronizationSource:sourceEvidence?.synchronizationSource,generation:sourceEvidence?.generation});
      if(tap.bindingKey!==key){tap.flush();tap.binding=identityFields;tap.bindingKey=key;}
      const ratio=sampleRate/16000;
      const evidenceKey=sourceEvidence?JSON.stringify({...sourceEvidence,observedAt:undefined,encodedTimestamp:undefined,rtpTimestamp:undefined,vote:sourceEvidence.vote?{firstAt:sourceEvidence.vote.firstAt}:undefined}):null;
      if(sourceEvidence && tap.evidenceKey!==evidenceKey && tap.history?.length && (tap.history.length>=16 || jsonBytes([...tap.history,{...sourceEvidence,sampleOffset:samples.length}])>32000))tap.flush();
      while(offset<data.length){
        if(!samples.length || tap.evidenceKey!==evidenceKey){
          const evidence=sourceEvidence?{...sourceEvidence,observedAt:sourceEvidence.observedAt+offset/sampleRate*1000}:null;
          if(!samples.length){startedAt=evidence?.observedAt || Date.now();tap.firstEvidence=evidence;}
          if(evidence){(tap.history ||= []).push({...evidence,sampleOffset:samples.length});tap.evidenceKey=evidenceKey;}
        }
        if(sourceEvidence && (samples.length===0 || offset<ratio))tap.lastEvidence={...sourceEvidence,observedAt:Math.max(sourceEvidence.observedAt+Math.max(0,offset)/sampleRate*1000,tap.firstEvidence.observedAt)};
        const i=Math.floor(offset),fraction=offset-i;
        const value=Math.max(-1,Math.min(1,data[i]*(1-fraction)+data[Math.min(i+1,data.length-1)]*fraction));samples.push(value);offset+=ratio;
        if(samples.length>=64000)tap.flush();
      }
      offset-=data.length;
    };
    tap.consume=consume;
    tap.pending=[];
    tap.drainPending=confirmed=>{
      clearTimeout(tap.pendingTimer);tap.pendingTimer=null;
      for(const item of tap.pending){const identity=confirmed?{...confirmed,sourceEvidence:{...item.identity.sourceEvidence,method:confirmed.attribution,reason:'buffered-sustained-activity',vote:confirmed.sourceEvidence.vote,confirmedAt:confirmed.sourceEvidence.observedAt}}:item.identity;consume(item.mono,item.sampleRate,item.encodedCopy,identity,true);}
      tap.pending=[];tap.pendingSeconds=0;tap.pendingCandidate=null;
    };
    tap.pumpDecoder=()=>{
      if(tap.pumping)return;tap.pumping=true;
      const decoder=tap.decoder;
      try {
        while(tap.decoder===decoder && decoder?.state==='configured' && decoder.decodeQueueSize<50 && tap.encodedQueue?.length)decoder.decode(tap.encodedQueue.shift());
      }catch(error){if(tap.decoder===decoder)decoderFailure(tap,error.message);}
      finally {tap.pumping=false;}
    };
    tap.watchDecoder=()=>{
      clearTimeout(tap.decoderTimer);tap.decoderTimer=null;
      const oldest=tap.identities.values().next().value;
      if(oldest)tap.decoderTimer=setTimeout(()=>{if(taps.get(track)===tap && tap.identities.size)decoderFailure(tap,'decoder-stalled');},Math.max(1,1000-(Date.now()-oldest.submittedAt)));
    };
    tap.route=(mono,sampleRate,record,encodedCopy=true)=>{
      if(!enabled || !active || !tap.gate || !track.enabled || track.muted){tap.drainPending();consume(mono,sampleRate,encodedCopy);return;}
      if(!router || !record?.context){tap.drainPending();const fallback=record?.fallback || {speaker:'Unknown',attribution:'unresolved'};if(router)fallback.sourceEvidence={version:1,...router.context({},track.id),method:fallback.attribution,reason:'decoder-metadata-miss'};consume(mono,sampleRate,encodedCopy,fallback);return;}
      let peak=0;for(const value of mono)peak=Math.max(peak,Math.abs(value));
      const decision=router.resolve(record.context,peak),candidate=record.context.contributors.join(',')+':'+decision.candidate;
      if(tap.pending.length && tap.pendingCandidate!==candidate && decision.action!=='rebind')tap.drainPending();
      if(decision.action==='hold'){
        if(tap.pending.length && tap.pendingCandidate!==candidate)tap.drainPending();
        tap.pendingCandidate=candidate;tap.pending.push({mono,sampleRate,encodedCopy,identity:decision.identity});tap.pendingSeconds=(tap.pendingSeconds || 0)+mono.length/sampleRate;
        if(!tap.pendingTimer)tap.pendingTimer=setTimeout(()=>tap.drainPending(),1500);
        if(tap.pending.length>=64 || tap.pendingSeconds>=1.5)tap.drainPending();
      }else{
        if(decision.action==='rebind' && tap.pendingCandidate===candidate)tap.drainPending(decision.identity);else tap.drainPending();
        consume(mono,sampleRate,encodedCopy,decision.identity);
      }
    };
    tap.ingest=(data,sampleRate)=>{
      if(source!=='remote' || !router){consume(data,sampleRate);return;}
      let metadata={};
      try {
        const now=performance.now(),fresh=values=>(values || []).filter(v=>Number.isFinite(v.timestamp) && now>=v.timestamp && now-v.timestamp<=150);
        metadata={contributingSources:fresh(tap.receiver?.getContributingSources?.()),synchronizationSource:fresh(tap.receiver?.getSynchronizationSources?.())[0]?.source};
      }catch(error){if(!tap.metadataWarning){tap.metadataWarning=true;post('warning',{message:'Receiver identity metadata unavailable; audio stays recorded as Unknown.'});}}
      tap.route(data,sampleRate,{context:router.context(metadata,track.id)},false);
    };
    try {
      if(source==='remote' && typeof MediaStreamTrackProcessor==='function' && typeof AudioData==='function'){
        // Attach at ontrack, before Meet configures the receiver; late WebAudio taps can stay silent.
        tap.reader=new MediaStreamTrackProcessor({track}).readable.getReader();
        void (async()=>{
          try {
            while(taps.get(track)===tap){
              const {value:audio,done}=await tap.reader.read();if(done)break;
              try {
                if(taps.get(track)!==tap)break;
                const mono=new Float32Array(audio.numberOfFrames),plane=new Float32Array(audio.numberOfFrames);
                for(let channel=0;channel<audio.numberOfChannels;channel++){
                  audio.copyTo(plane,{planeIndex:channel,format:'f32-planar'});
                  for(let i=0;i<mono.length;i++)mono[i]+=plane[i]/audio.numberOfChannels;
                }
                tap.ingest(mono,audio.sampleRate);
              } finally {audio.close();}
            }
          } catch(error){if(taps.get(track)===tap)post('error',{message:error.message});}
        })();
      } else {
        tap.context=new AudioContext();
        if(source==='local')tap.clone=track.clone();
        const originalStream=streams.get(track);
        const stream=source==='remote' ? (originalStream?.getAudioTracks().length===1 ? originalStream : new MediaStream([track])) : new MediaStream([tap.clone]);
        if(source==='remote'){
          tap.player=new Audio();tap.player.srcObject=stream;tap.player.volume=0;
          void tap.player.play().catch(error=>{if(taps.get(track)===tap)post('error',{message:error.message});});
        }
        tap.input=tap.context.createMediaStreamSource(stream);
        tap.node=tap.context.createScriptProcessor(4096,1,1);
        tap.input.connect(tap.node);tap.node.connect(tap.context.destination);
        tap.node.onaudioprocess=event=>{event.outputBuffer.getChannelData(0).fill(0);tap.ingest(event.inputBuffer.getChannelData(0),tap.context.sampleRate);};
        void tap.context.resume().catch(error=>{if(taps.get(track)===tap)post('error',{message:error.message});});
      }
      if(source==='remote' && tap.reader){
        const originalStream=streams.get(track);
        tap.player=new Audio();tap.player.srcObject=originalStream?.getAudioTracks().length===1 ? originalStream : new MediaStream([track]);tap.player.volume=0;
        void tap.player.play().catch(error=>{if(taps.get(track)===tap)post('error',{message:error.message});});
      }
      track.addEventListener('ended',()=>release(track),{once:true});
    } catch(error){release(track);throw error;}
  }
  function observeEncoded(receiver,frame){
    const tap=taps.get(receiver.track);
    if(!tap || !enabled || !active || !tap.gate || Date.now()<(tap.decoderRetryAt||0))return;
    tap.encodedFrames=(tap.encodedFrames||0)+1;
    const metadata=frame.getMetadata?.() || {};
    const payload=meetPrimaryOpusPayload(frame.data,metadata,receiver.getParameters().codecs || []);
    if(!payload?.length)return;
    if(!tap.decoder || tap.decoder.state==='closed'){
      const decoder=tap.decoder=new AudioDecoder({
        output(audio){
          try {
            if(taps.get(receiver.track)!==tap || tap.decoder!==decoder || !enabled || !active)return;
            if(tap.useEncoded!==true){tap.drainPending();tap.flush();tap.useEncoded=true;}
            const mono=new Float32Array(audio.numberOfFrames),plane=new Float32Array(audio.numberOfFrames);
            for(let channel=0;channel<audio.numberOfChannels;channel++){
              audio.copyTo(plane,{planeIndex:channel,format:'f32-planar'});
              for(let i=0;i<mono.length;i++)mono[i]+=plane[i]/audio.numberOfChannels;
            }
            const entry=[...tap.identities].find(([time,record])=>audio.timestamp>=time && audio.timestamp<time+record.duration);
            const record=entry?.[1];
            if(entry && audio.timestamp+audio.numberOfFrames/audio.sampleRate*1000000>=entry[0]+record.duration-1)tap.identities.delete(entry[0]);
            tap.watchDecoder();
            tap.route(mono,audio.sampleRate,record);
            tap.pumpDecoder();
          } finally {audio.close();}
        },
        error(error){if(taps.get(receiver.track)===tap && tap.decoder===decoder)decoderFailure(tap,error.message);}
      });
      decoder.addEventListener?.('dequeue',()=>{if(tap.decoder===decoder)tap.pumpDecoder();});
      tap.decoder.configure({codec:'opus',sampleRate:48000,numberOfChannels:2});tap.identities.clear();tap.encodedQueue=[];tap.timestamp=0;
    }
    // Copy before Meet transfers the original buffer; never retain or alter its frame.
    if(tap.identities.size>=100){decoderFailure(tap,'decoder-backpressure');return;}
    const duration=opusDuration(payload);
    if(!duration){decoderFailure(tap,'invalid-opus-duration');return;}
    tap.identities.set(tap.timestamp,{duration,submittedAt:Date.now(),context:router?.context(metadata,receiver.track.id,frame.timestamp),fallback:speakers?.identity(metadata) || {speaker:'Unknown',attribution:'unresolved'}});
    tap.watchDecoder();
    tap.encodedQueue.push(new EncodedAudioChunk({type:'key',timestamp:tap.timestamp,data:payload.slice()}));tap.timestamp+=duration;tap.pumpDecoder();
  }
  if(typeof RTCRtpReceiver==='function' && typeof RTCRtpReceiver.prototype.createEncodedStreams==='function' && typeof AudioDecoder==='function'){
    const originalStreams=RTCRtpReceiver.prototype.createEncodedStreams;
    RTCRtpReceiver.prototype.createEncodedStreams=function(...args){
      const result=Reflect.apply(originalStreams,this,args);
      if(this.track?.kind!=='audio' || !result?.readable?.pipeThrough)return result;
      const receiver=this;
      return {...result,readable:result.readable.pipeThrough(new TransformStream({transform(frame,controller){
        try{observeEncoded(receiver,frame);}catch(error){const tap=taps.get(receiver.track);if(tap)decoderFailure(tap,error.message);}
        controller.enqueue(frame);
      }}))};
    };
  }
  function scan(){
    const wanted=new Map();
    for(const peer of peers){
      if(peer.connectionState==='closed'){peers.delete(peer);continue;}
      if(peer.connectionState!=='connected' && !['connected','completed'].includes(peer.iceConnectionState))continue;
      for(const receiver of peer.getReceivers())if(receiver.track?.kind==='audio' && receiver.track.readyState==='live')wanted.set(receiver.track,{source:'remote',peer,receiver});
      for(const sender of peer.getSenders())if(sender.track?.kind==='audio' && sender.track.readyState==='live')wanted.set(sender.track,{source:'local',sender,peer});
    }
    const presence=router?router.presence():null;
    if(active && presence===false){if(presenceLostAt===null)presenceLostAt=Date.now();if(Date.now()-presenceLostAt>=2000){for(const tap of taps.values()){tap.drainPending();tap.flush();}active=false;post('end');}}else presenceLostAt=null;
    if(wanted.size && !active && presence!==false){clearTimeout(endedTimer);active=true;post('start',{presenceConfirmed:presence===true});if(speakers)post('participants',{participants:router?router.roster():speakers.roster()});}
    if(active && router){const participants=router.roster(),key=JSON.stringify(participants);if(key!==rosterKey){rosterKey=key;post('participants',{participants});}}
    if(enabled)for(const [track,info]of wanted){try{capture(track,info.source,info.peer,info.receiver);const tap=taps.get(track);tap.gate=!info.sender || info.sender.getParameters().encodings?.some(e=>e.active!==false)!==false;}catch(error){post('error',{message:error.message});}}
    for(const [track,tap]of taps){if(!wanted.has(track))tap.gate=false;if(!enabled || (!wanted.has(track) && (!tap.reader || ['closed','failed'].includes(tap.peer.connectionState) || track.readyState==='ended')))release(track);}
    if(!wanted.size && active && presence===null && !peers.size){clearTimeout(endedTimer);endedTimer=null;active=false;post('end');}
    if(!wanted.size && active && presence===null && !endedTimer)endedTimer=setTimeout(()=>{endedTimer=null;if(!taps.size && active){active=false;post('end');}},3000);
    if(wanted.size && endedTimer){clearTimeout(endedTimer);endedTimer=null;}
  }
  window.RTCPeerConnection=new Proxy(Original,{construct(target,args,newTarget){const peer=Reflect.construct(target,args,newTarget);peers.add(peer);if(speakers){peer.addEventListener('datachannel',event=>speakers.observe(event.channel));if(typeof peer.createDataChannel==='function'){const originalChannel=peer.createDataChannel;peer.createDataChannel=function(...channelArgs){const channel=Reflect.apply(originalChannel,this,channelArgs);speakers.observe(channel);return channel;};}}peer.addEventListener('connectionstatechange',scan);peer.addEventListener('track',event=>{if(event.streams?.[0])streams.set(event.track,event.streams[0]);if(enabled && event.track.kind==='audio' && typeof MediaStreamTrackProcessor==='function' && typeof AudioData==='function'){try{capture(event.track,'remote',peer,event.receiver);}catch(error){post('error',{message:error.message});}}scan();});return peer;}});
  window.addEventListener('message',event=>{if(event.source!==window || event.origin!==location.origin || event.data?.source!=='call-assistant-control')return;enabled=event.data.enabled===true;scan();});
  window.addEventListener('pagehide',()=>{enabled=false;for(const track of taps.keys())release(track);if(active)post('end');});
  setInterval(scan,500);
})();
