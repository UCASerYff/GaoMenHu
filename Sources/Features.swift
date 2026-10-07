import AppKit
import Foundation

struct BrowserChoice: Equatable {
    var allowed: [String]
    var standard: String
}

struct OrganizationState: Equatable {
    var tiles: [Tile]
    var browsers: [String: BrowserChoice]
    init(_ library: Library) {
        tiles = library.tiles
        browsers = Dictionary(uniqueKeysWithValues: library.sites.map {
            ($0.id, BrowserChoice(allowed: $0.allowedBrowsers, standard: $0.defaultBrowser))
        })
    }
}

struct OrganizationEdit {
    var before: OrganizationState
    var after: OrganizationState
}

struct PendingLibraryChange {
    var library: Library
    var baseline: Library
    var reason: String
    var kind: String
    var expires: Date
}

extension AppDelegate {
    func reportLaunch(_ id: String, message: String) {
        guard launchFeedback[id] != message else { return }
        launchFeedback[id] = message
        emit("toast", ["message": message])
    }

    func handleFeatureAction(_ action: String, data: [String: Any], responseID: String) throws -> Bool {
        switch action {
        case "preferences":
            guard let density = data["layoutDensity"] as? String, ["compact", "comfortable"].contains(density),
                  let size = data["iconSize"] as? Int, [60, 76, 92].contains(size) else { throw AppError.message("外观选项无效。") }
            var next = library; next.layoutDensity = density; next.iconSize = size
            try store.save(next); library = next
            reply(responseID, ["ok": true, "state": state()])
        case "batch":
            try batch(data); reply(responseID, ["ok": true, "state": state(), "message": "整理完成，可使用 ⌘Z 撤销。"])
        case "undo":
            try undoOrganization(); reply(responseID, ["ok": true, "state": state(), "message": "已撤销上一次整理。"])
        case "previewBackup": previewBackup(data, responseID: responseID)
        case "applyBackup", "applyBookmarks":
            guard let token = data["token"] as? String else { throw AppError.message("请先预览。") }
            try applyLibraryChange(token: token, kind: action == "applyBookmarks" ? "bookmarks" : "backup")
            reply(responseID, ["ok": true, "state": state(), "message": "已完成，操作前的数据已保存到本地快照。"])
        case "snapshots":
            let formatter = ISO8601DateFormatter()
            let snapshots = try store.snapshots().map { snapshot -> [String: Any] in
                ["id": snapshot.id, "date": formatter.string(from: Date(timeIntervalSince1970: snapshot.createdAt)),
                 "label": snapshot.reason, "sites": snapshot.siteCount, "folders": snapshot.folderCount]
            }
            reply(responseID, ["ok": true, "snapshots": snapshots])
        case "previewSnapshot":
            guard let id = data["id"] as? String else { throw AppError.message("请选择快照。") }
            let imported = try store.loadSnapshot(id: id)
            let next = try LibraryOperations.restore(imported, into: library)
            reply(responseID, try prepareLibraryChange(next, kind: "backup", reason: "恢复本地快照前", sites: imported.sites.count,
                folders: imported.tiles.filter { $0.kind == "folder" }.count,
                message: "恢复快照中的网站和排列；当前额外网站保留在已移除入口中。不会删除钥匙串密码。"))
        case "bookmarkSources":
            let sources = testMode ? [] : BookmarksImporter().sources()
            reply(responseID, ["ok": true, "sources": sources.map { ["id": $0.id, "browser": $0.browserID, "label": $0.name] }])
        case "previewBookmarks":
            guard !testMode else { throw AppError.message("测试程序不读取真实浏览器收藏。") }
            guard let sourceID = data["sourceID"] as? String else { throw AppError.message("请选择浏览器资料。") }
            let preview = try BookmarksImporter().preview(sourceID: sourceID, current: library)
            guard let bar = preview.roots.first(where: { $0.id == "bookmark_bar" }) else { throw AppError.message("这个浏览器资料没有收藏栏。") }
            let next = try BookmarksImporter().importBookmarks(sourceID: sourceID, rootIDs: ["bookmark_bar"], into: library)
            reply(responseID, try prepareLibraryChange(next, kind: "bookmarks", reason: "导入浏览器收藏前", sites: bar.siteCount, folders: bar.folderCount,
                duplicates: bar.duplicateCount, message: "导入收藏栏，保留文件夹。多层文件夹显示为路径名称；重复网址保留搞门户现有账号和浏览器设置。"))
        case "saveWorkspace":
            try saveWorkspace(data); reply(responseID, ["ok": true, "state": state(), "message": "工作场景已保存。"])
        case "deleteWorkspace":
            guard let id = data["id"] as? String, library.workspaces?.contains(where: { $0.id == id }) == true else { throw AppError.message("场景不存在。") }
            var next = library; next.workspaces?.removeAll { $0.id == id }
            _ = try store.checkpoint(library, reason: "删除工作场景前")
            try store.save(next); library = next; reply(responseID, ["ok": true, "state": state()])
        case "launchWorkspace": launchWorkspace(data, responseID: responseID)
        case "refreshIcon":
            guard let id = data["siteID"] as? String, let site = library.sites.first(where: { $0.id == id }) else { throw AppError.message("网站不存在。") }
            guard site.iconSource != "custom" else { throw AppError.message("这个图标是手动设置的，请在编辑中恢复网站图标后重试。") }
            iconLoader.clearCache(); fetchIcon(site)
            reply(responseID, ["ok": true, "message": "正在获取这个网站的清晰图标。"])
        case "reconnectBrowser":
            guard let browserID = data["browser"] as? String, ["chrome", "edge"].contains(browserID),
                  let browser = Browser.catalog.first(where: { $0.id == browserID }) else { throw AppError.message("浏览器无效。") }
            if !testMode {
                try registerNativeHosts()
                guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleID) else { throw AppError.message("浏览器未安装。") }
                NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
            }
            reply(responseID, ["ok": true, "state": state(), "message": "已检查本机连接并唤起浏览器。助手会自动重连，也可在助手弹窗点“重新连接”立即重试。"])
        default: return false
        }
        return true
    }

    func searchKeys() -> [String: String] {
        var result: [String: String] = [:]
        for site in library.sites {
            let source = site.name + " " + (site.aliases ?? "")
            if let cached = searchKeyCache[site.id], cached.0 == source {
                result[site.id] = cached.1; continue
            }
            let romanized = (source.applyingTransform(.toLatin, reverse: false) ?? source)
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "zh_CN"))
            let words = romanized.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            let key = romanized + " " + words.joined() + " " + String(words.compactMap(\.first))
            searchKeyCache[site.id] = (source, key); result[site.id] = key
        }
        return result
    }

    func commitOrganization(_ next: Library, reason: String) throws {
        _ = try next.validated()
        let before = OrganizationState(library), after = OrganizationState(next)
        guard before != after else { return }
        _ = try store.checkpoint(library, reason: reason)
        try store.save(next)
        organizationHistory.append(OrganizationEdit(before: before, after: after))
        if organizationHistory.count > 30 { organizationHistory.removeFirst() }
        library = next
    }

    func undoOrganization() throws {
        guard let edit = organizationHistory.last else { throw AppError.message("没有可以撤销的整理操作。") }
        guard OrganizationState(library) == edit.after else {
            organizationHistory.removeAll()
            throw AppError.message("网站数据已发生其他变化，请从本地快照恢复原排列。")
        }
        var next = library; next.tiles = edit.before.tiles
        for index in next.sites.indices {
            if let choice = edit.before.browsers[next.sites[index].id] {
                next.sites[index].allowedBrowsers = choice.allowed
                next.sites[index].defaultBrowser = choice.standard
            }
        }
        try store.save(next); library = next; organizationHistory.removeLast()
        launches.removeAll()
    }

    func batch(_ data: [String: Any]) throws {
        guard let requested = data["siteIDs"] as? [String], !requested.isEmpty,
              let operation = data["operation"] as? String else { throw AppError.message("请先选择网站。") }
        let ids = Set(requested)
        guard ids.count == requested.count, ids.isSubset(of: visibleSiteIDs(library.tiles)) else { throw AppError.message("选中的网站已变化，请重新选择。") }
        var next = library
        switch operation {
        case "remove":
            for id in requested { next.tiles = removeFromTiles(id, next.tiles) }
        case "browser":
            guard let browser = data["browser"] as? String, Browser.catalog.contains(where: { $0.id == browser }) else { throw AppError.message("请选择有效浏览器。") }
            guard next.sites.filter({ ids.contains($0.id) }).allSatisfy({ $0.allowedBrowsers.contains(browser) }) else {
                throw AppError.message("这个浏览器未被所有选中网站允许，请先分别修改网站的允许浏览器。")
            }
            for index in next.sites.indices where ids.contains(next.sites[index].id) {
                next.sites[index].defaultBrowser = browser
            }
        case "move":
            let folderID = (data["folderID"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let folderName = (data["folderName"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var target: Tile?
            if let folderID {
                guard let found = library.tiles.first(where: { $0.kind == "folder" && $0.id == folderID }) else { throw AppError.message("目标文件夹不存在。") }
                target = found
            } else if !folderName.isEmpty {
                guard folderName.count <= 60 else { throw AppError.message("文件夹名称最多 60 个字。") }
                target = Tile(id: UUID().uuidString, kind: "folder", name: folderName, children: [])
            }
            let ordered = library.tiles.flatMap { $0.kind == "folder" ? ($0.children ?? []) : [$0.id] }.filter { ids.contains($0) }
            for id in requested { next.tiles = removeFromTiles(id, next.tiles) }
            if var target {
                target.children = (target.children ?? []).filter { !ids.contains($0) } + ordered
                if let index = next.tiles.firstIndex(where: { $0.id == target.id }) { next.tiles[index] = target }
                else { next.tiles.append(target) }
            } else {
                next.tiles += ordered.map { Tile(id: $0, kind: "site", name: nil, children: nil) }
            }
        default: throw AppError.message("不支持这个批量操作。")
        }
        try commitOrganization(next, reason: "批量整理前")
        launches = launches.filter { !ids.contains($0.value.siteID) }
    }

    func prepareLibraryChange(_ next: Library, kind: String, reason: String, sites: Int, folders: Int, duplicates: Int = 0, message: String) throws -> [String: Any] {
        _ = try next.validated()
        pendingLibraryChanges = pendingLibraryChanges.filter { $0.value.expires > Date() }
        if pendingLibraryChanges.count >= 8 { pendingLibraryChanges.removeAll() }
        let token = UUID().uuidString
        pendingLibraryChanges[token] = PendingLibraryChange(library: next, baseline: library, reason: reason, kind: kind, expires: Date().addingTimeInterval(600))
        return ["ok": true, "token": token, "preview": ["sites": sites, "folders": folders, "duplicates": duplicates, "message": message,
            "folderNames": Array(next.tiles.filter { $0.kind == "folder" }.compactMap(\.name).prefix(30))]]
    }

    func applyLibraryChange(token: String, kind: String) throws {
        guard let pending = pendingLibraryChanges[token], pending.kind == kind, pending.expires > Date() else { throw AppError.message("预览已过期，请重新选择。") }
        guard library == pending.baseline else { throw AppError.message("预览期间网站发生变化，请重新预览后导入。") }
        _ = try store.checkpoint(library, reason: pending.reason)
        try store.save(pending.library); library = pending.library
        applyAppearance(); settingsModel?.refresh()
        pendingLibraryChanges.removeAll(); organizationHistory.removeAll(); launches.removeAll()
        for site in library.sites where site.icon == nil { fetchIcon(site) }
    }

    func previewBackup(_ data: [String: Any], responseID: String) {
        let mode = data["mode"] as? String == "restore" ? "restore" : "merge"
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        panel.message = mode == "restore" ? "预览并恢复网站、文件夹和排列；操作前会保存本地快照。" : "预览合并网站和文件夹，重复网址保留现有设置。"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { self.reply(responseID, ["ok": false, "cancelled": true]); return }
            do {
                let bytes = try Data(contentsOf: url); guard bytes.count < 20_000_000 else { throw AppError.message("备份文件过大。") }
                let imported = try JSONDecoder().decode(Library.self, from: bytes).validated()
                let next = try mode == "restore" ? LibraryOperations.restore(imported, into: self.library) : LibraryOperations.merge(imported, into: self.library)
                let added = next.sites.count - self.library.sites.count
                let message = mode == "restore" ? "恢复备份中的文件夹和排列。当前额外网站会保留在已移除入口中，现存账号密码不会删除；外来账号需重新填写密码。" : "新增网站按原文件夹加入，重复网址保留现有配置；外来账号需重新填写密码。"
                self.reply(responseID, try self.prepareLibraryChange(next, kind: "backup", reason: "恢复或合并备份前", sites: imported.sites.count, folders: imported.tiles.filter { $0.kind == "folder" }.count, duplicates: max(0, imported.sites.count - added), message: message))
            } catch { self.reply(responseID, ["ok": false, "error": error.localizedDescription]) }
        }
    }

    func saveWorkspace(_ data: [String: Any]) throws {
        guard let object = data["workspace"], let bytes = try? JSONSerialization.data(withJSONObject: object) else { throw AppError.message("场景内容无效。") }
        var workspace = try JSONDecoder().decode(Workspace.self, from: bytes)
        workspace.name = workspace.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if workspace.id.isEmpty { workspace.id = UUID().uuidString }
        guard !workspace.name.isEmpty, workspace.name.count <= 60, !workspace.siteIDs.isEmpty,
              workspace.siteIDs.count <= 20, Set(workspace.siteIDs).count == workspace.siteIDs.count,
              Set(workspace.siteIDs).isSubset(of: Set(library.sites.map(\.id))) else { throw AppError.message("场景需要名称和 1–20 个有效网站。") }
        var next = library, groups = library.workspaces ?? []
        if let index = groups.firstIndex(where: { $0.id == workspace.id }) { groups[index] = workspace } else { groups.append(workspace) }
        next.workspaces = groups
        _ = try store.checkpoint(library, reason: "编辑工作场景前")
        try store.save(next); library = next
    }

    func launchWorkspace(_ data: [String: Any], responseID: String) {
        guard let id = data["id"] as? String, let group = library.workspaces?.first(where: { $0.id == id }) else { reply(responseID, ["ok": false, "error": "场景不存在。"]); return }
        let sites = group.siteIDs.compactMap { id in library.sites.first(where: { $0.id == id }) }
        guard !sites.isEmpty, sites.count <= 20, sites.count == group.siteIDs.count else { reply(responseID, ["ok": false, "error": "场景内的网站已变化，请先编辑场景。"]); return }
        do { for site in sites { try validateLaunch(site, browserID: site.defaultBrowser) } }
        catch { reply(responseID, ["ok": false, "error": error.localizedDescription]); return }
        let perform = {
            if self.testMode { self.reply(responseID, ["ok": true, "message": "测试场景已验证，共 \(sites.count) 个网站。"]); return }
            for (index, site) in sites.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.3) {
                    self.launch(["siteID": site.id], responseID: "workspace-" + UUID().uuidString)
                }
            }
            self.reply(responseID, ["ok": true, "message": "正在打开「\(group.name)」的 \(sites.count) 个网站。"])
        }
        let needsPassword = sites.contains { site in site.accounts.contains { $0.id == site.defaultAccount && $0.hasPassword } }
        if needsPassword { vault.authenticate("打开工作场景并填入所选账号") { ok, error in if ok { perform() } else { self.reply(responseID, ["ok": false, "error": error ?? "已取消。"]) } } }
        else { perform() }
    }

    func validateLaunch(_ site: Website, browserID: String) throws {
        guard site.allowedBrowsers.contains(browserID), let browser = Browser.catalog.first(where: { $0.id == browserID }),
              (testMode || NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleID) != nil), validWebURL(site.url) != nil else { throw AppError.message("\(site.name)：浏览器未安装或不在允许列表中。") }
        let available = activeClients().filter { $0.browser == browserID }
        if let selected = site.profiles[browserID], !selected.isEmpty, !available.contains(where: { $0.id == selected }) {
            throw AppError.message("\(site.name)：指定浏览器资料尚未连接，请先打开该资料的搞门户助手。")
        }
        if site.profiles[browserID]?.isEmpty != false, available.count > 1 { throw AppError.message("\(site.name)：请先选择浏览器个人资料。") }
    }

    func saveBrowserBookmark(_ data: [String: Any], browser: String, profileID: String) throws -> [String: Any] {
        guard let raw = data["url"] as? String, let url = validWebURL(raw), let title = data["title"] as? String else { throw AppError.message("当前页面不能收藏，请打开普通网页。") }
        let folderID = (data["folderID"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if let folderID, !library.tiles.contains(where: { $0.id == folderID && $0.kind == "folder" }) { throw AppError.message("文件夹已变化，请重新选择。") }
        if let existing = library.sites.first(where: { LibraryOperations.canonicalURL($0.url) == LibraryOperations.canonicalURL(raw) }) {
            if !visibleSiteIDs(library.tiles).contains(existing.id) {
                var next = library
                if let folderID, let index = next.tiles.firstIndex(where: { $0.id == folderID }) { next.tiles[index].children?.append(existing.id) }
                else { next.tiles.append(Tile(id: existing.id, kind: "site", name: nil, children: nil)) }
                try commitOrganization(next, reason: "重新收藏已移除网站前")
                emit("update", ["state": state()])
                return ["ok": true, "message": "已恢复这个网站入口，原有账号和浏览器设置已保留。"]
            }
            return ["ok": true, "message": "这个网址已保存在「\(existing.name)」中。"]
        }
        let name = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        let site = Website(id: UUID().uuidString, name: name.isEmpty ? (url.host ?? "新网站") : name, url: raw, color: "#537CE6", icon: nil, allowedBrowsers: [browser], defaultBrowser: browser, accounts: [], defaultAccount: nil, profiles: [browser: profileID])
        var next = library; next.sites.append(site)
        if let folderID, let index = next.tiles.firstIndex(where: { $0.id == folderID }) { next.tiles[index].children?.append(site.id) }
        else { next.tiles.append(Tile(id: site.id, kind: "site", name: nil, children: nil)) }
        _ = try store.checkpoint(library, reason: "从浏览器收藏前")
        try store.save(next); library = next; organizationHistory.removeAll()
        emit("update", ["state": state()]); fetchIcon(site)
        return ["ok": true, "message": "已收藏到搞门户。"]
    }
}
