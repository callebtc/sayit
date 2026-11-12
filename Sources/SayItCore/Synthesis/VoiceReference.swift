import Foundation

public struct VoiceReference: Sendable {
    public let audioURL: URL
    public let transcript: String?
    public let kind: VoiceReferenceKind

    public init(audioURL: URL, transcript: String?) {
        self.audioURL = audioURL
        self.transcript = transcript
        self.kind = .audio
    }

    public init(phononEmbeddingURL: URL) {
        self.audioURL = phononEmbeddingURL
        self.transcript = nil
        self.kind = .phononEmbedding
    }
}
