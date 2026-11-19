import Foundation
import Hummingbird
import HummingbirdTesting
@testable import SayItBackend
import SayItCore
import SayItProtocol
import Testing
@testable import SayItHTTP

@Suite("HTTP event stream revocation", .serialized)
struct HTTPEventStreamRevocationTests {
    @Test("Revoking an API token ends its open event stream before later snapshots")
    @MainActor
    func revokedTokenEndsEventStreamBeforeLaterSnapshots() async throws {
        let fixture = try await EventStreamFixture()
        defer { fixture.remove() }
        let token = await fixture.tokens.issue(secret: "revoked-reader")

        try await fixture.run { client in
            let stream = try await fixture.openStream(client, token: token)
            defer { stream.cancel() }

            #expect(await stream.waitFor(fixture.initialMarker))
            try await Task.sleep(for: .milliseconds(150))
            #expect(!(await stream.isFinished()))

            await fixture.revoke(token)
            try await fixture.expectUnauthorized(client, token: token)
            #expect(await stream.waitUntilFinished())

            await fixture.publish(fixture.laterMarker)
            try await Task.sleep(for: .milliseconds(200))
            #expect(!(await stream.contains(fixture.laterMarker)))
            await stream.finish()
        }
    }

    @Test("Revoking an API token ends every event stream opened with that token")
    @MainActor
    func revokedTokenEndsEveryEventStreamItOpened() async throws {
        let fixture = try await EventStreamFixture()
        defer { fixture.remove() }
        let token = await fixture.tokens.issue(secret: "shared-reader")

        try await fixture.run { client in
            let first = try await fixture.openStream(client, token: token)
            let second = try await fixture.openStream(client, token: token)
            defer {
                first.cancel()
                second.cancel()
            }

            #expect(await first.waitFor(fixture.initialMarker))
            #expect(await second.waitFor(fixture.initialMarker))

            await fixture.revoke(token)
            #expect(await first.waitUntilFinished())
            #expect(await second.waitUntilFinished())

            await fixture.publish(fixture.laterMarker)
            try await Task.sleep(for: .milliseconds(200))
            #expect(!(await first.contains(fixture.laterMarker)))
            #expect(!(await second.contains(fixture.laterMarker)))
            await first.finish()
            await second.finish()
        }
    }

    @Test("Revoking one API token leaves another token's event stream open")
    @MainActor
    func revokingOneTokenLeavesAnotherTokensStreamOpen() async throws {
        let fixture = try await EventStreamFixture()
        defer { fixture.remove() }
        let revoked = await fixture.tokens.issue(secret: "revoked-reader")
        let kept = await fixture.tokens.issue(secret: "kept-reader")

        try await fixture.run { client in
            let revokedStream = try await fixture.openStream(client, token: revoked)
            let keptStream = try await fixture.openStream(client, token: kept)
            defer {
                revokedStream.cancel()
                keptStream.cancel()
            }

            #expect(await revokedStream.waitFor(fixture.initialMarker))
            #expect(await keptStream.waitFor(fixture.initialMarker))

            await fixture.revoke(revoked)
            #expect(await revokedStream.waitUntilFinished())
            #expect(!(await keptStream.isFinished()))

            await fixture.publish(fixture.laterMarker)
            #expect(await keptStream.waitFor(fixture.laterMarker))
            #expect(!(await revokedStream.contains(fixture.laterMarker)))
            await revokedStream.finish()
            await keptStream.finish()
        }
    }
}

@MainActor
private final class EventStreamFixture {
    let initialMarker = "initial-before-revocation"
    let laterMarker = "post-revocation-sensitive-state"
    let backend: SayItBackendService
    let tokens: RevocableTokenDirectory
    let root: URL
    private let capture = SSEBodyCapture()
    private let server: SayItHTTPServer

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "SayItHTTPEventStream-\(UUID().uuidString)"
        )
        let directories = try AppDirectories.testing(root: root)
        let tokens = RevocableTokenDirectory()
        backend = try SayItBackendService(
            directories: directories,
            playback: makeHeadlessPlaybackController()
        )
        self.tokens = tokens
        server = try SayItHTTPServer(
            backend: backend,
            port: 49_125,
            tokenAuthorizer: { token, scope in
                try await tokens.authorize(token: token, scope: scope)
            }
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func run(
        _ body: @escaping @Sendable (any TestClientProtocol) async throws -> Void
    ) async throws {
        await backend.start()
        await backend.reportServiceError(initialMarker)
        let router = Router()
        router.middlewares.add(SSEBodyCaptureMiddleware(capture: capture))
        server.registerSystemRoutes(on: router)
        let app = Application(router: router)
        try await app.test(.router) { client in
            try await body(client)
        }
    }

    func openStream(
        _ client: any TestClientProtocol,
        token: RevocableToken
    ) async throws -> RunningEventStream {
        try await client.execute(
            uri: "/v1/events",
            method: .get,
            headers: bearer(token.secret)
        ) { response in
            #expect(response.status == .ok)
        }
        let body = try #require(await capture.take())
        return RunningEventStream(body: body)
    }

    func revoke(_ token: RevocableToken) async {
        await tokens.revoke(token.id)
        let response = await backend.handle(
            ServiceRequest(command: .revokeToken(token.id))
        )
        guard case .accepted = response else {
            Issue.record("Revoking the API token failed: \(response)")
            return
        }
    }

    func publish(_ marker: String) async {
        await backend.reportServiceError(marker)
    }

    func expectUnauthorized(
        _ client: any TestClientProtocol,
        token: RevocableToken
    ) async throws {
        try await client.execute(
            uri: "/v1/state",
            method: .get,
            headers: bearer(token.secret)
        ) { response in
            #expect(response.status == .unauthorized)
        }
    }

    private func bearer(_ secret: String) -> HTTPFields {
        var fields = HTTPFields()
        fields[.authorization] = "Bearer \(secret)"
        return fields
    }
}

