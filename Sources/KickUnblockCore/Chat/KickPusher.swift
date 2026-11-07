import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum KickPusher {
    public static let defaultKey = "34bf7a0ff419a2a775b9"
    public static let defaultCluster = "us2"

    public static func chatChannel(chatroomID: Int) -> String { "chatrooms.\(chatroomID).v2" }

    public static func isFatalClose(_ code: Int) -> Bool { (4000...4099).contains(code) }
    public static let appKeyNotInCluster = 4001

    public static func backoff(attempt: Int, cap: Double = 30) -> Double {
        min(cap, pow(2, Double(max(0, min(attempt, 10)))))
    }
}

public enum KickRealtimeNegotiation {
    public static func url(channelID: Int) -> URL {
        URL(string: "https://web.kick.com/api/v1/realtime/channels/\(channelID)/chat/connection")!
    }

    public static func request(channelID: Int, clientID: String, userAgent: String) -> URLRequest {
        var r = URLRequest(url: url(channelID: channelID))
        r.httpMethod = "POST"
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.httpBody = body(clientID: clientID)
        return r
    }

    public static func body(clientID: String) -> Data {
        let obj: [String: Any] = [
            "client": ["id": clientID, "type": "web"],
            "capabilities": ["accepted_providers": [["provider": "pusher"]]],
        ]
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
    }

    public struct Response: Decodable {
        public let data: Payload?
        public struct Payload: Decodable { public let connections: [Connection] }
        public struct Connection: Decodable {
            public let provider: String
            public let credentials: Credentials?
        }
        public struct Credentials: Decodable { public let app_key: String?; public let cluster: String? }
    }

    public static func pusherCredentials(from data: Data) -> (key: String, cluster: String)? {
        guard let r = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        for c in r.data?.connections ?? [] where c.provider == "pusher" {
            if let k = c.credentials?.app_key, let cl = c.credentials?.cluster, !k.isEmpty, !cl.isEmpty { return (k, cl) }
        }
        return nil
    }
}

public enum KickPusherEvents {
    public static let chatMessage = #"App\Events\ChatMessageEvent"#
    public static let messageDeleted = #"App\Events\MessageDeletedEvent"#
    public static let userBanned = #"App\Events\UserBannedEvent"#
    public static let chatroomClear = #"App\Events\ChatroomClearEvent"#
    public static let subscription = #"App\Events\SubscriptionEvent"#
    public static let giftedSubscriptions = #"App\Events\GiftedSubscriptionsEvent"#
    public static let streamHost = #"App\Events\StreamHostEvent"#

    struct Message: Decodable {
        let id: String
        let content: String
        let type: String?
        let created_at: String?
        let sender: Sender
        let metadata: Metadata?
        struct Sender: Decodable {
            let id: Int?
            let username: String
            let slug: String?
            let identity: Identity?
        }
        struct Identity: Decodable { let color: String?; let badges: [KickChatEvent.Badge]? }
        struct Metadata: Decodable {
            let original_sender: OriginalSender?
            let original_message: OriginalMessage?
        }
        struct OriginalSender: Decodable { let id: FlexibleID?; let username: String? }
        struct OriginalMessage: Decodable { let id: String?; let content: String? }
    }
    struct Deleted: Decodable { let message: Ref?; struct Ref: Decodable { let id: String } }
    struct Banned: Decodable { let user: User?; struct User: Decodable { let id: Int?; let username: String? } }
    struct Sub: Decodable { let username: String?; let months: Int? }
    struct Gift: Decodable { let gifted_usernames: [String]?; let gifter_username: String? }
    struct Host: Decodable { let host_username: String?; let number_viewers: Int? }

    public static func parse(frame text: String) -> ChatStreamEvent? {
        guard let raw = PusherFrame.decode(text), let payload = raw.data else { return nil }
        return parse(event: raw.event, data: payload)
    }

    public static func parse(event: String, data: String) -> ChatStreamEvent? {
        let d = Data(data.utf8)
        let dec = JSONDecoder()
        switch event {
        case chatMessage:
            guard let m = try? dec.decode(Message.self, from: d) else { return nil }
            var reply: ChatReply?
            if m.type == "reply", let o = m.metadata?.original_message {
                reply = ChatReply(username: m.metadata?.original_sender?.username, content: o.content)
            }
            return .message(IncomingChat(
                id: m.id, userID: m.sender.id, username: m.sender.username,
                colorHex: m.sender.identity?.color, badges: m.sender.identity?.badges ?? [],
                content: m.content, reply: reply,
                sentAt: KickWebDate.parse(m.created_at) ?? Date()))
        case messageDeleted:
            guard let x = try? dec.decode(Deleted.self, from: d), let id = x.message?.id else { return nil }
            return .deleted(messageID: id)
        case userBanned:
            let x = try? dec.decode(Banned.self, from: d)
            return .userBanned(userID: x?.user?.id, username: x?.user?.username)
        case chatroomClear:
            return .cleared
        case subscription:
            guard let x = try? dec.decode(Sub.self, from: d), let u = x.username else { return nil }
            let months = (x.months ?? 1) > 1 ? " for \(x.months!) months" : ""
            return .system(id: "sub-\(u)-\(x.months ?? 1)-\(data.hashValue)", text: "\(u) subscribed\(months)")
        case giftedSubscriptions:
            guard let x = try? dec.decode(Gift.self, from: d) else { return nil }
            let n = x.gifted_usernames?.count ?? 0
            return .system(id: "gift-\(data.hashValue)", text: "\(x.gifter_username ?? "Someone") gifted \(n) sub\(n == 1 ? "" : "s")")
        case streamHost:
            guard let x = try? dec.decode(Host.self, from: d), let h = x.host_username else { return nil }
            return .system(id: "host-\(data.hashValue)", text: "\(h) is hosting with \(x.number_viewers ?? 0) viewers")
        default:
            return nil
        }
    }
}
