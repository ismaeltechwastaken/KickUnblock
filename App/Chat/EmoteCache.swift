import Foundation
import ImageIO
#if canImport(UIKit)
import UIKit
#endif
import KickUnblockCore

// MARK: - Data cache

final class EmoteDataCache: @unchecked Sendable {
    static let shared = EmoteDataCache()
    let store = NSCache<NSString, NSData>()
    private let stills = NSCache<NSString, UIImage>()
    private let downloads = EmoteDownloads()

    init() {
        store.totalCostLimit = 32 * 1024 * 1024
        stills.countLimit = 1_000
        stills.totalCostLimit = 24 * 1024 * 1024
    }

    func data(for url: URL, key: String) async -> Data? {
        if let d = store.object(forKey: key as NSString) { return d as Data }
        return await downloads.fetch(url: url, key: key, into: store)
    }

    func still(for url: URL, key: String) async -> UIImage? {
        if let img = stills.object(forKey: key as NSString) { return img }
        guard let data = await data(for: url, key: key), let img = EmoteDecoder.firstFrame(data) else { return nil }
        stills.setObject(img, forKey: key as NSString, cost: Int(img.size.width * img.size.height) * 16)
        return img
    }

    func removeAll() {
        store.removeAllObjects()
        stills.removeAllObjects()
        Task { await EmoteFrameCache.shared.removeAll() }
    }
}

actor EmoteDownloads {
    private var tasks: [String: Task<Data?, Never>] = [:]

    func fetch(url: URL, key: String, into cache: NSCache<NSString, NSData>) async -> Data? {
        if let running = tasks[key] { return await running.value }
        let task = Task<Data?, Never> {
            var req = URLRequest(url: url)
            req.setValue(KickWebClient.userAgent, forHTTPHeaderField: "User-Agent")
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
                  !data.isEmpty else { return nil }
            cache.setObject(data as NSData, forKey: key as NSString, cost: data.count)
            return data
        }
        tasks[key] = task
        let value = await task.value
        tasks[key] = nil
        return value
    }
}

enum EmoteDecoder {
    static func firstFrame(_ data: Data) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return UIImage(data: data) }
        return UIImage(cgImage: cg, scale: 2, orientation: .up)
    }
}

extension EmoteDataCache {
    func image(for url: URL, provider: EmoteProvider = .kick) async -> UIImage? {
        await still(for: url, key: EmoteCacheKey.make(url: url, provider: provider))
    }
}

// MARK: - Frame cache

final class EmoteFrames: @unchecked Sendable {
    let images: [CGImage]
    let keyTimes: [NSNumber]
    let duration: CFTimeInterval
    init(images: [CGImage], keyTimes: [NSNumber], duration: CFTimeInterval) {
        self.images = images; self.keyTimes = keyTimes; self.duration = duration
    }
    var cost: Int { images.reduce(0) { $0 + $1.bytesPerRow * $1.height } }
}

