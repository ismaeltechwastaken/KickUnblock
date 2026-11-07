import SwiftUI
import AVKit
import KickUnblockCore

struct PlayerScreen: View {
    @EnvironmentObject var session: PlaybackSession
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    @State private var chat = ChatViewModel()
    @AppStorage(PrefKey.landscapeChat) private var chatModeRaw = TweakDefault.landscape
    @AppStorage(PrefKey.overlayWidth) private var overlayWidth = TweakDefault.overlayWidth
    @AppStorage(PrefKey.overlayOpacity) private var overlayOpacity = TweakDefault.overlayOpacity
    @AppStorage(PrefKey.controlsAutoHide) private var autoHide = TweakDefault.autoHide
    @AppStorage(PrefKey.showStats) private var showStats = TweakDefault.showStats
    @AppStorage(PrefKey.seekInterval) private var seekRaw = TweakDefault.seek
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var dragY: CGFloat = 0
    @State private var seekFlash: String?
    @State private var toast: String?
    @State private var showSettings = false
    @State private var showFullTweaks = false
    @State private var isLandscape = false
    @State private var taps = PlayerTapSequence()

    private var chatMode: LandscapeChatMode { LandscapeChatMode(rawValue: chatModeRaw) ?? .rightSplit }
    private var hasChatSource: Bool { session.nowPlaying?.chat != nil || session.nowPlaying?.vodReplay != nil }
    private var hasChat: Bool { hasChatSource && !session.theater }
    private var accent: Color { ThemeReader().accent }

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            let placement = ChatPlacement.resolve(mode: chatMode, landscape: landscape, hasChat: hasChat)
            ZStack {
                Color.black.ignoresSafeArea()
                if landscape { landscapeLayout(geo, placement) } else { portraitLayout(geo, placement) }
            }
            .offset(y: max(0, dragY))
            .animation(.interactiveSpring, value: dragY)
            .onAppear { isLandscape = landscape }
            .onChange(of: landscape) { _, l in isLandscape = l }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .tint(.white)
        .sheet(isPresented: $showSettings, onDismiss: scheduleHide) {
            VideoPlayerSettingsSheet(openFullSettings: {
                showSettings = false
                Task { try? await Task.sleep(nanoseconds: 350_000_000); showFullTweaks = true }
            })
            .environmentObject(session).environmentObject(model)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showFullTweaks, onDismiss: scheduleHide) {
            TweakSheet().environmentObject(model).environmentObject(session).presentationDetents([.medium, .large])
        }
        .task(id: session.nowPlaying?.chat) {
            if let t = session.nowPlaying?.chat { await chat.start(t, globalEmotes: model.globalEmotes) }
            else if session.nowPlaying?.vodReplay == nil { chat.stop() }
        }
        .vodChatReplay(vm: chat, globalEmotes: model.globalEmotes)
        .onChange(of: model.globalEmotes) { _, globals in chat.updateGlobalEmotes(globals) }
        .onAppear(perform: scheduleHide)
        .onChange(of: voiceOverEnabled) { _, enabled in
            if enabled { showControls() } else { scheduleHide() }
        }
        .onChange(of: session.wantsPlayback) { _, playing in
            if playing { if controlsVisible { scheduleHide() } } else { hideTask?.cancel(); showControls(schedule: false) }
        }
        .onChange(of: session.scrubUI.isInteracting) { _, busy in
            if busy { hideTask?.cancel() } else if controlsVisible { scheduleHide() }
        }
        .onDisappear {
            hideTask?.cancel()
            chat.stop()
            OrientationLock.release()
        }
    }

    private func minimize() {
        hideTask?.cancel()
        OrientationLock.release()
        session.minimize()
        dismiss()
    }

    // MARK: layouts

    private func portraitLayout(_ geo: GeometryProxy, _ placement: ChatPlacement) -> some View {
        VStack(spacing: 0) {
            video(overlayWidth: placement == .overlay ? geo.size.width : nil,
                  overlayHeight: geo.size.width * 9 / 16 * 0.6,
                  overlayAlignment: .bottom)
            .aspectRatio(16 / 9, contentMode: .fit).frame(maxWidth: .infinity)
            .overlay(alignment: .bottom) {
                if controlsVisible, hasTimeline {
                    PlayerProgressBar(onDragging: { hideTask?.cancel() }, onEnded: scheduleHide)
                        .offset(y: PlayerProgressBar.hitHeight / 2 - PlayerProgressBar.trackHeight / 2)
                        .transition(.opacity)
                }
            }
            .zIndex(1)
            if let np = session.nowPlaying, np.kind != .clip, !np.channelSlug.isEmpty, !session.theater {
                StreamerInfoStrip(slug: np.channelSlug, fallbackName: np.channelName, fallbackTitle: np.title, isLive: np.kind == .live) {
                    model.pendingChannel = np.channelSlug
                    minimize()
                }
            }
            if placement == .below {
                ChatView(vm: chat, allowSending: true)
            } else {
                infoPanel
            }
        }
        .background(ThemeReader().background.ignoresSafeArea())
    }

    @ViewBuilder private func landscapeLayout(_ geo: GeometryProxy, _ placement: ChatPlacement) -> some View {
        let w = geo.size.width * OverlayGeometry.clampWidth(overlayWidth)
        switch placement {
        case .side:
            HStack(spacing: 0) {
                video().ignoresSafeArea(.container, edges: .vertical)
                ChatView(vm: chat).frame(width: w)
            }
        case .overlay:
            video(overlayWidth: w).ignoresSafeArea(.container, edges: .vertical)
        default:
            video().ignoresSafeArea(.container, edges: .vertical)
        }
    }

    private func overlayChat(width: CGFloat, height: CGFloat?) -> some View {
        ChatView(vm: chat, transparent: true)
            .frame(width: width)
            .frame(maxHeight: height ?? .infinity)
            .background(Color.black.opacity(OverlayGeometry.clampOpacity(overlayOpacity)))
            .allowsHitTesting(controlsVisible)
            .accessibilityLabel("Chat overlay")
    }

    private var infoPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let np = session.nowPlaying {
                Text(np.title).font(.headline)
                Text(np.channelName).font(.subheadline).foregroundStyle(.kuSecondary)
            }
            Spacer()
        }
        .padding().frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: video surface

    private func video(overlayWidth: CGFloat? = nil, overlayHeight: CGFloat? = nil,
                       overlayAlignment: Alignment = .trailing) -> some View {
        ZStack {
            Color.black
            if let np = session.nowPlaying {
                if np.streamURL == nil, let slug = np.embedSlug {
                    OfficialEmbedView(slug: slug)
                } else {
                    PlayerLayerView(aspectFill: session.aspectFill, enablePiP: true)
                        .opacity(session.hideVideo ? 0 : 1)
                    if session.hideVideo { audioOnlyCard(np) }
                }
            }
            gestureLayer
            if let overlayWidth {
                overlayChat(width: overlayWidth, height: overlayHeight)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: overlayAlignment)
            }
            if let f = seekFlash {
                Text(f).font(.headline).padding(10).background(.ultraThinMaterial, in: Capsule()).transition(.opacity)
                    .allowsHitTesting(false)
            }
            if controlsVisible { controls.transition(.opacity) }
            if showStats {
                statsPill.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.leading, 10).padding(.top, 52).allowsHitTesting(false)
            }
            if session.isHoldingFrame, !controlsVisible {
                ProgressView().controlSize(.large).tint(.white).allowsHitTesting(false)
            }
            if session.isRecoveringLive {
                Label("Reconnecting…", systemImage: "arrow.clockwise")
                    .font(.caption).padding(8).background(.black.opacity(0.8), in: Capsule())
                    .accessibilityIdentifier("player.recovering")
                    .allowsHitTesting(false)
            }
            if let toast {
                Label(toast, systemImage: "bookmark.fill")
                    .font(.footnote.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.black.opacity(0.8), in: Capsule())
                    .allowsHitTesting(false)
                    .frame(maxHeight: .infinity, alignment: .top).padding(.top, 56)
                    .transition(.opacity)
            }
            if let notice = session.liveNotice, session.errorText == nil {
                Label(notice, systemImage: "clock.arrow.circlepath")
                    .font(.caption).padding(8).background(.black.opacity(0.8), in: Capsule())
                    .accessibilityIdentifier("player.liveNotice")
                    .allowsHitTesting(false)
                    .frame(maxHeight: .infinity, alignment: .top).padding(.top, 56)
            }
            if let e = session.errorText {
                VStack(spacing: 8) {
                    Text(e).font(.caption)
                    if session.isLive { Button("Retry playback") { session.retryLivePlayback() }.buttonStyle(.bordered) }
                }
                .padding(8).background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .clipped()
    }

    private func audioOnlyCard(_ np: NowPlaying) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform").font(.largeTitle).foregroundStyle(accent)
            Text("Audio Only").font(.headline)
            Text(np.channelName).font(.caption).foregroundStyle(.kuSecondary)
        }
        .allowsHitTesting(false)
    }

    private var gestureLayer: some View {
        HStack(spacing: 0) {
            tapZone(.leading, seconds: -Double(LiveRewind.skipSeconds(preferred: seekRaw, atLiveEdge: atLiveEdge, forward: false)))
            tapZone(.trailing, seconds: Double(seekRaw))
        }
        .gesture(MagnificationGesture().onEnded { scale in
            withAnimation { session.aspectFill = scale > 1 }
        })
        .simultaneousGesture(swipeDown)
    }

    private var swipeDown: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { v in if abs(v.translation.height) > abs(v.translation.width) { dragY = v.translation.height } }
            .onEnded { v in
                let down = v.translation.height > 120 || v.predictedEndTranslation.height > 260
                dragY = 0
                if down && abs(v.translation.height) > abs(v.translation.width) { minimize() }
            }
    }

    private func tapZone(_ zone: PlayerTapSequence.Zone, seconds: Double) -> some View {
        Color.clear.contentShape(Rectangle())
            .onTapGesture {
                let canSeek = session.nowPlaying?.streamURL != nil
                switch taps.tap(zone: zone, at: ProcessInfo.processInfo.systemUptime, canSeek: canSeek) {
                case .toggleControls:
                    toggleControls()
                case .seek(let revert):
                    if revert { toggleControls() }
                    if seconds > 0, atLiveEdge { return }
                    session.seek(by: seconds)
                    let label = seconds < 0 ? "−\(Int(-seconds))s" : "+\(Int(seconds))s"
                    withAnimation(.easeOut(duration: 0.12)) { seekFlash = label }
                    Task {
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        if seekFlash == label { withAnimation(.easeOut(duration: 0.15)) { seekFlash = nil } }
                    }
                }
            }
    }

    // MARK: controls

    private func ctl(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            PlayerIcon(symbol: symbol)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var chatModeButton: some View {
        Button {
            chatModeRaw = chatMode.next.rawValue
            scheduleHide()
        } label: {
            PlayerIcon(symbol: chatMode.symbol)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(chatMode.title)
        .accessibilityValue(chatMode.label)
        .accessibilityIdentifier("player.chat.layout")
        .accessibilityHint("Switch to \(chatMode.next.label.lowercased()) chat")
    }

    private var hasTimeline: Bool {
        guard session.nowPlaying?.streamURL != nil else { return false }
        return session.isLive || session.scrubRange != nil
    }

    private func showToast(_ text: String) {
        withAnimation(.easeOut(duration: 0.15)) { toast = text }
        UIAccessibility.post(notification: .announcement, argument: text)
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if toast == text { withAnimation(.easeOut(duration: 0.2)) { toast = nil } }
        }
    }

    private var atLiveEdge: Bool { session.isLive && !session.isBehindLive }

    private var controls: some View {
        ZStack {
            Color.black.opacity(0.35).allowsHitTesting(false)
            LinearGradient(colors: [.black.opacity(0.45), .clear, .clear, .black.opacity(0.45)], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
            VStack(spacing: 0) {
                topBar.padding(.horizontal, 8).padding(.top, 4)
                Spacer(minLength: 0)
                transport
                Spacer(minLength: 0)
                bottomBar.padding(.horizontal, isLandscape ? 16 : 10)
                    .padding(.bottom, isLandscape ? 0 : PlayerProgressBar.trackHeight + 6)
                if isLandscape, hasTimeline {
                    PlayerProgressBar(onDragging: { hideTask?.cancel() }, onEnded: scheduleHide)
                        .padding(.horizontal, 20).padding(.bottom, 6)
                }
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    private var topBar: some View {
        HStack(spacing: 0) {
            ctl("chevron.down", "Minimize player", action: minimize)
            if isLandscape, let np = session.nowPlaying {
                VStack(alignment: .leading, spacing: 1) {
                    Text(np.channelName).font(.subheadline.weight(.bold)).lineLimit(1)
                    Text(np.title).font(.caption).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                }
                .foregroundStyle(.white)
                .allowsHitTesting(false)
            }
            Spacer(minLength: 4)
            if let item = session.nowPlaying?.savedItem, !session.isLive {
                ctl(model.isSaved(item.id) ? "bookmark.fill" : "bookmark", model.isSaved(item.id) ? "Remove from saved" : "Save") {
                    model.toggleSaved(item); scheduleHide()
                    showToast(model.isSaved(item.id) ? "Added to Saved Clips" : "Removed from Saved Clips")
                }
            }
            if let slug = session.nowPlaying?.channelSlug, let url = URL(string: "https://kick.com/\(slug)") {
                ShareLink(item: url) { PlayerIcon(symbol: "square.and.arrow.up") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Share")
                    .simultaneousGesture(TapGesture().onEnded { hideTask?.cancel() })
            }
            AirPlayButton().frame(width: 44, height: 44)
            ctl("gearshape.fill", "Video player settings") { hideTask?.cancel(); showSettings = true }
        }
    }

    private var transport: some View {
        HStack(spacing: 4) {
            if canSkip { skipButton(forward: false) }
            Button { session.togglePlay(); scheduleHide() } label: {
                Image(systemName: session.wantsPlayback ? "pause.fill" : "play.fill")
                    .font(.system(size: 38, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64).contentShape(Rectangle())
                    .shadow(color: .black.opacity(0.35), radius: 4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(session.wantsPlayback ? "Pause" : "Play")
            if canSkip { skipButton(forward: true).disabled(atLiveEdge).opacity(atLiveEdge ? 0.35 : 1) }
        }
    }

    private var canSkip: Bool {
        guard session.nowPlaying?.streamURL != nil else { return false }
        return session.isLive ? session.liveEdgeElapsed != nil : session.scrubRange != nil
    }

    private func skipButton(forward: Bool) -> some View {
        let secs = LiveRewind.skipSeconds(preferred: seekRaw, atLiveEdge: atLiveEdge, forward: forward)
        return Button {
            session.seek(by: forward ? Double(secs) : -Double(secs))
            scheduleHide()
        } label: {
            Image(systemName: SeekSymbol.name(forward: forward, seconds: secs))
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56).contentShape(Rectangle())
                .shadow(color: .black.opacity(0.35), radius: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(forward ? "Forward \(secs) seconds" : "Back \(secs) seconds")
    }

    private var shownTime: Double { session.scrubUI.previewTime ?? session.currentTime }

    @ViewBuilder private var timeLabel: some View {
        if session.isLive {
            HStack(spacing: 6) {
                Circle().fill(atLiveEdge && session.wantsPlayback ? Color(hex: Contrast.liveBadgeHex) : Color.white.opacity(0.45))
                    .frame(width: 8, height: 8)
                Text(session.liveClockTime.map(PlayerClock.format) ?? "LIVE")
                    .font(.system(.callout, design: .default).weight(.bold).monospacedDigit())
                    .accessibilityIdentifier("player.live.time")
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(atLiveEdge ? "Live" : "Behind live")
        } else if let r = session.scrubRange {
            Text("\(PlayerClock.format(shownTime)) / \(PlayerClock.format(r.end))")
                .font(.system(.callout, design: .default).weight(.bold).monospacedDigit())
                .accessibilityIdentifier("player.vod.time")
        }
    }

    private var goLiveButton: some View {
        Button { session.goLive(); scheduleHide() } label: {
            HStack(spacing: 6) {
                if session.isRejoiningLive { ProgressView().controlSize(.mini).tint(.white) }
                Text(session.isRejoiningLive ? "Going live…" : "Go to LIVE").font(.subheadline.weight(.bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14).frame(height: 34)
            .background(.black.opacity(0.5), in: Capsule())
            .frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(session.isRejoiningLive)
        .accessibilityLabel(session.isRejoiningLive ? "Going live" : "Go to live")
        .transition(.opacity)
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            timeLabel.foregroundStyle(.white)
            if session.isLive, session.isBehindLive || session.isRejoiningLive { goLiveButton }
            if let l = session.stats.liveLatency, showStats, session.isLive {
                Text(String(format: "%.1fs", max(0, l))).font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.7))
            }
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                ctl(session.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", session.isMuted ? "Unmute" : "Mute") {
                    session.isMuted.toggle(); scheduleHide()
                }
                if session.canStartPiP { ctl("pip.enter", "Picture in Picture") { session.startPiP() } }
                if isLandscape && hasChatSource { chatModeButton }
                ctl(isLandscape ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                    isLandscape ? "Exit fullscreen" : "Fullscreen") {
                    OrientationLock.force(landscape: !isLandscape)
                    scheduleHide()
                }
            }
        }
        .frame(minHeight: 44)
        .animation(.easeOut(duration: 0.15), value: session.isBehindLive)
    }

    private var statsPill: some View {
        let s = session.stats
        return VStack(alignment: .leading, spacing: 2) {
            Text("\(s.resolutionText) · \(s.fpsText)")
            Text(s.bitrateText)
            Text("Buffer \(s.bufferText) · dropped \(s.droppedFrames) · stalls \(s.stalls)")
            if let l = s.latencyText { Text(l) }
        }
        .font(.system(size: 10, design: .monospaced))
        .padding(6)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
        .foregroundStyle(s.health == .good ? .green : s.health == .fair ? .yellow : .red)
    }

    private func toggleControls() {
        guard !voiceOverEnabled else { showControls(); return }
        withAnimation(.easeOut(duration: 0.15)) { controlsVisible.toggle() }
        if controlsVisible { scheduleHide() } else { hideTask?.cancel() }
    }

    private func showControls(schedule: Bool = true) {
        if !controlsVisible { withAnimation(.easeOut(duration: 0.15)) { controlsVisible = true } }
        if schedule { scheduleHide() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard !voiceOverEnabled else { controlsVisible = true; return }
        guard !showSettings, !showFullTweaks, session.wantsPlayback else { return }
        let delay = ControlsAutoHide(rawValue: autoHide)?.rawValue ?? ControlsAutoHide.default.rawValue
        hideTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, !voiceOverEnabled, !showSettings, !showFullTweaks,
                  session.wantsPlayback, !session.scrubUI.isInteracting else { return }
            withAnimation(.easeOut(duration: 0.25)) { controlsVisible = false }
        }
    }
}

struct PlayerIcon: View {
    let symbol: String
    var size: CGFloat = 20
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .shadow(color: .black.opacity(0.3), radius: 3)
    }
}

struct PlayerProgressBar: View {
    @EnvironmentObject var session: PlaybackSession
    @GestureState private var dragActive = false
    var onDragging: () -> Void = {}
    var onEnded: () -> Void = {}

    static let trackHeight: CGFloat = 4
    static let hitHeight: CGFloat = 32
    private static let handle: CGFloat = 16

    private var range: ScrubRange? {
        if session.isLive {
            guard let r = session.displayScrubRange, LiveEdge.showsScrubBar(r) else { return nil }
            return r
        }
        return session.scrubRange
    }

    var body: some View {
        GeometryReader { g in
            let w = max(1, g.size.width)
            let live = session.isLive
            let f = CGFloat(min(max(session.displayScrubFraction, 0), 1))
            let enabled = range != nil
            let accent = ThemeReader().accent
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.white.opacity(0.3)).frame(height: Self.trackHeight)
                Rectangle().fill(accent).frame(width: w * f, height: Self.trackHeight)
                if enabled || live {
                    Circle().fill(accent)
                        .frame(width: Self.handle, height: Self.handle)
                        .scaleEffect(session.scrubUI.isDragging ? 1.25 : 1)
                        .offset(x: min(max(0, w * f - Self.handle / 2), w - Self.handle))
                }
            }
            .frame(width: w, height: g.size.height)
            .contentShape(Rectangle())
            .transaction { $0.animation = nil }
            .gesture(drag(width: w), including: enabled ? .all : .none)
        }
        .frame(height: Self.hitHeight)
        .onChange(of: dragActive) { _, active in
            if !active && session.scrubUI.isDragging {
                session.cancelScrubbing()
                onEnded()
            }
        }
        .onDisappear { session.cancelScrubbing() }
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue(session.isLive ? (session.liveClockTime.map(PlayerClock.format) ?? "Live")
                                           : PlayerClock.format(session.currentTime))
        .accessibilityAdjustableAction { dir in
            guard let range else { return }
            onDragging()
            defer { onEnded() }
            if session.isLive {
                session.seek(by: dir == .increment ? 60 : -60)
                return
            }
            let step = max(5, range.length / 50)
            session.seek(to: range.clamp(session.currentTime + (dir == .increment ? step : -step)))
        }
    }

    private func drag(width w: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($dragActive) { _, active, _ in active = true }
            .onChanged { v in
                guard let range else { return }
                session.scrubbing(fraction: min(max(v.location.x / w, 0), 1), range: range)
                onDragging()
            }
            .onEnded { v in
                session.endScrubbing(fraction: min(max(v.location.x / w, 0), 1))
                onEnded()
            }
    }
}

struct MiniPlayerBar: View {
    @EnvironmentObject var session: PlaybackSession
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Color.black
                if session.nowPlaying?.streamURL != nil {
                    PlayerLayerView(aspectFill: true, enablePiP: false)
                } else if let slug = session.nowPlaying?.embedSlug {
                    Image(systemName: "play.rectangle").foregroundStyle(.kuSecondary).accessibilityLabel(slug)
                }
            }
            .frame(width: 96, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(session.nowPlaying?.title ?? "").font(.footnote.weight(.semibold)).lineLimit(1)
                Text(session.nowPlaying?.channelName ?? "").font(.caption2).foregroundStyle(.kuSecondary)
            }
            Spacer()
            Button { session.togglePlay() } label: {
                Image(systemName: session.wantsPlayback ? "pause.fill" : "play.fill").frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel(session.wantsPlayback ? "Pause" : "Play")
            .foregroundStyle(.white)
            Button { session.close() } label: {
                Image(systemName: "xmark").frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel("Close player")
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .font(.title3)
        .padding(8)
        .chromeSurface(in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.5), radius: 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player.mini")
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture { session.expand() }
        .gesture(DragGesture().onEnded { v in
            if v.translation.height < -40 { session.expand() }
            else if v.translation.height > 40 { session.close() }
        })
    }
}

