import AVKit
import OSLog
import SwiftUI
#if canImport(AmazonIVSPlayer)
import AmazonIVSPlayer
#endif

struct PlayerLayerView: UIViewRepresentable {
    @EnvironmentObject var session: PlaybackSession
    var aspectFill: Bool
    var enablePiP: Bool

    func makeUIView(context: Context) -> PlayerMountView {
        let v = PlayerMountView()
        v.backgroundColor = .black
        v.update(session: session, aspectFill: aspectFill, enablePiP: enablePiP)
        return v
    }

    func updateUIView(_ v: PlayerMountView, context: Context) {
        v.update(session: session, aspectFill: aspectFill, enablePiP: enablePiP)
    }

    static func dismantleUIView(_ v: PlayerMountView, coordinator: ()) {
        MainActor.assumeIsolated {
            v.hasYieldedSurface = true
            guard let host = v.session?.renderHost, host.superview === v else { return }
            host.isDismantled = true
            host.removeFromSuperview()
            host.waitingMount?.adoptWaitingSurface()
        }
    }
}

final class PlayerMountView: UIView {
    weak var session: PlaybackSession?
    var hasYieldedSurface = false
    private var aspectFill = false
    private(set) var enablePiP = false
    private var placeholder: UIView?

    func update(session s: PlaybackSession, aspectFill: Bool, enablePiP: Bool) {
        MainActor.assumeIsolated {
            session = s
            self.aspectFill = aspectFill
            self.enablePiP = enablePiP
            guard !hasYieldedSurface, s.presentation == (enablePiP ? .full : .mini) else { return }
            let host = s.renderHost
            if host.superview !== self, !enablePiP, let current = host.superview as? PlayerMountView,
               !current.hasYieldedSurface, current.window != nil {
                host.waitingMount = self
                showPlaceholder(of: host)
                return
            }
            host.session = s
            host.isDismantled = false
            host.enablePiP = enablePiP
            let gravity: AVLayerVideoGravity = aspectFill ? .resizeAspectFill : .resizeAspect
            CATransaction.begin(); CATransaction.setDisableActions(true)
            if host.superview !== self {
                (host.superview as? PlayerMountView)?.hasYieldedSurface = true
                host.waitingMount = nil
                addSubview(host)
                placeholder?.removeFromSuperview()
                placeholder = nil
            }
            host.frame = bounds
            host.playerLayer.videoGravity = gravity
            #if canImport(AmazonIVSPlayer)
            host.ivsLayer.videoGravity = gravity
            #endif
            host.setNeedsLayout()
            host.layoutIfNeeded()
            CATransaction.commit()
            host.attach()
        }
    }

    private func showPlaceholder(of host: PlayerHostView) {
        guard placeholder == nil, bounds.width > 1, host.bounds.width > 1,
              let shot = host.snapshotView(afterScreenUpdates: false) else { return }
        let scale = max(bounds.width / host.bounds.width, bounds.height / host.bounds.height)
        shot.isUserInteractionEnabled = false
        shot.transform = CGAffineTransform(scaleX: scale, y: scale)
        shot.center = CGPoint(x: bounds.midX, y: bounds.midY)
        addSubview(shot)
        placeholder = shot
    }

    func adoptWaitingSurface() {
        guard let s = session else { return }
        update(session: s, aspectFill: aspectFill, enablePiP: enablePiP)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window == nil else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.window == nil, let host = self.session?.renderHost,
                      host.superview === self else { return }
                host.waitingMount?.adoptWaitingSurface()
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        MainActor.assumeIsolated {
            guard let host = session?.renderHost else { return }
            if host.waitingMount === self {
                if let placeholder { placeholder.center = CGPoint(x: bounds.midX, y: bounds.midY) } else { showPlaceholder(of: host) }
            }
            guard host.superview === self else { return }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            host.frame = bounds
            host.setNeedsLayout()
            host.layoutIfNeeded()
            CATransaction.commit()
        }
    }
}

