// Input is resampled by AudioContext to 16 kHz. This node never routes captured PCM to the speakers.
class PCMCollector extends AudioWorkletProcessor {
  constructor() { super(); this.buffer = new Float32Array(16000 * 8); this.length = 0; this.port.onmessage = event => { if (event.data === 'flush') { this.flush(); this.port.postMessage({type:'flushed'}); } }; }
  flush() { if (this.length) { const pcm = this.buffer.slice(0,this.length); this.port.postMessage(pcm.buffer,[pcm.buffer]); this.length = 0; } }
  process(inputs,outputs) {
    const channels = inputs[0];
    if (channels?.length) for (let i=0;i<channels[0].length;i++) {
      let sample = 0;
      for (const channel of channels) sample += channel[i] / channels.length;
      this.buffer[this.length++] = Math.max(-1,Math.min(1,sample));
      if (this.length === this.buffer.length) this.flush();
    }
    for (const output of outputs) for (const channel of output) channel.fill(0);
    return true;
  }
}
registerProcessor('pcm-collector',PCMCollector);
