import AppKit
import WebKit
import Foundation
import Carbon
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate, NSWindowDelegate, NSMenuItemValidation {
    var window: NSWindow!
    var web: WKWebView!
    var library: Library = .empty() { didSet { floatingLauncher?.refresh() } }
    var store: LibraryStore!
    var vault: Vault!
    var server: BridgeServer?
    var clients: [String: BrowserClient] = [:]
    var launches: [String: LaunchRequest] = [:]
    var statusItem: NSStatusItem!
    var hotkey: EventHotKeyRef?
    var timer: Timer?
    var settingsWindow: NSWindow?
    var settingsModel: PortalSettingsModel?
    var floatingLauncher: FloatingLauncherController?
    var testMode = CommandLine.arguments.contains("--ui-test")
    var lastInteraction = Date()
    var lastClientSignature = ""
    let iconLoader = IconLoader()
    var iconRequests: [String: (token: UUID, url: String)] = [:]
    var organizationHistory: [OrganizationEdit] = []
    var pendingLibraryChanges: [String: PendingLibraryChange] = [:]
    var searchKeyCache: [String: (String, String)] = [:]
    var launchFeedback: [String: String] = [:]
    let resources = Bundle.main.resourceURL!
    var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.00" }

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        let siblings = NSRunningApplication.runningApplications(withBundleIdentifier: "cn.mendao.launcher").filter { $0.processIdentifier != getpid() }
        if !testMode, let existing = siblings.first {
            existing.activate(options: [.activateAllWindows]); NSApp.terminate(nil); return
        }
        store = LibraryStore(persistent: !testMode)
        vault = Vault(testing: testMode)
        var loadError: String?
        do {
            library = try store.load(defaultBrowsers: installedBrowsers().map { $0.id })
            if !testMode && !FileManager.default.fileExists(atPath: store.file.path) { try store.save(library) }
        }
        catch { library = .empty(); loadError = "已有数据读取失败，暂时进入只读空白界面。原始数据已保留。\n\(error.localizedDescription)"; store = LibraryStore(persistent: false) }
        applyAppearance(); setupMenus(); setupWindow(); setupStatusItem(); registerHotkey()
        floatingLauncher = FloatingLauncherController(app: self)
        floatingLauncher?.start()
        if !testMode {
            do {
                try registerNativeHosts()
                let bridge = BridgeServer(expectedHostPath: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/MenDaoBridge").path)
                bridge.handler = { [weak self] request in self?.handleBrowser(request) ?? ["ok": false] }
                try bridge.start(); server = bridge
            } catch { loadError = error.localizedDescription }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            if Date().timeIntervalSince(self.lastInteraction) > 300, self.vault.unlocked, !self.testMode {
                self.vault.lock(); self.launches.removeAll(); self.emit("locked", [:])
            }
            if !self.vault.unlocked { self.emit("locked", [:]) }
            self.launches = self.launches.filter { $0.value.expires > Date() }
            self.launchFeedback = self.launchFeedback.filter { self.launches[$0.key] != nil }
            let signature = self.activeClients().map { $0.id + $0.label }.joined(separator: "|")
            if signature != self.lastClientSignature {
                self.lastClientSignature = signature
                self.emit("profiles", ["state": self.state()])
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(lockVault), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(lockVault), name: NSWorkspace.willSleepNotification, object: nil)
        if let loadError { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.showError(loadError) } }
        if !testMode {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                for site in self.library.sites where site.iconSource != "custom" &&
                    (((site.iconRevision ?? 0) < 2 && Date().timeIntervalSince1970 - (site.iconCheckedAt ?? 0) > 86400) ||
                     (site.icon == nil && Date().timeIntervalSince1970 - (site.iconCheckedAt ?? 0) > 604800)) {
                    self.fetchIcon(site)
                }
            }
        }
        #if DEBUG_TESTING
        if testMode && CommandLine.arguments.contains("--self-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.runAutomatedTests() }
        }
        #endif
    }

    func setupWindow() {
        let controller = WKUserContentController(); controller.add(self, name: "mendao")
        let config = WKWebViewConfiguration(); config.userContentController = controller
        config.websiteDataStore = .nonPersistent()
        web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        if #available(macOS 13.3, *) { web.isInspectable = testMode }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1380, height: 860), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "搞门户 V\(version)"
        window.backgroundColor = .windowBackgroundColor
        window.minSize = NSSize(width: 1040, height: 720)
        configureToolbar()
        window.isReleasedWhenClosed = false; window.delegate = self
        window.contentView = web
        window.collectionBehavior = [.fullScreenPrimary]
        let frameName = testMode ? "MenDao.Test" : "MenDao.Main"
        window.setFrameAutosaveName(frameName)
        if !window.setFrameUsingName(frameName) { window.center() }
        web.loadFileURL(resources.appendingPathComponent("index.html"), allowingReadAccessTo: resources)
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    func setupMenus() {
        let bar = NSMenu()
        let appRoot = NSMenuItem(); bar.addItem(appRoot)
        let appMenu = NSMenu(); appRoot.submenu = appMenu
        appMenu.addItem(withTitle: "关于搞门户", action: #selector(about), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "锁定账号库", action: #selector(lockVault), keyEquivalent: "l")
        appMenu.addItem(withTitle: "设置…", action: #selector(settings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏搞门户", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "退出搞门户", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editRoot = NSMenuItem(); bar.addItem(editRoot); let edit = NSMenu(title: "编辑"); editRoot.submenu = edit
        let undo = edit.addItem(withTitle: "撤销整理或编辑", action: #selector(undoMenu), keyEquivalent: "z"); undo.target = self
        for item in [("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            edit.addItem(withTitle: item.0, action: Selector(item.1), keyEquivalent: item.2)
        }
        let viewRoot = NSMenuItem(); bar.addItem(viewRoot); let view = NSMenu(title: "显示"); viewRoot.submenu = view
        view.addItem(withTitle: "搜索网站", action: #selector(search), keyEquivalent: "f")
        view.addItem(withTitle: "添加网站", action: #selector(addSite), keyEquivalent: "n")
        let full = view.addItem(withTitle: "切换全屏", action: #selector(fullscreen), keyEquivalent: "f"); full.keyEquivalentModifierMask = [.command, .control]
        let sidebar = view.addItem(withTitle: "显示或隐藏侧栏", action: #selector(toggleSidebar), keyEquivalent: "s"); sidebar.keyEquivalentModifierMask = [.command, .control]
        let floating = view.addItem(withTitle: "显示或隐藏悬浮窗", action: #selector(toggleFloatingLauncher), keyEquivalent: "p")
        floating.keyEquivalentModifierMask = [.command, .control]; floating.target = self
        let dataRoot = NSMenuItem(); bar.addItem(dataRoot); let data = NSMenu(title: "数据"); dataRoot.submenu = data
        data.addItem(withTitle: "导出完整资料…", action: #selector(exportFullBackup), keyEquivalent: "")
        data.addItem(withTitle: "从完整资料恢复…", action: #selector(restoreFullBackup), keyEquivalent: "")
        data.addItem(.separator())
        data.addItem(withTitle: "导出模块备份…", action: #selector(exportModuleBackup), keyEquivalent: "")
        data.addItem(withTitle: "恢复模块备份…", action: #selector(restoreModuleBackup), keyEquivalent: "")
        data.addItem(withTitle: "合并导入模块备份…", action: #selector(mergeModuleBackup), keyEquivalent: "")
        NSApp.mainMenu = bar
    }
    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let image = NSImage(systemSymbolName: "door.left.hand.open", accessibilityDescription: "搞门户") { image.isTemplate = true; statusItem.button?.image = image }
        let menu = NSMenu()
        menu.addItem(withTitle: "打开搞门户  ⌃⌥Space", action: #selector(showWindow), keyEquivalent: "")
        let floating = menu.addItem(withTitle: "显示或隐藏悬浮窗", action: #selector(toggleFloatingLauncher), keyEquivalent: ""); floating.target = self
        menu.addItem(withTitle: "锁定账号库", action: #selector(lockVault), keyEquivalent: "")
        menu.addItem(.separator()); menu.addItem(withTitle: "退出搞门户", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        statusItem.menu = menu
    }
    func registerHotkey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, data in
            if let data { Unmanaged<AppDelegate>.fromOpaque(data).takeUnretainedValue().showWindow() }
            return noErr
        }, 1, &spec, pointer, nil)
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey), EventHotKeyID(signature: 0x4D44414F, id: 1), GetApplicationEventTarget(), 0, &hotkey)
    }
    @objc func showWindow() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); emit("search", [:]) }
    @objc func undoMenu() { web.evaluateJavaScript("window.mendaoUndo && window.mendaoUndo();", completionHandler: nil) }
    @objc func lockVault() { vault?.lock(); launches.removeAll(); emit("locked", [:]) }
    @objc func about() { NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "搞门户", .applicationVersion: "V\(version)", .credits: NSAttributedString(string: "网站、账号，一点就到。\n网站启动台 · 浏览器选择 · 本地账号库")]) }
    @objc func settings() { openNativeSettings() }
    @objc func search() { showWindow(); emit("search", [:]) }
    @objc func addSite() { showWindow(); emit("addSite", [:]) }
    @objc func fullscreen() { window.toggleFullScreen(nil) }
    @objc func toggleFloatingLauncher() { floatingLauncher?.toggle(); settingsModel?.refresh() }
    func setFloatingLauncherVisible(_ visible: Bool) { floatingLauncher?.setVisible(visible); settingsModel?.refresh() }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleFloatingLauncher) { menuItem.state = floatingLauncher?.isVisible == true ? .on : .off }
        return true
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { sender.orderOut(nil); return false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationWillTerminate(_ notification: Notification) { floatingLauncher?.stop(); timer?.invalidate(); server?.stop(); if let hotkey { UnregisterEventHotKey(hotkey) } }

    func installedBrowsers() -> [Browser] { Browser.catalog.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil } }
    func activeClients() -> [BrowserClient] { clients.values.filter { Date().timeIntervalSince($0.lastSeen) < 9 }.sorted { $0.label < $1.label } }
    func state() -> [String: Any] {
        let value = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(library))) ?? [:]
        return ["library": value, "version": version, "unlocked": vault.unlocked,
                "browsers": Browser.catalog.map { browser -> [String: Any] in
                    ["id": browser.id, "name": browser.name, "installed": installedBrowsers().contains(browser), "supportsFill": browser.supportsFill]
                }, "profiles": activeClients().map { ["id": $0.id, "browser": $0.browser, "label": $0.label] },
                "testMode": testMode, "canUndo": !organizationHistory.isEmpty, "searchKeys": searchKeys(),
                "extensionPath": resources.appendingPathComponent("BrowserExtension").path]
    }
    func emit(_ event: String, _ payload: [String: Any]) {
        if event == "toast", let message = payload["message"] as? String { floatingLauncher?.showStatus(message) }
        guard web != nil, let data = try? JSONSerialization.data(withJSONObject: ["event": event, "payload": payload]), let text = String(data: data, encoding: .utf8) else { return }
        web.evaluateJavaScript("window.nativeEvent && window.nativeEvent(\(text));", completionHandler: nil)
    }
    func reply(_ id: String, _ value: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: ["id": id, "value": value]), let text = String(data: data, encoding: .utf8) else { return }
        web.evaluateJavaScript("window.nativeReply(\(text));", completionHandler: nil)
    }
    func showError(_ text: String) { let alert = NSAlert(); alert.messageText = "搞门户"; alert.informativeText = text; alert.addButton(withTitle: "知道了"); alert.runModal() }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let allowed = action.request.url?.isFileURL == true && action.request.url?.standardizedFileURL.path.hasPrefix(resources.standardizedFileURL.path + "/") == true
        decisionHandler(allowed ? .allow : .cancel)
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.isFileURL == true,
              let body = message.body as? [String: Any], let id = body["id"] as? String, let action = body["action"] as? String else { return }
        let data = body["data"] as? [String: Any] ?? [:]
        lastInteraction = Date()
        do {
            switch action {
            case "state": reply(id, ["ok": true, "state": state()])
            case "layout":
                guard let tiles = data["tiles"], let json = try? JSONSerialization.data(withJSONObject: tiles) else { throw AppError.message("排列数据无效。") }
                var next = library; next.tiles = try JSONDecoder().decode([Tile].self, from: json)
                let previous = visibleSiteIDs(library.tiles)
                guard visibleSiteIDs(next.tiles) == previous else { throw AppError.message("拖动时不能丢失网站。") }
                try commitOrganization(next, reason: "调整排列前"); reply(id, ["ok": true, "state": state()])
            case "saveSite": saveSite(data, responseID: id)
            case "launch": launch(data, responseID: id)
            case "removeSite":
                guard let siteID = data["siteID"] as? String else { throw AppError.message("网站不存在。") }
                var next = library; next.tiles = removeFromTiles(siteID, next.tiles)
                try commitOrganization(next, reason: "移除入口前")
                launches = launches.filter { $0.value.siteID != siteID }
                reply(id, ["ok": true, "state": state()])
            case "restoreSite":
                guard let siteID = data["siteID"] as? String, library.sites.contains(where: { $0.id == siteID }) else { throw AppError.message("网站不存在。") }
                var next = library
                if !visibleSiteIDs(next.tiles).contains(siteID) { next.tiles.append(Tile(id: siteID, kind: "site", name: nil, children: nil)) }
                try commitOrganization(next, reason: "恢复入口前"); reply(id, ["ok": true, "state": state()])
            case "deleteAccount": deleteAccount(data, responseID: id)
            case "unlock": vault.authenticate("解锁搞门户的网站账号库") { ok, error in self.reply(id, ["ok": ok, "error": error ?? "", "state": self.state()]) }
            case "lock": lockVault(); reply(id, ["ok": true, "state": state()])
            case "chooseIcon":
                let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg, .webP, .ico]; panel.allowsMultipleSelection = false
                panel.beginSheetModal(for: window) { response in
                    if response == .OK, let url = panel.url,
                       let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                       let bytes = attributes[.size] as? NSNumber, bytes.intValue < 20_000_000,
                       let image = NSImage(contentsOf: url), let encoded = self.imageData(image, size: 1024) {
                        self.reply(id, ["ok": true, "icon": encoded, "sourcePixels": 1024])
                    }
                    else { self.reply(id, ["ok": false, "cancelled": true]) }
                }
            case "extensionFolder": NSWorkspace.shared.activateFileViewerSelecting([resources.appendingPathComponent("BrowserExtension")]); reply(id, ["ok": true])
            case "extensionSetup":
                guard let browserID = data["browser"] as? String, ["chrome", "edge"].contains(browserID),
                      let browser = Browser.catalog.first(where: { $0.id == browserID }), let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleID),
                      let url = URL(string: browserID == "chrome" ? "chrome://extensions/" : "edge://extensions/") else { throw AppError.message("浏览器未安装。") }
                NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil); reply(id, ["ok": true])
            case "fullscreen": fullscreen(); reply(id, ["ok": true])
            case "refreshIcons":
                iconLoader.clearCache()
                for site in library.sites where site.iconSource != "custom" { fetchIcon(site) }
                reply(id, ["ok": true, "message": "正在重新获取清晰图标，完成后会自动更新。"])
            case "appearance":
                try updateSettings(appearance: data["appearance"] as? String)
                reply(id, ["ok": true, "state": state()])
            case "openSettings": settings(); reply(id, ["ok": true])
            case "export": exportLibrary(id)
            case "import": previewBackup(["mode": "merge"], responseID: id)
            case "quit": NSApp.terminate(nil)
            default: if try !handleFeatureAction(action, data: data, responseID: id) { throw AppError.message("未知操作。") }
            }
        } catch { reply(id, ["ok": false, "error": error.localizedDescription]) }
    }

    func visibleSiteIDs(_ tiles: [Tile]) -> Set<String> { Set(tiles.flatMap { $0.kind == "folder" ? ($0.children ?? []) : [$0.id] }) }
    func removeFromTiles(_ id: String, _ input: [Tile]) -> [Tile] {
        input.compactMap { tile in
            if tile.kind == "site" { return tile.id == id ? nil : tile }
            var folder = tile; folder.children = (folder.children ?? []).filter { $0 != id }
            return folder.children!.isEmpty ? nil : folder
        }
    }

    func saveSite(_ data: [String: Any], responseID: String) {
        guard let siteObject = data["site"] as? [String: Any] else { reply(responseID, ["ok": false, "error": "网站数据无效。"]); return }
        let hasSecrets = (siteObject["accounts"] as? [[String: Any]] ?? []).contains { ($0["password"] as? String).map { !$0.isEmpty } ?? false }
        let perform = {
            var staged: [String] = []
            do {
                var object = siteObject
                var accounts = object["accounts"] as? [[String: Any]] ?? []
                var passwords: [String: String] = [:]
                let siteID = object["id"] as? String ?? ""
                let old = self.library.sites.first(where: { $0.id == siteID })
                for i in accounts.indices {
                    let oldID = accounts[i]["id"] as? String ?? UUID().uuidString
                    let previous = old?.accounts.first(where: { $0.id == oldID })
                    let password = accounts[i].removeValue(forKey: "password") as? String ?? ""
                    accounts[i]["hasPassword"] = previous?.hasPassword ?? false
                    if !password.isEmpty {
                        let newID = UUID().uuidString
                        accounts[i]["id"] = newID; accounts[i]["hasPassword"] = true
                        if object["defaultAccount"] as? String == oldID { object["defaultAccount"] = newID }
                        passwords[newID] = password
                    } else { accounts[i]["id"] = oldID }
                    let hosts = accounts[i]["loginHosts"] as? [String] ?? []
                    guard hosts.allSatisfy({ normalizedHost($0) != nil }) else { throw AppError.message("登录域名格式不正确。请填写完整域名，例如 accounts.example.com。") }
                    accounts[i]["loginHosts"] = hosts.compactMap(normalizedHost)
                }
                object["accounts"] = accounts
                if accounts.isEmpty { object.removeValue(forKey: "defaultAccount") }
                let json = try JSONSerialization.data(withJSONObject: object)
                var site = try JSONDecoder().decode(Website.self, from: json)
                if let old, old.url == site.url, object["iconChanged"] as? Bool != true {
                    // The editor may have opened before a background icon upgrade finished.
                    site.icon = old.icon; site.iconSource = old.iconSource
                    site.iconRevision = old.iconRevision; site.iconSourcePixels = old.iconSourcePixels
                    site.iconCheckedAt = old.iconCheckedAt
                }
                if old?.url != site.url, site.iconSource != "custom" {
                    site.icon = nil; site.iconRevision = nil; site.iconSourcePixels = nil; site.iconCheckedAt = nil
                }
                var next = self.library
                if let index = next.sites.firstIndex(where: { $0.id == site.id }) { next.sites[index] = site }
                else { next.sites.append(site); next.tiles.append(Tile(id: site.id, kind: "site", name: nil, children: nil)) }
                _ = try next.validated()
                for (id, password) in passwords { try self.vault.save(password, id: id); staged.append(id) }
                try self.store.save(next)
                self.library = next
                self.organizationHistory.removeAll()
                self.launches = self.launches.filter { $0.value.siteID != site.id }
                let retained = Set(site.accounts.map(\.id))
                var cleanupFailed = false
                for account in old?.accounts ?? [] where !retained.contains(account.id) {
                    do { try self.vault.remove(id: account.id) } catch { cleanupFailed = true }
                }
                self.reply(responseID, ["ok": true, "state": self.state(), "warning": cleanupFailed ? "网站已保存，但旧密码的钥匙串清理失败，请在系统钥匙串中处理。" : ""])
                if site.icon == nil, site.iconSource != "custom" { self.fetchIcon(site) }
            } catch {
                for id in staged { try? self.vault.remove(id: id) }
                self.reply(responseID, ["ok": false, "error": error.localizedDescription])
            }
        }
        let oldAccounts = library.sites.first(where: { $0.id == siteObject["id"] as? String })?.accounts ?? []
        let newIDs = Set((siteObject["accounts"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String })
        let removingAccounts = oldAccounts.contains { !newIDs.contains($0.id) }
        if hasSecrets || removingAccounts { vault.authenticate("更新搞门户的网站账号密码") { ok, error in if ok { perform() } else { self.reply(responseID, ["ok": false, "error": error ?? "已取消。"] ) } } }
        else { perform() }
    }

    func deleteAccount(_ data: [String: Any], responseID: String) {
        guard let siteID = data["siteID"] as? String, let accountID = data["accountID"] as? String,
              let index = library.sites.firstIndex(where: { $0.id == siteID }), library.sites[index].accounts.contains(where: { $0.id == accountID }) else { reply(responseID, ["ok": false, "error": "账号不存在。"]); return }
        vault.authenticate("删除搞门户保存的网站账号") { ok, error in
            guard ok else { self.reply(responseID, ["ok": false, "error": error ?? "已取消。"]); return }
            do {
                var next = self.library
                next.sites[index].accounts.removeAll { $0.id == accountID }
                if next.sites[index].defaultAccount == accountID { next.sites[index].defaultAccount = next.sites[index].accounts.first?.id }
                let originalAccount = self.library.sites[index].accounts.first { $0.id == accountID }!
                let originalPassword = originalAccount.hasPassword ? try self.vault.read(id: accountID) : nil
                try self.vault.remove(id: accountID)
                do { try self.store.save(next) }
                catch {
                    if let originalPassword { try? self.vault.save(originalPassword, id: accountID) }
                    throw error
                }
                self.library = next
                self.launches = self.launches.filter { $0.value.accountID != accountID }
                self.reply(responseID, ["ok": true, "state": self.state()])
            } catch { self.reply(responseID, ["ok": false, "error": error.localizedDescription]) }
        }
    }

    func launchFromFloating(siteID: String, browserID: String?, completion: @escaping (String?) -> Void) {
        lastInteraction = Date()
        guard visibleSiteIDs(library.tiles).contains(siteID) else { completion("这个网站已从启动台移除。"); return }
        var data: [String: Any] = ["siteID": siteID]
        if let browserID { data["browser"] = browserID }
        launch(data, responseID: nil) { value in
            completion(value["ok"] as? Bool == true ? nil : (value["error"] as? String ?? "网站打开失败。"))
        }
    }

    func launch(_ data: [String: Any], responseID: String?, completion: (([String: Any]) -> Void)? = nil) {
        let respond: ([String: Any]) -> Void = { value in
            if let completion { completion(value) }
            else if let responseID { self.reply(responseID, value) }
        }
        guard let siteID = data["siteID"] as? String, let site = library.sites.first(where: { $0.id == siteID }) else { respond(["ok": false, "error": "网站不存在。"]); return }
        let browserID = data["browser"] as? String ?? site.defaultBrowser
        do { try validateLaunch(site, browserID: browserID) }
        catch { respond(["ok": false, "error": error.localizedDescription]); return }
        if testMode { respond(["ok": true, "message": "测试启动已验证。"]); return }
        guard let browser = Browser.catalog.first(where: { $0.id == browserID }),
              let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleID), let url = validWebURL(site.url) else { respond(["ok": false, "error": "浏览器未安装或网址无效。"]); return }
        let accountID = data["accountID"] as? String ?? site.defaultAccount
        let account = site.accounts.first(where: { $0.id == accountID })
        let perform = {
            let available = self.activeClients().filter { $0.browser == browserID }
            let selectedProfile = site.profiles[browserID].flatMap { $0.isEmpty ? nil : $0 }
            // Recheck after authentication: connected profiles may have changed while the prompt was open.
            do { try self.validateLaunch(site, browserID: browserID) }
            catch { respond(["ok": false, "error": error.localizedDescription]); return }
            let needsFill = account?.hasPassword == true
            let profile = selectedProfile ?? available.first?.id
            let requestID = UUID().uuidString
            if browser.supportsFill && (!available.isEmpty || needsFill) {
                self.launches[requestID] = LaunchRequest(id: requestID, browser: browserID, profileID: profile, siteID: site.id,
                    accountID: account?.id, url: url.absoluteString, allowed: account.map { allowedOrigins(site: site, account: $0) } ?? [],
                    expires: Date().addingTimeInterval(300))
                NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                    if error != nil { DispatchQueue.main.async {
                        self.launches.removeValue(forKey: requestID)
                        self.emit("toast", ["message": "浏览器未能启动，请重新打开浏览器后重试。"])
                    } }
                }
                respond(["ok": true, "message": available.isEmpty ? "正在连接浏览器助手…" : "正在用 \(browser.name) 打开 \(site.name)…"])
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                    guard let request = self.launches[requestID], request.claimedProfile == nil else { return }
                    self.launches.removeValue(forKey: requestID)
                    // Explicit profiles must never fall back to a different profile.
                    if selectedProfile != nil {
                        self.emit("toast", ["message": "指定的浏览器资料未响应，请打开它的搞门户助手并重新连接。"])
                    } else {
                        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                            DispatchQueue.main.async { self.emit("toast", ["message": error == nil ? "网页已打开，但助手未连接。请在浏览器中打开搞门户助手并重新连接后重试自动填充。" : "网页打开失败，请检查浏览器。"]) }
                        }
                    }
                }
            } else {
                // Ordinary launches do not wait for a browser helper when no account needs filling.
                NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                    DispatchQueue.main.async { self.emit("toast", ["message": error == nil ? "已交给 \(browser.name) 打开 \(site.name)。" : "网页打开失败，请检查浏览器后重试。"]) }
                }
                respond(["ok": true, "message": "正在用 \(browser.name) 打开…"])
            }
        }
        if account?.hasPassword == true {
            vault.authenticate("为 \(site.name) 填入你选择的账号") { ok, error in if ok { perform() } else { respond(["ok": false, "error": error ?? "已取消解锁。"] ) } }
        } else { perform() }
    }

    func handleBrowser(_ data: [String: Any]) -> [String: Any] {
        guard let browser = data["browser"] as? String, ["chrome", "edge"].contains(browser),
              let extensionID = data["extension"] as? String,
              let expected = try? String(contentsOf: resources.appendingPathComponent("extension-id.txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), extensionID == expected,
              let profileID = data["profileId"] as? String, profileID.count <= 100, UUID(uuidString: profileID) != nil else { return ["ok": false, "error": "连接身份无效。"] }
        let label = String((data["label"] as? String ?? "默认资料").prefix(80))
        let before = Set(activeClients().map(\.id))
        clients[profileID] = BrowserClient(id: profileID, browser: browser, label: label, lastSeen: Date())
        if before != Set(activeClients().map(\.id)) { emit("profiles", ["state": state()]) }
        switch data["type"] as? String {
        case "collections":
            return ["ok": true, "folders": library.tiles.filter { $0.kind == "folder" }.map { ["id": $0.id, "name": $0.name ?? "文件夹"] }]
        case "saveBookmark":
            do { return try saveBrowserBookmark(data, browser: browser, profileID: profileID) }
            catch { return ["ok": false, "error": error.localizedDescription] }
        case "poll":
            if let key = launches.keys.sorted(by: { launches[$0]!.createdAt < launches[$1]!.createdAt }).first(where: { key in
                guard let item = launches[key] else { return false }
                return item.browser == browser && item.claimedProfile == nil && item.expires > Date() && (item.profileID == nil || item.profileID == profileID)
            }), var request = launches[key] {
                if request.profileID == nil, activeClients().filter({ $0.browser == browser }).count > 1 {
                    launches.removeValue(forKey: key); emit("toast", ["message": "多个浏览器资料已连接，请为网站指定资料。"])
                    return ["ok": true, "version": version]
                }
                request.claimedProfile = profileID; launches[key] = request
                return ["ok": true, "version": version, "launch": ["id": request.id, "url": request.url]]
            }
            return ["ok": true, "version": version, "unlocked": vault.unlocked]
        case "bind":
            guard let id = data["requestId"] as? String, let tabID = data["tabId"] as? Int,
                  var request = launches[id], request.claimedProfile == profileID, request.browser == browser,
                  request.expires > Date(), request.tabID == nil else { return ["ok": false] }
            request.tabID = tabID; launches[id] = request; return ["ok": true]
        case "launchStatus":
            guard let id = data["requestId"] as? String, let request = launches[id], request.browser == browser,
                  request.claimedProfile == profileID, request.expires > Date(),
                  let status = data["status"] as? String, ["opened", "failed"].contains(status) else { return ["ok": false] }
            if status == "opened" {
                guard let tabID = data["tabId"] as? Int, request.tabID == tabID else { return ["ok": false] }
                let site = library.sites.first { $0.id == request.siteID }
                let needsFill = site?.accounts.contains { $0.id == request.accountID && $0.hasPassword } == true
                if request.filled { return ["ok": true] }
                reportLaunch(id, message: needsFill ? "网页已打开，等待登录表单…" : "网页已在指定浏览器资料中打开。")
                if needsFill {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 25) {
                        guard let current = self.launches[id], !current.filled,
                              self.launchFeedback[id] == "网页已打开，等待登录表单…" else { return }
                        self.reportLaunch(id, message: "尚未检测到可填表单：可能已登录，或需要先进入登录页。")
                    }
                } else { launches.removeValue(forKey: id) }
            } else {
                if let bound = request.tabID, bound != data["tabId"] as? Int { return ["ok": false] }
                reportLaunch(id, message: "浏览器未能完成打开，请从搞门户重试；仍失败时在助手中重新连接。")
                launches.removeValue(forKey: id)
            }
            return ["ok": true]
        case "credentials":
            guard let id = data["requestId"] as? String, let tabID = data["tabId"] as? Int,
                  let request = launches[id], request.browser == browser, request.claimedProfile == profileID,
                  request.tabID == tabID, request.expires > Date(), !request.filled,
                  let url = data["url"] as? String, let source = origin(url), source.hasPrefix("https://"),
                  let site = library.sites.first(where: { $0.id == request.siteID }),
                  let account = site.accounts.first(where: { $0.id == request.accountID }), account.hasPassword else { return ["ok": false, "error": "没有可用的填充授权。"] }
            guard request.allowed.contains(source) else {
                let message = "当前登录页的域名未获授权。请核对网站，在账号编辑中填写准确的其他登录域名后重新启动。"
                reportLaunch(id, message: message); return ["ok": false, "error": message]
            }
            guard vault.unlocked else {
                let message = "账号库已锁定，请回到搞门户解锁并重新打开网站。"
                reportLaunch(id, message: message); return ["ok": false, "error": message]
            }
            do {
                let password = try vault.read(id: account.id)
                guard !password.isEmpty else { throw AppError.message("密码不可用，请在搞门户中重新保存该账号密码。") }
                return ["ok": true, "username": account.username, "password": password]
            } catch {
                reportLaunch(id, message: error.localizedDescription)
                return ["ok": false, "error": error.localizedDescription]
            }
        case "filled":
            guard let id = data["requestId"] as? String, var request = launches[id], request.claimedProfile == profileID,
                  request.browser == browser, request.tabID == data["tabId"] as? Int else { return ["ok": false] }
            // Two-step forms may need username and password on consecutive pages.
            guard request.expires > Date() else { return ["ok": false] }
            if data["passwordFilled"] as? Bool == true {
                request.filled = true; launches[id] = request
                reportLaunch(id, message: "账号和密码已填入，请自行完成登录。")
            } else { reportLaunch(id, message: "账号已填入，等待下一步密码页面。") }
            return ["ok": true]
        case "close":
            if let id = data["requestId"] as? String, let request = launches[id], request.claimedProfile == profileID, request.browser == browser { launches.removeValue(forKey: id) }
            return ["ok": true]
        default: return ["ok": false]
        }
    }

    func registerNativeHosts() throws {
        let host = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/MenDaoBridge").path
        let id = try String(contentsOf: resources.appendingPathComponent("extension-id.txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let object: [String: Any] = ["name": nativeHostName, "description": "搞门户浏览器助手", "path": host, "type": "stdio", "allowed_origins": ["chrome-extension://\(id)/"]]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        for path in ["Library/Application Support/Google/Chrome/NativeMessagingHosts", "Library/Application Support/Microsoft Edge/NativeMessagingHosts"] {
            let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent(nativeHostName + ".json")
            try data.write(to: destination, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        }
    }

    func imageData(_ image: NSImage, size: Int) -> String? {
        guard image.size.width > 0, image.size.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let graphics = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
        graphics.imageInterpolation = .high
        NSColor.clear.setFill(); NSRect(x: 0, y: 0, width: size, height: size).fill()
        let scale = min(CGFloat(size) / image.size.width, CGFloat(size) / image.size.height)
        let rect = NSRect(x: (CGFloat(size) - image.size.width * scale) / 2, y: (CGFloat(size) - image.size.height * scale) / 2, width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: rect); NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        return "data:image/png;base64," + data.base64EncodedString()
    }
    func fetchIcon(_ site: Website) {
        guard !testMode, site.iconSource != "custom", iconRequests[site.id]?.url != site.url else { return }
        let request = UUID(); iconRequests[site.id] = (request, site.url)
        iconLoader.load(site.url) { result in
            DispatchQueue.main.async {
                guard self.iconRequests[site.id]?.token == request else { return }
                self.iconRequests.removeValue(forKey: site.id)
                guard let index = self.library.sites.firstIndex(where: { $0.id == site.id }),
                      self.library.sites[index].url == site.url, self.library.sites[index].iconSource != "custom" else { return }
                var next = self.library
                // Keep an existing icon on timeout or an unavailable site; retry later.
                if let result {
                    next.sites[index].icon = result.dataURL
                    next.sites[index].iconSourcePixels = result.sourcePixels
                    next.sites[index].iconRevision = 2
                }
                next.sites[index].iconSource = "website"
                next.sites[index].iconCheckedAt = Date().timeIntervalSince1970
                do { try self.store.save(next); self.library = next; self.emit("update", ["state": self.state()]) } catch { }
            }
        }
    }

    func exportLibrary(_ responseID: String) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "搞门户-模块备份.json"; panel.allowedContentTypes = [.json]
        panel.beginSheetModal(for: window) { result in
            guard result == .OK, let url = panel.url else { self.reply(responseID, ["ok": false, "cancelled": true]); return }
            do {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(self.library).write(to: url, options: .atomic)
                self.reply(responseID, ["ok": true, "message": "已导出网站、排列和账号信息。密码留在本机钥匙串，未导出。"])
            } catch { self.reply(responseID, ["ok": false, "error": error.localizedDescription]) }
        }
    }

}

@main struct MenDao {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate(); app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) { }
    }
}
