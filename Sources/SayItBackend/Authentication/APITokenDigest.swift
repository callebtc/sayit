import CryptoKit
import Foundation

enum APITokenDigest {
    static func digest(_ token: String) -> Data {
        Data(SHA256.hash(data: Data(token.utf8)))
    }

    static func matches(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) {
            difference |= left ^ right
        }
        return difference == 0
    }
}
