import Foundation

public extension JSONDecoder {
    static var sayIt: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
