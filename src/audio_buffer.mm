#include "audio_buffer.h"

#import <ApplicationServices/ApplicationServices.h>
#import <CoreMedia/CoreMedia.h>
#import <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>

#include <algorithm>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace {
constexpr uint32_t kTargetSampleRate = 48000;
constexpr uint16_t kTargetChannels = 2;
constexpr size_t kTargetFramesPerChunk = 480;
constexpr size_t kTargetSamplesPerChunk = kTargetFramesPerChunk * kTargetChannels;
constexpr size_t kMaxQueuedFrames = 256;
}

class AudioCapturer;

@interface SCKAudioOutputHandler : NSObject <SCStreamOutput>
- (instancetype)initWithCapturer:(AudioCapturer *)capturer;
@end

struct AudioCapturerImpl {
    dispatch_queue_t queue;
    dispatch_semaphore_t start_semaphore;
    dispatch_semaphore_t stop_semaphore;
    SCStream *stream;
    SCKAudioOutputHandler *output_handler;
    std::atomic<bool> started;
    std::atomic<bool> start_failed;

    AudioCapturerImpl()
        : queue(dispatch_queue_create("getSystemAudio.capture", DISPATCH_QUEUE_SERIAL)),
          start_semaphore(dispatch_semaphore_create(0)),
          stop_semaphore(dispatch_semaphore_create(0)),
          stream(nil),
          output_handler(nil),
          started(false),
          start_failed(false)
    {
    }
};

@implementation SCKAudioOutputHandler {
    AudioCapturer *_capturer;
}

