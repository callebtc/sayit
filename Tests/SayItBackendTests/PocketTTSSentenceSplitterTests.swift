import Foundation
import Testing
@testable import SayItBackend

@Suite("PocketTTS and Phonon sentence splitting")
struct PocketTTSSentenceSplitterTests {
    /// Mirrors Phonon's SentencePiece vocabulary: standalone `"▁"` exists (ID 1),
    /// `"▁."` does NOT exist, and unknown characters fall back to `<0x..>` bytes.
    private func makeTokenizerJSONData(words: [String] = []) -> Data {
        var pieces: [(String, Double)] = [
            ("<unk>", 0),
            ("▁", -2.9),
            (".", -3.3),
            ("!", -8.7),
            ("?", -5.5),
            ("...", -8.6),
            (",", -3.1),
            (";", -7.0),
            (":", -6.5),
            ("'", -5.0),
            ("\"", -5.0),
            ("(", -6.0),
            (")", -6.0),
            ("-", -5.0),
            ("*", -10.8),
            ("/", -6.0),
            ("$", -6.0),
            ("@", -6.0),
            ("+", -6.0),
        ]
        var seen = Set(pieces.map(\.0))
        for scalar in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789" {
            let value = String(scalar)
            if seen.insert(value).inserted {
                pieces.append((value, -6.0))
            }
        }
        for word in words {
            if seen.insert(word).inserted {
                pieces.append((word, -3.5))
            }
        }
        for byte in UInt8.min...UInt8.max {
            let token = String(format: "<0x%02X>", byte)
            if seen.insert(token).inserted {
                pieces.append((token, 0.0))
            }
        }

        let vocabJSON = pieces.map { piece, score in
            let escaped = piece
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return #"["\#(escaped)",\#(score)]"#
        }.joined(separator: ",")
        return Data(#"{"model":{"type":"Unigram","unk_id":0,"vocab":[\#(vocabJSON)]}}"#.utf8)
    }

    @Test("Punctuation token set excludes standalone SentencePiece metaspace and byte fallback tokens")
    func punctuationTokenSetExcludesMetaspace() throws {
        let tokenizerData = makeTokenizerJSONData()
        let endTokens = try PocketTTSSentenceSplitter.punctuationTokenIDs(
            for: ".!...?",
            tokenizerJSONData: tokenizerData
        )
        // ID 1 is standalone "▁"; IDs 2, 3, 4, 5 are ".", "!", "?", "...".
        #expect(!endTokens.contains(1))
        #expect(endTokens.contains(2))
        #expect(endTokens.contains(3))
        #expect(endTokens.contains(4))
        #expect(endTokens.contains(5))
    }

    @Test("Does not split mid-sentence at standalone metaspace tokens")
    func doesNotSplitMidSentenceOnMetaspace() throws {
        let tokenizerData = makeTokenizerJSONData(words: [
            "▁Most", "▁token", "▁have", "▁extreme", "▁noise", "▁from",
            "▁that", "▁train", "▁on", "▁your", "▁data", "▁or", "▁to", "▁be",
            "▁is", "▁the", "▁largest", "▁understand", "▁AI", "▁because",
            "▁we", "▁real", "▁usage", "▁an", "▁platform", "▁paying",
            "▁and", "▁thousands", "▁of", "▁zero"
        ])
        let text = """
        Most token aggregators have extreme noise from ① token promos from/to providers that train on your data or ② providers that *claim* to be ZDR.

        Vercel AI Gateway is the largest trustworthy datasource to understand global AI token flows, because we have real usage, from real customers, an at-scale platform (400k+ paying customers and thousands of enterprises), and zero markup.
        """

        let chunks = try PocketTTSSentenceSplitter.split(
            text,
            tokenizerJSONData: tokenizerData,
            maxTokens: 50
        )

        #expect(
            chunks.first
                == "Most token aggregators have extreme noise from ① token promos from/to providers that train on your data or ② providers that *claim* to be ZDR."
        )

