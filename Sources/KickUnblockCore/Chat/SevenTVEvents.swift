import Foundation

public struct SevenTVChannel: Sendable, Hashable {
    public let index: EmoteIndex
    public let setID: String?
    public let userID: String?
    public static let empty = SevenTVChannel(index: .empty)
    public init(index: EmoteIndex, setID: String? = nil, userID: String? = nil) {
        self.index = index; self.setID = setID; self.userID = userID
    }
}

// MARK: - Cosmetics

public struct SevenTVBadge: Hashable, Sendable {
    public let id: String
    public let tooltip: String
    public let url: URL
    public init(id: String, tooltip: String, url: URL) { self.id = id; self.tooltip = tooltip; self.url = url }
}

public struct SevenTVPaint: Hashable, Sendable {
    public enum Function: String, Sendable { case linear = "LINEAR_GRADIENT", radial = "RADIAL_GRADIENT", image = "URL" }
    public struct Stop: Hashable, Sendable {
        public let at: Double
        public let color: UInt32
        public init(at: Double, color: UInt32) { self.at = at; self.color = color }
    }
    public let id: String
    public let name: String
    public let function: Function
    public let angle: Double
    public let repeats: Bool
    public let stops: [Stop]
    public let color: UInt32?
    public init(id: String, name: String, function: Function, angle: Double, repeats: Bool, stops: [Stop], color: UInt32?) {
        self.id = id; self.name = name; self.function = function; self.angle = angle
        self.repeats = repeats; self.stops = stops.sorted { $0.at < $1.at }; self.color = color
    }

    public func nameColors(count n: Int) -> [String]? {
        guard n > 0 else { return [] }
        guard function != .image, !stops.isEmpty else { return color.map { Array(repeating: Self.readable($0), count: n) } }
        let tilt = sin(angle * .pi / 180)
        return (0..<n).map { i in
            let x = n == 1 ? 0.5 : Double(i) / Double(n - 1)
            var t = function == .radial ? abs(x - 0.5) * 2 : 0.5 + (x - 0.5) * tilt
            if repeats, let last = stops.last?.at, last > 0, last < 1 { t = t.truncatingRemainder(dividingBy: last) }
            return Self.readable(sample(t))
        }
    }

    func sample(_ t: Double) -> UInt32 {
        guard let first = stops.first, let last = stops.last else { return color ?? .max }
        if t <= first.at { return first.color }
        for (a, b) in zip(stops, stops.dropFirst()) where t <= b.at {
            return Self.mix(a.color, b.color, b.at > a.at ? (t - a.at) / (b.at - a.at) : 1)
        }
        return last.color
    }

    static func mix(_ a: UInt32, _ b: UInt32, _ f: Double) -> UInt32 {
        var out: UInt32 = 0
        for shift: UInt32 in [24, 16, 8, 0] {
            let x = Double((a >> shift) & 0xFF), y = Double((b >> shift) & 0xFF)
            out |= UInt32((x + (y - x) * f).rounded()) << shift
        }
        return out
    }

    static func readable(_ rgba: UInt32) -> String {
        func ch(_ shift: UInt32) -> Double { Double((rgba >> shift) & 0xFF) / 255 }
        return Contrast.readableOnDark(HexColor.string((ch(24), ch(16), ch(8))))
    }
}

public enum SevenTVCosmetic: Hashable, Sendable { case badge(SevenTVBadge), paint(SevenTVPaint) }

public struct SevenTVEntitlement: Hashable, Sendable {
    public enum Kind: String, Sendable { case badge = "BADGE", paint = "PAINT" }
    public let kind: Kind
    public let refID: String
    public let kickUserIDs: [Int]
    public init(kind: Kind, refID: String, kickUserIDs: [Int]) { self.kind = kind; self.refID = refID; self.kickUserIDs = kickUserIDs }
}

public struct ChatUserStyle: Hashable, Sendable {
    public let badge: SevenTVBadge?
    public let paint: SevenTVPaint?
}

public struct SevenTVCosmeticsStore: Equatable, Sendable {
    private var badges: [String: SevenTVBadge] = [:]
    private var paints: [String: SevenTVPaint] = [:]
    private var userBadge: [Int: String] = [:]
    private var userPaint: [Int: String] = [:]
    public init() {}

    @discardableResult
    public mutating func apply(_ event: SevenTVEvent) -> Bool {
        switch event {
        case .cosmetic(.badge(let b)):
            guard badges[b.id] != b else { return false }
            badges[b.id] = b
            return true
        case .cosmetic(.paint(let p)):
            guard paints[p.id] != p else { return false }
            paints[p.id] = p
            return true
        case .entitlement(let e, let granted):
            var changed = false
            for uid in e.kickUserIDs {
                switch e.kind {
                case .badge: changed = Self.assign(&userBadge, uid, e.refID, granted) || changed
                case .paint: changed = Self.assign(&userPaint, uid, e.refID, granted) || changed
                }
            }
            return changed
        case .emoteSetChanged, .activeSetChanged:
            return false
        }
    }

