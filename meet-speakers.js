/* Copyright 2026 Kuali contributors · SPDX-License-Identifier: Apache-2.0
 * Adapted from browser-extension/src/meet-protocol.js: bounded decoding added.
 * License and attribution: docs/licenses/kuali-apache-2.0.txt and kuali-NOTICE.txt.
 */
(() => {
  const decoder = new TextDecoder();

  class ProtoReader {
    constructor(bytes) {
      this.bytes = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
      this.pos = 0;
    }

    get done() {
      return this.pos >= this.bytes.length;
    }

    varint() {
      let value = 0;
      let shift = 0;
      while (this.pos < this.bytes.length && shift < 35) {
        const byte = this.bytes[this.pos++];
        value += (byte & 0x7f) * (2 ** shift);
        if ((byte & 0x80) === 0) return value;
        shift += 7;
      }
      // Values such as caption timestamps can exceed Number's exact integer
      // range. Kuali does not consume them here, but the reader still needs to
      // advance over every remaining varint byte safely.
      while (this.pos < this.bytes.length && (this.bytes[this.pos++] & 0x80) !== 0) {}
      return value;
    }

    bytesField() {
      const length = this.varint();
      const end = this.pos + length;
      if(end>this.bytes.length)throw new Error("Truncated Meet protobuf field");
      const value = this.bytes.subarray(this.pos, end);
      this.pos = end;
      return value;
    }

    string() {
      return decoder.decode(this.bytesField());
    }

    skip(wireType) {
      if (wireType === 0) {
        this.varint();
      } else if (wireType === 1) {
        this.pos = Math.min(this.bytes.length, this.pos + 8);
      } else if (wireType === 2) {
        this.bytesField();
      } else if (wireType === 5) {
        this.pos = Math.min(this.bytes.length, this.pos + 4);
      } else {
        throw new Error(`Unsupported protobuf wire type ${wireType}`);
      }
    }
  }

  function fields(bytes, visit) {
    const reader = new ProtoReader(bytes);
    while (!reader.done) {
      const tag = reader.varint();
      if (!tag) break;
      const field = tag >>> 3;
      const wire = tag & 7;
      if (!visit(field, wire, reader)) reader.skip(wire);
    }
  }

  function nested(bytes, fieldNumber) {
    let result = null;
    fields(bytes, (field, wire, reader) => {
      if (field === fieldNumber && wire === 2) {
        result = reader.bytesField();
        return true;
      }
      return false;
    });
    return result;
  }

  function decodeUser(bytes) {
    const user = {
      deviceId: "",
      fullName: "",
      displayName: "",
      profilePicture: null,
      status: 0,
      parentDeviceId: null,
      isCurrentUser: false,
      isHost: false,
    };
    fields(bytes, (field, wire, reader) => {
      if (wire === 2 && [1, 2, 3, 7, 21, 29].includes(field)) {
        const value = reader.string();
        if (field === 1) user.deviceId = value;
        else if (field === 2) user.fullName = value;
        else if (field === 3) user.profilePicture = value || null;
        else if (field === 7) user.isCurrentUser = !!value;
        else if (field === 21) user.parentDeviceId = value || null;
        else if (field === 29) user.displayName = value;
        return true;
      }
      if (wire === 0 && (field === 4 || field === 34)) {
        const value = reader.varint();
        if (field === 4) user.status = value;
        else user.isHost = value !== 0;
        return true;
      }
      return false;
    });
    return user.deviceId ? user : null;
  }

  function decodeUserListWrapper(bytes) {
    const users = [];
    fields(bytes, (field, wire, reader) => {
      if (field === 2 && wire === 2) {
        const user = decodeUser(reader.bytesField());
        if (user) users.push(user);
        return true;
      }
      return false;
    });
    return users;
  }

  function decodeDeviceOutput(bytes) {
    const output = {
      deviceId: "",
      streamId: "",
      outputType: 0,
      disabled: false,
    };
    fields(bytes, (field, wire, reader) => {
      if (wire === 0 && field === 2) {
        output.outputType = reader.varint();
        return true;
      }
      if (wire === 2 && (field === 4 || field === 6 || field === 10)) {
        if (field === 4) output.streamId = reader.string();
        else if (field === 6) output.deviceId = reader.string();
        else {
          const status = reader.bytesField();
          fields(status, (statusField, statusWire, statusReader) => {
            if (statusField === 1 && statusWire === 0) {
              output.disabled = statusReader.varint() !== 0;
              return true;
            }
            return false;
          });
        }
        return true;
      }
      return false;
    });
    return output.deviceId && output.streamId ? output : null;
  }

  function decodeCollectionBytes(bytes) {
    const root = nested(bytes, 1);
    const body = root && nested(root, 2);
    if (!body) return { users: [], deviceOutputs: [] };

    const users = [];
    const deviceOutputs = [];
    fields(body, (field, wire, reader) => {
      if (wire !== 2 || (field !== 3 && field !== 13)) return false;
      const wrapper = reader.bytesField();
      if (field === 3) {
        fields(wrapper, (deviceField, deviceWire, deviceReader) => {
          if (deviceField === 2 && deviceWire === 2) {
            const output = decodeDeviceOutput(deviceReader.bytesField());
            if (output) deviceOutputs.push(output);
            return true;
          }
          return false;
        });
      } else {
        fields(wrapper, (combinedField, combinedWire, combinedReader) => {
          if (combinedField === 1 && combinedWire === 2) {
            users.push(...decodeUserListWrapper(combinedReader.bytesField()));
            return true;
          }
          return false;
        });
      }
      return true;
    });
    return { users, deviceOutputs };
  }

  async function toBytes(data) {
    if (data instanceof Uint8Array) return data;
    if (data instanceof ArrayBuffer) return new Uint8Array(data);
    if (ArrayBuffer.isView(data)) return new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
    if (data instanceof Blob) return new Uint8Array(await data.arrayBuffer());
    throw new TypeError("Unsupported Meet collections payload");
  }

  async function inflate(bytes, format) {
    if (typeof DecompressionStream !== "function") {
      throw new Error("This Chrome version does not expose DecompressionStream");
    }
    const reader = new Blob([bytes]).stream().pipeThrough(new DecompressionStream(format)).getReader();
    const chunks=[];let size=0;
    try {
      while(true){const {value,done}=await reader.read();if(done)break;size+=value.length;if(size>8*1024*1024)throw new Error("Meet collection exceeds limit");chunks.push(value);}
    } finally {await reader.cancel();}
    const result=new Uint8Array(size);let offset=0;for(const chunk of chunks){result.set(chunk,offset);offset+=chunk.length;}return result;
  }

  async function decodeCollectionPacket(data) {
    if((data?.size ?? data?.byteLength ?? 0)>2*1024*1024)throw new Error("Meet packet exceeds limit");
    const bytes = await toBytes(data);
    let decoded;
    if(bytes[0]===0x1f && bytes[1]===0x8b)decoded=await inflate(bytes,"gzip");
    else if((bytes[0]&15)===8 && (bytes[0]>>>4)<=7 && ((bytes[0]<<8)+bytes[1])%31===0)decoded=await inflate(bytes,"deflate");
    else if(bytes[0]===0x0a)decoded=bytes;
    else throw new Error("Unsupported Meet participant packet format");
    return decodeCollectionBytes(decoded);
  }

  /** Preserve data-channel order even when packet decoding is asynchronous. */
  function orderedAsyncHandler(handler) {
    let tail = Promise.resolve();
    return (...args) => {
      const result = tail.then(() => handler(...args));
      tail = result.catch(() => {});
      return result;
    };
  }

  /**
   * Keep one current output per raw Meet device and a reverse source lookup.
   * When Meet moves a device to another CSRC, remove the old reverse alias only
   * if that device still owns it; a newer participant may already have reused it.
   */
  function indexDeviceOutput(byDevice, bySource, output) {
    if (!(byDevice instanceof Map) || !(bySource instanceof Map)) {
      throw new TypeError("Meet device output indexes must be Maps");
    }
    const deviceId = String(output?.deviceId || "");
    const streamId = String(output?.streamId || "");
    const outputType = Number(output?.outputType || 0);
    if (!deviceId || !streamId || !outputType) return null;

    const key = `${outputType}:${deviceId}`;
    const previous = byDevice.get(key);
    let staleSource = "";
    if (previous?.streamId && previous.streamId !== streamId) {
      staleSource = previous.streamId;
      if (bySource.get(staleSource) === previous) bySource.delete(staleSource);
    }
    const indexed = { ...output, deviceId, streamId, outputType };
    const displaced = bySource.get(streamId);
    if (displaced && displaced !== previous) {
      const displacedKey = `${displaced.outputType}:${displaced.deviceId}`;
      if (byDevice.get(displacedKey) === displaced) byDevice.delete(displacedKey);
    }
    byDevice.set(key, indexed);
    bySource.set(streamId, indexed);
    return { indexed, staleSource };
  }

  function decodeSyncUsersBase64(value) {
    if(typeof value!=="string" || value.length>4*1024*1024)throw new Error("Meet roster exceeds limit");
    const binary = atob(value.trim());
    const bytes = new Uint8Array(binary.length);
    for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
    const wrapper = nested(bytes, 2);
    const userList = wrapper && nested(wrapper, 2);
    return userList ? decodeUserListWrapper(userList) : [];
  }

  globalThis.KualiMeetProtocol = Object.freeze({
    decodeCollectionBytes,
    decodeCollectionPacket,
    decodeSyncUsersBase64,
    orderedAsyncHandler,
    indexDeviceOutput,
  });
})();

