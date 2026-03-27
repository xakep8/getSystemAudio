#include <napi.h>
#include <vector>
#include <cstring>
#include "audio_buffer.h"

AudioCapturer capturer;
Napi::ThreadSafeFunction g_pcm_tsfn;
std::atomic<bool> g_has_tsfn{false};

struct PcmPayload
{
    std::vector<float> pcm;
    AudioCapturer::PcmFrameMeta meta;
};

Napi::Value start_capture(const Napi::CallbackInfo &info)
{
    Napi::Env env = info.Env();

    if (!capturer.is_initialized())
    {
        Napi::Error::New(env, "AudioCapturer is not initialized!").ThrowAsJavaScriptException();
        return env.Undefined();
    }
    if (!capturer.is_callback_set())
    {
        Napi::Error::New(env, "Callback for Audio Capture is not set").ThrowAsJavaScriptException();
        return env.Undefined();
    }

    capturer.start_capture();
    return env.Undefined();
}

Napi::Value set_callback(const Napi::CallbackInfo &info)
{
    Napi::Env env = info.Env();

    if (!capturer.is_initialized())
    {
        Napi::Error::New(env, "AudioCapturer is not initialized!").ThrowAsJavaScriptException();
        return env.Undefined();
    }

    if (info.Length() < 1 || !info[0].IsFunction())
    {
        Napi::TypeError::New(env, "setCallback expects a function as the first argument").ThrowAsJavaScriptException();
        return env.Undefined();
    }

    Napi::Function js_callback = info[0].As<Napi::Function>();

    if (g_has_tsfn.load())
    {
        g_pcm_tsfn.Release();
        g_has_tsfn.store(false);
    }

    g_pcm_tsfn = Napi::ThreadSafeFunction::New(env, js_callback, "AudioPcmCallback", 256, 1);
    g_has_tsfn.store(true);

    capturer.set_callback([](const float *data, size_t frames, const AudioCapturer::PcmFrameMeta &meta)
                          {
                             if (!g_has_tsfn.load())
                             {
                                 return;
                             }

                             auto *payload = new PcmPayload{
                                 std::vector<float>(data, data + frames),
                                 meta};

                             napi_status status = g_pcm_tsfn.NonBlockingCall(
                                 payload,
                                 [](Napi::Env env, Napi::Function cb, PcmPayload *packet)
                                 {
                                     Napi::Float32Array pcm_array = Napi::Float32Array::New(env, packet->pcm.size());
                                     std::memcpy(pcm_array.Data(), packet->pcm.data(), packet->pcm.size() * sizeof(float));

                                     Napi::Object meta_obj = Napi::Object::New(env);
                                     meta_obj.Set("sampleRate", Napi::Number::New(env, packet->meta.sample_rate));
                                     meta_obj.Set("channels", Napi::Number::New(env, packet->meta.channels));
                                     size_t frame_count = packet->meta.channels > 0
                                                              ? packet->pcm.size() / packet->meta.channels
                                                              : packet->pcm.size();
                                     meta_obj.Set("frameCount", Napi::Number::New(env, frame_count));
                                     meta_obj.Set("sequence", Napi::Number::New(env, static_cast<double>(packet->meta.sequence)));
                                     meta_obj.Set("timestampMs", Napi::Number::New(env, packet->meta.timestamp_ms));
                                     meta_obj.Set("fromSystem", Napi::Boolean::New(env, packet->meta.from_system_capture));
                                     meta_obj.Set("source", Napi::String::New(env, packet->meta.from_system_capture ? "system" : "fallback"));

                                     cb.Call({pcm_array, meta_obj});
                                     delete packet;
                                 });

                             if (status != napi_ok)
                             {
                                 delete payload;
                             } });

    return env.Undefined();
}

Napi::Value stop_capture(const Napi::CallbackInfo &info)
{
    Napi::Env env = info.Env();
    capturer.stop_capture();

    if (g_has_tsfn.load())
    {
        g_pcm_tsfn.Release();
        g_has_tsfn.store(false);
    }

    return env.Undefined();
}

Napi::Value get_capture_diagnostics(const Napi::CallbackInfo &info)
{
    Napi::Env env = info.Env();

    AudioCapturer::CaptureDiagnostics diagnostics = capturer.get_capture_diagnostics();

    Napi::Object out = Napi::Object::New(env);
    out.Set("permissionPreflight", Napi::Boolean::New(env, diagnostics.permission_preflight));
    out.Set("usingSystemCapture", Napi::Boolean::New(env, diagnostics.using_system_capture));
    out.Set("lastStartSystemCaptureSucceeded", Napi::Boolean::New(env, diagnostics.last_start_system_capture_succeeded));
    out.Set("systemFrameCallbacks", Napi::Number::New(env, static_cast<double>(diagnostics.system_frame_callbacks)));
    out.Set("fallbackFrameCallbacks", Napi::Number::New(env, static_cast<double>(diagnostics.fallback_frame_callbacks)));
    out.Set("sckAudioSampleCallbacks", Napi::Number::New(env, static_cast<double>(diagnostics.sck_audio_sample_callbacks)));
    out.Set("sckScreenSampleCallbacks", Napi::Number::New(env, static_cast<double>(diagnostics.sck_screen_sample_callbacks)));
    out.Set("sckAudioDroppedInvalidOrNotReady", Napi::Number::New(env, static_cast<double>(diagnostics.sck_audio_dropped_invalid_or_not_ready)));
    out.Set("sckAudioDroppedMissingFormat", Napi::Number::New(env, static_cast<double>(diagnostics.sck_audio_dropped_missing_format)));
    out.Set("sckAudioDroppedZeroChannelsOrFrames", Napi::Number::New(env, static_cast<double>(diagnostics.sck_audio_dropped_zero_channels_or_frames)));
    out.Set("sckAudioDroppedBufferListError", Napi::Number::New(env, static_cast<double>(diagnostics.sck_audio_dropped_buffer_list_error)));
    out.Set("queuedFrameDepth", Napi::Number::New(env, static_cast<double>(diagnostics.queued_frame_depth)));
    out.Set("queueMaxDepth", Napi::Number::New(env, static_cast<double>(diagnostics.queue_max_depth)));
    out.Set("queueDroppedFrames", Napi::Number::New(env, static_cast<double>(diagnostics.queue_dropped_frames)));
    out.Set("queueUnderrunFrames", Napi::Number::New(env, static_cast<double>(diagnostics.queue_underrun_frames)));
    out.Set("lastError", Napi::String::New(env, diagnostics.last_error));

    return out;
}

Napi::Object Initialize(Napi::Env env, Napi::Object exports)
{
    exports.Set(
        Napi::String::New(env, "startCapture"),
        Napi::Function::New(env, start_capture));

    exports.Set(
        Napi::String::New(env, "stopCapture"),
        Napi::Function::New(env, stop_capture));

    exports.Set(
        Napi::String::New(env, "setCallback"),
        Napi::Function::New(env, set_callback));

    exports.Set(
        Napi::String::New(env, "getCaptureDiagnostics"),
        Napi::Function::New(env, get_capture_diagnostics));

    return exports;
}

NODE_API_MODULE(getSystemAudio, Initialize)