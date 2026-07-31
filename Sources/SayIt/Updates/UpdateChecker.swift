import Foundation

actor UpdateChecker {
    typealias DataLoader =
        @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let dataLoader: DataLoader
    private let releasesURL: URL?

    init(
        session: URLSession = .shared,
        releasesURL: URL? = nil
    ) {
        dataLoader = { request in
            try await session.data(for: request)
        }
        self.releasesURL = releasesURL ?? Self.configuredURL(
            from: Bundle.main.object(
                forInfoDictionaryKey: "SayItUpdateAPIURL"
            ) as? String
        )
    }

    init(
        releasesURL: URL?,
        dataLoader: @escaping DataLoader
    ) {
        self.releasesURL = releasesURL
        self.dataLoader = dataLoader
    }

    func check(currentVersion: String) async throws -> UpdateResult {
        guard let releasesURL else {
            return .unconfigured
        }
        guard let current = SemanticVersion(tag: currentVersion) else {
            throw UpdateCheckerError.invalidCurrentVersion
        }

        var request = URLRequest(url: releasesURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(
            "2026-03-10",
            forHTTPHeaderField: "X-GitHub-Api-Version"
        )
        request.setValue(
            "SayIt/\(current.description)",
            forHTTPHeaderField: "User-Agent"
        )

        let (data, response) = try await dataLoader(request)
        guard let http = response as? HTTPURLResponse else {
            throw UpdateCheckerError.invalidResponse
        }
        if http.statusCode == 404 {
            return .noPublishedRelease
        }
        guard (200..<300).contains(http.statusCode) else {
            throw UpdateCheckerError.requestFailed(
                statusCode: http.statusCode
            )
        }

        let release: GitHubRelease
        do {
            release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        } catch {
            throw UpdateCheckerError.invalidResponse
        }
        guard let latest = SemanticVersion(tag: release.tagName) else {
            throw UpdateCheckerError.invalidReleaseTag
        }
        guard Self.isTrustedGitHubURL(release.htmlURL) else {
            throw UpdateCheckerError.invalidReleaseURL
        }

        if latest > current {
            return .available(
                version: latest.description,
                url: release.htmlURL
            )
        }
        return .current
    }

    private static func isTrustedGitHubURL(_ url: URL) -> Bool {
        guard let components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ) else {
            return false
        }
        return components.scheme?.lowercased() == "https"
            && components.host?.lowercased() == "github.com"
            && components.user == nil
            && components.password == nil
            && (components.port == nil || components.port == 443)
    }

    private static func configuredURL(from value: String?) -> URL? {
        guard let value,
              let url = URL(
                string: value.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
              ),
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "api.github.com" else {
            return nil
        }
        return url
    }
}