final class PlayerHostView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    #if canImport(AmazonIVSPlayer)
    let ivsLayer = IVSPlayerLayer()
    #endif
    var pip: AVPictureInPictureController?
    private var pipUsesIVS: Bool?
    private var avSource: AVPictureInPictureController.ContentSource?
    private var ivsSource: AVPictureInPictureController.ContentSource?
    private var livePlayback: AnyObject?
    private var frozen: UIView?
    private var freezeToken: UUID?
    private var readyObs: NSKeyValueObservation?
    private var possibleObs: NSKeyValueObservation?
    private var pipRequested = false
    private var backgroundDetached = false
    var enablePiP = false
    var isDismantled = false
    weak var session: PlaybackSession?
    weak var waitingMount: PlayerMountView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        #if canImport(AmazonIVSPlayer)
        layer.addSublayer(ivsLayer)
        #endif
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(background), name: UIApplication.didEnterBackgroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(foreground), name: UIApplication.willEnterForegroundNotification, object: nil)
        observeReadiness()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        #if canImport(AmazonIVSPlayer)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        ivsLayer.frame = bounds
        CATransaction.commit()
        #endif
    }

    func attach() {
        guard !isDismantled, !backgroundDetached, let s = session else { return }
        MainActor.assumeIsolated {
            let ivs = s.usesIVS
            #if canImport(AmazonIVSPlayer)
            if ivs {
                if ivsLayer.player !== s.ivsPlayer { ivsLayer.player = s.ivsPlayer }
                if playerLayer.player != nil { playerLayer.player = nil }
            } else {
                if ivsLayer.player != nil { ivsLayer.player = nil }
                if playerLayer.player !== s.player { playerLayer.player = s.player }
            }
            ivsLayer.isHidden = !ivs
            #else
            if playerLayer.player !== s.player { playerLayer.player = s.player }
            #endif
            let active = pip?.isPictureInPictureActive == true
            if active { pipRequested = false }
            let keep = active || s.autoPiP || pipRequested
            if pip != nil, !keep { dropPiP() }
            if let pip, !active {
                pip.canStartPictureInPictureAutomaticallyFromInline = s.autoPiP && enablePiP
            }
            guard AVPictureInPictureController.isPictureInPictureSupported(), keep, pipUsesIVS != ivs,
                  enablePiP || active, let source = contentSource(ivs: ivs) else { return }
            pipUsesIVS = ivs
            if let pip {
                pip.contentSource = source
                return
            }
            let next = AVPictureInPictureController(contentSource: source)
            pip = next
            next.delegate = s
            next.canStartPictureInPictureAutomaticallyFromInline = s.autoPiP && enablePiP
            s.registerPiP(next, owner: self)
        }
    }

    private func contentSource(ivs: Bool) -> AVPictureInPictureController.ContentSource? {
        #if canImport(AmazonIVSPlayer)
        if ivs {
            if ivsSource == nil, let base = AVPictureInPictureController.ContentSource(ivsPlayerLayer: ivsLayer) {
                if let layer = base.sampleBufferDisplayLayer, let inner = base.sampleBufferPlaybackDelegate, let session {
                    let playback = LivePiPPlayback(inner: inner, base: base, session: session)
                    livePlayback = playback
                    ivsSource = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: layer, playbackDelegate: playback)
                } else {
                    ivsSource = base
                }
            }
            return ivsSource
        }
        #endif
        if avSource == nil { avSource = AVPictureInPictureController.ContentSource(playerLayer: playerLayer) }
        return avSource
    }

    func invalidatePiPPlayback() { pip?.invalidatePlaybackState() }

    func requestPiP() {
        if let pip, pip.isPictureInPicturePossible { pip.startPictureInPicture(); return }
        pipRequested = true
        attach()
        guard let pip else { pipRequested = false; return }
        possibleObs = pip.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] c, _ in
            guard c.isPictureInPicturePossible else { return }
            DispatchQueue.main.async {
                guard let self, self.pip === c, self.pipRequested, self.possibleObs != nil else { return }
                self.possibleObs = nil
                c.startPictureInPicture()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.pipRequested else { return }
            self.pipRequested = false
            self.possibleObs = nil
            self.attach()
        }
    }

    func freezeFrame() {
        guard frozen == nil, window != nil, bounds.width > 1,
              UIApplication.shared.applicationState == .active,
              pip?.isPictureInPictureActive != true,
              let shot = snapshotView(afterScreenUpdates: false) else { return }
        shot.frame = bounds
        shot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        shot.isUserInteractionEnabled = false
        addSubview(shot)
        frozen = shot
        let token = UUID()
        freezeToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.freezeToken == token else { return }
            self.thaw()
        }
    }

    var isFrozen: Bool { frozen != nil }

    func thaw() {
        guard let shot = frozen else { return }
        frozen = nil
        freezeToken = nil
        session?.frameReleased()
        UIView.animate(withDuration: 0.2, animations: { shot.alpha = 0 }, completion: { _ in shot.removeFromSuperview() })
    }

    private func observeReadiness() {
        readyObs = playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] layer, _ in
            guard layer.isReadyForDisplay else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.frozen != nil, self.session?.usesIVS == false,
                          self.playerLayer.player === self.session?.player else { return }
                    self.thaw()
                }
            }
        }
    }

    func retirePiP() {
        thaw()
        let old = pip
        pipRequested = false
        dropPiP()
        if old?.isPictureInPictureActive == true { old?.stopPictureInPicture() }
        detach()
    }

    private func dropPiP() {
        pip?.canStartPictureInPictureAutomaticallyFromInline = false
        pip?.delegate = nil
        pip = nil
        possibleObs = nil
        pipUsesIVS = nil
        avSource = nil
        ivsSource = nil
        livePlayback = nil
    }

    func detach() {
        playerLayer.player = nil
        #if canImport(AmazonIVSPlayer)
        ivsLayer.player = nil
        #endif
    }

    var pipWillStartOnExit: Bool {
        guard let pip else { return false }
        return pip.isPictureInPictureActive || (pip.canStartPictureInPictureAutomaticallyFromInline && pip.isPictureInPicturePossible)
    }

    @objc private func background() {
        guard let s = session else { return }
        let keepAudio = MainActor.assumeIsolated { s.backgroundAudio && !s.isPiPActive }
        guard keepAudio else { return }
        guard pipWillStartOnExit else { backgroundDetach(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, UIApplication.shared.applicationState == .background,
                  self.pip?.isPictureInPictureActive != true else { return }
            self.backgroundDetach()
        }
    }

    private func backgroundDetach() {
        backgroundDetached = true
        playerLayer.player = nil
    }

    func reattach() {
        backgroundDetached = false
        attach()
    }

    @objc private func foreground() { reattach() }
}

