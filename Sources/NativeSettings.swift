import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ConnectedBrowserProfile: Identifiable, Equatable {
    let id: String
    let label: String
}

final class PortalSettingsModel: ObservableObject {
    unowned let app: AppDelegate
    @Published var busy = false
    @Published var status = ""
    @Published private(set) var checkingBrowsers = false
    @Published private(set) var browserSnapshots: [PortalBrowserTarget: BrowserDiagnosticSnapshot] = [:]
    @Published private(set) var connectedProfiles: [String: [ConnectedBrowserProfile]] = [:]

    init(app: AppDelegate) { self.app = app }
    func refresh() { objectWillChange.send() }

    func updateConnectedProfiles() {
        let profiles = Dictionary(grouping: app.activeClients(), by: \.browser).mapValues { clients in
            clients.map { ConnectedBrowserProfile(id: $0.id, label: $0.label.isEmpty ? "默认资料" : $0.label) }
                .sorted { $0.label == $1.label ? $0.id < $1.id : $0.label < $1.label }
        }
        if connectedProfiles != profiles { connectedProfiles = profiles }
    }

    func diagnoseBrowsers() {
        updateConnectedProfiles()
        guard !app.testMode, !checkingBrowsers else { return }
        let diagnostics = app.browserDiagnostics
        let workspace = NSWorkspace.shared
        let runningIDs = Set(workspace.runningApplications.compactMap(\.bundleIdentifier))
        let applications = Browser.catalog.compactMap { browser -> (PortalBrowserTarget, Bool, Bool)? in
            guard let target = PortalBrowserTarget(rawValue: browser.id) else { return nil }
            return (target, workspace.urlForApplication(withBundleIdentifier: browser.bundleID) != nil, runningIDs.contains(browser.bundleID))
        }
        let bridgeRunning = app.server != nil
        checkingBrowsers = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let results = Dictionary(uniqueKeysWithValues: applications.map { target, installed, running in
                (target, diagnostics.snapshot(for: target, installed: installed, running: running, bridgeRunning: bridgeRunning))
            })
            DispatchQueue.main.async {
                self?.browserSnapshots = results
                self?.checkingBrowsers = false
            }
        }
    }

    func repairBrowser(_ target: PortalBrowserTarget) {
        guard !app.testMode, app.store.isWritable, !checkingBrowsers,
              let snapshot = browserSnapshots[target], snapshot.canRepair else { return }
        do {
            if snapshot.nativeHost.status == .issue { try app.registerNativeHosts(for: target) }
            try app.startBrowserBridge()
            status = "已修复 \(target.name) 的本机连接配置。请在目标资料的助手弹窗中重新连接。"
        } catch { status = error.localizedDescription }
        diagnoseBrowsers()
    }

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
                Section("浏览器助手") { BrowserDiagnosticsView(model: model) }
                Section("悬浮窗") {
                    Toggle("显示悬浮窗", isOn: Binding(get: { app.floatingLauncher?.isVisible ?? false }, set: { app.setFloatingLauncherVisible($0); model.refresh() }))
                    Picker("停靠位置", selection: Binding(get: { app.floatingLauncher?.dockEdge.rawValue ?? "right" }, set: { app.floatingLauncher?.setDock(FloatingLauncherEdge(rawValue: $0) ?? .right); model.refresh() })) {
                        Text("左侧").tag("left"); Text("右侧").tag("right"); Text("自由浮动").tag("none")
                    }
                    HStack {
                        Button("重置悬浮窗位置") { app.floatingLauncher?.resetPosition(); app.setFloatingLauncherVisible(true); model.refresh() }
                        Text("⌃⌘P 显示或隐藏").foregroundStyle(.secondary)
                    }
                    Text("所有位置均收起为竖线，悬停约 0.45 秒或点击展开。鼠标移出实际窗口约 0.15 秒收起，点击其他位置立即收起；展开时可拖动顶部、两侧和底部空白处，靠近侧边 32 点内实时吸附，移开恢复自由移动；中文组词、右键菜单与登录验证时暂缓收起。窗口高度随网站数量调整，位置与显示开关仅保存在本机。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Section("下载中心") {
                    Button("打开下载队列…") { app.openDownloads() }
                    Text("HTTP / HTTPS 文件直链；复核保存目录后传输。暂停与恢复会核验原目录、片段摘要及资源版本，退出后不会继续下载。原下载目录需要在搞门户重新授权。")
                        .foregroundStyle(.secondary)
                }
                Section("邮件") {
                    Button("打开邮件…") { app.openMail() }
                    Button("邮件设置…") { app.openMailSettings() }
                    Text("在原生窗口中管理收件箱、身份、草稿与关联平台。首次只显示缓存；连接邮箱须明确确认并由系统授权读取原钥匙串凭据。")
                        .foregroundStyle(.secondary)
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
                    LabeledContent("版本", value: "V\(app.version) · 构建 \(app.build)")
                }
            }.formStyle(.grouped).tabItem { Text("外观") }
            Form {
                Section("当前资料") {
                    Text("ZIP 仅包含当前网站、账号元数据、图标、文件夹、工作场景与外观。密码留在系统钥匙串，不包含浏览器 Cookie、下载队列、邮件资料或附件。")
                        .foregroundStyle(.secondary)
                    Button("导出当前资料…") { app.exportFullBackup() }
                    Button("从资料恢复…") { app.restoreFullBackup() }
                    if model.busy { ProgressView().controlSize(.small) }
                }
                Section("JSON 格式") {
                    Text("导出当前网站资料，可合并导入或预览恢复；不包含密码。")
                        .foregroundStyle(.secondary)
                    Button("导出 JSON…") { app.exportModuleBackup() }
                    Button("导入 JSON…") { app.mergeModuleBackup() }
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
        .tint(PortalTheme.accent)
        .background(PortalTheme.canvas)
        .frame(width: 820, height: 740)
    }
}

