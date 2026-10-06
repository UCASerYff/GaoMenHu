import Foundation

/// Normalizes only URL authority, default ports and an empty root path. Query order,
/// path case, fragments and percent escapes remain meaningful bookmark identity.
func bookmarkURLKey(_ value: String) -> String? {
    guard validWebURL(value) != nil, var url = URLComponents(string: value),
          let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
    url.scheme = scheme; url.host = host
    if scheme == "https" && url.port == 443 || scheme == "http" && url.port == 80 { url.port = nil }
    if url.percentEncodedPath.isEmpty { url.percentEncodedPath = "/" }
    return url.string
}

enum LibraryOperations {
    static func canonicalURL(_ value: String) -> String { bookmarkURLKey(value) ?? value }
    static func merge(_ imported: Library, into current: Library) throws -> Library {
        try combine(imported, current: current, restoring: false)
    }
    static func restore(_ imported: Library, into current: Library) throws -> Library {
        try combine(imported, current: current, restoring: true)
    }

    private static func combine(_ imported: Library, current: Library, restoring: Bool) throws -> Library {
        _ = try imported.validated(); _ = try current.validated()
        var result = current
        var siteMap: [String: String] = [:]
        var byURL: [String: String] = [:]
        for site in current.sites where byURL[bookmarkURLKey(site.url)!] == nil { byURL[bookmarkURLKey(site.url)!] = site.id }
        var usedSiteIDs = Set(current.sites.map(\.id))
        var addedIDs: Set<String> = []
        var restoredIDs: Set<String> = []
        let reservedLocalIDs = Set(imported.sites.compactMap { importedSite in
            current.sites.first(where: { $0.id == importedSite.id && bookmarkURLKey($0.url) == bookmarkURLKey(importedSite.url) })?.id
        })
        for original in imported.sites {
            let key = bookmarkURLKey(original.url)!
            let existingID: String?
            if restoring {
                // A complete restore preserves intentionally separate entries for
                // the same URL (different browsers, profiles or account choices).
                existingID = current.sites.first(where: { $0.id == original.id && bookmarkURLKey($0.url) == key })?.id
                    ?? current.sites.first(where: { bookmarkURLKey($0.url) == key && !restoredIDs.contains($0.id) && !reservedLocalIDs.contains($0.id) })?.id
            } else { existingID = byURL[key] }
            if let existingID, let index = result.sites.firstIndex(where: { $0.id == existingID }) {
                siteMap[original.id] = existingID
                if restoring && restoredIDs.insert(existingID).inserted {
                    let local = result.sites[index]
                    var site = original; site.id = existingID
                    let accounts = restoredAccounts(original.accounts, local: local.accounts)
                    site.accounts = accounts.accounts
                    site.defaultAccount = original.defaultAccount.flatMap { accounts.ids[$0] }
                        ?? local.defaultAccount ?? site.accounts.first?.id
                    // Native profile tokens belong to this installation only.
                    site.profiles = local.profiles
                    result.sites[index] = site
                } else {
                    // Merging duplicate URLs still retains imported account metadata,
                    // without replacing local browser choices or Keychain bindings.
                    result.sites[index].accounts = restoredAccounts(original.accounts, local: result.sites[index].accounts).accounts
                }
                continue
            }
            var site = original
            // Foreign IDs never acquire an existing Keychain item's binding.
            site.id = UUID().uuidString
            while usedSiteIDs.contains(site.id) { site.id = UUID().uuidString }
            usedSiteIDs.insert(site.id)
            let originalDefault = original.defaultAccount
            site.accounts = original.accounts.map { account in
                var copy = account; copy.id = UUID().uuidString; copy.hasPassword = false; return copy
            }
            if let index = original.accounts.firstIndex(where: { $0.id == originalDefault }) { site.defaultAccount = site.accounts[index].id }
            else { site.defaultAccount = nil }
            site.profiles = [:]
            result.sites.append(site); siteMap[original.id] = site.id
            byURL[key] = site.id; addedIDs.insert(site.id); restoredIDs.insert(site.id)
        }

        var seen = restoring ? Set<String>() : Set(current.tiles.flatMap { $0.kind == "folder" ? ($0.children ?? []) : [$0.id] })
        var usedTileIDs = Set(result.sites.map(\.id))
        if !restoring { usedTileIDs.formUnion(current.tiles.map(\.id)) }
        var mappedTiles: [Tile] = []
        for tile in imported.tiles {
            let sourceIDs = tile.kind == "folder" ? (tile.children ?? []) : [tile.id]
            let children = sourceIDs.compactMap { siteMap[$0] }.filter { id in
                guard restoring || addedIDs.contains(id) else { return false }
                return seen.insert(id).inserted
            }
            guard !children.isEmpty else { continue }
            if tile.kind == "site" {
                mappedTiles.append(Tile(id: children[0], kind: "site", name: nil, children: nil))
            } else {
                var folderID = tile.id
                if usedTileIDs.contains(folderID) { folderID = UUID().uuidString }
                usedTileIDs.insert(folderID)
                mappedTiles.append(Tile(id: folderID, kind: "folder", name: tile.name, children: children))
            }
        }
        if restoring {
            result.tiles = mappedTiles
            result.appearance = imported.appearance
            result.layoutDensity = imported.layoutDensity
            result.iconSize = imported.iconSize
        } else { result.tiles += mappedTiles }
        var workspaces = restoring ? [] : (current.workspaces ?? [])
        var workspaceIDs = Set(workspaces.map(\.id))
        for original in imported.workspaces ?? [] {
            var workspace = original
            var unique: Set<String> = []
            workspace.siteIDs = original.siteIDs.compactMap { siteMap[$0] }.filter { unique.insert($0).inserted }
            guard !workspace.siteIDs.isEmpty else { continue }
            if !restoring, workspaces.contains(where: { $0.name == workspace.name && $0.siteIDs == workspace.siteIDs }) { continue }
            if workspaceIDs.contains(workspace.id) { workspace.id = UUID().uuidString }
            workspaceIDs.insert(workspace.id); workspaces.append(workspace)
        }
        result.workspaces = workspaces.isEmpty ? nil : workspaces
        return try result.validated()
    }

