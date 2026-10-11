import Foundation

enum RelayError: LocalizedError {
    case unsupportedMac
    case targetNotRunning
    case noOutputDevice
    case configuration(String)
    case unsupportedTapFormat(String)
    case rendererFailed(String)
    case captureFailed(String)
    case cleanupFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedMac:
            "系统空间音频需要 Apple Silicon Mac。"
        case .targetNotRunning:
            "等待指定应用连接到音频系统。"
        case .noOutputDevice:
            "等待音频输出设备。"
        case .configuration(let detail):
            "配置有误，已停止接管：\(detail)"
        case .unsupportedTapFormat(let detail):
            "音频格式不支持，已保留应用原声：\(detail)"
        case .rendererFailed(let detail):
            "苹果空间音频渲染器中断，正在恢复原声：\(detail)"
        case .captureFailed(let detail):
            "指定应用的音频捕获中断：\(detail)"
        case .cleanupFailed(let detail):
            "无法完整释放音频捕获，已尝试恢复原声：\(detail)"
        }
    }
}
