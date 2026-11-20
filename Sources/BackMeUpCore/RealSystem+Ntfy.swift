import Foundation
import Security

/// ntfy and the Keychain for the real Mac.
extension RealSystem {
    /// The Keychain service BackMeUp's secrets are stored under, one item per `Secret`.
    public static let keychainService = "io.github.blowoffvalve.BackMeUp"
    /// The UserDefaults key for the ntfy server address.
    public static let ntfyServerKey = "ntfyServer"

    // MARK: ntfy

    /// POSTs the message with URLSession. Fails without sending if the server address isn't
    /// valid. The failure reason never contains the topic, the token or the URL.
    public func sendNtfy(_ message: NtfyMessage, completion: @escaping @MainActor (NtfySendResult) -> Void) {
        guard let request = message.request else {
            completion(.failed("the server address isn't a valid web address"))
            return
        }
        Task {
            let result: NtfySendResult
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                result = (200..<300).contains(status) ? .sent : .failed("the server answered \(status)")
            } catch let error as URLError {
                result = .failed("network error \(error.code.rawValue)")
            } catch {
                result = .failed("network error")
            }
            completion(result)
        }
    }

    // MARK: Secrets

    public func loadSecret(_ secret: Secret) -> String? {
        var query = Self.keychainQuery(secret)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func saveSecret(_ value: String?, as secret: Secret) {
        let query = Self.keychainQuery(secret)
        guard let value else {
            SecItemDelete(query as CFDictionary)
            return
        }
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    private static func keychainQuery(_ secret: Secret) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: secret.rawValue,
        ]
    }

    // MARK: The ntfy server

    public func loadNtfyServer() -> String? {
        UserDefaults.standard.string(forKey: Self.ntfyServerKey)
    }

    public func saveNtfyServer(_ server: String) {
        UserDefaults.standard.set(server, forKey: Self.ntfyServerKey)
    }
}
