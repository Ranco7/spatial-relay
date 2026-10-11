#import "AudioCaptureBridge.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <cstddef>
#include <memory>
#include <vector>

namespace {

// More than ten seconds at 48 kHz. This leaves ample headroom for an AirPods
// spatial-mode hardware reconfiguration without dropping or compressing PCM.
constexpr UInt32 kRingCapacityFrames = 524288;
NSString *const kCaptureErrorDomain = @"com.shevlfs.SpatialRelay.AudioCapture";

struct CaptureStorage {
    explicit CaptureStorage(UInt32 capacity)
        : samples(static_cast<size_t>(capacity) * 2, 0.0f),
          capacityFrames(capacity),
          mask(capacity - 1) {}

    std::vector<float> samples;
    const UInt32 capacityFrames;
    const UInt32 mask;

    alignas(64) std::atomic<UInt64> readCursor { 0 };
    alignas(64) std::atomic<UInt64> writeCursor { 0 };
    std::atomic<UInt64> droppedFrames { 0 };
    std::atomic<UInt64> formatMismatches { 0 };
    std::atomic<UInt64> callbacks { 0 };
    std::atomic<UInt64> capturedFrames { 0 };
    std::atomic<UInt32> peakBits { 0 };

    bool nonInterleaved = false;
    UInt32 bytesPerFrame = 0;
    UInt32 channels = 2;
    UInt32 tapBufferOffset = 0;

    void reset() noexcept {
        readCursor.store(0, std::memory_order_release);
        writeCursor.store(0, std::memory_order_release);
        droppedFrames.store(0, std::memory_order_relaxed);
        formatMismatches.store(0, std::memory_order_relaxed);
        callbacks.store(0, std::memory_order_relaxed);
        capturedFrames.store(0, std::memory_order_relaxed);
        storePeak(0.0f);
    }

    UInt32 available() const noexcept {
        // Load the consumer-owned cursor first. If the consumer advances after
        // this snapshot, the result is only conservatively high; it cannot
        // underflow because the producer-owned cursor never moves backwards.
        const auto read = readCursor.load(std::memory_order_acquire);
        const auto write = writeCursor.load(std::memory_order_acquire);
        if (write < read) return 0;
        return static_cast<UInt32>(std::min<UInt64>(write - read, capacityFrames));
    }

    void storePeak(float peak) noexcept {
        UInt32 bits = 0;
        static_assert(sizeof(bits) == sizeof(peak));
        std::memcpy(&bits, &peak, sizeof(bits));
        peakBits.store(bits, std::memory_order_relaxed);
    }

    float takePeak() noexcept {
        const UInt32 bits = peakBits.exchange(0, std::memory_order_relaxed);
        float peak = 0.0f;
        std::memcpy(&peak, &bits, sizeof(peak));
        return peak;
    }

    UInt32 writableFrames(UInt32 requested, UInt64 write, UInt64 read) noexcept {
        const UInt64 occupied = write - read;
        const UInt32 freeFrames = occupied >= capacityFrames
            ? 0
            : capacityFrames - static_cast<UInt32>(occupied);
        const UInt32 writable = std::min(requested, freeFrames);
        if (writable < requested) {
            droppedFrames.fetch_add(requested - writable, std::memory_order_relaxed);
        }
        return writable;
    }

    void configure(UInt32 channelCount, bool planar) {
        channels = channelCount;
        nonInterleaved = planar;
        bytesPerFrame = sizeof(float) * (planar ? 1 : channels);
        samples.assign(static_cast<size_t>(capacityFrames) * channels, 0.0f);
        reset();
    }

    void writeInterleaved(const float *source, UInt32 requestedFrames) noexcept {
        if (source == nullptr || requestedFrames == 0) return;
        const UInt64 write = writeCursor.load(std::memory_order_relaxed);
        const UInt64 read = readCursor.load(std::memory_order_acquire);
        const UInt32 frames = writableFrames(requestedFrames, write, read);
        if (frames == 0) return;
        const UInt32 offset = static_cast<UInt32>(write) & mask;
        const UInt32 first = std::min(frames, capacityFrames - offset);
        std::memcpy(samples.data() + static_cast<size_t>(offset) * channels,
                    source, static_cast<size_t>(first) * channels * sizeof(float));
        if (first < frames) {
            std::memcpy(samples.data(), source + static_cast<size_t>(first) * channels,
                        static_cast<size_t>(frames - first) * channels * sizeof(float));
        }
        float peak = 0;
        for (size_t i = 0; i < static_cast<size_t>(frames) * channels; ++i) {
            peak = std::max(peak, std::fabs(source[i]));
        }
        storePeak(std::min(peak, 1.0f));
        capturedFrames.fetch_add(frames, std::memory_order_relaxed);
        writeCursor.store(write + frames, std::memory_order_release);
    }

