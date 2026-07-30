import Foundation

public struct VoiceTuning: Codable, Equatable, Sendable {
    public var preset: VoiceTuningPreset
    public var parameters: [String: Double]

    public init(
        preset: VoiceTuningPreset = .natural,
        parameters: [String: Double] = [:]
    ) {
        self.preset = preset
        self.parameters = parameters
    }
}
