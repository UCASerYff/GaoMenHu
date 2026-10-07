import AppKit
import QuartzCore

/// A native, nonactivating companion to the website launcher. Window preferences
/// remain separate from the library, so showing it never rewrites user data.
final class FloatingLauncherController: NSObject, NSSearchFieldDelegate, NSMenuDelegate {
    static let collapsedSize = NSSize(width: 20, height: 104)
    private unowned let app: AppDelegate
    private let preferences: UserDefaults?
    let panel: FloatingLauncherPanel
    private let container = FloatingLauncherTrackingView()
    private let surface = NSVisualEffectView()
    private let edgeHandle = FloatingLauncherEdgeHandle()
    private let header = FloatingLauncherHeader()
    private let searchField = FloatingLauncherSearchField()
    private let scroll = NSScrollView()
    private let rows = NSView()
    private let footer = NSTextField(labelWithString: "")
    private let openMain = NSButton()
    private var currentRows: [Website] = []
    private var screenObserver: NSObjectProtocol?
    private var pointerTimer: Timer?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var keyObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private var pressStartedInside = false
    private var enabled = true
    private var dragOffset: NSPoint?
    private var dragMoved = false
    private var dock = "right"
    private var launching = false
    private var anchorFrame = NSRect(x: 0, y: 0, width: 20, height: 104)
    private var hoverStartedAt: TimeInterval?
    private var outsideStartedAt: TimeInterval?
    private var holdUntil: TimeInterval = 0
    private var hoverArmed = true
    private var menuDepth = 0
    private var status = "点击网站打开，右键选择浏览器"
    private(set) var expanded = false
    private(set) var edgeHidden = false
    var dockEdge: FloatingLauncherEdge { FloatingLauncherEdge(rawValue: dock) ?? .none }
    var isVisible: Bool { panel.isVisible }
    var visibleSiteIDs: [String] { currentRows.map(\.id) }
    var query: String { searchField.stringValue }
    var activeMonitorCount: Int { [localMouseMonitor, globalMouseMonitor].compactMap { $0 }.count }

