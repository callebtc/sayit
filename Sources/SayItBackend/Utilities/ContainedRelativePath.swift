import Foundation

public enum ContainedRelativePath {
    public static func fileURL(
        _ relativePath: String,
        rootedAt root: URL
    ) throws -> URL {
        let components = relativePath.split(
            separator: "/",
            omittingEmptySubsequences: true
        )
        guard !relativePath.hasPrefix("/"),
              !components.isEmpty,
              components.allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw Failure.unsafePath
        }
        let target = components.reduce(root) {
            $0.appending(path: String($1))
        }.standardizedFileURL
        let allowedPrefix = root.standardizedFileURL.path + "/"
        guard target.path.hasPrefix(allowedPrefix) else {
            throw Failure.unsafePath
        }
        return target
    }

    public static func component(_ value: String) throws -> String {
        let components = value.split(
            separator: "/",
            omittingEmptySubsequences: true
        )
        guard !value.hasPrefix("/"),
              components.count == 1,
              value == String(components[0]),
              components[0] != ".",
              components[0] != ".." else {
            throw Failure.unsafePath
        }
        return value
    }

    public enum Failure: Error, Equatable, Sendable {
        case unsafePath
    }
}
