import Foundation

public struct HLSVariant: Equatable, Hashable, Sendable {
    public let uri: URL
    public let bandwidth: Int
    public let width: Int?
    public let height: Int?
    public let frameRate: Double?
    public let codecs: String?
    public let name: String?

    public init(uri: URL, bandwidth: Int, width: Int? = nil, height: Int? = nil, frameRate: Double? = nil,
                codecs: String? = nil, name: String? = nil) {
        self.uri = uri; self.bandwidth = bandwidth; self.width = width; self.height = height
        self.frameRate = frameRate; self.codecs = codecs; self.name = name
    }

    public var isAudioOnly: Bool {
        if (name ?? "").lowercased().contains("audio") { return true }
        guard height == nil else { return false }
        guard let c = codecs?.lowercased() else { return false }
        return !c.contains("avc1") && !c.contains("hvc1") && !c.contains("hev1") && !c.contains("av01")
    }

    public var label: String {
        if isAudioOnly { return "Audio Only" }
        if let h = height {
            if let f = frameRate, f > 0 { return "\(h)p\(Int(f.rounded()))" }
            return "\(h)p"
        }
        return name ?? "\(bandwidth / 1000) kbps"
    }
}

public enum M3U8MasterParser {
    public static func parse(_ text: String, base: URL) -> [HLSVariant] {
        var out: [HLSVariant] = []
        var pending: [String: String]?
        var groupNames: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-MEDIA:") {
                let a = attributes(String(line.dropFirst("#EXT-X-MEDIA:".count)))
                if a["TYPE"] == "VIDEO", let g = a["GROUP-ID"], let n = a["NAME"] { groupNames[g] = n }
            } else if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pending = attributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
            } else if let attrs = pending, !line.isEmpty, !line.hasPrefix("#") {
                pending = nil
                guard let uri = resolve(line, base: base) else { continue }
                let res = attrs["RESOLUTION"]?.lowercased().split(separator: "x").compactMap { Int($0) }
                let video = attrs["VIDEO"]
                out.append(HLSVariant(uri: uri, bandwidth: Int(attrs["BANDWIDTH"] ?? "") ?? 0,
                                      width: res?.count == 2 ? res![0] : nil, height: res?.count == 2 ? res![1] : nil,
                                      frameRate: attrs["FRAME-RATE"].flatMap(Double.init), codecs: attrs["CODECS"],
                                      name: video.map { groupNames[$0] ?? $0 }))
            }
        }
        return out
    }

    public static func resolve(_ s: String, base: URL) -> URL? {
        if let u = URL(string: s), u.scheme != nil { return u }
        return URL(string: s, relativeTo: base)?.absoluteURL
    }

    public static func attributes(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        var key = "", value = "", inKey = true, inQuotes = false
        func flush() {
            let k = key.trimmingCharacters(in: .whitespaces)
            if !k.isEmpty { out[k] = value }
            key = ""; value = ""; inKey = true
        }
        for ch in s {
            if inKey {
                if ch == "=" { inKey = false } else if ch == "," { flush() } else { key.append(ch) }
            } else if ch == "\"" { inQuotes.toggle() }
            else if ch == ",", !inQuotes { flush() }
            else { value.append(ch) }
        }
        flush()
        return out
    }
}

public struct HLSMediaPlaylist: Equatable, Sendable {
    public struct Segment: Equatable, Sendable {
        public let url: URL
        public let duration: Double
        public let range: Range<Int>?
    }
    public var initSection: Segment?
    public var segments: [Segment] = []
    public var isEncrypted = false
    public var hasEndList = false

    public var fileExtension: String { initSection != nil ? "mp4" : "ts" }

    public static func parse(_ text: String, base: URL) -> HLSMediaPlaylist {
        var p = HLSMediaPlaylist()
        var duration: Double?
        var pendingRange: (length: Int, offset: Int?)?
        var nextOffset: [URL: Int] = [:]
        func range(for url: URL, _ r: (length: Int, offset: Int?)?) -> Range<Int>? {
            guard let r else { return nil }
            let start = r.offset ?? nextOffset[url] ?? 0
            nextOffset[url] = start + r.length
            return start..<(start + r.length)
        }
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXTINF:") {
                duration = Double(line.dropFirst(8).split(separator: ",").first.map(String.init) ?? "")
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                pendingRange = byteRange(String(line.dropFirst("#EXT-X-BYTERANGE:".count)))
            } else if line.hasPrefix("#EXT-X-KEY:") {
                let method = M3U8MasterParser.attributes(String(line.dropFirst("#EXT-X-KEY:".count)))["METHOD"] ?? "NONE"
                if method.uppercased() != "NONE" { p.isEncrypted = true }
            } else if line.hasPrefix("#EXT-X-MAP:") {
                let a = M3U8MasterParser.attributes(String(line.dropFirst("#EXT-X-MAP:".count)))
                if let u = a["URI"].flatMap({ M3U8MasterParser.resolve($0, base: base) }) {
                    p.initSection = Segment(url: u, duration: 0, range: a["BYTERANGE"].flatMap(byteRange).flatMap { range(for: u, $0) })
                }
            } else if line.hasPrefix("#EXT-X-ENDLIST") {
                p.hasEndList = true
            } else if !line.isEmpty, !line.hasPrefix("#"), let u = M3U8MasterParser.resolve(line, base: base) {
                p.segments.append(Segment(url: u, duration: duration ?? 0, range: range(for: u, pendingRange)))
                duration = nil; pendingRange = nil
            }
        }
        return p
    }

    static func byteRange(_ s: String) -> (length: Int, offset: Int?)? {
        let parts = s.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")).split(separator: "@")
        guard let len = parts.first.flatMap({ Int($0) }) else { return nil }
        return (len, parts.count > 1 ? Int(parts[1]) : nil)
    }

    public var downloadParts: [Segment] {
        var out: [Segment] = []
        for s in ([initSection].compactMap { $0 } + segments) {
            if let last = out.last, last.url == s.url, let a = last.range, let b = s.range, a.upperBound == b.lowerBound {
                out[out.count - 1] = Segment(url: s.url, duration: last.duration + s.duration, range: a.lowerBound..<b.upperBound)
            } else if let last = out.last, last.url == s.url, last.range == nil, s.range == nil {
                continue
            } else {
                out.append(s)
            }
        }
        return out
    }
}

