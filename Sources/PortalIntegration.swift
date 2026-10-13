import AppKit
import WebKit
import Foundation
import Darwin
import UniformTypeIdentifiers

private struct PortalExchangeContext: Codable {
    let requestID: String
    let sourceBundleID: String
    let action: String
}

/// File-based, user-confirmed adapter. This never joins the browser socket and
/// never reads another application's database, browser profile or credentials.
final class PortalExchangeCoordinator {
    unowned let app: AppDelegate
    let directory: URL
    private var ledger: PortalRequestLedger?
    private var busy = false
    private var activeProposal: String?
    private var contexts: [String: PortalExchangeContext] = [:]
    private let worker = DispatchQueue(label: "cn.mendao.portal.exchange", qos: .userInitiated)

    init(app: AppDelegate) {
        self.app = app
        directory = app.store.directory.appendingPathComponent("Exchange", isDirectory: true)
        // An isolated UI test never creates records in the real data directory.
        if !app.testMode {
            do { ledger = try PortalRequestLedger(directory: directory.appendingPathComponent("Journal")) }
            catch { app.emit("toast", ["message": "交接记录不可读，跨 App 动作已停用；原记录保持不变。"] ) }
        }
    }

    static func validateRequest(_ manifest: GaoActionManifest) throws {
        guard manifest.kind == "request" else { throw PortalActionError.invalidParameters }
        try PortalActionPlanner.validateParameters(action: manifest.action,
            parameters: manifest.parameters.mapValues(\.foundationValue),
            itemCount: manifest.items.count, referenceCount: manifest.references.count)
    }

