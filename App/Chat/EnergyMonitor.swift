import Foundation
import KickUnblockCore

@MainActor
final class EnergyMonitor: ObservableObject {
    static let shared = EnergyMonitor()
    @Published private(set) var constrained = EnergyMonitor.current()
    private var observers: [NSObjectProtocol] = []

    private init() {
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }

    private func refresh() {
        let now = Self.current()
        if now != constrained { constrained = now }
    }

    nonisolated static func current() -> Bool {
        let p = ProcessInfo.processInfo
        return ChatEnergyPolicy.isConstrained(lowPowerMode: p.isLowPowerModeEnabled, thermalState: p.thermalState)
    }
}
