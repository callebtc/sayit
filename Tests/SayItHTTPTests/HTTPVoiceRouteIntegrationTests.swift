import Foundation
import Hummingbird
import HummingbirdTesting
@testable import SayItBackend
import SayItCore
import SayItProtocol
import Testing
@testable import SayItHTTP

@Suite("HTTP voice routes", .serialized)
struct HTTPVoiceRouteIntegrationTests {
    @Test("Saved voice lifecycle enforces scopes and redacts private data")
    @MainActor
    func savedVoiceLifecycle() async throws {
        let fixture = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let router = Router()
        fixture.server.registerVoiceRoutes(on: router)
        let app = Application(router: router)

        try await app.test(.router) { client in
            let readHeaders = fixture.headers(
                token: fixture.readToken.secret
            )
            let writeHeaders = fixture.headers(
                token: fixture.writeToken.secret
            )
            let profilePath =
                "/v1/voices/\(fixture.profileID.uuidString)"

            try await client.execute(
                uri: "/v1/voices?modelID=\(fixture.modelID)",
                method: .get,
                headers: readHeaders
            ) { response in
                #expect(response.status == .ok)
                let body = Data(response.body.readableBytesView)
                let catalog = try SayItWireCodec.decode(
                    HTTPVoiceCatalogResponse.self,
                    from: body
                )
                #expect(catalog.profiles.map(\.id) == [fixture.profileID])
                #expect(catalog.models.map(\.modelID) == [fixture.modelID])
                let text = String(decoding: body, as: UTF8.self)
                #expect(!text.contains("private reference transcript"))
                #expect(!text.contains("reference.wav"))
                #expect(!text.contains(fixture.root.path))
            }

            try await client.execute(
                uri: profilePath,
                method: .get,
                headers: readHeaders
            ) { response in
                #expect(response.status == .ok)
                let profile = try SayItWireCodec.decode(
                    VoiceProfileSnapshot.self,
                    from: Data(response.body.readableBytesView)
                )
                #expect(profile.id == fixture.profileID)
            }

            try await client.execute(
                uri: "\(profilePath)/select",
                method: .post,
                headers: writeHeaders
            ) {
                #expect($0.status == .accepted)
            }

            var renameHeaders = writeHeaders
            renameHeaders[.contentType] = "application/json"
            let renameBody = ByteBuffer(
                bytes: try SayItWireCodec.encode(
                    RenameVoiceRequest(name: "Golden Harbor")
                )
            )
            try await client.execute(
                uri: profilePath,
                method: .patch,
                headers: renameHeaders,
                body: renameBody
            ) {
                #expect($0.status == .accepted)
            }

            try await client.execute(
                uri: profilePath,
                method: .patch,
                headers: readHeaders,
                body: renameBody
            ) { response in
                #expect(response.status == .forbidden)
                let problem = try SayItWireCodec.decode(
                    APIProblem.self,
                    from: Data(response.body.readableBytesView)
                )
                #expect(
                    problem.code == "authentication.insufficient_scope"
                )
                #expect(
                    response.headers[.contentType]?
                        .hasPrefix("application/problem+json") == true
                )
            }

            try await client.execute(
                uri: profilePath,
                method: .delete,
                headers: writeHeaders
            ) {
                #expect($0.status == .accepted)
            }
            try await client.execute(
                uri: profilePath,
                method: .get,
                headers: readHeaders
            ) { response in
                #expect(response.status == .notFound)
                let problem = try SayItWireCodec.decode(
                    APIProblem.self,
                    from: Data(response.body.readableBytesView)
                )
                #expect(problem.code == "voice.not_found")
            }
        }

        #expect(fixture.server.isAllowedHost("localhost"))
        #expect(fixture.server.isAllowedHost("127.0.0.1"))
        #expect(!fixture.server.isAllowedHost("example.com"))
        #expect(!fixture.server.isAllowedHost(nil))
    }
}

private extension HTTPVoiceRouteIntegrationTests {
    struct Fixture: @unchecked Sendable {
        let root: URL
        let modelID: String
        let profileID: UUID
        let backend: SayItBackendService
        let server: SayItHTTPServer
        let readToken: APITokenCreation
        let writeToken: APITokenCreation

        @MainActor
        static func make() async throws -> Self {
            let root = FileManager.default.temporaryDirectory.appending(
                path: "SayItHTTPVoiceTests-\(UUID().uuidString)"
            )
            let directories = try AppDirectories.testing(root: root)
            let modelID = "qwen3-06b-base-8bit"
            let profileID = UUID()
            try seedProfile(
                id: profileID,
                modelID: modelID,
                directories: directories
            )
            let backend = try SayItBackendService(
                directories: directories,
                playback: HTTPVoiceTestPlayback()
            )
            let readToken = makeToken(
                secret: "voice-route-read",
                scopes: [.voicesRead]
            )
            let writeToken = makeToken(
                secret: "voice-route-write",
                scopes: [.voicesRead, .voicesWrite]
            )
            return try Self(
                root: root,
                modelID: modelID,
                profileID: profileID,
                backend: backend,
                server: SayItHTTPServer(
                    backend: backend,
                    port: 49_321
                ) { token, scope in
                    let creation = switch token {
                    case readToken.secret:
                        readToken
                    case writeToken.secret:
                        writeToken
                    default:
                        throw ServiceFailure(
                            code: "authentication.invalid_token",
                            message: "The API token is invalid."
                        )
                    }
                    guard creation.metadata.scopes.contains(scope) else {
                        throw ServiceFailure(
                            code: "authentication.insufficient_scope",
                            message: "The API token does not grant this permission."
                        )
                    }
                    return creation.metadata
                },
                readToken: readToken,
                writeToken: writeToken
            )
        }

