#import <CoreAudio/CoreAudio.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SRPCMChunk : NSObject

@property(nonatomic, readonly) NSData *data;
@property(nonatomic, readonly) UInt32 frameCount;

- (instancetype)init NS_UNAVAILABLE;

@end

/// Copies HAL-owned tap buffers into a bounded, preallocated SPSC ring.
/// The Core Audio callback performs no allocation, locking, logging, or UI work.
@interface SRAudioCaptureBridge : NSObject {
@public
    void *_captureStorage;
@private
    AudioObjectID _deviceID;
    AudioDeviceIOProcID _ioProcID;
    BOOL _ioProcMayBeRunning;
}

@property(nonatomic, readonly, getter=isCapturing) BOOL capturing;
@property(nonatomic, readonly) UInt32 availableFrameCount;
@property(nonatomic, readonly) UInt64 droppedFrameCount;
@property(nonatomic, readonly) UInt64 formatMismatchCount;
@property(nonatomic, readonly) UInt64 callbackCount;
@property(nonatomic, readonly) UInt64 capturedFrameCount;
@property(nonatomic, readonly) float peakLevel;

- (BOOL)startCapturingDevice:(AudioObjectID)deviceID
                      format:(AudioStreamBasicDescription)format
                       error:(NSError * _Nullable * _Nullable)error;

- (BOOL)stopWithError:(NSError * _Nullable * _Nullable)error;
- (void)reset;

/// Call only from one non-real-time consumer queue.
- (nullable SRPCMChunk *)dequeueChunkWithMaximumFrameCount:(UInt32)maximumFrameCount;

#if DEBUG
/// Deterministic unit-test hook. Never used by the app's relay path.
- (void)debugEnqueueInterleavedFloatData:(NSData *)data;
#endif

@end

NS_ASSUME_NONNULL_END
