import Foundation
@preconcurrency import MLX

/// One array stored in a `.npy` archive member, as little-endian C-order bytes.
struct NumPyArray {
    let descriptor: String
    let shape: [Int]
    let payload: Data

    var dtype: DType? {
        switch descriptor {
        case "<f4": .float32
        case "<f2": .float16
        case "|i1", "<i1": .int8
        case "<i4": .int32
        default: nil
        }
    }
}

/// Reads the uncompressed `.npz` archives written by NumPy's `savez`.
///
/// NumPy stores each array as a `.npy` member of a ZIP archive. Members are
/// located through the central directory because NumPy's local headers carry
/// ZIP64 placeholder sizes.
struct NumPyArchive {
    private let members: [String: NumPyArray]

    init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .alwaysMapped))
    }

    init(data: Data) throws {
        members = try Self.members(in: data)
    }

    /// A numeric array whose payload matches its shape and type.
    func array(named name: String) throws -> NumPyArray {
        let member = try member(named: name)
        guard let dtype = member.dtype else {
            throw NumPyArchiveError.unsupportedType(name, member.descriptor)
        }
        let byteCount = member.shape.reduce(Optional(dtype.size)) { total, dimension in
            total.map { $0.multipliedReportingOverflow(by: dimension) }
                .flatMap { $0.overflow ? nil : $0.partialValue }
        }
        guard member.payload.count == byteCount else {
            throw NumPyArchiveError.malformedMember(name)
        }
        return member
    }

    /// Decodes a scalar NumPy Unicode string (`<U…`), stored as UTF-32LE.
    func text(named name: String) throws -> String {
        let member = try member(named: name)
        guard member.descriptor.hasPrefix("<U"), member.shape.isEmpty,
              member.payload.count.isMultiple(of: 4) else {
            throw NumPyArchiveError.unsupportedType(name, member.descriptor)
        }
        // NumPy pads the fixed-width string with NUL characters.
        guard let text = String(data: member.payload, encoding: .utf32LittleEndian) else {
            throw NumPyArchiveError.malformedMember(name)
        }
        return String(text.prefix { $0 != "\0" })
    }

    private func member(named name: String) throws -> NumPyArray {
        guard let member = members[name] else {
            throw NumPyArchiveError.missingMember(name)
        }
        return member
    }

    private static func members(in data: Data) throws -> [String: NumPyArray] {
        let endRecordLength = 22
        guard data.count >= endRecordLength else {
            throw NumPyArchiveError.malformedArchive
        }
        let searchFloor = max(0, data.count - endRecordLength - Int(UInt16.max))
        guard let endRecord = stride(
            from: data.count - endRecordLength, through: searchFloor, by: -1
        ).first(where: {
            data.littleEndianInteger(UInt32.self, at: $0) == 0x0605_4B50
        }) else {
            throw NumPyArchiveError.malformedArchive
        }

        let entryCount = Int(data.littleEndianInteger(UInt16.self, at: endRecord + 10))
        var cursor = Int(data.littleEndianInteger(UInt32.self, at: endRecord + 16))
        var members: [String: NumPyArray] = [:]
        for _ in 0..<entryCount {
            guard cursor + 46 <= data.count,
                  data.littleEndianInteger(UInt32.self, at: cursor) == 0x0201_4B50 else {
                throw NumPyArchiveError.malformedArchive
            }
            let method = data.littleEndianInteger(UInt16.self, at: cursor + 10)
            let compressedSize = data.littleEndianInteger(UInt32.self, at: cursor + 20)
            let size = data.littleEndianInteger(UInt32.self, at: cursor + 24)
            let nameLength = Int(data.littleEndianInteger(UInt16.self, at: cursor + 28))
            let extraLength = Int(data.littleEndianInteger(UInt16.self, at: cursor + 30))
            let commentLength = Int(data.littleEndianInteger(UInt16.self, at: cursor + 32))
            let localHeader = Int(data.littleEndianInteger(UInt32.self, at: cursor + 42))
            guard cursor + 46 + nameLength <= data.count else {
                throw NumPyArchiveError.malformedArchive
            }
            let fileName = String(
                decoding: data.subdata(in: data.startIndex + cursor + 46
                    ..< data.startIndex + cursor + 46 + nameLength),
                as: UTF8.self
            )
            cursor += 46 + nameLength + extraLength + commentLength

            guard method == 0, compressedSize == size, size != UInt32.max,
                  localHeader != Int(UInt32.max) else {
                throw NumPyArchiveError.unsupportedMember(fileName)
            }
            guard localHeader + 30 <= data.count,
                  data.littleEndianInteger(UInt32.self, at: localHeader) == 0x0403_4B50 else {
                throw NumPyArchiveError.malformedArchive
            }
            let start = localHeader + 30
                + Int(data.littleEndianInteger(UInt16.self, at: localHeader + 26))
                + Int(data.littleEndianInteger(UInt16.self, at: localHeader + 28))
            let end = start + Int(size)
            guard end <= data.count else {
                throw NumPyArchiveError.malformedArchive
            }
            let name = fileName.hasSuffix(".npy")
                ? String(fileName.dropLast(4))
                : fileName
            members[name] = try member(
                named: name,
                in: data[data.startIndex + start ..< data.startIndex + end]
            )
        }
        return members
    }

    private static func member(named name: String, in data: Data) throws -> NumPyArray {
        let base = data.startIndex
        guard data.count >= 10,
              data.prefix(6).elementsEqual([0x93] + Array("NUMPY".utf8)) else {
            throw NumPyArchiveError.malformedMember(name)
        }
        let headerStart: Int
        let headerLength: Int
        switch data[base + 6] {
        case 1:
            headerStart = 10
            headerLength = Int(data.littleEndianInteger(UInt16.self, at: 8))
        case 2, 3:
            guard data.count >= 12 else {
                throw NumPyArchiveError.malformedMember(name)
            }
            headerStart = 12
            headerLength = Int(data.littleEndianInteger(UInt32.self, at: 8))
        default:
            throw NumPyArchiveError.malformedMember(name)
        }
        let payloadStart = headerStart + headerLength
        guard payloadStart <= data.count else {
            throw NumPyArchiveError.malformedMember(name)
        }
        let header = String(
            decoding: data[base + headerStart ..< base + payloadStart],
            as: UTF8.self
        )
        guard let descriptor = header.firstMatch(of: /'descr':\s*'([^']+)'/)?.1,
              header.contains(/'fortran_order':\s*False/),
              let dimensions = header.firstMatch(of: /'shape':\s*\(([^)]*)\)/)?.1 else {
            throw NumPyArchiveError.malformedMember(name)
        }
        let shape = try dimensions.split(separator: ",").compactMap { value -> Int? in
            let value = value.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { return nil }
            guard let dimension = Int(value), dimension >= 0 else {
                throw NumPyArchiveError.malformedMember(name)
            }
            return dimension
        }
        return NumPyArray(
            descriptor: String(descriptor),
            shape: shape,
            payload: data[(base + payloadStart)...]
        )
    }
}

private extension Data {
    func littleEndianInteger<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        withUnsafeBytes {
            T(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: T.self))
        }
    }
}
