import Foundation

public struct PickerEmote: Codable, Hashable, Sendable, Identifiable {
    public let name: String
    public let kickID: Int?
    public let provider: EmoteProvider
    public let imageURL: URL?
    public let locked: Bool

    public init(name: String, kickID: Int? = nil, provider: EmoteProvider, imageURL: URL? = nil, locked: Bool = false) {
        self.name = name; self.kickID = kickID; self.provider = provider; self.imageURL = imageURL; self.locked = locked
    }

    public var id: String { "\(provider.rawValue):\(kickID.map(String.init) ?? name)" }

    public var chatText: String {
        if provider == .kick, let kickID { return "[emote:\(kickID):\(name)]" }
        return name
    }

    public var displayURL: URL? {
        if provider == .kick, let kickID { return KickEmoteCDN.url(id: String(kickID)) }
        return imageURL
    }

    public static func insert(_ e: PickerEmote, into draft: String) -> String {
        guard !draft.isEmpty else { return e.chatText + " " }
        let sep = draft.hasSuffix(" ") ? "" : " "
        return draft + sep + e.chatText + " "
    }
}

public struct RecentEmotes: Codable, Hashable, Sendable {
    public static let capacity = 24
    public static let quickCount = 8
    public private(set) var items: [PickerEmote]

    public init(items: [PickerEmote] = []) { self.items = Array(items.prefix(Self.capacity)) }

    public var quick: [PickerEmote] { Array(items.prefix(Self.quickCount)) }

    public mutating func record(_ e: PickerEmote) {
        guard !e.locked else { return }
        items.removeAll { $0.id == e.id }
        items.insert(e, at: 0)
        if items.count > Self.capacity { items.removeLast(items.count - Self.capacity) }
    }

    public static func load(_ d: UserDefaults = .standard) -> RecentEmotes {
        guard let data = d.data(forKey: PrefKey.recentEmotes),
              let r = try? JSONDecoder().decode(RecentEmotes.self, from: data) else { return RecentEmotes() }
        return r
    }

    public func save(_ d: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { d.set(data, forKey: PrefKey.recentEmotes) }
    }
}

public struct KickEmoteSets: Sendable, Hashable {
    public let channel: [PickerEmote]
    public let global: [PickerEmote]

    struct RawSet: Decodable {
        let id: FlexibleID?
        let slug: String?
        let emotes: [RawEmote]?
    }
    struct RawEmote: Decodable {
        let id: Int
        let name: String
        let subscribers_only: LenientBool?
    }

    public init(channel: [PickerEmote] = [], global: [PickerEmote] = []) { self.channel = channel; self.global = global }

    public static func parse(_ data: Data, isSubscriber: Bool = false) -> KickEmoteSets? {
        guard let sets = try? JSONDecoder().decode([RawSet].self, from: data) else { return nil }
        var channel: [PickerEmote] = [], global: [PickerEmote] = []
        for s in sets {
            let shared = ["Global", "Emoji"].contains(s.id?.value ?? "")
            for e in s.emotes ?? [] {
                let locked = !shared && (e.subscribers_only?.value ?? false) && !isSubscriber
                let p = PickerEmote(name: e.name, kickID: e.id, provider: .kick, locked: locked)
                if shared { global.append(p) } else { channel.append(p) }
            }
        }
        return KickEmoteSets(channel: channel, global: global)
    }
}

extension EmoteIndex {
    public func pickerEmotes(provider: EmoteProvider) -> [PickerEmote] {
        entries.filter { $0.value.provider == provider }
            .map { PickerEmote(name: $0.key, provider: provider, imageURL: $0.value.url) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