- (instancetype)initWithCapturer:(AudioCapturer *)capturer
{
    self = [super init];
    if (self) {
        _capturer = capturer;
    }
    return self;
}

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type
{
    _capturer->on_stream_output_callback(type == SCStreamOutputTypeAudio);

    if (type != SCStreamOutputTypeAudio || sampleBuffer == nullptr) {
        return;
    }

    if (!CMSampleBufferIsValid(sampleBuffer) || !CMSampleBufferDataIsReady(sampleBuffer)) {
        _capturer->on_stream_audio_drop(AudioCapturer::AudioDropReason::InvalidOrNotReady);
        return;
    }

    CMAudioFormatDescriptionRef format_desc = CMSampleBufferGetFormatDescription(sampleBuffer);
    if (format_desc == nullptr) {
        _capturer->on_stream_audio_drop(AudioCapturer::AudioDropReason::MissingFormat);
        return;
    }

    const AudioStreamBasicDescription *asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format_desc);
    if (asbd == nullptr) {
        _capturer->on_stream_audio_drop(AudioCapturer::AudioDropReason::MissingFormat);
        return;
    }

    const uint32_t channels = static_cast<uint32_t>(asbd->mChannelsPerFrame);
    if (channels == 0) {
        _capturer->on_stream_audio_drop(AudioCapturer::AudioDropReason::ZeroChannelsOrFrames);
        return;
    }

    size_t frames = static_cast<size_t>(CMSampleBufferGetNumSamples(sampleBuffer));

    const bool is_float = (asbd->mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    const bool is_signed_int = (asbd->mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0;
    const bool is_non_interleaved = (asbd->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;

    size_t bytes_per_sample = 0;
    if (is_float && asbd->mBitsPerChannel == 32) {
        bytes_per_sample = sizeof(float);
    } else if (is_signed_int && asbd->mBitsPerChannel == 16) {
        bytes_per_sample = sizeof(int16_t);
    } else if (is_signed_int && asbd->mBitsPerChannel == 32) {
        bytes_per_sample = sizeof(int32_t);
    }

    if (bytes_per_sample == 0) {
        _capturer->on_stream_audio_drop(AudioCapturer::AudioDropReason::BufferListError);
        return;
    }

    if (is_non_interleaved) {
        if (frames == 0) {
            _capturer->on_stream_audio_drop(AudioCapturer::AudioDropReason::ZeroChannelsOrFrames);
            return;
        }

        std::vector<uint8_t> abl_storage(sizeof(AudioBufferList) + sizeof(AudioBuffer) * (channels - 1));
        AudioBufferList *buffer_list = reinterpret_cast<AudioBufferList *>(abl_storage.data());
        buffer_list->mNumberBuffers = channels;

        std::vector<std::vector<uint8_t>> channel_raw(channels);
        for (uint32_t ch = 0; ch < channels; ++ch) {
            channel_raw[ch].resize(frames * bytes_per_sample);
            buffer_list->mBuffers[ch].mNumberChannels = 1;
            buffer_list->mBuffers[ch].mDataByteSize = static_cast<uint32_t>(channel_raw[ch].size());
            buffer_list->mBuffers[ch].mData = channel_raw[ch].data();
        }

        OSStatus copy_pcm_status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            0,
            static_cast<int32_t>(frames),
            buffer_list);

        if (copy_pcm_status != noErr) {
            _capturer->on_stream_audio_drop(AudioCapturer::AudioDropReason::BufferListError);
            return;
        }

        std::vector<float> pcm(frames * channels, 0.0f);
        if (is_float) {
            for (uint32_t ch = 0; ch < channels; ++ch) {
                const float *src = reinterpret_cast<const float *>(channel_raw[ch].data());
                for (size_t frame = 0; frame < frames; ++frame) {
                    pcm[frame * channels + ch] = src[frame];
                }
            }
        } else if (is_signed_int && asbd->mBitsPerChannel == 16) {
            for (uint32_t ch = 0; ch < channels; ++ch) {
                const int16_t *src = reinterpret_cast<const int16_t *>(channel_raw[ch].data());
                for (size_t frame = 0; frame < frames; ++frame) {
                    pcm[frame * channels + ch] = static_cast<float>(src[frame]) / 32768.0f;
                }
            }
        } else if (is_signed_int && asbd->mBitsPerChannel == 32) {
            for (uint32_t ch = 0; ch < channels; ++ch) {
                const int32_t *src = reinterpret_cast<const int32_t *>(channel_raw[ch].data());
                for (size_t frame = 0; frame < frames; ++frame) {
                    pcm[frame * channels + ch] = static_cast<float>(src[frame]) / 2147483648.0f;
                }
            }
        }

        CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
        double timestamp_ms = CMTIME_IS_VALID(pts) ? (CMTimeGetSeconds(pts) * 1000.0) : 0.0;

        _capturer->on_pcm_from_system_capture(
            pcm.data(),
            pcm.size(),
            static_cast<uint32_t>(asbd->mSampleRate),
            static_cast<uint16_t>(channels),
            timestamp_ms,
            true);
        return;
    }

    CMBlockBufferRef data_buffer = CMSampleBufferGetDataBuffer(sampleBuffer);
    if (data_buffer == nullptr) {
        _capturer->on_stream_audio_drop(AudioCapturer::AudioDropReason::BufferListError);
        return;
    }

    const size_t data_bytes = static_cast<size_t>(CMBlockBufferGetDataLength(data_buffer));
    if (data_bytes == 0) {
        _capturer->on_stream_audio_drop(AudioCapturer::AudioDropReason::ZeroChannelsOrFrames);
        return;
    }

    const size_t total_samples_from_buffer = data_bytes / bytes_per_sample;
    if (frames == 0) {
        frames = total_samples_from_buffer / channels;
    }

    if (frames == 0) {
        _capturer->on_stream_audio_drop(AudioCapturer::AudioDropReason::ZeroChannelsOrFrames);
        return;
    }

    const size_t expected_samples = frames * channels;
    const size_t copy_samples = std::min(expected_samples, total_samples_from_buffer);

    std::vector<uint8_t> raw(copy_samples * bytes_per_sample);
    OSStatus copy_status = CMBlockBufferCopyDataBytes(data_buffer, 0, raw.size(), raw.data());
    if (copy_status != noErr) {
        _capturer->on_stream_audio_drop(AudioCapturer::AudioDropReason::BufferListError);
        return;
    }

    std::vector<float> pcm(expected_samples, 0.0f);
    if (is_float) {
        const float *src = reinterpret_cast<const float *>(raw.data());
        for (size_t i = 0; i < copy_samples; ++i) {
            pcm[i] = src[i];
        }
    } else if (is_signed_int && asbd->mBitsPerChannel == 16) {
        const int16_t *src = reinterpret_cast<const int16_t *>(raw.data());
        for (size_t i = 0; i < copy_samples; ++i) {
            pcm[i] = static_cast<float>(src[i]) / 32768.0f;
        }
    } else if (is_signed_int && asbd->mBitsPerChannel == 32) {
        const int32_t *src = reinterpret_cast<const int32_t *>(raw.data());
        for (size_t i = 0; i < copy_samples; ++i) {
            pcm[i] = static_cast<float>(src[i]) / 2147483648.0f;
        }
    }

    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    double timestamp_ms = CMTIME_IS_VALID(pts) ? (CMTimeGetSeconds(pts) * 1000.0) : 0.0;

    _capturer->on_pcm_from_system_capture(
        pcm.data(),
        pcm.size(),
        static_cast<uint32_t>(asbd->mSampleRate),
        static_cast<uint16_t>(channels),
        timestamp_ms,
        true);
}

@end

AudioCapturer::AudioCapturer()
{
    m_impl = new AudioCapturerImpl();
    m_Initialized = (m_impl != nullptr);
}

AudioCapturer::~AudioCapturer()
{
    stop_capture();
    auto *impl = static_cast<AudioCapturerImpl *>(m_impl);
    delete impl;
    m_impl = nullptr;
}

void AudioCapturer::getAudioCapturePermission()
{
    bool has_permission = CGPreflightScreenCaptureAccess();
    m_permission_preflight_.store(has_permission);

    if (!has_permission) {
        CGRequestScreenCaptureAccess();

        bool after_request = CGPreflightScreenCaptureAccess();
        m_permission_preflight_.store(after_request);
        if (!after_request) {
            std::lock_guard<std::mutex> lock(m_diag_mutex);
            m_last_error = "Screen capture permission was denied or not yet granted";
        }
    }
}

bool AudioCapturer::start_system_capture()
{
    auto *impl = static_cast<AudioCapturerImpl *>(m_impl);
    if (impl == nullptr) {
        return false;
    }

    getAudioCapturePermission();

    impl->started.store(false);
    impl->start_failed.store(false);

    __block AudioCapturerImpl *impl_ref = impl;
    __block AudioCapturer *capturer_ref = this;

    [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *error) {
        if (error != nil || content == nil || content.displays.count == 0) {
            {
                std::lock_guard<std::mutex> lock(capturer_ref->m_diag_mutex);
                if (error != nil) {
                    capturer_ref->m_last_error = [[error localizedDescription] UTF8String];
                } else {
                    capturer_ref->m_last_error = "No shareable displays available for ScreenCaptureKit";
                }
            }
            impl_ref->start_failed.store(true);
            dispatch_semaphore_signal(impl_ref->start_semaphore);
            return;
        }

        SCDisplay *display = content.displays.firstObject;
        SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];

        SCStreamConfiguration *config = [[SCStreamConfiguration alloc] init];
        config.capturesAudio = YES;
        config.sampleRate = 48000;
        config.channelCount = 2;
        config.excludesCurrentProcessAudio = NO;
        config.width = display.width;
        config.height = display.height;
        config.queueDepth = 5;
        config.minimumFrameInterval = CMTimeMake(1, 60);

        SCStream *stream = [[SCStream alloc] initWithFilter:filter configuration:config delegate:nil];
        SCKAudioOutputHandler *handler = [[SCKAudioOutputHandler alloc] initWithCapturer:capturer_ref];

        NSError *add_output_error = nil;
        BOOL did_add = [stream addStreamOutput:handler type:SCStreamOutputTypeAudio sampleHandlerQueue:impl_ref->queue error:&add_output_error];

        NSError *add_screen_output_error = nil;
        BOOL did_add_screen = [stream addStreamOutput:handler type:SCStreamOutputTypeScreen sampleHandlerQueue:impl_ref->queue error:&add_screen_output_error];

        if (!did_add || add_output_error != nil) {
            {
                std::lock_guard<std::mutex> lock(capturer_ref->m_diag_mutex);
                if (add_output_error != nil) {
                    capturer_ref->m_last_error = [[add_output_error localizedDescription] UTF8String];
                } else {
                    capturer_ref->m_last_error = "Failed to add ScreenCaptureKit audio output";
                }
            }
            impl_ref->start_failed.store(true);
            dispatch_semaphore_signal(impl_ref->start_semaphore);
            return;
        }

        if (!did_add_screen || add_screen_output_error != nil) {
            {
                std::lock_guard<std::mutex> lock(capturer_ref->m_diag_mutex);
                if (add_screen_output_error != nil) {
                    capturer_ref->m_last_error = [[add_screen_output_error localizedDescription] UTF8String];
                } else {
                    capturer_ref->m_last_error = "Failed to add ScreenCaptureKit screen output";
                }
            }
            impl_ref->start_failed.store(true);
            dispatch_semaphore_signal(impl_ref->start_semaphore);
            return;
        }

        impl_ref->stream = stream;
        impl_ref->output_handler = handler;

        [stream startCaptureWithCompletionHandler:^(NSError *start_error) {
            if (start_error != nil) {
                {
                    std::lock_guard<std::mutex> lock(capturer_ref->m_diag_mutex);
                    capturer_ref->m_last_error = [[start_error localizedDescription] UTF8String];
                }
                impl_ref->start_failed.store(true);
            } else {
                impl_ref->started.store(true);
                std::lock_guard<std::mutex> lock(capturer_ref->m_diag_mutex);
                capturer_ref->m_last_error.clear();
            }
            dispatch_semaphore_signal(impl_ref->start_semaphore);
        }];
    }];

    dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, 2LL * NSEC_PER_SEC);
    long wait_result = dispatch_semaphore_wait(impl->start_semaphore, timeout);

    bool succeeded = !(wait_result != 0 || impl->start_failed.load() || !impl->started.load());
    m_last_start_system_capture_succeeded_.store(succeeded);
    if (!succeeded && wait_result != 0) {
        std::lock_guard<std::mutex> lock(m_diag_mutex);
        if (m_last_error.empty()) {
            m_last_error = "Timed out waiting for ScreenCaptureKit stream start";
        }
    }

    if (!succeeded) {
        return false;
    }

    return true;
}

