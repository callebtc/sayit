import Foundation
@preconcurrency import MLX

/// Navigates the nested weight layout Woof stores as JSON in `__tree__`.
///
/// Objects and lists mirror the model's structure; `{"@": name}` refers to an
/// array member of the same archive.
struct WoofWeightTree {
    private let node: Any
    private let archive: NumPyArchive
    private let path: String

    init(archive: NumPyArchive) throws {
        let json = try archive.text(named: "__tree__")
        self.init(
            node: try JSONSerialization.jsonObject(with: Data(json.utf8)),
            archive: archive,
            path: "weights"
        )
    }

    private init(node: Any, archive: NumPyArchive, path: String) {
        self.node = node
        self.archive = archive
        self.path = path
    }

    var keys: [String] {
        (node as? [String: Any]).map { $0.keys.sorted() } ?? []
    }

    func contains(_ key: String) -> Bool {
        (node as? [String: Any])?[key] != nil
    }

    func child(_ key: String) throws -> WoofWeightTree {
        guard let value = (node as? [String: Any])?[key] else {
            throw WoofModelError.invalidWeights("\(path).\(key) is missing")
        }
        return WoofWeightTree(node: value, archive: archive, path: "\(path).\(key)")
    }

    func elements() throws -> [WoofWeightTree] {
        guard let values = node as? [Any] else {
            throw WoofModelError.invalidWeights("\(path) is not a list")
        }
        return values.enumerated().map {
            WoofWeightTree(node: $1, archive: archive, path: "\(path)[\($0)]")
        }
    }

    func element(_ index: Int) throws -> WoofWeightTree {
        let values = try elements()
        guard values.indices.contains(index) else {
            throw WoofModelError.invalidWeights("\(path)[\(index)] is missing")
        }
        return values[index]
    }

    func int() throws -> Int {
        guard let value = node as? NSNumber else {
            throw WoofModelError.invalidWeights("\(path) is not a number")
        }
        return value.intValue
    }

    func float() throws -> Float {
        guard let value = node as? NSNumber else {
            throw WoofModelError.invalidWeights("\(path) is not a number")
        }
        return value.floatValue
    }

    func string() throws -> String {
        guard let value = node as? String else {
            throw WoofModelError.invalidWeights("\(path) is not a string")
        }
        return value
    }

    /// A stored array, converted to `float32`.
    ///
    /// Each weight is evaluated as it loads, so its int8 source and
    /// intermediates are freed one weight at a time.
    func tensor() throws -> MLXArray {
        guard let object = node as? [String: Any], object.count == 1,
              let name = object["@"] as? String else {
            throw WoofModelError.invalidWeights("\(path) is not an array")
        }
        let array = try archive.array(named: name)
        guard let dtype = array.dtype else {
            throw NumPyArchiveError.unsupportedType(name, array.descriptor)
        }
        return evaluated(MLXArray(array.payload, array.shape, dtype: dtype).asType(.float32))
    }

    /// A speech-model projection: per-row int8 weights (`q`, `s`) or `float32`
    /// weights (`w`), each with an optional bias (`b`).
    func linear() throws -> WoofLinear {
        let weight = if contains("q") {
            evaluated(try child("q").tensor() * child("s").tensor().expandedDimensions(axis: 1))
        } else {
            try child("w").tensor()
        }
        return WoofLinear(
            weight: weight,
            bias: contains("b") ? try child("b").tensor() : nil
        )
    }

    /// A decoder array: stored directly, or as int8 values with one `float32`
    /// scale per group of `g` values along each row of the `axis` dimension.
    func dequantized() throws -> MLXArray {
        guard contains("q8") else {
            return try tensor()
        }
        let values = try child("q8").tensor()
        let scales = try child("s").tensor()
        let shape = try child("shape").elements().map { try $0.int() }
        let axis = try child("axis").int()
        let groupSize = try child("g").int()
        let rows = values.dim(0)
        let rowLength = values.dim(1)
        let groupCount = scales.dim(1)
        guard shape.indices.contains(axis), shape[axis] == rows,
              shape.reduce(1, *) == rows * rowLength,
              groupCount * groupSize >= rowLength else {
            throw WoofModelError.invalidWeights("\(path) has inconsistent quantization")
        }
        let grouped = padded(
            values,
            widths: [[0, 0], [0, groupCount * groupSize - rowLength]]
        )
        .reshaped(rows, groupCount, groupSize) * scales.expandedDimensions(axis: 2)
        var remaining = shape
        remaining.remove(at: axis)
        return evaluated(grouped
            .reshaped(rows, groupCount * groupSize)[0..., ..<rowLength]
            .reshaped([rows] + remaining)
            .movedAxis(source: 0, destination: axis))
    }

    private func evaluated(_ array: MLXArray) -> MLXArray {
        eval(array)
        return array
    }
}

/// `x @ weightᵀ + bias` for weights stored as `(output, input)`.
struct WoofLinear {
    let weight: MLXArray
    let bias: MLXArray?

    init(weight: MLXArray, bias: MLXArray?) {
        self.weight = weight.transposed()
        self.bias = bias
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let output = matmul(x, weight)
        return bias.map { output + $0 } ?? output
    }
}
