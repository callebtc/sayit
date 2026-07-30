import Foundation

public struct VoiceRecordingAnalysis: Equatable, Sendable {
    public let duration: TimeInterval
    public let rootMeanSquare: Float
    public let peak: Float
    public let sampleRate: Double

    public init(
        duration: TimeInterval,
        rootMeanSquare: Float,
        peak: Float,
        sampleRate: Double
    ) {
        self.duration = duration
        self.rootMeanSquare = rootMeanSquare
        self.peak = peak
        self.sampleRate = sampleRate
    }
}
