import AVFoundation
import AVKit
import MediaPlayer
import SwiftUI
import KickUnblockCore
#if canImport(AmazonIVSPlayer)
import AmazonIVSPlayer
#endif
#if !canImport(AmazonIVSPlayer)
#error("Amazon IVS Player SDK required for live playback: run python3 Scripts/release_dependencies.py")
#endif

struct NowPlaying: Equatable {
    enum Kind: Equatable { case live, vod, clip }
    var kind: Kind
    var title: String
    var channelSlug: String
    var channelName: String
    var streamURL: URL?
    var embedSlug: String?
    var startOffset: Double = 0
    var thumbnailURL: URL?
    var artworkURL: URL? = nil
    var chat: ChatTarget?
    var savedItem: SavedClip?
    var knownDuration: Double?
    var vodReplay: VODChatReplayTarget? = nil
    var liveStartedAt: Date? = nil
    var liveBroadcastID: Int? = nil
}

@MainActor
final class PlaybackSession: NSObject, ObservableObject {
    enum Presentation { case closed, full, mini }

    @Published private(set) var player = AVPlayer()
    #if canImport(AmazonIVSPlayer)
    @Published private(set) var ivsPlayer = IVSPlayer()
    private var ivsTimeObserver: Any?
    static let ivsAvailable = true
    #else
    static let ivsAvailable = false
    #endif
    @Published private(set) var liveEngine: LiveEngine? {
        didSet {
            guard liveEngine != oldValue else { return }
            DispatchQueue.main.async { [weak self] in self?.renderHost.attach() }
        }
    }
    @Published private(set) var liveQualities: [LiveRendition] = []
    @Published private(set) var activeLiveQuality: LiveRendition?
    @Published private(set) var airPlayRouteActive = false
    private var ivsLoadGeneration: UInt64?
    private var ivsLoadedURL: URL?
    private(set) var sdkLiveLatency: Double?
    @Published private(set) var liveNotice: String?
    private var baselineDelay: Double?
    private var recordingURL: URL?
    private var recordingBroadcastID: Int?
    private var pendingRecording: (url: URL, time: Double)?
    private var recordingTask: Task<Void, Never>?
    private var recordingEndReloads = 0
    private var lastLiveLatency: Double?
    private var pausedLiveElapsed: Double?
    @Published var presentation: Presentation = .closed { didSet { updateIdleTimer() } }
    @Published private(set) var nowPlaying: NowPlaying?
    @Published private(set) var isPlaying = false
    @Published private(set) var stats = StreamStats()
    @Published private(set) var hideVideo = false
    @Published private(set) var isHoldingFrame = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var errorText: String?
    @Published var aspectFill = false
    @Published var theater = false
    @Published var isPiPActive = false
    @Published var isMuted = false { didSet { applyMute() } }
    @Published private(set) var variants: [HLSVariant] = []
    @Published private(set) var scrubRange: ScrubRange?
    @Published private(set) var sleepTimer: SleepTimerOption = .off
    @Published private(set) var sleepFireDate: Date?

    weak var pipController: AVPictureInPictureController?
    private(set) var pipHost: PlayerHostView?
    let renderHost = PlayerHostView()
    private var loadedPlan: QualityPlan?
    @Published private(set) var scrubUI = ScrubInteraction()
    @Published private(set) var isRejoiningLive = false
    @Published private(set) var userRewoundLive = false
    private var liveClock: LivePlaybackClock?
    @Published private(set) var isRecoveringLive = false
    var wantsPlayback: Bool { recoveryPolicy.wantsPlayback }
    private var recoveryPolicy = LiveRecoveryPolicy()
    private var audioInterruption = AudioInterruptionPolicy()
    private var needsAudioReload = false
    private var canStartPlayback: Bool { recoveryPolicy.wantsPlayback && !audioInterruption.isInterrupted }
    private var recoveryTask: Task<Void, Never>?
    private var isLoadingItem = false
    private var isSeekingItem = false
    private var recoveryProgressAnchor: Double?
    private var needsLiveRecovery = false
    private var intentionallyPausedAt: TimeInterval?
    private var loadTask: Task<Void, Never>?
    private var loadGeneration: UInt64 = 0
    private var seekGeneration: UInt64 = 0
    private var masterURL: URL?
    private var sleepTask: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var artworkLookupTask: Task<Void, Never>?
    private var playbackRequestID = UUID()
    private var endObs: NSObjectProtocol?
    var isScrubbing: Bool { scrubUI.isInteracting }
    private var timeObserver: Any?
    private var statsTimer: Timer?
    private var statusObs: NSKeyValueObservation?
    private var rateObs: NSKeyValueObservation?
    private var defaultsObs: NSObjectProtocol?
    private var stallCount = 0
    private let defaults = UserDefaults.standard