public enum QualityChoice: Hashable, Sendable {
    case auto
    case source
    case rendition(String)
    case audioOnly

    public var rawValue: String {
        switch self {
        case .auto: "auto"
        case .source: "source"
        case .audioOnly: "audioOnly"
        case .rendition(let l): l
        }
    }

    public init(rawValue: String) {
        switch rawValue {
        case "auto": self = .auto
        case "source", "": self = .source
        case "audioOnly": self = .audioOnly
        case "p720": self = .rendition("720p60")
        case "p480": self = .rendition("480p30")
        default: self = .rendition(rawValue)
        }
    }

    public var label: String {
        switch self {
        case .auto: "Auto"
        case .source: "Source"
        case .audioOnly: "Audio Only"
        case .rendition(let l): l
        }
    }

    public static let presets: [QualityChoice] = [.auto, .source, .rendition("720p60"), .rendition("480p30"),
                                                  .rendition("360p30"), .rendition("160p30"), .audioOnly]

    public static func pills(for variants: [HLSVariant]) -> [QualityChoice] {
        let video = variants.filter { !$0.isAudioOnly }.sorted { $0.bandwidth > $1.bandwidth }
        var out: [QualityChoice] = [.auto]
        for (i, v) in video.enumerated() {
            let c: QualityChoice = i == 0 ? .source : .rendition(v.label)
            if !out.contains(c) { out.append(c) }
        }
        out.append(.audioOnly)
        return out
    }

    public func pillLabel(variants: [HLSVariant]) -> String {
        if self == .source, let top = variants.filter({ !$0.isAudioOnly }).max(by: { $0.bandwidth < $1.bandwidth }) {
            return "Source (\(top.label))"
        }
        return label
    }

    var requestedHeight: Int? {
        guard case .rendition(let l) = self, let p = l.firstIndex(of: "p") else { return nil }
        return Int(l[..<p])
    }
}

public struct QualityPlan: Equatable, Sendable {
    public let variantURL: URL?
    public let variant: HLSVariant?
    public let maxResolution: (width: Double, height: Double)
    public let peakBitRate: Double
    public let hideVideo: Bool

    public func needsReload(from other: QualityPlan) -> Bool { variantURL != other.variantURL }
    public static func == (a: QualityPlan, b: QualityPlan) -> Bool {
        a.variantURL == b.variantURL && a.maxResolution == b.maxResolution && a.peakBitRate == b.peakBitRate && a.hideVideo == b.hideVideo
    }
}

public enum AudioOnlySaver {
    public static let maxResolution: (width: Double, height: Double) = (284, 160)
    public static let peakBitRate: Double = 200_000
    public static func expectedVariant(in variants: [HLSVariant]) -> HLSVariant? {
        let video = variants.filter { !$0.isAudioOnly }
        let fits = video.filter { ($0.height ?? .max) <= Int(maxResolution.height) }
        return (fits.isEmpty ? video : fits).min { $0.bandwidth < $1.bandwidth }
    }
}

public enum QualitySelector {
    static let noCaps: (width: Double, height: Double) = (0, 0)

    public static func plan(for choice: QualityChoice, variants: [HLSVariant]) -> QualityPlan {
        let video = variants.filter { !$0.isAudioOnly }
        func direct(_ v: HLSVariant?) -> QualityPlan {
            QualityPlan(variantURL: v?.uri, variant: v, maxResolution: noCaps, peakBitRate: 0, hideVideo: false)
        }
        switch choice {
        case .auto:
            return direct(nil)
        case .source:
            return direct(video.max { $0.bandwidth < $1.bandwidth })
        case .rendition(let label):
            if let exact = video.first(where: { $0.label == label }) { return direct(exact) }
            let h = choice.requestedHeight ?? .max
            let below = video.filter { ($0.height ?? 0) <= h }
            return direct(below.max { $0.bandwidth < $1.bandwidth } ?? video.min { $0.bandwidth < $1.bandwidth })
        case .audioOnly:
            let v = variants.filter(\.isAudioOnly).min { $0.bandwidth < $1.bandwidth } ?? AudioOnlySaver.expectedVariant(in: variants)
            return QualityPlan(variantURL: v?.uri, variant: v, maxResolution: AudioOnlySaver.maxResolution,
                               peakBitRate: AudioOnlySaver.peakBitRate, hideVideo: true)
        }
    }
}
