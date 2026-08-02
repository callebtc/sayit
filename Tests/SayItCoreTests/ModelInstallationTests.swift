import Foundation
import Testing
@testable import SayItCore

@Suite("Model installation metadata")
struct ModelInstallationTests {
    @Test("ISO-8601 metadata round-trips with the shared codec")
    func metadataRoundTrip() throws {
        let installation = ModelInstallation(
            modelID: ModelID("kokoro-bf16"),
            revision: "a71e4d38b236d968966a2002c4c895dbd12b1c3c",
            installedBytes: 452_538_744,
            verifiedAt: try Date(
                "2026-07-29T15:34:13Z",
                strategy: .iso8601
            ),
            dependenciesVerifiedAt: nil,
            dependenciesFingerprint: "dependency-fingerprint",
            relativePath: "kokoro-bf16/revision"
        )

        let data = try JSONEncoder.sayIt.encode(installation)
        let decoded = try JSONDecoder.sayIt.decode(
            ModelInstallation.self,
            from: data
        )

        #expect(decoded == installation)
    }
}
