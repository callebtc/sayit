import Foundation
import MLXAudioTTS
import Testing
@testable import SayItBackend

@Suite("Caching text processor")
struct CachingTextProcessorTests {
    private final class CountingTextProcessor: TextProcessor, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var callCount = 0

        func process(text: String, language: String?) throws -> String {
            lock.withLock { callCount += 1 }
            return "\(language ?? "default"):\(text)"
        }
    }

    @Test("Reuses phonemized output across repeated text and language pairs")
    func reusesCachedResults() throws {
        let base = CountingTextProcessor()
        let cached = CachingTextProcessor(base, capacity: 4)

        let first = try cached.process(text: "Hello world.", language: "en-us")
        let second = try cached.process(text: "Hello world.", language: "en-us")
        let french = try cached.process(text: "Hello world.", language: "fr-fr")

        #expect(first == "en-us:Hello world.")
        #expect(second == first)
        #expect(french == "fr-fr:Hello world.")
        #expect(base.callCount == 2)
    }

    @Test("Evicts least-recently-used entries beyond capacity and clears on demand")
    func evictsAndClears() throws {
        let base = CountingTextProcessor()
        let cached = CachingTextProcessor(base, capacity: 2)

        _ = try cached.process(text: "a", language: "en")
        _ = try cached.process(text: "b", language: "en")
        // Promote "a" via cache hit so "b" becomes least-recently-used.
        _ = try cached.process(text: "a", language: "en")
        _ = try cached.process(text: "c", language: "en")
        #expect(base.callCount == 3)

        // "a" and "c" remain cached; "b" was evicted.
        _ = try cached.process(text: "a", language: "en")
        _ = try cached.process(text: "c", language: "en")
        #expect(base.callCount == 3)

        _ = try cached.process(text: "b", language: "en")
        #expect(base.callCount == 4)

        cached.clearCache()
        _ = try cached.process(text: "b", language: "en")
        #expect(base.callCount == 5)
    }
}
