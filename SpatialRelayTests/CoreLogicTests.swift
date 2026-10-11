import CoreAudio
import CoreMedia
import XCTest
@testable import SpatialRelay

final class CoreLogicTests: XCTestCase {
    func testFamilyMatcherIncludesNetEaseChromeAndHelpersOnly() {
        let targets = RelayConfiguration().targetBundleIDs
        for bundle in ["com.netease.163music", "com.netease.163music.helper",
                       "com.google.Chrome", "com.google.Chrome.helper.Renderer"] {
            XCTAssertTrue(AppFamilyMatcher.matches(bundleIdentifier: bundle, owningAppBundleIdentifier: nil, targets: targets))
        }
        for bundle in ["com.apple.Safari", "com.google.ChromeCanary",
                       "com.netease.163musicx", "", "com.ranco7.SpatialRelay"] {
            XCTAssertFalse(AppFamilyMatcher.matches(bundleIdentifier: bundle, owningAppBundleIdentifier: nil, targets: targets))
        }
    }

    func testFamilyMatcherUsesOwningAppForDifferentlyNamedHelpers() {
        let targets = RelayConfiguration().targetBundleIDs
        XCTAssertTrue(AppFamilyMatcher.matches(bundleIdentifier: "org.chromium.utility",
            owningAppBundleIdentifier: "com.google.Chrome", targets: targets))
        XCTAssertTrue(AppFamilyMatcher.matches(bundleIdentifier: "",
            owningAppBundleIdentifier: "com.netease.163music", targets: targets))
        XCTAssertFalse(AppFamilyMatcher.matches(bundleIdentifier: "com.google.Chrome.helper",
            owningAppBundleIdentifier: "com.example.Other", targets: targets))
        let path = "/Applications/Google Chrome.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper"
        XCTAssertEqual(AppFamilyMatcher.outerAppURL(executablePath: path)?.path, "/Applications/Google Chrome.app")
        XCTAssertNil(AppFamilyMatcher.outerAppURL(executablePath: "/usr/bin/afplay"))
    }

    func testConfigurationAndRetryAreBounded() throws {
        XCTAssertEqual(RelayConfiguration().targetBundleIDs, ["com.netease.163music", "com.google.Chrome"])
        XCTAssertNoThrow(try RelayConfiguration().validated())
        var config = RelayConfiguration()
        config.targetBundleIDs = []
        XCTAssertThrowsError(try config.validated())
        config.targetBundleIDs = ["com.ranco7.SpatialRelay"]
        XCTAssertThrowsError(try config.validated())
        config.targetBundleIDs = ["com.google.Chrome "]
        XCTAssertThrowsError(try config.validated())
        var retry = RetryBackoff()
        XCTAssertEqual((0..<8).map { _ in retry.nextDelay() }, [5, 10, 20, 40, 60, 60, 60, 60])
        retry.reset()
        XCTAssertEqual(retry.nextDelay(), 5)
    }

