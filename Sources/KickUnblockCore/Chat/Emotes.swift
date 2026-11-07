import Foundation

public struct EmoteIndex: Sendable, Hashable {
    public struct Entry: Sendable, Hashable {
        public let url: URL
        public let provider: EmoteProvider
        public let overlay: Bool
        public init(url: URL, provider: EmoteProvider, overlay: Bool = false) {
            self.url = url; self.provider = provider; self.overlay = overlay
        }
    }
    public var entries: [String: Entry]
    public static let empty = EmoteIndex(entries: [:])
    public init(entries: [String: Entry]) { self.entries = entries }
    public init(byName: [String: URL], provider: EmoteProvider = .sevenTV) {
        entries = byName.mapValues { Entry(url: $0, provider: provider) }
    }
    public var byName: [String: URL] { entries.mapValues(\.url) }
    public var count: Int { entries.count }
    public func merging(_ other: EmoteIndex) -> EmoteIndex {
        EmoteIndex(entries: entries.merging(other.entries) { _, new in new })
    }
    public static func channel(_ channel: EmoteIndex, over global: EmoteIndex) -> EmoteIndex {
        global.merging(channel)
    }
}

public enum KickEmoteCDN {
    public static var urlTemplate = "https://files.kick.com/emotes/{id}/fullsize"
    public static func url(id: String) -> URL? {
        URL(string: urlTemplate.replacingOccurrences(of: "{id}", with: id))
    }
}

public enum EmoteCacheKey {
    public static func make(url: URL, provider: EmoteProvider) -> String {
        let parts = url.pathComponents.filter { $0 != "/" }
        if let i = parts.firstIndex(where: { $0 == "emote" || $0 == "emotes" }), i + 1 < parts.count {
            return "\(provider.rawValue):\(parts[i + 1])"
        }
        return "\(provider.rawValue):\(url.absoluteString)"
    }
}

public enum EmoteParser {
    public static func parse(_ content: String, thirdParty: EmoteIndex = .empty, kickEmotes: Bool = true) -> [ChatSegment] {
        var out: [ChatSegment] = []
        var buffer = ""
        func flushText() { if !buffer.isEmpty { out.append(contentsOf: splitThirdParty(buffer, thirdParty)); buffer = "" } }

        var rest = Substring(content)
        while let open = rest.range(of: "[emote:") {
            buffer += rest[rest.startIndex..<open.lowerBound]
            let afterOpen = rest[open.upperBound...]
            guard let close = afterOpen.firstIndex(of: "]") else { buffer += rest[open.lowerBound...]; rest = ""; break }
            let inner = afterOpen[afterOpen.startIndex..<close]
            let parts = inner.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2, !parts[0].isEmpty, parts[0].allSatisfy(\.isNumber), let url = KickEmoteCDN.url(id: parts[0]) {
                if kickEmotes {
                    flushText()
                    out.append(.emote(name: parts[1], url: url, provider: .kick))
                } else {
                    buffer += ":\(parts[1]):"
                }
            } else {
                buffer += rest[open.lowerBound...close]
            }
            rest = afterOpen[afterOpen.index(after: close)...]
        }
        buffer += rest
        flushText()
        return merged(out)
    }

    static func splitThirdParty(_ text: String, _ idx: EmoteIndex) -> [ChatSegment] {
        guard !idx.entries.isEmpty else { return [.text(text)] }
        var out: [ChatSegment] = []
        var current = ""
        var word = ""
        func flushWord() {
            if let e = idx.entries[word] {
                if !current.isEmpty { out.append(.text(current)); current = "" }
                out.append(e.overlay ? .overlay(name: word, url: e.url, provider: e.provider)
                                     : .emote(name: word, url: e.url, provider: e.provider))
            } else { current += word }
            word = ""
        }
        for ch in text {
            if ch == " " { flushWord(); current.append(ch) } else { word.append(ch) }
        }
        flushWord()
        if !current.isEmpty { out.append(.text(current)) }
        return out
    }