    override init() {
        super.init()
        installEngineObservers()
        airPlayRouteActive = Self.routeIsAirPlay()
        NotificationCenter.default.addObserver(self, selector: #selector(routeChanged), name: AVAudioSession.routeChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(audioInterrupted(_:)), name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(mediaServicesReset), name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
        defaultsObs = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyTweaks() }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(didEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        setupRemoteCommands()
    }

    private func installEngineObservers() {
        player.allowsExternalPlayback = true
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
        let observedAVPlayer = player
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self, weak observedAVPlayer] t in
            MainActor.assumeIsolated {
                guard let self, observedAVPlayer === self.player, self.player.currentItem != nil, !self.usesIVS else { return }
                self.currentTime = t.seconds.isFinite ? t.seconds : 0
                self.settleHeldSeek()
                self.refreshTimeline()
            }
        }
        rateObs = player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            Task { @MainActor in
                guard let self, p === self.player else { return }
                guard !self.usesIVS else { return }
                self.isPlaying = self.canStartPlayback && self.player.timeControlStatus != .paused
                self.updateIdleTimer()
                self.updateNowPlayingProgress()
            }
        }
        #if canImport(AmazonIVSPlayer)
        ivsPlayer.delegate = self
        let observedIVSPlayer = ivsPlayer
        ivsTimeObserver = ivsPlayer.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self, weak observedIVSPlayer] t in
            MainActor.assumeIsolated {
                guard let self, observedIVSPlayer === self.ivsPlayer, self.usesIVS,
                      self.ivsLoadGeneration == self.loadGeneration else { return }
                self.currentTime = t.seconds.isFinite ? t.seconds : 0
                self.settleHeldSeek()
                self.refreshTimeline()
            }
        }
        #endif
    }

    // MARK: tweaks

    var quality: QualityChoice {
        if isLive { return LiveQualityPolicy.initialChoice(storedPreference: defaults.string(forKey: PrefKey.preferredQuality)) }
        return QualityChoice(rawValue: defaults.string(PrefKey.preferredQuality, default: TweakDefault.quality))
    }
    var speed: Double { PlaybackSpeed.clamp(defaults.double(PrefKey.playbackSpeed, default: TweakDefault.speed)) }
    var seekInterval: Double { Double(defaults.int(PrefKey.seekInterval, default: TweakDefault.seek)) }
    var backgroundAudio: Bool { defaults.bool(PrefKey.backgroundAudio, default: TweakDefault.backgroundAudio) }
    var autoPiP: Bool { defaults.bool(PrefKey.autoPiP, default: TweakDefault.autoPiP) }
    var isLive: Bool { nowPlaying?.kind == .live }
    var usesIVS: Bool { isLive && liveEngine == .ivs }

    func applyTweaks() {
        if usesIVS {
            applyLiveQuality()
        } else if let item = player.currentItem {
            let next = QualitySelector.plan(for: quality, variants: variants)
            if let loadedPlan, next.needsReload(from: loadedPlan), let np = nowPlaying {
                if inRecording, let url = recordingURL { pendingRecording = (url, currentTime) }
                beginLoad(np, resumeAt: isLive ? nil : currentTime, refetchVariants: false)
                return
            }
            applyCaps(to: item)
        }
        if isPlaying, !isLive, abs(player.rate - Float(speed)) > 0.01 { player.rate = Float(speed) }
        pipController?.canStartPictureInPictureAutomaticallyFromInline = autoPiP && presentation == .full
        renderHost.attach()
        updateIdleTimer()
        updateNowPlayingProgress()
    }

    private func applyCaps(to item: AVPlayerItem) {
        let plan = QualitySelector.plan(for: quality, variants: variants)
        item.preferredMaximumResolution = CGSize(width: plan.maxResolution.width, height: plan.maxResolution.height)
        item.preferredPeakBitRate = plan.peakBitRate
        loadedPlan = plan
        hideVideo = plan.hideVideo
    }

    func setQuality(_ q: QualityChoice) { defaults.set(q.rawValue, forKey: PrefKey.preferredQuality) }
    func setSpeed(_ v: Double) { defaults.set(PlaybackSpeed.clamp(v), forKey: PrefKey.playbackSpeed) }
    var activeVariant: HLSVariant? { loadedPlan?.variant }

    var qualityPills: [QualityChoice] { usesIVS ? LiveQualityPolicy.pills(for: liveQualities) : QualityChoice.pills(for: variants) }
    func qualityLabel(_ q: QualityChoice) -> String {
        usesIVS ? LiveQualityPolicy.pillLabel(q, qualities: liveQualities) : q.pillLabel(variants: variants)
    }

    private func applyLiveQuality() {
        #if canImport(AmazonIVSPlayer)
        guard usesIVS else { return }
        let qualities = ivsPlayer.qualities
        liveQualities = qualities.map(Self.rendition)
        switch LiveQualityPolicy.decision(for: quality, qualities: liveQualities) {
        case .auto:
            if !ivsPlayer.autoQualityMode { ivsPlayer.autoQualityMode = true }
            activeLiveQuality = nil; hideVideo = false
        case .manual(let r):
            if let q = qualities.first(where: { Self.rendition($0) == r }),
               LiveQualityPolicy.needsFixedQuality(current: ivsPlayer.quality.map(Self.rendition), target: r, autoMode: ivsPlayer.autoQualityMode) {
                ivsPlayer.setQuality(q, adaptive: true)
            }
            activeLiveQuality = r; hideVideo = false
        case .audioOnly(let r):
            if let r, let q = qualities.first(where: { Self.rendition($0) == r }),
               LiveQualityPolicy.needsFixedQuality(current: ivsPlayer.quality.map(Self.rendition), target: r, autoMode: ivsPlayer.autoQualityMode) {
                ivsPlayer.setQuality(q, adaptive: true)
            }
            activeLiveQuality = r; hideVideo = true
        case .pending:
            hideVideo = false
        }
        #endif
    }

    #if canImport(AmazonIVSPlayer)
    private static func rendition(_ q: IVSQuality) -> LiveRendition {
        LiveRendition(name: q.name, bitrate: q.bitrate, width: q.width, height: q.height, framerate: Double(q.framerate))
    }
    #endif

    // MARK: playback

    func play(_ item: NowPlaying) {
        if presentation == .mini, let current = nowPlaying, isSameStream(current, item) {
            theater = false
            expand()
            return
        }
        needsAudioReload = false
        _ = AudioSession.activate()
        intentionallyPausedAt = nil
        playbackRequestID = UUID()
        artworkLookupTask?.cancel(); artworkLookupTask = nil
        recoveryPolicy.startSession(generation: loadGeneration)
        isRecoveringLive = false
        presentation = .full
        theater = false
        beginLoad(item, resumeAt: item.startOffset > 0 ? item.startOffset : nil)
    }

    private func isSameStream(_ a: NowPlaying, _ b: NowPlaying) -> Bool {
        guard a.kind == b.kind, a.channelSlug.lowercased() == b.channelSlug.lowercased() else { return false }
        switch a.kind {
        case .live: return a.liveBroadcastID == b.liveBroadcastID
        case .vod, .clip: return a.streamURL != nil && a.streamURL == b.streamURL
        }
    }

    private func beginLoad(_ item: NowPlaying, resumeAt: Double?, refetchVariants: Bool = true) {
        needsAudioReload = false
        clearAVItemObservers()
        loadTask?.cancel()
        recoveryTask?.cancel(); recoveryTask = nil
        loadGeneration &+= 1
        recoveryPolicy.beginLoad(generation: loadGeneration)
        isLoadingItem = true
        isSeekingItem = false
        recoveryProgressAnchor = nil
        needsLiveRecovery = false
        let generation = loadGeneration
        loadTask = Task { [weak self] in
            await self?.load(item, resumeAt: resumeAt, refetchVariants: refetchVariants, generation: generation)
        }
    }

    private func load(_ item: NowPlaying, resumeAt: Double?, refetchVariants: Bool, generation: UInt64) async {
        guard !Task.isCancelled, generation == loadGeneration else { return }
        defer { if generation == loadGeneration { isLoadingItem = false } }
        let sameItem = nowPlaying?.streamURL == item.streamURL
        let recording = item.kind == .live ? pendingRecording : nil
        pendingRecording = nil
        nowPlaying = item
        let engine: LiveEngine? = item.kind == .live
            ? (recording != nil ? .recording : LiveEnginePolicy.engine(sdkAvailable: Self.ivsAvailable, airPlayActive: airPlayRouteActive)) : nil
        if sameItem, let current = liveEngine, let engine, current != engine || engine == .recording { holdFrame() }
        liveEngine = engine
        errorText = nil
        stallCount = 0
        stats = StreamStats()
        if !sameItem { cancelSleepTimer() }
        scrubRange = ScrubTimeline.range(isLive: item.kind == .live, itemDuration: nil, seekable: [], knownDuration: item.knownDuration)
        liveClock = nil
        userRewoundLive = recording != nil
        liveNotice = nil
        scrubUI.reset()
        seekGeneration &+= 1
        duration = scrubRange?.end ?? 0
        let startAt = recording?.time ?? resumeAt
        currentTime = startAt ?? 0
        updateNowPlayingInfo()
        guard let url = recording?.url ?? item.streamURL else {
            player.replaceCurrentItem(with: nil)
            stopIVS()
            variants = []
            return
        }
        if usesIVS { loadIVS(url, generation: generation); return }
        stopIVS()
        if refetchVariants || masterURL != url {
            let fetched = await Self.fetchVariants(url)
            guard !Task.isCancelled, generation == loadGeneration else { return }
            variants = fetched
            masterURL = url
        }
        let plan = QualitySelector.plan(for: quality, variants: variants)
        let source = plan.variantURL ?? url
        let asset = recording.flatMap { RecordingLoader.shared.asset(for: source, startAt: $0.time) } ?? AVURLAsset(url: source)
        player.allowsExternalPlayback = true
        let playerItem = AVPlayerItem(asset: asset)
        applyCaps(to: playerItem)
        statusObs = playerItem.observe(\.status, options: [.new]) { [weak self] it, _ in
            let err = it.status == .failed ? (it.error?.localizedDescription ?? "Playback failed") : nil
            Task { @MainActor in
                guard let self, generation == self.loadGeneration, self.player.currentItem === it else { return }
                if let err {
                    if self.isLive { self.recoverLiveItem(generation: generation) }
                    else { self.errorText = err }
                }
            }
        }
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemPlaybackStalled, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(stalled(_:)), name: .AVPlayerItemPlaybackStalled, object: playerItem)
        NotificationCenter.default.removeObserver(self, name: AVPlayerItem.timeJumpedNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(timeJumped(_:)), name: AVPlayerItem.timeJumpedNotification, object: playerItem)
        if let endObs { NotificationCenter.default.removeObserver(endObs) }
        endObs = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: playerItem, queue: .main) { [weak self, weak playerItem] _ in
            MainActor.assumeIsolated {
                guard let self, let playerItem, generation == self.loadGeneration,
                      self.player.currentItem === playerItem else { return }
                if self.inRecording { self.recordingReachedEnd(); return }
                guard self.sleepTimer == .endOfVideo else { return }
                self.pausePlayback(); self.cancelSleepTimer()
            }
        }
        player.automaticallyWaitsToMinimizeStalling = true
        player.replaceCurrentItem(with: playerItem)
        if recording == nil, let t = startAt, t > 0 {
            await player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        guard !Task.isCancelled, generation == loadGeneration, player.currentItem === playerItem else { return }
        if canStartPlayback { player.playImmediately(atRate: isLive ? 1 : Float(speed)) }
        startStats()
        updateNowPlayingProgress()
    }

    private func loadIVS(_ url: URL, generation: UInt64) {
        player.replaceCurrentItem(with: nil)
        variants = []; masterURL = nil; loadedPlan = nil
        liveQualities = []; activeLiveQuality = nil; hideVideo = false
        baselineDelay = nil
        sdkLiveLatency = nil
        #if canImport(AmazonIVSPlayer)
        ivsLoadGeneration = generation
        ivsLoadedURL = url
        ivsPlayer.setLiveLowLatencyEnabled(true)
        ivsPlayer.autoQualityMode = true
        ivsPlayer.setRebufferToLive(LiveEdgePolicy.rebufferToLive(userRewound: false))
        ivsPlayer.setNetworkRecoveryMode(.resume)
        ivsPlayer.load(url)
        #endif
        startStats()
        updateNowPlayingProgress()
    }

    private func stopIVS() {
        #if canImport(AmazonIVSPlayer)
        guard ivsLoadGeneration != nil else { return }
        ivsLoadGeneration = nil
        ivsLoadedURL = nil
        ivsPlayer.pause()
        ivsPlayer.load(nil)
        #endif
        liveQualities = []; activeLiveQuality = nil
    }

    private var engineFailed: Bool {
        #if canImport(AmazonIVSPlayer)
        if usesIVS { return ivsPlayer.error != nil }
        #endif
        return player.currentItem?.status == .failed
    }

    private func enginePause() {
        #if canImport(AmazonIVSPlayer)
        ivsPlayer.pause()
        #endif
        player.pause()
    }

    private func enginePlay(atRate rate: Float) {
        guard canStartPlayback else { return }
        #if canImport(AmazonIVSPlayer)
        if usesIVS { ivsPlayer.play(); return }
        #endif
        player.playImmediately(atRate: rate)
    }

    static func fetchVariants(_ url: URL) async -> [HLSVariant] {
        var r = URLRequest(url: url)
        r.setValue(KickWebClient.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: r),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return M3U8MasterParser.parse(String(decoding: data, as: UTF8.self), base: url)
    }

    private func applyMute() {
        player.isMuted = isMuted
        #if canImport(AmazonIVSPlayer)
        ivsPlayer.muted = isMuted
        #endif
    }

    func togglePlay() {
        if isLive, errorText != nil { retryLivePlayback(); return }
        if recoveryPolicy.wantsPlayback { pausePlayback() } else { resumePlayback() }
    }

    private func pausePlayback() {
        objectWillChange.send()
        if recoveryPolicy.wantsPlayback {
            intentionallyPausedAt = ProcessInfo.processInfo.systemUptime
            pausedLiveElapsed = isLive && !inRecording && !isBehindLive ? liveEdgeElapsed : nil
        }
        recoveryPolicy.setPlaybackWanted(false)
        recoveryTask?.cancel(); recoveryTask = nil
        isRecoveringLive = false
        isRejoiningLive = false
        enginePause()
        updateNowPlayingProgress()
    }

    private func resumePlayback() {
        guard nowPlaying != nil, !recoveryPolicy.wantsPlayback else { return }
        guard !audioInterruption.isInterrupted, AudioSession.activate() else { return }
        objectWillChange.send()
        recoveryPolicy.setPlaybackWanted(true)
        airPlayRouteActive = Self.routeIsAirPlay()
        let needsRouteReload = isLive && Self.ivsAvailable && nowPlaying?.streamURL != nil
            && !inRecording && LiveEnginePolicy.engine(sdkAvailable: true, airPlayActive: airPlayRouteActive) != liveEngine
        if needsAudioReload || needsRouteReload, let np = nowPlaying {
            needsAudioReload = false
            if inRecording, let url = recordingURL {
                pendingRecording = (url, currentTime)
                beginLoad(np, resumeAt: nil, refetchVariants: false)
                return
            }
            isRejoiningLive = isLive
            beginLoad(np, resumeAt: isLive ? nil : currentTime)
            return
        }
        let pausedFor = intentionallyPausedAt.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0
        intentionallyPausedAt = nil
        let pausedAt = pausedLiveElapsed
        pausedLiveElapsed = nil
        if isLive, !inRecording, let pausedAt, LiveRewind.resumesFromRecording(pausedFor: pausedFor) {
            rewindIntoRecording(at: pausedAt)
            return
        }
        if errorText != nil, isLive { retryLivePlayback(); return }
        if isLive, needsLiveRecovery || engineFailed {
            recoverLiveItem(generation: loadGeneration)
            return
        }
        enginePlay(atRate: isLive ? 1 : Float(speed))
    }

    func retryLivePlayback() {
        guard isLive, nowPlaying != nil else { return }
        recoveryTask?.cancel(); recoveryTask = nil
        recoveryPolicy.startSession(generation: loadGeneration)
        recoveryPolicy.setPlaybackWanted(true)
        errorText = nil
        recoverLiveItem(generation: loadGeneration)
    }

    private func recoverLiveItem(generation: UInt64) {
        guard generation == loadGeneration, isLive, let current = nowPlaying else { return }
        if inRecording, let url = recordingURL, recordingEndReloads < 3 {
            recordingEndReloads += 1
            pendingRecording = (url, currentTime)
            beginLoad(current, resumeAt: nil, refetchVariants: false)
            return
        }
        needsLiveRecovery = true
        guard canStartPlayback else { return }
        guard let delay = recoveryPolicy.request(generation: generation) else {
            if recoveryPolicy.exhausted {
                isRecoveringLive = false
                isRejoiningLive = false
                errorText = "Live playback stopped. Retry playback."
                enginePause()
            }
            return
        }
        isRecoveringLive = true
        loadTask?.cancel()
        enginePause()
        recoveryTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self, !Task.isCancelled, generation == self.loadGeneration,
                      self.recoveryPolicy.canRecover(generation: generation) else { return }
                let channel = try await KickWebClient().channel(current.channelSlug)
                guard !Task.isCancelled, generation == self.loadGeneration,
                      self.recoveryPolicy.canRecover(generation: generation) else { return }
                guard let freshURL = channel.hlsURL,
                      let origin = BroadcastOriginRefresh.resolve(
                        currentStartedAt: current.liveStartedAt, currentBroadcastID: current.liveBroadcastID,
                        channel: channel, expectedSlug: current.channelSlug, expectedChannelID: current.chat?.channelID,
                        nowUTC: Date().timeIntervalSince1970) else {
                    throw KickWebError.offline("Channel is offline or its playback identity changed.")
                }
                var fresh = current
                fresh.streamURL = freshURL
                fresh.liveStartedAt = origin.startedAt
                fresh.liveBroadcastID = origin.broadcastID
                self.beginLoad(fresh, resumeAt: nil)
            } catch {
                guard let self, !Task.isCancelled, generation == self.loadGeneration,
                      self.recoveryPolicy.canRecover(generation: generation) else { return }
                self.recoveryTask = nil
                self.recoveryPolicy.beginLoad(generation: generation)
                self.recoverLiveItem(generation: generation)
            }
        }
    }

    func seek(by delta: Double) {
        if isLive {
            let held = scrubUI.isSeeking && !scrubUI.isDragging ? scrubUI.previewTime : nil
            guard let base = held ?? liveClockTime else { return }
            seekLive(toElapsed: base + delta)
            return
        }
        let base = scrubUI.isSeeking && !scrubUI.isDragging ? (scrubUI.previewTime ?? currentTime) : currentTime
        let target = base + delta
        let t = scrubRange.map { min($0.clamp(target), max($0.start, $0.end - 1)) } ?? max(0, target)
        seek(to: t)
    }

    func seek(to t: Double) {
        guard t.isFinite else { return }
        let id = scrubUI.beginSeek(to: t, range: displayScrubRange)
        performSeek(to: t, scrubID: id)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            self?.scrubUI.complete(id)
        }
    }

    private func settleHeldSeek() {
        guard scrubUI.isSeeking, !scrubUI.isDragging, let target = scrubUI.previewTime,
              abs(currentTime - target) <= 1.5 else { return }
        scrubUI.reset()
    }

    private func performSeek(to requested: Double, scrubID: UInt64? = nil) {
        guard requested.isFinite, let item = player.currentItem else {
            if let scrubID { scrubUI.complete(scrubID) }
            return
        }
        let t = scrubRange?.clamp(requested) ?? max(0, requested)
        if isLive { userRewoundLive = true }
        seekGeneration &+= 1
        let generation = seekGeneration
        isSeekingItem = true
        item.cancelPendingSeeks()
        let tol = isLive ? CMTime(seconds: 1, preferredTimescale: 600) : .zero
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: tol, toleranceAfter: tol) { [weak self, weak item] finished in
            Task { @MainActor in
                guard let self, let item, self.player.currentItem === item, generation == self.seekGeneration else { return }
                self.isSeekingItem = false
                if finished {
                    let actual = item.currentTime().seconds
                    if actual.isFinite { self.currentTime = actual }
                }
                if let scrubID { self.scrubUI.complete(scrubID) }
                self.refreshTimeline()
            }
        }
    }

    func scrubbing(fraction: Double, range: ScrubRange) {
        if !scrubUI.isDragging {
            seekGeneration &+= 1
            isSeekingItem = false
            player.currentItem?.cancelPendingSeeks()
        }
        scrubUI.update(fraction: fraction, range: range)
    }

    func cancelScrubbing() { scrubUI.cancelDrag() }

    func endScrubbing(fraction: Double) {
        if isLive {
            guard scrubUI.isDragging, let r = displayScrubRange, fraction.isFinite else { scrubUI.reset(); return }
            let target = r.time(atFraction: fraction)
            scrubUI.reset()
            seekLive(toElapsed: target)
            return
        }
        refreshTimeline()
        guard let range = scrubRange,
              let selection = scrubUI.release(fraction: fraction, latestRange: range) else { scrubUI.reset(); return }
        performSeek(to: selection.time, scrubID: selection.id)
    }

    private func refreshTimeline() {
        defer { updateNowPlayingProgress() }
        if usesIVS { refreshIVSTimeline(); return }
        let item = player.currentItem
        let seekable = item?.seekableTimeRanges.map { ($0.timeRangeValue.start.seconds, $0.timeRangeValue.duration.seconds) } ?? []
        let r = ScrubTimeline.range(isLive: isLive, itemDuration: item?.duration.seconds, seekable: seekable,
                                    knownDuration: nowPlaying?.knownDuration)
        if r != scrubRange { scrubRange = r }
        let d = isLive ? 0 : (r?.end ?? 0)
        if d != duration { duration = d }
        if isLive, !userRewoundLive, !scrubUI.isInteracting, player.timeControlStatus == .playing,
           let r, currentTime > r.start {
            if liveClock == nil {
                liveClock = LivePlaybackClock(mediaTime: currentTime, wallTime: ProcessInfo.processInfo.systemUptime)
            }
            if isRejoiningLive { isRejoiningLive = false }
        }
    }

    private func refreshIVSTimeline() {
        #if canImport(AmazonIVSPlayer)
        guard ivsLoadGeneration == loadGeneration else { return }
        let playing = ivsPlayer.state == .playing
        let delay = LiveViewerDelay.seconds(nowUTC: Date().timeIntervalSince1970, syncTime: ivsPlayer.syncTime.seconds)
        if playing, !isSeekingItem, let delay { baselineDelay = min(baselineDelay ?? delay, delay) }
        if scrubRange != nil { scrubRange = nil }
        if duration != 0 { duration = 0 }
        if playing, isRejoiningLive, !scrubUI.isInteracting { isRejoiningLive = false }
        #endif
    }

    nonisolated static func fetchPlaylistText(_ url: URL) async -> String? {
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        r.setValue(KickWebClient.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: r),
              (resp as? HTTPURLResponse)?.statusCode == 200, data.count <= 512 * 1024 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: sleep timer

    func setSleepTimer(_ option: SleepTimerOption) {
        cancelSleepTimer()
        sleepTimer = option
        guard let fire = option.fireDate(from: Date()) else { return }
        sleepFireDate = fire
        sleepTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, fire.timeIntervalSinceNow) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.pausePlayback(); self?.cancelSleepTimer() }
        }
    }

    private func cancelSleepTimer() {
        sleepTask?.cancel(); sleepTask = nil
        sleepTimer = .off; sleepFireDate = nil
    }

    var livePosition: Double {
        return liveClock?.position(at: ProcessInfo.processInfo.systemUptime) ?? max(currentTime, scrubRange?.end ?? 0)
    }

    var isBehindLive: Bool {
        if usesIVS {
            return !isRejoiningLive && LiveEdgePolicy.isBehind(userRewound: userRewoundLive, delay: stats.liveLatency, baseline: baselineDelay)
        }
        return isLive && !isRejoiningLive && (userRewoundLive || livePosition - currentTime > 6)
    }

    var displayScrubFraction: Double {
        if isLive {
            guard let r = displayScrubRange, r.length > 0 else { return 1 }
            if let p = scrubUI.previewTime, scrubUI.isInteracting { return min(max((p - r.start) / r.length, 0), 1) }
            guard inRecording, !isRejoiningLive else { return 1 }
            return min(max((currentTime - r.start) / r.length, 0), 1)
        }
        return LiveScrubPresentation.fraction(current: currentTime, range: displayScrubRange, interaction: scrubUI,
            isNaturalLive: false)
    }

    var displayScrubRange: ScrubRange? {
        guard isLive else { return scrubRange }
        guard let edge = liveEdgeElapsed, edge > 1 else { return nil }
        return ScrubRange(start: 0, end: edge)
    }

    // MARK: live rewind

    var inRecording: Bool { isLive && liveEngine == .recording }

    var liveEdgeElapsed: Double? {
        if usesIVS, let l = stats.liveLatency, l.isFinite, l > 0 { lastLiveLatency = l }
        return LiveRewind.edgeElapsed(now: Date(), startedAt: nowPlaying?.liveStartedAt, latency: lastLiveLatency)
    }

    var liveClockTime: Double? {
        guard isLive else { return nil }
        if let p = scrubUI.previewTime, scrubUI.isInteracting { return p }
        if inRecording, !isRejoiningLive { return currentTime }
        return liveEdgeElapsed
    }

    private func seekLive(toElapsed target: Double) {
        guard let edge = liveEdgeElapsed else { return }
        switch LiveRewind.action(target: target, liveEdge: edge, inRecording: inRecording, recordingEnd: scrubRange?.end) {
        case .stay: return
        case .goLive: goLive()
        case .seekRecording(let t):
            recordingEndReloads = 0
            seek(to: t)
        case .loadRecording(let t):
            rewindIntoRecording(at: t)
        }
    }

    private func rewindIntoRecording(at elapsed: Double) {
        guard isLive, let np = nowPlaying else { return }
        recoveryTask?.cancel(); recoveryTask = nil
        recordingTask?.cancel()
        recordingEndReloads = 0
        recoveryPolicy.setPlaybackWanted(true)
        let held = scrubUI.beginSeek(to: elapsed, range: displayScrubRange)
        recordingTask = Task { [weak self] in
            guard let self else { return }
            let url = await self.recordingSource(for: np)
            guard !Task.isCancelled, self.nowPlaying?.channelSlug == np.channelSlug else { return }
            guard let url else {
                self.scrubUI.complete(held)
                self.liveNotice = "Rewind isn't available for this stream yet."
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    if self?.liveNotice == "Rewind isn't available for this stream yet." { self?.liveNotice = nil }
                }
                return
            }
            let playable = await Self.recordingPlayableEnd(url)
            guard !Task.isCancelled, self.nowPlaying?.channelSlug == np.channelSlug else { return }
            self.pendingRecording = (url, playable.map { min(elapsed, $0) } ?? elapsed)
            self.isRejoiningLive = false
            self.beginLoad(np, resumeAt: nil, refetchVariants: true)
        }
    }

    private static func recordingPlayableEnd(_ master: URL) async -> Double? {
        guard let text = await fetchPlaylistText(master),
              let variant = M3U8MasterParser.parse(text, base: master).first(where: { !$0.isAudioOnly }),
              let media = await fetchPlaylistText(variant.uri) else { return nil }
        return RecordingPlaylist.playableEnd(media)
    }

    private func recordingSource(for np: NowPlaying) async -> URL? {
        if let url = recordingURL, recordingBroadcastID == np.liveBroadcastID { return url }
        guard let videos = try? await KickWebClient().videos(np.channelSlug),
              let url = LiveRewind.recordingURL(in: videos, broadcastID: np.liveBroadcastID) else { return nil }
        recordingURL = url
        recordingBroadcastID = np.liveBroadcastID
        return url
    }

    private func recordingReachedEnd() {
        guard inRecording, let np = nowPlaying, let url = recordingURL else { return }
        if recordingEndReloads >= 2 { goLive(); return }
        recordingEndReloads += 1
        let at = currentTime
        recordingTask?.cancel()
        recordingTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self, !Task.isCancelled, self.inRecording, self.nowPlaying?.channelSlug == np.channelSlug else { return }
            self.pendingRecording = (url, at)
            self.beginLoad(np, resumeAt: nil, refetchVariants: false)
        }
    }

    @discardableResult
    func goLive() -> Bool {
        guard isLive, let np = nowPlaying, !(isRejoiningLive && isLoadingItem) else { return false }
        recordingTask?.cancel(); recordingTask = nil
        pendingRecording = nil
        recoveryPolicy.setPlaybackWanted(true)
        isRejoiningLive = true
        beginLoad(np, resumeAt: nil, refetchVariants: false)
        return true
    }

    func minimize() { if nowPlaying != nil { presentation = .mini } }
    func expand() { if nowPlaying != nil { presentation = .full } }

    private func clearAVItemObservers() {
        statusObs?.invalidate(); statusObs = nil
        if let endObs { NotificationCenter.default.removeObserver(endObs) }
        self.endObs = nil
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemPlaybackStalled, object: nil)
        NotificationCenter.default.removeObserver(self, name: AVPlayerItem.timeJumpedNotification, object: nil)
    }

    func close() {
        retirePiP()
        clearAVItemObservers()
        needsAudioReload = false
        playbackRequestID = UUID()
        artworkLookupTask?.cancel(); artworkLookupTask = nil
        pausePlayback()
        loadTask?.cancel(); loadTask = nil
        isLoadingItem = false; isSeekingItem = false
        loadGeneration &+= 1; seekGeneration &+= 1
        liveClock = nil; isRejoiningLive = false; userRewoundLive = false
        recordingTask?.cancel(); recordingTask = nil
        pendingRecording = nil; recordingURL = nil; recordingBroadcastID = nil; pausedLiveElapsed = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        stopIVS()
        liveEngine = nil
        nowPlaying = nil
        presentation = .closed
        variants = []; scrubRange = nil; masterURL = nil
        cancelSleepTimer()
        statsTimer?.invalidate(); statsTimer = nil
        scrubUI.reset()
        artworkTask?.cancel(); artworkTask = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        updateIdleTimer()
    }

    func registerPiP(_ controller: AVPictureInPictureController, owner: PlayerHostView) {
        if let prior = pipHost, prior !== owner { retirePiP() }
        pipHost = owner
        pipController = controller
    }

    func retirePiP() {
        let owner = pipHost
        pipHost = nil
        pipController = nil
        isPiPActive = false
        owner?.retirePiP()
        if owner !== renderHost { renderHost.retirePiP() }
    }

    func startPiP() { renderHost.requestPiP() }

    func setPlayingFromPiP(_ playing: Bool) {
        if playing { resumePlayback() } else { pausePlayback() }
        renderHost.invalidatePiPPlayback()
    }

    func skipFromPiP(_ seconds: Double) {
        guard seconds.isFinite, seconds != 0 else { return }
        seek(by: seconds)
    }

    private func holdFrame() {
        renderHost.freezeFrame()
        isHoldingFrame = renderHost.isFrozen
    }

    func frameReleased() { if isHoldingFrame { isHoldingFrame = false } }

    var currentStreamURL: URL? {
        if isLive { return nowPlaying?.streamURL }
        return (player.currentItem?.asset as? AVURLAsset)?.url ?? nowPlaying?.streamURL
    }

    var canStartPiP: Bool { AVPictureInPictureController.isPictureInPictureSupported() && (pipController?.isPictureInPicturePossible ?? !autoPiP) }

    static func routeIsAirPlay() -> Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .airPlay }
    }

    @objc private func routeChanged() {
        Task { @MainActor in
            let active = Self.routeIsAirPlay()
            guard active != self.airPlayRouteActive else { return }
            self.airPlayRouteActive = active
            guard !self.needsAudioReload, self.canStartPlayback,
                  self.isLive, let np = self.nowPlaying, np.streamURL != nil, Self.ivsAvailable,
                  !self.inRecording && LiveEnginePolicy.engine(sdkAvailable: true, airPlayActive: active) != self.liveEngine else { return }
            self.isRejoiningLive = true
            self.beginLoad(np, resumeAt: nil)
        }
    }

    @objc private func timeJumped(_ notification: Notification) {
        guard let item = notification.object as? AVPlayerItem else { return }
        Task { @MainActor in
            guard item === self.player.currentItem, self.isPiPActive, self.inRecording,
                  !self.isLoadingItem, !self.isSeekingItem,
                  let end = item.seekableTimeRanges.last?.timeRangeValue.end.seconds, end.isFinite else { return }
            let t = item.currentTime().seconds
            if LiveRewind.skippedPastRecording(from: self.currentTime, to: t, recordingEnd: end) { self.goLive() }
        }
    }

    @objc private func stalled(_ notification: Notification) {
        guard let item = notification.object as? AVPlayerItem, player.currentItem === item else { return }
        stallCount += 1
    }

    @objc private func audioInterrupted(_ notification: Notification) {
        guard let raw = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            audioInterruption.begin(wantsPlayback: recoveryPolicy.wantsPlayback)
            recoveryTask?.cancel(); recoveryTask = nil
            recoveryPolicy.setPlaybackWanted(recoveryPolicy.wantsPlayback)
            isRecoveringLive = false; isRejoiningLive = false
            enginePause()
            isPlaying = false
            updateIdleTimer()
            updateNowPlayingProgress()
        case .ended:
            guard audioInterruption.isInterrupted else { return }
            let rawOptions = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? NSNumber)?.uintValue ?? 0
            let allowed = AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
            let resume = audioInterruption.end(shouldResume: allowed, wantsPlayback: recoveryPolicy.wantsPlayback)
            guard resume, !needsAudioReload, let np = nowPlaying, AudioSession.activate() else {
                pausePlayback()
                return
            }
            airPlayRouteActive = Self.routeIsAirPlay()
            if isLive, Self.ivsAvailable, np.streamURL != nil,
               !inRecording && LiveEnginePolicy.engine(sdkAvailable: true, airPlayActive: airPlayRouteActive) != liveEngine {
                isRejoiningLive = true
                beginLoad(np, resumeAt: nil)
                return
            }
            if isLive, needsLiveRecovery || engineFailed { recoverLiveItem(generation: loadGeneration) }
            else { enginePlay(atRate: isLive ? 1 : Float(speed)) }
        @unknown default:
            break
        }
    }

    @objc private func mediaServicesReset() {
        pausePlayback()
        retirePiP()
        audioInterruption.reset()
        loadTask?.cancel(); loadTask = nil
        loadGeneration &+= 1; seekGeneration &+= 1
        recoveryPolicy.beginLoad(generation: loadGeneration)
        isLoadingItem = false; isSeekingItem = false
        clearAVItemObservers()
        statsTimer?.invalidate(); statsTimer = nil
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        rateObs?.invalidate(); rateObs = nil
        player.replaceCurrentItem(with: nil)
        stopIVS()
        #if canImport(AmazonIVSPlayer)
        ivsPlayer.delegate = nil
        if let ivsTimeObserver { ivsPlayer.removeTimeObserver(ivsTimeObserver) }
        ivsTimeObserver = nil
        ivsPlayer = IVSPlayer()
        #endif
        player = AVPlayer()
        applyMute()
        installEngineObservers()
        needsAudioReload = nowPlaying != nil
        liveClock = nil; scrubRange = nil; scrubUI.reset()
        isPlaying = false
        AudioSession.configure(activate: false)
        updateIdleTimer()
        updateNowPlayingProgress()
    }

    @objc private func didEnterBackground() {
        Task { @MainActor in
            if !self.backgroundAudio && !self.isPiPActive && !self.renderHost.pipWillStartOnExit { self.pausePlayback() }
        }
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = isPlaying && presentation == .full
            && defaults.bool(PrefKey.keepAwake, default: TweakDefault.keepAwake)
    }

    // MARK: inspector

    private func startStats() {
        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleStats() }
        }
    }

    private func sampleStats() {
        if usesIVS {
            sampleIVSStats()
            if isPiPActive { renderHost.invalidatePiPPlayback() }
            return
        }
        guard let item = player.currentItem else { return }
        let mediaTime = item.currentTime().seconds
        let eligible = isLive && !audioInterruption.isInterrupted && !isLoadingItem && !isSeekingItem && !isScrubbing
        if recoveryPolicy.noProgress(mediaTime: mediaTime, now: ProcessInfo.processInfo.systemUptime, eligible: eligible) {
            recoverLiveItem(generation: loadGeneration)
        } else if isRecoveringLive, !recoveryPolicy.pending, !isLoadingItem,
                  player.timeControlStatus == .playing, mediaTime.isFinite {
            if let previous = recoveryProgressAnchor, mediaTime > previous + 0.25 {
                isRecoveringLive = false
            }
            recoveryProgressAnchor = mediaTime
        }
        var s = StreamStats()
        s.width = Int(item.presentationSize.width); s.height = Int(item.presentationSize.height)
        if let ev = item.accessLog()?.events.last {
            s.observedBitrate = ev.observedBitrate
            s.indicatedBitrate = ev.indicatedBitrate
            s.droppedFrames = max(0, ev.numberOfDroppedVideoFrames)
        }
        s.fps = item.tracks.compactMap { $0.currentVideoFrameRate > 0 ? Double($0.currentVideoFrameRate) : nil }.first
        s.bufferAhead = StreamStats.bufferAhead(
            ranges: item.loadedTimeRanges.map { ($0.timeRangeValue.start.seconds, $0.timeRangeValue.duration.seconds) },
            current: item.currentTime().seconds)
        s.stalls = stallCount
        if isLive, let date = item.currentDate() { s.liveLatency = (Date().timeIntervalSince(date) * 10).rounded() / 10 }
        if s != stats { stats = s }
    }

    private func sampleIVSStats() {
        #if canImport(AmazonIVSPlayer)
        guard ivsLoadGeneration == loadGeneration else { return }
        let p = ivsPlayer
        let mediaTime = p.position.seconds
        let eligible = !audioInterruption.isInterrupted && !isLoadingItem && !isSeekingItem && !isScrubbing
        if recoveryPolicy.noProgress(mediaTime: mediaTime, now: ProcessInfo.processInfo.systemUptime, eligible: eligible) {
            recoverLiveItem(generation: loadGeneration)
        } else if isRecoveringLive, !recoveryPolicy.pending, !isLoadingItem, p.state == .playing, mediaTime.isFinite {
            if let previous = recoveryProgressAnchor, mediaTime > previous + 0.25 { isRecoveringLive = false }
            recoveryProgressAnchor = mediaTime
        }
        var s = StreamStats()
        s.width = Int(p.videoSize.width); s.height = Int(p.videoSize.height)
        s.observedBitrate = p.bandwidthEstimate > 0 ? Double(p.bandwidthEstimate) : nil
        s.indicatedBitrate = p.videoBitrate > 0 ? Double(p.videoBitrate) : nil
        s.droppedFrames = max(0, p.videoFramesDropped)
        if let q = p.quality, q.framerate > 0 { s.fps = Double(q.framerate) }
        let buffered = p.buffered.seconds
        s.bufferAhead = buffered.isFinite ? max(0, buffered) : 0
        s.stalls = stallCount
        s.liveLatency = LiveViewerDelay.seconds(nowUTC: Date().timeIntervalSince1970, syncTime: p.syncTime.seconds)
        sdkLiveLatency = LiveEdgePolicy.measuredDelay(p.liveLatency.seconds)
        if s != stats { stats = s }
        #endif
    }

    // MARK: lock screen

    private func updateNowPlayingProgress() {
        guard nowPlaying != nil, var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        var advancing = player.timeControlStatus == .playing
        var rate = Double(player.rate)
        #if canImport(AmazonIVSPlayer)
        if usesIVS { advancing = ivsLoadGeneration == loadGeneration && ivsPlayer.state == .playing; rate = 1 }
        #endif
        let progress = NowPlayingProgress(isLive: isLive, advancing: advancing,
            playbackAllowed: canStartPlayback && !needsAudioReload && !isLoadingItem && !isRecoveringLive && !isSeekingItem,
            engineRate: rate, position: currentTime, duration: duration > 0 ? duration : nowPlaying?.knownDuration)
        info[MPNowPlayingInfoPropertyPlaybackRate] = progress.rate
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = progress.elapsed
        info[MPMediaItemPropertyPlaybackDuration] = progress.duration
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.resumePlayback() }; return .success }
        c.pauseCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.pausePlayback() }; return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.togglePlay() }; return .success }
    }

    func resolveChannelArtwork(using lookup: @escaping @MainActor () async -> URL?) {
        artworkLookupTask?.cancel()
        let requestID = playbackRequestID
        let pendingLoad = loadTask
        artworkLookupTask = Task { [weak self] in
            await pendingLoad?.value
            guard let self, !Task.isCancelled, requestID == self.playbackRequestID,
                  self.nowPlaying != nil, self.nowPlaying?.artworkURL == nil else { return }
            let url = await lookup()
            guard !Task.isCancelled, requestID == self.playbackRequestID,
                  let url, self.nowPlaying != nil, self.nowPlaying?.artworkURL == nil else { return }
            self.nowPlaying?.artworkURL = url
            self.updateNowPlayingInfo()
        }
    }

    private func updateNowPlayingInfo() {
        guard let np = nowPlaying else { return }
        let info: [String: Any] = [
            MPMediaItemPropertyTitle: np.title,
            MPMediaItemPropertyArtist: np.channelName,
            MPNowPlayingInfoPropertyIsLiveStream: np.kind == .live,
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        updateNowPlayingProgress()
        artworkTask?.cancel()
        guard let url = np.artworkURL else { return }
        artworkTask = Task { [weak self] in
            var r = URLRequest(url: url)
            r.setValue(KickWebClient.userAgent, forHTTPHeaderField: "User-Agent")
            guard let (data, resp) = try? await URLSession.shared.data(for: r),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let image = UIImage(data: data), !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, !Task.isCancelled, self.nowPlaying?.channelSlug == np.channelSlug,
                      self.nowPlaying?.artworkURL == url,
                      var current = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
                current[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                MPNowPlayingInfoCenter.default().nowPlayingInfo = current
            }
        }
    }
}

