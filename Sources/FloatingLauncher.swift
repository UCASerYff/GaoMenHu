import AppKit
import QuartzCore

/// A native, nonactivating companion to the website launcher. Window preferences
/// remain separate from the library, so showing it never rewrites user data.
final class FloatingLauncherController: NSObject, NSSearchFieldDelegate {
    static let expandedSize = NSSize(width: 364, height: 526)
    static let collapsedSize = NSSize(width: 140, height: 48)
    private unowned let app: AppDelegate
    private let preferences: UserDefaults?
    let panel: FloatingLauncherPanel
    private let surface = NSVisualEffectView()
    private let header = FloatingLauncherHeader()
    private let searchField = FloatingLauncherSearchField()
    private let summary = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()
    private let rows = NSView()
    private let footer = NSTextField(labelWithString: "")
    private let openMain = NSButton()
    private var currentRows: [Website] = []
    private var screenObserver: NSObjectProtocol?
    private var enabled = true
    private var dragOffset: NSPoint?
    private var dock = "right"
    private var launching = false
    private var status = "点击网站打开，右键选择浏览器"
    private(set) var expanded = false
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
        dock = preferences?.string(forKey: "GaoMenHu.Floating.Dock") ?? "right"
        configure()
    }

    func start() {
        restorePosition()
        refresh()
        if enabled { panel.orderFrontRegardless() }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.place(self.panel.frame, snap: false)
            }
    }

    func stop() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
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
            place(panel.frame, snap: false)
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
        let previous = panel.frame
        expanded = value
        if !value {
            panel.makeFirstResponder(nil)
            searchField.stringValue = ""
        }
        let size = value ? Self.expandedSize : Self.collapsedSize
        let x = dock == "right" ? previous.maxX - size.width : previous.minX
        place(NSRect(x: x, y: previous.maxY - size.height, width: size.width, height: size.height), snap: false)
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
        let size = expanded ? Self.expandedSize : Self.collapsedSize
        let frame = NSRect(x: screen.visibleFrame.maxX - size.width - 8,
                           y: screen.visibleFrame.maxY - size.height - 96,
                           width: size.width, height: size.height)
        panel.setFrame(FloatingLauncherGeometry.constrain(frame: frame, to: screen.visibleFrame), display: true)
        layout()
        savePosition()
    }

    /// Only an isolated test app can export a preview; production never captures
    /// a user's websites or accounts.
    func capturePreview(to url: URL) {
        guard app.testMode, let bitmap = surface.bitmapImageRepForCachingDisplay(in: surface.bounds) else { return }
        surface.cacheDisplay(in: surface.bounds, to: bitmap)
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
        panel.contentView = surface

        header.expanded = { [weak self] in self?.expanded ?? false }
        header.beginDrag = { [weak self] point in
            guard let self else { return }
            self.dragOffset = NSPoint(x: point.x - self.panel.frame.minX, y: point.y - self.panel.frame.minY)
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
            if moved { self.place(self.panel.frame, snap: true); self.savePosition() }
            else if !self.expanded { self.setExpanded(true) }
        }
        header.collapse = { [weak self] in self?.setExpanded(false) }
        header.close = { [weak self] in self?.setVisible(false) }
        surface.addSubview(header)

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
        surface.frame = NSRect(origin: .zero, size: panel.frame.size)
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
        let size = expanded ? Self.expandedSize : Self.collapsedSize
        if let x = preferences?.object(forKey: "GaoMenHu.Floating.X") as? Double,
           let top = preferences?.object(forKey: "GaoMenHu.Floating.Top") as? Double,
           x.isFinite, top.isFinite {
            let frame = NSRect(x: x, y: top - size.height, width: size.width, height: size.height)
            panel.setFrame(FloatingLauncherGeometry.restoredFrame(saved: frame, size: size, screens: NSScreen.screens.map(\.visibleFrame)), display: false)
        } else { resetPosition() }
        layout()
    }

    private func place(_ frame: NSRect, snap: Bool) {
        let screens = NSScreen.screens.map(\.visibleFrame)
        var placed = FloatingLauncherGeometry.restoredFrame(saved: frame, size: frame.size, screens: screens)
        if let screen = FloatingLauncherGeometry.screen(for: placed, among: screens) {
            if snap { placed = FloatingLauncherGeometry.snap(frame: placed, to: screen).frame }
            let left = abs(placed.minX - screen.minX), right = abs(placed.maxX - screen.maxX)
            if left <= 24 { dock = "left" }
            else if right <= 24 { dock = "right" }
            else if snap { dock = "free" }
        }
        panel.setFrame(placed, display: true)
        layout()
    }

    private func savePosition() {
        let collapsedX = dock == "right" ? panel.frame.maxX - Self.collapsedSize.width : panel.frame.minX
        preferences?.set(Double(collapsedX), forKey: "GaoMenHu.Floating.X")
        preferences?.set(Double(panel.frame.maxY), forKey: "GaoMenHu.Floating.Top")
        preferences?.set(dock, forKey: "GaoMenHu.Floating.Dock")
    }
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
    var beginDrag: ((NSPoint) -> Void)?
    var drag: ((NSPoint) -> Void)?
    var endDrag: ((Bool) -> Void)?
    var collapse: (() -> Void)?
    var close: (() -> Void)?
    private let title = NSTextField(labelWithString: "搞门户")
    private let symbol = NSImageView()
    private let collapseButton = NSButton()
    private let closeButton = NSButton()
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
            (collapseButton, "minus", "收起悬浮窗", #selector(collapseTapped)),
            (closeButton, "xmark", "隐藏悬浮窗", #selector(closeTapped))
        ] {
            button.image = NSImage(systemSymbolName: image, accessibilityDescription: label)
            button.isBordered = false
            button.target = self; button.action = action
            button.toolTip = label
            button.setAccessibilityLabel(label)
            addSubview(button)
        }
        setAccessibilityLabel("搞门户悬浮窗入口；拖动调整位置，点击展开")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        for button in [collapseButton, closeButton] where !button.isHidden && button.frame.contains(local) { return button }
        return self
    }
    func update() {
        let isExpanded = expanded?() ?? false
        symbol.frame = NSRect(x: 15, y: 14, width: 20, height: 20)
        title.frame = NSRect(x: 44, y: 15, width: 90, height: 18)
        collapseButton.isHidden = !isExpanded
        closeButton.isHidden = !isExpanded
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
