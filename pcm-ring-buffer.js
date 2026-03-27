export class PcmRingBuffer {
  constructor(capacitySamples = 48000) {
    if (!Number.isInteger(capacitySamples) || capacitySamples <= 0) {
      throw new TypeError('capacitySamples must be a positive integer');
    }

    this._capacity = capacitySamples;
    this._buffer = new Float32Array(capacitySamples);
    this._readIndex = 0;
    this._writeIndex = 0;
    this._available = 0;
  }

  get capacity() {
    return this._capacity;
  }

  get availableSamples() {
    return this._available;
  }

  push(samples) {
    if (!(samples instanceof Float32Array)) {
      throw new TypeError('samples must be a Float32Array');
    }

    if (samples.length >= this._capacity) {
      const tail = samples.subarray(samples.length - this._capacity);
      this._buffer.set(tail, 0);
      this._readIndex = 0;
      this._writeIndex = 0;
      this._available = this._capacity;
      return;
    }

    const overflow = Math.max(0, this._available + samples.length - this._capacity);
    if (overflow > 0) {
      this._readIndex = (this._readIndex + overflow) % this._capacity;
      this._available -= overflow;
    }

    const firstWrite = Math.min(samples.length, this._capacity - this._writeIndex);
    this._buffer.set(samples.subarray(0, firstWrite), this._writeIndex);

    const remaining = samples.length - firstWrite;
    if (remaining > 0) {
      this._buffer.set(samples.subarray(firstWrite), 0);
    }

    this._writeIndex = (this._writeIndex + samples.length) % this._capacity;
    this._available += samples.length;
  }

  read(sampleCount) {
    if (!Number.isInteger(sampleCount) || sampleCount <= 0) {
      throw new TypeError('sampleCount must be a positive integer');
    }

    const out = new Float32Array(sampleCount);
    const toRead = Math.min(sampleCount, this._available);

    if (toRead > 0) {
      const firstRead = Math.min(toRead, this._capacity - this._readIndex);
      out.set(this._buffer.subarray(this._readIndex, this._readIndex + firstRead), 0);

      const remaining = toRead - firstRead;
      if (remaining > 0) {
        out.set(this._buffer.subarray(0, remaining), firstRead);
      }

      this._readIndex = (this._readIndex + toRead) % this._capacity;
      this._available -= toRead;
    }

    return out;
  }
}
