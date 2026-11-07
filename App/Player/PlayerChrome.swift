import SwiftUI
import AVKit
import UIKit

@MainActor
enum OrientationLock {
    static var mask: UIInterfaceOrientationMask = .allButUpsideDown

    private static var scene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }

    static func force(landscape: Bool) {
        mask = landscape ? .landscape : .portrait
        apply(landscape ? .landscapeRight : .portrait)
    }

    static func release() {
        guard mask != .allButUpsideDown else { return }
        let wasLandscape = mask == .landscape
        mask = .allButUpsideDown
        apply(wasLandscape ? .portrait : nil)
    }

    private static func apply(_ target: UIInterfaceOrientationMask?) {
        guard let scene else { return }
        for w in scene.windows {
            var vc = w.rootViewController
            while let current = vc {
                current.setNeedsUpdateOfSupportedInterfaceOrientations()
                vc = current.presentedViewController
            }
        }
        if let target {
            scene.requestGeometryUpdate(UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: target)) { _ in
                Task { @MainActor in
                    guard mask != .allButUpsideDown else { return }
                    mask = .allButUpsideDown
                    apply(nil)
                }
            }
        }
    }
}

final class KickUnblockAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        MainActor.assumeIsolated { OrientationLock.mask }
    }
}

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .white
        v.activeTintColor = .systemGreen
        v.prioritizesVideoDevices = true
        v.backgroundColor = .clear
        v.accessibilityLabel = "AirPlay"
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
