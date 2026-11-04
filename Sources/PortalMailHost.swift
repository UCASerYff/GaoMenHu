import AppKit
import Foundation
import SwiftUI

/// Mail remains in native views. Only the command to open this module crosses
/// the website launcher's bridge; mailbox state and content never do.
@MainActor
final class PortalMailWindowController: NSWindowController, NSWindowDelegate {
    let store: MailStore
    let floating: MailFloatingController
    private var settingsWindow: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var themeObserver: NSObjectProtocol?

    init(store: MailStore) {
        self.store = store
        floating = MailFloatingController(store: store)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1360, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier("GaoMenHu.Mail.Main")
        window.title = "搞门户 · 邮件"
        window.minSize = NSSize(width: 1080, height: 720)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: PortalMailRootView(store: store,
            showFloating: { [weak self] in self?.floating.show() },
            openSettings: { [weak self] in self?.presentSettings() }))
        window.center()
        floating.onOpenInbox = { [weak self] accountID, messageID in
            self?.store.openCachedInbox(accountID: accountID, messageID: messageID)
            self?.present()
        }
        floating.onCompose = { [weak self] accountID in
            self?.store.newDraft(accountID: accountID)
            self?.present()
        }
        floating.onOpenSettings = { [weak self] in self?.presentSettings() }
        observers.append(NotificationCenter.default.addObserver(forName: .mailOpenSettings, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.presentSettings() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .mailAppearanceChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyAppearance() }
        })
        themeObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.applyAppearance()
                    NotificationCenter.default.post(name: .mailAppearanceChanged, object: nil)
                }
            }
        applyAppearance()
        // These keys belong only to this host. Migration sets visibility and
        // previews false; later explicit choices in this host may be restored.
        if store.storage.readFailure == nil { floating.restoreIfNeeded() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        if let themeObserver { DistributedNotificationCenter.default().removeObserver(themeObserver) }
    }

    func present() {
        showWindow(nil)
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
        window?.attachedSheet?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    var ownsKeyWindow: Bool {
        guard var key = NSApp.keyWindow else { return false }
        while let parent = key.sheetParent { key = parent }
        return key === window || key === settingsWindow
    }

    func presentSettings() {
        if settingsWindow == nil {
            let settings = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 740),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            settings.identifier = NSUserInterfaceItemIdentifier("GaoMenHu.Mail.Settings")
            settings.title = "邮件设置"
            settings.isReleasedWhenClosed = false
            settings.delegate = self
            settings.contentView = NSHostingView(rootView: MailSettingsView(store: store, floating: floating,
                onAppearanceChange: { [weak self] _ in
                    self?.applyAppearance()
                    NotificationCenter.default.post(name: .mailAppearanceChanged, object: nil)
                }))
            settings.center()
            settingsWindow = settings
        }
        applyAppearance()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func applyAppearance() {
        if let window { MailAppearance.current.apply(to: window) }
        if let settingsWindow { MailAppearance.current.apply(to: settingsWindow) }
    }

    /// A failed draft write or an in-flight SMTP submission must keep the app
    /// alive, so the user can retain the draft or learn the submission result.
    func retainDraftBeforeClosing() -> Bool {
        if store.sending {
            let alert = NSAlert()
            alert.messageText = "邮件正在发送"
            alert.informativeText = "请等待发送结果后关闭或退出，避免无法确认服务商是否已接受邮件。"
            alert.addButton(withTitle: "继续等待")
            alert.runModal()
            return false
        }
        if let draft = store.compose {
            do { try store.saveDraft(draft) }
            catch {
                let alert = NSAlert()
                alert.messageText = "草稿尚未保存"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "返回继续编辑")
                alert.runModal()
                present()
                return false
            }
        }
        return true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === window, !retainDraftBeforeClosing() { return false }
        sender.orderOut(nil)
        return false
    }
}

extension AppDelegate {
    @MainActor private func embeddedMail() -> PortalMailWindowController {
        if let mailWindowController { return mailWindowController }
        let destination = store.directory.appendingPathComponent("MailCenter", isDirectory: true)
        let legacy = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/GaoSeries/GaoYouJian", isDirectory: true)
        let issue: String?
        if testMode || !store.isWritable {
            issue = "当前网站资料不可写或处于隔离测试模式，邮件模块不会初始化或读取真实邮箱资料。"
        } else {
            switch PortalMailUIOnlyBootstrap.readiness(destinationRootURL: destination, legacyRootURL: legacy,
                targetDefaults: UserDefaults.standard) {
            case .ready: issue = nil
            case .recoveryRequired(let detail): issue = detail
            case .absent: issue = legacyMailIssue(destination: destination, legacy: legacy)
            }
        }
        let controller = PortalMailWindowController(store: MailStore(root: destination, blockedBecause: issue))
        mailWindowController = controller
        return controller
    }

