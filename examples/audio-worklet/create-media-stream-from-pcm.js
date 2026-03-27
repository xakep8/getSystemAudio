export async function createMediaStreamFromPcm(options = {}) {
  const sampleRate = options.sampleRate ?? 48000;

  const context = new AudioContext({ sampleRate });
  await context.audioWorklet.addModule('./system-audio-processor.js');

  const processorNode = new AudioWorkletNode(context, 'system-audio-processor', {
    numberOfInputs: 0,
    numberOfOutputs: 1,
    outputChannelCount: [1],
  });

  const destination = context.createMediaStreamDestination();
  processorNode.connect(destination);

  return {
    stream: destination.stream,
    pushPcm(pcm) {
      if (!(pcm instanceof Float32Array)) {
        throw new TypeError('pcm must be a Float32Array');
      }
      processorNode.port.postMessage(pcm);
    },
    async close() {
      processorNode.disconnect();
      await context.close();
    },
  };
}