    private static func assign(_ map: inout [Int: String], _ uid: Int, _ ref: String, _ granted: Bool) -> Bool {
        if granted {
            guard map[uid] != ref else { return false }
            map[uid] = ref
        } else {
            guard map[uid] == ref else { return false }
            map[uid] = nil
        }
        return true
    }

    public func style(for kickUserID: Int?) -> ChatUserStyle? {
        guard let id = kickUserID else { return nil }
        let badge = userBadge[id].flatMap { badges[$0] }
        let paint = userPaint[id].flatMap { paints[$0] }
        return badge == nil && paint == nil ? nil : ChatUserStyle(badge: badge, paint: paint)
    }
}

// MARK: - Events

public enum SevenTVEvent: Hashable, Sendable {
    case emoteSetChanged(setID: String, added: [String: EmoteIndex.Entry], removed: [String])
    case activeSetChanged(userID: String)
    case entitlement(SevenTVEntitlement, granted: Bool)
    case cosmetic(SevenTVCosmetic)
}

public enum SevenTVEventFrame: Hashable, Sendable {
    case hello(heartbeat: TimeInterval)
    case heartbeat
    case dispatch(SevenTVEvent)
    case reconnect
    case endOfStream(code: Int)
    case ignored
}

public struct SevenTVSubscription: Hashable, Sendable {
    public let type: String
    public let condition: [String: String]
    public init(type: String, condition: [String: String]) { self.type = type; self.condition = condition }

    public static func emoteSet(_ id: String) -> SevenTVSubscription { .init(type: "emote_set.update", condition: ["object_id": id]) }
    public static func user(_ id: String) -> SevenTVSubscription { .init(type: "user.update", condition: ["object_id": id]) }
    public static func cosmetics(kickUserID: Int) -> [SevenTVSubscription] {
        let c = ["ctx": "channel", "platform": "KICK", "id": String(kickUserID)]
        return [.init(type: "entitlement.*", condition: c), .init(type: "cosmetic.*", condition: c)]
    }
}

@MainActor
public protocol SevenTVEventStream: AnyObject {
    var onEvent: ((SevenTVEvent) -> Void)? { get set }
    func update(_ subscriptions: Set<SevenTVSubscription>)
    func stop()
}

public enum SevenTVEventAPI {
    public static let url = URL(string: "wss://events.7tv.io/v3")!

    public static func subscribe(_ s: SevenTVSubscription) -> String { frame(op: 35, s) }
    public static func unsubscribe(_ s: SevenTVSubscription) -> String { frame(op: 36, s) }

