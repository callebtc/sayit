import Foundation

public struct VoiceProfileResolver: Sendable {
    public init() {}

    public func resolve(
        identifier: String,
        requestedModelID: String?,
        currentModelID: String,
        profiles: [VoiceProfileSnapshot]
    ) throws -> VoiceProfileSnapshot {
        let profile: VoiceProfileSnapshot?
        if let id = UUID(uuidString: identifier) {
            profile = profiles.first { $0.id == id }
        } else {
            let modelID = requestedModelID ?? currentModelID
            let matches = profiles.filter {
                $0.modelID == modelID
                    && $0.displayName.compare(
                        identifier,
                        options: [.caseInsensitive, .diacriticInsensitive]
                    ) == .orderedSame
            }
            guard matches.count <= 1 else {
                throw ServiceFailure(
                    code: "voice.ambiguous_name",
                    message: "More than one saved voice has that name. Use its UUID."
                )
            }
            profile = matches.first
        }
        guard let profile else {
            throw ServiceFailure(
                code: "voice.not_found",
                message: "The saved voice was not found."
            )
        }
        if let requestedModelID, requestedModelID != profile.modelID {
            throw ServiceFailure(
                code: "voice.model_mismatch",
                message: "That saved voice belongs to \(profile.modelID)."
            )
        }
        return profile
    }
}
