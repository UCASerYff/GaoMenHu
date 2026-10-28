import Foundation
import Darwin

private final class ActionTestEvidence: PortalLedgerEvidenceStore {
    var value: Data?
    func read() throws -> Data? { value }
    func write(_ data: Data) throws { value = data }
}

@main struct PortalActionsTests {
    static func main() throws {
        var count = 0
        func check(_ name: String, _ value: @autoclosure () throws -> Bool) {
            guard (try? value()) == true else { fatalError(name) }
            count += 1
        }
        func rejects(_ name: String, code: String? = nil, _ body: () throws -> Void) {
            do { try body(); fatalError("Expected rejection: " + name) }
            catch let error as PortalActionError { check(name, code == nil || error.code == code) }
            catch { fatalError("Unexpected error for " + name + ": " + String(describing: type(of: error))) }
        }

        var library = Library.initial(browsers: ["chrome", "edge"])
        let runtime = PortalRuntime(installedBrowserIDs: ["chrome", "edge", "safari"], connectedProfiles: [:])
        func plan(_ action: String, _ parameters: [String: Any], source: Library? = nil, environment: PortalRuntime? = nil) throws -> PortalActionPlan {
            try PortalActionPlanner.plan(action: action, parameters: parameters, library: source ?? library, runtime: environment ?? runtime)
        }
        check("default browser remains selected", try plan("portal.openSite", ["siteID": "seed-1"]) == .openSite(PortalSiteLaunch(siteID: "seed-1", browserID: "chrome", profileID: nil, requiresAuthentication: false)))
        check("explicit allowed browser", try plan("portal.openSite", ["siteID": "seed-1", "browserID": "edge"]) == .openSite(PortalSiteLaunch(siteID: "seed-1", browserID: "edge", profileID: nil, requiresAuthentication: false)))
        rejects("site IDs cannot be spoofed", code: "site_not_found") { _ = try plan("portal.openSite", ["siteID": "not-a-site"]) }
        rejects("unallowed browser never falls back", code: "browser_not_allowed") { _ = try plan("portal.openSite", ["siteID": "seed-0", "browserID": "edge"]) }
        rejects("unknown browser rejected", code: "browser_not_allowed") { _ = try plan("portal.openSite", ["siteID": "seed-0", "browserID": "invented"]) }
        rejects("uninstalled browser never falls back", code: "browser_unavailable") {
            _ = try plan("portal.openSite", ["siteID": "seed-1"], environment: PortalRuntime(installedBrowserIDs: ["edge"], connectedProfiles: [:]))
        }
        var bad = library; bad.sites[1].defaultBrowser = "safari"
        rejects("default outside allowed list rejected", code: "invalid_site_configuration") { _ = try plan("portal.openSite", ["siteID": "seed-1", "browserID": "chrome"], source: bad) }
        bad = library; bad.sites.append(bad.sites[1])
        rejects("ambiguous stored ID rejected", code: "site_not_found") { _ = try plan("portal.openSite", ["siteID": "seed-1"], source: bad) }
        bad = library; bad.sites[1].allowedBrowsers = []
        rejects("empty allowed list rejected", code: "invalid_site_configuration") { _ = try plan("portal.openSite", ["siteID": "seed-1"], source: bad) }
        var bound = library; bound.sites[1].profiles = ["chrome": "fixture-profile"]
        rejects("missing selected profile rejected", code: "profile_unavailable") { _ = try plan("portal.openSite", ["siteID": "seed-1"], source: bound) }
        let connected = PortalRuntime(installedBrowserIDs: ["chrome", "edge"], connectedProfiles: ["chrome": ["fixture-profile", "another-profile"]])
        check("bound profile retained among multiple", try plan("portal.openSite", ["siteID": "seed-1"], source: bound, environment: connected) == .openSite(PortalSiteLaunch(siteID: "seed-1", browserID: "chrome", profileID: "fixture-profile", requiresAuthentication: false)))
        rejects("unbound multiple profiles rejected", code: "profile_ambiguous") { _ = try plan("portal.openSite", ["siteID": "seed-1"], environment: connected) }
        let sole = PortalRuntime(installedBrowserIDs: ["chrome"], connectedProfiles: ["chrome": ["sole-profile"]])
        check("sole existing profile selected", try plan("portal.openSite", ["siteID": "seed-1"], environment: sole) == .openSite(PortalSiteLaunch(siteID: "seed-1", browserID: "chrome", profileID: "sole-profile", requiresAuthentication: false)))

        let account = Account(id: "fixture-account", label: "Fixture", username: "not-exported", loginHosts: ["auth.example.test"], hasPassword: true)
        var secured = library; secured.sites[1].accounts = [account]; secured.sites[1].defaultAccount = account.id
        if case .openSite(let launch) = try plan("portal.openSite", ["siteID": "seed-1"], source: secured) {
            check("password account must retain authentication requirement", launch.requiresAuthentication)
        } else { fatalError("Wrong plan") }
        bad = secured; bad.sites[1].url = "http://example.test"
        rejects("HTTP account fill rejected", code: "insecure_login_scope") { _ = try plan("portal.openSite", ["siteID": "seed-1"], source: bad) }
        bad = secured; bad.sites[1].accounts[0].loginHosts = ["http://auth.example.test"]
        rejects("explicit HTTP login host rejected", code: "insecure_login_scope") { _ = try plan("portal.openSite", ["siteID": "seed-1"], source: bad) }
        bad = secured; bad.sites[1].accounts[0].loginHosts = ["https://auth.example.test/path"]
        rejects("login host path rejected", code: "invalid_site_configuration") { _ = try plan("portal.openSite", ["siteID": "seed-1"], source: bad) }
        bad = secured; bad.sites[1].defaultAccount = "missing"
        rejects("missing selected account rejected", code: "invalid_site_configuration") { _ = try plan("portal.openSite", ["siteID": "seed-1"], source: bad) }
        var ordinaryHTTP = library; ordinaryHTTP.sites[1].url = "http://example.test"
        check("ordinary HTTP site allowed without account fill", (try? plan("portal.openSite", ["siteID": "seed-1"], source: ordinaryHTTP)) != nil)
        check("planning does not alter library or account", secured.sites[1].accounts[0] == account && library == Library.initial(browsers: ["chrome", "edge"]))

        library.workspaces = [Workspace(id: "work", name: "Fixture", siteIDs: ["seed-1", "seed-0"])]
        if case .openWorkspace(let launch) = try plan("portal.openWorkspace", ["workspaceID": "work"]) {
            check("workspace order retained", launch.sites.map(\.siteID) == ["seed-1", "seed-0"])
            check("workspace uses each default", launch.sites.allSatisfy { $0.browserID == "chrome" })
        } else { fatalError("Wrong workspace plan") }
        rejects("unknown workspace rejected", code: "workspace_not_found") { _ = try plan("portal.openWorkspace", ["workspaceID": "missing"]) }
        bad = library; bad.workspaces?[0].siteIDs.append("missing")
        rejects("changed workspace fails before side effects", code: "workspace_not_found") { _ = try plan("portal.openWorkspace", ["workspaceID": "work"], source: bad) }
        bad = library; bad.workspaces?[0].siteIDs.append("seed-0")
        rejects("duplicate workspace sites rejected", code: "workspace_not_found") { _ = try plan("portal.openWorkspace", ["workspaceID": "work"], source: bad) }
        bad = library; bad.workspaces?[0].siteIDs = []
        rejects("empty workspace rejected", code: "workspace_not_found") { _ = try plan("portal.openWorkspace", ["workspaceID": "work"], source: bad) }
        check("search default is visible empty query", try plan("portal.focusSearch", [:]) == .focusSearch(""))
        check("search bound accepted", try plan("portal.focusSearch", ["query": String(repeating: "中", count: 4096)]) == .focusSearch(String(repeating: "中", count: 4096)))
        rejects("search over limit rejected", code: "invalid_parameters") { _ = try plan("portal.focusSearch", ["query": String(repeating: "a", count: 4097)]) }
        rejects("search null not silently ignored", code: "invalid_parameters") { _ = try plan("portal.focusSearch", ["query": NSNull()]) }
        rejects("NUL query rejected", code: "invalid_parameters") { _ = try plan("portal.focusSearch", ["query": "a\0b"]) }
        rejects("boolean IDs rejected", code: "invalid_parameters") { _ = try plan("portal.openSite", ["siteID": true]) }
        rejects("unknown action rejected", code: "unsupported_action") { _ = try plan("portal.arbitrary", [:]) }
        for key in ["password", "cookies", "headers", "shell", "script", "callbackURL", "accountID", "profilePath", "browserArguments", "autoSubmit", "captcha"] {
            rejects("unknown field " + key, code: "invalid_parameters") { _ = try plan("portal.openSite", ["siteID": "seed-1", key: "forbidden"]) }
        }
        rejects("attachments rejected", code: "invalid_parameters") { try PortalActionPlanner.validateParameters(action: "portal.focusSearch", parameters: [:], itemCount: 1) }
        rejects("references rejected", code: "invalid_parameters") { try PortalActionPlanner.validateParameters(action: "portal.focusSearch", parameters: [:], referenceCount: 1) }
        check("proposal only contains draft", try plan("portal.proposeSite", ["url": "https://example.test/path", "title": "Fixture"]) == .proposeSite(PortalSiteProposal(url: "https://example.test/path", title: "Fixture")))
        rejects("proposal title over bound rejected", code: "invalid_parameters") { _ = try plan("portal.proposeSite", ["url": "https://example.test", "title": String(repeating: "a", count: 257)]) }
        for url in ["javascript:alert(1)", "file:///private/tmp/input", "https://user:password@example.test", "https://@example.test", "https://example.test/%zz", "https://example.test/%", "https://example.test/a b", "https://example.test/\n", "https:///", "https://*.example.test", "https://example.test:0", "https://example.test:65536"] {
            rejects("unsafe proposal URL rejected", code: "invalid_url") { _ = try plan("portal.proposeSite", ["url": url]) }
        }

        if case .prepareDownload(let urls) = try plan("portal.prepareDownload", ["urls": ["https://example.test/movie?token=private#fragment", "http://example.test/plain"]]) {
            check("download review flags all URL query or fragment", urls[0].requiresPrivacyReview && !urls[1].requiresPrivacyReview)
            check("download stripped fallback omits query and fragment", urls[0].withoutQueryAndFragment == "https://example.test/movie")
            check("ordinary download remains HTTP", urls[1].url == "http://example.test/plain")
        } else { fatalError("Wrong download plan") }
        rejects("zero download URLs rejected", code: "invalid_parameters") { _ = try plan("portal.prepareDownload", ["urls": [String]()]) }
        rejects("oversized download batch rejected", code: "invalid_parameters") { _ = try plan("portal.prepareDownload", ["urls": Array(repeating: "https://example.test", count: 33)]) }
        rejects("mixed download URL types rejected", code: "invalid_parameters") { _ = try plan("portal.prepareDownload", ["urls": ["https://example.test", 7]]) }
        rejects("download media option not added to portal V1", code: "invalid_parameters") { _ = try plan("portal.prepareDownload", ["urls": ["https://example.test"], "mediaType": "video"]) }

        let catalog = try UserExposedSiteCatalog(library: secured, authorizedSiteIDs: ["seed-1"])
        check("catalog only explicitly authorized selection", catalog.sites.map(\.siteID) == ["seed-1"])
        check("empty authorization exports nothing", try UserExposedSiteCatalog(library: secured, authorizedSiteIDs: []).sites.isEmpty)
        let exported = String(data: try JSONEncoder().encode(catalog), encoding: .utf8)!
        check("catalog has no URL account profile or history", !exported.contains("https:") && !exported.contains("not-exported") && !exported.contains("accounts") && !exported.contains("profiles") && !exported.contains("history"))
        rejects("catalog stale selection rejected", code: "site_not_found") { _ = try UserExposedSiteCatalog(library: secured, authorizedSiteIDs: ["missing"]) }

        let downloadParameters: [String: Any] = ["type": "object", "properties": ["urls": ["type": "array", "minItems": 1, "maxItems": 32, "items": ["type": "string", "format": "uri"]], "mediaType": ["type": "string", "enum": ["file", "video"]]], "required": ["urls"], "additionalProperties": false]
        let validCapability: [String: Any] = ["schemaVersion": 1, "bundleID": "com.gaoseries.GaoXiaZai", "appVersion": "1.00", "actions": [["action": "downloads.prepare", "parameters": downloadParameters, "items": ["maxCount": 0], "references": ["maxCount": 0]]]]
        func capability(_ object: [String: Any]) throws -> PortalDownloadProviderCapability {
            try .validated(data: JSONSerialization.data(withJSONObject: object), installedBundleID: "com.gaoseries.GaoXiaZai")
        }
        check("matching installed provider supports only declared options", try capability(validCapability).supportedMediaTypes == ["file", "video"])
        var caps = validCapability; caps["schemaVersion"] = 2
        rejects("newer capability schema rejected", code: "download_provider_incompatible") { _ = try capability(caps) }
        caps = validCapability; caps["schemaVersion"] = true
        rejects("boolean schema version rejected", code: "download_provider_incompatible") { _ = try capability(caps) }
        caps = validCapability; caps["bundleID"] = "other.app"
        rejects("claimed wrong provider rejected", code: "download_provider_incompatible") { _ = try capability(caps) }
        rejects("actual installed identity must match", code: "download_provider_incompatible") { _ = try PortalDownloadProviderCapability.validated(data: JSONSerialization.data(withJSONObject: validCapability), installedBundleID: "other.app") }
        caps = validCapability; caps["actions"] = [["action": "downloads.fake"]]
        rejects("mere app presence does not provide prepare", code: "download_provider_incompatible") { _ = try capability(caps) }
        caps = validCapability
        var wrongParameters = downloadParameters; wrongParameters["additionalProperties"] = true
        caps["actions"] = [["action": "downloads.prepare", "parameters": wrongParameters, "items": ["maxCount": 0], "references": ["maxCount": 0]]]
        rejects("provider arbitrary parameter schema rejected", code: "download_provider_incompatible") { _ = try capability(caps) }
        wrongParameters = downloadParameters; wrongParameters["properties"] = ["urls": ["type": "array", "minItems": 1, "maxItems": 32, "items": ["type": "string"]], "headers": ["type": "object"]]
        caps["actions"] = [["action": "downloads.prepare", "parameters": wrongParameters, "items": ["maxCount": 0], "references": ["maxCount": 0]]]
        rejects("provider headers not compatible", code: "download_provider_incompatible") { _ = try capability(caps) }
        check("absent provider message honest", PortalDownloadProviderCapability.unavailable.code == "download_provider_unavailable")

        let downloadReply = "ABCDEF12-3456-4789-8ABC-DEF123456789"
        var routeChecks: [String] = []
        check("request consults only action history", try PortalExchangeRouting.route(kind: "request", inReplyTo: nil,
            requireRequestLedger: { routeChecks.append("request") },
            requireDownloadRequest: { _ in fatalError("request must not use download history") }) == .request)
        check("request gate actually ran", routeChecks == ["request"])
        routeChecks = []
        check("known result does not consult missing action history", try PortalExchangeRouting.route(kind: "result", inReplyTo: downloadReply,
            requireRequestLedger: { throw PortalActionError.invalidLedger },
            requireDownloadRequest: { routeChecks.append($0) }) == .downloadResult)
        check("result correlation is canonical", routeChecks == [downloadReply.lowercased()])
        for invalidReply: String? in [nil, "", "not-a-request", " " + downloadReply] {
            rejects("invalid result correlation rejected before either history", code: "unmatched_download_result") {
                _ = try PortalExchangeRouting.route(kind: "result", inReplyTo: invalidReply,
                    requireRequestLedger: { fatalError("invalid result must not consult action history") },
                    requireDownloadRequest: { _ in fatalError("invalid correlation must not reach download history") })
            }
        }
        rejects("unknown package kind cannot select a history", code: "invalid_parameters") {
            _ = try PortalExchangeRouting.route(kind: "invented", inReplyTo: downloadReply,
                requireRequestLedger: { fatalError("unknown kind must not reach action history") },
                requireDownloadRequest: { _ in fatalError("unknown kind must not reach download history") })
        }
        rejects("missing action history never falls back to downloads", code: "invalid_request_ledger") {
            _ = try PortalExchangeRouting.route(kind: "request", inReplyTo: nil,
                requireRequestLedger: { throw PortalActionError.invalidLedger },
                requireDownloadRequest: { _ in fatalError("missing action history cannot authorize via downloads") })
        }
        let unavailableDownloads = PortalActionError(code: "download_unavailable", message: "unavailable")
        rejects("missing download history never falls back to action ledger", code: "download_unavailable") {
            _ = try PortalExchangeRouting.route(kind: "result", inReplyTo: downloadReply,
                requireRequestLedger: { fatalError("result must not fall back to old action history") },
                requireDownloadRequest: { _ in throw unavailableDownloads })
        }
        let unknownDownload = PortalActionError(code: "unmatched_download_result", message: "unknown")
        rejects("unknown outgoing request does not pass available download history", code: "unmatched_download_result") {
            _ = try PortalExchangeRouting.route(kind: "result", inReplyTo: downloadReply,
                requireRequestLedger: { fatalError("unknown result must not consult old action history") },
                requireDownloadRequest: { _ in throw unknownDownload })
        }
        var currentDownloadHistory = true
        let currentGate = { (reply: String) throws -> Void in
            guard currentDownloadHistory else { throw unavailableDownloads }
            guard reply == downloadReply.lowercased() else { throw unknownDownload }
        }
        check("copy gate permits independently known result", try PortalExchangeRouting.route(kind: "result", inReplyTo: downloadReply,
            requireRequestLedger: { throw PortalActionError.invalidLedger }, requireDownloadRequest: currentGate) == .downloadResult)
        currentDownloadHistory = false
        rejects("consumption rechecks changed download history", code: "download_unavailable") {
            _ = try PortalExchangeRouting.route(kind: "result", inReplyTo: downloadReply,
                requireRequestLedger: { throw PortalActionError.invalidLedger }, requireDownloadRequest: currentGate)
        }

        let oldUnavailable = PortalExchangeHistoryAvailability(requestsReadable: false, downloadsReadable: true)
        check("missing old history explicitly identified", oldUnavailable.restrictions.count == 1 && oldUnavailable.emptyMessage.contains("网站动作历史恢复受限"))
        check("available empty download history separately described", oldUnavailable.emptyMessage.contains("可读取的下载交接历史当前没有记录。") && !oldUnavailable.emptyMessage.contains("可读取的网站动作历史当前没有记录。"))
        check("download choices may remain visible with old recovery notice", oldUnavailable.readableHistoryNotice.contains("下方仅列出可核验的历史。"))
        let downloadUnavailable = PortalExchangeHistoryAvailability(requestsReadable: true, downloadsReadable: false)
        check("missing download history explicitly identified", downloadUnavailable.restrictions.count == 1 && downloadUnavailable.emptyMessage.contains("下载交接历史恢复受限"))
        check("available empty action history separately described", downloadUnavailable.emptyMessage.contains("可读取的网站动作历史当前没有记录。") && !downloadUnavailable.emptyMessage.contains("可读取的下载交接历史当前没有记录。"))
        let neitherReadable = PortalExchangeHistoryAvailability(requestsReadable: false, downloadsReadable: false)
        check("both unavailable histories are never called empty", neitherReadable.restrictions.count == 2 && !neitherReadable.emptyMessage.contains("当前没有记录。") && neitherReadable.emptyMessage.contains("不能解释为没有记录"))
        let bothReadable = PortalExchangeHistoryAvailability(requestsReadable: true, downloadsReadable: true)
        check("genuinely empty readable histories retain empty state", bothReadable.restrictions.isEmpty && bothReadable.emptyMessage == "还没有跨 App 交接记录。")
        check("readable history has no false recovery warning", bothReadable.readableHistoryNotice.isEmpty)

        let now = Date(timeIntervalSince1970: 1_760_270_400)
        let id = "11111111-1111-4111-8111-000000000004"
        let hash = String(repeating: "a", count: 64)
        let temporary = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("mendao-portal-actions-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let evidence = ActionTestEvidence()
        let ledger = try PortalRequestLedger(directory: temporary.appendingPathComponent("ledger"), now: now, evidence: evidence)
        if case .new(let record) = try ledger.receive(requestID: id, fingerprint: hash, action: "portal.openSite", now: now) {
            check("new request starts awaiting visible confirmation", record.state == .received && record.outcome == .awaitingUser)
        } else { fatalError("Expected new request") }
        rejects("cannot execute without approval", code: "invalid_request_transition") { _ = try ledger.beginExecution(requestID: id, now: now) }
        rejects("cannot finish before execution", code: "invalid_request_transition") { _ = try ledger.finish(requestID: id, outcome: .cancelled, now: now) }
        if case .repeated(let record) = try ledger.receive(requestID: id.uppercased(), fingerprint: hash, action: "portal.openSite", now: now) {
            check("repeat awaiting confirmation returns stored record", record.state == .received)
        } else { fatalError("Expected repeated request") }
        rejects("same ID different digest rejected", code: "request_id_conflict") { _ = try ledger.receive(requestID: id, fingerprint: String(repeating: "b", count: 64), action: "portal.openSite", now: now) }
        rejects("same ID different action rejected", code: "request_id_conflict") { _ = try ledger.receive(requestID: id, fingerprint: hash, action: "portal.focusSearch", now: now) }
        _ = try ledger.approve(requestID: id, now: now)
        _ = try ledger.beginExecution(requestID: id, now: now)
        _ = try ledger.markAwaitingUser(requestID: id, now: now)
        check("editor remains awaiting user after visible open", ledger.record(requestID: id)?.outcome == .awaitingUser)
        let completed = PortalActionOutcome(status: .completed, workflowState: .opened)
        _ = try ledger.finish(requestID: id, outcome: completed, now: now)
        rejects("completed request cannot execute twice", code: "invalid_request_transition") { _ = try ledger.beginExecution(requestID: id, now: now) }
        rejects("completed request cannot be reapproved", code: "invalid_request_transition") { _ = try ledger.approve(requestID: id, now: now) }
        let reloaded = try PortalRequestLedger(directory: ledger.directory, now: now, evidence: evidence)
        if case .repeated(let record) = try reloaded.receive(requestID: id, fingerprint: hash, action: "portal.openSite", now: now) {
            check("completed repeat after relaunch returns original result", record.state == .completed && record.outcome == completed)
        } else { fatalError("Expected persisted repeated request") }
        let privateMode = try FileManager.default.attributesOfItem(atPath: ledger.file.path)[.posixPermissions] as! NSNumber
        check("ledger private file mode", privateMode.intValue == 0o600)
        let ledgerText = String(data: try Data(contentsOf: ledger.file), encoding: .utf8)!
        check("ledger excludes raw request or credential data", !ledgerText.contains("https:") && !ledgerText.contains("not-exported") && !ledgerText.contains("profile") && !ledgerText.contains("query"))

        let interruptedID = UUID().uuidString
        _ = try reloaded.receive(requestID: interruptedID, fingerprint: hash, action: "portal.proposeSite", now: now)
        _ = try reloaded.approve(requestID: interruptedID, now: now)
        _ = try reloaded.beginExecution(requestID: interruptedID, now: now)
        _ = try reloaded.markAwaitingUser(requestID: interruptedID, now: now)
        let recovered = try PortalRequestLedger(directory: ledger.directory, now: now.addingTimeInterval(1), evidence: evidence)
        check("crash in editor never replays side effect", recovered.record(requestID: interruptedID)?.state == .failed && recovered.record(requestID: interruptedID)?.outcome.errorCode == "interrupted_execution")
        let again = try PortalRequestLedger(directory: ledger.directory, now: now.addingTimeInterval(2), evidence: evidence)
        check("crash recovery persisted", again.record(requestID: interruptedID)?.outcome.errorCode == "interrupted_execution")
        let cancelledID = UUID().uuidString
        _ = try again.receive(requestID: cancelledID, fingerprint: hash, action: "portal.focusSearch", now: now)
        _ = try again.cancel(requestID: cancelledID, now: now)
        rejects("cancelled request never executes", code: "invalid_request_transition") { _ = try again.approve(requestID: cancelledID, now: now) }
        let pendingID = UUID().uuidString
        _ = try again.receive(requestID: pendingID, fingerprint: hash, action: "portal.prepareDownload", now: now)
        _ = try again.approve(requestID: pendingID, now: now)
        _ = try again.beginExecution(requestID: pendingID, now: now)
        _ = try again.finish(requestID: pendingID, outcome: PortalActionOutcome(status: .pending, workflowState: .handedOff), now: now)
        check("downstream pending handoff not repeated", again.record(requestID: pendingID)?.state == .completed && again.record(requestID: pendingID)?.outcome.status == .pending)
        let unsafeID = UUID().uuidString
        _ = try again.receive(requestID: unsafeID, fingerprint: hash, action: "portal.focusSearch", now: now)
        rejects("error codes cannot carry URLs to journal", code: "invalid_request_transition") { _ = try again.fail(requestID: unsafeID, code: "https://private.example.test/?token=secret", now: now) }
        check("failed persistence does not advance memory", again.record(requestID: unsafeID)?.state == .received)
        check("ledger history includes only real records", again.allRecords.count == 5)
        let intact = try Data(contentsOf: ledger.file)
        try Data("{malformed".utf8).write(to: ledger.file)
        rejects("corrupt ledger not treated as empty", code: "invalid_request_ledger") { _ = try PortalRequestLedger(directory: ledger.directory, now: now, evidence: evidence) }
        check("corrupt ledger retained unchanged", try Data(contentsOf: ledger.file) == Data("{malformed".utf8))
        try intact.write(to: ledger.file)
        let symbolic = temporary.appendingPathComponent("symbolic")
        try FileManager.default.createSymbolicLink(at: symbolic, withDestinationURL: ledger.directory)
        rejects("ledger symlink directory rejected", code: "invalid_request_ledger") { _ = try PortalRequestLedger(directory: symbolic, now: now, evidence: evidence) }
        let hardLink = temporary.appendingPathComponent("hardlink")
        check("create isolated hardlink fixture", link(ledger.file.path, hardLink.path) == 0)
        rejects("hardlinked ledger rejected", code: "invalid_request_ledger") { _ = try PortalRequestLedger(directory: ledger.directory, now: now, evidence: evidence) }
        try FileManager.default.removeItem(at: hardLink)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: ledger.file.path)
        rejects("public ledger rejected", code: "invalid_request_ledger") { _ = try PortalRequestLedger(directory: ledger.directory, now: now, evidence: evidence) }

        let opened = PortalSiteOutcome(siteID: "seed-0", workflowState: .opened, errorCode: nil)
        let failed = PortalSiteOutcome(siteID: "seed-1", workflowState: .failed, errorCode: "browser_open_failed")
        let accepted = PortalSiteOutcome(siteID: "seed-2", workflowState: .accepted, errorCode: nil)
        let cancelled = PortalSiteOutcome(siteID: "seed-3", workflowState: .cancelled, errorCode: nil)
        check("actual mixed workspace failure partial", PortalActionOutcome.workspace([opened, failed]).status == .partial)
        check("all opened means browser handoff completed", PortalActionOutcome.workspace([opened]).workflowState == .opened)
        check("pending helper acceptance stays pending", PortalActionOutcome.workspace([accepted]).status == .pending)
        check("mixed helper and browser remains partial", PortalActionOutcome.workspace([opened, accepted]).status == .partial)
        check("all failures fail workspace", PortalActionOutcome.workspace([failed]).status == .failed)
        check("all auth cancellations cancel workspace", PortalActionOutcome.workspace([cancelled]).status == .cancelled)
        check("empty workspace not false success", PortalActionOutcome.workspace([]).status == .failed)
        print("Portal action tests passed: \(count)")
    }
}
