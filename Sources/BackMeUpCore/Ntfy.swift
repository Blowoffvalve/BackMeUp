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

/// One message to send through ntfy: an HTTP POST of `body` to `server/topic`, with `Title` and
/// `Tags` headers and, when there's a token, `Authorization: Bearer <token>`.
public struct NtfyMessage: Equatable, Sendable {
    public var server: String
    public var topic: String
    public var token: String?
    public var title: String
    public var body: String
    /// ntfy tags. Emoji short codes such as `warning` show as an icon on the phone.
    public var tags: [String]

    public init(server: String, topic: String, token: String?, title: String, body: String, tags: [String]) {
        self.server = server
        self.topic = topic
        self.token = token
        self.title = title
        self.body = body
        self.tags = tags
    }

    /// The tag for a problem, shown on the phone as a warning sign.
    public static let warningTag = "warning"
    /// The tag for good news, shown on the phone as a check mark.
    public static let successTag = "white_check_mark"

    /// The HTTP request that sends this message, or nil if the server address isn't a valid
    /// http or https URL.
    public var request: URLRequest? {
        guard var components = URLComponents(string: server),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              components.host?.isEmpty == false
        else { return nil }
        let path = components.path.hasSuffix("/") ? components.path : components.path + "/"
        components.path = path + topic
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(title, forHTTPHeaderField: "Title")
        request.setValue(tags.joined(separator: ","), forHTTPHeaderField: "Tags")
        if let token {
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

/// Values BackMeUp keeps in the Keychain. Uninstalling deletes every case.
public enum Secret: String, CaseIterable, Sendable {
    case ntfyTopic
    case ntfyToken
}
