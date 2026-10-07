import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class PortalSettingsModel: ObservableObject {
    unowned let app: AppDelegate
    @Published var busy = false
    @Published var status = ""
    init(app: AppDelegate) { self.app = app }
    func refresh() { objectWillChange.send() }
    func change(appearance: String? = nil, density: String? = nil, iconSize: Int? = nil) {
        do { try app.updateSettings(appearance: appearance, density: density, iconSize: iconSize); refresh() }
        catch { status = error.localizedDescription }
    }
}

struct PortalSettingsView: View {
    @ObservedObject var model: PortalSettingsModel
    private var app: AppDelegate { model.app }
    var body: some View {
        TabView {
            Form {
                Section("启动台") {
                    Picker("排列密度", selection: Binding(get: { app.library.layoutDensity ?? "compact" }, set: { model.change(density: $0) })) {
                        Text("宽松").tag("comfortable"); Text("紧凑").tag("compact")
                    }
                    Picker("图标大小", selection: Binding(get: { app.library.iconSize ?? 76 }, set: { model.change(iconSize: $0) })) {
                        Text("小").tag(60); Text("标准").tag(76); Text("大").tag(92)
                    }
                    HStack {
                        Button("导入浏览器收藏…") { app.showSettingsPage("bookmarks") }
                        Button("刷新网站图标") { app.refreshWebsiteIcons(); model.status = "正在获取清晰图标，完成后会自动更新。" }
                    }
                    Button("查看已移除的网站…") { app.showSettingsPage("archived") }
                }
                Section("浏览器助手") {
                    Text("Chrome 和 Edge 助手支持自动填充。每个浏览器个人资料需要单独加载并连接。")
                        .foregroundStyle(.secondary)
                    ForEach(Browser.catalog.filter(\.supportsFill), id: \.id) { browser in
                        HStack {
                            Text(browser.name)
                            Spacer()
                            let count = app.activeClients().filter { $0.browser == browser.id }.count
                            Text(count > 0 ? "已连接 · \(count) 个资料" : "未连接").foregroundStyle(count > 0 ? Color.green : Color.secondary)
                            Button("重新连接") { app.reconnectBrowser(browser) }
                                .disabled(!app.installedBrowsers().contains(browser))
                            Button("管理扩展…") { app.openBrowserExtensions(browser) }
                                .disabled(!app.installedBrowsers().contains(browser))
                        }
                    }
                    Button("打开助手文件夹") { NSWorkspace.shared.activateFileViewerSelecting([app.resources.appendingPathComponent("BrowserExtension")]) }
                    Text("在浏览器扩展管理页开启开发者模式，加载助手文件夹。更新后可在该页面重新加载助手。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Section("悬浮窗") {
                    Toggle("显示悬浮窗", isOn: Binding(get: { app.floatingLauncher?.isVisible ?? false }, set: { app.setFloatingLauncherVisible($0); model.refresh() }))
                    Picker("停靠位置", selection: Binding(get: { app.floatingLauncher?.dockEdge.rawValue ?? "right" }, set: { app.floatingLauncher?.setDock(FloatingLauncherEdge(rawValue: $0) ?? .right); model.refresh() })) {
                        Text("左侧").tag("left"); Text("右侧").tag("right"); Text("自由浮动").tag("none")
                    }
                    HStack {
                        Button("重置悬浮窗位置") { app.floatingLauncher?.resetPosition(); app.setFloatingLauncherVisible(true); model.refresh() }
                        Text("⌃⌘P 显示或隐藏").foregroundStyle(.secondary)
                    }
                    Text("所有位置均收起为竖线，悬停约 0.45 秒或点击展开，鼠标移出后自动收起。顶部可拖动；正在输入、右键菜单与登录验证时暂缓收起。位置与显示开关仅保存在本机。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Section("账号库") {
                    HStack {
                        Text(app.vault.unlocked ? "已解锁" : "已锁定")
                        Spacer()
                        Button("锁定账号库") { app.lockVault(); model.refresh() }.disabled(!app.vault.unlocked)
                    }
                    Text("密码由系统钥匙串保管，解锁 5 分钟后、锁屏或睡眠后锁定。填入账号密码后，由你自行完成登录。")
                        .foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).tabItem { Text("模块设置") }
            Form {
                Section {
                    LabeledContent("语言", value: "简体中文")
                    Picker("外观", selection: Binding(get: { app.effectiveAppearance }, set: { model.change(appearance: $0) })) {
                        Text("跟随系统").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark")
                    }
                    LabeledContent("版本", value: "V" + app.version)
                }
            }.formStyle(.grouped).tabItem { Text("外观") }
            Form {
                Section("完整资料") {
                    Text("包含网站、账号信息、图标、文件夹、工作场景、外观设置与恢复快照。密码留在系统钥匙串，浏览器 Cookie 不包含在备份中。")
                    Button("导出完整资料…") { app.exportFullBackup() }
                    Button("从完整资料恢复…") { app.restoreFullBackup() }
                    if model.busy { ProgressView().controlSize(.small) }
                }
                Section("模块格式") {
                    Text("JSON 格式保存当前网站资料，可合并导入或预览恢复；不包含历史快照和密码。")
                        .foregroundStyle(.secondary)
                    Button("导出模块备份…") { app.exportModuleBackup() }
                    Button("恢复模块备份…") { app.restoreModuleBackup() }
                    Button("合并导入模块备份…") { app.mergeModuleBackup() }
                    Button("查看恢复快照…") { app.showSettingsPage("snapshots") }
                }
                Section("数据目录") {
                    Button("打开数据目录") { app.revealDataDirectory() }
                }
            }.formStyle(.grouped).tabItem { Text("数据") }
        }
        .disabled(model.busy)
        .padding(20)
        .safeAreaInset(edge: .bottom) {
            if !model.status.isEmpty { Text(model.status).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding([.horizontal, .bottom], 24) }
        }
        .tint(Color(red: 0.20, green: 0.45, blue: 0.82))
        .frame(width: 820, height: 740)
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in model.refresh() }
    }
}

extension AppDelegate: NSToolbarDelegate {
    var effectiveAppearance: String { ["system", "light", "dark"].contains(library.appearance) ? library.appearance : "system" }
    func applyAppearance() {
        NSApp.appearance = effectiveAppearance == "system" ? nil : NSAppearance(named: effectiveAppearance == "dark" ? .darkAqua : .aqua)
    }
    func updateSettings(appearance: String? = nil, density: String? = nil, iconSize: Int? = nil) throws {
        var next = library
        if let appearance {
            guard ["system", "light", "dark"].contains(appearance) else { throw AppError.message("外观设置无效。") }
            next.appearance = appearance
        }
        if let density { next.layoutDensity = density }
        if let iconSize { next.iconSize = iconSize }
        try store.save(next); library = next; applyAppearance(); emit("update", ["state": state()])
    }
    func configureToolbar() {
        let toolbar = NSToolbar(identifier: "GaoMenHu.MainToolbar")
        toolbar.delegate = self; toolbar.displayMode = .iconOnly
        window.toolbar = toolbar; window.toolbarStyle = .unified
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.init("sidebar"), .flexibleSpace, .init("add")] }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarAllowedItemIdentifiers(toolbar) }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard ["sidebar", "add"].contains(id.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = id.rawValue == "sidebar" ? "显示或隐藏侧栏" : "添加网站"
        item.toolTip = id.rawValue == "sidebar" ? "显示或隐藏侧栏（⌃⌘S）" : "添加网站（⌘N）"
        item.image = NSImage(systemSymbolName: id.rawValue == "sidebar" ? "sidebar.left" : "plus", accessibilityDescription: item.label)
        item.target = self; item.action = id.rawValue == "sidebar" ? #selector(toggleSidebar) : #selector(addSite)
        return item
    }
    @objc func toggleSidebar() { emit("toggleSidebar", [:]) }
    func openNativeSettings() {
        if settingsWindow == nil {
            let model = PortalSettingsModel(app: self); settingsModel = model
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 740), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            panel.title = "搞门户设置"; panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: PortalSettingsView(model: model))
            panel.center(); settingsWindow = panel
        }
        settingsModel?.refresh(); settingsWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func showSettingsPage(_ page: String) {
        guard settingsModel?.busy != true else { return }
        settingsWindow?.orderOut(nil); window.makeKeyAndOrderFront(nil)
        emit("settingsPage", ["page": page])
    }
    @objc func restoreModuleBackup() { showSettingsPage("backup-restore") }
    @objc func mergeModuleBackup() { showSettingsPage("backup-merge") }
    func openBrowserExtensions(_ browser: Browser) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleID),
              let url = URL(string: browser.id == "chrome" ? "chrome://extensions/" : "edge://extensions/") else { return }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: .init(), completionHandler: nil)
    }
    func reconnectBrowser(_ browser: Browser) {
        do {
            if !testMode {
                try registerNativeHosts()
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleID) else { throw AppError.message("浏览器未安装。") }
                NSWorkspace.shared.openApplication(at: url, configuration: .init())
            }
            settingsModel?.status = "已检查本机连接并唤起浏览器。助手会自动重连，也可在助手弹窗中重新连接。"
        } catch { settingsModel?.status = error.localizedDescription }
    }
    func refreshWebsiteIcons() {
        iconLoader.clearCache()
        for site in library.sites where site.iconSource != "custom" { fetchIcon(site) }
    }
    func revealDataDirectory() {
        guard !testMode, store.persistent else { settingsModel?.status = "测试模式不使用真实数据目录。"; return }
        NSWorkspace.shared.open(store.directory)
    }
    @objc func exportModuleBackup() {
        guard settingsModel?.busy != true else { return }
        openNativeSettings()
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "搞门户-模块备份.json"
        settingsModel?.busy = true
        panel.beginSheetModal(for: settingsWindow!) { result in
            defer { self.settingsModel?.busy = false }
            guard result == .OK, let url = panel.url else { return }
            do {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(self.library).write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                self.settingsModel?.status = "模块备份已导出；密码保留在本机钥匙串。"
            } catch { self.settingsModel?.status = "导出失败：" + error.localizedDescription }
        }
    }
    @objc func exportFullBackup() {
        guard settingsModel?.busy != true else { return }
        openNativeSettings()
        let panel = NSSavePanel(); panel.allowedContentTypes = [.zip]; panel.nameFieldStringValue = FullBackup.defaultFilename
        settingsModel?.busy = true
        panel.beginSheetModal(for: settingsWindow!) { result in
            guard result == .OK, let url = panel.url else { self.settingsModel?.busy = false; return }
            do {
                // Capture current library; strictly read/validate every snapshot off the UI thread.
                let library = self.library, version = self.version
                let snapshotDirectory = self.store.persistent ? self.store.directory.appendingPathComponent("Snapshots", isDirectory: true) : nil
                let transient = self.store.persistent ? [] : try self.store.transientSnapshots.values.map { try JSONDecoder().decode(FullBackup.Snapshot.self, from: $0) }
                self.settingsModel?.busy = true; self.settingsModel?.status = "正在备份并逐文件校验…"
                DispatchQueue.global(qos: .userInitiated).async {
                    let outcome = Result {
                        if let snapshotDirectory { return try FullBackup.export(library: library, snapshotDirectory: snapshotDirectory, version: version, destination: url) }
                        return try FullBackup.export(library: library, snapshots: transient, version: version, destination: url)
                    }
                    DispatchQueue.main.async {
                        self.settingsModel?.busy = false
                        switch outcome {
                        case .success(let summary): self.settingsModel?.status = "备份完成：\(summary.fileCount) 个文件，全部 SHA-256 校验通过。"
                        case .failure(let error): self.settingsModel?.status = "备份失败：" + error.localizedDescription
                        }
                    }
                }
            } catch { self.settingsModel?.busy = false; self.settingsModel?.status = "备份失败：" + error.localizedDescription }
        }
    }
    @objc func restoreFullBackup() {
        guard settingsModel?.busy != true else { return }
        openNativeSettings()
        guard testMode || store.persistent else { settingsModel?.status = "当前处于只读模式，原资料已保留；请先解决数据读取问题再恢复。"; return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.zip]; panel.allowsMultipleSelection = false
        settingsModel?.busy = true
        panel.beginSheetModal(for: settingsWindow!) { result in
            guard result == .OK, let url = panel.url else { self.settingsModel?.busy = false; return }
            let baseline = self.library, version = self.version
            self.settingsModel?.busy = true; self.settingsModel?.status = "正在校验完整资料…"
            DispatchQueue.global(qos: .userInitiated).async {
                let outcome = Result { try FullBackup.read(url, currentVersion: version) }
                DispatchQueue.main.async {
                    do {
                        let payload = try outcome.get()
                        guard self.library == baseline else { throw AppError.message("校验期间网站资料已发生变化，请重新选择备份。") }
                        let alert = NSAlert(); alert.messageText = "恢复这份完整资料？"
                        alert.informativeText = "已校验 \(payload.manifest.files.count) 个文件，包含 \(payload.library.sites.count) 个网站与 \(payload.snapshots.count) 份快照。\n\n将恢复排列、场景和设置；备份未包含的现有网站保留为已移除入口。本机密码绑定继续保留，外来账号需重新填写密码。恢复前会保留安全快照。"
                        alert.addButton(withTitle: "恢复资料"); alert.addButton(withTitle: "取消")
                        alert.beginSheetModal(for: self.settingsWindow!) { response in
                            defer { self.settingsModel?.busy = false }
                            guard response == .alertFirstButtonReturn else { self.settingsModel?.status = "已取消恢复。"; return }
                            do {
                                guard self.library == baseline else { throw AppError.message("当前资料已变化，请重新选择备份。") }
                                self.library = try self.store.installBackup(payload, current: self.library)
                                self.organizationHistory.removeAll(); self.pendingLibraryChanges.removeAll(); self.launches.removeAll()
                                self.applyAppearance(); self.emit("update", ["state": self.state()])
                                self.settingsModel?.status = "恢复完成。原资料已保留为恢复快照；密码仍在本机钥匙串。"
                                self.settingsModel?.refresh()
                            } catch { self.settingsModel?.status = "恢复未完成：" + error.localizedDescription }
                        }
                    } catch { self.settingsModel?.busy = false; self.settingsModel?.status = "恢复未完成：" + error.localizedDescription }
                }
            }
        }
    }
}
