import Foundation

public struct KickChatEvent: Decodable, Hashable, Sendable {
    public let message_id: String
    public let content: String
    public let created_at: String?
    public let sender: Participant
    public let broadcaster: Participant?
    public let replies_to: Reply?
    public let emotes: [EmoteRef]?

    public struct Participant: Decodable, Hashable, Sendable {
        public let user_id: Int?
        public let username: String
        public let is_verified: Bool?
        public let profile_picture: String?
        public let channel_slug: String?
        public let identity: Identity?
    }
    public struct Identity: Decodable, Hashable, Sendable {
        public let username_color: String?
        public let badges: [Badge]?
    }
    public struct Badge: Decodable, Hashable, Sendable {
        public let text: String
        public let type: String
        public let count: Int?
        public init(text: String, type: String, count: Int? = nil) { self.text = text; self.type = type; self.count = count }
    }
    public struct Reply: Decodable, Hashable, Sendable {
        public let message_id: String
        public let content: String?
        public let sender: Participant?
    }
    public struct EmoteRef: Decodable, Hashable, Sendable {
        public let emote_id: String
        public let positions: [Pos]
        public struct Pos: Decodable, Hashable, Sendable { public let s: Int; public let e: Int }
    }
}

public struct ChatReply: Hashable, Sendable {
    public let username: String
    public let content: String
    public init(username: String?, content: String?) {
        self.username = username ?? "?"; self.content = content ?? ""
    }

    public func segments(thirdParty: EmoteIndex = .empty, kickEmotes: Bool = true) -> [ChatSegment] {
        EmoteParser.merged([.text("@\(username): ")] + EmoteParser.parse(content, thirdParty: thirdParty, kickEmotes: kickEmotes))
    }

    public var plainText: String { ChatSegment.plainText(segments()) }
}

public struct IncomingChat: Hashable, Sendable {
    public let id: String
    public let userID: Int?
    public let username: String
    public let colorHex: String?
    public let badges: [KickChatEvent.Badge]
    public let content: String
    public let reply: ChatReply?
    public let sentAt: Date
    public var replyPreview: String? { reply?.plainText }
    public init(id: String, userID: Int?, username: String, colorHex: String?, badges: [KickChatEvent.Badge],
                content: String, reply: ChatReply?, sentAt: Date) {
        self.id = id; self.userID = userID; self.username = username; self.colorHex = colorHex
        self.badges = badges; self.content = content; self.reply = reply; self.sentAt = sentAt
    }
    public init(webhook e: KickChatEvent) {
        self.init(id: e.message_id, userID: e.sender.user_id, username: e.sender.username,
                  colorHex: e.sender.identity?.username_color, badges: e.sender.identity?.badges ?? [],
                  content: e.content,
                  reply: e.replies_to.map { ChatReply(username: $0.sender?.username, content: $0.content) },
                  sentAt: ChatMessage.parseDate(e.created_at) ?? Date())
    }
}

public enum ChatStreamEvent: Hashable, Sendable {
    case message(IncomingChat)
    case deleted(messageID: String)
    case userBanned(userID: Int?, username: String?)
    case cleared
    case system(id: String, text: String)
}

public struct ChatMessage: Identifiable, Hashable, Sendable {
    public let id: String
    public let userID: Int?
    public let username: String
    public let colorHex: String?
    public let badges: [KickChatEvent.Badge]
    public let segments: [ChatSegment]
    public let replySegments: [ChatSegment]?
    public let sentAt: Date
    public let isSystem: Bool

    public init(id: String, userID: Int? = nil, username: String, colorHex: String?, badges: [KickChatEvent.Badge],
                segments: [ChatSegment], replySegments: [ChatSegment]? = nil, sentAt: Date = Date(), isSystem: Bool = false) {
        self.id = id; self.userID = userID; self.username = username; self.colorHex = colorHex
        self.badges = badges; self.segments = segments; self.replySegments = replySegments
        self.sentAt = sentAt; self.isSystem = isSystem
    }

    public static func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    public init(_ c: IncomingChat, emotes: EmoteIndex = .empty, kickEmotes: Bool = true) {
        self.init(id: c.id, userID: c.userID, username: c.username, colorHex: c.colorHex, badges: c.badges,
                  segments: EmoteParser.parse(c.content, thirdParty: emotes, kickEmotes: kickEmotes),
                  replySegments: c.reply?.segments(thirdParty: emotes, kickEmotes: kickEmotes), sentAt: c.sentAt)
    }

    public init(event: KickChatEvent, thirdParty: EmoteIndex = .empty) {
        self.init(IncomingChat(webhook: event), emotes: thirdParty)
    }

    public static func system(id: String, text: String, at date: Date = Date()) -> ChatMessage {
        ChatMessage(id: id, username: "", colorHex: nil, badges: [], segments: [.text(text)],
                    replySegments: nil, sentAt: date, isSystem: true)
    }

    public var plainText: String { ChatSegment.plainText(segments) }

    public var replyPreview: String? { replySegments.map(ChatSegment.plainText) }
}

public enum ChatSegment: Hashable, Sendable {
    case text(String)
    case emote(name: String, url: URL, provider: EmoteProvider)
    case overlay(name: String, url: URL, provider: EmoteProvider)

    public static func plainText(_ segments: [ChatSegment]) -> String {
        segments.map { switch $0 { case .text(let t): t; case .emote(let n, _, _), .overlay(let n, _, _): n } }.joined()
    }

    public static func stacked(_ segments: [ChatSegment]) -> [ChatPiece] {
        var out: [ChatPiece] = []
        for seg in segments {
            switch seg {
            case .text(let t): out.append(.text(t))
            case .emote(let n, let u, let p): out.append(.emote(ChatEmote(name: n, url: u, provider: p), overlays: []))
            case .overlay(let n, let u, let p):
                let top = ChatEmote(name: n, url: u, provider: p)
                if case .text(let gap)? = out.last, gap.allSatisfy(\.isWhitespace), out.count > 1,
                   case .emote(let base, let overlays) = out[out.count - 2] {
                    out.removeLast()
                    out[out.count - 1] = .emote(base, overlays: overlays + [top])
                } else if case .emote(let base, let overlays)? = out.last {
                    out[out.count - 1] = .emote(base, overlays: overlays + [top])
                } else {
                    out.append(.emote(top, overlays: []))
                }
            }
        }
        return out
    }
}

public struct ChatEmote: Hashable, Sendable {
    public let name: String
    public let url: URL
    public let provider: EmoteProvider
    public init(name: String, url: URL, provider: EmoteProvider) { self.name = name; self.url = url; self.provider = provider }
}

public enum ChatPiece: Hashable, Sendable {
    case text(String)
    case emote(ChatEmote, overlays: [ChatEmote])
}

public enum EmoteProvider: String, Codable, Hashable, Sendable { case kick, sevenTV, bttv, ffz }
