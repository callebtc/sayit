import Foundation

public enum SynthesisEvent: Sendable {
    case loadingModel(ModelID)
    case modelLoaded(ModelID)
    case chunkStarted(index: Int, text: String)
    case audio(AudioChunk)
    case metrics(SynthesisMetrics)
    case completed
    case cancelled
}
