#if DEBUG_TESTING
import Foundation

extension AppDelegate {
    func runNativeFeatureChecks() -> [String: Bool] {
        let original = library, originalStore = store!
        defer {
            library = original; store = originalStore; organizationHistory.removeAll()
            pendingLibraryChanges.removeAll(); launches.removeAll(); clients.removeAll(); launchFeedback.removeAll()
        }
        store = LibraryStore(persistent: false)
        library = Library.initial(browsers: ["chrome", "edge"])
        var checks: [String: Bool] = [:]
        func check(_ name: String, _ value: @autoclosure () -> Bool) { checks[name] = value() }
        do {
            let initial = library
            try batch(["siteIDs": ["seed-0", "seed-1"], "operation": "move", "folderName": "写论文"])
            check("batchCreatesOrderedFolder", library.tiles.last?.children == ["seed-0", "seed-1"])
            let snapshotCount = try store.snapshots().count
            check("batchCheckpointCreated", snapshotCount == 1)
            try undoOrganization(); check("undoRestoresLayout", library.tiles == initial.tiles)
            try batch(["siteIDs": ["seed-1", "seed-2"], "operation": "browser", "browser": "edge"])
            check("batchSetsAllowedDefault", library.sites[1].defaultBrowser == "edge" && library.sites[2].defaultBrowser == "edge")
            library.sites[1].aliases = "new alias during undo"
            try undoOrganization()
            check("undoPreservesOtherWebsiteChanges", library.sites[1].defaultBrowser == "chrome" && library.sites[1].aliases == "new alias during undo")
            let unchanged = library
            check("batchRejectsUnallowedBrowser", (try? batch(["siteIDs": ["seed-0"], "operation": "browser", "browser": "edge"])) == nil)
            check("rejectedBatchIsAtomic", library == unchanged)
            try batch(["siteIDs": ["seed-0"], "operation": "remove"])
            check("batchRemovalKeepsWebsite", library.sites.count == 6 && !visibleSiteIDs(library.tiles).contains("seed-0"))
            let profile = UUID().uuidString
            let restored = try saveBrowserBookmark(["url": "https://claude.ai/", "title": "Claude"], browser: "edge", profileID: profile)
            check("bookmarkRestoresArchivedEntry", restored["ok"] as? Bool == true && visibleSiteIDs(library.tiles).contains("seed-0") && library.sites.count == 6)
            check("bookmarkDuplicateKeepsBrowser", library.sites[0].allowedBrowsers == ["chrome"] && library.sites[0].defaultBrowser == "chrome")
            check("bookmarkRejectsCredentialURL", (try? saveBrowserBookmark(["url": "https://user:pass@example.test", "title": "Bad"], browser: "chrome", profileID: profile)) == nil)
            check("bookmarkRejectsInternalURL", (try? saveBrowserBookmark(["url": "chrome://settings", "title": "Bad"], browser: "chrome", profileID: profile)) == nil)
            _ = try saveBrowserBookmark(["url": "https://new.example.test/path?x=1", "title": "New"], browser: "edge", profileID: profile)
            check("bookmarkRecordsTrustedProfile", library.sites.last?.profiles["edge"] == profile && library.sites.last?.defaultBrowser == "edge")
            check("bookmarkDoesNotMakeAccounts", library.sites.last?.accounts.isEmpty == true)
            var next = library; next.tiles.reverse()
            let preview = try prepareLibraryChange(next, kind: "backup", reason: "Test", sites: next.sites.count, folders: 0, message: "Test")
            let token = preview["token"] as! String
            check("previewDoesNotMutateData", library.tiles != next.tiles)
            check("previewRejectsWrongAction", (try? applyLibraryChange(token: token, kind: "bookmarks")) == nil)
            try applyLibraryChange(token: token, kind: "backup")
            check("applyUsesPreviewedLayout", library.tiles == next.tiles)
            check("previewTokenIsSingleUse", (try? applyLibraryChange(token: token, kind: "backup")) == nil)
            let stale = try prepareLibraryChange(next, kind: "backup", reason: "Test", sites: 7, folders: 0, message: "Test")["token"] as! String
            library.sites[0].name = "Changed after preview"
            check("stalePreviewCannotOverwriteEdits", (try? applyLibraryChange(token: stale, kind: "backup")) == nil)
            library.sites[0].name = "学信档案"; library.sites[0].aliases = "学籍"
            let key = searchKeys()["seed-0"] ?? ""
            check("searchContainsPinyin", key.contains("xuexin"))
            check("searchContainsInitials", key.contains("xxda"))
            try saveWorkspace(["workspace": ["id": "work", "name": "写论文", "siteIDs": ["seed-0", "seed-1"]]])
            check("workspaceStoresOrderedWebsites", library.workspaces?.first?.siteIDs == ["seed-0", "seed-1"])
            check("workspaceRejectsDuplicateSites", (try? saveWorkspace(["workspace": ["id": "bad", "name": "Bad", "siteIDs": ["seed-0", "seed-0"]]])) == nil)
            check("workspaceRejectsMissingSite", (try? saveWorkspace(["workspace": ["id": "bad", "name": "Bad", "siteIDs": ["missing"]]])) == nil)

            let extensionID = try String(contentsOf: resources.appendingPathComponent("extension-id.txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            let base: [String: Any] = ["extension": extensionID, "browser": "chrome", "profileId": profile]
            func request(_ data: [String: Any]) -> [String: Any] { handleBrowser(base.merging(data) { _, new in new }) }
            check("collectionsRequireExtensionIdentity", handleBrowser(base.merging(["type": "collections", "extension": "invalid"]) { _, new in new })["ok"] as? Bool == false)
            check("collectionsAvailableToHelper", request(["type": "collections"])["ok"] as? Bool == true)
            let account = Account(id: "native-fixture-account", label: "Fixture", username: "fixture", loginHosts: [], hasPassword: true)
            library.sites[0].accounts = [account]; library.sites[0].defaultAccount = account.id
            let oldID = "z-first", newID = "a-second"
            launches[oldID] = LaunchRequest(id: oldID, browser: "chrome", profileID: profile, siteID: "seed-0", accountID: account.id, url: "https://example.test", allowed: [], expires: Date().addingTimeInterval(300), createdAt: Date().addingTimeInterval(-2))
            launches[newID] = LaunchRequest(id: newID, browser: "chrome", profileID: profile, siteID: "seed-1", accountID: nil, url: "https://example.test/two", allowed: [], expires: Date().addingTimeInterval(300))
            let launch = request(["type": "poll"])["launch"] as? [String: Any]
            check("sceneLaunchQueueIsFIFO", launch?["id"] as? String == oldID)
            check("launchStatusRejectsUnboundTab", request(["type": "launchStatus", "requestId": oldID, "tabId": 5, "status": "opened"])["ok"] as? Bool == false)
            _ = request(["type": "bind", "requestId": oldID, "tabId": 5])
            let denied = request(["type": "credentials", "requestId": oldID, "tabId": 5, "url": "https://other.example.test/login"])
            check("unapprovedLoginDomainExplained", denied["ok"] as? Bool == false && (denied["error"] as? String)?.contains("域名") == true)
            launches[oldID]?.allowed = ["https://example.test"]
            let missingPassword = request(["type": "credentials", "requestId": oldID, "tabId": 5, "url": "https://example.test/login"])
            check("missingPasswordExplained", missingPassword["ok"] as? Bool == false && (missingPassword["error"] as? String)?.contains("密码") == true)
            _ = request(["type": "filled", "requestId": oldID, "tabId": 5, "passwordFilled": true])
            let feedback = launchFeedback[oldID]
            _ = request(["type": "launchStatus", "requestId": oldID, "tabId": 5, "status": "opened"])
            check("lateOpenedKeepsFilledFeedback", feedback == launchFeedback[oldID])
            check("launchStatusRejectsWrongProfile", handleBrowser(base.merging(["type": "launchStatus", "requestId": oldID, "tabId": 5, "status": "failed", "profileId": UUID().uuidString]) { _, new in new })["ok"] as? Bool == false)
        } catch { checks["setupOrUnexpectedFailure"] = false; print("Native feature test error: \(error.localizedDescription)") }
        return checks
    }
}
#endif
