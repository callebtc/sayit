import Foundation
import NaturalLanguage

public actor TextCleaner: TextIngesting {
    public static let confirmationThreshold = 50_000
    public static let maximumCharacterCount = 200_000
    private let parser = TextParser()
    private let titleGenerator = SpeechTitleGenerator()

    public init() {}

    public func ingest(_ payload: TextSourcePayload) async throws -> CleanedText {
        let parsed = try parser.parse(payload)
        guard !parsed.text.isEmpty else {
            throw TextIngestionError.noReadableText
        }
        guard parsed.text.count <= Self.maximumCharacterCount else {
            throw TextIngestionError.textTooLong(limit: Self.maximumCharacterCount)
        }

        return CleanedText(
            text: parsed.text,
            title: titleGenerator.title(from: parsed.text),
            detectedLanguage: detectLanguage(in: parsed.text),
            cleanupSummary: CleanupSummary(
                sourceFormat: parsed.sourceFormat,
                removedCodeBlocks: parsed.removedCodeBlocks,
                normalizedWhitespace: parsed.normalizedWhitespace
            ),
            requiresLongTextConfirmation: parsed.text.count
                > Self.confirmationThreshold
        )
    }

    private func detectLanguage(in text: String) -> String? {
        let sample = String(text.prefix(2_000))
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        return recognizer.dominantLanguage?.rawValue
    }
}
