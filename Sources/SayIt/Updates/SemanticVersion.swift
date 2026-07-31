import Foundation

struct SemanticVersion: Comparable, CustomStringConvertible, Sendable {
    private enum PrereleaseIdentifier: Equatable, Sendable {
        case numeric(String)
        case alphanumeric(String)
    }

    let major: UInt
    let minor: UInt
    let patch: UInt

    private let prerelease: [PrereleaseIdentifier]
    private let prereleaseDescription: [String]
    private let buildMetadata: [String]

    init?(tag rawValue: String) {
        var version = rawValue.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if version.first == "v" || version.first == "V" {
            version.removeFirst()
        }
        guard !version.isEmpty else { return nil }

        let buildParts = version.split(
            separator: "+",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard buildParts.count <= 2 else { return nil }
        if buildParts.count == 2 && buildParts[1].isEmpty {
            return nil
        }

        let buildIdentifiers = buildParts.count == 2
            ? buildParts[1].split(
                separator: ".",
                omittingEmptySubsequences: false
            )
            : []
        guard buildIdentifiers.allSatisfy(Self.isValidIdentifier) else {
            return nil
        }

        let precedenceParts = buildParts[0].split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard precedenceParts.count <= 2 else { return nil }
        if precedenceParts.count == 2 && precedenceParts[1].isEmpty {
            return nil
        }

        let core = precedenceParts[0].split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard core.count == 3,
              let major = Self.parseCoreIdentifier(core[0]),
              let minor = Self.parseCoreIdentifier(core[1]),
              let patch = Self.parseCoreIdentifier(core[2]) else {
            return nil
        }

        let prereleaseStrings = precedenceParts.count == 2
            ? precedenceParts[1].split(
                separator: ".",
                omittingEmptySubsequences: false
            )
            : []
        guard let prerelease = Self.parsePrerelease(prereleaseStrings) else {
            return nil
        }

        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
        prereleaseDescription = prereleaseStrings.map(String.init)
        buildMetadata = buildIdentifiers.map(String.init)
    }

    var description: String {
        var value = "\(major).\(minor).\(patch)"
        if !prereleaseDescription.isEmpty {
            value += "-\(prereleaseDescription.joined(separator: "."))"
        }
        if !buildMetadata.isEmpty {
            value += "+\(buildMetadata.joined(separator: "."))"
        }
        return value
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.major == rhs.major
            && lhs.minor == rhs.minor
            && lhs.patch == rhs.patch
            && lhs.prerelease == rhs.prerelease
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major {
            return lhs.major < rhs.major
        }
        if lhs.minor != rhs.minor {
            return lhs.minor < rhs.minor
        }
        if lhs.patch != rhs.patch {
            return lhs.patch < rhs.patch
        }
        if lhs.prerelease.isEmpty {
            return false
        }
        if rhs.prerelease.isEmpty {
            return true
        }

        for (left, right) in zip(lhs.prerelease, rhs.prerelease) {
            if left == right {
                continue
            }
            return Self.precedes(left, right)
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }

    private static func parseCoreIdentifier(
        _ identifier: Substring
    ) -> UInt? {
        guard isASCIINumber(identifier),
              identifier.count == 1 || identifier.first != "0" else {
            return nil
        }
        return UInt(identifier)
    }

    private static func parsePrerelease(
        _ identifiers: [Substring]
    ) -> [PrereleaseIdentifier]? {
        var parsed: [PrereleaseIdentifier] = []
        parsed.reserveCapacity(identifiers.count)

        for identifier in identifiers {
            guard isValidIdentifier(identifier) else { return nil }
            if isASCIINumber(identifier) {
                guard identifier.count == 1 || identifier.first != "0" else {
                    return nil
                }
                parsed.append(.numeric(String(identifier)))
            } else {
                parsed.append(.alphanumeric(String(identifier)))
            }
        }
        return parsed
    }

    private static func isValidIdentifier(_ identifier: Substring) -> Bool {
        !identifier.isEmpty && identifier.utf8.allSatisfy { byte in
            (48...57).contains(byte)
                || (65...90).contains(byte)
                || (97...122).contains(byte)
                || byte == 45
        }
    }

    private static func isASCIINumber(_ identifier: Substring) -> Bool {
        !identifier.isEmpty
            && identifier.utf8.allSatisfy { (48...57).contains($0) }
    }

    private static func precedes(
        _ lhs: PrereleaseIdentifier,
        _ rhs: PrereleaseIdentifier
    ) -> Bool {
        switch (lhs, rhs) {
        case (.numeric(let left), .numeric(let right)):
            if left.count != right.count {
                return left.count < right.count
            }
            return left < right
        case (.numeric, .alphanumeric):
            return true
        case (.alphanumeric, .numeric):
            return false
        case (.alphanumeric(let left), .alphanumeric(let right)):
            return left < right
        }
    }
}