    // Interleaving is a memory-layout copy, with no arithmetic on PCM samples.
    void writePlanar(const AudioBuffer *buffers, UInt32 requestedFrames) noexcept {
        const UInt64 write = writeCursor.load(std::memory_order_relaxed);
        const UInt64 read = readCursor.load(std::memory_order_acquire);
        const UInt32 frames = writableFrames(requestedFrames, write, read);
        float peak = 0;
        for (UInt32 frame = 0; frame < frames; ++frame) {
            const UInt32 destination = (static_cast<UInt32>(write) + frame) & mask;
            for (UInt32 channel = 0; channel < channels; ++channel) {
                const float *source = static_cast<const float *>(buffers[channel].mData);
                std::memcpy(&samples[static_cast<size_t>(destination) * channels + channel],
                            source + frame, sizeof(float));
                peak = std::max(peak, std::fabs(source[frame]));
            }
        }
        storePeak(std::min(peak, 1.0f));
        capturedFrames.fetch_add(frames, std::memory_order_relaxed);
        writeCursor.store(write + frames, std::memory_order_release);
    }

    UInt32 readInterleaved(float *destination, UInt32 maximumFrames) noexcept {
        if (destination == nullptr || maximumFrames == 0) return 0;

        const UInt64 read = readCursor.load(std::memory_order_relaxed);
        const UInt64 write = writeCursor.load(std::memory_order_acquire);
        const UInt32 frames = static_cast<UInt32>(
            std::min<UInt64>(maximumFrames, write - read)
        );
        if (frames == 0) return 0;

        const UInt32 offset = static_cast<UInt32>(read) & mask;
        const UInt32 first = std::min(frames, capacityFrames - offset);
        std::memcpy(destination,
                    samples.data() + static_cast<size_t>(offset) * channels,
                    static_cast<size_t>(first) * channels * sizeof(float));
        if (first < frames) {
            std::memcpy(destination + static_cast<size_t>(first) * channels,
                        samples.data(),
                        static_cast<size_t>(frames - first) * channels * sizeof(float));
        }

        readCursor.store(read + frames, std::memory_order_release);
        return frames;
    }
};

CaptureStorage *storage(SRAudioCaptureBridge *bridge) noexcept {
    return static_cast<CaptureStorage *>(bridge->_captureStorage);
}

bool isFloatAligned(const void *pointer) noexcept {
    return pointer != nullptr &&
        (reinterpret_cast<std::uintptr_t>(pointer) % alignof(float)) == 0;
}

OSStatus captureIOProc(AudioObjectID,
                       const AudioTimeStamp *,
                       const AudioBufferList *inputData,
                       const AudioTimeStamp *,
                       AudioBufferList *outputData,
                       const AudioTimeStamp *,
                       void *clientData) noexcept {
    // Never produce audio through the aggregate; AVFoundation owns playback.
    if (outputData != nullptr) {
        for (UInt32 i = 0; i < outputData->mNumberBuffers; ++i) {
            if (outputData->mBuffers[i].mData != nullptr) {
                std::memset(outputData->mBuffers[i].mData, 0, outputData->mBuffers[i].mDataByteSize);
            }
        }
    }
    auto *state = static_cast<CaptureStorage *>(clientData);
    if (state == nullptr) return noErr;
    state->callbacks.fetch_add(1, std::memory_order_relaxed);
    if (inputData == nullptr || inputData->mNumberBuffers == 0) return noErr;

    const UInt32 required = state->nonInterleaved ? state->channels : 1;
    if (inputData->mNumberBuffers != state->tapBufferOffset + required) {
        state->formatMismatches.fetch_add(1, std::memory_order_relaxed);
        return noErr;
    }
    // Physical input streams are disabled before AudioDeviceStart. Their buffers
    // must remain NULL; never copy or inspect microphone sample data.
    for (UInt32 i = 0; i < state->tapBufferOffset; ++i) {
        if (inputData->mBuffers[i].mData != nullptr) {
            state->formatMismatches.fetch_add(1, std::memory_order_relaxed);
            return noErr;
        }
    }
    const AudioBuffer *buffers = &inputData->mBuffers[state->tapBufferOffset];
    if (buffers[0].mDataByteSize == 0) return noErr;
    if (state->nonInterleaved) {
        for (UInt32 channel = 0; channel < state->channels; ++channel) {
            if (buffers[channel].mNumberChannels != 1 ||
                !isFloatAligned(buffers[channel].mData) ||
                buffers[channel].mDataByteSize != buffers[0].mDataByteSize ||
                buffers[channel].mDataByteSize % sizeof(float) != 0) {
                state->formatMismatches.fetch_add(1, std::memory_order_relaxed);
                return noErr;
            }
        }
        state->writePlanar(buffers, buffers[0].mDataByteSize / sizeof(float));
    } else {
        if (buffers[0].mNumberChannels != state->channels ||
            !isFloatAligned(buffers[0].mData) || state->bytesPerFrame == 0 ||
            buffers[0].mDataByteSize % state->bytesPerFrame != 0) {
            state->formatMismatches.fetch_add(1, std::memory_order_relaxed);
            return noErr;
        }
        state->writeInterleaved(static_cast<const float *>(buffers[0].mData),
                               buffers[0].mDataByteSize / state->bytesPerFrame);
    }
    return noErr;
}

// Enable ONLY the final input stream (the sole process tap), no physical input
// and no aggregate output. Verify HAL readback before any callback can run.
OSStatus configureStreamUsage(AudioObjectID device, AudioDeviceIOProcID ioProc,
                              AudioObjectPropertyScope scope, bool finalInputOnly) {
    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyStreams, scope, kAudioObjectPropertyElementMain
    };
    UInt32 size = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(device, &address, 0, nullptr, &size);
    if (status != noErr) return status;
    const UInt32 count = size / sizeof(AudioStreamID);
    if (count == 0) return finalInputOnly ? kAudioHardwareBadStreamError : noErr;
    const size_t usageSize = offsetof(AudioHardwareIOProcStreamUsage, mStreamIsOn) +
        static_cast<size_t>(count) * sizeof(UInt32);
    std::vector<std::max_align_t> memory((usageSize + sizeof(std::max_align_t) - 1) /
                                       sizeof(std::max_align_t));
    auto *usage = reinterpret_cast<AudioHardwareIOProcStreamUsage *>(memory.data());
    usage->mIOProc = reinterpret_cast<void *>(ioProc);
    usage->mNumberStreams = count;
    for (UInt32 i = 0; i < count; ++i) usage->mStreamIsOn[i] = finalInputOnly && i == count - 1 ? 1 : 0;
    address.mSelector = kAudioDevicePropertyIOProcStreamUsage;
    status = AudioObjectSetPropertyData(device, &address, 0, nullptr,
                                       static_cast<UInt32>(usageSize), usage);
    if (status != noErr) return status;
    UInt32 readSize = static_cast<UInt32>(usageSize);
    status = AudioObjectGetPropertyData(device, &address, 0, nullptr, &readSize, usage);
    if (status != noErr) return status;
    if (usage->mNumberStreams != count) return kAudioHardwareBadStreamError;
    for (UInt32 i = 0; i < count; ++i) {
        if ((usage->mStreamIsOn[i] != 0) != (finalInputOnly && i == count - 1)) {
            return kAudioHardwareIllegalOperationError;
        }
    }
    return noErr;
}