#if canImport(AmazonIVSPlayer)
extension PlaybackSession: IVSPlayer.Delegate {
    nonisolated func player(_ player: IVSPlayer, didChangeState state: IVSPlayer.State) {
        MainActor.assumeIsolated { self.ivsStateChanged(state, player: player) }
    }
    nonisolated func player(_ player: IVSPlayer, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            guard player === self.ivsPlayer, let g = self.ivsLoadGeneration,
                  LiveCallbackGate.accepts(.error(playerHasError: player.error != nil), self.ivsCallbackContext(player)) else { return }
            self.recoverLiveItem(generation: g)
        }
    }
    nonisolated func playerWillRebuffer(_ player: IVSPlayer) {
        MainActor.assumeIsolated {
            guard player === self.ivsPlayer, LiveCallbackGate.accepts(.rebuffer, self.ivsCallbackContext(player)) else { return }
            self.stallCount += 1
        }
    }
    nonisolated func player(_ player: IVSPlayer, didChangeQuality quality: IVSQuality?) {
        MainActor.assumeIsolated {
            let matches = quality.map(Self.rendition) == player.quality.map(Self.rendition)
            guard player === self.ivsPlayer,
                  LiveCallbackGate.accepts(.quality(matchesPlayer: matches), self.ivsCallbackContext(player)) else { return }
            if !player.autoQualityMode, let quality { self.activeLiveQuality = Self.rendition(quality) }
        }
    }
}

