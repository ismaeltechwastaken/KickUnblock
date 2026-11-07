import Foundation

public struct WebCookie: Equatable, Sendable {
    public let name: String
    public let value: String
    public let domain: String
    public init(name: String, value: String, domain: String) { self.name = name; self.value = value; self.domain = domain }
}

public enum KickSessionCookies {
    public static let allowedNames: Set<String> = ["session_token", "XSRF-TOKEN", "kick_session"]
    public static func isChallengeCookie(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.hasPrefix("cf_") || n.hasPrefix("__cf") || n.hasPrefix("_cf") || n.contains("clearance") || n.hasPrefix("__ddg")
    }

    public static func isKickDomain(_ domain: String) -> Bool {
        let d = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return d == "kick.com" || d.hasSuffix(".kick.com")
    }

    public static func filter(_ cookies: [WebCookie]) -> [WebCookie] {
        cookies.filter { isKickDomain($0.domain) && allowedNames.contains($0.name) && !isChallengeCookie($0.name) && !$0.value.isEmpty }
    }

    public static func isSignedIn(_ cookies: [WebCookie]) -> Bool {
        filter(cookies).contains { $0.name == "session_token" }
    }

    public static func headers(_ cookies: [WebCookie]) -> [String: String] {
        let mine = filter(cookies)
        guard !mine.isEmpty else { return [:] }
        var h = ["Cookie": mine.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")]
        if let x = mine.first(where: { $0.name == "XSRF-TOKEN" }) { h["X-XSRF-TOKEN"] = x.value.removingPercentEncoding ?? x.value }
        if let s = mine.first(where: { $0.name == "session_token" }) { h["Authorization"] = "Bearer \(s.value.removingPercentEncoding ?? s.value)" }
        return h
    }
}

public enum KickAccountEndpoint: Sendable {
    case sendMessage(chatroomID: Int)
    case followed(cursor: String?)
    case dropsCampaigns
    case dropsProgress

    public var url: URL {
        switch self {
        case .sendMessage(let id): return URL(string: "https://kick.com/api/v2/messages/send/\(id)")!
        case .followed(let cursor):
            var c = URLComponents(string: "https://kick.com/api/v2/channels/followed")!
            if let cursor { c.queryItems = [URLQueryItem(name: "cursor", value: cursor)] }
            return c.url!
        case .dropsCampaigns: return URL(string: "https://web.kick.com/api/v1/drops/campaigns")!
        case .dropsProgress: return URL(string: "https://web.kick.com/api/v1/drops/progress")!
        }
    }
    public var method: String { if case .sendMessage = self { return "POST" }; return "GET" }

    public static let loginPage = URL(string: "https://kick.com/login")!
    public static let dropsPage = URL(string: "https://kick.com/drops")!
    public static let chatSettingsPage = URL(string: "https://kick.com/settings/profile")!
    public static func channelPage(_ slug: String) -> URL { URL(string: "https://kick.com/\(slug)")! }
}

public enum KickAccountError: Error, Equatable, LocalizedError {
    case notSignedIn
    case challenge(status: Int, url: URL)
    case refused(status: Int, message: String?)
    case decoding
    case csrfMismatch

    public var errorDescription: String? {
        switch self {
        case .notSignedIn: "Sign in under Tweaks › Kick Account to continue."
        case .csrfMismatch: "Kick rejected your CSRF token (HTTP 419). Open kick.com in the sign-in sheet to refresh it. Then try again."
        case .challenge(let s, _): "kick.com answered with a web page (HTTP \(s)) instead of data. Open it in the web view to continue."
        case .refused(let s, let m): m.map { "Kick refused the request (HTTP \(s)). \($0)" } ?? "Kick refused the request (HTTP \(s))."
        case .decoding: "Kick's response had an unexpected format."
        }
    }
    public var webViewURL: URL? { if case .challenge(_, let u) = self { return u }; return nil }
}

public enum KickAccountResponse {
    public static func check(status: Int, contentType: String?, body: Data, url: URL) throws {
        let ct = (contentType ?? "").lowercased()
        let head = String(decoding: body.prefix(64), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ct.contains("text/html") || head.hasPrefix("<!doctype") || head.hasPrefix("<html") {
            throw KickAccountError.challenge(status: status, url: url)
        }
        let json = try? JSONSerialization.jsonObject(with: body)
        let object = json as? [String: Any]
        let envelope = object?["status"] as? [String: Any]
        let envelopeMessage = nonEmpty(envelope?["message"] as? String)
        if (200..<300).contains(status) {
            guard json != nil else { throw KickAccountError.decoding }
            if envelope?["error"] as? Bool == true {
                throw KickAccountError.refused(status: (envelope?["code"] as? Int) ?? status, message: envelopeMessage)
            }
            return
        }
        let validation = (object?["errors"] as? [String: Any]).flatMap { errors in
            errors.keys.sorted().lazy.compactMap { k in nonEmpty((errors[k] as? [String])?.first ?? errors[k] as? String) }.first
        }
        let message = validation ?? envelopeMessage ?? nonEmpty(object?["message"] as? String)
        if status == 401 { throw KickAccountError.notSignedIn }
        if status == 419 { throw KickAccountError.csrfMismatch }
        if status == 403, (message ?? "").lowercased().contains("not authenticated") { throw KickAccountError.notSignedIn }
        throw KickAccountError.refused(status: status, message: message)
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}

public struct KickWebSendMessage: Encodable, Equatable {
    public let content: String
    public let type = "message"
    public init(content: String) { self.content = String(content.prefix(500)) }
}

public enum FollowedChannelsParser {
    public static func parse(_ data: Data) -> (channels: [FollowedChannel], nextCursor: String?) {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return ([], nil) }
        var list: [[String: Any]] = []
        var cursor: String?
        if let a = root as? [[String: Any]] { list = a }
        else if let o = root as? [String: Any] {
            list = (o["channels"] as? [[String: Any]]) ?? (o["data"] as? [[String: Any]]) ?? []
            for k in ["nextCursor", "next_cursor", "cursor"] {
                if let s = o[k] as? String, !s.isEmpty { cursor = s }
                else if let i = o[k] as? Int { cursor = String(i) }
            }
        }
        let channels: [FollowedChannel] = list.compactMap { c in
            let channel = c["channel"] as? [String: Any]
            let user = (c["user"] as? [String: Any]) ?? (channel?["user"] as? [String: Any])
            guard let slug = (c["channel_slug"] as? String) ?? (c["slug"] as? String) ?? (channel?["slug"] as? String),
                  !slug.isEmpty else { return nil }
            let name = (c["user_username"] as? String) ?? (c["username"] as? String) ?? (user?["username"] as? String) ?? slug
            let avatar = (c["profile_picture"] as? String) ?? (user?["profile_pic"] as? String) ?? (user?["profile_picture"] as? String)
            let uid = (c["user_id"] as? Int) ?? (channel?["user_id"] as? Int) ?? (user?["id"] as? Int)
            return FollowedChannel(slug: slug, broadcasterUserID: uid, displayName: name, avatarURL: avatar)
        }
        return (channels, channels.isEmpty ? nil : cursor)
    }
}

// MARK: Drops

public struct DropsCampaignList: Decodable, Sendable { public let data: [DropsCampaign] }

public struct DropsCampaign: Decodable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let status: String?
    public let ends_at: String?
    public let connect_url: String?
    public let url: String?
    public let category: Category?
    public let organization: Organization?
    public let rewards: [Reward]?
    public let channels: [Channel]?
    public let rule: Rule?

