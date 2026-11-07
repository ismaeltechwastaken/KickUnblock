import Foundation

public enum BroadcastOriginRefresh {
    public struct Origin: Equatable, Sendable {
        public let startedAt: Date?
        public let broadcastID: Int?
    }

    public static func resolve(currentStartedAt: Date?, currentBroadcastID: Int?,
                               channel: WebChannel, expectedSlug: String, expectedChannelID: Int?,
                               nowUTC: Double) -> Origin? {
        guard nowUTC.isFinite, channel.slug.caseInsensitiveCompare(expectedSlug) == .orderedSame,
              expectedChannelID.map({ $0 == channel.id }) ?? true,
              channel.isLive, let stream = channel.livestream, stream.id > 0 else { return nil }
        if currentBroadcastID == stream.id, currentStartedAt != nil {
            return Origin(startedAt: currentStartedAt, broadcastID: currentBroadcastID)
        }
        let start = stream.startedAt.flatMap { date -> Date? in
            let utc = date.timeIntervalSince1970
            return LiveViewerDelay.validSync(utc) && utc <= nowUTC ? date : nil
        }
        if let start, let currentStartedAt, start < currentStartedAt { return nil }
        if currentBroadcastID == nil, start == nil {
            return Origin(startedAt: currentStartedAt, broadcastID: stream.id)
        }
        return Origin(startedAt: start, broadcastID: stream.id)
    }
}