extension PlaybackSession {
    private func ivsCallbackContext(_ player: IVSPlayer) -> LiveCallbackContext {
        LiveCallbackContext(engineIsIVS: usesIVS, boundGeneration: ivsLoadGeneration, currentGeneration: loadGeneration,
                            expectedPath: ivsLoadedURL, playerPath: player.path)
    }

    private func ivsStateChanged(_ state: IVSPlayer.State, player: IVSPlayer) {
        let event: LiveCallbackEvent = state == .ended ? .endedState(playerStillEnded: player.state == .ended) : .benignState
        guard player === ivsPlayer, let g = ivsLoadGeneration,
              LiveCallbackGate.accepts(event, ivsCallbackContext(player)) else { return }
        switch state {
        case .ready:
            isPlaying = false
            applyLiveQuality()
            if canStartPlayback { ivsPlayer.play() }
        case .playing:
            renderHost.thaw()
            if !canStartPlayback { ivsPlayer.pause() }
            isPlaying = canStartPlayback
            refreshIVSTimeline()
        case .buffering:
            isPlaying = canStartPlayback
        case .ended:
            isPlaying = false
            recoverLiveItem(generation: g)
        case .idle:
            isPlaying = false
        @unknown default:
            break
        }
        pipController?.canStartPictureInPictureAutomaticallyFromInline = autoPiP && presentation == .full
        updateIdleTimer()
        updateNowPlayingProgress()
    }
}
#endif

extension PlaybackSession: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ c: AVPictureInPictureController) {
        Task { @MainActor [weak self] in
            guard let self, c === self.pipController else { return }
            self.renderHost.reattach()
        }
    }
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) {
        Task { @MainActor [weak self] in
            guard let self, c === self.pipController else { return }
            self.isPiPActive = true
            self.renderHost.reattach()
        }
    }
    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        Task { @MainActor [weak self] in
            guard let self, c === self.pipController else { return }
            self.isPiPActive = false
            self.renderHost.attach()
        }
    }
    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController,
                                                restoreUserInterfaceForPictureInPictureStopWithCompletionHandler done: @escaping (Bool) -> Void) {
        Task { @MainActor [weak self] in
            guard let self, c === self.pipController else { done(false); return }
            self.presentation = .full
            done(true)
        }
    }
}
