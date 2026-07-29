import Foundation

public struct PlaybackSnapshot: Codable, Sendable {
    public let state: String
    public let elapsed: TimeInterval
    public let generatedDuration: TimeInterval
    public let estimatedDuration: TimeInterval
    public let rate: Double
    public let currentTitle: String
    public let amplitudes: [Float]
    public let spokenText: String
    public let spokenChunks: [PlaybackTextChunk]

    public init(
        state: String = "idle",
        elapsed: TimeInterval = 0,
        generatedDuration: TimeInterval = 0,
        estimatedDuration: TimeInterval = 0,
        rate: Double = 1,
        currentTitle: String = "",
        amplitudes: [Float] = [],
        spokenText: String = "",
        spokenChunks: [PlaybackTextChunk] = []
    ) {
        self.state = state
        self.elapsed = elapsed
        self.generatedDuration = generatedDuration
        self.estimatedDuration = estimatedDuration
        self.rate = rate
        self.currentTitle = currentTitle
        self.amplitudes = amplitudes
        self.spokenText = spokenText
        self.spokenChunks = spokenChunks
    }
}
