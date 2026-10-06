import Foundation

@main struct LibraryOperationTests {
    static func main() throws {
        var count = 0
        func check(_ name: String, _ assertion: @autoclosure () -> Bool) {
            guard assertion() else { fatalError(name) }; count += 1
        }
        func site(_ id: String, _ url: String, _ browser: String = "edge") -> Website {
            Website(id: id, name: id, url: url, color: "#123456", allowedBrowsers: [browser], defaultBrowser: browser,
                    accounts: [], defaultAccount: nil, profiles: [:])
        }
        func tile(_ id: String) -> Tile { Tile(id: id, kind: "site", name: nil, children: nil) }
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mendao-data-tests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let oldJSON = #"{"schema":1,"sites":[],"tiles":[],"appearance":"dusk"}"#.data(using: .utf8)!
        let old = try JSONDecoder().decode(Library.self, from: oldJSON)
        check("legacy library retains defaults", old.layoutDensity == nil && old.iconSize == nil && old.workspaces == nil)
        var bad = old; bad.layoutDensity = "invalid"
        check("reject bad density", (try? bad.validated()) == nil)
        bad = old; bad.iconSize = 300
        check("reject bad icon size", (try? bad.validated()) == nil)
        var localA = site("local-a", "https://EXAMPLE.com:443")
        let currentAccount = Account(id: "local-account", label: "Current name", username: "current-user", loginHosts: ["auth.example.com"], hasPassword: true)
        let recentAccount = Account(id: "recent-account", label: "Recent", username: "new-user", loginHosts: [], hasPassword: true)
        localA.accounts = [currentAccount, recentAccount]; localA.defaultAccount = currentAccount.id; localA.profiles = ["edge": "local-profile"]
        let localB = site("local-b", "https://b.example/path?q=1")
        var current = Library(sites: [localA, localB], tiles: [tile(localA.id), tile(localB.id)])
        current.workspaces = [Workspace(id: "scene", name: "Current", siteIDs: [localA.id, localB.id])]
        var importedA = site("backup-a", "https://example.com/", "chrome")
        importedA.accounts = [Account(id: currentAccount.id, label: "Stale label", username: "old-user", loginHosts: ["stale.example.com"], hasPassword: false)]
        importedA.defaultAccount = currentAccount.id; importedA.profiles = ["chrome": "foreign-profile"]
        let importedB = site("backup-b", "https://new.example/page?q=1")
        var incoming = Library(sites: [importedA, importedB], tiles: [Tile(id: "folder", kind: "folder", name: "Original folder", children: [importedB.id, importedA.id])])
        incoming.layoutDensity = "compact"; incoming.iconSize = 60
        incoming.workspaces = [Workspace(id: "scene", name: "Restore scene", siteIDs: [importedB.id, importedA.id])]
        let restored = try LibraryOperations.restore(incoming, into: current)
        let restoredA = restored.sites.first(where: { $0.id == localA.id })!
        let restoredB = restored.sites.first(where: { bookmarkURLKey($0.url) == bookmarkURLKey(importedB.url) })!
        check("URL identity preserves local site id", restoredA.id == localA.id)
        check("same machine account fields authoritative", restoredA.accounts.first == currentAccount)
        check("newly created accounts not orphaned", restoredA.accounts.contains(recentAccount))
        check("same machine keychain binding retained", restoredA.accounts.first?.hasPassword == true)
        check("profile tokens stay local", restoredA.profiles == localA.profiles)
        check("restore folder child order", restored.tiles.first?.children == [restoredB.id, localA.id])
        check("missing current sites archived", restored.sites.contains(localB) && !restored.tiles.contains(where: { $0.id == localB.id || ($0.children ?? []).contains(localB.id) }))
        check("restore settings", restored.layoutDensity == "compact" && restored.iconSize == 60)
        check("restore workspace id mapping", restored.workspaces?.first?.siteIDs == [restoredB.id, localA.id])
        var duplicatedCurrent = current
        var sameURL = localA; sameURL.id = "same-url-second"; sameURL.accounts = []; sameURL.defaultAccount = nil
        duplicatedCurrent.sites.append(sameURL); duplicatedCurrent.tiles.append(tile(sameURL.id))
        check("same-machine restore retains intentionally duplicated entries", (try? LibraryOperations.restore(duplicatedCurrent, into: duplicatedCurrent)) == duplicatedCurrent)
        var duplicateBackup = Library(sites: [site("dup-one", "https://same.example/", "edge"), site("dup-two", "https://same.example/", "chrome")], tiles: [tile("dup-one"), tile("dup-two")])
        let restoredDuplicates = try LibraryOperations.restore(duplicateBackup, into: .empty())
        check("foreign restore retains same URL different browser entries", restoredDuplicates.sites.count == 2 && restoredDuplicates.tiles.count == 2 && restoredDuplicates.sites.map(\.defaultBrowser) == ["edge", "chrome"])
        duplicateBackup.sites[1].id = localA.id; duplicateBackup.sites[1].url = localA.url; duplicateBackup.tiles[1].id = localA.id
        duplicateBackup.sites[0].url = localA.url
        let reservedRestore = try LibraryOperations.restore(duplicateBackup, into: current)
        check("restore does not reuse reserved exact local id", reservedRestore.tiles.count == 2 && reservedRestore.tiles[0].id != localA.id && reservedRestore.tiles[1].id == localA.id)
        let merged = try LibraryOperations.merge(incoming, into: current)
        check("merge deduplicates root URL", merged.sites.count == 3)
        check("merge does not change browser choices", merged.sites.first?.defaultBrowser == "edge")
        check("merge keeps layout", Array(merged.tiles.prefix(2)) == current.tiles)
        check("merge maintains imported folder", merged.tiles.last?.kind == "folder" && merged.tiles.last?.name == "Original folder")
        check("merge remaps workspace collision", merged.workspaces?.count == 2 && Set(merged.workspaces!.map(\.id)).count == 2)
        let mergedAgain = try LibraryOperations.merge(incoming, into: merged)
        check("workspace repeat merge is idempotent", mergedAgain == merged)
        var renamedWorkspace = incoming; renamedWorkspace.workspaces![0].name = "Different content"
        let mergedDifferent = try LibraryOperations.merge(renamedWorkspace, into: merged)
        check("workspace same id different content retained", mergedDifferent.workspaces?.count == 3 && Array(mergedDifferent.workspaces!.prefix(2)) == merged.workspaces!)
        var foreign = incoming; foreign.sites[0].url = "https://foreign.example/"
        foreign.sites[0].accounts[0].hasPassword = true
        let foreignRestored = try LibraryOperations.restore(foreign, into: current)
        let foreignAccount = foreignRestored.sites.first(where: { $0.url == "https://foreign.example/" })!.accounts[0]
        check("foreign same account id receives new id", foreignAccount.id != currentAccount.id)
        check("foreign cannot claim local password", !foreignAccount.hasPassword)
        check("foreign account does not delete existing binding", foreignRestored.sites.first(where: { $0.id == localA.id })?.accounts == localA.accounts)
        var staleDefault = incoming
        staleDefault.sites[0].accounts = [Account(id: "foreign-account", label: "Foreign", username: "foreign-user", loginHosts: [], hasPassword: true)]
        staleDefault.sites[0].defaultAccount = "foreign-account"
        let defaultRestored = try LibraryOperations.restore(staleDefault, into: current).sites.first(where: { $0.id == localA.id })!
        check("foreign default remapped", defaultRestored.defaultAccount == defaultRestored.accounts.first?.id && defaultRestored.defaultAccount != "foreign-account")
        check("foreign default password not imported", defaultRestored.accounts.first?.hasPassword == false)
        var identicalForeign = current; identicalForeign.sites[0].accounts = [currentAccount]; identicalForeign.sites[0].accounts[0].id = "foreign-identical"
        identicalForeign.sites[0].defaultAccount = "foreign-identical"
        let identicalRestored = try LibraryOperations.restore(identicalForeign, into: current).sites[0]
        check("foreign identical account metadata cannot acquire keychain binding", identicalRestored.accounts[0].id != currentAccount.id && !identicalRestored.accounts[0].hasPassword && identicalRestored.accounts.contains(currentAccount))
        let onceMerged = try LibraryOperations.merge(staleDefault, into: current)
        let twiceMerged = try LibraryOperations.merge(staleDefault, into: onceMerged)
        check("repeated foreign account import does not duplicate metadata", twiceMerged.sites.map { $0.accounts.count } == onceMerged.sites.map { $0.accounts.count })
        check("preserve query distinctions", LibraryOperations.canonicalURL("https://example.com/?a=1") != LibraryOperations.canonicalURL("https://example.com/?a=2"))
        check("preserve query ordering", LibraryOperations.canonicalURL("https://example.com/?a=1&b=2") != LibraryOperations.canonicalURL("https://example.com/?b=2&a=1"))
        check("preserve path case", LibraryOperations.canonicalURL("https://example.com/A") != LibraryOperations.canonicalURL("https://example.com/a"))
        check("preserve encoded path", LibraryOperations.canonicalURL("https://example.com/%2f") != LibraryOperations.canonicalURL("https://example.com/"))
        check("normalize host and default port", LibraryOperations.canonicalURL("HTTPS://EXAMPLE.com:443") == "https://example.com/")
        check("HTTP remains distinct", LibraryOperations.canonicalURL("http://example.com/") != LibraryOperations.canonicalURL("https://example.com/"))
        check("non-default port remains", LibraryOperations.canonicalURL("https://example.com:8443/") != LibraryOperations.canonicalURL("https://example.com/"))
        bad = current; bad.workspaces = [Workspace(id: "bad", name: "Empty", siteIDs: [])]
        check("reject empty workspace", (try? bad.validated()) == nil)
        bad.workspaces = [Workspace(id: "bad", name: "Missing", siteIDs: ["missing"])]
        check("reject stale workspace references", (try? bad.validated()) == nil)
        bad.workspaces = [Workspace(id: "bad", name: "Dup", siteIDs: [localA.id, localA.id])]
        check("reject repeated workspace site", (try? bad.validated()) == nil)
        let many = (0..<21).map { site("many-\($0)", "https://example.com/\($0)") }
        bad = Library(sites: many, tiles: [])
        bad.workspaces = [Workspace(id: "many", name: "Too many", siteIDs: many.map(\.id))]
        check("workspace limited to 20 sites", (try? bad.validated()) == nil)

        let store = LibraryStore(directory: temporary.appendingPathComponent("real"))
        for index in 0..<12 { _ = try store.checkpoint(current, reason: "Operation \(index)") }
        let snapshots = try store.snapshots()
        check("ten snapshot retention", snapshots.count == 10)
        check("snapshot sorted newest first", snapshots.first?.reason == "Operation 11" && snapshots.last?.reason == "Operation 2")
        check("snapshot preserves full library", (try? store.loadSnapshot(id: snapshots[0].id)) == current)
        check("snapshot refuses traversal", (try? store.loadSnapshot(id: "../../library")) == nil)
        let snapshotFolder = store.directory.appendingPathComponent("Snapshots")
        let folderMode = try FileManager.default.attributesOfItem(atPath: snapshotFolder.path)[.posixPermissions] as! NSNumber
        let fileMode = try FileManager.default.attributesOfItem(atPath: snapshotFolder.appendingPathComponent(snapshots[0].id + ".json").path)[.posixPermissions] as! NSNumber
        check("snapshot directory is private", folderMode.intValue == 0o700)
        check("snapshot file is private", fileMode.intValue == 0o600)
        let memoryPath = temporary.appendingPathComponent("memory-must-not-exist")
        let memory = LibraryStore(directory: memoryPath, persistent: false)
        let memorySnapshot = try memory.checkpoint(current, reason: "test")!
        check("test snapshot roundtrip", (try? memory.loadSnapshot(id: memorySnapshot.id)) == current)
        check("test mode avoids disk", !FileManager.default.fileExists(atPath: memoryPath.path))
        let symlinkID = UUID().uuidString
        try FileManager.default.createSymbolicLink(at: snapshotFolder.appendingPathComponent(symlinkID + ".json"), withDestinationURL: snapshotFolder.appendingPathComponent(snapshots[0].id + ".json"))
        check("snapshot rejects symlink", (try? store.loadSnapshot(id: symlinkID)) == nil)

        let browserHome = temporary.appendingPathComponent("browser-home")
        let profile = browserHome.appendingPathComponent("Library/Application Support/Microsoft Edge/Default")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        func bookmark(_ name: String, _ url: String) -> [String: Any] { ["type": "url", "name": name, "url": url] }
        func folder(_ name: String, _ children: [[String: Any]]) -> [String: Any] { ["type": "folder", "name": name, "children": children] }
        let document: [String: Any] = ["roots": [
            "bookmark_bar": folder("Favorites bar", [bookmark("Duplicate", "https://example.com/"),
                folder("Research", [bookmark("Paper A", "https://papers.example/a?token=1"),
                    folder("Archive", [bookmark("Paper B", "https://papers.example/a?token=2")]),
                    bookmark("Paper C", "https://papers.example/c")]), bookmark("Ignored", "javascript:alert(1)"),
                bookmark("Repeat", "https://papers.example/c")]),
            "other": folder("Other", [bookmark("Other item", "https://other.example/")])]]
        try JSONSerialization.data(withJSONObject: document).write(to: profile.appendingPathComponent("Bookmarks"))
        let importer = BookmarksImporter(homeDirectory: browserHome)
        check("only present browser profiles listed", importer.sources().map(\.id) == ["edge:Default"])
        let preview = try importer.preview(sourceID: "edge:Default", current: current)
        check("bookmark preview root IDs stable", preview.roots.map(\.id) == ["bookmark_bar", "other"])
        check("bookmark preview valid website count", preview.siteCount == 6)
        check("bookmark preview folder count", preview.folderCount == 2)
        check("bookmark preview duplicate count", preview.duplicateCount == 2)
        check("bookmark preview unsafe URL skipped", preview.skippedCount == 1)
        let bookmarkImport = try importer.importBookmarks(sourceID: "edge:Default", rootIDs: ["bookmark_bar"], into: current)
        check("import bar excludes other root and duplicates", bookmarkImport.sites.count == 5)
        check("bookmark query distinctions preserved", bookmarkImport.sites.filter { $0.url.contains("papers.example/a?") }.count == 2)
        check("bookmark duplicate retains browser preference", bookmarkImport.sites.first == localA)
        let researchFolder = bookmarkImport.tiles.first(where: { $0.name == "Research" })!
        check("nested folder flatten path", bookmarkImport.tiles.contains(where: { $0.name == "Research / Archive" }))
        check("split parent folder reunited", researchFolder.children?.count == 2 && bookmarkImport.tiles.filter { $0.name == "Research" }.count == 1)
        check("new bookmarks use source browser", bookmarkImport.sites.dropFirst(2).allSatisfy { $0.defaultBrowser == "edge" && $0.allowedBrowsers == ["edge"] })
        check("invalid source refused", (try? importer.preview(sourceID: "edge:../../outside", current: current)) == nil)
        check("invalid root refused", (try? importer.importBookmarks(sourceID: "edge:Default", rootIDs: ["missing"], into: current)) == nil)
        let nestedImport = try importer.importBookmarks(sourceID: "edge:Default", rootIDs: ["bookmark_bar/1/1"], into: current)
        check("select nested folder only", nestedImport.sites.count == 3 && nestedImport.tiles.last?.name == "Research / Archive")
        let repeatImport = try importer.importBookmarks(sourceID: "edge:Default", rootIDs: ["bookmark_bar"], into: bookmarkImport)
        check("reimport bookmarks is idempotent", repeatImport == bookmarkImport)
        print("Library operation tests passed: \(count)")
    }
}
