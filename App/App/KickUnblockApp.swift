import SwiftUI
import KickUnblockCore

@main
struct KickUnblockApp: App {
    @UIApplicationDelegateAdaptor(KickUnblockAppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @State private var showIntro = UserDefaults.standard.object(forKey: PrefKey.launchAnimation) as? Bool ?? TweakDefault.launchAnimation

    init() {
        AudioSession.configure()
        PrefKey.migrateStatsOverlayOff()
        UIWindow.appearance().backgroundColor = .black
        UITableView.appearance().backgroundColor = .clear
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootView()
                if showIntro {
                    LaunchOverlay { showIntro = false }.zIndex(1)
                }
            }
                .environmentObject(model)
                .environmentObject(model.auth)
                .environmentObject(model.webSession)
                .environmentObject(model.playback)
                .task { await model.bootstrap() }
                .task {
                    await Self.migrateRetiredIcon()
                }
        }
    }
}

extension KickUnblockApp {
    @MainActor static func migrateRetiredIcon() async {
        let app = UIApplication.shared
        guard app.supportsAlternateIcons,
              AppIconChoice.needsMigration(current: app.alternateIconName) else { return }
        try? await app.setAlternateIconName(nil)
    }
}

enum TweakDefault {
    static let dataSource = DataSource.website.rawValue
    static let backgroundAudio = true
    static let autoPiP = true
    static let quality = QualityChoice.auto.rawValue
    static let chatSendPath = ChatSendPath.webSession.rawValue
    static let speed = 1.0
    static let seek = SeekInterval.ten.rawValue
    static let keepAwake = true
    static let emotesKick = true
    static let emotes7TV = true
    static let animateEmotes = true
    static let sevenTVCosmetics = true
    static let emotesBTTVFFZ = false
    static let fontSize = 14.0
    static let spacing = ChatSpacing.comfortable.rawValue
    static let timestamps = false
    static let landscape = LandscapeChatMode.rightSplit.rawValue
    static let overlayWidth = 0.32
    static let overlayOpacity = 0.45
    static let hideCommands = false
    static let hideBanners = false
    static let dedupe = true
    static let background = OLEDBackground.carbon.rawValue
    static let accent = AccentChoice.kickNeon.rawValue
    static let autoHide = ControlsAutoHide.default.rawValue
    static let hideMature = false
    static let launchAnimation = true
    static let openingScreen = OpeningScreen.default.rawValue
    static let chromeStyle = ChromeStyle.default.rawValue
    static let showStats = PrefKey.showStatsDefault
}