OSStatus tapBufferOffset(AudioObjectID device, const AudioStreamBasicDescription &format,
                         UInt32 *offset) {
    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyScopeInput,
        kAudioObjectPropertyElementMain
    };
    UInt32 size = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(device, &address, 0, nullptr, &size);
    if (status != noErr) return status;
    if (size < sizeof(AudioBufferList)) return kAudioHardwareBadStreamError;
    std::vector<std::max_align_t> memory((size + sizeof(std::max_align_t) - 1) /
                                       sizeof(std::max_align_t));
    auto *list = reinterpret_cast<AudioBufferList *>(memory.data());
    status = AudioObjectGetPropertyData(device, &address, 0, nullptr, &size, list);
    if (status != noErr) return status;
    const bool planar = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    const UInt32 required = planar ? format.mChannelsPerFrame : 1;
    if (list->mNumberBuffers < required) return kAudioHardwareBadStreamError;
    *offset = list->mNumberBuffers - required;
    for (UInt32 i = *offset; i < list->mNumberBuffers; ++i) {
        if (list->mBuffers[i].mNumberChannels != (planar ? 1 : format.mChannelsPerFrame)) {
            return kAudioHardwareBadStreamError;
        }
    }
    return noErr;
}

NSError *captureError(NSString *operation, OSStatus status) {
    NSString *message = [NSString stringWithFormat:@"%@ failed with Core Audio status %d.",
                         operation,
                         static_cast<int>(status)];
    return [NSError errorWithDomain:kCaptureErrorDomain
                               code:status
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

} // namespace

@interface SRPCMChunk ()
@property(nonatomic, readwrite) NSData *data;
@property(nonatomic, readwrite) UInt32 frameCount;
- (instancetype)initWithData:(NSData *)data frameCount:(UInt32)frameCount;
@end

@implementation SRPCMChunk

- (instancetype)initWithData:(NSData *)data frameCount:(UInt32)frameCount {
    self = [super init];
    if (self) {
        _data = data;
        _frameCount = frameCount;
    }
    return self;
}

@end

@implementation SRAudioCaptureBridge

- (instancetype)init {
    self = [super init];
    if (self) {
        static_assert((kRingCapacityFrames & (kRingCapacityFrames - 1)) == 0,
                      "Ring capacity must be a power of two");
        _captureStorage = new CaptureStorage(kRingCapacityFrames);
        _deviceID = kAudioObjectUnknown;
        _ioProcID = nullptr;
        _ioProcMayBeRunning = NO;
    }
    return self;
}

- (void)dealloc {
    const BOOL stopped = [self stopWithError:nil];
    // A failed IOProc destruction is extremely rare, but freeing callback memory
    // would be unsafe. Leak the bounded storage until process exit instead.
    if (stopped) delete storage(self);
    _captureStorage = nullptr;
}

- (BOOL)isCapturing {
    return _ioProcID != nullptr;
}

- (UInt32)availableFrameCount {
    auto *state = storage(self);
    return state == nullptr ? 0 : state->available();
}

- (UInt64)droppedFrameCount {
    auto *state = storage(self);
    return state == nullptr ? 0 : state->droppedFrames.load(std::memory_order_relaxed);
}

- (UInt64)formatMismatchCount {
    auto *state = storage(self);
    return state == nullptr ? 0 : state->formatMismatches.load(std::memory_order_relaxed);
}

- (UInt64)callbackCount {
    auto *state = storage(self);
    return state == nullptr ? 0 : state->callbacks.load(std::memory_order_relaxed);
}

- (UInt64)capturedFrameCount {
    auto *state = storage(self);
    return state == nullptr ? 0 : state->capturedFrames.load(std::memory_order_relaxed);
}

- (float)peakLevel {
    auto *state = storage(self);
    return state == nullptr ? 0.0f : state->takePeak();
}

- (BOOL)startCapturingDevice:(AudioObjectID)deviceID
                      format:(AudioStreamBasicDescription)format
                       error:(NSError * _Nullable __autoreleasing *)error {
    if (error != nullptr) *error = nil;

    NSError *stopError = nil;
    if (![self stopWithError:&stopError]) {
        if (error != nullptr) *error = stopError;
        return NO;
    }

    const AudioFormatFlags allowedFlags = kAudioFormatFlagIsFloat |
        kAudioFormatFlagIsPacked |
        kAudioFormatFlagIsNonInterleaved |
        kAudioFormatFlagIsNonMixable;
    const bool hasOnlySupportedFlags = (format.mFormatFlags & ~allowedFlags) == 0;
    const bool isFloatPCM = format.mFormatID == kAudioFormatLinearPCM &&
        hasOnlySupportedFlags &&
        (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0 &&
        (format.mFormatFlags & kAudioFormatFlagIsPacked) != 0 &&
        (format.mFormatFlags & kAudioFormatFlagIsBigEndian) == 0;
    const bool nonInterleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    const UInt32 expectedBytesPerFrame = sizeof(float) * (nonInterleaved ? 1 : format.mChannelsPerFrame);
    const bool isSupportedFloat32 = isFloatPCM &&
        format.mChannelsPerFrame >= 1 && format.mChannelsPerFrame <= 32 &&
        format.mBitsPerChannel == 32 &&
        std::isfinite(format.mSampleRate) &&
        format.mSampleRate > 0 &&
        format.mFramesPerPacket == 1 &&
        format.mBytesPerFrame == expectedBytesPerFrame &&
        format.mBytesPerPacket == expectedBytesPerFrame &&
        format.mReserved == 0;
    if (!isSupportedFloat32) {
        if (error != nullptr) {
            NSString *description = [NSString stringWithFormat:
                @"Expected packed native-endian 1–32 channel Float32 PCM; received format '%c%c%c%c', flags 0x%08x, %u channels, %u bits, %u bytes/frame, %u frames/packet at %.3f Hz.",
                static_cast<char>((format.mFormatID >> 24) & 0xff),
                static_cast<char>((format.mFormatID >> 16) & 0xff),
                static_cast<char>((format.mFormatID >> 8) & 0xff),
                static_cast<char>(format.mFormatID & 0xff),
                format.mFormatFlags,
                format.mChannelsPerFrame,
                format.mBitsPerChannel,
                format.mBytesPerFrame,
                format.mFramesPerPacket,
                format.mSampleRate];
            *error = [NSError errorWithDomain:kCaptureErrorDomain
                                         code:-1
                                     userInfo:@{NSLocalizedDescriptionKey: description}];
        }
        return NO;
    }

    auto *state = storage(self);
    state->configure(format.mChannelsPerFrame, nonInterleaved);
    OSStatus layoutStatus = tapBufferOffset(deviceID, format, &state->tapBufferOffset);
    if (layoutStatus != noErr) {
        if (error != nullptr) *error = captureError(@"验证捕获缓冲布局", layoutStatus);
        return NO;
    }

    AudioDeviceIOProcID ioProcID = nullptr;
    OSStatus status = AudioDeviceCreateIOProcID(deviceID,
                                                captureIOProc,
                                                state,
                                                &ioProcID);
    if (status != noErr) {
        if (error != nullptr) *error = captureError(@"Creating the tap callback", status);
        return NO;
    }

    _deviceID = deviceID;
    _ioProcID = ioProcID;
    status = configureStreamUsage(deviceID, ioProcID, kAudioDevicePropertyScopeInput, true);
    if (status == noErr) {
        status = configureStreamUsage(deviceID, ioProcID, kAudioDevicePropertyScopeOutput, false);
    }
    if (status != noErr) {
        NSError *cleanupError = nil;
        [self stopWithError:&cleanupError];
        if (error != nullptr) *error = cleanupError ?: captureError(@"禁用物理输入与聚合输出", status);
        return NO;
    }
    // Set this before AudioDeviceStart. If start reports an error after doing
    // partial work, cleanup will still make a conservative stop attempt.
    _ioProcMayBeRunning = YES;

    status = AudioDeviceStart(deviceID, ioProcID);
    if (status != noErr) {
        NSError *cleanupError = nil;
        [self stopWithError:&cleanupError];
        if (error != nullptr) {
            NSError *startError = captureError(@"Starting the tap callback", status);
            if (cleanupError != nil) {
                NSString *message = [NSString stringWithFormat:@"%@ Cleanup also failed: %@",
                                     startError.localizedDescription,
                                     cleanupError.localizedDescription];
                *error = [NSError errorWithDomain:kCaptureErrorDomain
                                             code:status
                                         userInfo:@{NSLocalizedDescriptionKey: message}];
            } else {
                *error = startError;
            }
        }
        return NO;
    }

    return YES;
}

- (BOOL)stopWithError:(NSError * _Nullable __autoreleasing *)error {
    if (error != nullptr) *error = nil;
    if (_ioProcID == nullptr && _deviceID == kAudioObjectUnknown) {
        _ioProcMayBeRunning = NO;
        return YES;
    }
    if (_ioProcID == nullptr || _deviceID == kAudioObjectUnknown) {
        if (error != nullptr) {
            *error = [NSError errorWithDomain:kCaptureErrorDomain
                                         code:-2
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"The tap callback has inconsistent Core Audio ownership state."
            }];
        }
        return NO;
    }

    OSStatus stopStatus = noErr;
    if (_ioProcMayBeRunning) {
        stopStatus = AudioDeviceStop(_deviceID, _ioProcID);
        if (stopStatus == noErr || stopStatus == kAudioHardwareNotRunningError) {
            _ioProcMayBeRunning = NO;
        }
    }

    // Always attempt destruction. It is the authoritative ownership boundary:
    // once this succeeds, HAL can no longer call the clientData pointer even if
    // AudioDeviceStop returned an error.
    const OSStatus destroyStatus = AudioDeviceDestroyIOProcID(_deviceID, _ioProcID);
    if (destroyStatus == noErr) {
        _ioProcID = nullptr;
        _deviceID = kAudioObjectUnknown;
        _ioProcMayBeRunning = NO;
        return YES;
    }

    if (error != nullptr) {
        NSError *destroyError = captureError(@"Destroying the tap callback", destroyStatus);
        if (stopStatus != noErr && stopStatus != kAudioHardwareNotRunningError) {
            NSError *stopError = captureError(@"Stopping the tap callback", stopStatus);
            NSString *message = [NSString stringWithFormat:@"%@ %@",
                                 stopError.localizedDescription,
                                 destroyError.localizedDescription];
            *error = [NSError errorWithDomain:kCaptureErrorDomain
                                         code:destroyStatus
                                     userInfo:@{NSLocalizedDescriptionKey: message}];
        } else {
            *error = destroyError;
        }
    }
    return NO;
}

- (void)reset {
    // Resetting cursors while the real-time producer is active would violate
    // the SPSC ring invariants. The app only resets before capture or in tests.
    if (_ioProcMayBeRunning) return;
    auto *state = storage(self);
    if (state != nullptr) state->reset();
}

- (SRPCMChunk *)dequeueChunkWithMaximumFrameCount:(UInt32)maximumFrameCount {
    auto *state = storage(self);
    if (state == nullptr || maximumFrameCount == 0) return nil;

    const UInt32 available = state->available();
    const UInt32 requested = std::min(maximumFrameCount, available);
    if (requested == 0) return nil;

    NSMutableData *data = [NSMutableData dataWithLength:static_cast<NSUInteger>(requested) * state->channels * sizeof(float)];
    const UInt32 actual = state->readInterleaved(static_cast<float *>(data.mutableBytes), requested);
    if (actual == 0) return nil;
    if (actual < requested) {
        data.length = static_cast<NSUInteger>(actual) * state->channels * sizeof(float);
    }
    return [[SRPCMChunk alloc] initWithData:data frameCount:actual];
}

#if DEBUG
- (void)debugConfigureChannels:(UInt32)channels planar:(BOOL)planar tapBufferOffset:(UInt32)offset {
    if (_ioProcMayBeRunning || channels == 0 || channels > 32) return;
    auto *state = storage(self);
    state->configure(channels, planar);
    state->tapBufferOffset = offset;
}

- (void)debugEnqueueBufferList:(const AudioBufferList *)buffers {
    if (_ioProcMayBeRunning) return;
    captureIOProc(0, nullptr, buffers, nullptr, nullptr, nullptr, storage(self));
}

- (void)debugEnqueueInterleavedFloatData:(NSData *)data {
    auto *state = storage(self);
    if (_ioProcMayBeRunning ||
        state == nullptr ||
        !isFloatAligned(data.bytes) ||
        data.length % (state->channels * sizeof(float)) != 0) return;
    const UInt32 frames = static_cast<UInt32>(data.length / (state->channels * sizeof(float)));
    state->writeInterleaved(static_cast<const float *>(data.bytes), frames);
}
#endif

@end
