import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class CommandLineInstallController {
    enum Status: Equatable {
        case notInstalled
        case installed(URL)
    }

    private(set) var status: Status = .notInstalled
    private(set) var errorMessage: String?

    private let bookmarkDefaultsKey = "commandLineInstallBookmark"

    private static var realHomeDirectory: URL {
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: directory), isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    private var candidateDirectories: [URL] {
        [
            Self.realHomeDirectory.appending(path: ".local/bin", directoryHint: .isDirectory),
            URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
            URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
        ]
    }

    var preferredInstallDirectory: URL {
        Self.realHomeDirectory.appending(path: ".local/bin", directoryHint: .isDirectory)
    }

    func refresh(against toolURL: URL?) {
        guard toolURL != nil else {
            status = .notInstalled
            return
        }
        for directory in candidateDirectories {
            let link = directory.appending(path: "sayit")
            if FileManager.default.fileExists(atPath: link.path) {
                status = .installed(link)
                return
            }
        }
        status = .notInstalled
    }

    func installWithPanel(toolURL: URL) {
        errorMessage = nil
        guard let directory = chooseInstallDirectory() else { return }
        install(toolURL: toolURL, into: directory)
    }

    func install(toolURL: URL, into directory: URL) {
        errorMessage = nil
        let link = directory.appending(path: "sayit")
        do {
            if FileManager.default.fileExists(atPath: link.path) {
                guard isCommandLineSymlink(at: link) else {
                    errorMessage = "A file named “sayit” already exists in \(abbreviatedPath(for: directory)). Remove it manually or choose another folder."
                    return
                }
                try FileManager.default.removeItem(at: link)
            }
            try FileManager.default.createSymbolicLink(
                at: link,
                withDestinationURL: toolURL
            )
            saveBookmark(for: directory)
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh(against: toolURL)
    }

    func uninstall(toolURL: URL?) {
        errorMessage = nil
        guard case .installed(let link) = status else { return }
        guard isCommandLineSymlink(at: link) else {
            errorMessage = "The “sayit” command does not point to this app and was left untouched."
            status = .notInstalled
            return
        }
        let accessed = restoreBookmarkAccess(for: link.deletingLastPathComponent())
        defer {
            if accessed {
                link.deletingLastPathComponent().stopAccessingSecurityScopedResource()
            }
        }
        do {
            try FileManager.default.removeItem(at: link)
            UserDefaults.standard.removeObject(forKey: bookmarkDefaultsKey)
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh(against: toolURL)
    }

    func abbreviatedPath(for url: URL) -> String {
        let home = Self.realHomeDirectory.path
        let path = url.path
        guard path.hasPrefix(home) else { return path }
        let suffix = path.dropFirst(home.count)
        return suffix.isEmpty ? "~" : "~\(suffix)"
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func chooseInstallDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Install Here"
        panel.message = "Choose a folder in your shell’s PATH. The “sayit” command will be linked into it."
        let preferred = preferredInstallDirectory
        panel.directoryURL = FileManager.default.fileExists(atPath: preferred.path)
            ? preferred
            : Self.realHomeDirectory
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private func isCommandLineSymlink(at url: URL) -> Bool {
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(
            atPath: url.path
        ) else {
            return false
        }
        return destination.contains("SayItCLI.app")
    }

    private func saveBookmark(for directory: URL) {
        guard let data = try? directory.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else {
            return
        }
        UserDefaults.standard.set(data, forKey: bookmarkDefaultsKey)
    }

    private func restoreBookmarkAccess(for directory: URL) -> Bool {
        guard let data = UserDefaults.standard.data(forKey: bookmarkDefaultsKey)
        else {
            return false
        }
        var isStale = false
        guard let bookmarkURL = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return false
        }
        guard bookmarkURL.path == directory.path else { return false }
        return bookmarkURL.startAccessingSecurityScopedResource()
    }
}
