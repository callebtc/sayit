import Foundation

public struct VoiceSynthesisTuning: Sendable {
    public let preset: String
    public let parameters: [String: Double]

    public init(preset: String, parameters: [String: Double]) {
        self.preset = preset
        self.parameters = parameters
    }
}
