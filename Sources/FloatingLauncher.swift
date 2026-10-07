import AppKit
import QuartzCore

/// A native, nonactivating companion to the website launcher. Window preferences
/// remain separate from the library, so showing it never rewrites user data.
final class FloatingLauncherController: NSObject, NSSearchFieldDelegate, NSMenuDelegate {
    static let expandedSize = NSSize(width: 364, height: 526)
    static let collapsedSize = NSSize(width: 140, height: 48)
    private unowned let app: AppDelegate
    private let preferences: UserDefaults?
    let panel: FloatingLauncherPanel
    private let container = FloatingLauncherTrackingView()
    private let surface = NSVisualEffectView()
    private let edgeHandle = FloatingLauncherEdgeHandle()
    private let header = FloatingLauncherHeader()
    private let searchField = FloatingLauncherSearchField()
    private let summary = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()
    private let rows = NSView()
    private let footer = NSTextField(labelWithString: "")
    private let openMain = NSButton()
    private var currentRows: [Website] = []
    private var screenObserver: NSObjectProtocol?
    private var pointerTimer: Timer?
    private var enabled = true
    private var dragOffset: NSPoint?
    private var dock = "right"
    private var launching = false
    private var anchorFrame = NSRect(x: 0, y: 0, width: 140, height: 48)
    private var hoverStartedAt: TimeInterval?
    private var outsideStartedAt: TimeInterval?
    private var holdUntil: TimeInterval = 0
    private var hoverArmed = true
    private var menuDepth = 0
    private var status = "点击网站打开，右键选择浏览器"
    private(set) var expanded = false
    private(set) var edgeHidden = false
    private(set) var pinned = false
    private(set) var autoHideEnabled = true
    var dockEdge: FloatingLauncherEdge { FloatingLauncherEdge(rawValue: dock) ?? .none }
    var isVisible: Bool { panel.isVisible }
    var visibleSiteIDs: [String] { currentRows.map(\.id) }
    var query: String { searchField.stringValue }

