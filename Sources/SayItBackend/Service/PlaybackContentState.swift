import SayItProtocol

struct PlaybackContentState: Equatable {
    let currentTitle: String
    let modelID: String?
    let spokenText: String
}
