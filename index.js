import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const processor = require('./build/Release/audio_capture.node');

export const startCapture = processor.startCapture;
export const stopCapture = processor.stopCapture;
export const setCallback = processor.setCallback;
export const getCaptureDiagnostics = processor.getCaptureDiagnostics;

// Backward-compatible alias.
export const getAudioData = setCallback;

export { PcmRingBuffer } from './pcm-ring-buffer.js';

export default {
    startCapture,
    stopCapture,
    setCallback,
    getCaptureDiagnostics,
    getAudioData,
};