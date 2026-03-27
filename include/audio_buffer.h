#pragma once

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <deque>
#include <mutex>
#include <condition_variable>
#include <string>
#include <vector>
#include <thread>

class AudioCapturer
{
private:
    void getAudioCapturePermission();

public:
    enum class AudioDropReason
    {
        InvalidOrNotReady,
        MissingFormat,
        ZeroChannelsOrFrames,
        BufferListError,
    };

    struct CaptureDiagnostics
    {
        bool permission_preflight;
        bool using_system_capture;
        bool last_start_system_capture_succeeded;
        uint64_t system_frame_callbacks;
        uint64_t fallback_frame_callbacks;
        uint64_t sck_audio_sample_callbacks;
        uint64_t sck_screen_sample_callbacks;
        uint64_t sck_audio_dropped_invalid_or_not_ready;
        uint64_t sck_audio_dropped_missing_format;
        uint64_t sck_audio_dropped_zero_channels_or_frames;
        uint64_t sck_audio_dropped_buffer_list_error;
        uint64_t queued_frame_depth;
        uint64_t queue_max_depth;
        uint64_t queue_dropped_frames;
        uint64_t queue_underrun_frames;
        std::string last_error;
    };

    struct PcmFrameMeta
    {
        uint32_t sample_rate;
        uint16_t channels;
        uint64_t sequence;
        double timestamp_ms;
        bool from_system_capture;
    };

    using PcmCallback = std::function<void(const float *data, size_t frames, const PcmFrameMeta &meta)>;

    AudioCapturer();
    ~AudioCapturer();
    void start_capture();
    void set_callback(PcmCallback cb);
    void stop_capture();
    void on_pcm_from_system_capture(const float *data, size_t sample_count, uint32_t sample_rate, uint16_t channels, double timestamp_ms, bool from_system_capture);
    void on_stream_output_callback(bool is_audio_type);
    void on_stream_audio_drop(AudioDropReason reason);
    CaptureDiagnostics get_capture_diagnostics() const;
    bool is_initialized() const { return m_Initialized; }
    bool is_callback_set() const { return m_callback_set.load(); }

private:
    struct QueuedFrame
    {
        std::vector<float> pcm;
        bool from_system_capture;
        double timestamp_ms;
    };

    bool m_Initialized{false};
    bool start_system_capture();
    bool stop_system_capture();
    void delivery_loop();
    void enqueue_pcm_samples(const float *data, size_t sample_count, uint16_t input_channels, bool from_system_capture, double timestamp_ms);
    std::atomic<bool> m_callback_set{false};
    void m_captureLoop();
    std::atomic<bool> m_running_{false};
    std::atomic<bool> m_using_system_capture_{false};
    std::thread m_capture_thread;
    std::thread m_delivery_thread;
    std::atomic<uint64_t> m_sequence{0};
    std::atomic<int64_t> m_last_system_pcm_monotonic_us_{0};
    std::atomic<uint64_t> m_system_frame_callbacks_{0};
    std::atomic<uint64_t> m_fallback_frame_callbacks_{0};
    std::atomic<uint64_t> m_queue_dropped_frames_{0};
    std::atomic<uint64_t> m_queue_underrun_frames_{0};
    std::atomic<uint64_t> m_queue_max_depth_{0};
    std::atomic<uint64_t> m_sck_audio_sample_callbacks_{0};
    std::atomic<uint64_t> m_sck_screen_sample_callbacks_{0};
    std::atomic<uint64_t> m_sck_audio_dropped_invalid_or_not_ready_{0};
    std::atomic<uint64_t> m_sck_audio_dropped_missing_format_{0};
    std::atomic<uint64_t> m_sck_audio_dropped_zero_channels_or_frames_{0};
    std::atomic<uint64_t> m_sck_audio_dropped_buffer_list_error_{0};
    std::atomic<bool> m_permission_preflight_{false};
    std::atomic<bool> m_last_start_system_capture_succeeded_{false};
    std::mutex m_callback_mutex;
    mutable std::mutex m_queue_mutex;
    std::condition_variable m_queue_cv;
    std::deque<QueuedFrame> m_frame_queue;
    std::vector<float> m_pending_samples;
    size_t m_pending_offset{0};
    bool m_pending_from_system{false};
    double m_pending_timestamp_ms{0.0};
    mutable std::mutex m_diag_mutex;
    PcmCallback m_callback;
    void *m_impl{nullptr};
    std::string m_last_error;
};