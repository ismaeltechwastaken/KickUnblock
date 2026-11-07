import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ChatHistory {
    public static let targetCount = 50

    public static func url(channelID: Int, cursor: String? = nil) -> URL {
        var c = URLComponents(string: "https://kick.com/api/v2/channels/\(channelID)/messages")!
        if let cursor, !cursor.isEmpty { c.queryItems = [URLQueryItem(name: "cursor", value: cursor)] }
        return c.url!
    }

    public struct Page: Sendable {
        public let messages: [IncomingChat]
        public let cursor: String?
    }

    struct Envelope: Decodable {
        let data: Payload?
        struct Payload: Decodable {
            let messages: [Item]?
            let cursor: FlexibleID?
        }
    }

    struct Item: Decodable {
        let id: String
        let content: String?
        let type: String?
        let metadata: String?
        let created_at: String?
        let sender: KickPusherEvents.Message.Sender?
    }

    struct Meta: Decodable {
        let original_sender: Sender?
        let original_message: Original?
        struct Sender: Decodable { let username: String? }
        struct Original: Decodable { let content: String? }
    }

    public static func parse(_ data: Data) -> Page? {
        guard let env = try? JSONDecoder().decode(Envelope.self, from: data), let p = env.data else { return nil }
        let items = (p.messages ?? []).compactMap { m -> IncomingChat? in
            guard let s = m.sender, let text = m.content, !text.isEmpty else { return nil }
            var reply: ChatReply?
            if m.type == "reply", let raw = m.metadata,
               let meta = try? JSONDecoder().decode(Meta.self, from: Data(raw.utf8)), let o = meta.original_message {
                reply = ChatReply(username: meta.original_sender?.username, content: o.content)
            }
            return IncomingChat(id: m.id, userID: s.id, username: s.username, colorHex: s.identity?.color,
                                badges: s.identity?.badges ?? [], content: text, reply: reply,
                                sentAt: KickWebDate.parse(m.created_at) ?? Date(timeIntervalSince1970: 0))
        }
        let cursor = p.cursor?.value
        return Page(messages: items.sorted { $0.sentAt < $1.sentAt }, cursor: (cursor?.isEmpty ?? true) ? nil : cursor)
    }

    public static func fetchRecent(channelID: Int, limit: Int = targetCount,
                                   session: URLSession = .shared,
                                   userAgent: String = KickWebClient.userAgent) async -> [IncomingChat] {
        var pages: [[IncomingChat]] = []
        var cursor: String?
        var count = 0
        for _ in 0..<4 where count < limit {
            var req = URLRequest(url: url(channelID: channelID, cursor: cursor), timeoutInterval: 8)
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            guard let (data, resp) = try? await session.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let page = parse(data) else { break }
            pages.append(page.messages)
            count += page.messages.count
            guard let next = page.cursor, next != cursor, !page.messages.isEmpty else { break }
            cursor = next
        }
        return merge(pages, limit: limit)
    }

    public static func merge(_ pages: [[IncomingChat]], limit: Int = targetCount) -> [IncomingChat] {
        var seen = Set<String>()
        let all = pages.flatMap { $0 }.sorted { $0.sentAt < $1.sentAt }.filter { seen.insert($0.id).inserted }
        return Array(all.suffix(limit))
    }
}

public enum ChatTimeline {
    public static func merge(existing: [ChatMessage], history: [ChatMessage], limit: Int) -> [ChatMessage] {
        var out = existing
        var ids = Set(existing.map(\.id))
        for m in history.sorted(by: { $0.sentAt < $1.sentAt }) where ids.insert(m.id).inserted {
            let i = out.firstIndex { $0.sentAt > m.sentAt } ?? out.endIndex
            out.insert(m, at: i)
        }
        return out.count > limit ? Array(out.suffix(limit)) : out
    }
}

public struct MessageDeduper: Sendable {
    public let capacity: Int
    private var order: [String] = []
    private var seen: Set<String> = []
    public init(capacity: Int = 2000) { self.capacity = max(1, capacity) }

    public mutating func insert(_ id: String) -> Bool {
        guard seen.insert(id).inserted else { return false }
        order.append(id)
        if order.count > capacity {
            let drop = order.count - capacity
            for old in order.prefix(drop) { seen.remove(old) }
            order.removeFirst(drop)
        }
        return true
    }

    public func contains(_ id: String) -> Bool { seen.contains(id) }
    public mutating func reset() { order = []; seen = [] }
}
