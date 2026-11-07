import SwiftUI
import KickUnblockCore

struct TweakSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form { TweaksSections() }
                .oledPage()
                .themedControlTint()
                .navigationTitle("Tweaks")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
        .compatPresentationBackground(ThemeReader().background)
    }
}

struct TweaksSections: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var session: PlaybackSession

    @AppStorage(PrefKey.dataSource) private var dataSource = TweakDefault.dataSource
    @AppStorage(PrefKey.backgroundAudio) private var bgAudio = TweakDefault.backgroundAudio
    @AppStorage(PrefKey.autoPiP) private var autoPiP = TweakDefault.autoPiP
    @AppStorage(PrefKey.preferredQuality) private var quality = TweakDefault.quality
    @AppStorage(PrefKey.playbackSpeed) private var speed = TweakDefault.speed
    @AppStorage(PrefKey.seekInterval) private var seek = TweakDefault.seek
    @AppStorage(PrefKey.keepAwake) private var keepAwake = TweakDefault.keepAwake
    @AppStorage(PrefKey.emotesKick) private var emKick = TweakDefault.emotesKick
    @AppStorage(PrefKey.emotes7TV) private var em7TV = TweakDefault.emotes7TV
    @AppStorage(PrefKey.animateEmotes) private var animateEmotes = TweakDefault.animateEmotes
    @AppStorage(PrefKey.emotesBTTVFFZ) private var emBTTV = TweakDefault.emotesBTTVFFZ
    @AppStorage(PrefKey.sevenTVCosmetics) private var sevenTVCosmetics = TweakDefault.sevenTVCosmetics
    @AppStorage(PrefKey.chatFontSize) private var fontSize = TweakDefault.fontSize
    @AppStorage(PrefKey.chatSpacing) private var spacing = TweakDefault.spacing
    @AppStorage(PrefKey.chatTimestamps) private var timestamps = TweakDefault.timestamps
    @AppStorage(PrefKey.landscapeChat) private var landscape = TweakDefault.landscape
    @AppStorage(PrefKey.overlayWidth) private var overlayWidth = TweakDefault.overlayWidth
    @AppStorage(PrefKey.overlayOpacity) private var overlayOpacity = TweakDefault.overlayOpacity
    @AppStorage(PrefKey.hideCommands) private var hideCommands = TweakDefault.hideCommands
    @AppStorage(PrefKey.hideSystemBanners) private var hideBanners = TweakDefault.hideBanners
    @AppStorage(PrefKey.dedupeSpam) private var dedupe = TweakDefault.dedupe
    @AppStorage(PrefKey.background) private var background = TweakDefault.background
    @AppStorage(PrefKey.accent) private var accent = TweakDefault.accent
    @AppStorage(PrefKey.controlsAutoHide) private var autoHide = TweakDefault.autoHide
    @AppStorage(PrefKey.hideMature) private var hideMature = TweakDefault.hideMature
    @AppStorage(PrefKey.launchAnimation) private var launchAnimation = TweakDefault.launchAnimation
    @AppStorage(PrefKey.openingScreen) private var openingScreen = TweakDefault.openingScreen
    @AppStorage(PrefKey.chromeStyle) private var chromeStyle = TweakDefault.chromeStyle
    @AppStorage(PrefKey.showStats) private var showStats = TweakDefault.showStats
    @State private var copied = false
    @State private var confirmReset = false

    private var openingBinding: Binding<OpeningScreen> {
        Binding(get: { OpeningScreen.resolve(openingScreen) }, set: { openingScreen = $0.rawValue })
    }
    private var chromeBinding: Binding<ChromeStyle> {
        Binding(get: { ChromeStyle.resolve(chromeStyle) }, set: { chromeStyle = $0.rawValue })
    }

    var body: some View {
        Section {
            Picker("Data source", selection: $dataSource) {
                ForEach(DataSource.allCases) { Text($0.label).tag($0.rawValue) }
            }
            if model.router.isFallingBack {
                Label("kick.com blocked a request. Using the official API for a few minutes.", systemImage: "arrow.triangle.branch")
                    .font(.caption).foregroundStyle(.orange)
                Button("Try kick.com again") { model.router.reset(); model.fallbackNotice = nil }
            }
            TweakToggle("Background audio", "Keep sound playing when you leave the app.", isOn: $bgAudio)
            TweakToggle("Picture in Picture on exit", "Open a small video window when you leave the app. The player's PiP button works with this off too.", isOn: $autoPiP)
            Picker("Default quality", selection: $quality) {
                ForEach(QualityChoice.presets, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                if !QualityChoice.presets.map(\.rawValue).contains(quality) { Text(QualityChoice(rawValue: quality).label).tag(quality) }
            }
            VStack(alignment: .leading) {
                Text("Playback speed \(String(format: "%.2fx", speed))")
                Slider(value: $speed, in: PlaybackSpeed.range, step: PlaybackSpeed.step)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Skip length")
                Picker("Skip length", selection: $seek) {
                    ForEach(SeekInterval.allCases) { Text($0.label).tag($0.rawValue) }
                }.pickerStyle(.segmented)
            }
            TweakToggle("Keep screen on", "Stop the screen dimming as you watch.", isOn: $keepAwake)
        } header: { Text("Playback") } footer: {
            Text("\((DataSource(rawValue: dataSource) ?? .website).detail) Speed applies to VODs and clips only.")
        }
        .themedRows()

        Section {
            TweakToggle("Kick emotes", "Show Kick emotes in chat.", isOn: $emKick)
            TweakToggle("7TV emotes", "Show global and channel 7TV emotes. Channel emotes update live.", isOn: $em7TV).onChange(of: em7TV) { _, _ in Task { await model.reloadGlobalEmotes() } }
            TweakToggle("BTTV and FFZ emotes", "Show global BTTV and FFZ emotes.", isOn: $emBTTV).onChange(of: emBTTV) { _, _ in Task { await model.reloadGlobalEmotes() } }
            TweakToggle("Animated emotes", "Animate emotes. Off shows still images. Animation pauses in Low Power Mode or if your phone gets hot.", isOn: $animateEmotes)
            TweakToggle("7TV badges and name colors", "Show 7TV users' chosen badges and name colors.", isOn: $sevenTVCosmetics)
            VStack(alignment: .leading) {
                Text("Text size \(Int(fontSize)) pt")
                Slider(value: $fontSize, in: ChatFontSize.range, step: 1)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Line spacing")
                Picker("Line spacing", selection: $spacing) {
                    ForEach(ChatSpacing.allCases) { Text($0.label).tag($0.rawValue) }
                }.pickerStyle(.segmented)
            }
            TweakToggle("Timestamps", "Show the time next to each message.", isOn: $timestamps)
            Picker("Chat mode", selection: $landscape) {
                ForEach(LandscapeChatMode.allCases) { Text($0.label).tag($0.rawValue) }
            }
            VStack(alignment: .leading) {
                Text("Chat width \(Int(overlayWidth * 100))%")
                Slider(value: $overlayWidth, in: OverlayGeometry.widthRange, step: 0.01)
            }
            VStack(alignment: .leading) {
                Text("Overlay opacity \(Int(overlayOpacity * 100))%")
                Slider(value: $overlayOpacity, in: OverlayGeometry.opacityRange, step: 0.05)
            }
            TweakToggle("Hide bot commands", "Hide messages that start with !.", isOn: $hideCommands)
            TweakToggle("Hide sub and gift alerts", "Hide subscription and gift notices in chat.", isOn: $hideBanners)
            TweakToggle("Collapse repeated messages", "Hide the same message from the same person within 30 seconds.", isOn: $dedupe)
            NavigationLink("Blocked words and users") { BlockListView() }
        } header: { Text("Chat") }
        .themedRows()

        Section {
            Picker("Opening screen", selection: openingBinding) {
                ForEach(OpeningScreen.allCases) { Text($0.label).tag($0) }
            }
            Picker("Surfaces", selection: chromeBinding) {
                ForEach(ChromeStyle.allCases) { Text($0.label).tag($0) }
            }
            Picker("Background", selection: $background) {
                ForEach(OLEDBackground.allCases) { Text($0.label).tag($0.rawValue) }
            }
            HStack {
                Text("Accent")
                Spacer()
                ForEach(AccentChoice.allCases) { a in
                    Circle().fill(Color(hex: a.hex)).frame(width: 26, height: 26)
                        .overlay(Circle().stroke(.white, lineWidth: accent == a.rawValue ? 2 : 0))
                        .onTapGesture { accent = a.rawValue }
                        .accessibilityLabel(a.label)
                        .accessibilityAddTraits(accent == a.rawValue ? .isSelected : [])
                }
            }
            AppIconRow()
            VStack(alignment: .leading, spacing: 8) {
                Text("Hide player controls after")
                Picker("Hide player controls after", selection: $autoHide) {
                    ForEach(ControlsAutoHide.allCases) { Text($0.label).tag($0.rawValue) }
                }.pickerStyle(.segmented)
            }
            TweakToggle("Hide mature streams", "Hide streams marked 18+ in Browse.", isOn: $hideMature)
            TweakToggle("Launch animation", "Play the logo animation when the app opens.", isOn: $launchAnimation)
        } header: { Text("Appearance") } footer: {
            Text("Surfaces changes player controls and notices. Carbon is dark gray. Pure Black is for OLED screens.")
        }
        .themedRows()

        Section {
            TweakToggle("Stats overlay", "Show resolution, bitrate and buffer on the video.", isOn: $showStats)
            if let url = session.currentStreamURL {
                Text(url.absoluteString).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).lineLimit(4)
                Button(copied ? "Copied" : "Copy stream URL") {
                    UIPasteboard.general.string = url.absoluteString; copied = true
                }
                ForEach(ExternalPlayer.allCases) { p in
                    Button("Open in \(p.label)") {
                        if let u = p.url(for: url) { UIApplication.shared.open(u) }
                    }
                    .disabled(!(p.url(for: url).map { UIApplication.shared.canOpenURL($0) } ?? false))
                }
            }
        } header: { Text("Stream") } footer: {
            if session.currentStreamURL == nil { Text("Play a stream to copy its link or open it in another player.") }
        }
        .themedRows()

        LocalDiagnosticsSection()

        Section {
            Button("Reset all tweaks", role: .destructive) { confirmReset = true }
                .confirmationDialog("Reset all tweaks?", isPresented: $confirmReset, titleVisibility: .visible) {
                    Button("Reset", role: .destructive) {
                        PrefKey.resetTweaks()
                        Task { await model.reloadGlobalEmotes() }
                    }
                } message: {
                    Text("Reset settings to defaults. Keep follows, saved clips and sign-in.")
                }
        }
        .themedRows()
    }
}

struct TweakToggle: View {
    let title: String
    let note: String
    @Binding var isOn: Bool

    init(_ title: String, _ note: String, isOn: Binding<Bool>) {
        self.title = title
        self.note = note
        self._isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(note).font(.footnote).foregroundStyle(.kuSecondary)
            }
        }
        .accessibilityIdentifier(title)
    }
}
