import Foundation

public struct VODReplayWindow: Sendable {
    public let lowerBound: TimeInterval
    public let upperBound: TimeInterval
    public let messages: [IncomingChat]
    public let isPartial: Bool
    public init(lowerBound: TimeInterval, upperBound: TimeInterval, messages: [IncomingChat], isPartial: Bool) {
        self.lowerBound = lowerBound; self.upperBound = upperBound
        self.messages = messages; self.isPartial = isPartial
    }
}

public struct VODReplayClient: Sendable {
    public typealias FetchPage = @Sendable (Int, String) async throws -> VODReplayPage
    private let fetchPage: FetchPage
    public init(fetchPage: @escaping FetchPage) { self.fetchPage = fetchPage }

    public func load(context: VODReplayContext, from lower: TimeInterval, through upper: TimeInterval,
                     maxPages: Int = 6, maxMessages: Int = 300) async throws -> VODReplayWindow {
        let lower = try context.clamped(lower), upper = try context.clamped(upper)
        guard lower <= upper else { throw VODReplayError.invalidTimestamp }
        let pageLimit = min(6, max(1, maxPages)), messageLimit = min(300, max(1, maxMessages))
        var cursor = try context.cursor(at: upper)
        var seen = Set<String>(), ids = Set<String>(), messages: [IncomingChat] = []
        var partial = true
        let firstDate = context.startedAt.addingTimeInterval(lower)
        let lastDate = context.startedAt.addingTimeInterval(upper)
        for _ in 0..<pageLimit {
            try Task.checkCancellation()
            guard seen.insert(cursor).inserted else { throw VODReplayError.cursorLoop }
            let page = try await fetchPage(context.channelID, cursor)
            try Task.checkCancellation()
            guard page.messages.allSatisfy({ $0.sentAt <= lastDate }), page.oldestSentAt.map({ $0 <= lastDate }) ?? true else { throw VODReplayError.outsideWindow }
            for message in page.messages where message.sentAt >= firstDate && ids.insert(message.id).inserted {
                messages.append(message)
            }
            messages.sort { $0.sentAt == $1.sentAt ? $0.id < $1.id : $0.sentAt < $1.sentAt }
            if messages.count > messageLimit { messages = Array(messages.suffix(messageLimit)); break }
            if page.oldestSentAt.map({ $0 <= firstDate }) ?? true || page.cursor == nil {
                partial = false; break
            }
            guard let next = page.cursor else { break }
            cursor = next
        }
        return VODReplayWindow(lowerBound: lower, upperBound: upper, messages: messages, isPartial: partial)
    }
}