final class LivePiPPlayback: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate {
    private let inner: AVPictureInPictureSampleBufferPlaybackDelegate
    private let base: AVPictureInPictureController.ContentSource
    private weak var session: PlaybackSession?

    init(inner: AVPictureInPictureSampleBufferPlaybackDelegate, base: AVPictureInPictureController.ContentSource, session: PlaybackSession) {
        self.inner = inner
        self.base = base
        self.session = session
    }

    private func onMain(_ work: @escaping @MainActor (PlaybackSession) -> Void) {
        let run = { [weak self] in MainActor.assumeIsolated { if let s = self?.session { work(s) } } }
        if Thread.isMainThread { run() } else { DispatchQueue.main.async(execute: run) }
    }

    func pictureInPictureController(_ c: AVPictureInPictureController, setPlaying playing: Bool) {
        onMain { $0.setPlayingFromPiP(playing) }
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ c: AVPictureInPictureController) -> CMTimeRange {
        if let window = liveWindow() { return window }
        let range = inner.pictureInPictureControllerTimeRangeForPlayback(c)
        return range.isValid ? range : CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    private func liveWindow() -> CMTimeRange? {
        guard Thread.isMainThread, let timebase = base.sampleBufferDisplayLayer?.sampleBufferRenderer.timebase,
              let span = MainActor.assumeIsolated({ session?.liveEdgeElapsed }), span.isFinite, span > 15 else { return nil }
        let now = timebase.time
        guard now.isNumeric else { return nil }
        return CMTimeRange(start: now - CMTime(seconds: span, preferredTimescale: 600),
                           end: now + CMTime(seconds: 2, preferredTimescale: 600))
    }

    func pictureInPictureControllerIsPlaybackPaused(_ c: AVPictureInPictureController) -> Bool {
        guard Thread.isMainThread else { return inner.pictureInPictureControllerIsPlaybackPaused(c) }
        return MainActor.assumeIsolated { !(session?.wantsPlayback ?? false) }
    }

    func pictureInPictureController(_ c: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        inner.pictureInPictureController(c, didTransitionToRenderSize: newRenderSize)
    }

    func pictureInPictureController(_ c: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion: @escaping () -> Void) {
        onMain { $0.skipFromPiP(skipInterval.seconds) }
        completion()
    }

    func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(_ c: AVPictureInPictureController) -> Bool {
        inner.pictureInPictureControllerShouldProhibitBackgroundAudioPlayback?(c) ?? false
    }
}
