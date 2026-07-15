import Foundation

enum RelayError: LocalizedError {
    case unsupportedMac
    case spotifyNotRunning
    case spotifyNotProducingAudio
    case noOutputDevice
    case unsupportedTapFormat(String)
    case rendererFailed(String)
    case captureFailed(String)
    case cleanupFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedMac:
            "Spatial Audio on Mac requires Apple silicon."
        case .spotifyNotRunning:
            "Spotify is not connected to the Mac audio system. Open Spotify and start a song, then refresh."
        case .spotifyNotProducingAudio:
            "Spotify is open but no active output stream was found. Start playback, then try again."
        case .noOutputDevice:
            "macOS has no default audio output device."
        case .unsupportedTapFormat(let detail):
            "Spotify produced an audio format this relay cannot handle (\(detail))."
        case .rendererFailed(let detail):
            "The spatial audio renderer stopped (\(detail)). Spotify output has been restored."
        case .captureFailed(let detail):
            "Spotify audio capture failed (\(detail))."
        case .cleanupFailed(let detail):
            "Spatial Relay could not fully release the audio tap (\(detail)). It attempted to restore Spotify output; quit the app before retrying."
        }
    }
}