    init(app: AppDelegate, testPreferences: UserDefaults? = nil) {
        self.app = app
        preferences = app.testMode ? testPreferences : UserDefaults.standard
        panel = FloatingLauncherPanel(contentRect: NSRect(origin: .zero, size: Self.collapsedSize),
                                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        if let value = preferences?.object(forKey: "GaoMenHu.Floating.Enabled") as? Bool { enabled = value }
        preferences?.removeObject(forKey: "GaoMenHu.Floating.AutoHide")
        dock = preferences?.string(forKey: "GaoMenHu.Floating.Dock") ?? "right"
        configure()
    }

    func start() {
        stop()
        restorePosition()
        refresh()
        if enabled { panel.orderFrontRegardless() }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                guard let self, self.dragOffset == nil else { return }
                self.normalizeAnchor(); self.renderFrame(); self.savePosition()
            }
        if !(app.testMode && CommandLine.arguments.contains("--self-test")) {
            installMouseMonitors()
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                self?.pollPointer(at: NSEvent.mouseLocation, now: ProcessInfo.processInfo.systemUptime,
                                  mouseButtons: NSEvent.pressedMouseButtons)
            }
            timer.tolerance = 0.01
            RunLoop.main.add(timer, forMode: .common); pointerTimer = timer
            keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
                self?.dismissForOutsideInteraction()
            }
            activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main) { [weak self] _ in
                self?.dismissForOutsideInteraction()
            }
        }
    }

    func stop() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        pointerTimer?.invalidate(); pointerTimer = nil
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        localMouseMonitor = nil; globalMouseMonitor = nil
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        keyObserver = nil; activationObserver = nil
        pressStartedInside = false
        commitDragging()
        panel.orderOut(nil)
    }

    func refresh() {
        footer.stringValue = status
        footer.toolTip = status
        guard dragOffset == nil else { return }
        let matches = FloatingLauncherLogic.sites(in: app.library, query: query, usage: app.launchHistory.records, limit: 8)
        if matches != currentRows {
            currentRows = matches
            if expanded { renderFrame() }
        }
    }

    func setVisible(_ value: Bool) {
        enabled = value
        preferences?.set(value, forKey: "GaoMenHu.Floating.Enabled")
        if value {
            normalizeAnchor(); renderFrame()
            refresh()
            panel.orderFrontRegardless()
        } else {
            commitDragging()
            setExpanded(false)
            panel.makeFirstResponder(nil)
            panel.orderOut(nil)
        }
        app.settingsModel?.refresh()
    }

    func toggle() { setVisible(!isVisible) }

    func showStatus(_ message: String) {
        status = message
        footer.stringValue = status
        footer.toolTip = status
    }

    func setExpanded(_ value: Bool) {
        guard expanded != value else { return }
        if !value { commitDragging() }
        expanded = value
        hoverStartedAt = nil; outsideStartedAt = nil
        holdUntil = value ? 0 : ProcessInfo.processInfo.systemUptime + 0.2
        if !value {
            hoverArmed = false
            pressStartedInside = false
            panel.makeFirstResponder(nil)
            searchField.stringValue = ""
        }
        renderFrame()
        refresh()
        if enabled { panel.orderFrontRegardless() }
    }

    func search(_ value: String) {
        searchField.stringValue = value
        refresh()
    }

    func resetPosition() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        dock = "right"
        let bounds = dockingBounds(for: screen)
        anchorFrame = NSRect(x: bounds.maxX - Self.collapsedSize.width,
                             y: bounds.maxY - Self.collapsedSize.height - 96,
                             width: Self.collapsedSize.width, height: Self.collapsedSize.height)
        normalizeAnchor(); renderFrame()
        savePosition()
    }

    /// Only an isolated test app can export a preview; production never captures
    /// a user's websites or accounts.
    func capturePreview(to url: URL) {
        let view: NSView = edgeHidden ? edgeHandle : surface
        guard app.testMode, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let data = bitmap.representation(using: .png, properties: [:]) { try? data.write(to: url, options: .atomic) }
    }

    func controlTextDidChange(_ notification: Notification) { refresh() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if let first = currentRows.first { launch(first, browserID: nil) }
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { setExpanded(false); return true }
        return false
    }

    private func configure() {
        panel.title = "搞门户 · 悬浮窗"
        panel.identifier = NSUserInterfaceItemIdentifier("GaoMenHu.Floating")
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.dismiss = { [weak self] in self?.setExpanded(false) }

        surface.material = .popover
        surface.blendingMode = .behindWindow
        surface.state = .active
        surface.wantsLayer = true
        surface.layer?.cornerRadius = 16
        surface.layer?.masksToBounds = true
        surface.toolTip = "拖动空白处移动，靠近左右边缘自动吸附"
        panel.contentView = container
        container.addSubview(surface); container.addSubview(edgeHandle)
        edgeHandle.identifier = NSUserInterfaceItemIdentifier("GaoMenHu.Floating.EdgeHandle")
        container.pointerEntered = { [weak self] in self?.outsideStartedAt = nil }
        container.pointerExited = { [weak self] in
            self?.processPointer(at: NSEvent.mouseLocation, now: ProcessInfo.processInfo.systemUptime, mouseDown: NSEvent.pressedMouseButtons != 0)
        }

        header.identifier = NSUserInterfaceItemIdentifier("GaoMenHu.Floating.DragArea")
        header.beginDrag = { [weak self] point in self?.beginDragging(at: point) }
        header.drag = { [weak self] point in self?.drag(to: point) }
        header.endDrag = { [weak self] moved in
            self?.endDragging(moved: moved, at: NSEvent.mouseLocation)
        }
        surface.addSubview(header)
        edgeHandle.beginDrag = header.beginDrag; edgeHandle.drag = header.drag; edgeHandle.endDrag = header.endDrag
        panel.backgroundDraggingEnabled = { [weak self] in
            guard let self else { return false }
            return self.enabled && self.panel.isVisible && self.expanded && !self.launching && self.menuDepth == 0
        }
        panel.beginBackgroundDrag = header.beginDrag
        panel.dragBackground = header.drag
        panel.endBackgroundDrag = { [weak self] moved, point in self?.endDragging(moved: moved, at: point) }

        searchField.placeholderString = "搜索网站、拼音或网址"
        searchField.identifier = NSUserInterfaceItemIdentifier("GaoMenHu.Floating.Search")
        searchField.setAccessibilityLabel("搜索网站、拼音或网址")
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 13)
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self
        surface.addSubview(searchField)

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = rows
        surface.addSubview(scroll)

        footer.font = .systemFont(ofSize: 10)
        footer.textColor = .secondaryLabelColor
        footer.lineBreakMode = .byTruncatingTail
        surface.addSubview(footer)

        openMain.title = "全部网站"
        openMain.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)
        openMain.imagePosition = .imageLeading
        openMain.bezelStyle = .inline
        openMain.font = .systemFont(ofSize: 11)
        openMain.target = self
        openMain.action = #selector(openMainWindow)
        openMain.setAccessibilityLabel("打开搞门户主窗口")
        surface.addSubview(openMain)
        layout()
    }

    private func layout() {
        let width = panel.frame.width, height = panel.frame.height
        container.frame = NSRect(origin: .zero, size: panel.frame.size)
        surface.frame = NSRect(origin: .zero, size: panel.frame.size)
        edgeHandle.frame = container.bounds
        edgeHandle.edge = dockEdge
        edgeHandle.isHidden = !edgeHidden; surface.isHidden = edgeHidden
        edgeHandle.needsDisplay = true
        updateDockAppearance()
        header.frame = NSRect(x: 0, y: height - 12, width: width, height: 12)
        header.update()
        [searchField, scroll, footer, openMain].forEach { $0.isHidden = !expanded }
        if expanded {
            searchField.frame = NSRect(x: 16, y: height - 42, width: width - 32, height: 30)
            scroll.frame = NSRect(x: 12, y: 40, width: max(0, width - 24), height: max(0, height - 92))
            footer.frame = NSRect(x: 18, y: 12, width: width - 134, height: 16)
            openMain.frame = NSRect(x: width - 100, y: 8, width: 84, height: 24)
            rebuildRows()
        }
    }

    private func rebuildRows() {
        rows.subviews.forEach { $0.removeFromSuperview() }
        let width = max(0, scroll.contentSize.width)
        let contentHeight = max(scroll.contentSize.height, CGFloat(currentRows.count) * 46)
        rows.frame = NSRect(x: 0, y: 0, width: width, height: contentHeight)
        if currentRows.isEmpty {
            let empty = NSTextField(wrappingLabelWithString: app.library.sites.isEmpty ? "还没有网站\n打开主窗口，添加网站或导入收藏。" : "没有匹配的网站\n试试名称、网址或拼音首字母。")
            empty.alignment = .center
            empty.font = .systemFont(ofSize: 12)
            empty.textColor = .secondaryLabelColor
            empty.frame = NSRect(x: 12, y: contentHeight / 2 - 28, width: width - 24, height: 56)
            rows.addSubview(empty)
        }
        for (index, site) in currentRows.enumerated() {
            let row = FloatingLauncherRow(site: site)
            row.frame = NSRect(x: 2, y: contentHeight - CGFloat(index + 1) * 46, width: width - 4, height: 42)
            row.open = { [weak self] in self?.launch(site, browserID: nil) }
            row.browserMenu = { [weak self] in self?.browserMenu(for: site) ?? NSMenu() }
            row.isEnabled = !launching
            rows.addSubview(row)
        }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, contentHeight - scroll.contentSize.height)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func browserMenu(for site: Website) -> NSMenu {
        let menu = NSMenu(title: "选择浏览器")
        menu.autoenablesItems = false
        menu.delegate = self
        let title = NSMenuItem(title: "用指定浏览器打开", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        for browser in FloatingLauncherLogic.allowedBrowsers(for: site) {
            let item = NSMenuItem(title: browser.name + (browser.id == site.defaultBrowser ? " · 默认" : ""), action: #selector(launchUsingMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ["siteID": site.id, "browserID": browser.id]
            let installed = app.testMode || NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleID) != nil
            if !installed { item.title += " · 未安装" }
            item.isEnabled = !launching && installed
            menu.addItem(item)
        }
        return menu
    }

    @objc private func launchUsingMenu(_ item: NSMenuItem) {
        guard let data = item.representedObject as? [String: String], let id = data["siteID"],
              let site = app.library.sites.first(where: { $0.id == id }) else { return }
        launch(site, browserID: data["browserID"])
    }

    private func launch(_ site: Website, browserID: String?) {
        guard !launching else { return }
        launching = true
        status = "正在打开…"
        rebuildRows(); refresh()
        app.launchFromFloating(siteID: site.id, browserID: browserID) { [weak self] error in
            guard let self else { return }
            self.launching = false
            self.status = error ?? "正在用指定浏览器打开…"
            self.rebuildRows(); self.refresh()
            if error == nil { self.setExpanded(false) }
        }
    }

    @objc private func openMainWindow() { setExpanded(false); app.showWindow() }

    private func restorePosition() {
        let size = Self.collapsedSize
        if let x = preferences?.object(forKey: "GaoMenHu.Floating.X") as? Double,
           let top = preferences?.object(forKey: "GaoMenHu.Floating.Top") as? Double,
           x.isFinite, top.isFinite {
            let frame = NSRect(x: x, y: top - size.height, width: size.width, height: size.height)
            let bounds = dockingScreen(for: frame)
            anchorFrame = FloatingLauncherGeometry.restoredFrame(saved: frame, size: size, screens: bounds.map { [$0] } ?? dockingScreens)
        } else { resetPosition() }
        normalizeAnchor(); renderFrame()
    }

    private func normalizeAnchor() {
        let screens = dockingScreen(for: anchorFrame).map { [$0] } ?? dockingScreens
        anchorFrame = FloatingLauncherGeometry.restoredFrame(saved: anchorFrame, size: Self.collapsedSize, screens: screens)
        if let screen = FloatingLauncherGeometry.screen(for: anchorFrame, among: screens) {
            if dockEdge == .left { anchorFrame.origin.x = screen.minX }
            if dockEdge == .right { anchorFrame.origin.x = screen.maxX - anchorFrame.width }
        }
    }

    private func renderFrame() {
        let screen = dockingScreen(for: anchorFrame)
            ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        edgeHidden = !expanded
        let frame: NSRect
        if edgeHidden { frame = FloatingLauncherGeometry.hiddenFrame(anchor: anchorFrame, edge: dockEdge, in: screen) }
        else { frame = FloatingLauncherGeometry.resizedFrame(anchorFrame, size: FloatingLauncherGeometry.expandedSize(siteCount: currentRows.count),
                                                            in: screen, edge: dockEdge) }
        panel.hasShadow = !edgeHidden
        panel.setFrame(frame, display: true)
        layout()
    }

    private var dockingScreens: [NSRect] { NSScreen.screens.map { dockingBounds(for: $0) } }

    private func dockingBounds(for screen: NSScreen) -> NSRect {
        FloatingLauncherGeometry.dockingBounds(frame: screen.frame, visibleFrame: screen.visibleFrame)
    }

    private func dockingScreen(for frame: NSRect) -> NSRect? {
        FloatingLauncherGeometry.dockingScreen(for: frame, physicalScreens: NSScreen.screens.map(\.frame),
                                               visibleScreens: NSScreen.screens.map(\.visibleFrame))
    }

    private func updateDockAppearance() {
        switch dockEdge {
        case .left: surface.layer?.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        case .right: surface.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        case .none: surface.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        }
    }

    func beginDragging(at point: NSPoint) {
        guard enabled, panel.isVisible, !launching, menuDepth == 0 else { return }
        dragOffset = NSPoint(x: point.x - panel.frame.minX, y: point.y - panel.frame.minY)
        dragMoved = false
        hoverStartedAt = nil; outsideStartedAt = nil
    }

    func drag(to point: NSPoint) {
        guard let offset = dragOffset else { return }
        dragMoved = true
        var wanted = panel.frame
        wanted.origin = NSPoint(x: point.x - offset.x, y: point.y - offset.y)
        // Use the pointer's display so the panel can cross to an adjacent monitor.
        let screen = NSScreen.screens.first { $0.frame.contains(point) }.map { dockingBounds(for: $0) }
            ?? dockingScreen(for: wanted)
            ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        let snapped = FloatingLauncherGeometry.snap(frame: wanted, to: screen)
        dock = snapped.edge == .none ? "free" : snapped.edge.rawValue
        let sizeChanged = panel.frame.size != snapped.frame.size
        panel.setFrame(snapped.frame, display: true)
        edgeHandle.edge = dockEdge; edgeHandle.needsDisplay = true
        updateDockAppearance()
        if sizeChanged { layout() }
    }

    func endDragging(moved: Bool, at point: NSPoint, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard enabled, panel.isVisible else { commitDragging(); return }
        let active = dragOffset != nil
        let didMove = moved || dragMoved
        commitDragging()
        if !didMove {
            if !expanded { setExpanded(true) }
            refresh()
            return
        }
        guard active else { return }
        hoverArmed = false; hoverStartedAt = nil; outsideStartedAt = nil
        holdUntil = now + 0.2
        refresh(); app.settingsModel?.refresh()
        processPointer(at: point, now: now)
    }

    private func commitDragging() {
        let moved = dragOffset != nil && dragMoved
        dragOffset = nil; dragMoved = false; panel.cancelBackgroundDrag()
        guard moved else { return }
        // Every drag event has already clamped and snapped the actual frame.
        // Persist that same frame without a second placement on mouse-up.
        let frame = panel.frame
        anchorFrame = NSRect(x: dockEdge == .right ? frame.maxX - Self.collapsedSize.width : frame.minX,
                             y: frame.maxY - Self.collapsedSize.height,
                             width: Self.collapsedSize.width, height: Self.collapsedSize.height)
        savePosition()
    }

    private func savePosition() {
        preferences?.set(Double(anchorFrame.minX), forKey: "GaoMenHu.Floating.X")
        preferences?.set(Double(anchorFrame.maxY), forKey: "GaoMenHu.Floating.Top")
        preferences?.set(dock, forKey: "GaoMenHu.Floating.Dock")
    }

    func setDock(_ edge: FloatingLauncherEdge) {
        dock = edge == .none ? "free" : edge.rawValue
        normalizeAnchor(); renderFrame(); savePosition(); app.settingsModel?.refresh()
    }

    func menuWillOpen(_ menu: NSMenu) { menuDepth += 1; outsideStartedAt = nil }
    func menuDidClose(_ menu: NSMenu) {
        menuDepth = max(0, menuDepth - 1); outsideStartedAt = nil
        processPointer(at: NSEvent.mouseLocation, now: ProcessInfo.processInfo.systemUptime, mouseDown: NSEvent.pressedMouseButtons != 0)
    }

    private var protectedInteraction: Bool {
        let composing = panel.isKeyWindow && (searchField.currentEditor() as? NSTextView)?.hasMarkedText() == true
        return launching || menuDepth > 0 || dragOffset != nil || composing
    }

    private func dismissForOutsideInteraction() {
        guard enabled, panel.isVisible, expanded, !protectedInteraction else { return }
        setExpanded(false)
    }

    private func installMouseMonitors() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown,
                                           .leftMouseUp, .rightMouseUp, .otherMouseUp]
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return event }
            let point = event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? event.locationInWindow
            self.observeMouse(event.type, at: point, fromPanel: event.window === self.panel)
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.observeMouse(event.type, at: event.locationInWindow)
        }
    }

    private func observeMouse(_ type: NSEvent.EventType, at point: NSPoint, fromPanel: Bool = false) {
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: processMouseDown(at: point)
        case .leftMouseUp: processMouseUp(at: point, recoverDrag: !fromPanel)
        case .rightMouseUp, .otherMouseUp: processMouseUp(at: point, recoverDrag: false)
        default: break
        }
    }

    func processMouseDown(at point: NSPoint) {
        guard enabled, panel.isVisible, expanded else { return }
        if panel.frame.contains(point) {
            pressStartedInside = true; outsideStartedAt = nil
        } else { dismissForOutsideInteraction() }
    }

    func processMouseUp(at point: NSPoint, now: TimeInterval = ProcessInfo.processInfo.systemUptime, recoverDrag: Bool = true) {
        pressStartedInside = false
        if recoverDrag, dragOffset != nil { endDragging(moved: dragMoved, at: point, now: now) }
        processPointer(at: point, now: now)
    }

    /// Recover a release swallowed by another app or a system interaction.
    func pollPointer(at point: NSPoint, now: TimeInterval, mouseButtons: Int) {
        if mouseButtons & 1 == 0, dragOffset != nil { endDragging(moved: dragMoved, at: point, now: now) }
        processPointer(at: point, now: now, mouseDown: mouseButtons != 0)
    }

    /// Mouse-only observation never intercepts a click or reads keyboard input.
    func processPointer(at point: NSPoint, now: TimeInterval, mouseDown: Bool = false) {
        guard enabled, panel.isVisible, !NSApp.isHidden, dragOffset == nil else {
            hoverStartedAt = nil; outsideStartedAt = nil; return
        }
        if !mouseDown { pressStartedInside = false }
        if edgeHidden {
            if !panel.frame.contains(point) { hoverArmed = true; hoverStartedAt = nil; return }
            guard hoverArmed, !mouseDown, now >= holdUntil else { hoverStartedAt = nil; return }
            if hoverStartedAt == nil { hoverStartedAt = now }
            if now - (hoverStartedAt ?? now) >= 0.45 { setExpanded(true) }
            return
        }
        guard expanded else { outsideStartedAt = nil; return }
        if panel.frame.contains(point) { outsideStartedAt = nil; return }
        guard !protectedInteraction, !(mouseDown && pressStartedInside) else {
            outsideStartedAt = nil; return
        }
        if outsideStartedAt == nil { outsideStartedAt = now }
        if now - (outsideStartedAt ?? now) >= 0.15 { setExpanded(false) }
    }

}