    static func merged(_ segs: [ChatSegment]) -> [ChatSegment] {
        var out: [ChatSegment] = []
        for s in segs {
            if case .text(let t) = s, case .text(let prev)? = out.last { out[out.count - 1] = .text(prev + t) }
            else { out.append(s) }
        }
        return out
    }
}

public enum SevenTV {
    public static let globalSetURL = URL(string: "https://7tv.io/v3/emote-sets/global")!
    public static func kickUserURL(kickUserID: Int) -> URL {
        URL(string: "https://7tv.io/v3/users/kick/\(kickUserID)")!
    }

    public struct EmoteSet: Decodable { public let id: String?; public let emotes: [Emote]? }
    public struct UserConnection: Decodable {
        public let emote_set_id: String?
        public let emote_set: EmoteSet?
        public let user: User?
        public struct User: Decodable { public let id: String }
    }
    public struct Emote: Decodable {
        public let name: String
        public let flags: Int?
        public let data: Data_
        public struct Data_: Decodable { public let host: Host; public let flags: Int? }
        public struct Host: Decodable { public let url: String; public let files: [File] }
        public struct File: Decodable { public let name: String }
    }

    public static func imageURL(id: String, size: String = "2x") -> URL? {
        URL(string: "https://cdn.7tv.app/emote/\(id)/\(size).webp")
    }

    public static func entry(for e: Emote, size: String = "2x") -> EmoteIndex.Entry? {
        let file = e.data.host.files.first { $0.name == "\(size).webp" } ?? e.data.host.files.first
        guard let file else { return nil }
        let base = e.data.host.url.hasPrefix("//") ? "https:" + e.data.host.url : e.data.host.url
        let overlay = (e.flags ?? 0) & 1 != 0 || (e.data.flags ?? 0) & 256 != 0
        return URL(string: "\(base)/\(file.name)").map { .init(url: $0, provider: .sevenTV, overlay: overlay) }
    }

    public static func index(from set: EmoteSet?, size: String = "2x") -> EmoteIndex {
        var map: [String: EmoteIndex.Entry] = [:]
        for e in set?.emotes ?? [] { if let x = entry(for: e, size: size) { map[e.name] = x } }
        return EmoteIndex(entries: map)
    }

    public static func channel(from c: UserConnection) -> SevenTVChannel {
        SevenTVChannel(index: index(from: c.emote_set), setID: c.emote_set_id ?? c.emote_set?.id, userID: c.user?.id)
    }
}

public enum BTTV {
    public static let globalURL = URL(string: "https://api.betterttv.net/3/cached/emotes/global")!
    public struct Emote: Decodable { public let id: String; public let code: String }
    public static func index(_ emotes: [Emote]) -> EmoteIndex {
        var m: [String: EmoteIndex.Entry] = [:]
        for e in emotes { if let u = URL(string: "https://cdn.betterttv.net/emote/\(e.id)/2x") { m[e.code] = .init(url: u, provider: .bttv) } }
        return EmoteIndex(entries: m)
    }
}

public enum FFZ {
    public static let globalURL = URL(string: "https://api.frankerfacez.com/v1/set/global")!
    public struct Global: Decodable {
        public let default_sets: [Int]
        public let sets: [String: Set_]
    }
    public struct Set_: Decodable { public let emoticons: [Emote] }
    public struct Emote: Decodable {
        public let name: String
        public let hidden: Bool?
        public let urls: [String: String]
    }
    public static func index(_ g: Global) -> EmoteIndex {
        var m: [String: EmoteIndex.Entry] = [:]
        for id in g.default_sets {
            for e in g.sets[String(id)]?.emoticons ?? [] where e.hidden != true {
                let s = e.urls["2"] ?? e.urls["1"] ?? e.urls.values.first
                if let s, let u = URL(string: s.hasPrefix("//") ? "https:" + s : s) { m[e.name] = .init(url: u, provider: .ffz) }
            }
        }
        return EmoteIndex(entries: m)
    }
}
