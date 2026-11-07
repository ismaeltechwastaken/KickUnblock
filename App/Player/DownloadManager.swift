import Foundation
import KickUnblockCore
import Photos

@MainActor
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    enum State: Equatable { case running, done(URL), savedToPhotos, failed(String) }
    struct Job: Identifiable, Equatable {
        let id: String
        let title: String
        var detail: String
        var progress: Double
        var state: State
    }

    @Published private(set) var jobs: [String: Job] = [:]
    @Published private(set) var files: [URL] = []
    private var tasks: [String: Task<Void, Never>] = [:]

    private let chunk = 4 * 1024 * 1024

    static var folder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    init() { refreshFiles() }

    func refreshFiles() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: [.creationDateKey, .fileSizeKey])) ?? []
        files = urls.filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { (($0.creationDate) ?? .distantPast) > (($1.creationDate) ?? .distantPast) }
    }

    func delete(_ url: URL) { try? FileManager.default.removeItem(at: url); refreshFiles() }

    func cancel(_ id: String) {
        tasks[id]?.cancel(); tasks[id] = nil
        jobs[id] = nil
    }

    func start(id: String, title: String, url: URL, variant: HLSVariant?, toPhotos: Bool = false) {
        if case .running = jobs[id]?.state { return }
        jobs[id] = Job(id: id, title: title, detail: "Reading playlist…", progress: 0, state: .running)
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            do {
                let folder = toPhotos ? FileManager.default.temporaryDirectory : Self.folder
                let file = try await self.run(id: id, title: title, url: url, variant: variant, folder: folder)
                if toPhotos {
                    self.jobs[id]?.detail = "Saving to Photos…"
                    try await Self.saveToPhotos(file)
                    self.jobs[id]?.state = .savedToPhotos
                } else {
                    self.jobs[id]?.state = .done(file)
                    self.jobs[id]?.detail = file.lastPathComponent
                }
                self.jobs[id]?.progress = 1
                self.refreshFiles()
            } catch is CancellationError {
                self.jobs[id] = nil
            } catch {
                self.jobs[id]?.state = .failed(error.localizedDescription)
            }
            self.tasks[id] = nil
        }
    }

    private struct Failure: LocalizedError { let errorDescription: String? }

    static func saveToPhotos(_ ts: URL) async throws {
        let mp4 = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        defer {
            try? FileManager.default.removeItem(at: mp4)
            try? FileManager.default.removeItem(at: ts)
        }
        try await Task.detached(priority: .userInitiated) { try await TSRemux.convert(ts: ts, to: mp4) }.value
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw Failure(errorDescription: "Allow KickUnblock to add photos in Settings › Privacy & Security › Photos.")
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: mp4, options: nil)
        }
    }

    private func fetch(_ url: URL, range: Range<Int>? = nil) async throws -> Data {
        var r = URLRequest(url: url)
        r.setValue(KickWebClient.userAgent, forHTTPHeaderField: "User-Agent")
        if let range { r.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range") }
        let (data, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 || code == 206 else { throw Failure(errorDescription: "Kick's video server returned HTTP \(code) for \(url.lastPathComponent).") }
        if let range, code == 200, data.count > range.count {
            return data.subdata(in: range.clamped(to: 0..<data.count))
        }
        return data
    }

    private func run(id: String, title: String, url: URL, variant: HLSVariant?, folder: URL) async throws -> URL {
        var mediaURL = url
        var text = String(decoding: try await fetch(url), as: UTF8.self)
        guard text.hasPrefix("#EXTM3U") else { throw Failure(errorDescription: "This source is not an HLS playlist.") }
        var label = ""
        if text.contains("#EXT-X-STREAM-INF") {
            let ladder = M3U8MasterParser.parse(text, base: url).filter { !$0.isAudioOnly }
            guard let v = variant.flatMap({ want in ladder.first { $0.uri == want.uri } }) ?? ladder.max(by: { $0.bandwidth < $1.bandwidth })
            else { throw Failure(errorDescription: "No downloadable quality in this playlist.") }
            mediaURL = v.uri; label = " \(v.label)"
            text = String(decoding: try await fetch(mediaURL), as: UTF8.self)
        }
        let media = HLSMediaPlaylist.parse(text, base: mediaURL)
        if media.isEncrypted { throw Failure(errorDescription: "Encrypted videos can't be downloaded.") }
        guard media.hasEndList else { throw Failure(errorDescription: "Live streams can't be downloaded. Try the VOD after the stream ends.") }
        guard !media.segments.isEmpty else { throw Failure(errorDescription: "The playlist has no video segments.") }

        var requests: [(URL, Range<Int>?)] = []
        for p in media.downloadParts {
            if let r = p.range, r.count > chunk {
                var lo = r.lowerBound
                while lo < r.upperBound { let hi = min(lo + chunk, r.upperBound); requests.append((p.url, lo..<hi)); lo = hi }
            } else { requests.append((p.url, p.range)) }
        }

        let name = Self.fileName(title + label, ext: media.fileExtension)
        let partial = folder.appendingPathComponent("." + name + ".part")
        let dest = folder.appendingPathComponent(name)
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }
        var bytes = 0
        for (i, req) in requests.enumerated() {
            try Task.checkCancellation()
            let data = try await fetch(req.0, range: req.1)
            try handle.write(contentsOf: data)
            bytes += data.count
            jobs[id]?.progress = Double(i + 1) / Double(requests.count)
            jobs[id]?.detail = "\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) · \(i + 1)/\(requests.count)"
        }
        try handle.close()
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: partial, to: dest)
        return dest
    }

    static func fileName(_ title: String, ext: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t")
        let clean = title.components(separatedBy: bad).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return String((clean.isEmpty ? "Kick video" : clean).prefix(80)) + "." + ext
    }
}

private extension URL {
    var creationDate: Date? { (try? resourceValues(forKeys: [.creationDateKey]))?.creationDate }
}
