import SwiftUI
import UIKit
import KickUnblockCore

@MainActor
enum BadgeArt {
    private static var cache: [String: UIImage] = [:]

    static func image(_ kind: ChatBadgeKind, size: CGFloat) -> UIImage {
        let side = max(10, size.rounded())
        let key = "\(kind.rawValue)-\(side)"
        if let img = cache[key] { return img }
        let rect = CGRect(x: 0, y: 0, width: side, height: side)
        let img = UIGraphicsImageRenderer(size: rect.size).image { _ in
            let c = HexColor.rgb(kind.tileHex) ?? (0.4, 0.4, 0.4)
            UIColor(red: c.r, green: c.g, blue: c.b, alpha: 1).setFill()
            UIBezierPath(roundedRect: rect, cornerRadius: side * 0.24).fill()
            let cfg = UIImage.SymbolConfiguration(pointSize: side * 0.58, weight: .bold)
            if let sym = UIImage(systemName: kind.symbol, withConfiguration: cfg)?.withTintColor(.white, renderingMode: .alwaysOriginal) {
                let s = sym.size
                let scale = min(side * 0.68 / max(s.width, 1), side * 0.68 / max(s.height, 1), 1)
                let w = s.width * scale, h = s.height * scale
                sym.draw(in: CGRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h))
            }
        }
        cache[key] = img
        return img
    }
}
