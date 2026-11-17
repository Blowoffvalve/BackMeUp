import Foundation

/// Where phone alerts go through ntfy. ntfy is set up once a topic is given.
///
/// The server is stored with the other settings; the topic and token are secrets, stored in the
/// Keychain (see `Secret`), and never logged.
public struct NtfySettings: Equatable, Sendable {
    public static let defaultServer = "https://ntfy.sh"

    public var server: String
    public var topic: String
    /// An optional access token, sent as a bearer token.
    public var token: String?

    public init(server: String = NtfySettings.defaultServer, topic: String = "", token: String? = nil) {
        self.server = server
        self.topic = topic
        self.token = token
    }

    /// Whether alerts go to ntfy: a topic has been given.
    public var isSetUp: Bool { !topic.isEmpty }

    /// Trims spaces, drops an empty token, and falls back to the default server if none is given.
    var cleaned: NtfySettings {
        let server = server.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        return NtfySettings(
            server: server.isEmpty ? Self.defaultServer : server,
            topic: topic.trimmingCharacters(in: .whitespacesAndNewlines),
            token: token?.isEmpty == false ? token : nil
        )
    }
}

/// An ntfy tag. Emoji short codes such as `warning` show as an icon on the phone.
public enum NtfyTag: String, Equatable, Sendable {
    /// A problem, shown on the phone as a warning sign.
    case warning
    /// Good news, shown on the phone as a check mark.
    case success = "white_check_mark"
}

/// One message to send through ntfy: an HTTP POST of `body` to `server/topic`, with `Title` and
/// `Tags` headers and, when there's a token, `Authorization: Bearer <token>`.
public struct NtfyMessage: Equatable, Sendable {
    /// Where it goes: the server, topic and token.
    public var settings: NtfySettings
    public var title: String
    public var body: String
    public var tags: [NtfyTag]

    public init(settings: NtfySettings, title: String, body: String, tags: [NtfyTag]) {
        self.settings = settings
        self.title = title
        self.body = body
        self.tags = tags
    }

    /// The HTTP request that sends this message, or nil if the server address isn't a valid
    /// http or https URL.
    public var request: URLRequest? {
        guard var components = URLComponents(string: settings.server),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              components.host?.isEmpty == false
        else { return nil }
        let path = components.path.hasSuffix("/") ? components.path : components.path + "/"
        components.path = path + settings.topic
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(title, forHTTPHeaderField: "Title")
        request.setValue(tags.map(\.rawValue).joined(separator: ","), forHTTPHeaderField: "Tags")
        if let token = settings.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = Data(body.utf8)
        return request
    }
}

/// How sending an ntfy message went.
public enum NtfySendResult: Equatable, Sendable {
    case sent
    /// Not sent, with a reason a person can read, such as "the server answered 403".
    case failed(String)
}

/// How the Settings window's "Send test message" went.
public enum NtfyTestResult: Equatable, Sendable {
    /// Not sent: there's no topic to send it to.
    case needsTopic
    case sent
    /// Not sent, with a reason a person can read.
    case failed(String)

    public var succeeded: Bool { self == .sent }

    /// What the Settings window says about it.
    public var message: String {
        switch self {
        case .needsTopic: "Enter a topic first."
        case .sent: "Test message sent. Check that it arrived on your phone."
        case let .failed(reason): "Couldn't send the test message: \(reason)."
        }
    }
}

/// Values BackMeUp keeps in the Keychain. Uninstalling deletes every case.
public enum Secret: String, CaseIterable, Sendable {
    case ntfyTopic
    case ntfyToken
}