bool AudioCapturer::stop_system_capture()
{
    auto *impl = static_cast<AudioCapturerImpl *>(m_impl);
    if (impl == nullptr || impl->stream == nil) {
        return true;
    }

    __block AudioCapturerImpl *impl_ref = impl;
    [impl->stream stopCaptureWithCompletionHandler:^(NSError *error) {
        (void)error;
        dispatch_semaphore_signal(impl_ref->stop_semaphore);
    }];

    dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, 2LL * NSEC_PER_SEC);
    dispatch_semaphore_wait(impl->stop_semaphore, timeout);

    impl->stream = nil;
    impl->output_handler = nil;
    impl->started.store(false);
    impl->start_failed.store(false);
    return true;
}

void AudioCapturer::start_capture()
{
    if (m_running_.load()) {
        return;
    }

    m_running_.store(true);
    m_sequence.store(0);
    m_last_system_pcm_monotonic_us_.store(0);
    m_system_frame_callbacks_.store(0);
    m_fallback_frame_callbacks_.store(0);
    m_queue_dropped_frames_.store(0);
    m_queue_underrun_frames_.store(0);
    m_queue_max_depth_.store(0);
    m_sck_audio_sample_callbacks_.store(0);
    m_sck_screen_sample_callbacks_.store(0);
    m_sck_audio_dropped_invalid_or_not_ready_.store(0);
    m_sck_audio_dropped_missing_format_.store(0);
    m_sck_audio_dropped_zero_channels_or_frames_.store(0);
    m_sck_audio_dropped_buffer_list_error_.store(0);

    {
        std::lock_guard<std::mutex> lock(m_queue_mutex);
        m_frame_queue.clear();
        m_pending_samples.clear();
        m_pending_offset = 0;
        m_pending_from_system = false;
        m_pending_timestamp_ms = 0.0;
    }

    m_using_system_capture_.store(start_system_capture());
    m_delivery_thread = std::thread(&AudioCapturer::delivery_loop, this);
}