    private static func restoredAccounts(_ imported: [Account], local: [Account]) -> (accounts: [Account], ids: [String: String]) {
        var result: [Account] = []
        var ids: [String: String] = [:]
        var retained: Set<String> = []
        for account in imported {
            if let current = local.first(where: { $0.id == account.id }) ?? local.first(where: {
                !$0.hasPassword && $0.username == account.username && $0.label == account.label && $0.loginHosts == account.loginHosts
            }) {
                if retained.insert(current.id).inserted { result.append(current) }
                ids[account.id] = current.id
            } else {
                var copy = account; copy.id = UUID().uuidString; copy.hasPassword = false; result.append(copy); ids[account.id] = copy.id
            }
        }
        // A backup predating a newly saved account must not orphan its password.
        result += local.filter { !retained.contains($0.id) }
        return (result, ids)
    }
}

struct LibrarySnapshot: Codable, Equatable {
    let id: String
    let createdAt: Double
    let reason: String
    let siteCount: Int
    let folderCount: Int
}
private struct SnapshotEnvelope: Codable {
    let metadata: LibrarySnapshot
    let library: Library
}

extension LibraryStore {
    private var snapshotDirectory: URL { directory.appendingPathComponent("Snapshots", isDirectory: true) }

    @discardableResult func checkpoint(_ library: Library, reason: String) throws -> LibrarySnapshot? {
        _ = try library.validated()
        let metadata = LibrarySnapshot(id: UUID().uuidString, createdAt: Date().timeIntervalSince1970,
                                       reason: String(reason.prefix(100)), siteCount: library.sites.count,
                                       folderCount: library.tiles.filter { $0.kind == "folder" }.count)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(SnapshotEnvelope(metadata: metadata, library: library))
        if persistent {
            try prepareSnapshotDirectory()
            let url = snapshotDirectory.appendingPathComponent(metadata.id + ".json")
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } else { transientSnapshots[metadata.id] = data }
        for old in try snapshots().dropFirst(10) {
            if persistent { try FileManager.default.removeItem(at: snapshotDirectory.appendingPathComponent(old.id + ".json")) }
            else { transientSnapshots.removeValue(forKey: old.id) }
        }
        return metadata
    }