private final class FloatingLauncherTrackingView: NSView {
    var pointerEntered: (() -> Void)?
    var pointerExited: (() -> Void)?
    private var area: NSTrackingArea?
    override func updateTrackingAreas() {
        if let area { removeTrackingArea(area) }
        area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        if let area { addTrackingArea(area) }; super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { pointerEntered?() }
    override func mouseExited(with event: NSEvent) { pointerExited?() }
}

private final class FloatingLauncherEdgeHandle: NSView {
    var edge: FloatingLauncherEdge = .right
    var beginDrag: ((NSPoint) -> Void)?
    var drag: ((NSPoint) -> Void)?
    var endDrag: ((Bool) -> Void)?
    private var start = NSPoint.zero
    private var moved = false
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true); setAccessibilityRole(.button)
        setAccessibilityLabel("展开搞门户悬浮窗")
        toolTip = "悬停展开 · 点击立即展开 · 拖动移动位置"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: FloatingLauncherGeometry.stripRect(in: bounds, edge: edge),
                     xRadius: 3, yRadius: 3).fill()
    }
    override func mouseDown(with event: NSEvent) { start = NSEvent.mouseLocation; moved = false; beginDrag?(start) }
    override func mouseDragged(with event: NSEvent) {
        let point = NSEvent.mouseLocation
        if hypot(point.x - start.x, point.y - start.y) > 4 { moved = true }
        if moved { drag?(point) }
    }
    override func mouseUp(with event: NSEvent) { endDrag?(moved) }
    override func accessibilityPerformPress() -> Bool { endDrag?(false); return true }
}