    init(app: AppDelegate) {
        self.app = app
        preferences = app.testMode ? nil : UserDefaults.standard
        panel = FloatingLauncherPanel(contentRect: NSRect(origin: .zero, size: Self.collapsedSize),
                                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        if let value = preferences?.object(forKey: "GaoMenHu.Floating.Enabled") as? Bool { enabled = value }
        if let value = preferences?.object(forKey: "GaoMenHu.Floating.AutoHide") as? Bool { autoHideEnabled = value }
        dock = preferences?.string(forKey: "GaoMenHu.Floating.Dock") ?? "right"
        configure()
    }

    func start() {
        restorePosition()
        refresh()
        if enabled { panel.orderFrontRegardless() }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                guard let self, self.dragOffset == nil else { return }
                self.normalizeAnchor(); self.renderFrame(); self.savePosition()
            }
        if !(app.testMode && CommandLine.arguments.contains("--self-test")) {
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                self?.processPointer(at: NSEvent.mouseLocation, now: ProcessInfo.processInfo.systemUptime,
                                     mouseDown: NSEvent.pressedMouseButtons != 0)
            }
            RunLoop.main.add(timer, forMode: .common); pointerTimer = timer
        }
    }

    func stop() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        pointerTimer?.invalidate(); pointerTimer = nil
        panel.orderOut(nil)
    }

    func refresh() {
        let matches = FloatingLauncherLogic.sites(in: app.library, query: query, limit: 8)
        summary.stringValue = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "按启动台顺序 · \(FloatingLauncherLogic.orderedSites(in: app.library).count) 个网站"
            : "找到 \(matches.count) 个网站"
        if matches != currentRows {
            currentRows = matches
            rebuildRows()
        }
        footer.stringValue = status
        footer.toolTip = status
    }

    func setVisible(_ value: Bool) {
        enabled = value
        preferences?.set(value, forKey: "GaoMenHu.Floating.Enabled")
        if value {
            normalizeAnchor(); renderFrame()
            refresh()
            panel.orderFrontRegardless()
        } else {
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
        expanded = value
        hoverStartedAt = nil; outsideStartedAt = nil
        holdUntil = ProcessInfo.processInfo.systemUptime + 1
        if !value {
            pinned = false
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
        anchorFrame = NSRect(x: screen.visibleFrame.maxX - Self.collapsedSize.width,
                             y: screen.visibleFrame.maxY - Self.collapsedSize.height - 96,
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
        panel.contentView = container
        container.addSubview(surface); container.addSubview(edgeHandle)
        edgeHandle.identifier = NSUserInterfaceItemIdentifier("GaoMenHu.Floating.EdgeHandle")
        container.pointerEntered = { [weak self] in self?.outsideStartedAt = nil }
        container.pointerExited = { [weak self] in self?.hoverStartedAt = nil }

        header.expanded = { [weak self] in self?.expanded ?? false }
        header.beginDrag = { [weak self] point in
            guard let self else { return }
            self.dragOffset = NSPoint(x: point.x - self.panel.frame.minX, y: point.y - self.panel.frame.minY)
            self.hoverStartedAt = nil; self.outsideStartedAt = nil
        }
        header.drag = { [weak self] point in
            guard let self, let offset = self.dragOffset else { return }
            var frame = self.panel.frame
            frame.origin = NSPoint(x: point.x - offset.x, y: point.y - offset.y)
            self.panel.setFrame(frame, display: true)
        }
        header.endDrag = { [weak self] moved in
            guard let self else { return }
            self.dragOffset = nil
            if moved { self.finishDrag() }
            else if !self.expanded { self.setExpanded(true) }
        }
        header.collapse = { [weak self] in self?.setExpanded(false) }
        header.close = { [weak self] in self?.setExpanded(false) }
        header.pinned = { [weak self] in self?.pinned ?? false }
        header.togglePin = { [weak self] in self?.setPinned(!(self?.pinned ?? false)) }
        surface.addSubview(header)
        edgeHandle.beginDrag = header.beginDrag; edgeHandle.drag = header.drag; edgeHandle.endDrag = header.endDrag

        searchField.placeholderString = "搜索网站、拼音或网址"
        searchField.identifier = NSUserInterfaceItemIdentifier("GaoMenHu.Floating.Search")
        searchField.setAccessibilityLabel("搜索网站、拼音或网址")
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 13)
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self
        surface.addSubview(searchField)

        summary.font = .systemFont(ofSize: 11)
        summary.textColor = .secondaryLabelColor
        surface.addSubview(summary)

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
        header.frame = NSRect(x: 0, y: height - 48, width: width, height: 48)
        header.update()
        [searchField, summary, scroll, footer, openMain].forEach { $0.isHidden = !expanded }
        if expanded {
            searchField.frame = NSRect(x: 16, y: height - 88, width: width - 32, height: 30)
            summary.frame = NSRect(x: 18, y: height - 115, width: width - 36, height: 16)
            scroll.frame = NSRect(x: 12, y: 46, width: max(0, width - 24), height: max(0, height - 172))
            footer.frame = NSRect(x: 18, y: 16, width: width - 134, height: 16)
            openMain.frame = NSRect(x: width - 100, y: 12, width: 84, height: 24)
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
            if error == nil && !self.pinned { self.setExpanded(false) }
        }
    }

    @objc private func openMainWindow() { setExpanded(false); app.showWindow() }

    private func restorePosition() {
        let size = Self.collapsedSize
        if let x = preferences?.object(forKey: "GaoMenHu.Floating.X") as? Double,
           let top = preferences?.object(forKey: "GaoMenHu.Floating.Top") as? Double,
           x.isFinite, top.isFinite {
            let frame = NSRect(x: x, y: top - size.height, width: size.width, height: size.height)
            anchorFrame = FloatingLauncherGeometry.restoredFrame(saved: frame, size: size, screens: NSScreen.screens.map(\.visibleFrame))
        } else { resetPosition() }
        normalizeAnchor(); renderFrame()
    }

    private func normalizeAnchor() {
        let screens = NSScreen.screens.map(\.visibleFrame)
        anchorFrame = FloatingLauncherGeometry.restoredFrame(saved: anchorFrame, size: Self.collapsedSize, screens: screens)
        if let screen = FloatingLauncherGeometry.screen(for: anchorFrame, among: screens) {
            if dockEdge == .left { anchorFrame.origin.x = screen.minX }
            if dockEdge == .right { anchorFrame.origin.x = screen.maxX - anchorFrame.width }
        }
    }

    private func renderFrame() {
        let screen = FloatingLauncherGeometry.screen(for: anchorFrame, among: NSScreen.screens.map(\.visibleFrame))
            ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        edgeHidden = !expanded && autoHideEnabled && dockEdge != .none
        let frame: NSRect
        if edgeHidden { frame = FloatingLauncherGeometry.hiddenFrame(anchor: anchorFrame, edge: dockEdge, in: screen) }
        else { frame = FloatingLauncherGeometry.resizedFrame(anchorFrame, size: expanded ? Self.expandedSize : Self.collapsedSize,
                                                            in: screen, edge: dockEdge) }
        panel.hasShadow = !edgeHidden
        panel.setFrame(frame, display: true)
        layout()
    }

    private func finishDrag() {
        let frame = panel.frame
        let screen = FloatingLauncherGeometry.screen(for: frame, among: NSScreen.screens.map(\.visibleFrame))
            ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        let snapped = FloatingLauncherGeometry.snap(frame: frame, to: screen)
        dock = snapped.edge == .none ? "free" : snapped.edge.rawValue
        anchorFrame = NSRect(x: snapped.edge == .right ? snapped.frame.maxX - Self.collapsedSize.width : snapped.frame.minX,
                             y: snapped.frame.maxY - Self.collapsedSize.height,
                             width: Self.collapsedSize.width, height: Self.collapsedSize.height)
        normalizeAnchor(); renderFrame(); savePosition()
        hoverArmed = false; hoverStartedAt = nil; outsideStartedAt = nil
        holdUntil = ProcessInfo.processInfo.systemUptime + 1
    }

    private func savePosition() {
        preferences?.set(Double(anchorFrame.minX), forKey: "GaoMenHu.Floating.X")
        preferences?.set(Double(anchorFrame.maxY), forKey: "GaoMenHu.Floating.Top")
        preferences?.set(dock, forKey: "GaoMenHu.Floating.Dock")
    }

    func setAutoHide(_ value: Bool) {
        autoHideEnabled = value; preferences?.set(value, forKey: "GaoMenHu.Floating.AutoHide")
        hoverStartedAt = nil; outsideStartedAt = nil; hoverArmed = true
        renderFrame(); app.settingsModel?.refresh()
    }

    func setDock(_ edge: FloatingLauncherEdge) {
        dock = edge == .none ? "free" : edge.rawValue
        normalizeAnchor(); renderFrame(); savePosition(); app.settingsModel?.refresh()
    }

    func setPinned(_ value: Bool) {
        pinned = value; outsideStartedAt = nil; header.update()
        if value { setExpanded(true) }
    }

    func menuWillOpen(_ menu: NSMenu) { menuDepth += 1; outsideStartedAt = nil }
    func menuDidClose(_ menu: NSMenu) {
        menuDepth = max(0, menuDepth - 1); outsideStartedAt = nil
        holdUntil = ProcessInfo.processInfo.systemUptime + 0.5
    }

    /// Polling only this app's window bounds needs no global event hook or permissions.
    func processPointer(at point: NSPoint, now: TimeInterval, mouseDown: Bool = false) {
        guard enabled, panel.isVisible, !NSApp.isHidden, dragOffset == nil else {
            hoverStartedAt = nil; outsideStartedAt = nil; return
        }
        if edgeHidden {
            let inside = panel.frame.insetBy(dx: -3, dy: -3).contains(point)
            if !inside { hoverArmed = true; hoverStartedAt = nil; return }
            guard hoverArmed, !mouseDown, now >= holdUntil else { hoverStartedAt = nil; return }
            if hoverStartedAt == nil { hoverStartedAt = now }
            if now - (hoverStartedAt ?? now) >= 0.45 { setExpanded(true); holdUntil = now + 1 }
            return
        }
        guard expanded, autoHideEnabled, dockEdge != .none else { outsideStartedAt = nil; return }
        let editingSearch = panel.isKeyWindow && panel.firstResponder is NSTextView
        guard !pinned, !launching, menuDepth == 0, !mouseDown, !editingSearch, now >= holdUntil else {
            outsideStartedAt = nil; return
        }
        if panel.frame.insetBy(dx: -18, dy: -18).contains(point) { outsideStartedAt = nil; return }
        if outsideStartedAt == nil { outsideStartedAt = now }
        if now - (outsideStartedAt ?? now) >= 0.45 { setExpanded(false) }
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
        let width = min(6, bounds.width), height = min(88, max(0, bounds.height - 8))
        let x = edge == .left ? min(2, max(0, bounds.width - width)) : max(0, bounds.width - width - 2)
        NSBezierPath(roundedRect: NSRect(x: x, y: (bounds.height - height) / 2, width: width, height: height),
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
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
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
    var expanded: (() -> Bool)?
    var pinned: (() -> Bool)?
    var togglePin: (() -> Void)?
    var beginDrag: ((NSPoint) -> Void)?
    var drag: ((NSPoint) -> Void)?
    var endDrag: ((Bool) -> Void)?
    var collapse: (() -> Void)?
    var close: (() -> Void)?
    private let title = NSTextField(labelWithString: "搞门户")
    private let symbol = NSImageView()
    private let collapseButton = NSButton()
    private let closeButton = NSButton()
    private let pinButton = NSButton()
    private var startingPoint = NSPoint.zero
    private var moved = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        symbol.image = NSImage(systemSymbolName: "door.left.hand.open", accessibilityDescription: nil)
        symbol.contentTintColor = NSColor(calibratedRed: 0.20, green: 0.45, blue: 0.82, alpha: 1)
        addSubview(symbol)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        addSubview(title)
        for (button, image, label, action) in [
            (pinButton, "pin", "固定悬浮窗", #selector(pinTapped)),
            (collapseButton, "minus", "收起悬浮窗", #selector(collapseTapped)),
            (closeButton, "xmark", "隐藏到唤起入口", #selector(closeTapped))
        ] {
            button.image = NSImage(systemSymbolName: image, accessibilityDescription: label)
            button.isBordered = false
            button.target = self; button.action = action
            button.toolTip = label
            button.setAccessibilityLabel(label)
            addSubview(button)
        }
        setAccessibilityLabel("搞门户悬浮窗入口；拖动调整位置，点击展开")
        closeButton.identifier = NSUserInterfaceItemIdentifier("GaoMenHu.Floating.CloseToEntry")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        for button in [pinButton, collapseButton, closeButton] where !button.isHidden && button.frame.contains(local) { return button }
        return self
    }
    func update() {
        let isExpanded = expanded?() ?? false
        symbol.frame = NSRect(x: 15, y: 14, width: 20, height: 20)
        title.frame = NSRect(x: 44, y: 15, width: 90, height: 18)
        collapseButton.isHidden = !isExpanded
        closeButton.isHidden = !isExpanded
        pinButton.isHidden = !isExpanded
        let isPinned = pinned?() ?? false
        pinButton.image = NSImage(systemSymbolName: isPinned ? "pin.fill" : "pin", accessibilityDescription: nil)
        pinButton.toolTip = isPinned ? "取消固定，移出后自动收起" : "固定悬浮窗，保持展开"
        pinButton.setAccessibilityLabel(isPinned ? "取消固定悬浮窗" : "固定悬浮窗")
        pinButton.frame = NSRect(x: bounds.width - 99, y: 12, width: 26, height: 24)
        collapseButton.frame = NSRect(x: bounds.width - 68, y: 12, width: 26, height: 24)
        closeButton.frame = NSRect(x: bounds.width - 37, y: 12, width: 26, height: 24)
        toolTip = isExpanded ? "拖动标题可移动悬浮窗，靠近左右边缘可吸附" : "点击展开 · 拖动可移动"
    }
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
    @objc private func collapseTapped() { collapse?() }
    @objc private func closeTapped() { close?() }
    @objc private func pinTapped() { togglePin?() }
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