    func snapshots() throws -> [LibrarySnapshot] {
        let ids: [String]
        if persistent {
            guard FileManager.default.fileExists(atPath: snapshotDirectory.path) else { return [] }
            try rejectSnapshotSymlink(snapshotDirectory)
            ids = try FileManager.default.contentsOfDirectory(at: snapshotDirectory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }.map { $0.deletingPathExtension().lastPathComponent }
        } else { ids = Array(transientSnapshots.keys) }
        return ids.compactMap { id in try? snapshotEnvelope(id: id).metadata }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func loadSnapshot(id: String) throws -> Library { try snapshotEnvelope(id: id).library.validated() }

    private func snapshotEnvelope(id: String) throws -> SnapshotEnvelope {
        guard UUID(uuidString: id) != nil, !id.contains("/"), !id.contains(".") else { throw AppError.message("快照编号无效。") }
        let data: Data
        if persistent {
            try rejectSnapshotSymlink(snapshotDirectory)
            let url = snapshotDirectory.appendingPathComponent(id + ".json")
            try rejectSnapshotSymlink(url)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 30_000_000 else { throw AppError.message("快照文件过大。") }
            data = try Data(contentsOf: url)
        } else {
            guard let stored = transientSnapshots[id] else { throw AppError.message("找不到该快照。") }; data = stored
        }
        let envelope = try JSONDecoder().decode(SnapshotEnvelope.self, from: data)
        guard envelope.metadata.id == id else { throw AppError.message("快照编号不匹配。") }
        return envelope
    }

    private func prepareSnapshotDirectory() throws {
        let manager = FileManager.default
        for url in [directory, snapshotDirectory] {
            if manager.fileExists(atPath: url.path) { try rejectSnapshotSymlink(url) }
            try manager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
    }
    private func rejectSnapshotSymlink(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else { throw AppError.message("快照路径无效。") }
    }
}

struct BookmarkSource: Codable, Equatable {
    let id: String
    let browserID: String
    let profile: String
    let name: String
}
struct BookmarkGroup: Codable, Equatable {
    let id: String
    let name: String
    let siteCount: Int
    let folderCount: Int
    let duplicateCount: Int
    let children: [BookmarkGroup]
}
struct BookmarkPreview: Codable, Equatable {
    let source: BookmarkSource
    let roots: [BookmarkGroup]
    let siteCount: Int
    let folderCount: Int
    let duplicateCount: Int
    let skippedCount: Int
}
private struct BookmarkNode {
    let id: String
    let name: String
    let url: String?
    let children: [BookmarkNode]
}

struct BookmarksImporter {
    /// Tests provide an isolated home directory; only Bookmarks and display names
    /// from Local State are read. No login, cookie or browser preference database.
    var homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    private func browserRoot(_ browserID: String) -> URL? {
        let path: String
        switch browserID {
        case "edge": path = "Library/Application Support/Microsoft Edge"
        case "chrome": path = "Library/Application Support/Google/Chrome"
        default: return nil
        }
        return homeDirectory.appendingPathComponent(path, isDirectory: true)
    }
    func sources() -> [BookmarkSource] {
        var result: [BookmarkSource] = []
        for browserID in ["edge", "chrome"] {
            guard let root = browserRoot(browserID),
                  let children = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
            var names: [String: String] = [:]
            if let data = try? boundedData(root.appendingPathComponent("Local State")),
               let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let profile = state["profile"] as? [String: Any], let cache = profile["info_cache"] as? [String: [String: Any]] {
                for (key, value) in cache { names[key] = value["name"] as? String }
            }
            for directory in children.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                let profile = directory.lastPathComponent
                guard profile == "Default" || profile.hasPrefix("Profile "),
                      FileManager.default.fileExists(atPath: directory.appendingPathComponent("Bookmarks").path) else { continue }
                let browser = browserID == "edge" ? "Edge" : "Chrome"
                result.append(BookmarkSource(id: browserID + ":" + profile, browserID: browserID, profile: profile,
                                             name: browser + " · " + (names[profile] ?? profile)))
            }
        }
        return result
    }
    func preview(sourceID: String, current: Library) throws -> BookmarkPreview {
        let (source, nodes, skipped) = try read(sourceID)
        let known = Set(current.sites.compactMap { bookmarkURLKey($0.url) })
        var seen = known
        func group(_ node: BookmarkNode) -> BookmarkGroup {
            let urls = flattened(node).compactMap { $0.url }
            var duplicateCount = 0
            for url in urls { if !seen.insert(bookmarkURLKey(url)!).inserted { duplicateCount += 1 } }
            // Child previews use their own seen set so parent counting cannot mark
            // every child as duplicate merely because its parent was evaluated.
            func childGroup(_ child: BookmarkNode) -> BookmarkGroup {
                var localSeen = known
                let childURLs = flattened(child).compactMap { $0.url }
                let duplicates = childURLs.filter { !localSeen.insert(bookmarkURLKey($0)!).inserted }.count
                return BookmarkGroup(id: child.id, name: child.name, siteCount: childURLs.count,
                                     folderCount: folderCount(child), duplicateCount: duplicates,
                                     children: child.children.filter { $0.url == nil }.map(childGroup))
            }
            return BookmarkGroup(id: node.id, name: node.name, siteCount: urls.count, folderCount: folderCount(node),
                                 duplicateCount: duplicateCount, children: node.children.filter { $0.url == nil }.map(childGroup))
        }
        let roots = nodes.map(group)
        return BookmarkPreview(source: source, roots: roots, siteCount: roots.reduce(0) { $0 + $1.siteCount },
                               folderCount: roots.reduce(0) { $0 + $1.folderCount },
                               duplicateCount: roots.reduce(0) { $0 + $1.duplicateCount }, skippedCount: skipped)
    }
    func importBookmarks(sourceID: String, rootIDs: [String], into current: Library) throws -> Library {
        let (source, nodes, _) = try read(sourceID)
        guard !rootIDs.isEmpty else { throw AppError.message("请选择要导入的收藏目录。") }
        let allFolders = nodes.flatMap { flattened($0).filter { $0.url == nil }.map(\.id) }
        guard rootIDs.allSatisfy({ allFolders.contains($0) }) else { throw AppError.message("收藏目录已变化，请重新预览。") }
        let selected = Set(rootIDs)
        var next = current
        var seen = Set(current.sites.compactMap { bookmarkURLKey($0.url) })
        var groups: [(id: String?, name: String?, sites: [String])] = []
        func append(_ node: BookmarkNode, path: [String], folderID: String?, active: Bool) {
            let nowActive = active || selected.contains(node.id)
            if let url = node.url {
                guard nowActive, let key = bookmarkURLKey(url), seen.insert(key).inserted else { return }
                let id = UUID().uuidString
                let site = Website(id: id, name: String((node.name.isEmpty ? (URL(string: url)?.host ?? "网站") : node.name).prefix(100)),
                                   url: url, color: "#6F87B3", allowedBrowsers: [source.browserID], defaultBrowser: source.browserID,
                                   accounts: [], defaultAccount: nil, profiles: [:])
                next.sites.append(site)
                let name = path.isEmpty ? nil : String(path.joined(separator: " / ").prefix(120))
                if let folderID, let index = groups.firstIndex(where: { $0.id == folderID }) { groups[index].sites.append(id) }
                else if folderID == nil, let last = groups.indices.last, groups[last].id == nil { groups[last].sites.append(id) }
                else { groups.append((folderID, name, [id])) }
                return
            }
            // Browser root names are omitted; nested folders are flattened to paths.
            let isRoot = nodes.contains(where: { $0.id == node.id })
            let nextPath = isRoot ? path : path + [node.name.isEmpty ? "未命名文件夹" : node.name]
            for child in node.children { append(child, path: nextPath, folderID: isRoot ? nil : node.id, active: nowActive) }
        }
        for root in nodes { append(root, path: [], folderID: nil, active: false) }
        for (_, name, ids) in groups {
            if let name { next.tiles.append(Tile(id: UUID().uuidString, kind: "folder", name: name, children: ids)) }
            else { next.tiles += ids.map { Tile(id: $0, kind: "site", name: nil, children: nil) } }
        }
        return try next.validated()
    }
    private func read(_ sourceID: String) throws -> (BookmarkSource, [BookmarkNode], Int) {
        guard let source = sources().first(where: { $0.id == sourceID }), let root = browserRoot(source.browserID) else {
            throw AppError.message("找不到该浏览器收藏，请重新选择。")
        }
        let data = try boundedData(root.appendingPathComponent(source.profile).appendingPathComponent("Bookmarks"))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = object["roots"] as? [String: [String: Any]] else { throw AppError.message("浏览器收藏格式无效。") }
        var count = 0, skipped = 0
        func parse(_ item: [String: Any], id: String, depth: Int) throws -> BookmarkNode? {
            count += 1
            guard count <= 10000, depth <= 30 else { throw AppError.message("收藏目录过大或嵌套过深。") }
            let name = item["name"] as? String ?? ""
            if item["type"] as? String == "url" {
                guard let url = item["url"] as? String, validWebURL(url) != nil else { skipped += 1; return nil }
                return BookmarkNode(id: id, name: name, url: url, children: [])
            }
            guard item["type"] as? String == "folder", let children = item["children"] as? [[String: Any]] else { skipped += 1; return nil }
            let parsed = try children.enumerated().compactMap { index, child in try parse(child, id: id + "/" + String(index), depth: depth + 1) }
            return BookmarkNode(id: id, name: name, url: nil, children: parsed)
        }
        let rootOrder = ["bookmark_bar", "other", "synced"] + roots.keys.filter { !["bookmark_bar", "other", "synced"].contains($0) }.sorted()
        let nodes = try rootOrder.compactMap { key -> BookmarkNode? in guard let item = roots[key] else { return nil }; return try parse(item, id: key, depth: 0) }
        return (source, nodes, skipped)
    }
    private func boundedData(_ url: URL) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 20_000_000 else { throw AppError.message("浏览器收藏文件无法安全读取。") }
        return try Data(contentsOf: url)
    }
    private func flattened(_ node: BookmarkNode) -> [BookmarkNode] { [node] + node.children.flatMap(flattened) }
    private func folderCount(_ node: BookmarkNode) -> Int { node.children.reduce(0) { $0 + ($1.url == nil ? 1 : 0) + folderCount($1) } }
}
