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

    @Test("Voice file cache refreshes on miss after new voices are installed")
    func voiceFileCacheRefreshesOnMiss() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "PocketVoiceCache-\(UUID().uuidString)", directoryHint: .isDirectory)
        let voicesDir = root.appending(path: "voices", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: voicesDir, withIntermediateDirectories: true)
        let defaultFile = root.appending(path: "default-voice.safetensors")
        try Data([1]).write(to: defaultFile)

        // Populate cache with only the default voice present.
        let initial = PocketTTSStreamRunner.resolveVoiceFile(in: root, voice: "default")
        #expect(initial.file == defaultFile)
        #expect(PocketTTSStreamRunner.resolveVoiceFile(in: root, voice: "Zoey").file == nil)

        // Simulate "Update Voices" downloading a new preset into the same folder.
        let zoeyFile = voicesDir.appending(path: "Zoey.safetensors")
        try Data([2]).write(to: zoeyFile)

        let refreshed = PocketTTSStreamRunner.resolveVoiceFile(in: root, voice: "Zoey")
        #expect(refreshed.selected == "zoey")
        #expect(refreshed.file?.standardizedFileURL == zoeyFile.standardizedFileURL)
        #expect(refreshed.available.contains("zoey"))
    }

    @Test("Fused quad-step EOS slicing matches exact single-step frame limits")
    func quadStepEosBoundarySlicing() {
        // No EOS flag returns nil.
        #expect(
            PocketTTSStreamRunner.eosBlockKeepCounts(
                startStep: 8,
                eosFlags: [false, false, false, false],
                framesAfterEos: 3,
                maxGenLen: 100
            ) == nil
        )

        // EOS at offset 0 with framesAfterEos = 3 -> allowed steps [8, 9, 10] (3 frames in current, 0 in next).
        let offset0 = PocketTTSStreamRunner.eosBlockKeepCounts(
            startStep: 8,
            eosFlags: [true, false, false, false],
            framesAfterEos: 3,
            maxGenLen: 100
        )
        #expect(offset0?.eosStep == 8)
        #expect(offset0?.keepInCurrent == 3)
        #expect(offset0?.keepInNext == 0)
        #expect(offset0?.totalAllowed == 11)

        // EOS at offset 2 with framesAfterEos = 4 -> allowed up to step 14 (4 in current [8..11], 2 in next [12..13]).
        let offset2 = PocketTTSStreamRunner.eosBlockKeepCounts(
            startStep: 8,
            eosFlags: [false, false, true, true],
            framesAfterEos: 4,
            maxGenLen: 100
        )
        #expect(offset2?.eosStep == 10)
        #expect(offset2?.keepInCurrent == 4)
        #expect(offset2?.keepInNext == 2)
        #expect(offset2?.totalAllowed == 14)

        // EOS at offset 3 with framesAfterEos = 8 -> keeps all 4 in current and all 4 in next, leaving 3 tail frames.
        let offset3 = PocketTTSStreamRunner.eosBlockKeepCounts(
            startStep: 8,
            eosFlags: [false, false, false, true],
            framesAfterEos: 8,
            maxGenLen: 100
        )
        #expect(offset3?.eosStep == 11)
        #expect(offset3?.keepInCurrent == 4)
        #expect(offset3?.keepInNext == 4)
        #expect(offset3?.totalAllowed == 19)

        // Respects maxGenLen ceiling when tighter than detectedEos + framesAfterEos.
        let clamped = PocketTTSStreamRunner.eosBlockKeepCounts(
            startStep: 8,
            eosFlags: [false, true, false, false],
            framesAfterEos: 6,
            maxGenLen: 13
        )
        #expect(clamped?.keepInCurrent == 4)
        #expect(clamped?.keepInNext == 1)
        #expect(clamped?.totalAllowed == 13)
    }

    @Test("Streaming depthwise upsample overlap-add matches full causal transposed convolution")
    func depthwiseUpsampleStreamingEquivalence() {
        let channels = 3
        let stride = 2
        let totalTime = 10
        let input: [[Float]] = (0..<channels).map { c in
            (0..<totalTime).map { t in Float(c * 13 + t + 1) * 0.1 }
        }
        let wFirst: [[Float]] = [
            [0.5, -0.25],
            [0.75, 0.2],
            [-0.4, 0.9]
        ]
        let wSecond: [[Float]] = [
            [0.3, 0.6],
            [-0.1, 0.45],
            [0.8, -0.15]
        ]

        // Direct full causal transposed convolution:
        // y[c, t*s + k] = x[c, t]*w[c, k] + (t > 0 ? x[c, t-1]*w[c, s+k] : 0)
        var expected = Array(repeating: [Float](repeating: 0, count: totalTime * stride), count: channels)
        for c in 0..<channels {
            for t in 0..<totalTime {
                let xCurr = input[c][t]
                let xPrev = t > 0 ? input[c][t - 1] : 0
                for k in 0..<stride {
                    expected[c][t * stride + k] = xCurr * wFirst[c][k] + xPrev * wSecond[c][k]
                }
            }
        }

        // Stream in irregular chunk sizes (1, 3, 2, 4) and verify bit-exact parity.
        let chunkSizes = [1, 3, 2, 4]
        var prevInput: [Float]?
        var streamed = Array(repeating: [Float](), count: channels)
        var offset = 0
        for size in chunkSizes {
            let chunk = input.map { Array($0[offset..<(offset + size)]) }
            let out = PocketTTSStreamRunner.depthwiseUpsampleStepReference(
                input: chunk,
                wFirst: wFirst,
                wSecond: wSecond,
                prevInput: &prevInput
            )
            for c in 0..<channels {
                streamed[c].append(contentsOf: out[c])
            }
            offset += size
        }

        for c in 0..<channels {
            #expect(streamed[c].count == expected[c].count)
            for i in 0..<expected[c].count {
                #expect(abs(streamed[c][i] - expected[c][i]) < 1e-6)
            }
        }
    }
}