private struct RevocableToken: Sendable {
    let id: UUID
    let secret: String
}

private actor RevocableTokenDirectory {
    private var revoked: Set<UUID> = []
    private var secrets: [UUID: String] = [:]
    private var names: [UUID: String] = [:]

    func issue(secret: String) -> RevocableToken {
        let id = UUID()
        secrets[id] = secret
        names[id] = "Stream Reader"
        return RevocableToken(id: id, secret: secret)
    }

    func revoke(_ id: UUID) {
        revoked.insert(id)
    }

    func authorize(
        token: String,
        scope: APITokenScope
    ) throws -> APITokenMetadata {
        guard let id = secrets.first(where: { $0.value == token })?.key,
              !revoked.contains(id) else {
            throw ServiceFailure(
                code: "authentication.invalid_token",
                message: "The API token was revoked."
            )
        }
        return APITokenMetadata(
            id: id,
            name: names[id] ?? "Stream Reader",
            prefix: "stream",
            scopes: [scope],
            createdAt: .now,
            lastUsedAt: nil
        )
    }
}

private final class RunningEventStream: Sendable {
    private let recorder: SSEWriteRecorder
    private let task: Task<Void, Never>

    init(body: ResponseBody) {
        let recorder = SSEWriteRecorder()
        self.recorder = recorder
        task = Task.detached {
            var body = body
            try? await body.write(RecordingSSEWriter(recorder: recorder))
        }
    }

    func contains(_ marker: String) async -> Bool {
        let payloads = await recorder.payloads()
        return payloads.contains { $0.contains(marker) }
    }

    func isFinished() async -> Bool {
        await recorder.isFinished()
    }

    func waitFor(_ marker: String) async -> Bool {
        await poll(timeout: .seconds(5)) {
            await self.contains(marker)
        }
    }

    func waitUntilFinished() async -> Bool {
        await poll(timeout: .seconds(5)) {
            await self.isFinished()
        }
    }

    func cancel() {
        task.cancel()
    }

    func finish() async {
        task.cancel()
        await task.value
    }

    private func poll(
        timeout: Duration,
        condition: @Sendable () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            if await condition() { return true }
            if clock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor SSEBodyCapture {
    private var bodies: [ResponseBody] = []

    func store(_ body: ResponseBody) {
        bodies.append(body)
    }

    func take() -> ResponseBody? {
        guard !bodies.isEmpty else { return nil }
        return bodies.removeFirst()
    }
}

private struct SSEBodyCaptureMiddleware: RouterMiddleware {
    let capture: SSEBodyCapture

    func handle(
        _ request: Request,
        context: BasicRequestContext,
        next: (Request, BasicRequestContext) async throws -> Response
    ) async throws -> Response {
        let response = try await next(request, context)
        guard request.uri.path == "/v1/events", response.status == .ok else {
            return response
        }
        await capture.store(response.body)
        return Response(status: response.status, headers: response.headers)
    }
}

private actor SSEWriteRecorder {
    private var recordedPayloads: [String] = []
    private var finished = false

    func record(_ buffer: ByteBuffer) {
        recordedPayloads.append(
            String(decoding: buffer.readableBytesView, as: UTF8.self)
        )
    }

    func markFinished() {
        finished = true
    }

    func payloads() -> [String] {
        recordedPayloads
    }

    func isFinished() -> Bool {
        finished
    }
}

private struct RecordingSSEWriter: ResponseBodyWriter {
    let recorder: SSEWriteRecorder

    mutating func write(_ buffer: ByteBuffer) async throws {
        await recorder.record(buffer)
    }

    consuming func finish(_ trailingHeaders: HTTPFields?) async throws {
        await recorder.markFinished()
    }
}
