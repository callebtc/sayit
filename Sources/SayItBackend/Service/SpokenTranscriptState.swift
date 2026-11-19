import Foundation
import SayItCore
import SayItProtocol

/// Tracks the backend's active transcript, source chunk timing anchors, and
/// fallback model-switch context across streaming synthesis and history replay.
struct SpokenTranscriptState: Sendable {
    private(set) var text = ""
    private(set) var chunks: [PlaybackTextChunk] = []
    private(set) var playbackContext: PlaybackContext?
    private var characterCount = 0
    private var lastRecordedTextEnd = 0
    private var pendingSourceRange: Range<Int>?
    private var audioCursor: TimeInterval = 0

    mutating func assign(
        _ text: String,
        chunks: [PlaybackTextChunk] = [],
        language: String? = nil,
        setsPlaybackContext: Bool = true
    ) {
        self.text = text
        self.chunks = chunks
        characterCount = text.count
        lastRecordedTextEnd = 0
        playbackContext = setsPlaybackContext
            ? PlaybackContext(text: text, language: language)
            : nil
        pendingSourceRange = nil
        audioCursor = 0
    }

    mutating func reset() {
        self = SpokenTranscriptState()
    }

    mutating func registerChunk(_ chunk: SpeechChunk) {
        let range = chunk.sourceRange
        guard range.lowerBound >= lastRecordedTextEnd,
              range.upperBound <= characterCount,
              !range.isEmpty else {
            pendingSourceRange = nil
            return
        }
        pendingSourceRange = range
    }

    mutating func updateAudioCursor(_ duration: TimeInterval) {
        audioCursor = duration
    }

    @discardableResult
    mutating func finalizeLastChunk(audioEnd: TimeInterval) -> Bool {
        guard let chunk = chunks.last, chunk.audioEnd == nil else {
            return false
        }
        appendChunk(PlaybackTextChunk(
            textStart: chunk.textStart,
            textEnd: chunk.textEnd,
            audioStart: chunk.audioStart,
            audioEnd: max(audioEnd, chunk.audioStart)
        ))
        return true
    }

    mutating func flushPendingChunk(speechStartOffset: TimeInterval) {
        guard let range = pendingSourceRange else {
            return
        }
        pendingSourceRange = nil
        finalizeLastChunk(audioEnd: audioCursor)
        appendChunk(
            PlaybackTextChunk(
                textStart: range.lowerBound,
                textEnd: range.upperBound,
                audioStart: audioCursor + max(speechStartOffset, 0)
            )
        )
        lastRecordedTextEnd = range.upperBound
    }

    private mutating func appendChunk(_ chunk: PlaybackTextChunk) {
        if let last = chunks.last, last.textStart == chunk.textStart {
            chunks[chunks.count - 1] = chunk
        } else {
            chunks.append(chunk)
        }
    }
}
