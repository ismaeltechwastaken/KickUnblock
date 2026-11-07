import Foundation

// MARK: Data & Playback

public enum DataSource: String, CaseIterable, Identifiable, Sendable {
    case website
    case official
    public var id: String { rawValue }
    public var label: String { self == .website ? "Website Data Mode" : "Official Public API v1" }
    public var detail: String {
        switch self {
        case .website: "Uses kick.com. Falls back to the official API if blocked."
        case .official: "Uses your own Kick developer app and Kick's web player."
        }
    }
}

public enum PlaybackSpeed {
    public static let range: ClosedRange<Double> = 0.5...2.0
    public static let presets: [Double] = [0.5, 1.0, 1.25, 1.5, 2.0]
    public static func label(_ v: Double) -> String {
        v == v.rounded() ? String(format: "%.1fx", v) : String(format: "%gx", v)
    }
    public static let step = 0.25
    public static func clamp(_ v: Double) -> Double {
        let c = min(max(v, range.lowerBound), range.upperBound)
        return (c / step).rounded() * step
    }
}

public enum SeekInterval: Int, CaseIterable, Identifiable, Sendable {
    case five = 5, ten = 10, fifteen = 15
    public var id: Int { rawValue }
    public var label: String { "\(rawValue)s" }
}

// MARK: Chat

public enum ChatSpacing: String, CaseIterable, Identifiable, Sendable {
    case compact, comfortable
    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }
    public var rowPadding: Double { self == .compact ? 1 : 5 }
}

public enum ChatFontSize {
    public static let range: ClosedRange<Double> = 11...18
    public static func clamp(_ v: Double) -> Double { min(max(v, range.lowerBound), range.upperBound) }
}

public enum LandscapeChatMode: String, CaseIterable, Identifiable, Sendable {
    case rightSplit, floating, hidden
    public var id: String { rawValue }
    public var label: String {
        switch self { case .rightSplit: "Column"; case .floating: "Overlay"; case .hidden: "Hidden" }
    }
    public var title: String { "Chat: \(label)" }
    public var symbol: String {
        switch self {
        case .rightSplit: "sidebar.right"
        case .floating: "square.stack"
        case .hidden: "eye.slash"
        }
    }
    public var next: LandscapeChatMode {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

public enum ChatPlacement: Equatable, Sendable {
    case side
    case below
    case overlay
    case none

    public static func resolve(mode: LandscapeChatMode, landscape: Bool, hasChat: Bool) -> ChatPlacement {
        guard hasChat else { return .none }
        guard landscape else { return .below }
        switch mode {
        case .rightSplit: return landscape ? .side : .below
        case .floating: return .overlay
        case .hidden: return .none
        }
    }
}

public enum OverlayGeometry {
    public static let widthRange: ClosedRange<Double> = 0.25...0.40
    public static let opacityRange: ClosedRange<Double> = 0...0.9
    public static func clampWidth(_ v: Double) -> Double { min(max(v, widthRange.lowerBound), widthRange.upperBound) }
    public static func clampOpacity(_ v: Double) -> Double { min(max(v, opacityRange.lowerBound), opacityRange.upperBound) }
}

public enum ChatLimits {
    public static let defaultMax = 300
    public static func clamp(_ n: Int) -> Int { min(max(n, 50), 2000) }
}

public enum ChatTimestamp {
    public static func format(_ date: Date, timeZone: TimeZone = .current, locale: Locale = .autoupdatingCurrent) -> String {
        let f = DateFormatter()
        f.locale = locale; f.timeZone = timeZone; f.dateStyle = .none; f.timeStyle = .short
        return f.string(from: date)
    }

    public static func streamTime(_ date: Date, since start: Date) -> String {
        PlayerClock.format(max(0, date.timeIntervalSince(start)))
    }
}

// MARK: UI / OLED

public enum OLEDBackground: String, CaseIterable, Identifiable, Sendable {
    case pureBlack, carbon
    public var id: String { rawValue }
    public var label: String { self == .pureBlack ? "Pure Black" : "Carbon" }
    public var hex: String { self == .pureBlack ? "#000000" : "#0A0A0A" }
    public var surfaceHex: String { self == .pureBlack ? "#0D0D0D" : "#121417" }
    public var cardHex: String { self == .pureBlack ? "#000000" : "#121417" }
    public var cardBorderHex: String? { self == .pureBlack ? "#1E221F" : nil }
}

public enum AccentChoice: String, CaseIterable, Identifiable, Sendable {
    case kickNeon, cyberPurple, electricBlue, crimson, gold
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .kickNeon: "Kick Neon"; case .cyberPurple: "Cyber Purple"; case .electricBlue: "Electric Blue"
        case .crimson: "Crimson"; case .gold: "Gold"
        }
    }
    public var hex: String {
        switch self {
        case .kickNeon: "#53FC18"; case .cyberPurple: "#9146FF"; case .electricBlue: "#00E5FF"
        case .crimson: "#FF3366"; case .gold: "#FFC83D"
        }
    }
    public var foregroundHex: String { Contrast.foregroundHex(on: hex) }
    public var textHex: String {
        Contrast.readableText(hex, on: OLEDBackground.allCases.flatMap(\.textBackgroundHexes))
    }
}

