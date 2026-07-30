import Foundation

public enum VoiceSelection: Codable, Equatable, Hashable, Sendable {
    case automaticStable
    case preset(String)
    case profile(UUID)
    case randomPerParagraph

    private enum CodingKeys: String, CodingKey {
        case kind
        case id
    }

    private enum Kind: String, Codable {
        case automaticStable
        case preset
        case profile
        case randomPerParagraph
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .automaticStable:
            self = .automaticStable
        case .preset:
            self = .preset(try container.decode(String.self, forKey: .id))
        case .profile:
            self = .profile(try container.decode(UUID.self, forKey: .id))
        case .randomPerParagraph:
            self = .randomPerParagraph
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .automaticStable:
            try container.encode(Kind.automaticStable, forKey: .kind)
        case .preset(let id):
            try container.encode(Kind.preset, forKey: .kind)
            try container.encode(id, forKey: .id)
        case .profile(let id):
            try container.encode(Kind.profile, forKey: .kind)
            try container.encode(id, forKey: .id)
        case .randomPerParagraph:
            try container.encode(Kind.randomPerParagraph, forKey: .kind)
        }
    }
}