    func testPCMFactoryPreservesInterleavedMonoAndStereoBits() throws {
        for channels: UInt32 in [1, 2] {
            let bits: [UInt32] = channels == 1 ?
                [0x80000000, 0x00000001, 0x3f123456] :
                [0x80000000, 0x00000001, 0x3f123456, 0xbf654321]
            let data = bits.withUnsafeBytes { Data($0) }
            let factory = try PCMSampleBufferFactory(sampleRate: 48_000, channelCount: channels, channelLayout: nil)
            let sample = try factory.makeSampleBuffer(data: data,
                frameCount: UInt32(bits.count) / channels, startingAtFrame: 0)
            let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
            var output = Data(count: data.count)
            let status = output.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: data.count, destination: $0.baseAddress!)
            }
            XCTAssertEqual(status, noErr)
            XCTAssertEqual(data, output)
            XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(sample), .zero)
        }
        XCTAssertThrowsError(try PCMSampleBufferFactory(sampleRate: 48_000, channelCount: 6, channelLayout: nil))
    }

    func testMonoAndSixChannelRingPreserveEveryByte() throws {
        for channels: UInt32 in [1, 6] {
            let bridge = SRAudioCaptureBridge()
            bridge.debugConfigureChannels(channels, planar: false, tapBufferOffset: 0)
            let bits = (0..<Int(channels * 4)).map { UInt32($0) &+ 0x3e800000 }
            let input = bits.withUnsafeBytes { Data($0) }
            bridge.debugEnqueueInterleavedFloat(input)
            let chunk = try XCTUnwrap(bridge.dequeueChunk(withMaximumFrameCount: 4))
            XCTAssertEqual(chunk.frameCount, 4)
            XCTAssertEqual(chunk.data, input)
        }
    }

    func testPlanarTapIgnoresPhysicalInputAndCopiesStereoBits() throws {
        let bridge = SRAudioCaptureBridge()
        bridge.debugConfigureChannels(2, planar: true, tapBufferOffset: 1)
        var left: [UInt32] = [0x80000000, 0x3f123456]
        var right: [UInt32] = [0x00000001, 0xbf654321]
        let size = MemoryLayout<AudioBufferList>.size + 2 * MemoryLayout<AudioBuffer>.stride
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { pointer.deallocate() }
        pointer.initializeMemory(as: UInt8.self, repeating: 0, count: size)
        let list = pointer.bindMemory(to: AudioBufferList.self, capacity: 1)
        list.pointee.mNumberBuffers = 3
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        buffers[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 8, mData: nil)
        left.withUnsafeMutableBytes { l in
            right.withUnsafeMutableBytes { r in
                buffers[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 8, mData: l.baseAddress)
                buffers[2] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 8, mData: r.baseAddress)
                bridge.debugEnqueueBufferList(list)
                // Any enabled physical input invalidates the entire callback.
                buffers[0].mData = l.baseAddress
                bridge.debugEnqueueBufferList(list)
            }
        }
        let chunk = try XCTUnwrap(bridge.dequeueChunk(withMaximumFrameCount: 4))
        let expected: [UInt32] = [left[0], right[0], left[1], right[1]]
        XCTAssertEqual(chunk.data, expected.withUnsafeBytes { Data($0) })
        XCTAssertEqual(bridge.formatMismatchCount, 1)
        XCTAssertEqual(bridge.capturedFrameCount, 2)
    }

    func testAirPodsOutputDetectionIsCaseInsensitive() {
        let airPods = OutputDeviceInfo(
            id: 1,
            uid: "airpods",
            name: "TEST AIRPODS PRO",
            sampleRate: 48_000
        )
        let speakers = OutputDeviceInfo(
            id: 2,
            uid: "speakers",
            name: "MacBook Pro Speakers",
            sampleRate: 48_000
        )

        XCTAssertTrue(airPods.isLikelySpatialAudioHeadphones)
        XCTAssertFalse(speakers.isLikelySpatialAudioHeadphones)
    }

    func testOSStatusDescriptionShowsFourCharacterCode() {
        let status = OSStatus(bitPattern: 0x666D743F) // 'fmt?'
        XCTAssertEqual(CoreAudioFailure.describe(status), "'fmt?' / 1718449215")
        XCTAssertEqual(CoreAudioFailure.describe(-50), "-50")
    }

    func testRendererRecoveryRebasesAtLatestValidOutputTime() {
        let timescale: CMTimeScale = 48_000
        let currentTime = CMTime(value: 96_000, timescale: timescale)

        XCTAssertEqual(
            RendererRecoveryTimeline.restartFrame(
                currentTime: currentTime,
                suggestedFlushTime: CMTime(value: 72_000, timescale: timescale),
                timescale: timescale,
                fallbackFrame: 150_000
            ),
            96_000,
            "Flushed renderer timestamps must not force the live timeline backwards"
        )
        XCTAssertEqual(
            RendererRecoveryTimeline.restartFrame(
                currentTime: currentTime,
                suggestedFlushTime: CMTime(value: 120_000, timescale: timescale),
                timescale: timescale,
                fallbackFrame: 150_000
            ),
            120_000,
            "A later automatic-flush timestamp must remain eligible as the restart anchor"
        )
        XCTAssertEqual(
            RendererRecoveryTimeline.restartFrame(
                currentTime: .invalid,
                suggestedFlushTime: nil,
                timescale: timescale,
                fallbackFrame: 150_000
            ),
            150_000
        )
    }

    func testOutputReconfigurationGraceIncludesFiveSecondBoundary() {
        let start: UInt64 = 10_000
        XCTAssertTrue(
            OutputReconfigurationGrace.contains(
                startUptimeNanoseconds: start,
                nowUptimeNanoseconds: start + OutputReconfigurationGrace.durationNanoseconds
            )
        )
        XCTAssertFalse(
            OutputReconfigurationGrace.contains(
                startUptimeNanoseconds: start,
                nowUptimeNanoseconds: start + OutputReconfigurationGrace.durationNanoseconds + 1
            )
        )
    }

    func testCaptureRingPreservesStereoFramesAndConsumesPeak() throws {
        let bridge = SRAudioCaptureBridge()
        let input: [Float] = [0.25, -0.5, 0.75, -0.125, -0.2, 0.4]
        let data = input.withUnsafeBytes { Data($0) }

        bridge.debugEnqueueInterleavedFloat(data)

        XCTAssertEqual(bridge.availableFrameCount, 3)
        XCTAssertEqual(bridge.capturedFrameCount, 3)
        XCTAssertEqual(bridge.peakLevel, 0.75, accuracy: 0.0001)
        XCTAssertEqual(bridge.peakLevel, 0, accuracy: 0.0001)

        let firstChunk = try XCTUnwrap(bridge.dequeueChunk(withMaximumFrameCount: 2))
        XCTAssertEqual(firstChunk.frameCount, 2)
        XCTAssertEqual(floatArray(from: firstChunk.data), Array(input.prefix(4)))

        let secondChunk = try XCTUnwrap(bridge.dequeueChunk(withMaximumFrameCount: 8))
        XCTAssertEqual(secondChunk.frameCount, 1)
        XCTAssertEqual(floatArray(from: secondChunk.data), Array(input.suffix(2)))
        XCTAssertEqual(bridge.availableFrameCount, 0)
    }

    func testCaptureRingBoundsOverflowAndReportsDroppedFrames() {
        let bridge = SRAudioCaptureBridge()
        let capacity = 524_288
        let extraFrames = 17
        let input = [Float](repeating: 0.1, count: (capacity + extraFrames) * 2)

        bridge.debugEnqueueInterleavedFloat(input.withUnsafeBytes { Data($0) })

        XCTAssertEqual(bridge.availableFrameCount, UInt32(capacity))
        XCTAssertEqual(bridge.capturedFrameCount, UInt64(capacity))
        XCTAssertEqual(bridge.droppedFrameCount, UInt64(extraFrames))

        bridge.reset()
        XCTAssertEqual(bridge.availableFrameCount, 0)
        XCTAssertEqual(bridge.capturedFrameCount, 0)
        XCTAssertEqual(bridge.droppedFrameCount, 0)
    }

    func testCaptureRingPreservesOrderAcrossStorageWrap() throws {
        let bridge = SRAudioCaptureBridge()
        let capacity = 524_288
        let initialFrameCount = capacity - 2
        var initial = [Float]()
        initial.reserveCapacity(initialFrameCount * 2)
        for frame in 0..<initialFrameCount {
            initial.append(Float(frame))
            initial.append(-Float(frame))
        }
        bridge.debugEnqueueInterleavedFloat(initial.withUnsafeBytes { Data($0) })

        _ = try XCTUnwrap(
            bridge.dequeueChunk(withMaximumFrameCount: UInt32(initialFrameCount - 2))
        )

        let wrapped: [Float] = [
            1_000_001, -1_000_001,
            1_000_002, -1_000_002,
            1_000_003, -1_000_003,
            1_000_004, -1_000_004,
            1_000_005, -1_000_005,
            1_000_006, -1_000_006
        ]
        bridge.debugEnqueueInterleavedFloat(wrapped.withUnsafeBytes { Data($0) })

        let output = try XCTUnwrap(bridge.dequeueChunk(withMaximumFrameCount: 8))
        let expected = Array(initial.suffix(4)) + wrapped
        XCTAssertEqual(output.frameCount, 8)
        XCTAssertEqual(floatArray(from: output.data), expected)
    }

    func testApplicationBundleContainsStablePrivacyIdentity() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.ranco7.SpatialRelay")
        XCTAssertNotNil(Bundle.main.object(forInfoDictionaryKey: "NSAudioCaptureUsageDescription"))
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundlePackageType") as? String, "APPL")
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleIconName") as? String, "AppIcon")
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool, true)
    }

    private func floatArray(from data: Data) -> [Float] {
        data.withUnsafeBytes { bytes in
            Array(bytes.bindMemory(to: Float.self))
        }
    }
}
