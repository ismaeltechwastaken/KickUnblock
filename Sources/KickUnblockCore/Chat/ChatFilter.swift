import Foundation

public struct ChatFilterSettings: Equatable, Sendable {
    public var hideCommands: Bool
    public var hideSystemBanners: Bool
    public var dedupe: Bool
    public var dedupeWindow: TimeInterval
    public var blockedTerms: [String]
    public var blockedUsers: Set<String>
    public init(hideCommands: Bool = false, hideSystemBanners: Bool = false, dedupe: Bool = true, dedupeWindow: TimeInterval = 30,
                blockedTerms: [String] = [], blockedUsers: Set<String> = []) {
        self.hideCommands = hideCommands; self.hideSystemBanners = hideSystemBanners
        self.dedupe = dedupe; self.dedupeWindow = dedupeWindow
        self.blockedTerms = blockedTerms.compactMap(ChatBlockList.term)
        self.blockedUsers = Set(blockedUsers.compactMap(ChatBlockList.user))
    }
}

public struct ChatFilter: Sendable {
    public var settings: ChatFilterSettings
    private var recent: [String: Date] = [:]
    public init(settings: ChatFilterSettings) { self.settings = settings }

    public static func normalize(_ s: String) -> String {
        s.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    public static func isCommand(_ s: String) -> Bool {
        s.trimmingCharacters(in: .whitespaces).hasPrefix("!")
    }

    public func blocks(_ m: ChatMessage) -> Bool {
        guard !m.isSystem else { return false }
        if settings.blockedUsers.contains(m.username.lowercased()) { return true }
        guard !settings.blockedTerms.isEmpty else { return false }
        let text = ChatFilter.normalize(m.plainText)
        return settings.blockedTerms.contains { ChatBlockList.contains(text, term: $0) }
    }

    public mutating func allows(_ m: ChatMessage, now: Date = Date()) -> Bool {
        if m.isSystem { return !settings.hideSystemBanners }
        if blocks(m) { return false }
        let text = m.plainText
        if settings.hideCommands, Self.isCommand(text) { return false }
        guard settings.dedupe else { return true }
        let key = "\(m.userID.map(String.init) ?? m.username.lowercased())|\(Self.normalize(text))"
        if recent.count > 2000 { recent = recent.filter { abs(now.timeIntervalSince($0.value)) < settings.dedupeWindow } }
        if let t = recent[key], abs(now.timeIntervalSince(t)) < settings.dedupeWindow { return false }
        recent[key] = now
        return true
    }
}

public enum ChatBlockList {
    public static func term(_ raw: String) -> String? {
        let t = ChatFilter.normalize(raw)
        return t.isEmpty ? nil : t
    }

    public static func user(_ raw: String) -> String? {
        var u = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if u.hasPrefix("@") { u.removeFirst() }
        return u.isEmpty || u.contains(where: \.isWhitespace) ? nil : u
    }

    public static func adding(_ value: String?, to list: [String]) -> [String] {
        guard let value, !list.contains(value) else { return list }
        return list + [value]
    }

    public static func contains(_ text: String, term: String) -> Bool {
        guard let first = term.first, let last = term.last else { return false }
        let checkBefore = isWordCharacter(first), checkAfter = isWordCharacter(last)
        var search = text.startIndex..<text.endIndex
        while let r = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: search) {
            let before = r.lowerBound > text.startIndex ? text[text.index(before: r.lowerBound)] : nil
            let after = r.upperBound < text.endIndex ? text[r.upperBound] : nil
            if !(checkBefore && before.map(isWordCharacter) == true) && !(checkAfter && after.map(isWordCharacter) == true) { return true }
            search = text.index(after: r.lowerBound)..<text.endIndex
        }
        return false
    }

    static func isWordCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
}
