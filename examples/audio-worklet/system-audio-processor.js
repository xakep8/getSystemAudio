class SystemAudioProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    this.queue = [];
    this.readOffset = 0;

    this.port.onmessage = (event) => {
      const payload = event.data;
      if (!(payload instanceof Float32Array)) {
        return;
      }
      this.queue.push(payload);
    };
  }

  process(_, outputs) {
    const output = outputs[0];
    const channelData = output[0];

    channelData.fill(0);

    let writeIndex = 0;
    while (writeIndex < channelData.length && this.queue.length > 0) {
      const current = this.queue[0];
      const available = current.length - this.readOffset;
      const needed = channelData.length - writeIndex;
      const toCopy = Math.min(available, needed);

      channelData.set(current.subarray(this.readOffset, this.readOffset + toCopy), writeIndex);

      writeIndex += toCopy;
      this.readOffset += toCopy;

      if (this.readOffset >= current.length) {
        this.queue.shift();
        this.readOffset = 0;
      }
    }

    return true;
  }
}

registerProcessor('system-audio-processor', SystemAudioProcessor);
