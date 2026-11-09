// Checks Sparkle's EdDSA (Ed25519) signatures against a public key, with CryptoKit.
//
// Usage:
//   xcrun swift packaging/sparkle/ed25519.swift verify <base64 public key> <base64 signature> <file>
//     Exits 0 if the signature over the file's bytes is valid for the key, 1 otherwise.
//   xcrun swift packaging/sparkle/ed25519.swift test-sign <file>
//     For tests only: signs the file with a new throwaway key and prints
//     "<base64 public key> <base64 signature>".
//
// sign_update --verify can't replace this: it works from the private key, so it only
// shows that the update matches the key on hand, not the key the app ships with.

import CryptoKit
import Foundation

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func readFile(_ path: String) -> Data {
    guard let data = FileManager.default.contents(atPath: path) else {
        fail("Cannot read \(path)")
    }
    return data
}

let arguments = Array(CommandLine.arguments.dropFirst())

switch arguments.first {
case "verify" where arguments.count == 4:
    guard let keyData = Data(base64Encoded: arguments[1]),
          let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
    else {
        fail("The public key is not a base64 Ed25519 key")
    }
    guard let signature = Data(base64Encoded: arguments[2]) else {
        fail("The signature is not base64")
    }
    guard publicKey.isValidSignature(signature, for: readFile(arguments[3])) else {
        fail("The signature does not match \(arguments[3]) for this public key")
    }

case "test-sign" where arguments.count == 2:
    let privateKey = Curve25519.Signing.PrivateKey()
    let signature = try privateKey.signature(for: readFile(arguments[1]))
    print(privateKey.publicKey.rawRepresentation.base64EncodedString(), signature.base64EncodedString())

default:
    fail(
        "Usage: ed25519.swift verify <public key> <signature> <file> | test-sign <file>",
        code: 64
    )
}