        let joinedRemainder = chunks.dropFirst().joined(separator: " ")
        #expect(joinedRemainder.contains("to understand global AI token flows"))
        for chunk in chunks {
            #expect(!chunk.hasSuffix("to understand"))
            #expect(!chunk.hasSuffix("providers"))
            #expect(!chunk.hasSuffix("providers that"))
        }
        for chunk in chunks.dropFirst().dropLast() {
            #expect([",", ";", ":", "."].contains(chunk.last))
        }
    }

    @Test("Preserves periods inside decimals, URLs, emails, times, and titles")
    func preservesInnerPunctuation() throws {
        let tokenizerData = makeTokenizerJSONData(words: [
            "▁It", "▁costs", "▁dollars", "▁today", "▁We", "▁paid", "▁for",
            "▁the", "▁new", "▁chairs", "▁Read", "▁guide", "▁at", "▁first",
            "▁Write", "▁to", "▁before", "▁noon", "▁Bring", "▁a", "▁tool",
            "▁hammer", "▁or", "▁saw", "▁start", "▁on", "▁day", "▁will",
            "▁meet", "▁doctor", "▁from", "▁clinic"
        ])

        let cases = [
            "It costs 3.14 dollars today.",
            "We paid $822.95 for the new chairs.",
            "Read the guide at www.kyutai.org first.",
            "Write to jo@icloud.com before noon.",
            "Bring a tool, e.g. a hammer or a saw.",
            "We start at 4 p.m. on the first day.",
            "We will meet the new doctor at noon, Dr. Miller from the clinic."
        ]

        for sample in cases {
            let chunks = try PocketTTSSentenceSplitter.split(
                sample,
                tokenizerJSONData: tokenizerData,
                maxTokens: 50
            )
            #expect(chunks == [sample], "Unexpected split for: \(sample)")
        }
    }

    @Test("Sub-splits oversized sentences at commas while keeping decimal amounts intact")
    func subSplitsOversizedSentencesAtCommasAndGluesDecimals() throws {
        let tokenizerData = makeTokenizerJSONData(words: [
            "▁The", "▁total", "▁fee", "▁was", "▁which", "▁covered",
            "▁shipping", "▁and", "▁handling", "▁for", "▁all", "▁items"
        ])
        let text = "The total fee was $822.95, which covered shipping and handling for all items, including insurance."
        let chunks = try PocketTTSSentenceSplitter.split(
            text,
            tokenizerJSONData: tokenizerData,
            maxTokens: 20
        )
        #expect(chunks.count == 2)
        // Must glue "$822.95," with "which covered..." rather than ending a chunk on "$822.95,"
        #expect(chunks[0] == "The total fee was $822.95, which covered shipping and handling for all items,")
        #expect(chunks[1] == "including insurance.")
    }

    @Test("Splits at true sentence boundaries and keeps closing quotes attached")
    func splitsAtSentenceBoundariesAndKeepsClosers() throws {
        let tokenizerData = makeTokenizerJSONData(words: [
            "▁She", "▁said", "▁Hello", "▁world", "▁Then", "▁she", "▁left", "▁quickly"
        ])
        let text = #"She said "Hello world." Then she left quickly."#
        let chunks = try PocketTTSSentenceSplitter.split(
            text,
            tokenizerJSONData: tokenizerData,
            maxTokens: 10
        )
        #expect(chunks == [#"She said "Hello world.""#, "Then she left quickly."])
    }

    @Test("Normalizes curly apostrophes, ellipsis, and trailing weak punctuation")
    func normalizesPunctuationForGeneration() throws {
        let (prepared, guess) = try PocketTTSSentenceSplitter.prepareTextPrompt(
            "wouldn\u{2019}t stop\u{2026} wait,"
        )
        #expect(prepared == "Wouldn't stop... wait.")
        #expect(guess == 3)
    }
}