    private static func frame(op: Int, _ s: SevenTVSubscription) -> String {
        let o: [String: Any] = ["op": op, "d": ["type": s.type, "condition": s.condition]]
        let data = (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    public static func shouldReconnect(closeCode: Int) -> Bool {
        ![4001, 4002, 4003, 4004, 4009, 4010].contains(closeCode)
    }

    public static func reconnectDelay(attempt: Int, closeCode: Int? = nil) -> TimeInterval {
        if closeCode == 4007 { return 300 }
        return min(60, pow(2, Double(max(0, min(attempt, 6)))))
    }

    public static func isStale(lastMessage: TimeInterval, now: TimeInterval, heartbeat: TimeInterval) -> Bool {
        now - lastMessage > heartbeat * 3
    }

    public static func decode(_ text: String) -> SevenTVEventFrame {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let op = o["op"] as? Int else { return .ignored }
        let d = o["d"] as? [String: Any] ?? [:]
        switch op {
        case 0: return dispatch(d).map(SevenTVEventFrame.dispatch) ?? .ignored
        case 1: return .hello(heartbeat: (d["heartbeat_interval"] as? Double ?? 30_000) / 1000)
        case 2: return .heartbeat
        case 4: return .reconnect
        case 7: return .endOfStream(code: d["code"] as? Int ?? 0)
        default: return .ignored
        }
    }

    static func dispatch(_ d: [String: Any]) -> SevenTVEvent? {
        guard let type = d["type"] as? String, let body = d["body"] as? [String: Any] else { return nil }
        switch type {
        case "emote_set.update": return emoteSetChange(body)
        case "user.update": return activeSetChange(body)
        case "entitlement.create", "entitlement.delete":
            return entitlement(body["object"]).map { .entitlement($0, granted: type == "entitlement.create") }
        case "cosmetic.create", "cosmetic.update": return cosmetic(body["object"]).map(SevenTVEvent.cosmetic)
        default: return nil
        }
    }

    private static func fields(_ v: Any?) -> [[String: Any]] { v as? [[String: Any]] ?? [] }

    private static func emote(_ v: Any?) -> SevenTV.Emote? {
        guard let v, JSONSerialization.isValidJSONObject(v), let data = try? JSONSerialization.data(withJSONObject: v) else { return nil }
        return try? JSONDecoder().decode(SevenTV.Emote.self, from: data)
    }

    private static func name(_ v: Any?) -> String? { (v as? [String: Any])?["name"] as? String }

    static func emoteSetChange(_ body: [String: Any]) -> SevenTVEvent? {
        guard let id = body["id"] as? String else { return nil }
        var added: [String: EmoteIndex.Entry] = [:]
        var removed: [String] = []
        for f in fields(body["pulled"]) where f["key"] as? String == "emotes" {
            if let n = name(f["old_value"]) { removed.append(n) }
        }
        for f in fields(body["updated"]) where f["key"] as? String == "emotes" {
            if let n = name(f["old_value"]) { removed.append(n) }
            if let e = emote(f["value"]), let entry = SevenTV.entry(for: e) { added[e.name] = entry }
        }
        for f in fields(body["pushed"]) where f["key"] as? String == "emotes" {
            if let e = emote(f["value"]), let entry = SevenTV.entry(for: e) { added[e.name] = entry }
        }
        removed = removed.filter { added[$0] == nil }
        guard !added.isEmpty || !removed.isEmpty else { return nil }
        return .emoteSetChanged(setID: id, added: added, removed: removed)
    }

    static func activeSetChange(_ body: [String: Any]) -> SevenTVEvent? {
        guard let id = body["id"] as? String else { return nil }
        let touched = fields(body["updated"]).contains { f in
            f["key"] as? String == "connections" && fields(f["value"]).contains { $0["key"] as? String == "emote_set" }
        }
        return touched ? .activeSetChanged(userID: id) : nil
    }

    static func entitlement(_ object: Any?) -> SevenTVEntitlement? {
        guard let o = object as? [String: Any],
              let kind = (o["kind"] as? String).flatMap(SevenTVEntitlement.Kind.init(rawValue:)),
              let ref = o["ref_id"] as? String,
              let user = o["user"] as? [String: Any] else { return nil }
        let ids = fields(user["connections"]).compactMap { c -> Int? in
            guard c["platform"] as? String == "KICK" else { return nil }
            return (c["id"] as? String).flatMap { Int($0) } ?? (c["id"] as? Int)
        }
        return ids.isEmpty ? nil : SevenTVEntitlement(kind: kind, refID: ref, kickUserIDs: ids)
    }

    static func cosmetic(_ object: Any?) -> SevenTVCosmetic? {
        guard let o = object as? [String: Any], let data = o["data"] as? [String: Any],
              let id = (o["id"] as? String) ?? (data["id"] as? String) else { return nil }
        switch o["kind"] as? String {
        case "BADGE":
            guard let host = data["host"] as? [String: Any], let base = host["url"] as? String else { return nil }
            let files = fields(host["files"]).compactMap { $0["name"] as? String }
            guard let file = ["3x.webp", "2x.webp"].first(where: files.contains) ?? files.first,
                  let url = URL(string: (base.hasPrefix("//") ? "https:" + base : base) + "/" + file) else { return nil }
            return .badge(SevenTVBadge(id: id, tooltip: data["tooltip"] as? String ?? data["name"] as? String ?? "7TV", url: url))
        case "PAINT":
            let layer = (fields(data["stops"]).isEmpty ? fields(data["gradients"]).first : nil) ?? data
            let stops = fields(layer["stops"]).compactMap { s -> SevenTVPaint.Stop? in
                guard let at = s["at"] as? Double, let c = color(s["color"]) else { return nil }
                return SevenTVPaint.Stop(at: at, color: c)
            }
            return .paint(SevenTVPaint(id: id, name: data["name"] as? String ?? "",
                                       function: (layer["function"] as? String).flatMap(SevenTVPaint.Function.init(rawValue:)) ?? .linear,
                                       angle: layer["angle"] as? Double ?? 90, repeats: layer["repeat"] as? Bool ?? false,
                                       stops: stops, color: color(data["color"])))
        default:
            return nil
        }
    }

    static func color(_ v: Any?) -> UInt32? {
        guard let n = v as? NSNumber else { return nil }
        return UInt32(truncatingIfNeeded: n.int64Value)
    }
}
