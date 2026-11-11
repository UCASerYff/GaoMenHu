import Foundation
import Darwin

@main struct DownloadHistoryIsolationTests {
    typealias H = PortalDownloadHistoryIsolation
    static var checks = 0
    static var stage = "startup"
    struct Injected: Error {}
    static func check(_ value: @autoclosure () throws -> Bool) throws { let valid = try value(); precondition(valid); checks += 1 }
    static func rejects(_ code: String? = nil, _ body: () throws -> Void) {
        do { try body(); fatalError("unsafe history operation accepted") }
        catch { if let code { precondition((error as? DownloadGaoActionPackageError)?.code == code) }; checks += 1 }
    }
    final class Defaults: PortalDownloadMigrationDefaults {
        var values: [String: Any] = [:]
        var failCommit = false
        func object(forKey key: String) -> Any? { values[key] }
        func data(forKey key: String) -> Data? { values[key] as? Data }
        func set(_ value: Any?, forKey key: String) { values[key] = value }
        func synchronize() -> Bool {
            if failCommit {
                for (key, value) in values where key.hasPrefix(H.evidencePrefix) {
                    if let raw = value as? Data, let fields = try? JSONSerialization.jsonObject(with: raw) as? [String: Any], fields["phase"] as? String == "committed" { return false }
                }
            }
            return true
        }
    }
    final class Evidence: DownloadGaoExchangeEvidence {
        var raw: Data?
        func load() throws -> Data? { raw }
        func save(_ value: Data) throws { raw = value }
    }
    static func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
    static func object<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: H.encoded(value)) }
    static func write(_ bytes: Data, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try bytes.write(to: url); guard chmod(url.path, 0o600) == 0 else { throw Injected() }
    }
    final class Fixture {
        let root: URL, source: URL, target: URL
        let defaults = Defaults(), evidence = Evidence()
        let jobID = UUID(), itemID = UUID(), grantID = UUID(), completeID = UUID()
        var preferences = Data(), requests: [DownloadGaoExchangeRecord] = []
        init(cancelStage: String = "cancelled", cancelTask: Bool = false) throws {
            DownloadHistoryIsolationTests.stage = "fixture-directories"
            root = URL(fileURLWithPath: "/private/tmp/portal-history-\(UUID().uuidString).noindex")
            source = root.appendingPathComponent("Legacy/GaoXiaZai"); target = root.appendingPathComponent("MenDao/DownloadCenter")
            for path in [root, source.deletingLastPathComponent(), target.deletingLastPathComponent()] {
                try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
            let payload = Data("finished".utf8), now = Date(), url = "https://example.invalid/history.bin"
            do {
                DownloadHistoryIsolationTests.stage = "fixture-source-store"
                let store = try DownloadStore(root: source); var database = try store.load()
                database.jobs = [DownloadJob(id: jobID, requestID: completeID, itemIDs: [itemID], createdAt: now)]
                database.destinations = [DestinationGrant(id: grantID, displayPath: "/synthetic/external-do-not-open", bookmark: Data([1]), device: 1, inode: 2, volumeUUID: "synthetic")]
                database.items = [DownloadItem(id: itemID, jobID: jobID, destinationID: grantID, state: .completed,
                    sourceURL: url, sourceFingerprint: downloadDigest(Data(url.utf8)), displayURL: url, suggestedName: "history.bin",
                    bytesReceived: 8, expectedBytes: 8, bytesPerSecond: 0, sha256: downloadDigest(payload), errorMessage: nil,
                    retryAt: nil, artifact: PublishedArtifact(fileName: "history.bin", byteCount: 8, sha256: downloadDigest(payload), device: 1, inode: 3), createdAt: now,
                    stagingName: itemID.uuidString + ".part")]
                try store.save(database)
                try DownloadHistoryIsolationTests.write(try Data(contentsOf: source.appendingPathComponent("downloads.json")), source.appendingPathComponent("downloads.previous.json"))
            }
            let exchange = source.appendingPathComponent("Exchange")
            DownloadHistoryIsolationTests.stage = "fixture-journal-initialize"
            let journal = try DownloadGaoExchangeJournal(directory: exchange, evidence: evidence, historyDefaults: defaults)
            for name in ["Incoming", "Outgoing"] {
                try FileManager.default.createDirectory(at: exchange.appendingPathComponent(name), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
            for index in 0..<5 {
                let completed = index == 4, requestID = completed ? completeID : UUID()
                let request = DownloadGaoActionManifest(kind: "request", requestID: requestID.uuidString.lowercased(),
                    sourceBundleID: "com.synthetic.Caller", targetBundleID: "com.gaoseries.GaoXiaZai", action: "downloads.prepare",
                    createdAt: DownloadGaoActionPackage.iso8601(now), expiresAt: DownloadGaoActionPackage.iso8601(now.addingTimeInterval(120)),
                    nonce: try DownloadGaoActionPackage.randomNonce(), items: [], references: [], parameters: ["urls": .array([.string(url)])])
                let tasks = completed ? [jobID] : (cancelTask && index == 0 ? [UUID()] : [])
                let ids = completed ? [itemID] : []
                var result = DownloadGaoActionManifest(kind: "result", requestID: UUID().uuidString.lowercased(),
                    sourceBundleID: "com.gaoseries.GaoXiaZai", targetBundleID: "com.synthetic.Caller", action: "downloads.prepare",
                    createdAt: request.createdAt, expiresAt: request.expiresAt, nonce: try DownloadGaoActionPackage.randomNonce(),
                    items: completed ? [DownloadGaoActionItem(id: itemID.uuidString.lowercased(), relativePath: "payload/result.bin", uti: "public.data", byteCount: 8, sha256: downloadDigest(payload))] : [], references: [], parameters: [:])
                result.status = completed ? "completed" : cancelStage; result.inReplyTo = requestID.uuidString.lowercased()
                result.provenance = ["workflowState": .string(result.status!), "taskIDs": .array(tasks.map { .string($0.uuidString.lowercased()) })]
                let requestRaw = try DownloadGaoActionPackage.manifestData(request), resultRaw = try DownloadGaoActionPackage.manifestData(result)
                let delivery = DownloadGaoResultDelivery(packageName: result.requestID + ".gaoaction", manifest: result,
                    fingerprint: downloadDigest(resultRaw), attempts: 0, handedOffAt: nil, lastError: nil)
                let record = DownloadGaoExchangeRecord(id: requestID, sourceBundleID: request.sourceBundleID,
                    urls: [url], receivedAt: now, stage: completed ? "completed" : cancelStage, taskIDs: tasks,
                    outgoingURLs: [exchange.appendingPathComponent("Outgoing", isDirectory: true).appendingPathComponent(delivery.packageName, isDirectory: true)], hasFinalResult: true,
                    itemIDs: ids, outcomes: [], deliveries: [delivery], manifest: request, manifestSHA256: downloadDigest(requestRaw), packageName: request.requestID + ".gaoaction")
                DownloadHistoryIsolationTests.stage = "fixture-journal-append-\(index)"
                try journal.append(record); requests.append(record)
                if completed {
                    DownloadHistoryIsolationTests.stage = "fixture-complete-packages"
                    try DownloadHistoryIsolationTests.write(requestRaw, exchange.appendingPathComponent("Incoming/" + record.packageName + "/manifest.json"))
                    try FileManager.default.createDirectory(at: exchange.appendingPathComponent("Incoming/" + record.packageName + "/payload"), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                    try DownloadHistoryIsolationTests.write(resultRaw, exchange.appendingPathComponent("Outgoing/" + delivery.packageName + "/manifest.json"))
                    try DownloadHistoryIsolationTests.write(payload, exchange.appendingPathComponent("Outgoing/" + delivery.packageName + "/payload/result.bin"))
                }
            }
            preferences = try PropertyListSerialization.data(fromPropertyList: [PortalDownloadMigration.exchangeKey(directory: exchange, legacy: true): evidence.raw!, "synthetic.full.preference": true], format: .binary, options: 0)
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        func plan() throws -> H.Plan {
            DownloadHistoryIsolationTests.stage = "fixture-source-plan-known-schema"
            return try H.preflight(legacyRootURL: source, sourcePreferences: preferences)
        }
    }
    struct Proofs {
        let authority: H.Authority, snapshot: Data, human: Data, fence: Data, backup: Data
        let factSHA: String, snapshotSHA: String
        init(_ f: Fixture) throws {
            let plan = try f.plan(), planSHA = downloadDigest(try H.encoded(plan)), ref = "synthetic-human-approval"
            DownloadHistoryIsolationTests.stage = "fixture-private-proofs"
            snapshot = try DownloadHistoryIsolationTests.json(["schemaVersion": 1, "operation": H.operation, "authorizationReference": ref,
                "sourceJournalSHA256": plan.sourceJournalSHA256, "sourceRecordCount": 5,
                "exactApprovedRecords": try DownloadHistoryIsolationTests.object(plan.exactApprovedRecords), "remainingCompletedRecords": 1])
            snapshotSHA = downloadDigest(snapshot)
            let snapshotURL = f.root.appendingPathComponent("approved.json"); try DownloadHistoryIsolationTests.write(snapshot, snapshotURL)
            let fact = try DownloadHistoryIsolationTests.json(["schemaVersion": 1, "kind": "GaoSeriesHumanExplicitScopeAuthorization", "operation": "downloads-quarantine-missing-history",
                "questionCall": ref, "sourceBundleID": "com.gaoseries.GaoXiaZai", "targetBundleID": "cn.mendao.launcher",
                "approvedMissingHistorySnapshot": snapshotURL.path, "approvedMissingHistorySnapshotSHA256": snapshotSHA,
                "approvedProposalSHA256": String(repeating: "c", count: 64), "sourceFullyVerified": false,
                "expectedOutcome": "committed_with_quarantined_missing_history", "doesNotCertifyWritersFrozenOrBackupsOrCurrentSourceEquality": true])
            factSHA = downloadDigest(fact); let factURL = f.root.appendingPathComponent("human-fact.json"); try DownloadHistoryIsolationTests.write(fact, factURL)
            human = try H.encoded(H.HumanAuthorization(schemaVersion: 2, operation: H.operation, authorizationReference: ref, approved: true,
                actualHumanAuthorizationFactPath: factURL.path, actualHumanAuthorizationFactSHA256: factSHA,
                approvedSnapshotSHA256: snapshotSHA, planSHA256: planSHA, exactApprovedRecords: plan.exactApprovedRecords))
            let actualFence = try DownloadHistoryIsolationTests.json(["kind": "fenced-observed", "transactionID": UUID().uuidString,
                "previousSHA256": String(repeating: "a", count: 64), "sourceBundleIDs": ["com.gaoseries.GaoXiaZai", "com.gaoseries.GaoYouJian"],
                "sourceDataRoots": ["download": f.source.path], "targetDataRoots": ["download": f.target.path],
                "sourceFrozenAtThisObservation": true, "sourceFormalApplicationAbsentOrIsolated": true,
                "noSourceWriterObserved": true, "leaseMustRemainOwned": true, "backupVerified": false, "migrationApplied": false])
            let fenceURL = f.root.appendingPathComponent("actual-fence.json"); try DownloadHistoryIsolationTests.write(actualFence, fenceURL)
            let fenceSHA = downloadDigest(actualFence)
            fence = try H.encoded(H.FenceReceipt(schemaVersion: 2, operation: H.operation, receiptKind: "actual-writer-fence",
                sourceRoot: f.source.path, targetRoot: f.target.path, frozen: true, actualWriterFence: true,
                evidenceSHA256: fenceSHA, actualFenceReceiptPath: fenceURL.path, actualFenceReceiptSHA256: fenceSHA))
            backup = try DownloadHistoryIsolationTests.json(["kind": "synthetic-complete-restore-proof", "restoredBytesVerified": true])
            authority = H.Authority(schemaVersion: 2, operation: H.operation, sourceBundleID: "com.gaoseries.GaoXiaZai", targetBundleID: "cn.mendao.launcher",
                sourceRoot: f.source.path, targetRoot: f.target.path, sourceFrozen: true, planSHA256: planSHA,
                approvedSnapshotSHA256: snapshotSHA, humanAuthorizationSHA256: downloadDigest(human), fenceReceiptSHA256: downloadDigest(fence),
                backupReceiptSHA256: downloadDigest(backup), exactApprovedRecords: plan.exactApprovedRecords)
        }
        func apply(_ f: Fixture, trustedSnapshot: String? = nil, trustedFact: String? = nil,
                   humanOverride: Data? = nil, fenceOverride: Data? = nil,
                   maintenance: () throws -> Void = {}, fault: ((String) throws -> Void)? = nil) throws -> H.Receipt {
            var fields = try JSONSerialization.jsonObject(with: H.encoded(authority)) as! [String: Any]
            fields["humanAuthorizationSHA256"] = downloadDigest(humanOverride ?? human)
            fields["fenceReceiptSHA256"] = downloadDigest(fenceOverride ?? fence)
            let rebound = try JSONDecoder().decode(H.Authority.self, from: DownloadHistoryIsolationTests.json(fields))
            DownloadHistoryIsolationTests.stage = "fixture-apply-authority"
            return try H.prepare(destinationRootURL: f.target, legacyRootURL: f.source, sourcePreferences: f.preferences,
                authority: rebound, approvedSnapshot: snapshot, humanAuthorization: humanOverride ?? human, fenceReceipt: fenceOverride ?? fence, backupReceipt: backup,
                trustedApprovedSnapshotSHA256: trustedSnapshot ?? snapshotSHA, trustedHumanAuthorizationFactSHA256: trustedFact ?? factSHA,
                targetDefaults: f.defaults, maintenanceGuard: maintenance, fault: { checkpoint in
                    DownloadHistoryIsolationTests.stage = checkpoint
                    try fault?(checkpoint)
                })
        }
    }
    static func run() throws {
        do {
            let f = try Fixture(), p = try Proofs(f), before = try PortalDownloadMigration.tree(f.source)
            try check(try f.plan().exactApprovedRecords.count == 4)
            let plist = try PropertyListSerialization.propertyList(from: f.preferences, options: [], format: nil) as! [String: Any]
            let old = plist.compactMapValues { $0 as? Data }
            rejects { _ = try PortalDownloadMigration.preflight(legacyRootURL: f.source, sourcePreferences: old) }
            rejects { _ = try p.apply(f, trustedSnapshot: String(repeating: "f", count: 64)) }
            rejects { _ = try p.apply(f, trustedFact: String(repeating: "f", count: 64)) }
            var humanNumber = try JSONSerialization.jsonObject(with: p.human) as! [String: Any]
            humanNumber["approved"] = 1
            rejects { _ = try p.apply(f, humanOverride: json(humanNumber)) }
            humanNumber = try JSONSerialization.jsonObject(with: p.human) as! [String: Any]
            humanNumber["actualHumanAuthorizationFactPath"] = "relative/private.json"
            rejects { _ = try p.apply(f, humanOverride: json(humanNumber)) }
            var fenceMissing = try JSONSerialization.jsonObject(with: p.fence) as! [String: Any]
            fenceMissing["actualFenceReceiptPath"] = f.root.appendingPathComponent("missing-fence.json").path
            rejects { _ = try p.apply(f, fenceOverride: json(fenceMissing)) }
            rejects { _ = try p.apply(f, maintenance: { throw Injected() }) }
            try check(!FileManager.default.fileExists(atPath: f.target.path))
            var guards = 0
            let receipt = try p.apply(f, maintenance: { guards += 1 })
            try check(guards >= 3)
            try check(!receipt.sourceFullyVerified && !receipt.quarantinedPackageIntegrityVerified && receipt.ledgerDigestVerified)
            try check(receipt.plan.taskIDs == [f.jobID] && receipt.plan.itemIDs == [f.itemID] && receipt.plan.grantIDs == [f.grantID])
            try check(try PortalDownloadMigration.tree(f.source) == before)
            try H.verifyPreservedFiles(destinationRootURL: f.target, targetDefaults: f.defaults); checks += 1
            try check(!FileManager.default.fileExists(atPath: f.target.appendingPathComponent("downloads.previous.json").path))
            let history = f.target.appendingPathComponent(receipt.historyRelativePath)
            try check(!FileManager.default.fileExists(atPath: history.appendingPathComponent("OriginalFiles/downloads.previous.json").path))
            try check(try Data(contentsOf: history.appendingPathComponent("source-preferences.plist")) == f.preferences)
            try check(try Data(contentsOf: history.appendingPathComponent("OriginalFiles/Exchange/journal.json")) == Data(contentsOf: f.source.appendingPathComponent("Exchange/journal.json")))
            try check(try H.readHistory(destinationRootURL: f.target, targetDefaults: f.defaults).count == 4)
            try check(H.readiness(destinationRootURL: f.target, targetDefaults: f.defaults) == .ready)
            for record in f.requests {
                rejects("history_identity_reserved") { try H.guardNewRequest(root: f.target, requestID: record.id.uuidString, targetDefaults: f.defaults) }
                rejects("history_identity_reserved") { try H.guardNewRequest(root: f.target, requestID: UUID().uuidString, nonce: record.manifest.nonce, targetDefaults: f.defaults) }
            }
            try H.guardNewRequest(root: f.target, requestID: UUID().uuidString, nonce: "synthetic-new-nonce", targetDefaults: f.defaults); checks += 1
            let exchange = f.target.appendingPathComponent("Exchange")
            let evidence = f.defaults.data(forKey: PortalDownloadMigration.exchangeKey(directory: exchange))!
            let records = try DownloadGaoExchangeJournal.validateHistoricalSnapshot(Data(contentsOf: exchange.appendingPathComponent("journal.json")), evidence: evidence, directory: exchange)
            try check(records.count == 1 && records[0].id == f.completeID && records[0].isLegacyHistory)
            do {
                let mutableEvidence = Evidence(); mutableEvidence.raw = evidence
                let journal = try DownloadGaoExchangeJournal(directory: exchange, evidence: mutableEvidence, historyDefaults: f.defaults)
                var request = f.requests[0].manifest
                request.requestID = UUID().uuidString.lowercased(); request.targetBundleID = "cn.mendao.launcher"
                request.nonce = try DownloadGaoActionPackage.randomNonce()
                var fresh = DownloadGaoExchangeRecord(id: UUID(uuidString: request.requestID)!, sourceBundleID: request.sourceBundleID,
                    urls: f.requests[0].urls, receivedAt: Date(), stage: "awaitingReview", taskIDs: [], outgoingURLs: [], hasFinalResult: false,
                    manifest: request, manifestSHA256: downloadDigest(try DownloadGaoActionPackage.manifestData(request)), packageName: request.requestID + ".gaoaction")
                try journal.append(fresh); checks += 1
                fresh.manifest.nonce = f.requests[0].manifest.nonce
                rejects("history_identity_reserved") { try journal.replace(fresh) }
            }
            try check(try p.apply(f) == receipt)
            // Removing retired source data does not affect current history or its reject-only index.
            try FileManager.default.removeItem(at: f.source)
            try check(try H.readHistory(destinationRootURL: f.target, targetDefaults: f.defaults).count == 4)
            try H.verifyPreservedFiles(destinationRootURL: f.target, targetDefaults: f.defaults); checks += 1
            f.defaults.values.removeValue(forKey: H.evidenceKey(root: f.target))
            try FileManager.default.removeItem(at: H.markerURL(root: f.target))
            try FileManager.default.removeItem(at: H.completionURL(root: f.target))
            try FileManager.default.removeItem(at: f.target.appendingPathComponent(H.receiptPath))
            rejects("exchange_recovery_required") { _ = try H.readHistory(destinationRootURL: f.target, targetDefaults: f.defaults) }
        }
        for mode in ["fifth-missing", "symlink", "permissions", "cancel-has-task", "failed-state", "unknown-journal", "unknown-database", "fifo"] {
            let f = try Fixture(cancelStage: mode == "failed-state" ? "failed" : "cancelled", cancelTask: mode == "cancel-has-task")
            let complete = f.source.appendingPathComponent("Exchange/Incoming/" + f.requests[4].packageName)
            if mode == "fifth-missing" { try FileManager.default.removeItem(at: complete) }
            if mode == "symlink" { try FileManager.default.createSymbolicLink(atPath: f.source.appendingPathComponent("extra-link").path, withDestinationPath: "/synthetic/do-not-read") }
            if mode == "permissions" { guard chmod(f.source.appendingPathComponent("downloads.json").path, 0o644) == 0 else { throw Injected() } }
            if mode == "fifo" { guard mkfifo(f.source.appendingPathComponent("unexpected-fifo").path, 0o600) == 0 else { throw Injected() } }
            if mode == "unknown-journal" {
                let path = f.source.appendingPathComponent("Exchange/journal.json")
                var value = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
                var records = value["records"] as! [[String: Any]]; records[0]["unknownAuthority"] = true; value["records"] = records
                let raw = try DownloadHistoryIsolationTests.json(value); try DownloadHistoryIsolationTests.write(raw, path)
                var evidence = try JSONSerialization.jsonObject(with: f.evidence.raw!) as! [String: Any]
                evidence["digest"] = downloadDigest(raw); f.evidence.raw = try DownloadHistoryIsolationTests.json(evidence)
                var domain = try PropertyListSerialization.propertyList(from: f.preferences, options: [], format: nil) as! [String: Any]
                domain[PortalDownloadMigration.exchangeKey(directory: f.source.appendingPathComponent("Exchange"), legacy: true)] = f.evidence.raw!
                f.preferences = try PropertyListSerialization.data(fromPropertyList: domain, format: .binary, options: 0)
            }
            if mode == "unknown-database" {
                let path = f.source.appendingPathComponent("downloads.json")
                let envelope = try JSONDecoder().decode(PortalDownloadMigration.DatabaseEnvelope.self, from: Data(contentsOf: path))
                var value = try JSONSerialization.jsonObject(with: envelope.payload) as! [String: Any]; value["unknownAuthority"] = true
                let payload = try DownloadHistoryIsolationTests.json(value)
                try DownloadHistoryIsolationTests.write(H.encoded(PortalDownloadMigration.DatabaseEnvelope(payload: payload, sha256: downloadDigest(payload))), path)
            }
            rejects { _ = try f.plan() }
        }
        for point in ["isolation.preparing", "isolation.validated", "isolation.rootPublished", "isolation.evidencePublished", "isolation.committedSaved"] {
            let f = try Fixture(), p = try Proofs(f)
            rejects { _ = try p.apply(f, fault: { if $0 == point { throw Injected() } }) }
            if case .recoveryRequired = H.readiness(destinationRootURL: f.target, targetDefaults: f.defaults) { checks += 1 } else { fatalError("pending isolation became ready") }
            if point == "isolation.preparing" { rejects { _ = try p.apply(f) } }
            else { _ = try p.apply(f); try check(H.readiness(destinationRootURL: f.target, targetDefaults: f.defaults) == .ready) }
        }
        do {
            let f = try Fixture(), p = try Proofs(f); f.defaults.failCommit = true
            rejects { _ = try p.apply(f) }
            try check(!FileManager.default.fileExists(atPath: H.completionURL(root: f.target).path))
            if case .recoveryRequired = H.readiness(destinationRootURL: f.target, targetDefaults: f.defaults) { checks += 1 } else { fatalError("failed final sync became ready") }
            f.defaults.failCommit = false; _ = try p.apply(f)
            try check(H.readiness(destinationRootURL: f.target, targetDefaults: f.defaults) == .ready)
        }
        rejects { _ = try H.recordURL("relative/private.json") }
        rejects { _ = try H.recordURL("/private/tmp/../unsafe.json") }
        print("Download history isolation: \(checks) targeted checks passed (synthetic only)")
    }
    static func main() {
        do { try run() } catch {
            fputs("Synthetic history isolation failed after \(checks) checks; stage=\(stage); type=\(type(of: error)); synthetic-detail=\(error.localizedDescription).\n", stderr)
            exit(1)
        }
    }
}