private struct BrowserDiagnosticsView: View {
    @ObservedObject var model: PortalSettingsModel
    @State private var expanded: Set<PortalBrowserTarget> = []

    var body: some View {
        Text("Chrome 和 Edge 支持自动填充。每个资料须单独加载助手并连接。Safari 可直接启动网站，无需助手。")
            .foregroundStyle(.secondary)
        HStack {
            Button("重新检测") { model.diagnoseBrowsers() }
                .disabled(model.checkingBrowsers || model.app.testMode)
            if model.checkingBrowsers {
                ProgressView().controlSize(.small).accessibilityLabel("正在检测浏览器助手")
            }
            Button("打开助手文件夹") {
                guard !model.app.testMode else { return }
                NSWorkspace.shared.activateFileViewerSelecting([model.app.browserDiagnostics.extensionDirectory])
            }
            .disabled(model.app.testMode)
        }.buttonStyle(.bordered)
        ForEach(Browser.catalog.filter(\.supportsFill), id: \.id) { browser in
            if let target = PortalBrowserTarget(rawValue: browser.id) {
                browserRow(browser, target: target)
            }
        }
        Text("在目标资料的扩展管理页开启开发者模式并加载助手文件夹。升级后可重新加载。诊断只查看默认登记和实际连接，不能确认未回报资料的安装、停用或浏览器策略状态。")
            .font(.callout).foregroundStyle(.secondary)
    }