void AudioCapturer::on_stream_output_callback(bool is_audio_type)
{
    if (is_audio_type) {
        m_sck_audio_sample_callbacks_.fetch_add(1);
    } else {
        m_sck_screen_sample_callbacks_.fetch_add(1);
    }
}

void AudioCapturer::on_stream_audio_drop(AudioCapturer::AudioDropReason reason)
{
    switch (reason) {
    case AudioDropReason::InvalidOrNotReady:
        m_sck_audio_dropped_invalid_or_not_ready_.fetch_add(1);
        break;
    case AudioDropReason::MissingFormat:
        m_sck_audio_dropped_missing_format_.fetch_add(1);
        break;
    case AudioDropReason::ZeroChannelsOrFrames:
        m_sck_audio_dropped_zero_channels_or_frames_.fetch_add(1);
        break;
    case AudioDropReason::BufferListError:
        m_sck_audio_dropped_buffer_list_error_.fetch_add(1);
        break;
    }
}

void AudioCapturer::set_callback(AudioCapturer::PcmCallback cb)
{
    std::lock_guard<std::mutex> lock(m_callback_mutex);
    m_callback = std::move(cb);
    m_callback_set.store(static_cast<bool>(m_callback));
}

void AudioCapturer::stop_capture()
{
    m_running_.store(false);
    m_queue_cv.notify_all();

    if (m_using_system_capture_.load()) {
        stop_system_capture();
        m_using_system_capture_.store(false);
    }

    if (m_delivery_thread.joinable()) {
        m_delivery_thread.join();
    }

    if (m_capture_thread.joinable()) {
        m_capture_thread.join();
    }
}

