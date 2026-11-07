import Foundation

public struct WebImage: Decodable, Hashable, Sendable {
    public let url: String?
    public let src: String?
    public let srcset: String?
    public let responsive: String?

    enum CodingKeys: String, CodingKey { case url, src, srcset, responsive }

    public init(from decoder: Decoder) throws {
        if let raw = try? decoder.singleValueContainer().decode(String.self) {
            url = raw; src = nil; srcset = nil; responsive = nil
        } else {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            url = try? c.decode(String.self, forKey: .url)
            src = try? c.decode(String.self, forKey: .src)
            srcset = try? c.decode(String.self, forKey: .srcset)
            responsive = try? c.decode(String.self, forKey: .responsive)
        }
    }

    public var imageCandidates: [URL] {
        var result: [URL] = []
        for raw in [url, src, srcset, responsive] {
            if let url = ImageURLSanitizer.url(from: raw, base: URL(string: "https://kick.com")), !result.contains(url) {
                result.append(url)
            }
        }
        return result
    }
}

public enum ImageURLSanitizer {
    public static func url(from raw: String?, base: URL? = nil) -> URL? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if looksLikeSrcset(s) {
            let first = s.split(separator: ",", omittingEmptySubsequences: true).first.map(String.init) ?? s
            s = first.trimmingCharacters(in: .whitespaces)
            if let r = s.range(of: #"\s+\d+(\.\d+)?[wx]$"#, options: .regularExpression) { s = String(s[..<r.lowerBound]) }
        }
        s = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "%20")
        if s.hasPrefix("//") { s = "https:" + s }
        if s.lowercased().hasPrefix("https://") || s.lowercased().hasPrefix("http://") { return URL(string: s) }
        guard let base, !s.contains("://") else { return nil }
        return URL(string: s, relativeTo: base)?.absoluteURL
    }

    static func looksLikeSrcset(_ s: String) -> Bool {
        s.range(of: #"\S\s+\d+(\.\d+)?[wx](\s*,|\s*$)"#, options: .regularExpression) != nil
    }
}
