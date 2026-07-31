import Foundation
import Testing

@Suite("GitHub update checker")
struct UpdateCheckerTests {
    @Test("Reports a newer release and sends GitHub headers")
    func reportsAvailableUpdate() async throws {
        let releaseURL = try #require(
            URL(string: "https://github.com/example/sayit/releases/tag/v1.10.0")
        )
        let checker = try makeChecker(
            tag: "v1.10.0",
            releaseURL: releaseURL
        ) { request in
            #expect(
                request.value(forHTTPHeaderField: "Accept")
                    == "application/vnd.github+json"
            )
            #expect(
                request.value(forHTTPHeaderField: "X-GitHub-Api-Version")
                    == "2026-03-10"
            )
            #expect(
                request.value(forHTTPHeaderField: "User-Agent")
                    == "SayIt/1.9.0"
            )
        }

        let result = try await checker.check(currentVersion: "1.9.0")

        #expect(
            result == .available(version: "1.10.0", url: releaseURL)
        )
    }

    @Test("Reports current for an equal or newer running version")
    func reportsCurrentVersion() async throws {
        let checker = try makeChecker(tag: "V1.2.3")

        let equal = try await checker.check(currentVersion: "1.2.3")
        let newer = try await checker.check(currentVersion: "1.3.0")

        #expect(equal == .current)
        #expect(newer == .current)
    }

    @Test("A stable release supersedes a running prerelease")
    func stableReleaseSupersedesPrerelease() async throws {
        let releaseURL = try #require(
            URL(string: "https://github.com/example/sayit/releases/tag/v1.2.0")
        )
        let checker = try makeChecker(
            tag: "v1.2.0",
            releaseURL: releaseURL
        )

        let result = try await checker.check(
            currentVersion: "1.2.0-beta.2"
        )

        #expect(
            result == .available(version: "1.2.0", url: releaseURL)
        )
    }

    @Test("A missing published release is not a network failure")
    func handlesRepositoryWithoutRelease() async throws {
        let checker = try makeChecker(tag: "v1.0.0", statusCode: 404)

        let result = try await checker.check(currentVersion: "1.0.0")

        #expect(result == .noPublishedRelease)
    }

    @Test("Rejects malformed local and release versions")
    func rejectsMalformedVersions() async throws {
        let validChecker = try makeChecker(tag: "v1.0.0")
        await #expect(throws: UpdateCheckerError.invalidCurrentVersion) {
            _ = try await validChecker.check(currentVersion: "development")
        }

        let invalidReleaseChecker = try makeChecker(tag: "latest")
        await #expect(throws: UpdateCheckerError.invalidReleaseTag) {
            _ = try await invalidReleaseChecker.check(
                currentVersion: "1.0.0"
            )
        }
    }

    @Test("Only opens HTTPS release pages on GitHub")
    func rejectsUntrustedReleaseURL() async throws {
        let untrustedURL = try #require(
            URL(string: "https://example.com/sayit/releases/tag/v2.0.0")
        )
        let checker = try makeChecker(
            tag: "v2.0.0",
            releaseURL: untrustedURL
        )

        await #expect(throws: UpdateCheckerError.invalidReleaseURL) {
            _ = try await checker.check(currentVersion: "1.0.0")
        }
    }

    @Test("Reports non-successful GitHub responses")
    func rejectsFailedRequest() async throws {
        let checker = try makeChecker(tag: "v1.0.0", statusCode: 503)

        await #expect(
            throws: UpdateCheckerError.requestFailed(statusCode: 503)
        ) {
            _ = try await checker.check(currentVersion: "1.0.0")
        }
    }

    private func makeChecker(
        tag: String,
        releaseURL: URL? = nil,
        statusCode: Int = 200,
        inspectRequest: @escaping @Sendable (URLRequest) -> Void = { _ in }
    ) throws -> UpdateChecker {
        let endpoint = try #require(
            URL(string: "https://api.github.com/repositories/1/releases/latest")
        )
        let releaseURL = try #require(
            releaseURL ?? URL(
                string: "https://github.com/example/sayit/releases/tag/v1.0.0"
            )
        )
        let data = try JSONSerialization.data(
            withJSONObject: [
                "tag_name": tag,
                "html_url": releaseURL.absoluteString
            ]
        )

        return UpdateChecker(releasesURL: endpoint) { request in
            inspectRequest(request)
            let response = try #require(
                HTTPURLResponse(
                    url: endpoint,
                    statusCode: statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            return (data, response)
        }
    }
}