final class FloatingLauncherPanel: NSPanel {
    var dismiss: (() -> Void)?
    var backgroundDraggingEnabled: (() -> Bool)?
    var beginBackgroundDrag: ((NSPoint) -> Void)?
    var dragBackground: ((NSPoint) -> Void)?
    var endBackgroundDrag: ((Bool, NSPoint) -> Void)?
    private var backgroundPress: NSPoint?
    private var backgroundMoved = false
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Only the expanded panel's blank areas are draggable. Native controls keep
    /// their own click, text selection, context-menu and scroll handling.
    func canBeginBackgroundDrag(at point: NSPoint) -> Bool {
        guard backgroundDraggingEnabled?() == true, let content = contentView,
              content.bounds.contains(content.convert(point, from: nil)) else { return false }
        let hitPoint = content.superview?.convert(point, from: nil) ?? point
        var candidate = content.hitTest(hitPoint)
        while let view = candidate {
            if view is NSButton || view is NSSearchField || view is NSTextView || view is NSScroller { return false }
            if view === content { break }
            candidate = view.superview
        }
        return true
    }

    func cancelBackgroundDrag() { backgroundPress = nil; backgroundMoved = false }

    override func sendEvent(_ event: NSEvent) {
        let point = convertPoint(toScreen: event.locationInWindow)
        switch event.type {
        case .leftMouseDown where !event.modifierFlags.contains(.control):
            if canBeginBackgroundDrag(at: event.locationInWindow) {
                backgroundPress = point; backgroundMoved = false
                beginBackgroundDrag?(point)
                return
            }
        case .leftMouseDragged:
            if let start = backgroundPress {
                if hypot(point.x - start.x, point.y - start.y) > 3 { backgroundMoved = true }
                if backgroundMoved { dragBackground?(point) }
                return
            }
        case .leftMouseUp:
            if backgroundPress != nil {
                let moved = backgroundMoved
                cancelBackgroundDrag()
                endBackgroundDrag?(moved, point)
                return
            }
        default: break
        }
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) { dismiss?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { dismiss?() } else { super.keyDown(with: event) }
    }
}

