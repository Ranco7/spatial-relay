import AppKit
import AVFoundation
import CoreAudio
import Foundation
import OSLog

enum RelayPaths {
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SpatialRelay", isDirectory: true)
    }
    static var config: URL { root.appendingPathComponent("config.json") }
    static var status: URL { root.appendingPathComponent("status.json") }
}

struct RetryBackoff {
    private(set) var failures = 0
    mutating func reset() { failures = 0 }
    mutating func nextDelay() -> TimeInterval {
        failures = min(failures + 1, 5)
        return min(60, 5 * pow(2, Double(failures - 1)))
    }
}

final class BackgroundRelay: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.ranco7.SpatialRelay.background")
    private let logger = Logger(subsystem: "com.ranco7.SpatialRelay", category: "relay")
    private let configURL: URL
    private var configuration: RelayConfiguration?
    private var configStamp: Date?
    private var configWasRead = false
    private var coordinator: AudioRelayCoordinator?
    private var timer: DispatchSourceTimer?
    private var isActive = false
    private var isStopped = false
    private var suspended = false
    private var eventIsPending = false
    private var generation: UInt64 = 0
    private var retry = RetryBackoff()
    private var retryAfter: TimeInterval = 0
    private var lastMessage = ""
    private var lastStatusWrite: TimeInterval = 0
    private var lastTargets: [AudioProcessInfo] = []
    private var lastOutput: OutputDeviceInfo?
    private var hardwareListeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var observedOutputID = AudioObjectID(kAudioObjectUnknown)

    init(configURL: URL) { self.configURL = configURL }

    func start() {
        queue.async { [self] in
            addListener(object: AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyProcessObjectList)
            addListener(object: AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDefaultOutputDevice)
            addListener(object: AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDevices)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .seconds(2), leeway: .milliseconds(500))
            timer.setEventHandler { [weak self] in self?.reconcile() }
            self.timer = timer
            timer.resume()
        }
    }

    func setSuspended(_ value: Bool) {
        queue.async { [self] in
            suspended = value
            if value {
                stopPipeline()
                publish("休眠，等待唤醒")
            } else {
                retry.reset()
                retryAfter = 0
                reconcile()
            }
        }
    }

    func requestReconcile() {
        queue.async { [self] in
            guard !isStopped, !eventIsPending else { return }
            eventIsPending = true
            queue.asyncAfter(deadline: .now() + .milliseconds(150)) { [self] in
                eventIsPending = false
                reconcile()
            }
        }
    }

    func stop() {
        queue.sync {
            guard !isStopped else { return }
            isStopped = true
            timer?.setEventHandler {}
            timer?.cancel()
            timer = nil
            for (object, address, block) in hardwareListeners {
                var mutableAddress = address
                let status = AudioObjectRemovePropertyListenerBlock(object, &mutableAddress, queue, block)
                if status != noErr { logger.error("移除硬件监听失败：\(status)") }
            }
            hardwareListeners.removeAll()
            stopPipeline()
            publish("已停止，应用恢复直接播放")
        }
    }

    private func stopPipeline() {
        generation &+= 1
        isActive = false
        if let error = coordinator?.stop() {
            logger.error("\(error.localizedDescription, privacy: .public)")
            // Exit releases all private HAL resources; launchd restarts with throttle.
            exit(1)
        }
    }

    private func addListener(
        object: AudioObjectID, selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) {
        var address = propertyAddress(selector, scope: scope)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.requestReconcile() }
        let status = AudioObjectAddPropertyListenerBlock(object, &address, queue, block)
        if status == noErr {
            hardwareListeners.append((object, address, block))
        } else {
            // The bounded timer also discovers changes if a driver has no notifications.
            logger.notice("硬件监听暂不可用，使用低频检查：\(status)")
        }
    }

    private func observeOutput(_ id: AudioObjectID) {
        guard id != observedOutputID else { return }
        let system = AudioObjectID(kAudioObjectSystemObject)
        for (object, address, block) in hardwareListeners where object != system {
            var mutableAddress = address
            let status = AudioObjectRemovePropertyListenerBlock(object, &mutableAddress, queue, block)
            if status != noErr { logger.notice("旧输出设备监听已失效：\(status)") }
        }
        hardwareListeners.removeAll { $0.0 != system }
        observedOutputID = id
        guard id != kAudioObjectUnknown else { return }
        addListener(object: id, selector: kAudioDevicePropertyNominalSampleRate)
        addListener(object: id, selector: kAudioDevicePropertyDeviceIsAlive)
    }

    private func reloadConfiguration() -> Bool {
        let stamp = try? configURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        guard !configWasRead || stamp != configStamp else { return configuration != nil }
        configWasRead = true
        configStamp = stamp
        stopPipeline()
        coordinator = nil
        configuration = nil
        do {
            let config = try RelayConfiguration.read(configURL)
            configuration = config
            coordinator = AudioRelayCoordinator(configuration: config)
            retry.reset()
            retryAfter = 0
            return true
        } catch {
            publish(error.localizedDescription)
            return false
        }
    }

    private func reconcile() {
        guard !isStopped, !suspended, reloadConfiguration(), let configuration, let coordinator else { return }
        do {
            let discovery = try coordinator.discover()
            lastTargets = discovery.targetProcesses
            lastOutput = discovery.outputDevice
            observeOutput(discovery.outputDevice?.id ?? AudioObjectID(kAudioObjectUnknown))
            guard let output = discovery.outputDevice,
                  configuration.outputDeviceUID.map({ $0 == output.uid }) ?? output.isLikelySpatialAudioHeadphones else {
                stopPipeline()
                retry.reset()
                retryAfter = 0
                publish("等待 AirPods 成为系统声音输出")
                return
            }
            guard !discovery.targetProcesses.isEmpty else {
                stopPipeline()
                retry.reset()
                retryAfter = 0
                publish("等待网易云音乐或 Chrome")
                return
            }

            if isActive, let error = coordinator.healthFailure() {
                fail(error)
                return
            }
            if !isActive {
                guard ProcessInfo.processInfo.systemUptime >= retryAfter else { return }
                // Permission is requested by the OS only when configured targets are playing.
                guard discovery.targetProcesses.contains(where: \.isRunningOutput) else {
                    publish("等待指定应用播放")
                    return
                }
                let callbackGeneration = generation
                _ = try coordinator.start { [weak self] error in
                    guard let self else { return }
                    self.queue.async {
                        guard !self.isStopped, self.isActive, self.generation == callbackGeneration else { return }
                        self.fail(error)
                    }
                }
                isActive = true
                retry.reset()
                publish("正在通过苹果原生空间音频渲染器播放", force: true)
            } else {
                publish("正在通过苹果原生空间音频渲染器播放")
            }
        } catch { fail(error) }
    }

    private func fail(_ error: Error) {
        stopPipeline()
        let delay = retry.nextDelay()
        retryAfter = ProcessInfo.processInfo.systemUptime + delay
        publish("\(error.localizedDescription)；\(Int(delay)) 秒后重试", force: true)
    }

    private func publish(_ message: String, force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        let changed = message != lastMessage
        if changed {
            logger.notice("\(message, privacy: .public)")
            lastMessage = message
        }
        guard force || changed || (isActive && now - lastStatusWrite >= 15) else { return }
        lastStatusWrite = now
        let metrics = coordinator?.metrics()
        var status: [String: Any] = [
            "state": message, "active": isActive, "pid": getpid(),
            "updatedAt": ISO8601DateFormatter().string(from: Date()),
            "configuredApps": configuration?.targetBundleIDs ?? [],
            "processes": lastTargets.map {
                ["pid": $0.pid, "audioObjectID": $0.id, "bundleID": $0.bundleIdentifier,
                 "runningOutput": $0.isRunningOutput] as [String: Any]
            },
            "capturedFrames": metrics?.capturedFrameCount ?? 0,
            "callbacks": metrics?.callbackCount ?? 0,
            "bufferedMilliseconds": metrics?.bufferedMilliseconds ?? 0,
            "droppedFrames": metrics?.droppedFrameCount ?? 0,
            "formatMismatches": metrics?.formatMismatchCount ?? 0,
            "renderer": "AVSampleBufferAudioRenderer",
            "spatializationAllowed": ["mono", "stereo", "multichannel"],
            "nativeSpatialAudioMenuVerified": false
        ]
        if let output = lastOutput {
            status["output"] = ["uid": output.uid, "name": output.name, "sampleRate": output.sampleRate]
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys])
            try FileManager.default.createDirectory(at: RelayPaths.root, withIntermediateDirectories: true)
            try data.write(to: RelayPaths.status, options: .atomic)
        } catch {
            logger.error("无法写入状态文件：\(error.localizedDescription, privacy: .public)")
        }
    }
}