actor EmoteFrameCache {
    static let shared = EmoteFrameCache()
    private let cache: NSCache<NSString, EmoteFrames> = {
        let c = NSCache<NSString, EmoteFrames>(); c.totalCostLimit = 48 * 1024 * 1024; return c
    }()
    private enum DecodeResult: Sendable {
        case animated(EmoteFrames), confirmedStatic, failure, cancelled
    }
    private struct Job {
        let id: UUID
        let task: Task<DecodeResult, Never>
    }
    private var negatives = EmoteNegativeCache()
    private var admission = EmoteDecodeAdmission()
    private var inFlight: [String: Job] = [:]

    func frames(for data: Data, key: String, maxPixel: Int = 112, maxFrames: Int = 150) async -> EmoteFrames? {
        guard !Task.isCancelled else { return nil }
        if let hit = cache.object(forKey: key as NSString) { return hit }
        if negatives.contains(key, now: ProcessInfo.processInfo.systemUptime) { return nil }
        let consumer = UUID()
        guard let lease = admission.admit(key: key, bytes: data.count, consumer: consumer) else { return nil }
        let job: Job
        if lease.isNew {
            let task = Task.detached(priority: .utility) {
                Self.decode(data, maxPixel: maxPixel, maxFrames: maxFrames)
            }
            job = Job(id: lease.id, task: task)
            inFlight[key] = job
        } else if let existing = inFlight[key] {
            job = existing
        } else { return nil }
        return await withTaskCancellationHandler {
            let result = await job.task.value
            if Task.isCancelled { cancel(key: key, id: job.id, consumer: consumer) }
            if inFlight[key]?.id == job.id {
                inFlight[key] = nil
                if admission.finish(key: key, id: job.id), !job.task.isCancelled {
                    switch result {
                    case .animated(let frames): cache.setObject(frames, forKey: key as NSString, cost: frames.cost)
                    case .confirmedStatic: negatives.insert(.confirmedStatic, key: key, now: ProcessInfo.processInfo.systemUptime)
                    case .failure: negatives.insert(.failure, key: key, now: ProcessInfo.processInfo.systemUptime)
                    case .cancelled: break
                    }
                }
            }
            guard !Task.isCancelled, !job.task.isCancelled, case .animated(let frames) = result else { return nil }
            return frames
        } onCancel: {
            Task { await self.cancel(key: key, id: job.id, consumer: consumer) }
        }
    }

    private func cancel(key: String, id: UUID, consumer: UUID) {
        if admission.release(key: key, id: id, consumer: consumer), inFlight[key]?.id == id {
            inFlight[key]?.task.cancel()
        }
    }

    func removeAll() {
        cache.removeAllObjects()
        negatives.removeAll()
        admission.invalidateConsumers()
        for job in inFlight.values { job.task.cancel() }
    }

    private static func decode(_ data: Data, maxPixel: Int, maxFrames: Int) -> DecodeResult {
        guard !Task.isCancelled else { return .cancelled }
        guard maxPixel > 0, maxFrames > 1,
              let src = CGImageSourceCreateWithData(data as CFData, nil) else { return .failure }
        let sourceCount = CGImageSourceGetCount(src)
        let count = min(sourceCount, maxFrames)
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceShouldCacheImmediately: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixel]
        if sourceCount == 1 {
            return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) == nil ? .failure : .confirmedStatic
        }
        guard count > 1 else { return .failure }
        var images: [CGImage] = []; var delays: [Double] = []
        for i in 0..<count {
            guard !Task.isCancelled else { return .cancelled }
            guard let img = CGImageSourceCreateThumbnailAtIndex(src, i, opts as CFDictionary) else { continue }
            images.append(img); delays.append(delay(src, i))
        }
        guard !Task.isCancelled else { return .cancelled }
        guard images.count > 1 else { return .failure }
        let total = delays.reduce(0, +)
        var t = 0.0; var keyTimes: [NSNumber] = []
        for d in delays { keyTimes.append(NSNumber(value: t / total)); t += d }
        keyTimes.append(1.0)
        return .animated(EmoteFrames(images: images, keyTimes: keyTimes, duration: total))
    }

    private static func delay(_ src: CGImageSource, _ i: Int) -> Double {
        let p = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
        let dict = (p?[kCGImagePropertyWebPDictionary] ?? p?[kCGImagePropertyGIFDictionary]) as? [CFString: Any]
        let unclamped = (dict?[kCGImagePropertyWebPUnclampedDelayTime] ?? dict?[kCGImagePropertyGIFUnclampedDelayTime]) as? Double
        let clamped = (dict?[kCGImagePropertyWebPDelayTime] ?? dict?[kCGImagePropertyGIFDelayTime]) as? Double
        let d = unclamped ?? clamped ?? 0.1
        return d < 0.02 ? 0.1 : d
    }
}
