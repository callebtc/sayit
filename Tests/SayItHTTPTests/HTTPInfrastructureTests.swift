import Foundation
import Hummingbird
import HummingbirdTesting
@testable import SayItBackend
import SayItCore
import SayItProtocol
import Testing
@testable import SayItHTTP

@Suite("HTTP infrastructure", .serialized)
struct HTTPInfrastructureTests {
    @Test("Rate limits are isolated by key and stop exactly at the limit")
    func rateLimiterBoundaries() async {
        let limiter = APIRateLimiter()
        #expect(await limiter.consume(key: "a", limit: 2))
        #expect(await limiter.consume(key: "a", limit: 2))
        #expect(!(await limiter.consume(key: "a", limit: 2)))
        #expect(await limiter.consume(key: "b", limit: 1))
        #expect(!(await limiter.consume(key: "zero", limit: 0)))
    }

    @Test("Idempotency entries are isolated by token and key")
    func idempotencyIsolation() async {
        let store = IdempotencyStore()
        let firstToken = UUID()
        let secondToken = UUID()
        let job = SpeechJob(source: .http, title: "Idempotent")

        #expect(await store.job(tokenID: firstToken, key: "key") == nil)
        await store.store(job, tokenID: firstToken, key: "key")
        #expect(
            await store.job(tokenID: firstToken, key: "key")?.id == job.id
        )
        #expect(await store.job(tokenID: firstToken, key: "other") == nil)
        #expect(await store.job(tokenID: secondToken, key: "key") == nil)
    }

    @Test("Submission defaults and conflicts map to service semantics")
    func submissionDefaults() throws {
        let request = HTTPSubmission(text: "Read this.")
        let submission = try request.serviceSubmission()
        #expect(submission.inputFormat == .plainText)
        #expect(submission.source == .http)
        #expect(submission.queuePolicy == .enqueue)
        #expect(!submission.permitsLongText)

        #expect(throws: HTTPAPIError.self) {
            _ = try HTTPSubmission(
                text: "Read this.",
                voice: "preset",
                voiceSelection: .automaticStable
            ).serviceSubmission()
        }
    }

    @Test("Server validates ports, hosts, status mapping, and response headers")
    @MainActor
    func serverResponseBoundaries() throws {
        let fixture = try HTTPBackendFixture()
        defer { fixture.remove() }

        for port in [0, 1_023, 65_536] {
            #expect(throws: HTTPAPIError.self) {
                _ = try SayItHTTPServer(
                    backend: fixture.backend,
                    port: port
                )
            }
        }
        let server = try SayItHTTPServer(
            backend: fixture.backend,
            port: 49_123
        )
        #expect(server.isAllowedHost("localhost"))
        #expect(server.isAllowedHost("localhost:49123"))
        #expect(server.isAllowedHost("127.0.0.1"))
        #expect(server.isAllowedHost("127.0.0.1:49123"))
        #expect(!server.isAllowedHost("localhost:1"))
        #expect(!server.isAllowedHost(nil))

        #expect(server.status(for: "voice.not_found") == 404)
        #expect(server.status(for: "model.unavailable") == 404)
        #expect(server.status(for: "job.not_awaiting") == 409)
        #expect(server.status(for: "voice.active_cannot_remove") == 409)
        #expect(server.status(for: "speech.too_long") == 413)
        #expect(server.status(for: "request.invalid") == 400)

        let unauthorized = server.problemResponse(
            HTTPAPIError(
                status: 401,
                code: "authentication.missing_token",
                message: "Missing"
            )
        )
        #expect(unauthorized.status == .unauthorized)
        #expect(unauthorized.headers[.wwwAuthenticate] == "Bearer")
        #expect(
            unauthorized.headers[.contentType]?
                .hasPrefix("application/problem+json") == true
        )

        let file = server.fileResponse(
            ExportedFile(
                filename: "unsafe\"name.txt",
                contentType: "text/plain",
                data: Data("value".utf8)
            )
        )
        #expect(file.status == .ok)
        #expect(
            file.headers[.contentDisposition]
                == "attachment; filename=\"unsafename.txt\""
        )

        #expect(
            server.response(
                for: .failure(
                    ServiceFailure(
                        code: "history.not_found",
                        message: "Missing"
                    )
                )
            ).status == .notFound
        )
        #expect(
            server.response(for: .accepted, successStatus: .accepted).status
                == .accepted
        )
    }

    @Test("System, state, job, playback, model, history, and settings routes integrate")
    @MainActor
    func routeIntegration() async throws {
        let fixture = try HTTPBackendFixture()
        defer { fixture.remove() }
        await fixture.backend.start()
        let tokenID = UUID()
        let server = try SayItHTTPServer(
            backend: fixture.backend,
            port: 49_124
        ) { token, scope in
            guard token == "all-access" else {
                throw ServiceFailure(
                    code: "authentication.invalid_token",
                    message: "Invalid"
                )
            }
            return APITokenMetadata(
                id: tokenID,
                name: "Integration",
                prefix: "all",
                scopes: [scope],
                createdAt: .now,
                lastUsedAt: nil
            )
        }
        let router = Router()
        server.registerSystemRoutes(on: router)
        server.registerJobRoutes(on: router)
        server.registerPlaybackRoutes(on: router)
        server.registerModelRoutes(on: router)
        server.registerHistoryRoutes(on: router)
        server.registerSettingsRoutes(on: router)
        let app = Application(router: router)
        let authorized: HTTPFields = {
            var fields = HTTPFields()
            fields[.authorization] = "Bearer all-access"
            return fields
        }()
        let jsonHeaders: HTTPFields = {
            var fields = authorized
            fields[.contentType] = "application/json"
            return fields
        }()

        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/health", method: .get) {
                #expect($0.status == .ok)
                let health = try SayItWireCodec.decode(
                    HealthResponse.self,
                    from: Data($0.body.readableBytesView)
                )
                #expect(health.status == "ok")
            }
            try await client.execute(uri: "/v1/openapi.json", method: .get) {
                #expect($0.status == .ok)
                #expect(!$0.body.readableBytesView.isEmpty)
            }
            try await client.execute(uri: "/v1/state", method: .get) {
                #expect($0.status == .unauthorized)
            }
            var invalidAuth = HTTPFields()
            invalidAuth[.authorization] = "Bearer invalid"
            try await client.execute(
                uri: "/v1/state",
                method: .get,
                headers: invalidAuth
            ) {
                #expect($0.status == .unauthorized)
            }

            for uri in [
                "/v1/state",
                "/v1/jobs",
                "/v1/models",
                "/v1/history",
                "/v1/settings",
                "/v1/diagnostics"
            ] {
                try await client.execute(
                    uri: uri,
                    method: .get,
                    headers: authorized
                ) {
                    #expect($0.status == .ok)
                    #expect(
                        $0.headers[.cacheControl] == "no-store"
                            || uri == "/v1/jobs"
                    )
                }
            }

            try await client.execute(
                uri: "/v1/playback/seek",
                method: .post,
                headers: jsonHeaders,
                body: ByteBuffer(string: "not-json")
            ) {
                #expect($0.status == .badRequest)
            }
            try await client.execute(
                uri: "/v1/playback/seek",
                method: .post,
                headers: jsonHeaders,
                body: ByteBuffer(
                    bytes: try SayItWireCodec.encode(
                        SecondsRequest(seconds: 12)
                    )
                )
            ) {
                #expect($0.status == .accepted)
            }

            var badKeyHeaders = jsonHeaders
            badKeyHeaders[
                .init("idempotency-key")!
            ] = String(repeating: "x", count: 129)
            try await client.execute(
                uri: "/v1/jobs",
                method: .post,
                headers: badKeyHeaders,
                body: ByteBuffer(
                    bytes: try SayItWireCodec.encode(
                        HTTPSubmission(text: "Read")
                    )
                )
            ) {
                #expect($0.status == .badRequest)
            }

            var idempotentHeaders = jsonHeaders
            idempotentHeaders[.init("idempotency-key")!] = "same"
            let body = ByteBuffer(
                bytes: try SayItWireCodec.encode(
                    HTTPSubmission(
                        text: String(
                            repeating: "Long route text. ",
                            count: 5_000
                        )
                    )
                )
            )
            var firstID: UUID?
            try await client.execute(
                uri: "/v1/jobs",
                method: .post,
                headers: idempotentHeaders,
                body: body
            ) {
                #expect($0.status == .accepted)
                let job = try SayItWireCodec.decode(
                    SpeechJob.self,
                    from: Data($0.body.readableBytesView)
                )
                firstID = job.id
                #expect($0.headers[.location] != nil)
            }
            try await client.execute(
                uri: "/v1/jobs",
                method: .post,
                headers: idempotentHeaders,
                body: body
            ) {
                let job = try SayItWireCodec.decode(
                    SpeechJob.self,
                    from: Data($0.body.readableBytesView)
                )
                #expect(job.id == firstID)
            }
            try await client.execute(
                uri: "/v1/jobs/not-a-uuid",
                method: .get,
                headers: authorized
            ) {
                #expect($0.status == .badRequest)
            }
            try await client.execute(
                uri: "/v1/jobs/\(UUID().uuidString)",
                method: .get,
                headers: authorized
            ) {
                #expect($0.status == .notFound)
            }
        }
        #expect(fixture.playback.elapsed == 12)
    }
}