    func drain() {
        guard app.portalWebReady, !busy, !app.portalOpenQueue.isEmpty else { return }
        let url = app.portalOpenQueue.removeFirst()
        guard let ledger, app.store.persistent, !app.testMode else {
            app.showError("当前资料或交接记录不可用，已停止外部动作。请先检查原资料。")
            return
        }
        busy = true
        worker.async {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let received = try GaoActionPackage.receive(at: url,
                    stagingRoot: self.directory.appendingPathComponent("Incoming"),
                    targetBundleID: "cn.mendao.launcher", validateAction: Self.validateRequest)
                DispatchQueue.main.async { self.review(received, ledger: ledger) }
            } catch {
                DispatchQueue.main.async {
                    self.app.showError("交接包未通过安全检查或无法读取。请检查版本、有效期与权限，再使用“打开跨 App 交接包”选择原包。")
                    self.releaseQueue()
                }
            }
        }
    }

    private var runtime: PortalRuntime {
        PortalRuntime(installedBrowserIDs: Set(app.installedBrowsers().map(\.id)),
            connectedProfiles: Dictionary(grouping: app.activeClients(), by: \.browser).mapValues { Set($0.map(\.id)) })
    }

    private func review(_ received: GaoActionReceivedPackage, ledger: PortalRequestLedger) {
        let manifest = received.manifest
        let id = manifest.requestID.lowercased()
        do {
            let receipt = try ledger.receive(requestID: id, fingerprint: received.manifestSHA256, action: manifest.action)
            if case .repeated(let previous) = receipt {
                // A duplicate only displays its original state. It never runs the action again.
                try? FileManager.default.removeItem(at: received.packageURL)
                showOutcome(previous); releaseQueue(); return
            }
            let context = PortalExchangeContext(requestID: id, sourceBundleID: manifest.sourceBundleID, action: manifest.action)
            try saveContext(context); contexts[id] = context
            let plan = try PortalActionPlanner.plan(action: manifest.action,
                parameters: manifest.parameters.mapValues(\.foundationValue), library: app.library, runtime: runtime)
            try? FileManager.default.removeItem(at: received.packageURL)
            app.showWindow()
            let alert = NSAlert()
            alert.messageText = "复核跨 App 请求"
            alert.informativeText = "来源声明：\(manifest.sourceBundleID)\n该声明不证明发送者身份。\n\n" + summary(plan)
                + "\n\n只有确认后才执行；登录、验证码及二次验证仍由你完成。"
            alert.addButton(withTitle: confirmationTitle(plan)); alert.addButton(withTitle: "取消")
            alert.beginSheetModal(for: app.window) { response in
                do {
                    guard response == .alertFirstButtonReturn else {
                        _ = try ledger.cancel(requestID: id); self.releaseQueue(); return
                    }
                    let fresh = try PortalActionPlanner.plan(action: manifest.action,
                        parameters: manifest.parameters.mapValues(\.foundationValue), library: self.app.library, runtime: self.runtime)
                    guard fresh == plan else { throw PortalActionError(code: "input_changed", message: "复核期间网站或浏览器资料发生变化，请重新发起请求。") }
                    _ = try ledger.approve(requestID: id)
                    _ = try ledger.beginExecution(requestID: id)
                    self.execute(plan, requestID: id)
                } catch { self.fail(id, code: "request_changed") }
            }
        } catch {
            if ledger.record(requestID: id)?.state == .received {
                _ = try? ledger.fail(requestID: id, code: (error as? PortalActionError)?.code ?? "request_rejected")
            }
            app.showError((error as? PortalActionError)?.message ?? "交接请求未通过检查，未执行任何网站动作。")
            releaseQueue()
        }
    }

    private func execute(_ plan: PortalActionPlan, requestID: String) {
        switch plan {
        case .openSite(let site):
            app.launch(["siteID": site.siteID, "browser": site.browserID], responseID: nil, opened: { self.finish(requestID, $0) })
        case .openWorkspace(let workspace):
            let begin = {
                var outcomes: [PortalSiteOutcome] = []
                func next(_ index: Int) {
                    guard index < workspace.sites.count else { self.finish(requestID, .workspace(outcomes)); return }
                    let site = workspace.sites[index]
                    self.app.launch(["siteID": site.siteID, "browser": site.browserID], responseID: nil, opened: { outcome in
                        outcomes.append(PortalSiteOutcome(siteID: site.siteID, workflowState: outcome.workflowState, errorCode: outcome.errorCode))
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { next(index + 1) }
                    })
                }
                next(0)
            }
            if workspace.sites.contains(where: \.requiresAuthentication) {
                app.vault.authenticate("打开工作场景并填入所选账号") { ok, _ in
                    if ok { begin() } else { self.finish(requestID, .cancelled) }
                }
            } else { begin() }
        case .focusSearch(let query):
            applyWebFunction("portalApplySearch", arguments: [query]) { applied in
                self.finish(requestID, applied ? PortalActionOutcome(status: .completed, workflowState: .opened) : .failed("editor_busy"))
            }
        case .proposeSite(let proposal):
            activeProposal = requestID
            applyWebFunction("portalProposeSite", arguments: [proposal.url, proposal.title ?? "", requestID]) { applied in
                if applied { do { _ = try self.ledger?.markAwaitingUser(requestID: requestID) } catch { self.fail(requestID, code: "journal_write_failed") } }
                else { self.activeProposal = nil; self.finish(requestID, .failed("editor_busy")) }
            }
        case .prepareDownload(let urls):
            reviewDownload(urls) { outcome in self.finish(requestID, outcome) }
        }
    }

    private func applyWebFunction(_ function: String, arguments: [String], completion: @escaping (Bool) -> Void) {
        guard let data = try? JSONSerialization.data(withJSONObject: arguments), let json = String(data: data, encoding: .utf8) else { completion(false); return }
        app.web.evaluateJavaScript("window.\(function) && window.\(function)(...\(json))") { result, error in
            completion(error == nil && result as? Bool == true)
        }
    }

    func proposalSaved(_ id: String?, siteID: String) {
        guard let id, id == activeProposal, app.library.sites.contains(where: { $0.id == siteID }) else { return }
        activeProposal = nil
        finish(id, PortalActionOutcome(status: .completed, workflowState: .opened))
    }
    func proposalCancelled(_ id: String?) {
        guard let id, id == activeProposal else { return }
        activeProposal = nil; finish(id, .cancelled)
    }
    private func finish(_ id: String, _ outcome: PortalActionOutcome) {
        do { _ = try ledger?.finish(requestID: id, outcome: outcome) }
        catch { app.showError("交接结果无法保存。为防重复执行，原执行记录保留，不会自动重试。") }
        app.emit("toast", ["message": outcomeText(outcome) + " 可从“数据 → 查看交接结果”导出或发送。"])
        releaseQueue()
    }
    private func fail(_ id: String, code: String) {
        _ = try? ledger?.fail(requestID: id, code: code)
        activeProposal = nil; app.emit("toast", ["message": "请求未完成，请查看交接结果。"]); releaseQueue()
    }
    private func releaseQueue() { busy = false; DispatchQueue.main.async { self.drain() } }

    private func summary(_ plan: PortalActionPlan) -> String {
        switch plan {
        case .openSite(let launch):
            let site = app.library.sites.first { $0.id == launch.siteID }
            return "打开网站：\(site?.name ?? "已选网站")\n浏览器：\(Browser.catalog.first { $0.id == launch.browserID }?.name ?? launch.browserID)"
                + (launch.requiresAuthentication ? "\n此网站需要原有的本机认证与账号填充。" : "")
        case .openWorkspace(let group):
            return "打开场景：\(app.library.workspaces?.first { $0.id == group.workspaceID }?.name ?? "已选场景")\n"
                + group.sites.map { launch in (app.library.sites.first { $0.id == launch.siteID }?.name ?? "网站") + " · " + (Browser.catalog.first { $0.id == launch.browserID }?.name ?? launch.browserID) }.joined(separator: "\n")
        case .focusSearch(let query): return "打开搞门户搜索并填入：\n" + query
        case .proposeSite(let proposal): return "打开新增网站编辑器：\n" + (proposal.title ?? "") + "\n" + proposal.url + "\n仍需你检查浏览器设置并点击保存，不会直接修改网站库。"
        case .prepareDownload(let urls): return "复核本次选择的 \(urls.count) 个下载网址：\n" + urls.map(\.url).joined(separator: "\n") + "\n仅交接普通网址，不传密码、Cookie 或浏览器登录态。"
        }
    }
    private func confirmationTitle(_ plan: PortalActionPlan) -> String {
        switch plan { case .proposeSite: return "打开编辑器"; case .focusSearch: return "打开搜索"; case .prepareDownload: return "继续复核网址"; default: return "确认打开" }
    }
    private func outcomeText(_ outcome: PortalActionOutcome) -> String {
        switch outcome.status {
        case .completed: return "动作已完成（打开网页不代表登录成功）。"
        case .partial: return "场景部分完成，请检查逐站结果。"
        case .pending: return "已交接，等待用户或接收方继续处理。"
        case .cancelled: return "已取消。"
        case .unsupported: return "接收方不可用，未创建下载任务。"
        case .failed: return "动作未完成。错误代码：" + (outcome.errorCode ?? "operation_failed")
        }
    }

    private func saveContext(_ context: PortalExchangeContext) throws {
        let folder = directory.appendingPathComponent("Contexts")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = folder.appendingPathComponent(context.requestID + ".json")
        try JSONEncoder().encode(context).write(to: url, options: .atomic)
        guard chmod(url.path, 0o600) == 0 else { throw PortalActionError.invalidLedger }
    }
    private func context(for record: PortalRequestRecord) throws -> PortalExchangeContext {
        if let context = contexts[record.requestID] { return context }
        let url = directory.appendingPathComponent("Contexts").appendingPathComponent(record.requestID + ".json")
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1,
              info.st_size > 0, info.st_size < 4096, (info.st_mode & 0o077) == 0 else { throw PortalActionError.invalidLedger }
        let value = try JSONDecoder().decode(PortalExchangeContext.self, from: Data(contentsOf: url))
        guard value.requestID == record.requestID, value.action == record.action,
              value.sourceBundleID.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]{1,254}$", options: .regularExpression) != nil else { throw PortalActionError.invalidLedger }
        return value
    }

    func showResults() {
        guard let records = ledger?.allRecords, !records.isEmpty else { app.showError("还没有跨 App 交接记录。") ; return }
        guard app.window.attachedSheet == nil else { return }
        let alert = NSAlert(); alert.messageText = "交接结果"
        alert.informativeText = "重复请求只显示原结果。选中记录后可保存结果包，或由你明确发送给来源 App。"
        let choices = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 460, height: 28))
        for record in records { choices.addItem(withTitle: record.action + " · " + record.outcome.status.rawValue + " · " + record.requestID.prefix(8)) }
        alert.accessoryView = choices; alert.addButton(withTitle: "查看所选"); alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn { showOutcome(records[choices.indexOfSelectedItem]) }
    }
    private func showOutcome(_ record: PortalRequestRecord) {
        let alert = NSAlert(); alert.messageText = "交接结果 · " + record.action
        let details = (record.outcome.sites ?? []).map { $0.siteID + " · " + $0.workflowState.rawValue + ($0.errorCode.map { " · " + $0 } ?? "") }.joined(separator: "\n")
        alert.informativeText = outcomeText(record.outcome) + "\n状态：" + record.outcome.status.rawValue + " / " + record.outcome.workflowState.rawValue + "\n" + details
        alert.addButton(withTitle: "关闭"); alert.addButton(withTitle: "保存结果包"); alert.addButton(withTitle: "发送结果…")
        let response = alert.runModal()
        guard response != .alertFirstButtonReturn else { return }
        do {
            let context = try context(for: record)
            let result = try makeManifest(kind: "result", target: context.sourceBundleID, action: context.action,
                parameters: [:], replyTo: record.requestID, outcome: record.outcome)
            let url = try writeOutgoing(result)
            if response == .alertSecondButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                guard let target = compatibleApp(bundleID: context.sourceBundleID, requireCapability: false) else {
                    NSWorkspace.shared.activateFileViewerSelecting([url]); app.showError("未找到可接收交接包的来源 App。结果已保存在私有交接目录，可手动交给对方。"); return
                }
                let confirm = NSAlert(); confirm.messageText = "发送本次结果？"
                confirm.informativeText = "目标仅依据来源声明解析：\(context.sourceBundleID)。结果不含网站网址、账号、密码或浏览器资料。"
                confirm.addButton(withTitle: "发送结果"); confirm.addButton(withTitle: "取消")
                if confirm.runModal() == .alertFirstButtonReturn { openPackage(url, in: target) { _ in } }
            }
        } catch { app.showError("无法生成或发送结果包，原交接记录保留。") }
    }

    func prepareSelectedDownload(_ raw: String) {
        guard !busy else { app.emit("toast", ["message": "请先完成当前交接复核。"]); return }
        do {
            guard case .prepareDownload(let urls) = try PortalActionPlanner.plan(action: "portal.prepareDownload", parameters: ["urls": [raw]], library: app.library, runtime: runtime) else { return }
            busy = true; reviewDownload(urls) { outcome in self.app.emit("toast", ["message": self.outcomeText(outcome)]); self.releaseQueue() }
        } catch { app.showError("该网址不适合交接。只接受不含账号密码的 HTTP 或 HTTPS 网址。") }
    }
    private func reviewDownload(_ urls: [PortalDownloadURL], completion: @escaping (PortalActionOutcome) -> Void) {
        var selected = urls.map(\.url)
        if urls.contains(where: \.requiresPrivacyReview) {
            let alert = NSAlert(); alert.messageText = "网址包含查询参数或片段"
            alert.informativeText = "这些内容可能含私人标识或临时凭据。可以先去除；去除后某些链接可能不可用。不会读取 Cookie 或补充登录态。\n\n" + selected.joined(separator: "\n")
            alert.addButton(withTitle: "去除参数后继续"); alert.addButton(withTitle: "保留本次参数继续"); alert.addButton(withTitle: "取消")
            switch alert.runModal() {
            case .alertFirstButtonReturn: selected = urls.map(\.withoutQueryAndFragment)
            case .alertSecondButtonReturn: break
            default: completion(.cancelled); return
            }
        }
        guard let target = compatibleApp(bundleID: PortalDownloadProviderCapability.bundleID, requireCapability: true),
              let bundle = Bundle(url: target), let resource = bundle.url(forResource: "GaoCapabilities", withExtension: "json"),
              let data = try? Data(contentsOf: resource),
              let capability = try? PortalDownloadProviderCapability.validated(data: data, installedBundleID: bundle.bundleIdentifier ?? ""),
              capability.appVersion == bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            let alert = NSAlert(); alert.messageText = "搞下载尚不可用"
            alert.informativeText = "尚未找到实际安装且兼容的 downloads.prepare 提供方。不会创建下载任务；可复制本次已复核的网址。\n\n" + selected.joined(separator: "\n")
            alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "复制本次网址")
            if alert.runModal() == .alertSecondButtonReturn {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(selected.joined(separator: "\n"), forType: .string)
            }
            completion(PortalActionOutcome(status: .unsupported, workflowState: .unsupported, errorCode: "download_provider_unavailable")); return
        }
        let alert = NSAlert(); alert.messageText = "交给搞下载复核"
        alert.informativeText = "仅发送本次网址。目标会再次复核，不表示已经开始或完成下载。\n\n" + selected.joined(separator: "\n")
        let options = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 28))
        options.addItem(withTitle: "接收方可见默认")
        let media = capability.supportedMediaTypes.sorted(); media.forEach { options.addItem(withTitle: $0) }
        alert.accessoryView = options; alert.addButton(withTitle: "交给搞下载"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { completion(.cancelled); return }
        do {
            var parameters: [String: GaoJSONValue] = ["urls": .array(selected.map(GaoJSONValue.string))]
            if options.indexOfSelectedItem > 0 { parameters["mediaType"] = .string(media[options.indexOfSelectedItem - 1]) }
            let manifest = try makeManifest(kind: "request", target: PortalDownloadProviderCapability.bundleID, action: "downloads.prepare", parameters: parameters)
            let package = try writeOutgoing(manifest)
            openPackage(package, in: target) { ok in
                completion(ok ? PortalActionOutcome(status: .pending, workflowState: .accepted) : .failed("download_handoff_failed"))
            }
        } catch { completion(.failed("download_handoff_failed")) }
    }
    private func compatibleApp(bundleID: String, requireCapability: Bool) -> URL? {
        guard let found = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let url = found.resolvingSymlinksInPath().standardizedFileURL
        let allowed = [URL(fileURLWithPath: "/Applications", isDirectory: true), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        guard allowed.contains(where: { url.path.hasPrefix($0.path + "/") }), let bundle = Bundle(url: url), bundle.bundleIdentifier == bundleID else { return nil }
        let types = bundle.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]] ?? []
        guard types.contains(where: { ($0["LSItemContentTypes"] as? [String])?.contains("com.gaoseries.action-package") == true }) else { return nil }
        if requireCapability, bundle.url(forResource: "GaoCapabilities", withExtension: "json") == nil { return nil }
        return url
    }
    private func openPackage(_ package: URL, in target: URL, completion: @escaping (Bool) -> Void) {
        NSWorkspace.shared.open([package], withApplicationAt: target, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            DispatchQueue.main.async {
                self.app.emit("toast", ["message": error == nil ? "已交给目标 App。仍需在对方复核，打开成功不代表业务完成。" : "目标 App 未能接收交接包，私有副本已保留。"])
                completion(error == nil)
            }
        }
    }
    private func makeManifest(kind: String, target: String, action: String, parameters: [String: GaoJSONValue], replyTo: String? = nil, outcome: PortalActionOutcome? = nil) throws -> GaoActionManifest {
        let now = Date()
        var manifest = GaoActionManifest(kind: kind, requestID: UUID().uuidString, sourceBundleID: "cn.mendao.launcher", targetBundleID: target,
            action: action, createdAt: GaoActionPackage.iso8601(now), expiresAt: GaoActionPackage.iso8601(now.addingTimeInterval(120)),
            nonce: try GaoActionPackage.randomNonce(), items: [], references: [], parameters: parameters)
        if let outcome {
            manifest.inReplyTo = replyTo; manifest.status = outcome.status.rawValue; manifest.errorCode = outcome.errorCode
            manifest.provenance = ["workflowState": .string(outcome.workflowState.rawValue)]
            if let sites = outcome.sites {
                manifest.provenance?["sites"] = .array(sites.map { .object(["siteID": .string($0.siteID), "workflowState": .string($0.workflowState.rawValue), "errorCode": $0.errorCode.map(GaoJSONValue.string) ?? .null]) })
            }
        }
        return manifest
    }
    private func writeOutgoing(_ manifest: GaoActionManifest) throws -> URL {
        let url = directory.appendingPathComponent("Outgoing").appendingPathComponent(manifest.requestID + ".gaoaction", isDirectory: true)
        return try GaoActionPackage.write(manifest: manifest, to: url, validateAction: { value in
            if value.kind == "result" { guard value.parameters.isEmpty, value.items.isEmpty, value.references.isEmpty else { throw PortalActionError.invalidParameters }; return }
            guard value.action == "downloads.prepare", Set(value.parameters.keys).isSubset(of: ["urls", "mediaType"]),
                  value.items.isEmpty, value.references.isEmpty else { throw PortalActionError.invalidParameters }
            var parameters = value.parameters.mapValues(\.foundationValue); parameters.removeValue(forKey: "mediaType")
            try PortalActionPlanner.validateParameters(action: "portal.prepareDownload", parameters: parameters)
            if let type = value.parameters["mediaType"]?.string, !["file", "video", "audio", "image", "subtitle"].contains(type) { throw PortalActionError.invalidParameters }
        })
    }

    func exportCatalog(workspaces: Bool) {
        guard app.window.attachedSheet == nil else { return }
        let records: [(String, String)] = workspaces ? (app.library.workspaces ?? []).map { ($0.id, $0.name) } : app.library.sites.map { ($0.id, $0.name) }
        guard !records.isEmpty else { app.showError("没有可供选择的目录项目。") ; return }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 440, height: 260)); scroll.hasVerticalScroller = true
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: CGFloat(records.count) * 28))
        var checks: [NSButton] = []
        for (index, record) in records.enumerated() {
            let check = NSButton(checkboxWithTitle: record.1, target: nil, action: nil)
            check.frame = NSRect(x: 4, y: CGFloat(records.count - index - 1) * 28, width: 406, height: 26)
            check.state = .off; checks.append(check); document.addSubview(check)
        }
        scroll.documentView = document
        let alert = NSAlert(); alert.messageText = workspaces ? "选择允许导出的场景" : "选择允许导出的网站"
        alert.informativeText = "默认不选择任何项目。只导出所选 ID 和显示名称，不含网址、账号、密码、历史、浏览器资料或图标。文件由你自行交给调用方。"
        alert.accessoryView = scroll; alert.addButton(withTitle: "导出所选…"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let selected = records.enumerated().filter { checks[$0.offset].state == .on }.map(\.element)
        guard !selected.isEmpty else { app.showError("未选择项目，未导出任何网站或场景信息。") ; return }
        do {
            let data: Data
            if workspaces {
                data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "workspaces": selected.map { ["workspaceID": $0.0, "displayName": $0.1] }], options: [.prettyPrinted, .sortedKeys])
            } else { data = try JSONEncoder().encode(UserExposedSiteCatalog(library: app.library, authorizedSiteIDs: Set(selected.map(\.0)))) }
            let panel = NSSavePanel(); panel.nameFieldStringValue = workspaces ? "授权场景目录.json" : "授权网站目录.json"
            panel.beginSheetModal(for: app.window) { response in
                guard response == .OK, let url = panel.url else { return }
                do { try data.write(to: url, options: .atomic); guard chmod(url.path, 0o600) == 0 else { throw PortalActionError.invalidLedger } }
                catch { self.app.showError("导出失败，未公开任何额外目录。") }
            }
        } catch { app.showError("无法生成所选目录。") }
    }
}

extension AppDelegate {
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        guard !urls.isEmpty, urls.count <= 16, portalOpenQueue.count + urls.count <= 16,
              urls.allSatisfy({ $0.pathExtension.lowercased() == "gaoaction" }) else {
            sender.reply(toOpenOrPrint: .failure); return
        }
        portalOpenQueue.append(contentsOf: urls); sender.reply(toOpenOrPrint: .success)
        portalCoordinator?.drain()
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        portalWebReady = true; portalCoordinator?.drain()
    }
    @objc func openPortalPackage() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(importedAs: "com.gaoseries.action-package", conformingTo: .package)]
        panel.beginSheetModal(for: window) { response in
            if response == .OK, let url = panel.url { self.portalOpenQueue.append(url); self.portalCoordinator?.drain() }
        }
    }
    @objc func showPortalResults() { portalCoordinator?.showResults() }
    @objc func exportPortalSiteCatalog() { portalCoordinator?.exportCatalog(workspaces: false) }
    @objc func exportPortalWorkspaceCatalog() { portalCoordinator?.exportCatalog(workspaces: true) }
}