private final class FloatingLauncherSearchField: NSSearchField {
    override var needsPanelToBecomeKey: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        super.mouseDown(with: event)
    }
}

private final class FloatingLauncherHeader: NSView {
    var beginDrag: ((NSPoint) -> Void)?
    var drag: ((NSPoint) -> Void)?
    var endDrag: ((Bool) -> Void)?
    private var startingPoint = NSPoint.zero
    private var moved = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityLabel("搞门户悬浮窗入口；拖动调整位置，点击展开")
        toolTip = "拖动顶部、两侧或底部空白处移动，靠近左右边缘自动吸附"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }
    func update() { needsDisplay = true }
    override func mouseDown(with event: NSEvent) {
        startingPoint = NSEvent.mouseLocation
        moved = false
        beginDrag?(startingPoint)
    }
    override func mouseDragged(with event: NSEvent) {
        let point = NSEvent.mouseLocation
        if hypot(point.x - startingPoint.x, point.y - startingPoint.y) > 3 { moved = true }
        if moved { drag?(point) }
    }
    override func mouseUp(with event: NSEvent) { endDrag?(moved) }
}

private final class FloatingLauncherRow: NSButton {
    var open: (() -> Void)?
    var browserMenu: (() -> NSMenu)?
    private let nameLabel: NSTextField
    private let browserLabel: NSTextField
    private let icon = NSImageView()
    private let fallback: NSTextField
    private var hover = false
    private var tracker: NSTrackingArea?

