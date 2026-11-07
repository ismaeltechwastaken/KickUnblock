import Foundation

public struct FollowedChannel: Codable, Hashable, Identifiable, Sendable {
    public var id: String { slug }
    public let slug: String
    public var broadcasterUserID: Int?
    public var displayName: String
    public var avatarURL: String?
    public var followedAt: Date
    public init(slug: String, broadcasterUserID: Int? = nil, displayName: String, avatarURL: String? = nil, followedAt: Date = Date()) {
        self.slug = slug.lowercased(); self.broadcasterUserID = broadcasterUserID
        self.displayName = displayName; self.avatarURL = avatarURL; self.followedAt = followedAt
    }
}

public final class FollowStore: @unchecked Sendable {
    public static let key = "kickunblock.follows.v1"
    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func all() -> [FollowedChannel] {
        lock.lock(); defer { lock.unlock() }
        guard let data = defaults.data(forKey: Self.key),
              let list = try? JSONDecoder().decode([FollowedChannel].self, from: data) else { return [] }
        return list.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    public func isFollowing(_ slug: String) -> Bool { all().contains { $0.slug == slug.lowercased() } }

    public func follow(_ channel: FollowedChannel) {
        var list = all().filter { $0.slug != channel.slug }
        list.append(channel); save(list)
    }

    public func unfollow(_ slug: String) { save(all().filter { $0.slug != slug.lowercased() }) }

    public func removeAll() { lock.lock(); defaults.removeObject(forKey: Self.key); lock.unlock() }

    public func exportJSON() -> Data { (try? JSONEncoder().encode(all())) ?? Data("[]".utf8) }

    private func save(_ list: [FollowedChannel]) {
        lock.lock(); defer { lock.unlock() }
        defaults.set(try? JSONEncoder().encode(list), forKey: Self.key)
    }
}

public enum PrefKey {
    public static let dataSource = "kickunblock.data.source"
    public static let lowLatency = "kickunblock.player.lowLatency"
    public static let earlySegments = "kickunblock.player.earlySegments"
    public static let backgroundAudio = "kickunblock.player.bgAudio"
    public static let autoPiP = "kickunblock.player.autoPiP"
    public static let preferredQuality = "kickunblock.player.quality"
    public static let playbackSpeed = "kickunblock.player.speed"
    public static let seekInterval = "kickunblock.player.seek"
    public static let keepAwake = "kickunblock.player.keepAwake"
    public static let emotesKick = "kickunblock.chat.emotes.kick"
    public static let emotes7TV = "kickunblock.chat.emotes.7tv"
    public static let emotesBTTVFFZ = "kickunblock.chat.emotes.bttvffz"
    public static let animateEmotes = "kickunblock.chat.emotes.animate"
    public static let chatFontSize = "kickunblock.chat.fontSize"
    public static let chatSpacing = "kickunblock.chat.spacing"
    public static let chatTimestamps = "kickunblock.chat.timestamps"
    public static let landscapeChat = "kickunblock.chat.landscapeMode"
    public static let overlayWidth = "kickunblock.chat.overlayWidth"
    public static let overlayOpacity = "kickunblock.chat.overlayOpacity"
    public static let hideCommands = "kickunblock.chat.hideCommands"
    public static let hideSystemBanners = "kickunblock.chat.hideBanners"
    public static let dedupeSpam = "kickunblock.chat.dedupe"
    public static let chatMaxMessages = "kickunblock.chat.maxMessages"
    public static let background = "kickunblock.ui.background"
    public static let accent = "kickunblock.ui.accent"
    public static let controlsAutoHide = "kickunblock.ui.autoHide"
    public static let hideMature = "kickunblock.browse.hideMature"
    public static let launchAnimation = "kickunblock.ui.launchAnimation"
    public static let openingScreen = "kickunblock.ui.openingScreen"
    public static let chromeStyle = "kickunblock.ui.chromeStyle"
    public static let showStats = "kickunblock.inspector.stats"
    public static let showStatsDefault = false
    public static let localPlaybackDiagnostics = "kickunblock.inspector.localDiagnostics"
    public static let recentEmotes = "kickunblock.chat.recentEmotes"
    public static let highlightOwnMessages = "kickunblock.chat.highlightOwn"
    public static let didResetStatsOverlay = "kickunblock.migration.statsOverlayOff.v1"
    public static let didRetireLatencyTweaks = "kickunblock.migration.retireLatencyTweaks.v1"
    public static let chatRelayURL = "kickunblock.chat.relayURL"
    public static let pusherKey = "kickunblock.chat.pusherKey"
    public static let pusherCluster = "kickunblock.chat.pusherCluster"
    public static let kickEmoteURLTemplate = "kickunblock.chat.kickEmoteURL"
    public static let chatSendPath = "kickunblock.account.chatSendPath"
    public static let sevenTVCosmetics = "kickunblock.chat.7tvCosmetics"
    public static let blockedTerms = "kickunblock.chat.blockedTerms"
    public static let blockedUsers = "kickunblock.chat.blockedUsers"

    public static let tweakKeys = [dataSource, backgroundAudio, autoPiP, preferredQuality,
                                   playbackSpeed, seekInterval, keepAwake,
                                   emotesKick, emotes7TV, emotesBTTVFFZ, animateEmotes, sevenTVCosmetics, chatFontSize, chatSpacing,
                                   chatTimestamps, landscapeChat, overlayWidth, overlayOpacity,
                                   hideCommands, hideSystemBanners, dedupeSpam, chatMaxMessages,
                                   background, accent, controlsAutoHide, hideMature, launchAnimation, openingScreen, chromeStyle,
                                   showStats, localPlaybackDiagnostics, highlightOwnMessages]

    public static let all = tweakKeys + [chatRelayURL, chatSendPath, pusherKey, pusherCluster, kickEmoteURLTemplate,
                                         FollowStore.key, SavedClipStore.key, recentEmotes, blockedTerms, blockedUsers, didResetStatsOverlay,
                                         didRetireLatencyTweaks]

    public static func resetTweaks(_ defaults: UserDefaults = .standard) {
        tweakKeys.forEach { defaults.removeObject(forKey: $0) }
    }

    public static func migrateStatsOverlayOff(_ defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: didResetStatsOverlay) else { return }
        defaults.removeObject(forKey: showStats)
        defaults.set(true, forKey: didResetStatsOverlay)
    }

    public static func migrateRetiredLatencyTweaks(_ defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: didRetireLatencyTweaks) else { return }
        defaults.removeObject(forKey: lowLatency)
        defaults.removeObject(forKey: earlySegments)
        defaults.set(true, forKey: didRetireLatencyTweaks)
    }

    public static func clearAll(_ defaults: UserDefaults = .standard) {
        Set(all).forEach { defaults.removeObject(forKey: $0) }
    }
}

public enum ChatSendPath: String, CaseIterable, Identifiable, Sendable {
    case webSession
    case official
    public var id: String { rawValue }
    public var label: String { self == .webSession ? "Kick Account (web session)" : "Official API (OAuth)" }
}
