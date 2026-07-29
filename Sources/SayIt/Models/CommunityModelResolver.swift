import Foundation
import CryptoKit
import SayItCore

actor CommunityModelResolver {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func resolve(
        repository: String,
        revision: String?,
        token: String?
    ) async throws -> ModelDescriptor {
        let normalizedRepository = repository.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard normalizedRepository.split(separator: "/").count == 2 else {
            throw ModelManagerError.modelNotFound
        }
        let requestedRevision = revision?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).nilIfEmpty ?? "main"
        guard let metadataURL = URL(
            string: "https://huggingface.co/api/models/\(normalizedRepository)/revision/\(requestedRevision)?blobs=true"
        ) else {
            throw ModelManagerError.invalidDownloadURL
        }
        let (metadataData, metadataResponse) = try await session.data(
            for: request(url: metadataURL, token: token)
        )
        guard let http = metadataResponse as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw ModelManagerError.invalidResponse
        }
        let metadata = try JSONDecoder().decode(
            HuggingFaceModelResponse.self,
            from: metadataData
        )

        guard let configURL = URL(
            string: "https://huggingface.co/\(normalizedRepository)/resolve/\(metadata.sha)/config.json"
        ) else {
            throw ModelManagerError.invalidDownloadURL
        }
        let (configData, configResponse) = try await session.data(
            for: request(url: configURL, token: token)
        )
        guard let configHTTP = configResponse as? HTTPURLResponse,
              (200..<300).contains(configHTTP.statusCode),
              let config = try JSONSerialization.jsonObject(
                  with: configData
              ) as? [String: Any],
              let rawType = (
                  config["model_type"] as? String
                    ?? config["architecture"] as? String
                    ?? config["model_version"] as? String
              )?.lowercased(),
              SupportedModelTypes.all.contains(rawType) else {
            throw ModelManagerError.modelUnavailable
        }

        let diskBytes = metadata.siblings.reduce(Int64(0)) {
            $0 + ($1.lfs?.size ?? $1.size ?? 0)
        }
        let referenceOnly = [
            "echo_tts", "echo", "indextts", "index_tts", "moss_tts_nano"
        ].contains(rawType)
        let voiceDesign = ["irodori_tts", "irodori", "omnivoice"].contains(rawType)
        let progressive = [
            "kokoro", "kokoro_tts", "kitten_tts", "kitten", "pocket_tts"
        ].contains(rawType)
        let defaultVoice: String? = if ["kokoro", "kokoro_tts"].contains(rawType) {
            "af_heart"
        } else {
            nil
        }

        let repositoryName = normalizedRepository.split(separator: "/").last
            .map(String.init) ?? normalizedRepository
        let safeID = normalizedRepository
            .lowercased()
            .replacing("/", with: "-")
            .replacing("_", with: "-")
        let licenseID = metadata.cardData?.license ?? "See model card"
        let licenseURL = URL(
            string: "https://huggingface.co/\(normalizedRepository)"
        ) ?? URL(filePath: "/")

        return ModelDescriptor(
            id: ModelID("community-\(safeID)-\(metadata.sha.prefix(8))"),
            displayName: repositoryName,
            family: "Community model",
            repository: normalizedRepository,
            revision: metadata.sha,
            modelType: rawType,
            parameterCount: "Unknown",
            quantization: "Repository",
            languages: [],
            voices: defaultVoice.map { [$0] } ?? [],
            defaultVoice: defaultVoice,
            defaultLanguage: nil,
            capabilities: ModelCapabilities(
                presetVoices: defaultVoice != nil,
                voiceDescription: voiceDesign,
                voiceCloning: referenceOnly,
                streaming: progressive,
                longForm: true,
                languageSelection: true,
                requiresReferenceAudio: referenceOnly
            ),
            playbackMode: progressive ? .progressive : .buffered,
            files: [],
            estimatedDiskBytes: max(diskBytes, 1),
            estimatedPeakMemoryBytes: max(diskBytes * 2, 1_000_000_000),
            hardwareTier: diskBytes > 2_000_000_000 ? .high : .mid,
            license: ModelLicense(
                identifier: licenseID,
                url: licenseURL,
                commercialUseAllowed: false,
                requiresAcceptance: true
            ),
            stability: referenceOnly ? .unavailable : .experimental,
            testedMLXAudioVersion: "0.1.3",
            testedDate: "Community model — not tested"
        )
    }

    func resolveLocal(directory: URL) throws -> ModelDescriptor {
        let configURL = directory.appending(path: "config.json")
        let configData = try Data(contentsOf: configURL)
        guard let config = try JSONSerialization.jsonObject(
            with: configData
        ) as? [String: Any],
        let rawType = (
            config["model_type"] as? String
                ?? config["architecture"] as? String
                ?? config["model_version"] as? String
        )?.lowercased(),
        SupportedModelTypes.all.contains(rawType) else {
            throw ModelManagerError.modelUnavailable
        }

        let resourceKeys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw ModelManagerError.incompleteSnapshot
        }

        var files: [(path: String, bytes: Int64)] = []
        while let fileURL = enumerator.nextObject() as? URL {
            let values = try fileURL.resourceValues(forKeys: resourceKeys)
            guard values.isSymbolicLink != true else {
                throw ModelManagerError.incompleteSnapshot
            }
            guard values.isRegularFile == true else { continue }
            let relativePath = String(
                fileURL.path.dropFirst(directory.path.count + 1)
            )
            files.append((relativePath, Int64(values.fileSize ?? 0)))
        }
        guard files.contains(where: {
            $0.path.hasSuffix(".safetensors") && $0.bytes > 0
        }) else {
            throw ModelManagerError.incompleteSnapshot
        }

        var hasher = SHA256()
        hasher.update(data: configData)
        for file in files.sorted(by: { $0.path < $1.path }) {
            hasher.update(data: Data("\(file.path):\(file.bytes)".utf8))
        }
        let revision = hasher.finalize().map {
            String($0, radix: 16).leftPadding(toLength: 2, withPad: "0")
        }.joined()
        let diskBytes = files.reduce(Int64(0)) { $0 + $1.bytes }
        let referenceOnly = [
            "echo_tts", "echo", "indextts", "index_tts", "moss_tts_nano"
        ].contains(rawType)
        let voiceDesign = ["irodori_tts", "irodori", "omnivoice"].contains(rawType)
        let progressive = [
            "kokoro", "kokoro_tts", "kitten_tts", "kitten", "pocket_tts"
        ].contains(rawType)
        let defaultVoice = ["kokoro", "kokoro_tts"].contains(rawType)
            ? "af_heart"
            : nil

        return ModelDescriptor(
            id: ModelID("community-local-\(revision.prefix(12))"),
            displayName: directory.lastPathComponent,
            family: "Imported model",
            repository: "local-import",
            revision: revision,
            modelType: rawType,
            parameterCount: "Unknown",
            quantization: "Local",
            languages: [],
            voices: defaultVoice.map { [$0] } ?? [],
            defaultVoice: defaultVoice,
            defaultLanguage: nil,
            capabilities: ModelCapabilities(
                presetVoices: defaultVoice != nil,
                voiceDescription: voiceDesign,
                voiceCloning: referenceOnly,
                streaming: progressive,
                longForm: true,
                languageSelection: true,
                requiresReferenceAudio: referenceOnly
            ),
            playbackMode: progressive ? .progressive : .buffered,
            files: [],
            estimatedDiskBytes: max(diskBytes, 1),
            estimatedPeakMemoryBytes: max(diskBytes * 2, 1_000_000_000),
            hardwareTier: diskBytes > 2_000_000_000 ? .high : .mid,
            license: ModelLicense(
                identifier: "Review source license",
                url: URL(string: "https://huggingface.co") ?? URL(filePath: "/"),
                commercialUseAllowed: false,
                requiresAcceptance: true
            ),
            stability: referenceOnly ? .unavailable : .experimental,
            testedMLXAudioVersion: "0.1.3",
            testedDate: "Local model — not tested"
        )
    }

    private func request(url: URL, token: String?) -> URLRequest {
        var request = URLRequest(url: url)
        if let token, !token.isEmpty {
            request.setValue(
                "Bearer \(token)",
                forHTTPHeaderField: "Authorization"
            )
        }
        return request
    }
}