        func headers(token: String) -> HTTPFields {
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            return headers
        }

        private static func makeToken(
            secret: String,
            scopes: Set<APITokenScope>
        ) -> APITokenCreation {
            APITokenCreation(
                metadata: APITokenMetadata(
                    id: UUID(),
                    name: "Voice route test",
                    prefix: secret,
                    scopes: scopes,
                    createdAt: .now,
                    lastUsedAt: nil
                ),
                secret: secret
            )
        }

        private static func seedProfile(
            id: UUID,
            modelID: String,
            directories: AppDirectories
        ) throws {
            let directory = directories.voiceProfiles
                .appending(path: modelID, directoryHint: .isDirectory)
                .appending(path: id.uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try Data([0x52, 0x49, 0x46, 0x46]).write(
                to: directory.appending(path: "reference.wav")
            )
            let now = Date()
            let record = SeedProfile(
                schemaVersion: 1,
                id: id,
                modelID: modelID,
                displayName: "Silver Lark",
                origin: .recordedClone,
                language: "en",
                transcript: "private reference transcript",
                duration: 8,
                referenceFilename: "reference.wav",
                createdAt: now,
                updatedAt: now,
                tuning: VoiceTuning(),
                generationSeed: nil
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(record).write(
                to: directory.appending(path: "profile.json"),
                options: .atomic
            )
        }
    }

    struct SeedProfile: Codable {
        let schemaVersion: Int
        let id: UUID
        let modelID: String
        let displayName: String
        let origin: VoiceProfileOrigin
        let language: String?
        let transcript: String?
        let duration: TimeInterval
        let referenceFilename: String
        let createdAt: Date
        let updatedAt: Date
        let tuning: VoiceTuning
        let generationSeed: UInt64?
    }
}

@MainActor
private final class HTTPVoiceTestPlayback: BackendPlaybackControlling {
    var onFailure: (@MainActor (String) -> Void)?
    var onExternalControl: (@MainActor () -> Void)?
    var onStateChange: (@MainActor (PlaybackState) -> Void)?
    private(set) var state: PlaybackState = .idle {
        didSet {
            guard state != oldValue else { return }
            onStateChange?(state)
        }
    }
    private(set) var elapsed: TimeInterval = 0
    private(set) var generatedDuration: TimeInterval = 0
    private(set) var estimatedDuration: TimeInterval = 0
    private(set) var amplitudes: [Float] = []
    private(set) var currentTitle = ""
    private(set) var currentModelID: String?
    private(set) var spokenText = ""
    private(set) var spokenChunks: [PlaybackTextChunk] = []
    var shouldStartWhenBuffered = false
    var showTitleInNowPlaying = false
    var rate: Double = 1
    var volume: Double = 1
    var backwardSkipInterval: TimeInterval = 15
    var forwardSkipInterval: TimeInterval = 30

    func prepare(
        requestID _: UUID,
        title: String,
        estimatedDuration: TimeInterval,
        modelID: String?
    ) {
        currentTitle = title
        currentModelID = modelID
        self.estimatedDuration = estimatedDuration
        state = .preparing
    }

    func enqueue(_ chunk: AudioChunk) throws {
        generatedDuration += chunk.duration
        state = .buffering
    }

    func setSpokenText(_ text: String) {
        spokenText = text
        spokenChunks = []
    }

    func appendSpokenChunk(_ chunk: PlaybackTextChunk) {
        spokenChunks.append(chunk)
    }

    func play() { state = .playing }
    func pause() { state = .paused }

    func stop() {
        state = .idle
        elapsed = 0
        generatedDuration = 0
        estimatedDuration = 0
        currentTitle = ""
        currentModelID = nil
    }

    func stopForModelSwitch() async {
        stop()
    }

    func seek(to seconds: TimeInterval) { elapsed = seconds }
    func skip(by seconds: TimeInterval) { elapsed += seconds }
    func finishBuffering() { state = .playing }

    func archive(
        using _: AudioArchive
    ) async throws -> AudioArchiveResult {
        throw CocoaError(.featureUnsupported)
    }

    func playFile(at _: URL, title: String, modelID: String?) throws {
        currentTitle = title
        currentModelID = modelID
        state = .playing
    }
}
