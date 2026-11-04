import AppKit
import Combine
import SwiftUI

/// A drag ends on a native mouse-up event, never on return from an asynchronous AppKit request.
struct MailFloatingDragSession {
    private(set) var isPressed = false
    private(set) var didDrag = false
    private var pressedAt = NSPoint.zero
    private var grabOffset = NSSize.zero
    static let threshold: CGFloat = 4

    mutating func begin(pointer: NSPoint, frame: NSRect) {
        isPressed = true
        didDrag = false
        pressedAt = pointer
        grabOffset = NSSize(width: pointer.x - frame.minX, height: pointer.y - frame.minY)
    }

    mutating func carry(pointer: NSPoint) -> NSSize? {
        guard isPressed else { return nil }
        if !didDrag && hypot(pointer.x - pressedAt.x, pointer.y - pressedAt.y) >= Self.threshold { didDrag = true }
        return didDrag ? grabOffset : nil
    }

    mutating func finish() -> Bool? {
        guard isPressed else { return nil }
        let moved = didDrag
        isPressed = false
        didDrag = false
        return moved
    }
}

enum MailFloatingDockMode: String, Sendable {
    case free, left, right
}

/// A nonactivating utility panel: showing mail counts never takes focus from the user's current app.
@MainActor
private final class MailFloatingPanel: NSPanel {
    var dismiss: (() -> Void)?
    var allowsKey = true
    var containsVisiblePoint: ((NSPoint) -> Bool)?
    var onPressChanged: ((Bool) -> Void)?
    var onDrag: ((NSPoint, NSSize) -> Void)?
    var onRelease: ((Bool) -> Void)?
    private var dragSession = MailFloatingDragSession()
    var isPressed: Bool { dragSession.isPressed }
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { dismiss?() }
        else { super.keyDown(with: event) }
    }

    /// Window-level interception precedes NSHostingView hit testing and works from another foreground app.
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            if isGrabEvent(event) {
                dragSession.begin(pointer: convertPoint(toScreen: event.locationInWindow), frame: frame)
                onPressChanged?(true)
                return
            }
        case .leftMouseDragged where isPressed:
            let pointer = convertPoint(toScreen: event.locationInWindow)
            if let offset = dragSession.carry(pointer: pointer) { onDrag?(pointer, offset) }
            return
        case .leftMouseUp where isPressed:
            if let dragged = dragSession.finish() {
                onPressChanged?(false)
                onRelease?(dragged)
            }
            return
        default: break
        }
        super.sendEvent(event)
    }

    func cancelInteraction() {
        if dragSession.finish() != nil { onPressChanged?(false) }
    }

    func isGrabEvent(_ event: NSEvent) -> Bool {
        guard event.type == .leftMouseDown, !event.modifierFlags.contains(.control) else { return false }
        let pointer = convertPoint(toScreen: event.locationInWindow)
        guard containsVisiblePoint?(pointer) ?? frame.contains(pointer) else { return false }
        if !allowsKey { return true }
        // The shared fixed statistics header is pure display. Hit it before SwiftUI's responder tree.
        return pointer.y >= frame.maxY - min(MailFloatingController.dragHeaderHeight, frame.height)
    }
}

@MainActor
final class MailFloatingController: NSObject, ObservableObject, NSWindowDelegate, NSMenuDelegate {
    @Published private(set) var isVisible = false
    @Published private(set) var isExpanded = false
    @Published private(set) var isOnLeft = false
    @Published private(set) var expandedHeight: CGFloat = 280
    @Published var showPreviews: Bool {
        didSet { defaults.set(showPreviews, forKey: Key.previews) }
    }
    @Published var opacity: Double {
        didSet {
            let safe = Self.safeOpacity(opacity)
            if opacity != safe { opacity = safe }
            defaults.set(safe, forKey: Key.opacity)
            panel?.alphaValue = safe
        }
    }

