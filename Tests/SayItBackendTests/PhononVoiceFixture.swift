import Foundation

enum PhononVoiceFixture {
    static func data(
        shape: [Int] = [1, 512, 1], dtype: String = "F32",
        value: Float = 0.25
    ) throws -> Data {
        let count = shape.reduce(1, *)
        let stride = dtype == "F32" ? 4 : 2
        let header = try JSONSerialization.data(withJSONObject: [
            "speaker_wavs": [
                "dtype": dtype, "shape": shape,
                "data_offsets": [0, count * stride]
            ]
        ])
        var length = UInt64(header.count).littleEndian
        var data = withUnsafeBytes(of: &length) { Data($0) }
        data.append(header)
        for _ in 0..<count {
            if dtype == "F32" {
                var bits = value.bitPattern.littleEndian
                withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
            } else {
                var bits = (dtype == "F16"
                    ? Float16(value).bitPattern
                    : UInt16(value.bitPattern >> 16)).littleEndian
                withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
            }
        }
        return data
    }
}