@MainActor
private final class HTTPBackendFixture {
    let root: URL
    let playback: HTTPTestPlayback
    let backend: SayItBackendService

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "SayItHTTPTests-\(UUID().uuidString)"
        )
        let directories = try AppDirectories.testing(root: root)
        playback = HTTPTestPlayback()
        backend = try SayItBackendService(
            directories: directories,
            playback: playback
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private final class HTTPTestPlayback: BackendPlaybackControlling {
    var onFailure: (@MainActor (String) -> Void)?
    private(set) var state: PlaybackState = .idle
    private(set) var elapsed: TimeInterval = 0
    private(set) var generatedDuration: TimeInterval = 0
    private(set) var estimatedDuration: TimeInterval = 0
    private(set) var amplitudes: [Float] = []
    private(set) var currentTitle = ""
    private(set) var spokenText = ""
    private(set) var spokenChunks: [PlaybackTextChunk] = []
    var shouldStartWhenBuffered = false
    var showTitleInNowPlaying = false
    var rate: Double = 1
    var backwardSkipInterval: TimeInterval = 15
    var forwardSkipInterval: TimeInterval = 30

    func prepare(
        requestID _: UUID,
        title: String,
        estimatedDuration: TimeInterval
    ) {
        currentTitle = title
        self.estimatedDuration = estimatedDuration
        state = .preparing
    }

    func enqueue(_ chunk: AudioChunk) throws {
        generatedDuration += chunk.duration
    }

    func setSpokenText(_ text: String) {
        spokenText = text
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
    }

    func seek(to seconds: TimeInterval) { elapsed = seconds }
    func skip(by seconds: TimeInterval) { elapsed += seconds }
    func finishBuffering() { state = .playing }

    func archive(
        using _: AudioArchive
    ) async throws -> AudioArchiveResult {
        throw CocoaError(.featureUnsupported)
    }

    func playFile(at _: URL, title: String) throws {
        currentTitle = title
        state = .playing
    }
}