    var onOpenInbox: ((UUID?, String?) -> Void)?
    var onCompose: ((UUID?) -> Void)?
    var onOpenSettings: (() -> Void)?

    private let store: MailStore
    private let defaults: UserDefaults
    private var panel: MailFloatingPanel?
    private var statusItem: NSStatusItem?
    private var visibilityMenuItem: NSMenuItem?
    private var didRestoreVisibility = false
    private var isApplyingFrame = false
    private var savedVisible: Bool
    private var rememberedDisplay: String?
    private var dockMode: MailFloatingDockMode
    private var horizontalRatio: Double
    private var verticalRatio: Double
    private var pointerTimer: Timer?
    private var lastInsideAt = Date()
    private var outsideSince: Date?
    private var eventMonitors: [Any] = []
    private var requestedExpandedHeight: CGFloat = 280
    private var revealRequiresExit = false
    private var hoverStartedAt: Date?
    #if DEBUG_TESTING
    private var suppressPanelPresentationForTesting = false
    // Cursor-safe QA input does not move the real pointer. Pause only polling collapse for layout inspection.
    private let isLayoutPreviewForTesting = ProcessInfo.processInfo.arguments.contains("--layout-preview")
    #endif
    private static let margin: CGFloat = 12
    static let expandedSize = NSSize(width: 340, height: 280)
    static let railHitSize = NSSize(width: 20, height: 104)
    static let railVisualSize = NSSize(width: 6, height: 88)
    static let cardCornerRadius: CGFloat = 18
    static let dragHeaderHeight: CGFloat = 80
    static let dockDistance: CGFloat = 32
    private static let pointerInterval: TimeInterval = 0.04
    private static let leaveDelay: TimeInterval = 0.08

    private enum Key {
        static let visible = "gaomenhu.mail.floating.visible"
        static let previews = "gaomenhu.mail.floating.showPreviews"
        static let opacity = "gaomenhu.mail.floating.opacity"
        static let display = "gaomenhu.mail.floating.display"
        static let horizontal = "gaomenhu.mail.floating.horizontalRatio"
        static let vertical = "gaomenhu.mail.floating.verticalRatio"
        static let edge = "gaomenhu.mail.floating.edge"
        static let dock = "gaomenhu.mail.floating.dockMode"
    }