    public struct Category: Decodable, Hashable, Sendable { public let name: String?; public let slug: String?; public let image_url: String? }
    public struct Organization: Decodable, Hashable, Sendable { public let name: String?; public let logo_url: String? }
    public struct Rule: Decodable, Hashable, Sendable { public let name: String? }
    public struct Channel: Decodable, Hashable, Sendable { public let slug: String?; public let user: User?
        public struct User: Decodable, Hashable, Sendable { public let username: String?; public let profile_picture: String? } }
    public struct Reward: Decodable, Hashable, Sendable, Identifiable {
        public let id: String
        public let name: String?
        public let image_url: String?
        public let required_units: Int?
        public var imageURL: URL? { ImageURLSanitizer.url(from: image_url, base: URL(string: "https://ext.kick.com/")!) }
    }

    public var isActive: Bool { status == "active" }
}

public struct DropsProgress: Equatable, Sendable {
    public struct Item: Equatable, Sendable { public var units: Int; public var claimed: Bool
        public init(units: Int, claimed: Bool) { self.units = units; self.claimed = claimed } }
    public var byReward: [String: Item] = [:]
    public init(byReward: [String: Item] = [:]) { self.byReward = byReward }

    public static func parse(_ data: Data) -> DropsProgress {
        var p = DropsProgress()
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return p }
        func walk(_ any: Any) {
            if let a = any as? [Any] { a.forEach(walk); return }
            guard let o = any as? [String: Any] else { return }
            if let id = o["id"] as? String ?? o["reward_id"] as? String,
               let units = (o["progress_units"] ?? o["current_units"] ?? o["units"] ?? o["progress"]) as? Int {
                let claimed = (o["claimed"] as? Bool) ?? ((o["status"] as? String) == "claimed")
                p.byReward[id] = Item(units: units, claimed: claimed)
            }
            o.values.forEach(walk)
        }
        walk(root)
        return p
    }
}

public enum KickLoginAssist {
    public static let loginSelector = #"[data-testid="login"], button[aria-label*="Log In"], a[href*="login"]"#

    public static let openLoginFormScript: String = """
        (function () {
          if (window.__kuLoginAssist) { return; }
          window.__kuLoginAssist = true;
          var SELECTOR = '[data-testid="login"], button[aria-label*="Log In"], a[href*="login"]';
          var DEADLINE = Date.now() + 10000;
          var lastClick = 0;
          var clicks = 0;
          var observer = null;
          function formOpen() {
            return !!document.querySelector('input[name="password"], input[type="password"]');
          }
          function hydrated(el) {
            return Object.keys(el).some(function (k) { return k.indexOf('__react') === 0; });
          }
          function visible(el) {
            var r = el.getBoundingClientRect();
            return r.width > 0 && r.height > 0;
          }
          function stop() {
            if (observer) { observer.disconnect(); observer = null; }
            clearInterval(timer);
          }
          function attempt() {
            if (formOpen() || Date.now() > DEADLINE || clicks >= 5) { stop(); return; }
            if (Date.now() - lastClick < 1200) { return; }
            var els = Array.prototype.slice.call(document.querySelectorAll(SELECTOR));
            var el = els.filter(function (e) { return visible(e) && hydrated(e); })[0];
            if (!el) { return; }
            lastClick = Date.now();
            clicks += 1;
            el.click();
          }
          var timer = setInterval(attempt, 300);
          if (window.MutationObserver && document.body) {
            observer = new MutationObserver(attempt);
            observer.observe(document.body, { childList: true, subtree: true });
          }
          attempt();
        })();
        """

    public static let pollInterval: TimeInterval = 1
}
