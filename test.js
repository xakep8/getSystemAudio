import { createRequire } from 'node:module';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const require = createRequire(import.meta.url);
const addon = require('./build/Release/audio_capture.node');

function assert(condition, message) {
	if (!condition) {
		throw new Error(message);
	}
}

async function waitFor(conditionFn, timeoutMs, intervalMs = 50) {
	const start = Date.now();

	while (Date.now() - start < timeoutMs) {
		if (conditionFn()) {
			return;
		}
		await new Promise((resolve) => setTimeout(resolve, intervalMs));
	}

	throw new Error(`Timed out after ${timeoutMs}ms`);
}

async function run() {
	console.log('Loading addon and validating API...');

	assert(typeof addon.setCallback === 'function', 'Missing function: setCallback');
	assert(typeof addon.startCapture === 'function', 'Missing function: startCapture');
	assert(typeof addon.stopCapture === 'function', 'Missing function: stopCapture');
	assert(typeof addon.getCaptureDiagnostics === 'function', 'Missing function: getCaptureDiagnostics');

	let callbackCount = 0;
	let sawFloat32Array = false;
	let sawNonEmptyChunk = false;
	let sawMeta = false;
	let sawSourceMeta = false;
	let sampleRate = 48000;
	let channels = 1;
	let systemFrames = 0;
	let fallbackFrames = 0;
	const pcmChunks = [];
	const captureDurationMs = 10000;

	addon.setCallback((pcm, meta) => {
		callbackCount += 1;

		if (pcm instanceof Float32Array) {
			sawFloat32Array = true;
		}

		if (pcm && typeof pcm.length === 'number' && pcm.length > 0) {
			sawNonEmptyChunk = true;
		}

		if (
			meta &&
			typeof meta.sampleRate === 'number' &&
			typeof meta.channels === 'number' &&
			typeof meta.frameCount === 'number' &&
			typeof meta.sequence === 'number' &&
			typeof meta.timestampMs === 'number' &&
			typeof meta.fromSystem === 'boolean' &&
			(meta.source === 'system' || meta.source === 'fallback')
		) {
			sawMeta = true;
			sawSourceMeta = true;
			sampleRate = meta.sampleRate;
			channels = meta.channels;

			if (meta.fromSystem) {
				systemFrames += meta.frameCount;
			} else {
				fallbackFrames += meta.frameCount;
			}
		}

		if (pcm instanceof Float32Array && pcm.length > 0) {
			// Copy the data so it remains valid after callback returns.
			pcmChunks.push(new Float32Array(pcm));
		}
	});

	console.log('Callback set successfully. Starting capture...');
	addon.startCapture();

	await waitFor(() => callbackCount > 0, 5000);
	await new Promise((resolve) => setTimeout(resolve, captureDurationMs));

	console.log('Stopping capture...');
	addon.stopCapture();

	assert(callbackCount > 0, 'No callback frames were received');
	assert(sawFloat32Array, 'Callback payload was not Float32Array');
	assert(sawMeta, 'Callback metadata was missing or invalid');
	assert(sawSourceMeta, 'Callback source diagnostics were missing');

	if (!sawNonEmptyChunk) {
		console.warn('Received callbacks, but all chunks were empty');
	}

	const totalSamples = pcmChunks.reduce((sum, chunk) => sum + chunk.length, 0);
	assert(totalSamples > 0, 'No PCM samples were captured');

	const merged = new Float32Array(totalSamples);
	let offset = 0;
	for (const chunk of pcmChunks) {
		merged.set(chunk, offset);
		offset += chunk.length;
	}

	const outputDir = path.join(process.cwd(), 'recordings');
	fs.mkdirSync(outputDir, { recursive: true });

	const rawPath = path.join(outputDir, 'system_audio_test.f32le');
	const mp3Path = path.join(outputDir, 'system_audio_test.mp3');

	const rawBuffer = Buffer.from(merged.buffer, merged.byteOffset, merged.byteLength);
	fs.writeFileSync(rawPath, rawBuffer);

	const ffmpegCheck = spawnSync('ffmpeg', ['-version'], { stdio: 'ignore' });
	if (ffmpegCheck.status !== 0) {
		throw new Error(
			`ffmpeg is not available in PATH. PCM was saved to ${rawPath}. Install ffmpeg to generate MP3.`,
		);
	}

	const ffmpeg = spawnSync(
		'ffmpeg',
		[
			'-y',
			'-f',
			'f32le',
			'-ar',
			String(sampleRate),
			'-ac',
			String(channels),
			'-i',
			rawPath,
			'-codec:a',
			'libmp3lame',
			'-q:a',
			'2',
			mp3Path,
		],
		{ encoding: 'utf8' },
	);

	if (ffmpeg.status !== 0) {
		throw new Error(`ffmpeg conversion failed:\n${ffmpeg.stderr || ffmpeg.stdout}`);
	}

	console.log('N-API test passed');
	console.log(`Total callbacks received: ${callbackCount}`);
	console.log(`Captured ${totalSamples} samples (${channels} ch @ ${sampleRate} Hz)`);
	console.log(`Frame source breakdown: system=${systemFrames}, fallback=${fallbackFrames}`);
	console.log(`Raw PCM: ${rawPath}`);
	console.log(`Playable MP3: ${mp3Path}`);

	if (systemFrames === 0) {
		console.warn('No system frames were captured. Recording is fallback silence only.');
	}
}

run().catch((error) => {
	try {
		if (typeof addon?.stopCapture === 'function') {
			addon.stopCapture();
		}
	} catch (_) {
		// Ignore stop errors while failing.
	}

	console.error('N-API test failed');
	console.error(error?.stack || error);
	process.exitCode = 1;
});
