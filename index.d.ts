export interface PcmFrameMeta {
	sampleRate: number;
	channels: number;
	frameCount: number;
	sequence: number;
	timestampMs: number;
	fromSystem: boolean;
	source: 'system' | 'fallback';
}

export interface CaptureDiagnostics {
	permissionPreflight: boolean;
	usingSystemCapture: boolean;
	lastStartSystemCaptureSucceeded: boolean;
	systemFrameCallbacks: number;
	fallbackFrameCallbacks: number;
	sckAudioSampleCallbacks: number;
	sckScreenSampleCallbacks: number;
	sckAudioDroppedInvalidOrNotReady: number;
	sckAudioDroppedMissingFormat: number;
	sckAudioDroppedZeroChannelsOrFrames: number;
	sckAudioDroppedBufferListError: number;
	queuedFrameDepth: number;
	queueMaxDepth: number;
	queueDroppedFrames: number;
	queueUnderrunFrames: number;
	lastError: string;
}

export type PcmCallback = (pcm: Float32Array, meta: PcmFrameMeta) => void;

export declare function startCapture(): void;
export declare function stopCapture(): void;
export declare function setCallback(callback: PcmCallback): void;
export declare function getCaptureDiagnostics(): CaptureDiagnostics;

/**
 * Registers the PCM callback invoked from the native capture loop.
 *
 * Note: this mirrors the current JS entrypoint name.
 */
export declare function getAudioData(callback: PcmCallback): void;

export declare class PcmRingBuffer {
	constructor(capacitySamples?: number);
	get capacity(): number;
	get availableSamples(): number;
	push(samples: Float32Array): void;
	read(sampleCount: number): Float32Array;
}

declare const _default: {
	startCapture: typeof startCapture;
	stopCapture: typeof stopCapture;
	setCallback: typeof setCallback;
	getCaptureDiagnostics: typeof getCaptureDiagnostics;
	getAudioData: typeof getAudioData;
};

export default _default;
