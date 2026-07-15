import AppKit
import Combine
import Foundation

@MainActor
final class RelayViewModel: ObservableObject {
    enum CheckState {
        case ready
        case warning
        case unavailable
    }

    struct Message: Equatable {
        enum Kind {
            case info
            case warning
            case error
        }

        let kind: Kind
        let text: String
    }

    @Published private(set) var spotifyDetail = "Looking for Spotify…"
    @Published private(set) var spotifyState: CheckState = .warning
    @Published private(set) var outputDetail = "Looking for the current output…"
    @Published private(set) var outputState: CheckState = .warning
    @Published private(set) var message: Message?
    @Published private(set) var isRelaying = false
    @Published private(set) var isBusy = false
    @Published private(set) var meterLevel: CGFloat = 0
    @Published private(set) var latencyLabel = "~80 ms prebuffer"

    private let coordinator = AudioRelayCoordinator()
    private let startupQueue = DispatchQueue(
        label: "com.shevlfs.SpatialRelay.startup",
        qos: .userInitiated
    )
    private var discovery: RelayDiscovery?
    private var meterTimer: Timer?
    private var healthTick = 0
    private var startupOperationID: UUID?
    private var terminationCleanupIsRunning = false
    private var terminationCompletions: [() -> Void] = []
    private(set) var isReadyToTerminate = false

    deinit {
        MainActor.assumeIsolated {
            meterTimer?.invalidate()
            coordinator.stop()
        }
    }

    var canToggleRelay: Bool {
        if isRelaying { return !isBusy }
        return !isBusy &&
            discovery?.outputDevice != nil &&
            !(discovery?.spotifyProcesses.isEmpty ?? true)
    }

    var menuBarSymbolName: String {
        if isBusy { return "ellipsis.circle" }
        if isRelaying { return "waveform.circle.fill" }
        if message?.kind == .error { return "exclamationmark.triangle.fill" }
        return "waveform.circle"
    }

    var menuBarStatusText: String {
        if isBusy { return "Spatial Relay is changing audio state" }
        if isRelaying { return "Spatial Relay is active" }
        if message?.kind == .error { return "Spatial Relay needs attention" }
        return "Spatial Relay is stopped"
    }

    func refresh() {
        // Reopening the menu-bar window calls this view's onAppear again. Do not
        // make the main actor wait on Core Audio while a permission prompt or
        // pipeline startup is already running on the coordinator queue.
        guard !isRelaying, !isBusy else { return }

        do {
            let discovery = try coordinator.discover()
            self.discovery = discovery
            message = nil
            apply(discovery)
        } catch {
            discovery = nil
            spotifyDetail = "Unable to inspect audio processes"
            spotifyState = .unavailable
            outputDetail = "Unable to inspect the current output"
            outputState = .unavailable
            message = Message(kind: .error, text: error.localizedDescription)
        }
    }

    func toggleRelay() {
        if isRelaying {
            stopRelay()
        } else {
            startRelay()
        }
    }