void AudioCapturer::on_pcm_from_system_capture(const float *data, size_t sample_count, uint32_t sample_rate, uint16_t channels, double timestamp_ms, bool from_system_capture)
{
    if (!m_running_.load()) {
        return;
    }

    if (timestamp_ms <= 0.0) {
        auto now = std::chrono::steady_clock::now().time_since_epoch();
        timestamp_ms = static_cast<double>(
            std::chrono::duration_cast<std::chrono::microseconds>(now).count()) /
            1000.0;
    }

    if (from_system_capture) {
        auto now_us = std::chrono::duration_cast<std::chrono::microseconds>(
            std::chrono::steady_clock::now().time_since_epoch()).count();
        m_last_system_pcm_monotonic_us_.store(static_cast<int64_t>(now_us));
    }

    (void)sample_rate;
    enqueue_pcm_samples(data, sample_count, channels, from_system_capture, timestamp_ms);
}

void AudioCapturer::enqueue_pcm_samples(const float *data, size_t sample_count, uint16_t input_channels, bool from_system_capture, double timestamp_ms)
{
    if (data == nullptr || sample_count == 0) {
        return;
    }

    std::vector<float> normalized;
    if (input_channels == 2) {
        normalized.assign(data, data + sample_count);
    } else if (input_channels == 1) {
        const size_t mono_frames = sample_count;
        normalized.resize(mono_frames * kTargetChannels);
        for (size_t frame = 0; frame < mono_frames; ++frame) {
            float sample = data[frame];
            normalized[frame * 2] = sample;
            normalized[frame * 2 + 1] = sample;
        }
    } else {
        const size_t frame_count = sample_count / input_channels;
        normalized.resize(frame_count * kTargetChannels);
        for (size_t frame = 0; frame < frame_count; ++frame) {
            normalized[frame * 2] = data[frame * input_channels];
            normalized[frame * 2 + 1] = data[frame * input_channels + 1];
        }
    }

    std::lock_guard<std::mutex> lock(m_queue_mutex);

    if (!m_pending_samples.empty() && m_pending_from_system != from_system_capture) {
        m_pending_samples.clear();
        m_pending_offset = 0;
    }

    if (m_pending_samples.empty()) {
        m_pending_from_system = from_system_capture;
        m_pending_timestamp_ms = timestamp_ms;
    }

    m_pending_samples.insert(m_pending_samples.end(), normalized.begin(), normalized.end());

    while ((m_pending_samples.size() - m_pending_offset) >= kTargetSamplesPerChunk) {
        QueuedFrame frame;
        frame.pcm.resize(kTargetSamplesPerChunk);
        std::copy(
            m_pending_samples.begin() + static_cast<std::ptrdiff_t>(m_pending_offset),
            m_pending_samples.begin() + static_cast<std::ptrdiff_t>(m_pending_offset + kTargetSamplesPerChunk),
            frame.pcm.begin());

        frame.from_system_capture = m_pending_from_system;
        frame.timestamp_ms = m_pending_timestamp_ms;
        m_pending_offset += kTargetSamplesPerChunk;

        if (m_frame_queue.size() >= kMaxQueuedFrames) {
            m_frame_queue.pop_front();
            m_queue_dropped_frames_.fetch_add(1);
        }

        m_frame_queue.push_back(std::move(frame));
        uint64_t depth = static_cast<uint64_t>(m_frame_queue.size());
        uint64_t previous_max = m_queue_max_depth_.load();
        while (depth > previous_max && !m_queue_max_depth_.compare_exchange_weak(previous_max, depth)) {
        }
    }

    if (m_pending_offset > 0 && m_pending_offset >= (m_pending_samples.size() / 2)) {
        m_pending_samples.erase(
            m_pending_samples.begin(),
            m_pending_samples.begin() + static_cast<std::ptrdiff_t>(m_pending_offset));
        m_pending_offset = 0;
    }

    m_queue_cv.notify_one();
}

