import Combine
import SwiftUI
import KickUnblockCore

@MainActor
final class LocalDiagnosticsStore: ObservableObject {
    static let shared = LocalDiagnosticsStore()
    @Published private(set) var exportText = ""
    private var buffer = LocalPlaybackDiagnostics()
    private var subscriptions = Set<AnyCancellable>()
    private weak var session: PlaybackSession?

    func attach(to session: PlaybackSession, enabled: Bool) {
        self.session = session
        setEnabled(enabled)
    }

    func setEnabled(_ enabled: Bool) {
        subscriptions.removeAll()
        buffer.setEnabled(enabled)
        refreshExport()
        guard enabled, let session else { return }
        session.$isPlaying.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] playing in
            self?.record(playing ? .playing : .paused)
        }.store(in: &subscriptions)
        session.$isRecoveringLive.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] recovering in
            if recovering { self?.record(.retrying) }
        }.store(in: &subscriptions)
        session.$errorText.map { $0 != nil }.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] failed in
            if failed { self?.record(.failed) }
        }.store(in: &subscriptions)
        session.$stats.map(\.liveLatency).removeDuplicates()
            .throttle(for: .seconds(5), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] seconds in
                if let seconds { self?.record(.liveLatency, seconds: seconds) }
            }.store(in: &subscriptions)
        session.$scrubUI.map(\.isSeeking).removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] seeking in
            self?.record(seeking ? .seeking : .seekCompleted)
        }.store(in: &subscriptions)
    }

    func clear() {
        let enabled = buffer.isEnabled
        buffer.setEnabled(false)
        buffer.setEnabled(enabled)
        refreshExport()
    }

    private func record(_ kind: LocalPlaybackDiagnostics.EventKind, seconds: Double? = nil) {
        buffer.record(kind, seconds: seconds)
        refreshExport()
    }

    private func refreshExport() {
        exportText = (try? buffer.exportJSON()).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}

struct LocalDiagnosticsObserver: ViewModifier {
    @EnvironmentObject private var session: PlaybackSession
    @AppStorage(PrefKey.localPlaybackDiagnostics) private var enabled = false
    func body(content: Content) -> some View {
        content
            .onAppear { LocalDiagnosticsStore.shared.attach(to: session, enabled: enabled) }
            .onChange(of: enabled) { _, value in LocalDiagnosticsStore.shared.setEnabled(value) }
    }
}

struct LocalDiagnosticsSection: View {
    @AppStorage(PrefKey.localPlaybackDiagnostics) private var enabled = false
    @ObservedObject private var store = LocalDiagnosticsStore.shared
    var body: some View {
        Section {
            TweakToggle("Local playback diagnostics", "Keep a short playback log on this device for bug reports.", isOn: $enabled)
            if enabled {
                ShareLink(item: store.exportText) {
                    Label("Share local diagnostics", systemImage: "square.and.arrow.up")
                }
                Button("Clear local diagnostics") { store.clear() }
            }
        } header: { Text("Local diagnostics") } footer: {
            Text("No automatic uploads. Turning this off clears the log.")
        }
        .themedRows()
    }
}
