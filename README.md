# getSystemAudio

Capture macOS system audio in Node.js as real-time PCM frames from a native N-API addon.

This package is designed for pipelines like:

- Electron app captures system audio in the main process
- Renderer receives PCM chunks
- AudioWorklet converts PCM into a Web Audio graph
- MediaStreamAudioDestinationNode exposes a real MediaStream

## Platform Support

- macOS 13+
- Node.js with node-gyp toolchain
- Screen and System Audio Recording permission must be granted to the host app (Terminal, iTerm, Electron app, etc.)

## Install

```bash
npm install @0biwank/getsystemaudio
```

## Build Native Addon

```bash
npm run rebuild
```

## API

### startCapture(): void
Starts capture.

### stopCapture(): void
Stops capture.

### setCallback((pcm, meta) => void): void
Registers PCM callback.

- pcm: Float32Array
- meta.sampleRate: number
- meta.channels: number
- meta.frameCount: number
- meta.sequence: number
- meta.timestampMs: number
- meta.fromSystem: boolean
- meta.source: "system" | "fallback"

### getCaptureDiagnostics(): CaptureDiagnostics
Returns runtime diagnostics and queue/callback counters.

### getAudioData(callback)
Backward-compatible alias for setCallback.

## Quick Node Example

```js
import {
  startCapture,
  stopCapture,
  setCallback,
  getCaptureDiagnostics,
} from '@0biwank/getsystemaudio';

setCallback((pcm, meta) => {
  // pcm is interleaved float32
  // for stereo: [L0, R0, L1, R1, ...]
  if (meta.source === 'system') {
    // process real system audio
  }
});

startCapture();

setTimeout(() => {
  stopCapture();
  console.log(getCaptureDiagnostics());
}, 5000);
```

## Electron Integration (Recommended Architecture)

Keep capture in the main process. Push PCM to renderer via IPC. Convert to MediaStream in renderer using AudioWorklet.

### 1) Main process

```js
// main.js
import { app, BrowserWindow, ipcMain } from 'electron';
import {
  startCapture,
  stopCapture,
  setCallback,
  getCaptureDiagnostics,
} from '@0biwank/getsystemaudio';

let win;

function createWindow() {
  win = new BrowserWindow({
    webPreferences: {
      preload: new URL('./preload.js', import.meta.url).pathname,
      contextIsolation: true,
      nodeIntegration: false,
    },
  });

  win.loadURL('http://localhost:3000');
}

app.whenReady().then(() => {
  createWindow();

  setCallback((pcm, meta) => {
    // Transfer plain array-like data to renderer.
    // For higher throughput, consider chunk batching and shared memory.
    win?.webContents.send('system-audio:pcm', {
      pcm: Array.from(pcm),
      meta,
    });
  });
});

ipcMain.handle('system-audio:start', () => {
  startCapture();
  return getCaptureDiagnostics();
});

ipcMain.handle('system-audio:stop', () => {
  stopCapture();
  return getCaptureDiagnostics();
});

ipcMain.handle('system-audio:diag', () => getCaptureDiagnostics());
```

### 2) Preload bridge

```js
// preload.js
import { contextBridge, ipcRenderer } from 'electron';

contextBridge.exposeInMainWorld('systemAudio', {
  start: () => ipcRenderer.invoke('system-audio:start'),
  stop: () => ipcRenderer.invoke('system-audio:stop'),
  diagnostics: () => ipcRenderer.invoke('system-audio:diag'),
  onPcm: (handler) => {
    const listener = (_event, payload) => handler(payload);
    ipcRenderer.on('system-audio:pcm', listener);
    return () => ipcRenderer.removeListener('system-audio:pcm', listener);
  },
});
```

### 3) Renderer AudioWorklet -> MediaStream

```js
// renderer.js
async function createSystemMediaStream() {
  const context = new AudioContext({ sampleRate: 48000 });
  await context.audioWorklet.addModule('/audio/system-audio-processor.js');

  const node = new AudioWorkletNode(context, 'system-audio-processor', {
    numberOfInputs: 0,
    numberOfOutputs: 1,
    outputChannelCount: [2],
  });

  const destination = context.createMediaStreamDestination();
  node.connect(destination);

  const unsubscribe = window.systemAudio.onPcm(({ pcm, meta }) => {
    // Recreate Float32Array in renderer
    node.port.postMessage({ pcm: new Float32Array(pcm), meta });
  });

  await window.systemAudio.start();

  return {
    stream: destination.stream,
    stop: async () => {
      unsubscribe();
      await window.systemAudio.stop();
      node.disconnect();
      await context.close();
    },
  };
}
```

```js
// public/audio/system-audio-processor.js
class SystemAudioProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    this.queue = [];
    this.readOffset = 0;

    this.port.onmessage = (event) => {
      const payload = event.data;
      if (!payload || !(payload.pcm instanceof Float32Array)) return;
      this.queue.push(payload.pcm);
    };
  }

  process(_inputs, outputs) {
    const output = outputs[0];
    const left = output[0];
    const right = output[1] || output[0];

    left.fill(0);
    right.fill(0);

    let frameIndex = 0;
    while (frameIndex < left.length && this.queue.length > 0) {
      const chunk = this.queue[0];
      const availableSamples = chunk.length - this.readOffset;
      const availableFrames = Math.floor(availableSamples / 2);
      const neededFrames = left.length - frameIndex;
      const toCopyFrames = Math.min(availableFrames, neededFrames);

      for (let i = 0; i < toCopyFrames; i++) {
        const base = this.readOffset + i * 2;
        left[frameIndex + i] = chunk[base];
        right[frameIndex + i] = chunk[base + 1] ?? chunk[base];
      }

      frameIndex += toCopyFrames;
      this.readOffset += toCopyFrames * 2;

      if (this.readOffset >= chunk.length) {
        this.queue.shift();
        this.readOffset = 0;
      }
    }

    return true;
  }
}

registerProcessor('system-audio-processor', SystemAudioProcessor);
```

At this point you can use destination.stream as a standard MediaStream:

- attach to audio element
- use MediaRecorder
- add to WebRTC PeerConnection

## Diagnostics and Stability

Call getCaptureDiagnostics() periodically when tuning.

Useful fields:

- systemFrameCallbacks: real system frames delivered
- fallbackFrameCallbacks: fallback frames delivered
- queueDroppedFrames: queue overflow drops
- queueUnderrunFrames: queue starvation count
- queueMaxDepth: highest queue depth reached
- sckAudioSampleCallbacks: raw ScreenCaptureKit audio callback count

For smooth output:

- Keep renderer and worklet processing lightweight
- Prefer batching over sending very tiny chunks over IPC
- If queueDroppedFrames rises, reduce processing load or increase batching

## Permissions Checklist (macOS)

If you only get fallback frames:

1. Open System Settings -> Privacy and Security -> Screen and System Audio Recording.
2. Enable the process that starts capture:
   - Terminal, iTerm, or Electron app bundle
3. Fully restart that app after changing permission.

## License

MIT
