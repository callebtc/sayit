import Foundation

public struct AudioChunk: Identifiable, Sendable {
    public let id: UUID
    public let requestID: UUID
    public let index: Int
    public let samples: [Float]
    public let sampleRate: Double
    public let startsParagraph: Bool

    public init(
        id: UUID = UUID(),
        requestID: UUID,
        index: Int,
        samples: [Float],
        sampleRate: Double,
        startsParagraph: Bool
    ) {
        self.id = id
        self.requestID = requestID
        self.index = index
        self.samples = samples
        self.sampleRate = sampleRate
        self.startsParagraph = startsParagraph
    }

    public var duration: TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return Double(samples.count) / sampleRate
    }
}
