import Foundation

public struct ChatEmoteSession: Sendable {
    public private(set) var index: EmoteIndex
    public private(set) var generation: UInt64 = 0
    private var globals: EmoteIndex
    private var channel: EmoteIndex?
    public init(index: EmoteIndex = .empty) { self.index = index; globals = index }

    @discardableResult
    public mutating func begin(_ globals: EmoteIndex) -> UInt64 {
        generation &+= 1
        self.globals = globals
        channel = nil
        index = globals
        return generation
    }

    public mutating func end() { generation &+= 1 }

    public mutating func accept(channel: EmoteIndex, for generation: UInt64) -> Bool {
        guard generation == self.generation else { return false }
        self.channel = channel
        return recompute()
    }

    public mutating func accept(globals: EmoteIndex, keepChannel: Bool) -> Bool {
        self.globals = globals
        if !keepChannel { channel = nil }
        return recompute()
    }

    public mutating func applyChannelChange(added: [String: EmoteIndex.Entry], removed: [String]) -> Bool {
        guard var c = channel else { return false }
        for name in removed { c.entries[name] = nil }
        c.entries.merge(added) { _, new in new }
        channel = c
        return recompute()
    }

    private mutating func recompute() -> Bool {
        let next = channel.map { EmoteIndex.channel($0, over: globals) } ?? globals
        guard next != index else { return false }
        index = next
        return true
    }

    public func hydrate(_ visible: [ChatMessage], cache: inout [String: ChatMessage]) -> [ChatMessage] {
        for (id, m) in cache { cache[id] = m.rehydrated(emotes: index) }
        return visible.map { cache[$0.id] ?? $0.rehydrated(emotes: index) }
    }
}

extension ChatMessage {
    public func rehydrated(emotes: EmoteIndex) -> ChatMessage {
        guard !isSystem else { return self }
        return ChatMessage(id: id, userID: userID, username: username, colorHex: colorHex, badges: badges,
                           segments: EmoteParser.reresolve(segments, emotes),
                           replySegments: replySegments.map { EmoteParser.reresolveReply($0, emotes) },
                           sentAt: sentAt, isSystem: isSystem)
    }
}

extension EmoteParser {
    static func reresolve(_ segments: [ChatSegment], _ idx: EmoteIndex) -> [ChatSegment] {
        var out: [ChatSegment] = []
        for s in segments {
            switch s {
            case .text(let t): out += splitThirdParty(t, idx)
            case .emote(_, _, .kick): out.append(s)
            case .emote(let name, _, _), .overlay(let name, _, _):
                out += splitThirdParty(name, idx)
            }
        }
        return merged(out)
    }

    static func reresolveReply(_ segments: [ChatSegment], _ idx: EmoteIndex) -> [ChatSegment] {
        guard case .text(let first)? = segments.first, first.hasPrefix("@"),
              let end = first.range(of: ": ")?.upperBound else { return reresolve(segments, idx) }
        let rest = String(first[end...])
        return merged([.text(String(first[..<end]))] + reresolve((rest.isEmpty ? [] : [.text(rest)]) + segments.dropFirst(), idx))
    }
}
