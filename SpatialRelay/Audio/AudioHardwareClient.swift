import AppKit
import CoreAudio
import Foundation
import Darwin

struct AudioProcessInfo: Equatable, Identifiable, Sendable {
    let id: AudioObjectID
    let pid: pid_t
    let bundleIdentifier: String
    let applicationName: String
    let isRunningOutput: Bool
}

struct OutputDeviceInfo: Equatable, Sendable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let sampleRate: Double

    var isLikelySpatialAudioHeadphones: Bool {
        let normalized = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return normalized.contains("airpods") ||
            normalized.contains("beats fit pro") ||
            normalized.contains("beats studio pro")
    }
}


struct RelayConfiguration: Codable, Equatable, Sendable {
    var targetBundleIDs: [String] = ["com.netease.163music", "com.google.Chrome"]
    // A renamed AirPods device can be selected by its stable UID.
    var outputDeviceUID: String? = nil

    func validated() throws -> RelayConfiguration {
        guard !targetBundleIDs.isEmpty, targetBundleIDs.count <= 16,
              targetBundleIDs.allSatisfy({ id in
                  id == id.trimmingCharacters(in: .whitespacesAndNewlines) &&
                  id.contains(".") && !id.hasPrefix(".") && !id.hasSuffix(".") &&
                  id.unicodeScalars.allSatisfy {
                      CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-"
                  } &&
                  !id.lowercased().hasPrefix("com.ranco7.spatialrelay")
              }),
              outputDeviceUID == nil || !(outputDeviceUID?.isEmpty ?? true) else {
            throw RelayError.configuration("目标应用标识或输出设备 UID 无效")
        }
        return self
    }

    static func read(_ url: URL) throws -> RelayConfiguration {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return RelayConfiguration()
        }
        // Reject misspelled keys rather than unexpectedly using a default target.
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any],
              Set(dictionary.keys).isSubset(of: ["targetBundleIDs", "outputDeviceUID"]),
              dictionary["targetBundleIDs"] != nil else {
            throw RelayError.configuration("JSON 配置必须包含 targetBundleIDs，且不能有未知字段")
        }
        return try JSONDecoder().decode(RelayConfiguration.self, from: data).validated()
    }
}

enum AppFamilyMatcher {
    static func matches(
        bundleIdentifier: String,
        owningAppBundleIdentifier: String?,
        targets: [String]
    ) -> Bool {
        let allowed = Set(targets.map { $0.lowercased() })
        // The outer .app identifies helpers even if they use a different bundle ID.
        // A known different owner must never be overridden by a matching name.
        if let owner = owningAppBundleIdentifier, !owner.isEmpty {
            return allowed.contains(owner.lowercased())
        }
        let bundle = bundleIdentifier.lowercased()
        guard !bundle.isEmpty else { return false }
        return allowed.contains { bundle == $0 || bundle.hasPrefix($0 + ".") }
    }

    static func outerAppURL(executablePath: String) -> URL? {
        let parts = URL(fileURLWithPath: executablePath).standardized.pathComponents
        guard let index = parts.firstIndex(where: { $0.lowercased().hasSuffix(".app") }) else {
            return nil
        }
        return URL(fileURLWithPath: NSString.path(withComponents: Array(parts[...index])))
    }
}

final class AudioHardwareClient {
    private let systemObject = AudioObjectID(kAudioObjectSystemObject)

    let configuration: RelayConfiguration

    init(configuration: RelayConfiguration = RelayConfiguration()) {
        self.configuration = configuration
    }

    func targetProcesses() throws -> [AudioProcessInfo] {
        var address = propertyAddress(kAudioHardwarePropertyProcessObjectList)
        var byteCount: UInt32 = 0
        try CoreAudioFailure.check(
            AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &byteCount),
            operation: "Reading the audio process list size"
        )

