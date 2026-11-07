import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct SubscriberBadge: Decodable, Hashable, Sendable {
    public let id: Int?
    public let months: Int
    public let badge_image: Image?
    public struct Image: Decodable, Hashable, Sendable {
        public let src: String?
        public let srcset: String?
    }
    public var imageURL: URL? {
        guard let s = badge_image?.src, !s.isEmpty, let u = URL(string: s), u.scheme == "https" else { return nil }
        return u
    }
    public init(id: Int? = nil, months: Int, src: String?) {
        self.id = id; self.months = months; self.badge_image = Image(src: src, srcset: nil)
    }
}

public struct SubscriberBadgeSet: Hashable, Sendable {
    public let tiers: [SubscriberBadge]
    public static let empty = SubscriberBadgeSet([])

    public init(_ badges: [SubscriberBadge]) {
        tiers = badges.filter { $0.imageURL != nil && $0.months >= 0 }.sorted { $0.months < $1.months }
    }

    public func badge(forMonths count: Int?) -> SubscriberBadge? {
        guard let first = tiers.first else { return nil }
        let n = max(count ?? 1, 1)
        return tiers.last { $0.months <= n } ?? first
    }

    struct Envelope: Decodable { let subscriber_badges: [SubscriberBadge]? }

    public static func parse(_ data: Data) -> SubscriberBadgeSet {
        guard let e = try? JSONDecoder().decode(Envelope.self, from: data) else { return .empty }
        return SubscriberBadgeSet(e.subscriber_badges ?? [])
    }

    public static func fetch(slug: String, session: URLSession = .shared,
                             userAgent: String = KickWebClient.userAgent) async -> SubscriberBadgeSet {
        let safe = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug
        guard !slug.isEmpty, let url = URL(string: "https://kick.com/api/v2/channels/\(safe)") else { return .empty }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return .empty }
        return parse(data)
    }
}

public enum ChatBadgeKind: String, CaseIterable, Sendable {
    case broadcaster, moderator, vip, og, founder, verified, subscriber
    case subGifter = "sub_gifter"
    case staff, trainwreckstv, sidekick, bot
    case other

    public init(type: String) {
        self = ChatBadgeKind(rawValue: type.lowercased()) ?? .other
    }

    public var symbol: String {
        switch self {
        case .broadcaster: "video.fill"
        case .moderator: "shield.lefthalf.filled"
        case .vip: "diamond.fill"
        case .og: "flame.fill"
        case .founder: "medal.fill"
        case .verified: "checkmark"
        case .subscriber: "star.fill"
        case .subGifter: "gift.fill"
        case .staff: "wrench.and.screwdriver.fill"
        case .trainwreckstv: "tram.fill"
        case .sidekick: "person.2.fill"
        case .bot: "cpu"
        case .other: "circle.fill"
        }
    }

    public var tileHex: String {
        switch self {
        case .broadcaster: "#E5484D"
        case .moderator: "#30A46C"
        case .vip: "#D6409F"
        case .og: "#F76B15"
        case .founder: "#E2A336"
        case .verified: "#0090FF"
        case .subscriber: "#8E4EC6"
        case .subGifter: "#6E56CF"
        case .staff: "#12A594"
        case .trainwreckstv: "#5B5BD6"
        case .sidekick: "#00A2C7"
        case .bot: "#6F6F6F"
        case .other: "#6F6F6F"
        }
    }

    public var defaultName: String {
        switch self {
        case .broadcaster: "Broadcaster"
        case .moderator: "Moderator"
        case .vip: "VIP"
        case .og: "OG"
        case .founder: "Founder"
        case .verified: "Verified"
        case .subscriber: "Subscriber"
        case .subGifter: "Sub Gifter"
        case .staff: "Staff"
        case .trainwreckstv: "Trainwreck"
        case .sidekick: "Sidekick"
        case .bot: "Bot"
        case .other: "Badge"
        }
    }
}

public enum ChatBadgeText {
    public static func describe(_ b: KickChatEvent.Badge) -> String {
        let kind = ChatBadgeKind(type: b.type)
        let name = b.text.isEmpty ? kind.defaultName : b.text
        switch kind {
        case .subscriber:
            guard let n = b.count, n > 0 else { return name }
            return "\(name), \(n) month\(n == 1 ? "" : "s")"
        case .subGifter:
            guard let n = b.count, n > 0 else { return name }
            return "\(name), \(n) gift\(n == 1 ? "" : "s")"
        default:
            return name
        }
    }

    public static func accessibility(_ badges: [KickChatEvent.Badge]) -> String? {
        badges.isEmpty ? nil : "Badges: " + badges.map(describe).joined(separator: ", ")
    }
}
