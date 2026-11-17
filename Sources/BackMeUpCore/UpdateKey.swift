import Foundation

/// The EdDSA public key Sparkle checks updates against (`SUPublicEDKey` in Info.plist).
public enum UpdateKey {
    /// What `Packaging/Info.plist` holds until the maintainer adds the real key. Builds with it
    /// never check for updates, and `scripts/release.sh` refuses to sign a release.
    public static let placeholder = "REPLACE_WITH_SPARKLE_PUBLIC_ED_KEY"

    /// Whether `key` looks like a real Ed25519 public key: 32 bytes in base64, as Sparkle's
    /// `generate_keys` prints it.
    public static func isUsable(_ key: String?) -> Bool {
        guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines),
              let data = Data(base64Encoded: key)
        else { return false }
        return data.count == 32
    }
}
