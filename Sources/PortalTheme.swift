import SwiftUI
import AppKit

enum PortalTheme {
    static let accent = Color(red: 0.39, green: 0.36, blue: 0.87)
    static let accentNS = NSColor(calibratedRed: 0.39, green: 0.36, blue: 0.87, alpha: 1)
    static let canvas = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.09, green: 0.09, blue: 0.11, alpha: 1)
            : NSColor(calibratedRed: 0.965, green: 0.957, blue: 0.937, alpha: 1)
    })
    static let panel = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.14, green: 0.14, blue: 0.17, alpha: 1)
            : NSColor(calibratedRed: 1.0, green: 0.996, blue: 0.984, alpha: 1)
    })
}

struct PortalStatusBadge: View {
    let title: String
    var tint: Color = PortalTheme.accent
    var body: some View {
        Text(title).font(.caption.weight(.medium)).padding(.horizontal, 9).padding(.vertical, 4)
            .foregroundStyle(tint).background(tint.opacity(0.11), in: Capsule())
    }
}

struct PortalCard: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(20).background(PortalTheme.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.primary.opacity(0.07), lineWidth: 1))
    }
}

extension View {
    func portalCard() -> some View { modifier(PortalCard()) }
}
