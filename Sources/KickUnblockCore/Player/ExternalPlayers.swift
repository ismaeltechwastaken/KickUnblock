import Foundation

public enum ExternalPlayer: String, CaseIterable, Identifiable, Sendable {
    case vlc, infuse, outplayer
    public var id: String { rawValue }
    public var label: String {
        switch self { case .vlc: "VLC"; case .infuse: "Infuse"; case .outplayer: "OutPlayer" }
    }
    public var scheme: String {
        switch self { case .vlc: "vlc-x-callback"; case .infuse: "infuse"; case .outplayer: "outplayer" }
    }

    public func url(for stream: URL) -> URL? {
        let enc = Self.encode(stream.absoluteString)
        switch self {
        case .vlc: return URL(string: "vlc-x-callback://x-callback-url/stream?url=\(enc)")
        case .infuse: return URL(string: "infuse://x-callback-url/play?url=\(enc)")
        case .outplayer:
            return URL(string: "outplayer://\(stream.absoluteString)")
        }
    }

    public static func encode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
