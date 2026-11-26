import Foundation
import Testing
@testable import SayItBackend

@Suite("PocketTTS stream runner helpers")
struct PocketTTSStreamRunnerTests {
    @Test("KV cache capacity buckets step cleanly without premature doubling")
    func cacheCapacityBuckets() {
        #expect(PocketTTSStreamRunner.cacheCapacity(forTotalLength: 1) == 320)
        #expect(PocketTTSStreamRunner.cacheCapacity(forTotalLength: 256) == 320)
        #expect(PocketTTSStreamRunner.cacheCapacity(forTotalLength: 320) == 320)
        #expect(PocketTTSStreamRunner.cacheCapacity(forTotalLength: 321) == 512)
        #expect(PocketTTSStreamRunner.cacheCapacity(forTotalLength: 512) == 512)
        #expect(PocketTTSStreamRunner.cacheCapacity(forTotalLength: 513) == 1024)
        #expect(PocketTTSStreamRunner.cacheCapacity(forTotalLength: 1025) == 1280)
    }
}
