import AppKit
import SwiftUI
import Foundation

/// Downloads share the existing application identity, but keep their own
/// durable queue and request journal separate from the website account library.
@MainActor
final class PortalDownloadWindowController: NSWindowController, NSWindowDelegate {
    let coordinator: PortalDownloadCoordinator
    init(coordinator: PortalDownloadCoordinator) {
        self.coordinator = coordinator
        let view = DownloadMainView(coordinator: coordinator, manager: coordinator.downloads, exchange: coordinator.exchange)
        let content = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "搞门户 · 下载中心"
        window.minSize = NSSize(width: 1000, height: 650)
        window.contentView = content; window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.center()
        coordinator.onShowWindow = { [weak self] in self?.present() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    func present() { showWindow(nil); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        coordinator.cancelComposer()
        sender.orderOut(nil)
        return false
    }
}

extension AppDelegate {
    @MainActor
    private func embeddedDownloads() -> PortalDownloadWindowController {
        if let downloadWindowController { return downloadWindowController }
        let issue: String?
        let destination = store.directory.appendingPathComponent("DownloadCenter", isDirectory: true)
        let legacy = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/GaoSeries/GaoXiaZai", isDirectory: true)
        if testMode || !store.isWritable {
            issue = "当前网站资料不可写或处于隔离测试模式，下载中心不会初始化或读取真实队列。"
        } else {
            switch PortalDownloadHistoryIsolation.readiness(destinationRootURL: destination, targetDefaults: UserDefaults.standard) {
            case .some(.ready): issue = nil
            case .some(.recoveryRequired(let detail)): issue = detail
            case .some:
                issue = "下载历史隔离事务尚未通过完整核对；保留现有资料，不创建空队列。"
            case .none: issue = legacyDownloadIssue(destination: destination, legacy: legacy)
            }
        }
        let manager: DownloadManager
        let exchange: DownloadGaoExchange
        if let issue {
            manager = DownloadManager(blockedBecause: issue)
            exchange = DownloadGaoExchange(blockedBecause: issue)
        } else {
            manager = DownloadManager(rootURL: destination)
            exchange = manager.recoveryIssue.map { DownloadGaoExchange(blockedBecause: $0) }
                ?? DownloadGaoExchange(rootURL: destination.appendingPathComponent("Exchange", isDirectory: true))
        }
        let coordinator = PortalDownloadCoordinator(downloads: manager, exchange: exchange)
        let controller = PortalDownloadWindowController(coordinator: coordinator)
        downloadWindowController = controller
        return controller
    }

    @MainActor private func legacyDownloadIssue(destination: URL, legacy: URL) -> String? {
        do {
            let preferenceFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/com.gaoseries.GaoXiaZai.plist")
            let bytes = try PortalLegacyPreferences.read(
                domain: UserDefaults.standard.persistentDomain(forName: "com.gaoseries.GaoXiaZai"), file: preferenceFile)
            guard let oldPreferences = try PropertyListSerialization.propertyList(from: bytes, options: [], format: nil) as? [String: Any] else {
                throw PortalLegacyPreferences.ReadError.unreadable
            }
            let evidenceValues = oldPreferences.filter { $0.key.hasPrefix("GaoXiaZai.ExchangeEvidence.") }
            let sourcePreferences = evidenceValues.compactMapValues { $0 as? Data }
            guard sourcePreferences.count == evidenceValues.count else { throw PortalLegacyPreferences.ReadError.unreadable }
            switch PortalDownloadMigration.readiness(destinationRootURL: destination, legacyRootURL: legacy,
                sourcePreferences: sourcePreferences, targetDefaults: UserDefaults.standard) {
            case .newInstallation:
                return oldPreferences.isEmpty ? nil : "旧下载目录与初始化记录缺失，但原偏好仍存在；未创建空队列，请先核验完整来源。"
            case .ready: return nil
            case .requiresMigration:
                return "检测到原下载资料。请先完成经核验的下载资料迁入，再在这里管理队列；没有创建空队列或启动旧应用。"
            case .recoveryRequired(let detail): return detail
            }
        } catch {
            let receipt = destination.appendingPathComponent("MigrationEvidence/receipt.json")
            if FileManager.default.fileExists(atPath: receipt.path),
               case .ready = PortalDownloadMigration.readiness(destinationRootURL: destination, legacyRootURL: legacy,
                   sourcePreferences: [:], targetDefaults: UserDefaults.standard) { return nil }
            return "原下载偏好或初始化依据不可读，已停止初始化；请保留原资料并核验完整迁移备份。"
        }
    }

    @objc @MainActor func openDownloads() { embeddedDownloads().present() }

    @MainActor func prepareEmbeddedDownload(urls: [String], parentRequestID: String? = nil,
                                            completion: @escaping (PortalActionOutcome) -> Void) {
        let controller = embeddedDownloads()
        controller.present()
        controller.coordinator.prepareInternal(urls: urls, parentRequestID: parentRequestID, completion: completion)
    }

    @MainActor func receiveEmbeddedDownloadPackage(_ url: URL) {
        let controller = embeddedDownloads()
        controller.present()
        controller.coordinator.receive([url])
    }
}