    private func browserRow(_ browser: Browser, target: PortalBrowserTarget) -> some View {
        let profiles = model.connectedProfiles[browser.id] ?? []
        let snapshot = model.browserSnapshots[target]
        let isExpanded = Binding(get: { expanded.contains(target) }, set: { open in
            if open { expanded.insert(target) } else { expanded.remove(target) }
        })
        return DisclosureGroup(isExpanded: isExpanded) {
            if let snapshot {
                VStack(alignment: .leading, spacing: 8) {
                    evidenceRow("浏览器", snapshot.browser)
                    evidenceRow("随附扩展", snapshot.extensionPackage)
                    evidenceRow("原生消息登记", snapshot.nativeHost)
                    evidenceRow("本机桥接", snapshot.bridge)
                    evidenceRow("资料连接", snapshot.connection(profileCount: profiles.count))
                    ForEach(profiles) { profile in
                        Label(profile.label, systemImage: "person.crop.circle")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        if snapshot.installed {
                            Button("打开 \(browser.name)") { model.app.openBrowserToConnect(browser) }
                            Button("管理扩展…") { model.app.openBrowserExtensions(browser) }
                        }
                        if snapshot.canRepair {
                            Button("修复本机连接") { model.repairBrowser(target) }
                                .disabled(model.checkingBrowsers || !model.app.store.isWritable)
                        }
                    }.buttonStyle(.bordered).disabled(model.checkingBrowsers)
                    if !model.app.store.isWritable {
                        Text("资料处于恢复保护状态，暂时无法启动桥接或修复登记。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 6)
            } else {
                Text(model.app.testMode ? "测试模式已禁用本机浏览器诊断。" : "等待检测。")
                    .font(.callout).foregroundStyle(.secondary)
            }
        } label: {
            HStack {
                Text(browser.name)
                Spacer()
                Text(summary(snapshot, profileCount: profiles.count)).foregroundStyle(.secondary)
            }
        }
    }

    private func summary(_ snapshot: BrowserDiagnosticSnapshot?, profileCount: Int) -> String {
        if profileCount > 0 { return "已连接 · \(profileCount) 个资料" }
        guard let snapshot else { return model.checkingBrowsers ? "正在检测" : "待检测" }
        if !snapshot.installed && !snapshot.running { return "未找到浏览器" }
        if snapshot.extensionPackage.status == .issue { return "随附扩展异常" }
        if snapshot.nativeHost.status == .issue { return "登记需检查" }
        if !snapshot.bridgeRunning { return "桥接未启动" }
        if !snapshot.running { return "浏览器未打开" }
        return "连接待确认"
    }

    private func evidenceRow(_ label: String, _ evidence: BrowserDiagnosticEvidence) -> some View {
        let icon: String
        let color: Color
        switch evidence.status {
        case .verified: icon = "checkmark.circle"; color = .green
        case .issue: icon = "exclamationmark.triangle"; color = .orange
        case .unknown: icon = "questionmark.circle"; color = .secondary
        }
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon).foregroundStyle(color).accessibilityHidden(true)
            Text(label).fontWeight(.medium).fixedSize()
            Text(evidence.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.font(.callout)
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
        try store.save(next); library = next; applyAppearance(); publishLauncherState()
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
    @objc func toggleSidebar() {
        if mailWindowController?.ownsKeyWindow == true {
            NotificationCenter.default.post(name: .mailToggleSidebar, object: nil)
        } else { emit("toggleSidebar", [:]) }
    }
    func openNativeSettings() {
        if settingsWindow == nil {
            let model = PortalSettingsModel(app: self); settingsModel = model
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 740), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            panel.title = "搞门户设置"; panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: PortalSettingsView(model: model))
            panel.center(); settingsWindow = panel
        }
        settingsModel?.refresh(); settingsModel?.diagnoseBrowsers()
        settingsWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func showSettingsPage(_ page: String) {
        guard settingsModel?.busy != true else { return }
        settingsWindow?.orderOut(nil); window.makeKeyAndOrderFront(nil)
        emit("settingsPage", ["page": page])
    }
    @objc func restoreModuleBackup() { showSettingsPage("backup-restore") }
    @objc func mergeModuleBackup() { showSettingsPage("backup-merge") }
    var browserDiagnostics: BrowserDiagnostics {
        .init(home: FileManager.default.homeDirectoryForCurrentUser,
              systemLibrary: URL(fileURLWithPath: "/Library", isDirectory: true), resources: resources,
              helper: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/MenDaoBridge"), hostName: nativeHostName)
    }
    func startBrowserBridge() throws {
        guard !testMode, store.isWritable, server == nil else { return }
        let bridge = BridgeServer(expectedHostPath: browserDiagnostics.helper.path)
        bridge.handler = { [weak self] request in self?.handleBrowser(request) ?? ["ok": false] }
        try bridge.start()
        server = bridge
    }
    func openBrowserToConnect(_ browser: Browser) {
        guard !testMode else { return }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleID) else {
            settingsModel?.status = "系统未找到 \(browser.name)。"
            settingsModel?.diagnoseBrowsers()
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { [weak self] _, error in
            DispatchQueue.main.async {
                self?.settingsModel?.status = error.map { "无法打开 \(browser.name)：\($0.localizedDescription)" }
                    ?? "请在 \(browser.name) 的目标资料中打开搞门户助手，点击「重新连接」。"
                self?.settingsModel?.diagnoseBrowsers()
            }
        }
    }
    func openBrowserExtensions(_ browser: Browser) {
        guard !testMode else { return }
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleID),
              let url = URL(string: browser.id == "chrome" ? "chrome://extensions/" : "edge://extensions/") else {
            settingsModel?.status = "无法找到 \(browser.name) 的扩展管理入口。"
            settingsModel?.diagnoseBrowsers()
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: .init()) { [weak self] _, error in
            DispatchQueue.main.async {
                if let error { self?.settingsModel?.status = "无法打开扩展管理页：\(error.localizedDescription)" }
                self?.settingsModel?.diagnoseBrowsers()
            }
        }
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
        guard testMode || store.isWritable else { settingsModel?.status = "资料处于恢复保护状态，不能导出空白界面作为模块备份。原资料保持不变。"; return }
        guard settingsModel?.busy != true else { return }
        openNativeSettings()
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "搞门户-模块备份.json"
        settingsModel?.busy = true
        panel.beginSheetModal(for: settingsWindow!) { result in
            defer { self.settingsModel?.busy = false }
            guard result == .OK, let url = panel.url else { return }
            do {
                try self.store.requireWritable()
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(self.library).write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                self.settingsModel?.status = "模块备份已导出；密码保留在本机钥匙串。"
            } catch { self.settingsModel?.status = "导出失败：" + error.localizedDescription }
        }
    }
    @objc func exportFullBackup() {
        guard testMode || store.isWritable else { settingsModel?.status = "主库处于恢复保护状态，不能把空白界面导出为资料。原文件仍在原目录。"; return }
        guard settingsModel?.busy != true else { return }
        openNativeSettings()
        let panel = NSSavePanel(); panel.allowedContentTypes = [.zip]; panel.nameFieldStringValue = FullBackup.defaultFilename
        settingsModel?.busy = true
        panel.beginSheetModal(for: settingsWindow!) { result in
            guard result == .OK, let url = panel.url else { self.settingsModel?.busy = false; return }
            do {
                try self.store.requireWritable()
                let library = self.library, version = self.version
                self.settingsModel?.busy = true; self.settingsModel?.status = "正在导出并校验当前资料…"
                DispatchQueue.global(qos: .userInitiated).async {
                    let outcome = Result { try FullBackup.export(library: library, version: version, destination: url) }
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
        guard testMode || (store.persistent && store.isWritable) else { settingsModel?.status = "当前处于恢复保护模式，原资料已保留；请先检查主库及初始化证据，再恢复已核验的备份。"; return }
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
                        alert.informativeText = "已校验当前资料，包含 \(payload.library.sites.count) 个网站。\n\n将恢复排列、场景和设置；资料包未包含的现有网站保留为已移除入口。本机密码绑定继续保留，外来账号需重新填写密码。"
                        alert.addButton(withTitle: "恢复资料"); alert.addButton(withTitle: "取消")
                        alert.beginSheetModal(for: self.settingsWindow!) { response in
                            defer { self.settingsModel?.busy = false }
                            guard response == .alertFirstButtonReturn else { self.settingsModel?.status = "已取消恢复。"; return }
                            do {
                                guard self.library == baseline else { throw AppError.message("当前资料已变化，请重新选择备份。") }
                                let restored = try LibraryOperations.restore(payload.library, into: self.library)
                                try self.store.save(restored); self.library = restored
                                self.organizationHistory.removeAll(); self.pendingLibraryChanges.removeAll(); self.launches.removeAll()
                                self.applyAppearance(); self.publishLauncherState()
                                self.settingsModel?.status = "当前资料已恢复；密码仍在本机钥匙串。"
                                self.settingsModel?.refresh()
                            } catch { self.settingsModel?.status = "恢复未完成：" + error.localizedDescription }
                        }
                    } catch { self.settingsModel?.busy = false; self.settingsModel?.status = "恢复未完成：" + error.localizedDescription }
                }
            }
        }
    }
}