        let count = Int(byteCount) / MemoryLayout<AudioObjectID>.stride
        guard count > 0 else { return [] }
        var objectIDs = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
        let listStatus = objectIDs.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(systemObject, &address, 0, nil, &byteCount, bytes.baseAddress!)
        }
        try CoreAudioFailure.check(listStatus, operation: "Reading the audio process list")

        return objectIDs.compactMap { objectID in
            guard objectID != kAudioObjectUnknown else { return nil }

            let pid = (try? readPID(objectID)) ?? 0
            let coreAudioBundleID = (try? readString(objectID, selector: kAudioProcessPropertyBundleID)) ?? ""
            let application = NSRunningApplication(processIdentifier: pid)
            let bundleID = coreAudioBundleID.isEmpty ? (application?.bundleIdentifier ?? "") : coreAudioBundleID
            let applicationName = application?.localizedName ?? ""

            guard pid > 0, pid != getpid() else { return nil }
            var pathBytes = [CChar](repeating: 0, count: Int(PROC_PIDPATHINFO_MAXSIZE))
            let pathLength = pathBytes.withUnsafeMutableBytes {
                proc_pidpath(pid, $0.baseAddress, UInt32($0.count))
            }
            let path = pathLength > 0 ? String(cString: pathBytes) : ""
            let owner = AppFamilyMatcher.outerAppURL(executablePath: path)
                .flatMap { Bundle(url: $0)?.bundleIdentifier }
            guard AppFamilyMatcher.matches(
                bundleIdentifier: bundleID,
                owningAppBundleIdentifier: owner,
                targets: configuration.targetBundleIDs
            ) else { return nil }

            return AudioProcessInfo(
                id: objectID,
                pid: pid,
                bundleIdentifier: bundleID,
                applicationName: applicationName.isEmpty ? bundleID : applicationName,
                isRunningOutput: (try? readBool(objectID, selector: kAudioProcessPropertyIsRunningOutput)) ?? false
            )
        }
        .sorted {
            if $0.isRunningOutput != $1.isRunningOutput {
                return $0.isRunningOutput && !$1.isRunningOutput
            }
            return $0.pid < $1.pid
        }
    }

    func defaultOutputDevice() throws -> OutputDeviceInfo {
        var address = propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var byteCount = UInt32(MemoryLayout<AudioDeviceID>.size)
        try CoreAudioFailure.check(
            AudioObjectGetPropertyData(systemObject, &address, 0, nil, &byteCount, &deviceID),
            operation: "Finding the default output device"
        )

        guard deviceID != kAudioObjectUnknown else {
            throw RelayError.noOutputDevice
        }

        return OutputDeviceInfo(
            id: deviceID,
            uid: try readString(deviceID, selector: kAudioDevicePropertyDeviceUID),
            name: try readString(deviceID, selector: kAudioObjectPropertyName),
            sampleRate: try readDouble(deviceID, selector: kAudioDevicePropertyNominalSampleRate)
        )
    }

    func createTargetTap(processes: [AudioProcessInfo], outputDevice: OutputDeviceInfo) throws -> AudioObjectID {
        guard try streams(outputDevice.id, scope: kAudioDevicePropertyScopeOutput).count == 1 else {
            throw RelayError.unsupportedTapFormat("输出设备有多个硬件音频流，首版无法完整接管")
        }
        let description = CATapDescription()
        description.name = "空间音频桥 — 指定应用"
        description.processes = processes.map(\.id)
        description.isPrivate = true
        description.isExclusive = false
        description.isMixdown = false
        description.isMono = false
        description.muteBehavior = .mutedWhenTapped
        description.deviceUID = outputDevice.uid
        description.stream = 0

        var tapID = AudioObjectID(kAudioObjectUnknown)
        try CoreAudioFailure.check(
            AudioHardwareCreateProcessTap(description, &tapID),
            operation: "创建指定应用的音频捕获"
        )
        return tapID
    }

    func updateTapProcesses(_ tapID: AudioObjectID, processes: [AudioProcessInfo]) throws {
        guard !processes.isEmpty else { throw RelayError.targetNotRunning }
        var address = propertyAddress(kAudioTapPropertyDescription)
        var description: CATapDescription?
        var size = UInt32(MemoryLayout<CATapDescription?>.size)
        try CoreAudioFailure.check(
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &description),
            operation: "读取应用捕获描述"
        )
        guard let description else { throw RelayError.captureFailed("捕获描述已失效") }
        description.processes = processes.map(\.id)
        description.isExclusive = false
        var updated: CATapDescription? = description
        try CoreAudioFailure.check(
            AudioObjectSetPropertyData(tapID, &address, 0, nil, size, &updated),
            operation: "更新应用及辅助进程"
        )
    }

    func channelLayout(output: OutputDeviceInfo, channels: UInt32) throws -> Data? {
        guard channels > 2 else { return nil }
        var address = propertyAddress(kAudioDevicePropertyPreferredChannelLayout, scope: kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        try CoreAudioFailure.check(
            AudioObjectGetPropertyDataSize(output.id, &address, 0, nil, &size),
            operation: "读取多声道布局大小"
        )
        guard size >= MemoryLayout<AudioChannelLayout>.size, size <= 65_536 else {
            throw RelayError.unsupportedTapFormat("输出设备未提供可用的多声道布局")
        }
        var data = Data(count: Int(size))
        let status = data.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(output.id, &address, 0, nil, &size, $0.baseAddress!)
        }
        try CoreAudioFailure.check(status, operation: "读取多声道布局")
        data.count = Int(size)
        return data
    }

    func tapUID(_ tapID: AudioObjectID) throws -> String {
        try readString(tapID, selector: kAudioTapPropertyUID)
    }

    func tapFormat(_ tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = propertyAddress(kAudioTapPropertyFormat)
        var format = AudioStreamBasicDescription()
        var byteCount = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try CoreAudioFailure.check(
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &byteCount, &format),
            operation: "Reading the process tap format"
        )
        return format
    }

    func createAggregateDevice(tapUID: String, tapFormat: AudioStreamBasicDescription, output: OutputDeviceInfo) throws -> AudioObjectID {
        let aggregateUID = "com.ranco7.SpatialRelay.aggregate.\(UUID().uuidString)"
        let tapEntry: [String: Any] = [
            kAudioSubTapUIDKey: tapUID,
            kAudioSubTapDriftCompensationKey: false
        ]
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "空间音频桥捕获",
            kAudioAggregateDeviceSubDeviceListKey: [[
                kAudioSubDeviceUIDKey: output.uid,
                kAudioSubDeviceDriftCompensationKey: false
            ]],
            kAudioAggregateDeviceMainSubDeviceKey: output.uid,
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapListKey: [tapEntry]
        ]

        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        try CoreAudioFailure.check(
            AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID),
            operation: "Creating the private tap device"
        )
        // A separate free-running capture clock would accumulate drift against
        // AVFoundation's physical output. Verify that HAL accepted the output as master.
        do {
            guard try readString(aggregateID, selector: kAudioAggregateDevicePropertyMainSubDevice) == output.uid else {
                throw RelayError.captureFailed("系统没有采用输出设备作为捕获时钟源")
            }
            let aggregateRate = try readDouble(aggregateID, selector: kAudioDevicePropertyNominalSampleRate)
            guard abs(aggregateRate - output.sampleRate) <= 0.5 else {
                throw RelayError.unsupportedTapFormat("捕获聚合设备与耳机采样率不一致")
            }
            let physicalInputs = try streams(output.id, scope: kAudioDevicePropertyScopeInput)
            let aggregateInputs = try streams(aggregateID, scope: kAudioDevicePropertyScopeInput)
            guard aggregateInputs.count == physicalInputs.count + 1,
                  let tapStream = aggregateInputs.last else {
                throw RelayError.unsupportedTapFormat("聚合设备没有按预期提供唯一的应用捕获流")
            }
            var address = propertyAddress(kAudioStreamPropertyVirtualFormat)
            var streamFormat = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try CoreAudioFailure.check(
                AudioObjectGetPropertyData(tapStream, &address, 0, nil, &size, &streamFormat),
                operation: "校验捕获流格式"
            )
            guard streamFormat.mSampleRate == tapFormat.mSampleRate,
                  streamFormat.mFormatID == tapFormat.mFormatID,
                  streamFormat.mFormatFlags == tapFormat.mFormatFlags,
                  streamFormat.mBytesPerPacket == tapFormat.mBytesPerPacket,
                  streamFormat.mFramesPerPacket == tapFormat.mFramesPerPacket,
                  streamFormat.mBytesPerFrame == tapFormat.mBytesPerFrame,
                  streamFormat.mChannelsPerFrame == tapFormat.mChannelsPerFrame,
                  streamFormat.mBitsPerChannel == tapFormat.mBitsPerChannel else {
                throw RelayError.unsupportedTapFormat("聚合设备改变了应用捕获流格式，停止接管")
            }
        } catch {
            let status = AudioHardwareDestroyAggregateDevice(aggregateID)
            guard status == noErr else {
                throw RelayError.cleanupFailed("聚合设备校验失败且无法释放：\(CoreAudioFailure.describe(status))")
            }
            throw error
        }
        return aggregateID
    }

    @discardableResult
    func destroyAggregateDevice(_ deviceID: AudioObjectID) -> OSStatus {
        guard deviceID != kAudioObjectUnknown else { return noErr }
        return AudioHardwareDestroyAggregateDevice(deviceID)
    }

    @discardableResult
    func destroyTap(_ tapID: AudioObjectID) -> OSStatus {
        guard tapID != kAudioObjectUnknown else { return noErr }
        return AudioHardwareDestroyProcessTap(tapID)
    }

    /// Restores direct process audio even if a lower-level callback cannot be
    /// destroyed immediately. This is the teardown path's last-resort safety net.
    @discardableResult
    func unmuteTap(_ tapID: AudioObjectID) -> OSStatus {
        guard tapID != kAudioObjectUnknown else { return noErr }

        var address = propertyAddress(kAudioTapPropertyDescription)
        var description: CATapDescription?
        var byteCount = UInt32(MemoryLayout<CATapDescription?>.size)
        let readStatus = withUnsafeMutablePointer(to: &description) { pointer in
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &byteCount, pointer)
        }
        guard readStatus == noErr else { return readStatus }
        guard let description else { return kAudioHardwareUnspecifiedError }

        description.muteBehavior = .unmuted
        var updatedDescription: CATapDescription? = description
        byteCount = UInt32(MemoryLayout<CATapDescription?>.size)
        return withUnsafePointer(to: &updatedDescription) { pointer in
            AudioObjectSetPropertyData(tapID, &address, 0, nil, byteCount, pointer)
        }
    }

    private func streams(_ device: AudioObjectID, scope: AudioObjectPropertyScope) throws -> [AudioStreamID] {
        var address = propertyAddress(kAudioDevicePropertyStreams, scope: scope)
        var size: UInt32 = 0
        try CoreAudioFailure.check(
            AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size),
            operation: "读取硬件音频流数量"
        )
        guard size % UInt32(MemoryLayout<AudioStreamID>.stride) == 0 else {
            throw RelayError.unsupportedTapFormat("硬件音频流列表无效")
        }
        guard size > 0 else { return [] }
        var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.stride)
        let status = streams.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0.baseAddress!)
        }
        try CoreAudioFailure.check(status, operation: "读取硬件音频流")
        return Array(streams.prefix(Int(size) / MemoryLayout<AudioStreamID>.stride))
    }

    private func readPID(_ objectID: AudioObjectID) throws -> pid_t {
        var address = propertyAddress(kAudioProcessPropertyPID)
        var value: pid_t = 0
        var byteCount = UInt32(MemoryLayout<pid_t>.size)
        try CoreAudioFailure.check(
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &byteCount, &value),
            operation: "Reading an audio process identifier"
        )
        return value
    }

    private func readBool(_ objectID: AudioObjectID, selector: AudioObjectPropertySelector) throws -> Bool {
        var address = propertyAddress(selector)
        var value: UInt32 = 0
        var byteCount = UInt32(MemoryLayout<UInt32>.size)
        try CoreAudioFailure.check(
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &byteCount, &value),
            operation: "Reading an audio property"
        )
        return value != 0
    }

    private func readDouble(_ objectID: AudioObjectID, selector: AudioObjectPropertySelector) throws -> Double {
        var address = propertyAddress(selector)
        var value: Float64 = 0
        var byteCount = UInt32(MemoryLayout<Float64>.size)
        try CoreAudioFailure.check(
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &byteCount, &value),
            operation: "Reading an audio property"
        )
        return value
    }

    private func readString(_ objectID: AudioObjectID, selector: AudioObjectPropertySelector) throws -> String {
        var address = propertyAddress(selector)
        var value: CFString = "" as CFString
        var byteCount = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &byteCount, pointer)
        }
        try CoreAudioFailure.check(status, operation: "Reading an audio property")
        return value as String
    }
}
