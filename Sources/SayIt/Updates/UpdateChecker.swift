import Foundation

actor UpdateChecker {
    private let session: URLSession
    private let releasesURL: URL?

    init(
        session: URLSession = .shared,
        releasesURL: URL? = nil
    ) {
        self.session = session
        self.releasesURL = releasesURL ?? (
            Bundle.main.object(
                forInfoDictionaryKey: "SayItUpdateAPIURL"
            ) as? String
        ).flatMap(URL.init(string:))
    }

    func check(currentVersion: String) async throws -> UpdateResult {
        guard let releasesURL else {
            return .unconfigured
        }
        var request = URLRequest(url: releasesURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("SayIt/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw CocoaError(.fileReadUnknown)
        }
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        let latest = release.tagName.trimmingCharacters(
            in: CharacterSet(charactersIn: "vV")
        )
        if latest.compare(
            currentVersion,
            options: .numeric
        ) == .orderedDescending {
            return .available(version: latest, url: release.htmlURL)
        }
        return .current
    }
}