extension OLEDBackground {
    public var textBackgroundHexes: [String] {
        [hex, surfaceHex, cardHex, elevatedHex]
    }
    public var elevatedHex: String { self == .pureBlack ? "#1F1F1F" : "#252729" }
}

public enum TextToken: String, CaseIterable, Sendable {
    case primary, secondary, tertiary
    public var hex: String {
        switch self {
        case .primary: "#F4F5F4"
        case .secondary: "#A8ADA8"
        case .tertiary: "#8E938E"
        }
    }
}

public enum Palette {
    public struct Pair: Sendable, CustomStringConvertible {
        public let name: String
        public let foreground: String
        public let background: String
        public let minimum: Double
        public var ratio: Double { Contrast.ratio(foreground, background) ?? 0 }
        public var description: String { "\(name): \(foreground) on \(background) = \(String(format: "%.2f", ratio)) (min \(minimum))" }
    }

    public static func pairs(theme: OLEDBackground, accent: AccentChoice) -> [Pair] {
        var out: [Pair] = []
        out.append(Pair(name: "onAccent/accent", foreground: accent.foregroundHex, background: accent.hex, minimum: 4.5))
        out.append(Pair(name: "live badge", foreground: Contrast.foregroundHex(on: Contrast.liveBadgeHex),
                        background: Contrast.liveBadgeHex, minimum: 4.5))
        for bg in theme.textBackgroundHexes {
            for t in TextToken.allCases {
                out.append(Pair(name: "\(t.rawValue) text", foreground: t.hex, background: bg, minimum: 4.5))
            }
            out.append(Pair(name: "accent text", foreground: accent.textHex, background: bg, minimum: 4.5))
        }
        let tinted = Contrast.blend(accent.hex, alpha: 0.15, over: theme.cardHex)
        out.append(Pair(name: "primary on accent tint", foreground: TextToken.primary.hex, background: tinted, minimum: 4.5))
        return out
    }
}

public enum Contrast {
    public static let darkTextHex = "#080A08"
    public static let lightTextHex = "#FFFFFF"
    public static let minChatLuminance = 0.25
    public static let liveBadgeHex = "#53FC18"

    public static func blend(_ fg: String, alpha: Double, over bg: String) -> String {
        guard let f = HexColor.rgb(fg), let b = HexColor.rgb(bg) else { return bg }
        return HexColor.string((f.r * alpha + b.r * (1 - alpha), f.g * alpha + b.g * (1 - alpha), f.b * alpha + b.b * (1 - alpha)))
    }

    public static func readableText(_ hex: String, on backgrounds: [String], minimum: Double = 4.5) -> String {
        guard let c = HexColor.rgb(hex) else { return hex }
        func ok(_ h: String) -> Bool { backgrounds.allSatisfy { (ratio(h, $0) ?? 0) >= minimum } }
        var t = 0.0
        var out = HexColor.string(c)
        while !ok(out) && t < 1 {
            t = min(1, t + 0.02)
            out = HexColor.string((c.r + (1 - c.r) * t, c.g + (1 - c.g) * t, c.b + (1 - c.b) * t))
        }
        return out
    }

