import Foundation

public struct PlaybackSnapshot: Codable, Sendable {
    public let state: String
    public let elapsed: TimeInterval
    public let generatedDuration: TimeInterval
    public let estimatedDuration: TimeInterval
    public let rate: Double
    public let currentTitle: String
    public let modelID: String?
    public let amplitudes: [Float]
    public let spokenText: String
    public let spokenChunks: [PlaybackTextChunk]
    public let contentRevision: UInt64
    public let includesContent: Bool

    public init(
        state: String = "idle",
        elapsed: TimeInterval = 0,
        generatedDuration: TimeInterval = 0,
        estimatedDuration: TimeInterval = 0,
        rate: Double = 1,
        currentTitle: String = "",
        modelID: String? = nil,
        amplitudes: [Float] = [],
        spokenText: String = "",
        spokenChunks: [PlaybackTextChunk] = [],
        contentRevision: UInt64 = 0,
        includesContent: Bool = true
    ) {
        self.state = state
        self.elapsed = elapsed
        self.generatedDuration = generatedDuration
        self.estimatedDuration = estimatedDuration
        self.rate = rate
        self.currentTitle = currentTitle
        self.modelID = modelID
        self.amplitudes = amplitudes
        self.spokenText = spokenText
        self.spokenChunks = spokenChunks
        self.contentRevision = contentRevision
        self.includesContent = includesContent
    }

    private enum CodingKeys: String, CodingKey {
        case state
        case elapsed
        case generatedDuration
        case estimatedDuration
        case rate
        case currentTitle
        case modelID
        case amplitudes
        case spokenText
        case spokenChunks
        case contentRevision
        case includesContent
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = try container.decode(String.self, forKey: .state)
        elapsed = try container.decode(TimeInterval.self, forKey: .elapsed)
        generatedDuration = try container.decode(
            TimeInterval.self,
            forKey: .generatedDuration
        )
        estimatedDuration = try container.decode(
            TimeInterval.self,
            forKey: .estimatedDuration
        )
        rate = try container.decode(Double.self, forKey: .rate)
        currentTitle = try container.decode(
            String.self,
            forKey: .currentTitle
        )
        modelID = try container.decodeIfPresent(
            String.self,
            forKey: .modelID
        )
        amplitudes = try container.decode(
            [Float].self,
            forKey: .amplitudes
        )
        spokenText = try container.decode(String.self, forKey: .spokenText)
        spokenChunks = try container.decode(
            [PlaybackTextChunk].self,
            forKey: .spokenChunks
        )
        contentRevision = try container.decodeIfPresent(
            UInt64.self,
            forKey: .contentRevision
        ) ?? 0
        includesContent = try container.decodeIfPresent(
            Bool.self,
            forKey: .includesContent
        ) ?? true
    }
}