void AudioCapturer::delivery_loop()
{
    std::vector<float> silence(kTargetSamplesPerChunk, 0.0f);
    auto next_tick = std::chrono::steady_clock::now();

    while (m_running_.load() || !m_frame_queue.empty()) {
        next_tick += std::chrono::milliseconds(10);

        QueuedFrame frame;
        bool has_frame = false;
        {
            std::lock_guard<std::mutex> lock(m_queue_mutex);
            if (!m_frame_queue.empty()) {
                frame = std::move(m_frame_queue.front());
                m_frame_queue.pop_front();
                has_frame = true;
            }
        }

        PcmCallback callback;
        {
            std::lock_guard<std::mutex> lock(m_callback_mutex);
            callback = m_callback;
        }

        if (callback) {
            AudioCapturer::PcmFrameMeta meta{
                .sample_rate = kTargetSampleRate,
                .channels = kTargetChannels,
                .sequence = m_sequence.fetch_add(1),
                .timestamp_ms = has_frame ? frame.timestamp_ms : (static_cast<double>(std::chrono::duration_cast<std::chrono::microseconds>(next_tick.time_since_epoch()).count()) / 1000.0),
                .from_system_capture = has_frame ? frame.from_system_capture : false,
            };

            if (has_frame) {
                if (frame.from_system_capture) {
                    m_system_frame_callbacks_.fetch_add(1);
                } else {
                    m_fallback_frame_callbacks_.fetch_add(1);
                }
                callback(frame.pcm.data(), frame.pcm.size(), meta);
            } else if (m_running_.load()) {
                m_queue_underrun_frames_.fetch_add(1);
                m_fallback_frame_callbacks_.fetch_add(1);
                callback(silence.data(), silence.size(), meta);
            }
        }

        std::this_thread::sleep_until(next_tick);
        auto now = std::chrono::steady_clock::now();
        if (next_tick < now) {
            next_tick = now;
        }
    }
}

AudioCapturer::CaptureDiagnostics AudioCapturer::get_capture_diagnostics() const
{
    CaptureDiagnostics diagnostics{};
    diagnostics.permission_preflight = m_permission_preflight_.load();
    diagnostics.using_system_capture = m_using_system_capture_.load();
    diagnostics.last_start_system_capture_succeeded = m_last_start_system_capture_succeeded_.load();
    diagnostics.system_frame_callbacks = m_system_frame_callbacks_.load();
    diagnostics.fallback_frame_callbacks = m_fallback_frame_callbacks_.load();
    diagnostics.sck_audio_sample_callbacks = m_sck_audio_sample_callbacks_.load();
    diagnostics.sck_screen_sample_callbacks = m_sck_screen_sample_callbacks_.load();
    diagnostics.sck_audio_dropped_invalid_or_not_ready = m_sck_audio_dropped_invalid_or_not_ready_.load();
    diagnostics.sck_audio_dropped_missing_format = m_sck_audio_dropped_missing_format_.load();
    diagnostics.sck_audio_dropped_zero_channels_or_frames = m_sck_audio_dropped_zero_channels_or_frames_.load();
    diagnostics.sck_audio_dropped_buffer_list_error = m_sck_audio_dropped_buffer_list_error_.load();
    diagnostics.queue_max_depth = m_queue_max_depth_.load();
    diagnostics.queue_dropped_frames = m_queue_dropped_frames_.load();
    diagnostics.queue_underrun_frames = m_queue_underrun_frames_.load();

    {
        std::lock_guard<std::mutex> lock(m_queue_mutex);
        diagnostics.queued_frame_depth = static_cast<uint64_t>(m_frame_queue.size());
    }

    {
        std::lock_guard<std::mutex> lock(m_diag_mutex);
        diagnostics.last_error = m_last_error;
    }

    return diagnostics;
}

void AudioCapturer::m_captureLoop()
{
    // Legacy fallback loop intentionally unused after queue/delivery redesign.
}
