import Foundation

public enum RecordingPlaylist {
    public static let scheme = "kickunblock-rec"

    public static func wrap(_ url: URL) -> URL? {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.scheme == "https" else { return nil }
        c.scheme = scheme
        return c.url
    }

    public static func unwrap(_ url: URL) -> URL? {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.scheme == scheme else { return nil }
        c.scheme = "https"
        return c.url
    }

    public static let minimumHeight = 300

    static func resolutionHeight(_ line: String) -> Int? {
        guard let r = line.range(of: #"RESOLUTION=\d+x(\d+)"#, options: .regularExpression) else { return nil }
        return Int(line[r].split(separator: "x").last ?? "")
    }

    public static func playableEnd(_ media: String) -> Double? {
        var total = 0.0, target = 0.0, segments = 0
        for line in media.components(separatedBy: .newlines) {
            if line.hasPrefix("#EXTINF:"), let d = Double(line.dropFirst(8).split(separator: ",").first ?? "") {
                total += d; segments += 1
            } else if line.hasPrefix("#EXT-X-TARGETDURATION:"), let t = Double(line.dropFirst(22)) {
                target = t
            }
        }
        guard segments > 0 else { return nil }
        return max(0, total - 3 * max(target, 1) - 2)
    }

    public static func rewrite(_ text: String, base: URL, startAt: Double? = nil) -> String {
        let isMaster = text.contains("#EXT-X-STREAM-INF")
        func absolute(_ ref: String) -> URL? { URL(string: ref, relativeTo: base)?.absoluteURL }
        func playlistRef(_ ref: String) -> String {
            guard let abs = absolute(ref) else { return ref }
            let isPlaylist = abs.path.hasSuffix(".m3u8")
            return (isPlaylist ? wrap(abs) : abs)?.absoluteString ?? ref
        }
        var out: [String] = []
        var skipURI = false
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if isMaster, line.hasPrefix("#EXT-X-STREAM-INF:"), let h = resolutionHeight(line), h < minimumHeight {
                skipURI = true
                continue
            }
            if skipURI, !line.isEmpty, !line.hasPrefix("#") { skipURI = false; continue }
            if line == "#EXT-X-ENDLIST" || line.hasPrefix("#EXT-X-START:") || line.hasPrefix("#EXT-X-PROGRAM-DATE-TIME:") { continue }
            if line.hasPrefix("#EXT-X-MEDIA:"), line.contains("TYPE=SUBTITLES") { continue }
            if line.hasPrefix("#") {
                if let r = line.range(of: #"URI="([^"]*)""#, options: .regularExpression) {
                    let attr = String(line[r])
                    let ref = String(attr.dropFirst(5).dropLast())
                    let replaced = isMaster ? playlistRef(ref) : (absolute(ref)?.absoluteString ?? ref)
                    out.append(line.replacingCharacters(in: r, with: "URI=\"\(replaced)\""))
                } else {
                    out.append(line.replacingOccurrences(of: #",SUBTITLES="[^"]*""#, with: "", options: .regularExpression))
                }
            } else if line.isEmpty {
                out.append(line)
            } else {
                out.append(isMaster ? playlistRef(line) : (absolute(line)?.absoluteString ?? line))
            }
        }
        if !isMaster, let startAt, startAt.isFinite, startAt >= 0, let i = out.firstIndex(of: "#EXTM3U") {
            out.insert(String(format: "#EXT-X-START:TIME-OFFSET=%.3f,PRECISE=YES", startAt), at: i + 1)
        }
        return out.joined(separator: "\n")
    }
}
