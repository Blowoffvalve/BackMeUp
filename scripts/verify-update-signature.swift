// Checks a Sparkle EdDSA signature the way users' copies of BackMeUp will, using only CryptoKit.
// Usage: swift scripts/verify-update-signature.swift PUBLIC_KEY SIGNATURE FILE
// PUBLIC_KEY and SIGNATURE are base64, as in SUPublicEDKey and the appcast's sparkle:edSignature.
// Exits 0 if SIGNATURE is FILE's signature by the key, and 1 otherwise.
import CryptoKit
import Foundation

let args = CommandLine.arguments
guard args.count == 4,
      let keyData = Data(base64Encoded: args[1]),
      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
      let signature = Data(base64Encoded: args[2]),
      let file = FileManager.default.contents(atPath: args[3])
else {
    FileHandle.standardError.write(Data("Usage: verify-update-signature.swift PUBLIC_KEY SIGNATURE FILE\n".utf8))
    exit(1)
}
exit(key.isValidSignature(signature, for: file) ? 0 : 1)
