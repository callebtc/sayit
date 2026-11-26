import Foundation
import MLXAudioTTS

/// Caches phonemization results across chunk-budget fitting and model synthesis
/// so Kokoro and KittenTTS never run G2P twice on the same text.
final class CachingTextProcessor: TextProcessor, @unchecked Sendable {
    private struct Key: Hashable {
        let language: String
        let text: String
    }

    private let base: any TextProcessor
    private let capacity: Int
    private let lock = NSLock()
    private var values: [Key: String] = [:]
    private var order: [Key] = []

    init(_ base: any TextProcessor, capacity: Int = 64) {
        self.base = base
        self.capacity = max(capacity, 1)
    }

    var wrappedProcessor: any TextProcessor { base }

    func process(text: String, language: String?) throws -> String {
        let key = Key(language: language ?? "", text: text)
        if let cached = lock.withLock({ () -> String? in
            guard let value = values[key] else { return nil }
            if let existingIndex = order.firstIndex(of: key) {
                order.remove(at: existingIndex)
                order.append(key)
            }
            return value
        }) {
            return cached
        }
        let processed = try base.process(text: text, language: language)
        lock.withLock {
            if let existingIndex = order.firstIndex(of: key) {
                order.remove(at: existingIndex)
            }
            order.append(key)
            if order.count > capacity {
                let evicted = order.removeFirst()
                values.removeValue(forKey: evicted)
            }
            values[key] = processed
        }
        return processed
    }

    func prepare() async throws {
        try await base.prepare()
    }

    func prepare(for language: String) async throws {
        if let multilingual = base as? KokoroMultilingualProcessor {
            try await multilingual.prepare(for: language)
        } else {
            try await base.prepare()
        }
    }

    func clearCache() {
        lock.withLock {
            values.removeAll(keepingCapacity: false)
            order.removeAll(keepingCapacity: false)
        }
    }
}
