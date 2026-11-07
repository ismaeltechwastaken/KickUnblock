import Foundation

public struct KickIdentity: Equatable, Sendable {
    public let id: Int
    public let username: String
    public init(id: Int, username: String) { self.id = id; self.username = username }

    public var displayName: String { username }

    public static func parse(_ data: Data) -> KickIdentity? {
        guard let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any] else { return nil }
        for candidate in [root, root["user"] as? [String: Any], root["data"] as? [String: Any]] {
            guard let o = candidate else { continue }
            let id = (o["id"] as? Int) ?? (o["id"] as? String).flatMap { Int($0) }
            let name = (o["username"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let id, id > 0, !name.isEmpty { return KickIdentity(id: id, username: name) }
        }
        return nil
    }
}

public enum KickAccountRequest {
    public static let origin = "https://kick.com"
    public static let identityURL = URL(string: "https://kick.com/api/v1/user")!

    public static func build(_ url: URL, method: String = "GET", body: Data? = nil, cookies: [WebCookie],
                             userAgent: String, referer: URL? = nil) throws -> URLRequest {
        guard KickSessionCookies.isSignedIn(cookies) else { throw KickAccountError.notSignedIn }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.httpShouldHandleCookies = false
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue(origin, forHTTPHeaderField: "Origin")
        r.setValue((referer ?? URL(string: origin + "/")!).absoluteString, forHTTPHeaderField: "Referer")
        for (k, v) in KickSessionCookies.headers(cookies) { r.setValue(v, forHTTPHeaderField: k) }
        if let body { r.httpBody = body; r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return r
    }

    public static func sendMessage(_ text: String, chatroomID: Int, channelSlug: String?, cookies: [WebCookie],
                                   userAgent: String) throws -> URLRequest {
        let body = try JSONEncoder().encode(KickWebSendMessage(content: text))
        let referer = channelSlug.flatMap { s -> URL? in
            guard let enc = s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), !enc.isEmpty else { return nil }
            return URL(string: "\(origin)/\(enc)")
        }
        return try build(KickAccountEndpoint.sendMessage(chatroomID: chatroomID).url, method: "POST", body: body,
                         cookies: cookies, userAgent: userAgent, referer: referer)
    }
}

public enum KickLoginNavigation {
    public enum Provider: String, Equatable, Sendable {
        case google, apple
        public var guidance: String {
            let name = self == .google ? "Google" : "Apple"
            return "\(name) blocks sign-in in this view. Signing in with \(name) in Safari or Kick's app won't sign you in here. Use your Kick email or username and password here. Only use \(name)? Choose “Forgot password” on Kick's login form. Enter your account email to set a password."
        }
    }

    public enum Decision: Equatable, Sendable {
        case allow
        case cancel
        case blockedProvider(Provider)
    }

    public static func decide(_ url: URL, isMainFrame: Bool) -> Decision {
        let scheme = url.scheme?.lowercased() ?? ""
        if ["about", "blob", "data"].contains(scheme) { return .allow }
        guard scheme == "https" || scheme == "http" else { return .cancel }
        guard isMainFrame else { return .allow }
        let host = url.host?.lowercased() ?? ""
        if host == "accounts.google.com" || host.hasSuffix(".accounts.google.com") { return .blockedProvider(.google) }
        if host == "appleid.apple.com" { return .blockedProvider(.apple) }
        if KickSessionCookies.isKickDomain(host) {
            let parts = url.path.lowercased().split(separator: "/").map(String.init)
            let socialFlow = parts.contains { ["redirect", "auth", "oauth", "login", "social", "callback"].contains($0) }
            if socialFlow, parts.contains("google") { return .blockedProvider(.google) }
            if socialFlow, parts.contains("apple") { return .blockedProvider(.apple) }
        }
        return .allow
    }

    public static func shouldAutoDismiss(isLoginSheet: Bool, isSignedIn: Bool) -> Bool { isLoginSheet && isSignedIn }
}
