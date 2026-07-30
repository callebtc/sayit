import Foundation
import SayItCore
import SayItProtocol
import Security

actor APITokenStore {
    private static let service = "sh.sayit.mac.api-tokens"

    func create(
        name: String,
        scopes: Set<APITokenScope>
    ) throws -> APITokenCreation {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty, normalizedName.count <= 80 else {
            throw ServiceFailure(
                code: "token.invalid_name",
                message: "Give the token a name between 1 and 80 characters."
            )
        }
        guard !scopes.isEmpty else {
            throw ServiceFailure(
                code: "token.empty_scopes",
                message: "Select at least one permission."
            )
        }

        var randomBytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(
            kSecRandomDefault,
            randomBytes.count,
            &randomBytes
        ) == errSecSuccess else {
            throw ServiceFailure(
                code: "token.random_failed",
                message: "A secure API token could not be generated."
            )
        }

        let id = UUID()
        let prefix = "sayit_\(id.uuidString.lowercased().prefix(8))"
        let encodedSecret = Data(randomBytes)
            .base64EncodedString()
            .replacing("+", with: "-")
            .replacing("/", with: "_")
            .replacing("=", with: "")
        let secret = "\(prefix)_\(encodedSecret)"
        let metadata = APITokenMetadata(
            id: id,
            name: normalizedName,
            prefix: prefix,
            scopes: scopes,
            createdAt: .now,
            lastUsedAt: nil
        )
        let record = APITokenRecord(
            metadata: metadata,
            digest: APITokenDigest.digest(secret)
        )
        let data = try JSONEncoder.sayIt.encode(record)
        let status = SecItemAdd(
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Self.service,
                kSecAttrAccount as String: id.uuidString,
                kSecAttrAccessible as String:
                    kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                kSecValueData as String: data
            ] as CFDictionary,
            nil
        )
        guard status == errSecSuccess else {
            throw ServiceFailure(
                code: "token.keychain_failed",
                message: "The API token could not be stored in Keychain."
            )
        }
        return APITokenCreation(metadata: metadata, secret: secret)
    }

    func list() throws -> [APITokenMetadata] {
        try records().map(\.metadata).sorted {
            $0.createdAt > $1.createdAt
        }
    }

    func revoke(_ id: UUID) throws {
        let status = SecItemDelete(
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Self.service,
                kSecAttrAccount as String: id.uuidString
            ] as CFDictionary
        )
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ServiceFailure(
                code: "token.revoke_failed",
                message: "The API token could not be revoked."
            )
        }
    }

    func authorize(
        _ token: String,
        required scope: APITokenScope
    ) throws -> APITokenMetadata {
        let candidate = APITokenDigest.digest(token)
        guard var record = try records().first(where: {
            APITokenDigest.matches($0.digest, candidate)
        }) else {
            throw ServiceFailure(
                code: "authentication.invalid_token",
                message: "The API token is invalid."
            )
        }
        guard record.metadata.scopes.contains(scope) else {
            throw ServiceFailure(
                code: "authentication.insufficient_scope",
                message: "The API token does not grant this permission."
            )
        }

        record.metadata.lastUsedAt = .now
        try update(record)
        return record.metadata
    }

    private func records() throws -> [APITokenRecord] {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Self.service,
                kSecMatchLimit as String: kSecMatchLimitAll,
                kSecReturnData as String: true
            ] as CFDictionary,
            &result
        )
        if status == errSecItemNotFound {
            return []
        }
        guard status == errSecSuccess else {
            throw ServiceFailure(
                code: "token.keychain_failed",
                message: "API tokens could not be read from Keychain."
            )
        }

        let dataItems: [Data]
        if let values = result as? [Data] {
            dataItems = values
        } else if let value = result as? Data {
            dataItems = [value]
        } else {
            dataItems = []
        }
        return dataItems.compactMap {
            try? JSONDecoder.sayIt.decode(APITokenRecord.self, from: $0)
        }
    }

    private func update(_ record: APITokenRecord) throws {
        let data = try JSONEncoder.sayIt.encode(record)
        let status = SecItemUpdate(
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Self.service,
                kSecAttrAccount as String: record.metadata.id.uuidString
            ] as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        guard status == errSecSuccess else {
            throw ServiceFailure(
                code: "token.keychain_failed",
                message: "The API token metadata could not be updated."
            )
        }
    }
}
