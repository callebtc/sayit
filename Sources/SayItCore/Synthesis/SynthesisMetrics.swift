import Foundation

public struct SynthesisMetrics: Equatable, Sendable {
    public let chunkIndex: Int
    public let generationDuration: TimeInterval
    public let audioDuration: TimeInterval
    public let trailingAudioDuration: TimeInterval

    public init(
        chunkIndex: Int,
        generationDuration: TimeInterval,
        audioDuration: TimeInterval,
        trailingAudioDuration: TimeInterval = 0
    ) {
        self.chunkIndex = chunkIndex
        self.generationDuration = generationDuration
        self.audioDuration = audioDuration
        self.trailingAudioDuration = trailingAudioDuration
    }

    public var realTimeFactor: Double {
        guard audioDuration > 0 else { return 0 }
        return generationDuration / audioDuration
    }
}

/// Wall-clock measurements around synthesis; never includes text or voice data.
public struct SynthesisTiming: Equatable, Sendable {
    public enum Phase: String, Sendable {
        case modelLoad = "model_load"
        case voicePreparation = "voice_preparation"
        case firstAudio = "first_audio"
        case synthesisTotal = "total"
    }

    public let phase: Phase
    public let duration: TimeInterval

    public init(phase: Phase, duration: TimeInterval) {
        self.phase = phase
        self.duration = duration
    }
}

/// Progress only: no audio is decoded or changed to report these measurements.
public struct SynthesisProgress: Equatable, Sendable {
    public let chunkIndex: Int
    public let generatedAudioDuration: TimeInterval
    public let generationDuration: TimeInterval
    public let recentRealTimeFactor: Double
    /// Nonzero only for progress measured from audio already delivered to playback.
    public let deliveredAudioPieces: Int
    public let maximumDeliveryGap: TimeInterval
    public let initialGenerationDuration: TimeInterval
    public let initialAudioDuration: TimeInterval

    public init(chunkIndex: Int, generatedAudioDuration: TimeInterval,
                generationDuration: TimeInterval, recentRealTimeFactor: Double,
                deliveredAudioPieces: Int = 0,
                maximumDeliveryGap: TimeInterval = 0,
                initialGenerationDuration: TimeInterval = 0,
                initialAudioDuration: TimeInterval = 0) {
        self.chunkIndex = chunkIndex
        self.generatedAudioDuration = generatedAudioDuration
        self.generationDuration = generationDuration
        self.recentRealTimeFactor = recentRealTimeFactor
        self.deliveredAudioPieces = deliveredAudioPieces
        self.maximumDeliveryGap = maximumDeliveryGap
        self.initialGenerationDuration = initialGenerationDuration
        self.initialAudioDuration = initialAudioDuration
    }
}
