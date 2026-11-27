import AppKit
import Combine
import SwiftUI

/// Only the small native window remains when collapsed; no invisible full-card region blocks other apps.
struct MailFloatingRailView: View {
    let store: MailStore
    @ObservedObject var controller: MailFloatingController
    @State private var status = MailFloatingRailStatus()

    private var color: Color { PortalTheme.accent }

    var body: some View {
        Button(action: controller.expand) {
            Capsule(style: .continuous)
                .fill(color.opacity(status.hasUnread ? 0.96 : 0.82))
                .frame(width: MailFloatingController.railVisualSize.width, height: MailFloatingController.railVisualSize.height)
                .overlay(alignment: .top) {
                    if status.needsAttention { Circle().fill(Color.orange).frame(width: 3, height: 3).padding(.top, 5) }
                }
                .frame(width: MailFloatingController.railHitSize.width, height: MailFloatingController.railHitSize.height, alignment: controller.isOnLeft ? .leading : .trailing)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(MailFloatingRailTrackingView(onPointerChanged: { controller.railPointerChanged() }).accessibilityHidden(true))
        .accessibilityLabel(status.needsAttention ? "搞门户 · 邮件，邮箱待检查" : status.hasUnread ? "搞门户 · 邮件，有缓存未读邮件" : "搞门户 · 邮件悬浮窗")
        .onReceive(statusUpdates) { next in
            if next != status { status = next }
        }
    }

    private var statusUpdates: some Publisher<MailFloatingRailStatus, Never> {
        store.$library.map(\.accounts).removeDuplicates()
            .combineLatest(store.$messages, store.$problem.map { $0 != nil }.removeDuplicates())
            .map { accounts, messages, hasProblem in
                MailFloatingRailStatus(accounts: accounts, messages: messages, hasProblem: hasProblem)
            }
            .removeDuplicates()
    }
}

private struct MailFloatingRailTrackingView: NSViewRepresentable {
    var onPointerChanged: () -> Void
    func makeNSView(context: Context) -> TrackingView { let view = TrackingView(); view.onPointerChanged = onPointerChanged; return view }
    func updateNSView(_ view: TrackingView, context: Context) { view.onPointerChanged = onPointerChanged }

    final class TrackingView: NSView {
        var onPointerChanged: (() -> Void)?
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }
        override func mouseEntered(with event: NSEvent) { onPointerChanged?() }
        override func mouseExited(with event: NSEvent) { onPointerChanged?() }
    }
}
