#!/usr/bin/env swift
import CryptoKit
import Foundation

// Keep private bytes out of stdout, command arguments, logs and Git.
let arguments = CommandLine.arguments
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}
guard arguments.count == 3, ["create", "public"].contains(arguments[1]) else {
    fail("Usage: update-key.swift create|public ENV_FILE")
}
let url = URL(fileURLWithPath: arguments[2])
let key: Curve25519.Signing.PrivateKey
if arguments[1] == "create" {
    guard !FileManager.default.fileExists(atPath: url.path) else {
        fail("The environment file already exists; refusing to overwrite signing material.")
    }
    key = Curve25519.Signing.PrivateKey()
    let content = "SAYIT_SPARKLE_PRIVATE_KEY=\(key.rawRepresentation.base64EncodedString())\n"
    guard FileManager.default.createFile(
        atPath: url.path,
        contents: Data(content.utf8),
        attributes: [.posixPermissions: 0o600]
    ) else { fail("Could not write the environment file.") }
} else {
    guard let content = try? String(contentsOf: url, encoding: .utf8),
          let line = content.split(separator: "\n").first(where: { $0.hasPrefix("SAYIT_SPARKLE_PRIVATE_KEY=") }),
          let bytes = Data(base64Encoded: String(line.dropFirst("SAYIT_SPARKLE_PRIVATE_KEY=".count))),
          bytes.count == 32,
          let loaded = try? Curve25519.Signing.PrivateKey(rawRepresentation: bytes) else {
        fail("The environment file must contain a valid SAYIT_SPARKLE_PRIVATE_KEY seed.")
    }
    key = loaded
}
print(key.publicKey.rawRepresentation.base64EncodedString())
