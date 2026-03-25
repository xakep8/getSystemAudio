#pragma once

#include <atomic>
#include <cstddef>
#include <functional>
#include <vector>
#include <thread>

class AudioCapturer
{
private:
    void getAudioCapturePermission();

public:
    using PcmCallback = std::function<void(const float *data, size_t frames)>;

    AudioCapturer();
    ~AudioCapturer();
    void start_capture();
    void set_callback(PcmCallback cb);
    void stop_capture();
    bool is_initialized() const { return m_Initialized; }
    bool is_callback_set() const { return m_callback_set; }

private:
    bool m_Initialized{false};
    bool m_callback_set{false};
    void m_captureLoop();
    std::atomic<bool> m_running_{false};
    PcmCallback m_callback;
};