(() => {
  const protocol=globalThis.KualiMeetProtocol;
  // Keep even four-byte Unicode names within the native 500-byte field limit.
  const boundedName=value=>Array.from(String(value || '')).slice(0,120).join('');
  globalThis.CallAssistantMeetSpeakers=class {
    constructor(onRoster=()=>{},onWarning=()=>{}) {
      this.generation=0;this.lastError='';this.users=new Map();this.outputs=new Map();this.sources=new Map();this.channels=new WeakSet();this.onRoster=onRoster;this.onWarning=onWarning;
      let pending=0;
      const ordered=protocol.orderedAsyncHandler(async ({data,generation})=>{if(generation!==this.generation)return;try{const update=await protocol.decodeCollectionPacket(data);if(generation===this.generation)this.update(update);}catch(error){if(generation!==this.generation)return;this.sources.clear();this.outputs.clear();this.generation++;this.lastError=String(error.message).slice(0,200);this.warn(error);}});
      this.readCollection=data=>{if(pending>=32){this.sources.clear();this.outputs.clear();this.generation++;this.lastError='Meet speaker queue exceeds limit';this.warn(new Error(this.lastError));return Promise.resolve();}pending++;return ordered({data,generation:this.generation}).finally(()=>pending--);};
    }
    warn(error){if(!this.warned){this.warned=true;this.onWarning('Some speaker names unavailable; audio capture continues. '+error.message);}}
    update({users=[],deviceOutputs=[]}) {
      for(const user of users){if(user.deviceId && user.deviceId.length<=500 && (this.users.size<500 || this.users.has(user.deviceId)))this.users.set(user.deviceId,{deviceId:user.deviceId,fullName:boundedName(user.fullName),displayName:boundedName(user.displayName),isCurrentUser:user.isCurrentUser===true,parentDeviceId:user.parentDeviceId || null});}
      for(const output of deviceOutputs){if(output.outputType===1 && output.deviceId?.length<=500 && output.streamId?.length<=200 && (this.outputs.size<1000 || this.outputs.has('1:'+output.deviceId)))protocol.indexDeviceOutput(this.outputs,this.sources,output);}
      const roster=this.roster(),key=JSON.stringify(roster);
      if(key!==this.rosterKey){this.rosterKey=key;this.onRoster(roster);}
    }
    roster(){return [...this.users.values()].map(user=>({id:user.deviceId,name:(user.displayName || user.fullName || '').slice(0,500),isSelf:user.isCurrentUser===true})).filter(user=>user.name);}
    local(){const user=this.roster().find(user=>user.isSelf);return user?{participantID:user.id,speaker:user.name,attribution:'meet-rtp'}:{speaker:'You',attribution:'local'};}
    identity(metadata={}) {
      const contributors=[...new Set((metadata.contributingSources || []).map(value=>String(typeof value==='object'?value?.source:value)).filter(value=>/^\d+$/.test(value) && value!=='42'))].slice(0,32).sort();
      if(contributors.length!==1)return {speaker:contributors.length>1?'Multiple speakers':'Unknown',attribution:contributors.length>1?'mixed':'unresolved',contributors};
      const output=this.sources.get(contributors[0]),user=output && !output.disabled && this.users.get(output.deviceId);
      return output && !output.disabled?{participantID:output.deviceId,speaker:(user?.displayName || user?.fullName || 'Unknown').slice(0,500),attribution:'meet-rtp',contributors}:{speaker:'Unknown',attribution:'unresolved',contributors};
    }
    observe(channel){
      if(!channel || channel.label!=='collections' || this.channels.has(channel))return;
      this.channels.add(channel);channel.addEventListener('message',event=>{void this.readCollection(event.data);});
    }
    observeFetch(response) {
      if(response.url!=='https://meet.google.com/$rpc/google.rtc.meetings.v1.MeetingSpaceService/SyncMeetingSpaceCollections')return;
      void (async()=>{
        const reader=response.clone().body.getReader();let size=0;const chunks=[];
        try{while(true){const {value,done}=await reader.read();if(done)break;size+=value.length;if(size>4*1024*1024)throw new Error('Meet roster exceeds limit');chunks.push(value);}}
        finally{await reader.cancel();}
        const bytes=new Uint8Array(size);let offset=0;for(const chunk of chunks){bytes.set(chunk,offset);offset+=chunk.length;}
        this.update({users:protocol.decodeSyncUsersBase64(new TextDecoder().decode(bytes))});
      })().catch(error=>this.warn(error));
    }
  };
})();
