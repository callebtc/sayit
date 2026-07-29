import Foundation
import Security
import SayItProtocol

struct SayItClientValidator {
    func accepts(_ connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == geteuid(),
              let client = signingInformation(
                processIdentifier: connection.processIdentifier
              ),
              isAuthorizedClient(client),
              SayItServiceIdentifiers.trustedClientBundleIdentifiers
                .contains(client.identifier),
              let own = signingInformation(processIdentifier: getpid()) else {
            return false
        }

        if let ownTeam = own.teamIdentifier {
            return client.teamIdentifier == ownTeam
        }
        return client.teamIdentifier == nil
    }

    private func isAuthorizedClient(_ client: SigningInformation) -> Bool {
#if DEBUG
        client.hasClientEntitlement || client.teamIdentifier == nil
#else
        client.hasClientEntitlement
#endif
    }

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
}

private struct SigningInformation {
    let identifier: String
    let teamIdentifier: String?
    let hasClientEntitlement: Bool
}
