import Foundation
import SayItProtocol

public enum SayItCodeSigningRequirement {
    public static func forBundleIdentifiers(
        _ bundleIdentifiers: Set<String>
    ) -> String? {
#if DEBUG || SAYIT_LOCAL_BUILD
        nil
#else
        let identifierRequirement = bundleIdentifiers
            .sorted()
            .map { "identifier \"\($0)\"" }
            .joined(separator: " or ")
        guard !identifierRequirement.isEmpty else {
            return nil
        }

        return """
        anchor apple generic and \
        certificate 1[field.1.2.840.113635.100.6.2.6] exists and \
        certificate leaf[field.1.2.840.113635.100.6.1.13] exists and \
        certificate leaf[subject.OU] = "\(SayItServiceIdentifiers.teamIdentifier)" and \
        (\(identifierRequirement))
        """
#endif
    }
}

public struct SayItClientValidator {
    private let trustedBundleIdentifiers: Set<String>

    public var codeSigningRequirement: String? {
        SayItCodeSigningRequirement.forBundleIdentifiers(
            trustedBundleIdentifiers
        )
    }

    public init(
        trustedBundleIdentifiers: Set<String> = Set(
            SayItServiceIdentifiers.trustedClientBundleIdentifiers
        )
    ) {
        self.trustedBundleIdentifiers = trustedBundleIdentifiers
    }

    public func accepts(_ connection: NSXPCConnection) -> Bool {
        connection.effectiveUserIdentifier == geteuid()
    }
}