    public static func linearize(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    public static func luminance(r: Double, g: Double, b: Double) -> Double {
        0.2126 * linearize(r) + 0.7152 * linearize(g) + 0.0722 * linearize(b)
    }

    public static func luminance(hex: String) -> Double? {
        HexColor.rgb(hex).map { luminance(r: $0.r, g: $0.g, b: $0.b) }
    }

    public static func ratio(_ l1: Double, _ l2: Double) -> Double {
        (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    public static func ratio(_ a: String, _ b: String) -> Double? {
        guard let la = luminance(hex: a), let lb = luminance(hex: b) else { return nil }
        return ratio(la, lb)
    }

    public static func foregroundHex(on fill: String) -> String {
        guard let l = luminance(hex: fill) else { return lightTextHex }
        let dark = luminance(hex: darkTextHex) ?? 0
        return ratio(l, dark) >= ratio(l, 1) ? darkTextHex : lightTextHex
    }

    public static func readableOnDark(_ hex: String, minLuminance: Double = minChatLuminance) -> String {
        guard let c = HexColor.rgb(hex) else { return hex }
        if luminance(r: c.r, g: c.g, b: c.b) >= minLuminance { return HexColor.string(c) }
        var t = 0.0
        var out = c
        while t < 1 {
            t = min(1, t + 0.05)
            out = (c.r + (1 - c.r) * t, c.g + (1 - c.g) * t, c.b + (1 - c.b) * t)
            if luminance(r: out.r, g: out.g, b: out.b) >= minLuminance { break }
        }
        return HexColor.string(out)
    }
}

public enum ControlsAutoHide: Double, CaseIterable, Identifiable, Sendable {
    case short = 3, medium = 5, kick = 7, long = 10
    public var id: Double { rawValue }
    public var label: String { "\(Int(rawValue))s" }
    public static let `default` = ControlsAutoHide.kick
}

public enum AppTab: String, CaseIterable, Identifiable, Sendable {
    case following, browse, saved, tweaks
    public var id: String { rawValue }
    public var label: String {
        switch self { case .following: "Following"; case .browse: "Browse"; case .saved: "Saved Clips"; case .tweaks: "Tweaks" }
    }
    public var systemImage: String {
        switch self { case .following: "heart.fill"; case .browse: "square.grid.2x2.fill"; case .saved: "bookmark.fill"; case .tweaks: "slider.horizontal.3" }
    }
}

public enum OpeningScreen: String, CaseIterable, Identifiable, Sendable {
    case following, browse, saved
    public static let `default`: OpeningScreen = .browse
    public var id: String { rawValue }
    public var tab: AppTab {
        switch self { case .following: .following; case .browse: .browse; case .saved: .saved }
    }
    public var label: String { tab.label }

    public static func resolve(_ raw: String?) -> OpeningScreen { raw.flatMap(OpeningScreen.init(rawValue:)) ?? .default }

    public static func current(_ d: UserDefaults = .standard) -> OpeningScreen { resolve(d.string(forKey: PrefKey.openingScreen)) }
}

public enum TabRestoration {
    public static func resolve(savedTab: String?, savedLaunchID: String?, currentLaunchID: String, opening: OpeningScreen) -> AppTab {
        guard savedLaunchID == currentLaunchID, let savedTab, let tab = AppTab(rawValue: savedTab) else { return opening.tab }
        return tab
    }
}

public enum ChromeStyle: String, CaseIterable, Identifiable, Sendable {
    case system
    case classic
    case solid
    public static let `default`: ChromeStyle = .system
    public var id: String { rawValue }
    public var label: String {
        switch self { case .system: "System"; case .classic: "Classic"; case .solid: "Solid" }
    }

    public enum Resolved: Equatable, Sendable {
        case nativeGlass, classic, solid
        public var usesGlass: Bool { self == .nativeGlass }
    }

    public static func resolve(_ raw: String?) -> ChromeStyle { raw.flatMap(ChromeStyle.init(rawValue:)) ?? .default }

    public static func resolved(raw: String?, osMajorVersion: Int, reduceTransparency: Bool) -> Resolved {
        if reduceTransparency { return .solid }
        switch resolve(raw) {
        case .system: return osMajorVersion >= 26 ? .nativeGlass : .classic
        case .classic: return .classic
        case .solid: return .solid
        }
    }
}

public enum PrivacyCopy {
    public static let playerTelemetry = "Live video uses Amazon IVS. It sends playback telemetry to Amazon."
    public static let noAddedAnalytics = "KickUnblock adds no third-party analytics, ads or tracking."
    public static let diagnostics = "Diagnostics stay on this device. Off by default. You choose to share."
    public static var aboutFooter: String {
        "Not affiliated with Kick. " + noAddedAnalytics + " " + playerTelemetry + " Wordmark in Space Grotesk (OFL 1.1)."
    }
    public static var allText: String { [playerTelemetry, noAddedAnalytics, diagnostics, aboutFooter].joined(separator: "\n") }
}

public enum HexColor {
    public static func rgb(_ hex: String) -> (r: Double, g: Double, b: Double)? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }

    public static func string(_ c: (r: Double, g: Double, b: Double)) -> String {
        func b(_ x: Double) -> Int { Int((min(1, max(0, x)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", b(c.r), b(c.g), b(c.b))
    }
}