    func openSpotify() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") else {
            message = Message(kind: .error, text: "Spotify is not installed in a location macOS can find.")
            return
        }

        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { [weak self] _, error in
            guard let viewModel = self else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak viewModel] in
                MainActor.assumeIsolated {
                    if let error {
                        viewModel?.message = Message(kind: .error, text: error.localizedDescription)
                    } else {
                        viewModel?.refresh()
                    }
                }
            }
        }
    }

    func prepareForTermination(completion: @escaping () -> Void) {
        if isReadyToTerminate {
            completion()
            return
        }

        terminationCompletions.append(completion)
        guard !terminationCleanupIsRunning else { return }
        terminationCleanupIsRunning = true

        startupOperationID = nil
        meterTimer?.invalidate()
        meterTimer = nil
        isRelaying = false
        isBusy = true
        meterLevel = 0

        // The serial startup queue gives cleanup strict ordering after a tap
        // creation that may still be waiting for the privacy prompt. AppKit's
        // terminate-later reply keeps the process alive, while leaving the main
        // actor and menu responsive until Spotify has been safely unmuted.
        let coordinator = coordinator
        startupQueue.async { [weak self] in
            _ = coordinator.stop()
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isBusy = false
                    self.isReadyToTerminate = true
                    self.terminationCleanupIsRunning = false
                    let completions = self.terminationCompletions
                    self.terminationCompletions.removeAll()
                    completions.forEach { $0() }
                }
            }
        }
    }

    func quitApplication() {
        NSApplication.shared.terminate(nil)
    }

    private func startRelay() {
        isBusy = true
        message = nil
        let operationID = UUID()
        startupOperationID = operationID
        let coordinator = coordinator

        // Tap creation can wait for Core Audio or a privacy prompt. Keep it off
        // the main actor so the window and progress indicator stay responsive.
        startupQueue.async { [weak self] in
            let result: Result<RelayDiscovery, Error>
            do {
                let discovery = try coordinator.start { [weak self] error in
                    Task { @MainActor in
                        self?.handlePipelineFailure(error)
                    }
                }
                result = .success(discovery)
            } catch {
                result = .failure(error)
            }

            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.completeStart(result, operationID: operationID)
                }
            }
        }
    }

    private func completeStart(
        _ result: Result<RelayDiscovery, Error>,
        operationID: UUID
    ) {
        guard startupOperationID == operationID else { return }
        startupOperationID = nil
        isBusy = false

        switch result {
        case .success(let discovery):
            self.discovery = discovery
            apply(discovery)
            isRelaying = true
            if let output = discovery.outputDevice, !output.isLikelySpatialAudioHeadphones {
                message = Message(
                    kind: .warning,
                    text: "Relay active, but \(output.name) does not look like Spatial Audio-capable AirPods. Choose your AirPods as the Mac's output, then restart the relay."
                )
            } else {
                message = Message(
                    kind: .info,
                    text: "Relay active. Spatial Audio is now controlled for Spatial Relay in the macOS Sound menu."
                )
            }
            startMetering()
        case .failure(let error):
            let cleanupFailure = coordinator.stop()
            isRelaying = false
            message = Message(
                kind: .error,
                text: startFailureMessage(cleanupFailure ?? error)
            )
        }
    }

    private func stopRelay() {
        startupOperationID = nil
        isBusy = true
        meterTimer?.invalidate()
        meterTimer = nil
        let cleanupFailure = coordinator.stop()
        isRelaying = false
        meterLevel = 0
        isBusy = false
        message = cleanupFailure.map {
            Message(kind: .error, text: $0.localizedDescription)
        } ?? Message(kind: .info, text: "Relay stopped. Spotify is playing directly again.")
        refreshRouteRowsPreservingMessage()
    }

    private func handlePipelineFailure(_ error: Error) {
        startupOperationID = nil
        meterTimer?.invalidate()
        meterTimer = nil
        isRelaying = false
        isBusy = false
        meterLevel = 0
        message = Message(kind: .error, text: error.localizedDescription)
        refreshRouteRowsPreservingMessage()
    }

    private func startMetering() {
        meterTimer?.invalidate()
        healthTick = 0
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRelaying else { return }

                let metrics = self.coordinator.metrics()
                let shapedPeak = CGFloat(pow(max(0, min(1, metrics.peakLevel)), 0.45))
                self.meterLevel = max(shapedPeak, self.meterLevel * 0.72)
                self.latencyLabel = metrics.droppedFrameCount == 0
                    ? "~80 ms prebuffer"
                    : "\(metrics.droppedFrameCount) frames dropped"

                self.healthTick += 1
                if self.healthTick >= 8 {
                    self.healthTick = 0
                    if let failure = self.coordinator.healthFailure() {
                        let cleanupFailure = self.coordinator.stop()
                        self.handlePipelineFailure(cleanupFailure ?? failure)
                    }
                }
            }
        }
    }

    private func apply(_ discovery: RelayDiscovery) {
        if discovery.spotifyProcesses.isEmpty {
            spotifyDetail = "Open Spotify and start playback"
            spotifyState = .unavailable
        } else {
            let activeCount = discovery.spotifyProcesses.filter(\.isRunningOutput).count
            spotifyDetail = activeCount > 0
                ? "Audio stream detected"
                : "Connected; waiting for playback"
            spotifyState = activeCount > 0 ? .ready : .warning
        }

        if let output = discovery.outputDevice {
            outputDetail = "\(output.name) · \(Int(output.sampleRate.rounded())) Hz"
            outputState = output.isLikelySpatialAudioHeadphones ? .ready : .warning
        } else {
            outputDetail = "No default output device"
            outputState = .unavailable
        }

        guard message == nil || message?.kind != .error else { return }

        #if !arch(arm64)
        message = Message(kind: .error, text: RelayError.unsupportedMac.localizedDescription)
        #else
        if discovery.spotifyProcesses.isEmpty {
            message = Message(kind: .warning, text: "Spotify only appears in Core Audio after it opens an audio stream. Start a song, then click Refresh.")
        } else if let output = discovery.outputDevice, !output.isLikelySpatialAudioHeadphones {
            message = Message(kind: .warning, text: "The current output does not look like Spatial Audio-capable AirPods. Connect AirPods before starting the relay.")
        } else if !isRelaying {
            message = nil
        }
        #endif
    }

    private func refreshRouteRowsPreservingMessage() {
        let savedMessage = message
        do {
            let discovery = try coordinator.discover()
            self.discovery = discovery
            apply(discovery)
        } catch {
            discovery = nil
            spotifyDetail = "Unable to inspect audio processes"
            spotifyState = .unavailable
            outputDetail = "Unable to inspect the current output"
            outputState = .unavailable
        }
        message = savedMessage
    }

    private func startFailureMessage(_ error: Error) -> String {
        let description = error.localizedDescription
        if description.localizedCaseInsensitiveContains("permission") ||
            description.localizedCaseInsensitiveContains("denied") ||
            description.localizedCaseInsensitiveContains("operation not permitted") ||
            description.localizedCaseInsensitiveContains("'perm'") ||
            description.contains("560492391") ||
            description.localizedCaseInsensitiveContains("!hog") {
            return "\(description) Allow Spatial Relay in System Settings → Privacy & Security → Screen & System Audio Recording, then relaunch it."
        }
        return description
    }
}
