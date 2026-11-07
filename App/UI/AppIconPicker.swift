import SwiftUI
import UIKit
import KickUnblockCore

struct AppIconRow: View {
    @State private var current = AppIconChoice(alternateIconName: UIApplication.shared.alternateIconName)
    @State private var hint: String?
    @State private var busy = false
    @AppStorage(PrefKey.accent) private var accentRaw = TweakDefault.accent
    private var accent: Color { Color(hex: (AccentChoice(rawValue: accentRaw) ?? .kickNeon).hex) }
    private var accentText: Color { Color(hex: (AccentChoice(rawValue: accentRaw) ?? .kickNeon).textHex) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("App icon")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(AppIconChoice.allCases) { choice in
                        Button { select(choice) } label: { tile(choice) }
                            .buttonStyle(.plain)
                            .disabled(busy)
                            .accessibilityLabel("\(choice.label) icon")
                            .accessibilityAddTraits(current == choice ? .isSelected : [])
                    }
                }
                .padding(.vertical, 4).padding(.horizontal, 2)
            }
            if !UIApplication.shared.supportsAlternateIcons {
                Text("This install doesn't support alternate icons.").font(.caption).foregroundStyle(.kuSecondary)
            }
            if let hint { Text(hint).font(.caption).foregroundStyle(.orange) }
        }
    }

    private func tile(_ c: AppIconChoice) -> some View {
        VStack(spacing: 6) {
            Image(c.previewAssetName)
                .resizable().interpolation(.high)
                .frame(width: 60, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 13.5, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(current == c ? accent : .clear, lineWidth: 2.5).padding(-4))
            Text(c.label).font(.caption2).foregroundStyle(current == c ? accentText : .kuSecondary).lineLimit(1)
        }
        .frame(width: 70)
    }

    private func select(_ c: AppIconChoice) {
        guard c != current, UIApplication.shared.supportsAlternateIcons else { return }
        busy = true; hint = nil
        Task { @MainActor in
            do {
                try await UIApplication.shared.setAlternateIconName(c.alternateIconName)
                current = c
            } catch {
                hint = AppIconChoice.failureHint(code: (error as NSError).code)
                current = AppIconChoice(alternateIconName: UIApplication.shared.alternateIconName)
            }
            busy = false
        }
    }
}
