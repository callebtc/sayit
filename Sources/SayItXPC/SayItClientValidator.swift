import Foundation
import Security
import SayItProtocol

public struct SayItClientValidator {
    private let trustedBundleIdentifiers: Set<String>

    public init(
        trustedBundleIdentifiers: Set<String> = Set(
            SayItServiceIdentifiers.trustedClientBundleIdentifiers
        )
    ) {
        self.trustedBundleIdentifiers = trustedBundleIdentifiers
    }

    public func accepts(_ connection: NSXPCConnection) -> Bool {
#if DEBUG || SAYIT_LOCAL_BUILD
        connection.effectiveUserIdentifier == geteuid()
#else
        guard connection.effectiveUserIdentifier == geteuid(),
              let client = signingInformation(
                processIdentifier: connection.processIdentifier
              ),
              client.hasClientEntitlement,
              trustedBundleIdentifiers.contains(client.identifier),
              let own = signingInformation(processIdentifier: getpid()) else {
            return false
        }

        if let ownTeam = own.teamIdentifier {
            return client.teamIdentifier == ownTeam
        }
        return client.teamIdentifier == nil
#endif
    }

#if !DEBUG && !SAYIT_LOCAL_BUILD
    private func signingInformation(
        processIdentifier: pid_t
    ) -> SigningInformation? {
        let attributes = [
            kSecGuestAttributePid: processIdentifier as CFNumber
        ] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(
            nil,
            attributes,
            SecCSFlags(),
            &code
        ) == errSecSuccess,
        let code else {
            return nil
        }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(
            code,
            SecCSFlags(),
            &staticCode
        ) == errSecSuccess,
        let staticCode else {
            return nil
        }

        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
        let dictionary = information as? [CFString: Any],
        let identifier = dictionary[kSecCodeInfoIdentifier] as? String else {
            return nil
        }

        let entitlements = dictionary[kSecCodeInfoEntitlementsDict]
            as? [String: Any]
        return SigningInformation(
            identifier: identifier,
            teamIdentifier: dictionary[kSecCodeInfoTeamIdentifier] as? String,
            hasClientEntitlement: entitlements?[
                SayItServiceIdentifiers.clientEntitlement
            ] as? Bool == true
        )
    }
#endif
}

#if !DEBUG && !SAYIT_LOCAL_BUILD
private struct SigningInformation {
    let identifier: String
    let teamIdentifier: String?
    let hasClientEntitlement: Bool
}
#endif
