import Foundation

/// Sends messages through ntfy over the System port, and logs failed sends with the topic and
/// token hidden. Never waits for the network itself.
@MainActor
struct NtfySender {
    let system: any System

    /// Sends a message if `settings` is set up; does nothing otherwise. A failed send is logged.
    func send(
        title: String,
        body: String,
        tag: NtfyTag,
        with settings: NtfySettings,
        completion: @escaping @MainActor (NtfySendResult) -> Void = { _ in }
    ) {
        guard settings.isSetUp else { return }
        let message = NtfyMessage(settings: settings, title: title, body: body, tags: [tag])
        let system = system
        system.sendNtfy(message) { result in
            if case let .failed(reason) = result {
                system.log("Couldn't send the \"\(title)\" phone alert through ntfy: \(Self.redacted(reason, hiding: settings))")
            }
            completion(result)
        }
    }

    /// The Settings window's test message, and how it went.
    func sendTestMessage(with settings: NtfySettings) async -> NtfyTestResult {
        guard settings.isSetUp else { return .needsTopic }
        let result = await withCheckedContinuation { continuation in
            send(
                title: "BackMeUp test message",
                body: "Phone alerts from BackMeUp will arrive here.",
                tag: .success,
                with: settings
            ) { continuation.resume(returning: $0) }
        }
        switch result {
        case .sent: return .sent
        case let .failed(reason): return .failed(reason)
        }
    }

    /// The text with the topic and token blanked out, so neither reaches the log.
    static func redacted(_ text: String, hiding settings: NtfySettings) -> String {
        var text = text
        for secret in [settings.topic, settings.token ?? ""] where !secret.isEmpty {
            text = text.replacingOccurrences(of: secret, with: "[hidden]")
        }
        return text
    }
}
