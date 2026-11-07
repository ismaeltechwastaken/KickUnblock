import AVFoundation
import KickUnblockCore

final class RecordingLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let shared = RecordingLoader()
    let queue = DispatchQueue(label: "dev.ismaeltech.kickunblock.recording")
    private let lock = NSLock()
    private var startAt: Double?

    func asset(for url: URL, startAt: Double) -> AVURLAsset? {
        guard let wrapped = RecordingPlaylist.wrap(url) else { return nil }
        lock.lock(); self.startAt = startAt; lock.unlock()
        let asset = AVURLAsset(url: wrapped)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    func resourceLoader(_ loader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        guard let wrapped = request.request.url, let url = RecordingPlaylist.unwrap(wrapped) else { return false }
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        r.setValue(KickWebClient.userAgent, forHTTPHeaderField: "User-Agent")
        let task = URLSession.shared.dataTask(with: r) { data, response, error in
            guard let data, (response as? HTTPURLResponse)?.statusCode == 200 else {
                request.finishLoading(with: error ?? URLError(.badServerResponse))
                return
            }
            self.lock.lock(); let start = self.startAt; self.lock.unlock()
            let text = RecordingPlaylist.rewrite(String(decoding: data, as: UTF8.self), base: url, startAt: start)
            request.contentInformationRequest?.contentType = "public.m3u-playlist"
            request.contentInformationRequest?.isByteRangeAccessSupported = false
            request.contentInformationRequest?.contentLength = Int64(text.utf8.count)
            request.dataRequest?.respond(with: Data(text.utf8))
            request.finishLoading()
        }
        task.resume()
        return true
    }
}