@MainActor
final class BackgroundApplicationDelegate: NSObject, NSApplicationDelegate {
    var service: BackgroundRelay?
    private var workspaceTokens: [NSObjectProtocol] = []
    private var signals: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Test hosts must never trigger privacy prompts or mute real applications.
        guard ProcessInfo.processInfo.environment["SPATIAL_RELAY_TESTING"] != "1" else { return }
        service?.start()
        let center = NSWorkspace.shared.notificationCenter
        workspaceTokens.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) {
            [service] _ in service?.setSuspended(true)
        })
        workspaceTokens.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) {
            [service] _ in service?.setSuspended(false)
        })
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceTokens.append(center.addObserver(forName: name, object: nil, queue: nil) {
                [service] _ in service?.requestReconcile()
            })
        }
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApplication.shared.terminate(nil) }
            source.resume()
            signals.append(source)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        service?.stop()
        return .terminateNow
    }
}

@main
@MainActor
enum SpatialRelayApp {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.contains("--help") {
            print("""
            空间音频桥：静默接管网易云音乐与 Google Chrome。
            无参数：运行后台服务。--config 路径：使用指定 JSON 配置。
            --diagnose：只读检查应用、输出与渲染器配置；不捕获音频。
            --check-config：检查配置；不启动服务。--status：查看运行状态。
            """)
            return
        }
        var configURL = RelayPaths.config
        if let index = args.firstIndex(of: "--config") {
            guard index + 1 < args.count else { exitWithError("--config 后面需要配置文件路径") }
            configURL = URL(fileURLWithPath: args[index + 1])
        }
        if args.contains("--status") {
            do {
                let data = try Data(contentsOf: RelayPaths.status)
                print(String(decoding: data, as: UTF8.self))
            } catch { exitWithError("尚无运行状态，请先安装并启动服务") }
            return
        }
        if args.contains("--check-config") || args.contains("--diagnose") {
            do {
                let configuration = try RelayConfiguration.read(configURL)
                if args.contains("--check-config") {
                    print("配置有效：\(configuration.targetBundleIDs.joined(separator: "、"))")
                } else {
                    let hardware = AudioHardwareClient(configuration: configuration)
                    let processes = try hardware.targetProcesses()
                    let output = try? hardware.defaultOutputDevice()
                    let renderer = AVSampleBufferAudioRenderer()
                    renderer.allowedAudioSpatializationFormats = .monoStereoAndMultichannel
                    let report: [String: Any] = [
                        "configuredApps": configuration.targetBundleIDs,
                        "processes": processes.map { ["audioObjectID": $0.id, "pid": $0.pid, "bundleID": $0.bundleIdentifier] as [String: Any] },
                        "outputName": output?.name ?? "",
                        "outputUID": output?.uid ?? "",
                        "sampleRate": output?.sampleRate ?? 0,
                        "spatializationAllowedRawValue": renderer.allowedAudioSpatializationFormats.rawValue,
                        "nativeSpatialAudioMenuVerified": false,
                        "audioCaptureStarted": false
                    ]
                    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    print(String(decoding: data, as: UTF8.self))
                }
            } catch { exitWithError(error.localizedDescription) }
            return
        }
        // LaunchServices/XCTest may supply its own -NS... arguments.
        if args.contains(where: { $0.hasPrefix("--") && $0 != "--config" }) {
            exitWithError("参数无法识别，请用 --help 查看说明")
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = BackgroundApplicationDelegate()
        delegate.service = BackgroundRelay(configURL: configURL)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    private static func exitWithError(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(2)
    }
}
