#include <napi.h>
#include <vector>
#include <cstring>
#include "audio_buffer.h"

AudioCapturer capturer;
Napi::ThreadSafeFunction g_pcm_tsfn;
std::atomic<bool> g_has_tsfn{false};

Napi::Value start_capture(const Napi::CallbackInfo &info)
{
    Napi::Env env = info.Env();

    if (!capturer.is_initialized())
    {
        throw Napi::Error::New(env, "AudioCapturer is not initialized!");
    }
    if (!capturer.is_callback_set())
    {
        throw Napi::Error::New(env, "Callback for Audio Capture is not set");
    }

    capturer.start_capture();
    return env.Undefined();
}

Napi::Value set_callback(const Napi::CallbackInfo &info)
{
    Napi::Env env = info.Env();

    if (!capturer.is_initialized())
    {
        throw Napi::Error::New(env, "AudioCapturer is not initialized!");
    }

    if (info.Length() < 1 || !info[0].IsFunction())
    {
        throw Napi::TypeError::New(env, "setCallback expects a function as the first argument");
    }

    Napi::Function js_callback = info[0].As<Napi::Function>();

    if (g_has_tsfn.load())
    {
        g_pcm_tsfn.Release();
        g_has_tsfn.store(false);
    }

    g_pcm_tsfn = Napi::ThreadSafeFunction::New(env, js_callback, "AudioPcmCallback", 0, 1);
    g_has_tsfn.store(true);

    capturer.set_callback([](const float *data, size_t frames)
                          {
                             if (!g_has_tsfn.load())
                             {
                                 return;
                             }

                             auto *payload = new std::vector<float>(data, data + frames);

                             napi_status status = g_pcm_tsfn.BlockingCall(
                                 payload,
                                 [](Napi::Env env, Napi::Function cb, std::vector<float> *pcm)
                                 {
                                     Napi::Float32Array pcm_array = Napi::Float32Array::New(env, pcm->size());
                                     std::memcpy(pcm_array.Data(), pcm->data(), pcm->size() * sizeof(float));
                                     cb.Call({pcm_array});
                                     delete pcm;
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

    return exports;
}

NODE_API_MODULE(getSystemAudio, Initialize)