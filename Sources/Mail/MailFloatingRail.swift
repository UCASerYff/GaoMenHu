import AppKit
import SwiftUI

/// Only the small native window remains when collapsed; no invisible full-card region blocks other apps.
struct MailFloatingRailView: View {
    @ObservedObject var controller: MailFloatingController
    var unreadCount: Int = 0
    var errorCount: Int = 0

    private var color: Color { Color(red: 0.72, green: 0.63, blue: 0.90) }

    var body: some View {
        Button(action: controller.expand) {
            Capsule(style: .continuous)
                .fill(color.opacity(unreadCount > 0 ? 0.96 : 0.82))
                .frame(width: MailFloatingController.railVisualSize.width, height: MailFloatingController.railVisualSize.height)
                .overlay(alignment: .top) {
                    if errorCount > 0 { Circle().fill(Color.orange).frame(width: 3, height: 3).padding(.top, 5) }
                }
                .frame(width: MailFloatingController.railHitSize.width, height: MailFloatingController.railHitSize.height, alignment: controller.isOnLeft ? .leading : .trailing)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(MailFloatingRailTrackingView(onEnter: { controller.railPointerEntered() }, onExit: { controller.railPointerExited() }).accessibilityHidden(true))
        .accessibilityLabel(errorCount > 0 ? "搞门户 · 邮件，邮箱待检查" : unreadCount > 0 ? "搞门户 · 邮件，有缓存未读邮件" : "搞门户 · 邮件悬浮窗")
    }
}

private struct MailFloatingRailTrackingView: NSViewRepresentable {
    var onEnter: () -> Void
    var onExit: () -> Void
    func makeNSView(context: Context) -> TrackingView { let view = TrackingView(); view.onEnter = onEnter; view.onExit = onExit; return view }
    func updateNSView(_ view: TrackingView, context: Context) { view.onEnter = onEnter; view.onExit = onExit }

    final class TrackingView: NSView {
        var onEnter: (() -> Void)?
        var onExit: (() -> Void)?
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }
        override func mouseEntered(with event: NSEvent) { onEnter?() }
        override func mouseExited(with event: NSEvent) { onExit?() }
        override func mouseDown(with event: NSEvent) { onEnter?() }
    }
}
