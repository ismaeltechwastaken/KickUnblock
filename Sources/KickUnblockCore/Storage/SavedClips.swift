import Foundation

public struct SavedClip: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case clip, vod, channel }
    public let id: String
    public var kind: Kind
    public var title: String
    public var channelSlug: String
    public var channelName: String
    public var thumbnailURL: String?
    public var artworkURL: String?
    public var playbackURL: String?
    public var videoUUID: String?
    public var offset: Double?
    public var duration: Double?
    public var savedAt: Date

    public init(id: String, kind: Kind, title: String, channelSlug: String, channelName: String,
                thumbnailURL: String? = nil, artworkURL: String? = nil, playbackURL: String? = nil, videoUUID: String? = nil,
                offset: Double? = nil, duration: Double? = nil, savedAt: Date = Date()) {
        self.id = id; self.kind = kind; self.title = title; self.channelSlug = channelSlug
        self.channelName = channelName; self.thumbnailURL = thumbnailURL; self.playbackURL = playbackURL
        self.artworkURL = artworkURL
        self.videoUUID = videoUUID; self.offset = offset; self.duration = duration; self.savedAt = savedAt
    }
}

public final class SavedClipStore: @unchecked Sendable {
    public static let key = "kickunblock.saved.v1"
    private let defaults: UserDefaults
    private let lock = NSLock()
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func all() -> [SavedClip] {
        lock.lock(); defer { lock.unlock() }
        guard let d = defaults.data(forKey: Self.key),
              let list = try? JSONDecoder().decode([SavedClip].self, from: d) else { return [] }
        return list.sorted { $0.savedAt > $1.savedAt }
    }
    public func contains(_ id: String) -> Bool { all().contains { $0.id == id } }
    public func save(_ item: SavedClip) { write(all().filter { $0.id != item.id } + [item]) }
    public func remove(_ id: String) { write(all().filter { $0.id != id }) }
    @discardableResult public func toggle(_ item: SavedClip) -> Bool {
        if contains(item.id) { remove(item.id); return false } else { save(item); return true }
    }
    private func write(_ list: [SavedClip]) {
        lock.lock(); defer { lock.unlock() }
        defaults.set(try? JSONEncoder().encode(list), forKey: Self.key)
    }
}
