import Foundation

public enum AppIconChoice: String, CaseIterable, Identifiable, Sendable {
    case classic, oled, inverted, electric, crimson, gold, monoLight

    public var id: String { rawValue }

    public var alternateIconName: String? {
        switch self {
        case .classic: return nil
        case .oled: return "AppIcon-OLED"
        case .inverted: return "AppIcon-Inverted"
        case .electric: return "AppIcon-Electric"
        case .crimson: return "AppIcon-Crimson"
        case .gold: return "AppIcon-Gold"
        case .monoLight: return "AppIcon-MonoLight"
        }
    }

    public var previewAssetName: String {
        "IconPreview-" + (alternateIconName.map { String($0.dropFirst("AppIcon-".count)) } ?? "Classic")
    }

    public var label: String {
        switch self {
        case .classic: return "Classic"
        case .oled: return "OLED"
        case .inverted: return "Inverted"
        case .electric: return "Electric"
        case .crimson: return "Crimson"
        case .gold: return "Gold"
        case .monoLight: return "Mono Light"
        }
    }

    public init(alternateIconName: String?) {
        self = Self.allCases.first { $0.alternateIconName == alternateIconName } ?? .classic
    }

    public static let retiredIconNames: Set<String> = ["AppIcon-Glass"]

    public static func needsMigration(current: String?) -> Bool {
        guard let current else { return false }
        return retiredIconNames.contains(current) || !allCases.contains { $0.alternateIconName == current }
    }

    public static func failureHint(code: Int) -> String {
        if code == -54 {
            return "Your signer blocked the icon change (error -54). Signers like Feather may remove needed permissions. Re-sign with merged entitlements and try again."
        }
        return "Couldn't change the icon (error \(code)). Signers like Feather may block icon changes. Re-signing with merged entitlements usually fixes it."
    }
}
