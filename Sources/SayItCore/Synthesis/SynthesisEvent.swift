import Foundation

public enum SynthesisEvent: Sendable {
    case loadingModel(ModelID)
    case modelLoaded(ModelID)
    case creatingArticleVoice
    case chunkStarted(index: Int, chunk: SpeechChunk)
    case audio(AudioChunk)
    case progress(SynthesisProgress)
    case metrics(SynthesisMetrics)
    case timing(SynthesisTiming)
    case completed
    case cancelled
}
