import Foundation

public struct VODReplayPage: Sendable {
    public let messages: [IncomingChat]
    public let cursor: String?
    public let oldestSentAt: Date?

    public init(messages: [IncomingChat], cursor: String?, oldestSentAt: Date? = nil) {
        self.messages = messages
        self.cursor = cursor
        self.oldestSentAt = oldestSentAt ?? messages.map(\.sentAt).min()
    }

    private struct Envelope: Decodable {
        let data: Payload
        struct Payload: Decodable {
            let messages: [ChatHistory.Item]
            let cursor: FlexibleID?
        }
    }

    public static func parse(_ data: Data) throws -> VODReplayPage {
        let payload = try JSONDecoder().decode(Envelope.self, from: data).data
        var messages: [IncomingChat] = []
        var oldest: Date?
        for item in payload.messages.reversed() {
            guard !item.id.isEmpty, let sentAt = KickWebDate.parse(item.created_at) else {
                throw VODReplayError.invalidTimestamp
            }
            oldest = min(oldest ?? sentAt, sentAt)
            guard let sender = item.sender, let content = item.content, !content.isEmpty else { continue }
            var reply: ChatReply?
            if item.type == "reply", let raw = item.metadata,
               let meta = try? JSONDecoder().decode(ChatHistory.Meta.self, from: Data(raw.utf8)),
               let original = meta.original_message {
                reply = ChatReply(username: meta.original_sender?.username, content: original.content)
            }
            messages.append(IncomingChat(id: item.id, userID: sender.id, username: sender.username,
                                         colorHex: sender.identity?.color, badges: sender.identity?.badges ?? [],
                                         content: content, reply: reply, sentAt: sentAt))
        }
        let sorted = messages.enumerated().sorted {
            $0.element.sentAt == $1.element.sentAt ? $0.offset < $1.offset : $0.element.sentAt < $1.element.sentAt
        }.map(\.element)
        let cursor = payload.cursor?.value
        return VODReplayPage(messages: sorted, cursor: cursor.flatMap { $0.isEmpty ? nil : $0 }, oldestSentAt: oldest)
    }
}

public enum VODReplayError: Error, Equatable, Sendable {
    case invalidTimestamp
    case invalidContext
    case cursorLoop
    case outsideWindow
    case httpStatus(Int)
    case rateLimited(retryAfter: String?)
    case unexpectedResponse
}
