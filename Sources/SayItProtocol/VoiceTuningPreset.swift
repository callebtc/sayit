import Foundation

public enum VoiceTuningPreset: String, Codable, CaseIterable, Sendable {
    case faithful
    case natural
    case expressive
}
