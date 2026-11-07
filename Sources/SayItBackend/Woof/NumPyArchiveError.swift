import Foundation

enum NumPyArchiveError: LocalizedError, Equatable {
    case malformedArchive
    case malformedMember(String)
    case unsupportedMember(String)
    case unsupportedType(String, String)
    case missingMember(String)

    var errorDescription: String? {
        switch self {
        case .malformedArchive:
            "The model weights archive could not be read."
        case .malformedMember(let name):
            "The model weights archive has an unreadable array named \(name)."
        case .unsupportedMember(let name):
            "The model weights archive stores \(name) in an unsupported format."
        case .unsupportedType(let name, let type):
            "The model weights archive stores \(name) as unsupported type \(type)."
        case .missingMember(let name):
            "The model weights archive is missing \(name)."
        }
    }
}