    init(store: MailStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        savedVisible = defaults.object(forKey: Key.visible) as? Bool ?? false
        showPreviews = defaults.bool(forKey: Key.previews)
        opacity = Self.safeOpacity(defaults.object(forKey: Key.opacity) as? Double ?? 1)
        rememberedDisplay = defaults.string(forKey: Key.display)
        let savedSide = defaults.string(forKey: Key.edge)
        let restoredDock = defaults.string(forKey: Key.dock).flatMap(MailFloatingDockMode.init(rawValue:))
            ?? (savedSide == "left" ? .left : .right)
        dockMode = restoredDock
        let savedHorizontal = defaults.object(forKey: Key.horizontal) as? Double ?? (savedSide == "left" ? 0 : 1)
        let restoredHorizontal = Self.safeRatio(savedHorizontal, fallback: savedSide == "left" ? 0 : 1)
        horizontalRatio = restoredHorizontal
        let rememberedRatio = defaults.object(forKey: Key.vertical) as? Double ?? 0.15
        verticalRatio = Self.safeRatio(rememberedRatio, fallback: 0.15)
        isOnLeft = restoredDock == .left || (restoredDock == .free &&
            (savedSide == "left" || (savedSide != "right" && savedSide != "left" && restoredHorizontal < 0.5)))
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(willTerminate), name: NSApplication.willTerminateNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appearanceChanged), name: .mailAppearanceChanged, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        pointerTimer?.invalidate()
        eventMonitors.forEach { NSEvent.removeMonitor($0) }
    }

    /// Call after the app's main-window and Settings actions have been connected.
    func restoreIfNeeded() {
        installMenuBarItemIfNeeded()
        guard !didRestoreVisibility else { return }
        didRestoreVisibility = true
        if savedVisible { show() }
    }

    func show() {
        installMenuBarItemIfNeeded()
        guard panel?.isPressed != true else { return }
        guard !NSScreen.screens.isEmpty else { return }
        let window = ensurePanel()
        isVisible = true
        isExpanded = false
        revealRequiresExit = false
        hoverStartedAt = nil
        outsideSince = nil
        window.allowsKey = false
        window.isMovableByWindowBackground = false
        window.hasShadow = false
        window.contentView?.layer?.cornerRadius = 0
        applyRestoredFrame(to: window)
        window.level = .floating
        window.alphaValue = Self.safeOpacity(opacity)
        presentPanel(window)
        lastInsideAt = Date()
        startPointerWatcher()
        startMouseObservers()
        savedVisible = true
        defaults.set(true, forKey: Key.visible)
    }

    func hide() {
        panel?.cancelInteraction()
        panel?.orderOut(nil)
        stopPointerWatcher()
        stopMouseObservers()
        isVisible = false
        isExpanded = false
        revealRequiresExit = false
        savedVisible = false
        persistPosition()
        defaults.set(false, forKey: Key.visible)
    }

    func toggle() { isVisible ? hide() : show() }

    /// Reveal the card from the tiny native edge hit window, without activating the application.
    func expand() { expand(pointer: NSEvent.mouseLocation, now: Date()) }

    private func expand(pointer: NSPoint, now: Date) {
        guard isVisible, let panel, !panel.isPressed else { return }
        if revealRequiresExit && panel.frame.contains(pointer) { return }
        revealRequiresExit = false
        hoverStartedAt = nil
        lastInsideAt = now
        outsideSince = nil
        guard !isExpanded else { return }
        isExpanded = true
        panel.allowsKey = true
        panel.isMovableByWindowBackground = false
        panel.hasShadow = true
        panel.contentView?.layer?.cornerRadius = Self.cardCornerRadius
        applyRestoredFrame(to: panel)
        presentPanel(panel)
    }

    func railPointerExited() {
        hoverStartedAt = nil
        guard let panel, !panel.frame.contains(NSEvent.mouseLocation) else { return }
        revealRequiresExit = false
    }

    func railPointerEntered() {
        guard isVisible, !isExpanded, panel?.isPressed != true, !revealRequiresExit else { return }
        hoverStartedAt = Date()
    }

    /// Keep the feature enabled while replacing the actual window frame with its 20 × 104 hit area.
    func collapse() { collapse(pointer: NSEvent.mouseLocation, now: Date()) }

    private func collapse(pointer: NSPoint, now: Date) {
        guard isVisible, let panel, !panel.isPressed else { return }
        isExpanded = false
        panel.allowsKey = false
        panel.isMovableByWindowBackground = false
        panel.hasShadow = false
        panel.contentView?.layer?.cornerRadius = 0
        if panel.isKeyWindow { panel.resignKey() }
        applyRestoredFrame(to: panel)
        hoverStartedAt = nil
        lastInsideAt = now
        outsideSince = nil
        revealRequiresExit = panel.frame.contains(pointer)
        presentPanel(panel)
    }

    /// The natural SwiftUI card height never includes the collapsed rail.
    func updateExpandedHeight(_ ideal: CGFloat) {
        guard ideal.isFinite, ideal > 0 else { return }
        let requested = ceil(ideal)
        guard requestedExpandedHeight != requested else { return }
        requestedExpandedHeight = requested
        guard panel?.isPressed != true else { return }
        let previousHeight = expandedHeight
        refreshExpandedHeight()
        if expandedHeight != previousHeight, isExpanded, let panel { applyRestoredFrame(to: panel) }
    }

    /// Finish the native gesture. Carrying already decided free/docked placement; release only saves it.
    func finishDragging() {
        guard let panel, !panel.isPressed else { return }
        persistPosition()
        applyRestoredFrame(to: panel)
        lastInsideAt = Date()
    }

    func openInbox(accountID: UUID? = nil, messageID: String? = nil) {
        collapse()
        onOpenInbox?(accountID, messageID)
    }

    func compose(accountID: UUID? = nil) { collapse(); onCompose?(accountID) }
    func openSettings() { collapse(); onOpenSettings?() }

    func resetPosition() {
        guard panel?.isPressed != true else { return }
        defaults.removeObject(forKey: Key.display)
        defaults.removeObject(forKey: Key.horizontal)
        defaults.removeObject(forKey: Key.vertical)
        defaults.removeObject(forKey: Key.edge)
        defaults.removeObject(forKey: Key.dock)
        rememberedDisplay = nil
        dockMode = .right
        horizontalRatio = 1
        verticalRatio = 0.15
        isOnLeft = false
        if let panel { applyRestoredFrame(to: panel, persistResolvedDisplay: false) }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

    func windowDidMove(_ notification: Notification) {
        guard !isApplyingFrame, let panel, notification.object as? NSWindow === panel else { return }
        lastInsideAt = Date()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        guard !isApplyingFrame, let panel, notification.object as? NSWindow === panel else { return }
        lastInsideAt = Date()
    }

    func menuWillOpen(_ menu: NSMenu) {
        visibilityMenuItem?.title = isVisible ? "隐藏悬浮窗" : "显示悬浮窗"
    }

    private func installMenuBarItemIfNeeded() {
        #if DEBUG_TESTING
        if suppressPanelPresentationForTesting { return }
        #endif
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "envelope", accessibilityDescription: "搞门户 · 邮件")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = "搞门户 · 邮件"
        let menu = NSMenu()
        menu.delegate = self
        let visibility = NSMenuItem(title: isVisible ? "隐藏悬浮窗" : "显示悬浮窗", action: #selector(toggleFromMenu), keyEquivalent: "")
        visibility.target = self
        menu.addItem(visibility)
        visibilityMenuItem = visibility
        menu.addItem(.separator())
        for (title, action) in [("打开收件箱", #selector(openInboxFromMenu)), ("写邮件", #selector(composeFromMenu)), ("悬浮窗设置…", #selector(settingsFromMenu))] {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出搞门户 · 邮件", action: #selector(quitFromMenu), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
    }

    @objc private func toggleFromMenu() { toggle() }
    @objc private func openInboxFromMenu() { openInbox() }
    @objc private func composeFromMenu() { compose() }
    @objc private func settingsFromMenu() { openSettings() }
    @objc private func quitFromMenu() { NSApp.terminate(nil) }
    @objc private func appearanceChanged() { panel?.appearance = MailAppearance.current.nativeAppearance }

    @objc private func screensChanged() {
        guard let panel, !panel.isPressed else { return }
        // A remembered external display may have disappeared, so choose a connected screen first.
        applyRestoredFrame(to: panel)
    }

    @objc private func willTerminate() {
        persistPosition()
        stopPointerWatcher()
        stopMouseObservers()
        // Do not call hide(): a visible panel should return on the next launch.
        defaults.set(isVisible, forKey: Key.visible)
    }

    private func startMouseObservers() {
        #if DEBUG_TESTING
        if suppressPanelPresentationForTesting { return }
        #endif
        guard eventMonitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp]
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { _ = self?.observeLocalMouseEvent(event) }
            return event
        }) { eventMonitors.append(local) }
        // Global mouse-only observation needs no Accessibility permission and never changes the source event.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.observeMouseEvent(event, isGlobal: true) }
        }) { eventMonitors.append(global) }
    }

    private func stopMouseObservers() {
        eventMonitors.forEach { NSEvent.removeMonitor($0) }
        eventMonitors.removeAll()
    }

    private func observeLocalMouseEvent(_ event: NSEvent) -> NSEvent {
        observeMouseEvent(event, isGlobal: false)
        return event
    }

    private func observeMouseEvent(_ event: NSEvent, isGlobal: Bool) {
        guard isVisible, let panel else { return }
        let belongsToPanel = !isGlobal && event.window === panel
        let pointer = belongsToPanel ? panel.convertPoint(toScreen: event.locationInWindow) : NSEvent.mouseLocation
        if event.type == .leftMouseUp {
            // A release delivered elsewhere must not leave our previous gesture latched forever.
            if !belongsToPanel, panel.isPressed {
                panel.cancelInteraction()
                finishDragging()
                let previousHeight = expandedHeight
                refreshExpandedHeight()
                if expandedHeight != previousHeight, isExpanded { applyRestoredFrame(to: panel) }
                outsideSince = nil
            }
            return
        }
        guard [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) else { return }
        if belongsToPanel && containsVisiblePoint(pointer) { return }
        panel.cancelInteraction()
        hoverStartedAt = nil
        revealRequiresExit = false
        collapse(pointer: pointer, now: Date())
    }

    private func startPointerWatcher() {
        guard pointerTimer == nil else { return }
        let timer = Timer(timeInterval: Self.pointerInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkPointer() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pointerTimer = timer
    }

    private func stopPointerWatcher() {
        pointerTimer?.invalidate()
        pointerTimer = nil
        hoverStartedAt = nil
        outsideSince = nil
    }

    private func checkPointer() {
        evaluatePointer(pointer: NSEvent.mouseLocation, now: Date())
    }

    private func evaluatePointer(pointer: NSPoint, now: Date) {
        guard isVisible, let panel else { return }
        guard !panel.isPressed else { hoverStartedAt = nil; outsideSince = nil; return }
        let inside = containsVisiblePoint(pointer)
        if !isExpanded {
            if revealRequiresExit {
                if !inside { revealRequiresExit = false }
                return
            }
            if !inside { hoverStartedAt = nil; return }
            if hoverStartedAt == nil { hoverStartedAt = now }
            if let hoverStartedAt, now.timeIntervalSince(hoverStartedAt) >= 0.28 { expand(pointer: pointer, now: now) }
            return
        }
        if inside {
            lastInsideAt = now
            outsideSince = nil
            return
        }
        #if DEBUG_TESTING
        if isLayoutPreviewForTesting { outsideSince = nil; return }
        #endif
        if outsideSince == nil { outsideSince = now }
        if let outsideSince, now.timeIntervalSince(outsideSince) >= Self.leaveDelay { collapse(pointer: pointer, now: now) }
    }

    private func containsVisiblePoint(_ point: NSPoint) -> Bool {
        guard let panel else { return false }
        return isExpanded ? Self.roundedCardContains(point, in: panel.frame) : panel.frame.contains(point)
    }

    private func ensurePanel() -> MailFloatingPanel {
        if let panel { return panel }
        let window = MailFloatingPanel(contentRect: NSRect(origin: .zero, size: desiredSize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.title = "搞门户 · 邮件 · 悬浮窗"
        window.identifier = NSUserInterfaceItemIdentifier("GaoMenHu.Mail.Floating")
        window.appearance = MailAppearance.current.nativeAppearance
        window.delegate = self
        window.dismiss = { [weak self] in
            guard let self else { return }
            self.panel?.cancelInteraction()
            self.collapse()
        }
        window.containsVisiblePoint = { [weak self] point in self?.containsVisiblePoint(point) ?? false }
        window.onPressChanged = { [weak self] _ in
            self?.hoverStartedAt = nil
            self?.outsideSince = nil
            self?.lastInsideAt = Date()
        }
        window.onDrag = { [weak self] pointer, offset in self?.movePanel(pointer: pointer, grabOffset: offset) }
        window.onRelease = { [weak self] dragged in
            guard let self else { return }
            if dragged { self.finishDragging() }
            else if !self.isExpanded { self.revealRequiresExit = false; self.expand() }
            self.refreshExpandedHeight()
            if self.isExpanded, let panel = self.panel { self.applyRestoredFrame(to: panel) }
            if !self.isExpanded, let panel = self.panel {
                self.revealRequiresExit = panel.frame.contains(NSEvent.mouseLocation)
            }
            self.hoverStartedAt = nil
            self.outsideSince = nil
            self.lastInsideAt = Date()
        }
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = false
        window.allowsKey = isExpanded
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = isExpanded
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.level = .floating
        window.alphaValue = opacity
        let hosting = MailFloatingHostingView(rootView: MailFloatingView(store: store, controller: self))
        hosting.onPointerChanged = { [weak self] pointer in self?.evaluatePointer(pointer: pointer, now: Date()) }
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = isExpanded ? Self.cardCornerRadius : 0
        hosting.layer?.masksToBounds = true
        window.contentView = hosting
        panel = window
        return window
    }

    private var desiredSize: NSSize { isExpanded ? NSSize(width: Self.expandedSize.width, height: expandedHeight) : Self.railHitSize }

    private func refreshExpandedHeight(for screen: NSScreen? = nil) {
        guard panel?.isPressed != true else { return }
        let available = (screen ?? preferredScreen())?.visibleFrame.height ?? 420
        let height = Self.safeExpandedHeight(requestedExpandedHeight, availableHeight: available)
        if expandedHeight != height { expandedHeight = height }
    }

    private func presentPanel(_ panel: MailFloatingPanel) {
        #if DEBUG_TESTING
        // Hidden framework unit tests invoke the real state transitions without presenting a window.
        if suppressPanelPresentationForTesting { return }
        #endif
        panel.orderFrontRegardless()
    }

    private func applyRestoredFrame(to panel: NSWindow, persistResolvedDisplay: Bool = true) {
        guard (panel as? MailFloatingPanel)?.isPressed != true else { return }
        guard let screen = preferredScreen() else { return }
        refreshExpandedHeight(for: screen)
        let connectedDisplay = Self.displayIdentifier(screen)
        if rememberedDisplay != connectedDisplay {
            rememberedDisplay = connectedDisplay
            if persistResolvedDisplay { persistPosition() }
        }
        setFrame(Self.placementFrame(size: desiredSize, in: screen.visibleFrame, dock: dockMode,
                                     isLeft: isOnLeft, horizontalRatio: horizontalRatio, verticalRatio: verticalRatio), on: panel)
    }

    private func movePanel(pointer: NSPoint, grabOffset: NSSize) {
        guard let panel, panel.isPressed,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? panel.screen ?? preferredScreen() else { return }
        let candidate = Self.draggingFrame(pointer: pointer, grabOffset: grabOffset, size: panel.frame.size, in: screen.visibleFrame)
        let mode = Self.dockMode(for: candidate, in: screen.visibleFrame)
        let carried = Self.snappedFrame(candidate, in: screen.visibleFrame, dock: mode)
        setFrame(carried, on: panel)
        // AppKit can align the requested frame to pixels. Remember the real result, not the request.
        recordPlacement(frame: panel.frame, in: screen, mode: mode)
    }

    private func recordPlacement(frame: NSRect, in screen: NSScreen, mode: MailFloatingDockMode) {
        dockMode = mode
        if mode != .free { isOnLeft = mode == .left }
        else if !isExpanded { isOnLeft = Self.nearestEdgeIsLeft(for: frame, in: screen.visibleFrame) }
        // A free expanded card retains its opening direction even when dragged across the screen's midpoint.
        let ratios = Self.anchorRatios(for: frame, in: screen.visibleFrame, isLeft: isOnLeft)
        horizontalRatio = mode == .left ? 0 : mode == .right ? 1 : ratios.horizontal
        verticalRatio = ratios.vertical
        rememberedDisplay = Self.displayIdentifier(screen)
    }

    private func setFrame(_ frame: NSRect, on panel: NSWindow) {
        isApplyingFrame = true
        panel.setFrame(frame, display: true)
        isApplyingFrame = false
    }

    private func persistPosition() {
        defaults.set(rememberedDisplay, forKey: Key.display)
        defaults.set(isOnLeft ? "left" : "right", forKey: Key.edge)
        defaults.set(dockMode.rawValue, forKey: Key.dock)
        defaults.set(horizontalRatio, forKey: Key.horizontal)
        defaults.set(verticalRatio, forKey: Key.vertical)
    }

    private func preferredScreen() -> NSScreen? {
        if let identifier = rememberedDisplay,
           let screen = NSScreen.screens.first(where: { Self.displayIdentifier($0) == identifier }) { return screen }
        return NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func screenContaining(_ frame: NSRect) -> NSScreen? {
        NSScreen.screens.max { lhs, rhs in
            let l = lhs.frame.intersection(frame), r = rhs.frame.intersection(frame)
            return max(0, l.width) * max(0, l.height) < max(0, r.width) * max(0, r.height)
        }
    }

    private static func displayIdentifier(_ screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(CGDirectDisplayID(number.uint32Value)) else { return nil }
        return CFUUIDCreateString(nil, uuid.takeRetainedValue()) as String
    }

    static func safeOpacity(_ value: Double) -> Double { value.isFinite ? min(max(value, 0.65), 1) : 1 }

    static func safeRatio(_ value: Double, fallback: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : min(max(fallback.isFinite ? fallback : 0.5, 0), 1)
    }

    static func safeExpandedHeight(_ ideal: CGFloat, availableHeight: CGFloat) -> CGFloat {
        let limit = availableHeight.isFinite ? min(max(availableHeight, 1), 420) : 420
        return min(max(ideal.isFinite ? ceil(ideal) : 280, 1), limit)
    }

    /// Match the card's circular 18 pt clipping, including the transparent corner cutouts.
    static func roundedCardContains(_ point: NSPoint, in frame: NSRect) -> Bool {
        guard point.x.isFinite, point.y.isFinite, frame.contains(point) else { return false }
        let radius = min(cardCornerRadius, frame.width / 2, frame.height / 2)
        let x = min(max(point.x, frame.minX + radius), frame.maxX - radius)
        let y = min(max(point.y, frame.minY + radius), frame.maxY - radius)
        return pow(point.x - x, 2) + pow(point.y - y, 2) <= radius * radius
    }

    static func nearestEdgeIsLeft(for frame: NSRect, in visible: NSRect) -> Bool { frame.midX < visible.midX }

    static func dockMode(for frame: NSRect, in visible: NSRect) -> MailFloatingDockMode {
        let left = max(frame.minX - visible.minX, 0)
        let right = max(visible.maxX - frame.maxX, 0)
        guard left <= dockDistance || right <= dockDistance else { return .free }
        return left <= right ? .left : .right
    }

    static func snappedFrame(_ requested: NSRect, in visible: NSRect, dock: MailFloatingDockMode) -> NSRect {
        var frame = requested
        if dock == .left { frame.origin.x = visible.minX }
        else if dock == .right { frame.origin.x = visible.maxX - frame.width }
        return frame
    }

    /// Store the small rail's top and side anchor rather than the card's changing dimensions.
    static func anchorRatios(for frame: NSRect, in visible: NSRect, isLeft: Bool) -> (horizontal: Double, vertical: Double) {
        let railWidth = min(railHitSize.width, max(visible.width, 1))
        let railHeight = min(railHitSize.height, max(visible.height, 1))
        let x = isLeft ? frame.minX : frame.maxX - railWidth
        let across = max(visible.width - railWidth, 0)
        let down = max(visible.height - railHeight, 0)
        let horizontal = across > 0 ? Double((x - visible.minX) / across) : 0.5
        let vertical = down > 0 ? Double((visible.maxY - frame.maxY) / down) : 0
        return (safeRatio(horizontal, fallback: 0.5), safeRatio(vertical, fallback: 0.15))
    }

    /// A raw reachable candidate. The caller decides 32 pt side docking during this same drag event.
    static func draggingFrame(pointer: NSPoint, grabOffset: NSSize, size: NSSize, in visible: NSRect) -> NSRect {
        let width = min(max(size.width, 1), max(visible.width, 1))
        let height = min(max(size.height, 1), max(visible.height, 1))
        let x = min(max(pointer.x - grabOffset.width, visible.minX), visible.maxX - width)
        let y = min(max(pointer.y - grabOffset.height, visible.minY), visible.maxY - height)
        return NSRect(x: x, y: y, width: width, height: height)
    }

    /// Both forms use the rail's top anchor, so a reveal keeps the user's pointer inside the card.
    static func edgeFrame(size: NSSize, in visible: NSRect, isLeft: Bool, verticalRatio: Double) -> NSRect {
        placementFrame(size: size, in: visible, dock: isLeft ? .left : .right, isLeft: isLeft,
                       horizontalRatio: isLeft ? 0 : 1, verticalRatio: verticalRatio)
    }

    static func placementFrame(size: NSSize, in visible: NSRect, dock: MailFloatingDockMode,
                               isLeft: Bool, horizontalRatio: Double, verticalRatio: Double) -> NSRect {
        let ratio = safeRatio(verticalRatio, fallback: 0.15)
        let width = min(max(size.width, 1), max(visible.width, 1))
        let height = min(max(size.height, 1), max(visible.height, 1))
        let railWidth = min(railHitSize.width, max(visible.width, 1))
        let railHeight = min(railHitSize.height, max(visible.height, 1))
        let top = visible.maxY - CGFloat(ratio) * max(visible.height - railHeight, 0)
        let y = min(max(top - height, visible.minY), visible.maxY - height)
        let x: CGFloat
        if dock == .left { x = visible.minX }
        else if dock == .right { x = visible.maxX - width }
        else {
            let horizontal = safeRatio(horizontalRatio, fallback: isLeft ? 0 : 1)
            let railX = visible.minX + CGFloat(horizontal) * max(visible.width - railWidth, 0)
            let requestedX = isLeft ? railX : railX + railWidth - width
            x = min(max(requestedX, visible.minX), visible.maxX - width)
        }
        return NSRect(x: x, y: y, width: width, height: height)
    }

    /// Pure geometry shared by the controller and its isolated tests.
    static func clamped(_ requested: NSRect, in visible: NSRect) -> NSRect {
        let usable = visible.insetBy(dx: min(margin, max(0, visible.width / 4)), dy: min(margin, max(0, visible.height / 4)))
        let width = min(max(requested.width, 1), max(usable.width, 1))
        let height = min(max(requested.height, 1), max(usable.height, 1))
        let x = min(max(requested.minX, usable.minX), usable.maxX - width)
        let y = min(max(requested.minY, usable.minY), usable.maxY - height)
        return NSRect(x: x, y: y, width: width, height: height)
    }
}

private final class MailFloatingHostingView<Content: View>: NSHostingView<Content> {
    var onPointerChanged: ((NSPoint) -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner as AnyObject? === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { reportPointer(event); super.mouseEntered(with: event) }
    override func mouseExited(with event: NSEvent) { reportPointer(event); super.mouseExited(with: event) }
    override func mouseMoved(with event: NSEvent) { reportPointer(event); super.mouseMoved(with: event) }
    private func reportPointer(_ event: NSEvent) {
        guard let window else { return }
        onPointerChanged?(window.convertPoint(toScreen: event.locationInWindow))
    }
}
