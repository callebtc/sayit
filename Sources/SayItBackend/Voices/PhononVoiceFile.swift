import Foundation
import SayItProtocol

enum PhononVoiceFile {
    static let maximumByteCount = 8 * 1024 * 1024

    /// Validate the exported speaker latents before passing them to MLX.
    static func validate(_ data: Data) throws {
        guard (9...maximumByteCount).contains(data.count) else {
            throw invalidFile()
        }
        let headerLength = data.withUnsafeBytes {
            UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self))
        }
        guard headerLength > 0, headerLength <= 65_536,
              headerLength < data.count - 8 else {
            throw invalidFile()
        }
        let payloadStart = 8 + Int(headerLength)
        guard let header = try? JSONSerialization.jsonObject(
            with: data.subdata(in: 8..<payloadStart)
        ) as? [String: Any],
              Set(header.keys).subtracting(["__metadata__"]) == ["speaker_wavs"],
              let tensor = header["speaker_wavs"] as? [String: Any],
              let shape = tensor["shape"] as? [Int],
              shape.count == 3, shape[0] == 1, shape[1] == 512,
              (1...4096).contains(shape[2]),
              let dtype = tensor["dtype"] as? String,
              ["F32", "F16", "BF16"].contains(dtype),
              let offsets = tensor["data_offsets"] as? [Int],
              offsets.count == 2, offsets[0] == 0 else {
            throw invalidFile()
        }
        let stride = dtype == "F32" ? 4 : 2
        let byteCount = 512 * shape[2] * stride
        guard offsets[1] == byteCount,
              data.count - payloadStart == byteCount else {
            throw invalidFile()
        }
        var hasSignal = false
        let finite = data.withUnsafeBytes { bytes in
            for offset in Swift.stride(from: payloadStart, to: data.count, by: stride) {
                let value: Float
                if dtype == "F32" {
                    value = Float(bitPattern: UInt32(littleEndian:
                        bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                    ))
                } else {
                    let bits = UInt16(littleEndian:
                        bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self)
                    )
                    value = dtype == "F16"
                        ? Float(Float16(bitPattern: bits))
                        : Float(bitPattern: UInt32(bits) << 16)
                }
                guard value.isFinite else { return false }
                if value != 0 { hasSignal = true }
            }
            return true
        }
        guard finite, hasSignal else { throw invalidFile() }
    }

    private static func invalidFile() -> ServiceFailure {
        ServiceFailure(
            code: "voice.invalid_file",
            message: "Choose a valid Phonon voice file (.safetensors) exported from Gradium. The file must contain finite speaker latents and be no larger than 8 MB."
        )
    }
}
