import Foundation
import SayItProtocol
import Testing
@testable import SayItBackend

@Suite("Phonon voice files")
struct PhononVoiceFileTests {
    @Test("Exported speaker latents support floating-point formats", arguments: ["F32", "F16", "BF16"])
    func validFormats(dtype: String) throws {
        try PhononVoiceFile.validate(PhononVoiceFixture.data(dtype: dtype))
    }

    @Test("Malformed, incompatible, silent, and nonfinite embeddings are rejected")
    func rejectsInvalidEmbeddings() throws {
        let valid = try PhononVoiceFixture.data()
        let invalid = try [
            Data(), Data(repeating: 255, count: 20),
            Data(valid.dropLast()),
            valid + Data([0]),
            PhononVoiceFixture.data(shape: [1, 256, 1]),
            PhononVoiceFixture.data(shape: [512, 1]),
            PhononVoiceFixture.data(dtype: "I16"),
            PhononVoiceFixture.data(value: .nan),
            PhononVoiceFixture.data(value: .infinity),
            PhononVoiceFixture.data(value: 0),
            Data(repeating: 0, count: PhononVoiceFile.maximumByteCount + 1)
        ]
        for data in invalid {
            #expect(throws: ServiceFailure.self) {
                try PhononVoiceFile.validate(data)
            }
        }
    }
}
