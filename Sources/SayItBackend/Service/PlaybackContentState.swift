import SayItProtocol

struct PlaybackContentState: Equatable {
    let currentTitle: String
    let modelID: String?
    let amplitudes: [Float]
    let spokenText: String
    let spokenChunks: [PlaybackTextChunk]
}