    init(site: Website) {
        nameLabel = NSTextField(labelWithString: site.name)
        browserLabel = NSTextField(labelWithString: Browser.catalog.first(where: { $0.id == site.defaultBrowser })?.name ?? site.defaultBrowser)
        fallback = NSTextField(labelWithString: String(site.name.prefix(1)))
        super.init(frame: .zero)
        title = ""
        isBordered = false
        target = self; action = #selector(tapped)
        wantsLayer = true
        layer?.cornerRadius = 9
        nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingTail
        browserLabel.font = .systemFont(ofSize: 10)
        browserLabel.textColor = .secondaryLabelColor
        browserLabel.lineBreakMode = .byTruncatingTail
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.wantsLayer = true
        icon.layer?.cornerRadius = 7
        icon.layer?.masksToBounds = true
        if let source = site.icon, source.hasPrefix("data:image/"), let comma = source.firstIndex(of: ","),
           let data = Data(base64Encoded: String(source[source.index(after: comma)...])), data.count <= 3_000_000 {
            icon.image = NSImage(data: data)
        }
        fallback.alignment = .center
        fallback.font = .systemFont(ofSize: 16, weight: .medium)
        fallback.textColor = .white
        fallback.isHidden = icon.image != nil
        if icon.image == nil {
            icon.layer?.backgroundColor = color(site.color).cgColor
        }
        [icon, fallback, nameLabel, browserLabel].forEach { addSubview($0) }
        toolTip = site.name + "\n" + site.url + "\n右键选择允许的浏览器"
        setAccessibilityLabel("\(site.name)，用 \(browserLabel.stringValue) 打开")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 9, y: 5, width: 32, height: 32)
        fallback.frame = NSRect(x: 9, y: 10, width: 32, height: 24)
        nameLabel.frame = NSRect(x: 52, y: isFlipped ? 5 : 21, width: max(0, bounds.width - 72), height: 17)
        browserLabel.frame = NSRect(x: 52, y: isFlipped ? 23 : 5, width: max(0, bounds.width - 72), height: 14)
    }
    override func updateTrackingAreas() {
        if let tracker { removeTrackingArea(tracker) }
        tracker = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracker!)
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hover = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hover = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        if hover || isHighlighted {
            NSColor.controlAccentColor.withAlphaComponent(isHighlighted ? 0.15 : 0.08).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill()
        }
    }
    override func menu(for event: NSEvent) -> NSMenu? { browserMenu?() }
    @objc private func tapped() { if isEnabled { open?() } }
    private func color(_ text: String) -> NSColor {
        let value = text.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard value.count == 6, let hex = UInt32(value, radix: 16) else { return .systemBlue }
        return NSColor(calibratedRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                       blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
}
