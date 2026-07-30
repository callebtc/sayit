import Foundation

public struct VoiceReference: Sendable {
    public let audioURL: URL
    public let transcript: String?

    public init(audioURL: URL, transcript: String?) {
        self.audioURL = audioURL
        self.transcript = transcript
    }
}
