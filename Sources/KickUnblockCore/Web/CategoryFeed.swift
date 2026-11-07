import Foundation

public enum FeedPhase: Equatable, Sendable {
    case loading
    case content
    case empty(hiddenMature: Int)
    case failed(String)

    public static func resolve(visible: Int, total: Int, loading: Bool, error: String?) -> FeedPhase {
        if visible > 0 { return .content }
        if loading { return .loading }
        if let error { return .failed(error) }
        return .empty(hiddenMature: max(0, total - visible))
    }
}

public enum Deadline {
    public struct TimedOut: LocalizedError, Equatable {
        public let seconds: Double
        public init(seconds: Double) { self.seconds = seconds }
        public var errorDescription: String? { "Kick didn't answer within \(Int(seconds)) seconds." }
    }

    public static let list: Double = 20

    public static func run<T: Sendable>(seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                throw TimedOut(seconds: seconds)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw TimedOut(seconds: seconds) }
            return first
        }
    }
}

public enum CategoryArt {
    public static func gradientHex(seed: Int) -> (top: String, bottom: String) {
        let h = Double(((seed % 360) + 360) % 360) / 360
        return (hsb(h, 0.55, 0.42), hsb((h + 0.12).truncatingRemainder(dividingBy: 1), 0.6, 0.18))
    }

    public static func hsb(_ h: Double, _ s: Double, _ v: Double) -> String {
        let i = Int(h * 6) % 6, f = h * 6 - Double(Int(h * 6))
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        let rgb: (Double, Double, Double)
        switch i {
        case 0: rgb = (v, t, p); case 1: rgb = (q, v, p); case 2: rgb = (p, v, t)
        case 3: rgb = (p, q, v); case 4: rgb = (t, p, v); default: rgb = (v, p, q)
        }
        return HexColor.string(rgb)
    }

    public static func seed(id: Int, name: String) -> Int {
        if id > 0 { return id }
        return name.unicodeScalars.reduce(5381) { ($0 &* 33 &+ Int($1.value)) & 0x7FFF_FFFF }
    }
}

// MARK: - Browse grid

public enum GridSlot: Hashable, Sendable {
    case category(Int)
    case skeleton(Int)
}

public enum BrowseGrid {
    public static let placeholderDeadline: TimeInterval = 2.5
    public static let skeletonCount = 9
    public static let pageSize = 28

    public static func slots(categoryIDs: [Int], loading: Bool) -> [GridSlot] {
        var seen = Set<Int>()
        let items = categoryIDs.filter { seen.insert($0).inserted }.map(GridSlot.category)
        if items.isEmpty && loading { return (0..<skeletonCount).map(GridSlot.skeleton) }
        return items
    }

    public static func showsFallback(loadedCount: Int, elapsed: TimeInterval, failed: Bool) -> Bool {
        loadedCount == 0 && (failed || elapsed >= placeholderDeadline)
    }
}

public enum TileArt: Equatable, Sendable {
    case skeleton, image, fallback

    public static func resolve(hasImage: Bool, allFailed: Bool, noURLs: Bool, elapsed: TimeInterval,
                               deadline: TimeInterval = BrowseGrid.placeholderDeadline) -> TileArt {
        if hasImage { return .image }
        if allFailed || noURLs || elapsed >= deadline { return .fallback }
        return .skeleton
    }
}

public struct CategorySeed: Hashable, Sendable {
    public let id: Int
    public let slug: String
    public let name: String

    public static let top: [CategorySeed] = [
        .init(id: 15, slug: "just-chatting", name: "Just Chatting"),
        .init(id: 8, slug: "grand-theft-auto-v", name: "Grand Theft Auto V (GTA)"),
        .init(id: 8549, slug: "irl", name: "IRL"),
        .init(id: 5, slug: "league-of-legends", name: "League of Legends"),
        .init(id: 28, slug: "slots", name: "Slots & Casino"),
        .init(id: 14353, slug: "ea-sports-fc-27", name: "EA Sports FC 27"),
        .init(id: 1552, slug: "counter-strike-2", name: "Counter-Strike 2"),
        .init(id: 64, slug: "valorant", name: "VALORANT"),
        .init(id: 10, slug: "minecraft", name: "Minecraft"),
        .init(id: 957, slug: "pubg-mobile", name: "PUBG Mobile"),
        .init(id: 3, slug: "fortnite", name: "Fortnite"),
        .init(id: 14, slug: "dota-2", name: "Dota 2"),
        .init(id: 13, slug: "rust", name: "Rust"),
        .init(id: 97, slug: "Roblox", name: "Roblox"),
        .init(id: 109, slug: "red-dead-redemption-ii", name: "Red Dead Redemption II"),
        .init(id: 157, slug: "Garena-Free-Fire", name: "Garena Free Fire"),
        .init(id: 53, slug: "pubg-battlegrounds", name: "PUBG: Battlegrounds"),
        .init(id: 6433, slug: "ark-survival-ascended", name: "Ark: Survival Ascended"),
    ]

    public static func webPage(slug: String) -> URL {
        URL(string: "https://kick.com/category/\(KickWebEndpoint.strictQueryEncode(slug))")!
    }
}

public enum CategoryListError: LocalizedError, Equatable, Sendable {
    case limited
    public static let title = "Kick is limiting this list right now"
    public var errorDescription: String? {
        "\(Self.title). Try again in a minute. You can also open the category on kick.com."
    }

    public static func map(_ error: Error, websiteBlocked: Bool) -> Error {
        if error is CancellationError { return error }
        if let e = error as? KickWebError, e.isBlocked { return CategoryListError.limited }
        return websiteBlocked ? CategoryListError.limited : error
    }
}
