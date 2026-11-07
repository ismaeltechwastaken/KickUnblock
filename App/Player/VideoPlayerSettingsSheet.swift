import SwiftUI
import KickUnblockCore

struct VideoPlayerSettingsSheet: View {
    @EnvironmentObject var session: PlaybackSession
    @ObservedObject private var downloads = DownloadManager.shared
    @Environment(\.dismiss) private var dismiss
    @AppStorage(PrefKey.showStats) private var showStats = TweakDefault.showStats
    @AppStorage(PrefKey.backgroundAudio) private var backgroundAudio = TweakDefault.backgroundAudio
    @AppStorage(PrefKey.preferredQuality) private var qualityRaw = TweakDefault.quality
    @AppStorage(PrefKey.playbackSpeed) private var speed = TweakDefault.speed
    @AppStorage(PrefKey.landscapeChat) private var chatModeRaw = TweakDefault.landscape
    @AppStorage(PrefKey.overlayOpacity) private var overlayOpacity = TweakDefault.overlayOpacity
    var openFullSettings: () -> Void = {}

    private var accent: Color { ThemeReader().accent }
    private var np: NowPlaying? { session.nowPlaying }
    private var quality: QualityChoice { QualityChoice(rawValue: qualityRaw) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Video player").font(.headline)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .bold))
                        .frame(width: 30, height: 30)
                        .background(Color.secondary.opacity(0.25), in: Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if np?.chat != nil { chatSection }
                    if np?.streamURL != nil { qualitySection }
                    if np != nil && !session.isLive && np?.streamURL != nil { speedSection }
                    if np != nil { sleepSection }
                    if np != nil && !session.isLive && np?.streamURL != nil { downloadSection }
                    VStack(spacing: 0) {
                        Toggle("Stats overlay", isOn: $showStats).padding(.vertical, 6)
                        Divider()
                        Toggle("Background audio", isOn: $backgroundAudio).padding(.vertical, 6)
                        Divider()
                        Button(action: openFullSettings) {
                            HStack {
                                Label("Settings", systemImage: "slider.horizontal.3")
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.kuSecondary)
                            }
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .tint(accent)
                }
                .padding(.horizontal, 16).padding(.bottom, 20)
            }
        }
    }

    // MARK: sections

    private var chatSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            section("Chat") {
                ForEach(LandscapeChatMode.allCases) { m in
                    pill(m.label, active: chatModeRaw == m.rawValue) { chatModeRaw = m.rawValue }
                }
            }
            if chatModeRaw == LandscapeChatMode.floating.rawValue {
                HStack {
                    Text("Overlay background").font(.caption).foregroundStyle(.kuSecondary)
                    Slider(value: Binding(get: { OverlayGeometry.clampOpacity(overlayOpacity) },
                                          set: { overlayOpacity = OverlayGeometry.clampOpacity($0) }),
                           in: OverlayGeometry.opacityRange)
                        .tint(accent)
                        .accessibilityLabel("Overlay background opacity")
                }
            }
        }
    }

    private var qualitySection: some View {
        section("Quality") {
            ForEach(session.qualityPills, id: \.rawValue) { q in
                pill(session.qualityLabel(q), active: session.quality == q) { session.setQuality(q) }
            }
        }
    }

    private var speedSection: some View {
        section("Speed") {
            ForEach(PlaybackSpeed.presets, id: \.self) { v in
                pill(PlaybackSpeed.label(v), active: abs(speed - v) < 0.01) { session.setSpeed(v) }
            }
        }
    }

    private var sleepSection: some View {
        section(sleepTitle) {
            ForEach(SleepTimerOption.options(isLive: session.isLive)) { o in
                pill(o.label, active: session.sleepTimer == o) { session.setSleepTimer(o) }
            }
        }
    }

    private var sleepTitle: String {
        if let d = session.sleepFireDate {
            let m = max(0, Int(d.timeIntervalSinceNow / 60))
            return "Sleep timer · pauses in \(m) min"
        }
        return session.sleepTimer == .endOfVideo ? "Sleep timer · pauses at the end" : "Sleep timer"
    }

    @ViewBuilder private var downloadSection: some View {
        if let np, let url = np.streamURL {
            let id = "\(np.kind):\(url.absoluteString)"
            VStack(alignment: .leading, spacing: 6) {
                Text("Download").font(.caption.weight(.semibold)).foregroundStyle(.kuSecondary)
                if let job = downloads.jobs[id] {
                    switch job.state {
                    case .running:
                        HStack {
                            ProgressView(value: job.progress).tint(accent)
                            Button { downloads.cancel(id) } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(.kuSecondary).accessibilityLabel("Cancel download")
                        }
                        Text(job.detail).font(.caption2.monospacedDigit()).foregroundStyle(.kuSecondary)
                    case .savedToPhotos:
                        Label("Saved to Photos", systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(.green)
                    case .done(let file):
                        HStack {
                            Label("Saved to Files › KickUnblock › Downloads", systemImage: "checkmark.circle.fill")
                                .font(.caption).foregroundStyle(.green)
                            Spacer()
                            ShareLink(item: file) { Image(systemName: "square.and.arrow.up") }
                        }
                    case .failed(let msg):
                        Text(msg).font(.caption).foregroundStyle(.red)
                        downloadButton(id: id, np: np, url: url)
                    }
                } else {
                    downloadButton(id: id, np: np, url: url)
                }
            }
        }
    }

    private func downloadButton(id: String, np: NowPlaying, url: URL) -> some View {
        let v = session.activeVariant
        return Button {
            downloads.start(id: id, title: np.title, url: url, variant: v, toPhotos: np.kind == .clip)
        } label: {
            Label(np.kind == .clip ? "Save clip to Photos" : "Download VOD\(v.map { " · \($0.label)" } ?? "")", systemImage: "arrow.down.circle")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 8)
                .background(accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    // MARK: building blocks

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.kuSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) { content() }
            }
        }
    }

    private func pill(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(active ? .bold : .regular))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(active ? accent : Color.secondary.opacity(0.18), in: Capsule())
                .foregroundStyle(active ? ThemeReader().onAccent : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}
