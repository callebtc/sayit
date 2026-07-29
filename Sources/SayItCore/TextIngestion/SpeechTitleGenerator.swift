import Foundation
import NaturalLanguage

public struct SpeechTitleGenerator: Sendable {
    public static let fallbackTitle = "Untitled Recording"
    private static let maximumCharacterCount = 80

    public init() {}

    public func title(from text: String) -> String {
        guard let readableStart = text.firstIndex(where: isReadable) else {
            return Self.fallbackTitle
        }

        let readableText = String(text[readableStart...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = readableText
            .split(separator: "\n", maxSplits: 1)
            .first
            .map(String.init) ?? readableText
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = firstLine
        var title = ""
        tokenizer.enumerateTokens(
            in: firstLine.startIndex..<firstLine.endIndex
        ) { range, _ in
            title = String(firstLine[range])
            return false
        }

        if title.isEmpty {
            title = firstLine
        }
        title = title
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !title.isEmpty else {
            return Self.fallbackTitle
        }
        guard title.count > Self.maximumCharacterCount else {
            return title
        }

        let prefixLength = Self.maximumCharacterCount - 3
        return title
            .prefix(prefixLength)
            .trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    private func isReadable(_ character: Character) -> Bool {
        character.unicodeScalars.contains {
            CharacterSet.alphanumerics.contains($0)
        }
    }
}
