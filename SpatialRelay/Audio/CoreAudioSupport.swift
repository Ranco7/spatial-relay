import CoreAudio
import Foundation

struct CoreAudioFailure: LocalizedError, Equatable {
    let operation: String
    let status: OSStatus

    var errorDescription: String? {
        "\(operation) failed (\(Self.describe(status)))."
    }

    static func check(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            throw CoreAudioFailure(operation: operation, status: status)
        }
    }

    static func describe(_ status: OSStatus) -> String {
        let value = UInt32(bitPattern: status)
        let bytes = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]

        if bytes.allSatisfy({ $0 >= 32 && $0 <= 126 }),
           let code = String(bytes: bytes, encoding: .ascii) {
            return "'\(code)' / \(status)"
        }
        return String(status)
    }
}
func propertyAddress(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}