    @MainActor private func legacyMailIssue(destination: URL, legacy: URL) -> String? {
        do {
            let preferences = UserDefaults.standard.persistentDomain(forName: "com.gaoseries.GaoYouJian")
            let preferenceFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/com.gaoseries.GaoYouJian.plist")
            let bytes = try PortalLegacyPreferences.read(domain: preferences, file: preferenceFile)
            switch PortalMailMigration.readiness(destinationRootURL: destination, legacyRootURL: legacy,
                sourcePreferences: bytes, targetDefaults: UserDefaults.standard) {
            case .newInstallation, .ready: return nil
            case .requiresMigration:
                return "检测到原邮件资料。请先完成已核验的资料迁入；没有创建空库、连接邮箱或启动旧应用。"
            case .recoveryRequired(let detail): return detail
            }
        } catch {
            // A committed full migration has independent authority. Invalid
            // legacy preferences cannot authorize a new empty library.
            if case .ready = PortalMailMigration.readiness(destinationRootURL: destination, legacyRootURL: legacy,
                sourcePreferences: Data(), targetDefaults: UserDefaults.standard) { return nil }
            return "原邮件偏好无法读取。已停止初始化，请保留原邮件资料及完整备份。"
        }
    }

    @objc @MainActor func openMail() { embeddedMail().present() }
    @objc @MainActor func openMailSettings() { embeddedMail().presentSettings() }

    @MainActor func restoreMailFloatingIfRequested() {
        guard !testMode, store.isWritable,
              UserDefaults.standard.bool(forKey: "gaomenhu.mail.floating.visible") else { return }
        // Only an explicit choice saved by the new host enables this path.
        // It restores local counts/previews, never connection authorization.
        _ = embeddedMail()
    }

    @MainActor func setupMailMenu(in bar: NSMenu) {
        let root = NSMenuItem()
        bar.addItem(root)
        let menu = NSMenu(title: "邮件")
        root.submenu = menu
        for (title, action, key) in [
            ("打开邮件窗口", #selector(openMail), "0"),
            ("写邮件", #selector(mailCompose), ""),
            ("同步已授权邮箱", #selector(mailSynchronize), "r"),
            ("邮箱别名助手…", #selector(mailAliasHelper), ""),
            ("显示或隐藏邮件悬浮窗", #selector(toggleMailFloating), ""),
            ("邮件设置…", #selector(openMailSettings), "")
        ] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.target = self
        }
        menu.addItem(.separator())
        for (title, action) in [
            ("导出邮件资料备份…", #selector(mailExportBackup)),
            ("恢复邮件资料备份…", #selector(mailRestoreBackup)),
            ("导入平台 CSV…", #selector(mailImportPlatforms)),
            ("导出平台 CSV…", #selector(mailExportPlatforms))
        ] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
        }
    }

    @objc @MainActor func mailCompose() { let controller = embeddedMail(); controller.store.newDraft(); controller.present() }
    @objc @MainActor func mailSynchronize() {
        let controller = embeddedMail()
        controller.present()
        Task { await controller.store.syncAll() }
    }
    @objc @MainActor func mailAliasHelper() {
        embeddedMail().present()
        NotificationCenter.default.post(name: .mailOpenAliasHelper, object: nil)
    }
    @objc @MainActor func toggleMailFloating() { embeddedMail().floating.toggle() }
    @objc @MainActor func mailExportBackup() { let controller = embeddedMail(); controller.present(); controller.store.exportBackup() }
    @objc @MainActor func mailRestoreBackup() { let controller = embeddedMail(); controller.present(); controller.store.restoreBackup() }
    @objc @MainActor func mailImportPlatforms() { let controller = embeddedMail(); controller.present(); controller.store.importCSV() }
    @objc @MainActor func mailExportPlatforms() { let controller = embeddedMail(); controller.present(); controller.store.exportCSV() }
}
