import CryptoKit
import Foundation
import SayItCore

actor ModelManager: ModelManaging {
    typealias ProgressHandler = @Sendable (ModelDownloadProgress) async -> Void
    typealias TokenProvider = @Sendable () async throws -> String?

    private var modelList: [ModelDescriptor]
    private let dependencyList: [ModelDependencyDescriptor]
    private let directories: AppDirectories
    private let session: URLSession
    private let tokenProvider: TokenProvider
    private var activeModelID: ModelID
    private var activeInstallID: ModelID?
    private var activeInstallTask: Task<Void, Error>?

    init(
        catalog: ModelCatalog,
        directories: AppDirectories,
        activeModelID: ModelID,
        session: URLSession = .shared,
        tokenProvider: @escaping TokenProvider = { nil }
    ) {
        modelList = catalog.models
        dependencyList = catalog.dependencies
        self.directories = directories
        self.activeModelID = activeModelID
        self.session = session
        self.tokenProvider = tokenProvider
        let customURL = directories.applicationSupport.appending(
            path: "CustomModels.json"
        )
        if let data = try? Data(contentsOf: customURL),
           let customModels = try? JSONDecoder().decode(
               [ModelDescriptor].self,
               from: data
           ) {
            modelList.append(contentsOf: customModels)
        }
    }

    func models() -> [ModelDescriptor] {
        modelList
    }

    func install(_ id: ModelID) async throws {
        try await install(id) { _ in }
    }

    func install(
        _ id: ModelID,
        progress: @escaping ProgressHandler
    ) async throws {
        guard activeInstallID == nil else {
            throw ModelManagerError.anotherDownloadIsActive
        }
        guard let model = modelList.first(where: { $0.id == id }) else {
            throw ModelManagerError.modelNotFound
        }
        guard model.isSelectable else {
            throw ModelManagerError.modelUnavailable
        }
        if rawInstallation(for: model) != nil {
            let staleStaging = directories.downloads.appending(
                path: "\(model.id.rawValue)-\(model.revision).partial",
                directoryHint: .isDirectory
            )
            try? FileManager.default.removeItem(at: staleStaging)
            return
        }

        activeInstallID = id
        let task = Task {
            try await self.performInstall(model, progress: progress)
        }
        activeInstallTask = task
        defer {
            activeInstallID = nil
            activeInstallTask = nil
        }
        try await task.value
    }

    func cancelInstall(_ id: ModelID) {
        guard activeInstallID == id else { return }
        activeInstallTask?.cancel()
    }

    func remove(_ id: ModelID) throws {
        guard id != activeModelID else {
            throw ModelManagerError.activeModelCannotBeRemoved
        }
        guard let model = modelList.first(where: { $0.id == id }),
              let installation = rawInstallation(for: model) else {
            return
        }
        let url = directories.models.appending(path: installation.relativePath)
        try FileManager.default.removeItem(at: url)
        for dependency in dependencies(for: model) {
            let isStillNeeded = modelList.contains { candidate in
                candidate.id != model.id
                    && rawInstallation(for: candidate) != nil
                    && dependencies(for: candidate).contains {
                        $0.id == dependency.id
                    }
            }
            if !isStillNeeded {
                let dependencyURL = dependencyDestination(dependency)
                if FileManager.default.fileExists(
                    atPath: dependencyURL.path
                ) {
                    try FileManager.default.removeItem(at: dependencyURL)
                }
            }
        }
        if model.repository == "local-import" {
            modelList.removeAll { $0.id == id }
            try persistCustomModels()
        }
    }

    func select(_ id: ModelID) throws {
        guard let model = modelList.first(where: { $0.id == id }) else {
            throw ModelManagerError.modelNotFound
        }
        guard model.isSelectable else {
            throw ModelManagerError.modelUnavailable
        }
        guard installation(for: model) != nil else {
            throw ModelManagerError.incompleteSnapshot
        }
        activeModelID = id
    }

    func installedModelIDs() -> Set<ModelID> {
        Set(modelList.compactMap { installation(for: $0)?.modelID })
    }

    func installedURL(for id: ModelID) -> URL? {
        guard let model = modelList.first(where: { $0.id == id }),
              let installation = installation(for: model) else {
            return nil
        }
        return directories.models.appending(path: installation.relativePath)
    }

    func addCommunityModel(_ model: ModelDescriptor) throws {
        if let index = modelList.firstIndex(where: { $0.id == model.id }) {
            modelList[index] = model
        } else {
            modelList.append(model)
        }
        try persistCustomModels()
    }

    func importLocalModel(
        _ model: ModelDescriptor,
        from source: URL
    ) throws {
        try preflight(requiredBytes: model.estimatedDiskBytes)
        let staging = directories.downloads.appending(
            path: "\(model.id.rawValue)-\(model.revision).importing",
            directoryHint: .isDirectory
        )
        if FileManager.default.fileExists(atPath: staging.path) {
            try FileManager.default.removeItem(at: staging)
        }
        try FileManager.default.copyItem(at: source, to: staging)
        do {
            let relativePath = "\(model.id.rawValue)/\(model.revision)"
            let installation = ModelInstallation(
                modelID: model.id,
                revision: model.revision,
                installedBytes: model.estimatedDiskBytes,
                verifiedAt: .now,
                dependenciesVerifiedAt: requiresManagedDependencies(model)
                    ? nil
                    : .now,
                relativePath: relativePath
            )
            let metadata = try JSONEncoder.sayIt.encode(installation)
            try metadata.write(
                to: staging.appending(path: "installation.json"),
                options: .atomic
            )
            let finalURL = directories.models.appending(
                path: relativePath,
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(
                at: finalURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: finalURL.path) {
                try FileManager.default.removeItem(at: finalURL)
            }
            try FileManager.default.moveItem(at: staging, to: finalURL)
            try addCommunityModel(model)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    private func performInstall(
        _ model: ModelDescriptor,
        progress: @escaping ProgressHandler
    ) async throws {
        var files = model.files
        if files.isEmpty {
            files = try await resolveManifest(for: model)
        }
        guard !files.isEmpty else {
            throw ModelManagerError.incompleteSnapshot
        }

        let dependencies = dependencies(for: model)
        let dependencyBytes = dependencies.reduce(Int64(0)) {
            $0 + $1.files.reduce(Int64(0)) { $0 + $1.byteCount }
        }
        let totalBytes = files.reduce(Int64(0)) { $0 + $1.byteCount }
            + dependencyBytes
        try preflight(requiredBytes: max(totalBytes, model.estimatedDiskBytes))

        let stagingName = "\(model.id.rawValue)-\(model.revision).partial"
        let staging = directories.downloads.appending(
            path: stagingName,
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: staging,
            withIntermediateDirectories: true
        )

        var completedBytes = existingVerifiedBytes(in: staging, files: files)
        for dependency in dependencies {
            let installed = dependencyDestination(dependency)
            if dependencyIsValid(dependency, at: installed) {
                completedBytes += dependency.files.reduce(Int64(0)) {
                    $0 + $1.byteCount
                }
            } else {
                let dependencyStaging = staging
                    .appending(path: "__dependencies")
                    .appending(path: dependency.id)
                completedBytes += existingVerifiedBytes(
                    in: dependencyStaging,
                    files: dependency.files
                )
            }
        }
        let startedAt = ContinuousClock.now
        await progress(
            ModelDownloadProgress(
                modelID: model.id,
                state: .downloading,
                completedBytes: completedBytes,
                totalBytes: totalBytes,
                bytesPerSecond: 0
            )
        )

        do {
            for file in files {
                try Task.checkCancellation()
                let destination = staging.appending(path: file.path)
                if isValidExistingFile(destination, descriptor: file) {
                    continue
                }

                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let remoteURL = try downloadURL(
                    repository: model.repository,
                    revision: model.revision,
                    path: file.path
                )
                let resumeURL = destination.appendingPathExtension("resume")
                let delegate = ModelFileDownloadDelegate(
                    modelID: model.id,
                    baseCompletedBytes: completedBytes,
                    totalModelBytes: totalBytes,
                    progress: progress
                )
                let downloadedFile = destination.appendingPathExtension(
                    "download"
                )
                let response = try await delegate.download(
                    using: session,
                    request: try await authorizedRequest(url: remoteURL),
                    resumeData: try? Data(contentsOf: resumeURL),
                    to: downloadedFile,
                    resumeDataURL: resumeURL
                )
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else {
                    throw ModelManagerError.invalidResponse
                }

                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(
                    at: downloadedFile,
                    to: destination
                )
                try? FileManager.default.removeItem(at: resumeURL)
                try verify(destination, descriptor: file)
                completedBytes += file.byteCount
                let elapsed = startedAt.duration(to: .now)
                let elapsedSeconds = max(
                    Double(elapsed.components.seconds)
                        + Double(elapsed.components.attoseconds) / 1e18,
                    0.001
                )
                await progress(
                    ModelDownloadProgress(
                        modelID: model.id,
                        state: .downloading,
                        completedBytes: completedBytes,
                        totalBytes: totalBytes,
                        bytesPerSecond: Int64(Double(completedBytes) / elapsedSeconds)
                    )
                )
            }

            for dependency in dependencies {
                let installed = dependencyDestination(dependency)
                if dependencyIsValid(dependency, at: installed) {
                    continue
                }
                let dependencyStaging = staging
                    .appending(path: "__dependencies")
                    .appending(path: dependency.id)
                try FileManager.default.createDirectory(
                    at: dependencyStaging,
                    withIntermediateDirectories: true
                )

                for file in dependency.files {
                    try Task.checkCancellation()
                    let destination = dependencyStaging.appending(
                        path: file.path
                    )
                    if isValidExistingFile(destination, descriptor: file) {
                        continue
                    }
                    try FileManager.default.createDirectory(
                        at: destination.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    let remoteURL = try downloadURL(
                        repository: dependency.repository,
                        revision: dependency.revision,
                        path: file.path
                    )
                    let resumeURL = destination.appendingPathExtension(
                        "resume"
                    )
                    let delegate = ModelFileDownloadDelegate(
                        modelID: model.id,
                        baseCompletedBytes: completedBytes,
                        totalModelBytes: totalBytes,
                        progress: progress
                    )
                    let downloadedFile = destination.appendingPathExtension(
                        "download"
                    )
                    let response = try await delegate.download(
                        using: session,
                        request: try await authorizedRequest(url: remoteURL),
                        resumeData: try? Data(contentsOf: resumeURL),
                        to: downloadedFile,
                        resumeDataURL: resumeURL
                    )
                    guard let http = response as? HTTPURLResponse,
                          (200..<300).contains(http.statusCode) else {
                        throw ModelManagerError.invalidResponse
                    }
                    if FileManager.default.fileExists(
                        atPath: destination.path
                    ) {
                        try FileManager.default.removeItem(at: destination)
                    }
                    try FileManager.default.moveItem(
                        at: downloadedFile,
                        to: destination
                    )
                    try? FileManager.default.removeItem(at: resumeURL)
                    try verify(destination, descriptor: file)
                    completedBytes += file.byteCount
                }
                guard dependencyIsValid(
                    dependency,
                    at: dependencyStaging
                ) else {
                    throw ModelManagerError.incompleteSnapshot
                }
            }

            await progress(
                ModelDownloadProgress(
                    modelID: model.id,
                    state: .verifying,
                    completedBytes: completedBytes,
                    totalBytes: totalBytes,
                    bytesPerSecond: 0
                )
            )
            try validateSnapshot(at: staging, model: model, files: files)

            for dependency in dependencies {
                let destination = dependencyDestination(dependency)
                guard !dependencyIsValid(dependency, at: destination) else {
                    continue
                }
                let dependencyStaging = staging
                    .appending(path: "__dependencies")
                    .appending(path: dependency.id)
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(
                    at: dependencyStaging,
                    to: destination
                )
                if dependency.id == "kitten-tts-g2p" {
                    let source = destination.appending(
                        path: "us_bart_config.json"
                    )
                    let compatibilityConfig = destination.appending(
                        path: "config.json"
                    )
                    if !FileManager.default.fileExists(
                        atPath: compatibilityConfig.path
                    ) {
                        try FileManager.default.copyItem(
                            at: source,
                            to: compatibilityConfig
                        )
                    }
                }
            }
            try? FileManager.default.removeItem(
                at: staging.appending(path: "__dependencies")
            )

            let relativePath = "\(model.id.rawValue)/\(model.revision)"
            let installation = ModelInstallation(
                modelID: model.id,
                revision: model.revision,
                installedBytes: completedBytes,
                verifiedAt: .now,
                dependenciesVerifiedAt: requiresManagedDependencies(model)
                    ? nil
                    : .now,
                relativePath: relativePath
            )
            let metadata = try JSONEncoder.sayIt.encode(installation)
            try metadata.write(
                to: staging.appending(path: "installation.json"),
                options: .atomic
            )

            let finalURL = directories.models.appending(
                path: relativePath,
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(
                at: finalURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: finalURL.path) {
                try FileManager.default.removeItem(at: finalURL)
            }
            try FileManager.default.moveItem(at: staging, to: finalURL)
            await progress(
                ModelDownloadProgress(
                    modelID: model.id,
                    state: .installed,
                    completedBytes: completedBytes,
                    totalBytes: totalBytes,
                    bytesPerSecond: 0
                )
            )
        } catch is CancellationError {
            throw CancellationError()
        }
    }

    private func persistCustomModels() throws {
        let customModels = modelList.filter {
            $0.id.rawValue.hasPrefix("community-")
        }
        let data = try JSONEncoder.sayIt.encode(customModels)
        try data.write(
            to: directories.applicationSupport.appending(path: "CustomModels.json"),
            options: .atomic
        )
    }

    private func resolveManifest(
        for model: ModelDescriptor
    ) async throws -> [ModelFileDescriptor] {
        guard let url = URL(
            string: "https://huggingface.co/api/models/\(model.repository)/revision/\(model.revision)?blobs=true"
        ) else {
            throw ModelManagerError.invalidDownloadURL
        }
        let (data, response) = try await session.data(
            for: try await authorizedRequest(url: url)
        )
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw ModelManagerError.invalidResponse
        }
        let remote = try JSONDecoder().decode(HuggingFaceModelResponse.self, from: data)
        guard remote.sha == model.revision else {
            throw ModelManagerError.invalidResponse
        }

        return remote.siblings.compactMap { sibling in
            guard shouldInstall(sibling.rfilename) else { return nil }
            let byteCount = sibling.lfs?.size ?? sibling.size ?? 0
            guard byteCount > 0 else { return nil }
            return ModelFileDescriptor(
                path: sibling.rfilename,
                byteCount: byteCount,
                sha256: sibling.lfs?.sha256
            )
        }
    }

    private func shouldInstall(_ path: String) -> Bool {
        if path.hasPrefix("samples/") || path.hasPrefix(".") {
            return false
        }
        let lower = path.lowercased()
        return lower.hasSuffix(".json")
            || lower.hasSuffix(".safetensors")
            || lower.hasSuffix(".npz")
            || lower.hasSuffix(".model")
            || lower.hasSuffix(".txt")
            || lower.hasSuffix(".tiktoken")
            || lower.hasSuffix(".py")
            || lower.hasSuffix(".wav")
    }

    private func downloadURL(
        repository: String,
        revision: String,
        path: String
    ) throws -> URL {
        let allowed = CharacterSet.urlPathAllowed.subtracting(
            CharacterSet(charactersIn: "#?")
        )
        guard let encodedPath = path.addingPercentEncoding(
            withAllowedCharacters: allowed
        ),
        let url = URL(
            string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(encodedPath)"
        ) else {
            throw ModelManagerError.invalidDownloadURL
        }
        return url
    }

    private func dependencies(
        for model: ModelDescriptor
    ) -> [ModelDependencyDescriptor] {
        let modelType = model.modelType.lowercased()
        return dependencyList.filter {
            $0.modelTypes.contains(modelType)
        }
    }

    private func dependencyDestination(
        _ dependency: ModelDependencyDescriptor
    ) -> URL {
        directories.hubCache
            .appending(path: "mlx-audio")
            .appending(path: dependency.targetSubdirectory)
    }

    private func dependencyIsValid(
        _ dependency: ModelDependencyDescriptor,
        at directory: URL
    ) -> Bool {
        dependency.files.allSatisfy {
            isValidExistingFile(
                directory.appending(path: $0.path),
                descriptor: $0
            )
        }
    }

    private func authorizedRequest(url: URL) async throws -> URLRequest {
        var request = URLRequest(url: url)
        if let token = try await tokenProvider(), !token.isEmpty {
            request.setValue(
                "Bearer \(token)",
                forHTTPHeaderField: "Authorization"
            )
        }
        return request
    }

    private func preflight(requiredBytes: Int64) throws {
        let values = try directories.models.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        guard let available = values.volumeAvailableCapacityForImportantUsage,
              available >= requiredBytes + requiredBytes / 5 else {
            throw ModelManagerError.insufficientDiskSpace(
                required: requiredBytes + requiredBytes / 5
            )
        }
    }

    private func validateSnapshot(
        at url: URL,
        model: ModelDescriptor,
        files: [ModelFileDescriptor]
    ) throws {
        let config = url.appending(path: "config.json")
        guard let configData = try? Data(contentsOf: config),
              let configJSON = try? JSONSerialization.jsonObject(
                  with: configData
              ) as? [String: Any],
              SupportedModelTypes.all.contains(model.modelType.lowercased()),
              files.contains(where: {
                  $0.path.hasSuffix(".safetensors") && $0.byteCount > 0
              }) else {
            throw ModelManagerError.incompleteSnapshot
        }
        for file in files {
            try verify(url.appending(path: file.path), descriptor: file)
        }

        let declaredType = (
            configJSON["model_type"] as? String
                ?? configJSON["architecture"] as? String
                ?? configJSON["model_version"] as? String
        )?.lowercased()
        guard let declaredType else {
            return
        }
        guard SupportedModelTypes.all.contains(declaredType),
              declaredType == model.modelType.lowercased()
                || model.modelType.lowercased().contains(declaredType)
                || declaredType.contains(model.modelType.lowercased()) else {
            throw ModelManagerError.modelUnavailable
        }
    }

    private func installation(for model: ModelDescriptor) -> ModelInstallation? {
        guard let installation = rawInstallation(for: model) else {
            return nil
        }
        if requiresManagedDependencies(model),
           installation.dependenciesVerifiedAt == nil {
            return nil
        }
        return installation
    }

    private func rawInstallation(
        for model: ModelDescriptor
    ) -> ModelInstallation? {
        let relativePath = "\(model.id.rawValue)/\(model.revision)"
        let url = directories.models
            .appending(path: relativePath)
            .appending(path: "installation.json")
        guard let data = try? Data(contentsOf: url),
              let installation = try? JSONDecoder.sayIt.decode(
                  ModelInstallation.self,
                  from: data
              ),
              installation.revision == model.revision else {
            return nil
        }
        return installation
    }

    func markDependenciesVerified(_ id: ModelID) throws {
        guard let model = modelList.first(where: { $0.id == id }),
              let installation = rawInstallation(for: model) else {
            throw ModelManagerError.incompleteSnapshot
        }
        let updated = ModelInstallation(
            modelID: installation.modelID,
            revision: installation.revision,
            installedBytes: installation.installedBytes,
            verifiedAt: installation.verifiedAt,
            dependenciesVerifiedAt: .now,
            relativePath: installation.relativePath
        )
        let metadata = try JSONEncoder.sayIt.encode(updated)
        try metadata.write(
            to: directories.models
                .appending(path: installation.relativePath)
                .appending(path: "installation.json"),
            options: .atomic
        )
    }

    private func requiresManagedDependencies(
        _ model: ModelDescriptor
    ) -> Bool {
        ["kokoro", "kokoro_tts", "kitten", "kitten_tts"].contains(
            model.modelType.lowercased()
        )
    }

    private func existingVerifiedBytes(
        in directory: URL,
        files: [ModelFileDescriptor]
    ) -> Int64 {
        files.reduce(Int64(0)) { result, file in
            result + (
                isValidExistingFile(
                    directory.appending(path: file.path),
                    descriptor: file
                ) ? file.byteCount : 0
            )
        }
    }

    private func isValidExistingFile(
        _ url: URL,
        descriptor: ModelFileDescriptor
    ) -> Bool {
        guard let size = try? url.resourceValues(
            forKeys: [.fileSizeKey]
        ).fileSize else {
            return false
        }
        return Int64(size) == descriptor.byteCount
    }

    private func verify(
        _ url: URL,
        descriptor: ModelFileDescriptor
    ) throws {
        guard isValidExistingFile(url, descriptor: descriptor) else {
            throw ModelManagerError.incompleteSnapshot
        }
        guard let expected = descriptor.sha256 else { return }

        var hasher = SHA256()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let data = try handle.read(upToCount: 1_024 * 1_024), !data.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: data)
        }
        let actual = hasher.finalize().map { byte in
            String(byte, radix: 16).leftPadding(toLength: 2, withPad: "0")
        }.joined()
        guard actual == expected else {
            try? FileManager.default.removeItem(at: url)
            throw ModelManagerError.checksumMismatch(path: descriptor.path)
        }
    }
}
