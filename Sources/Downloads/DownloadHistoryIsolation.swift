import Foundation
import Darwin
import CoreFoundation

/// Explicitly approved exceptional migration. Missing packages remain missing,
/// outside the live Exchange. No API in this type starts transfers or reads grants.
enum PortalDownloadHistoryIsolation {
    typealias M = PortalDownloadMigration
    static let operation = "download.migrate-with-cancelled-history-isolation.v1"
    static let evidencePrefix = "GaoMenHu.DownloadHistoryIsolation."
    static let receiptPath = "MigrationEvidence/receipt.json"
    struct DeliveryPin: Codable, Equatable {
        let packageName: String
        let fingerprint: String
        let status: String
    }
    struct RecordPin: Codable, Equatable {
        let recordID: UUID
        let stage: String
        let requestManifestSHA256: String
        let nonceSHA256: String
        let packageName: String
        let missingRelativePackages: [String]
        let deliveries: [DeliveryPin]
    }
    struct Entry: Identifiable, Codable, Equatable {
        let id: UUID
        let sourceBundleID: String
        let receivedAt: Date
        let requestManifestSHA256: String
        let missingPackages: [String]
        let originalStage: String
    }
    struct Plan: Codable, Equatable {
        let schemaVersion: Int
        let operation: String
        let sourceRoot: String
        let sourceManifestSHA256: String
        let sourceMarkerSHA256: String
        let sourcePreferencesSHA256: String
        let sourceJournalSHA256: String
        let sourceExchangeEvidenceSHA256: String
        let sourceInstallationID: UUID
        let exactApprovedRecords: [RecordPin]
        let verifiedCompleteRecordIDs: [UUID]
        let taskIDs: [UUID]
        let itemIDs: [UUID]
        let grantIDs: [UUID]
        let sourceFullyVerified: Bool
    }
    struct Authority: Codable, Equatable {
        let schemaVersion: Int
        let operation: String
        let sourceBundleID: String
        let targetBundleID: String
        let sourceRoot: String
        let targetRoot: String
        let sourceFrozen: Bool
        let planSHA256: String
        let approvedSnapshotSHA256: String
        let humanAuthorizationSHA256: String
        let fenceReceiptSHA256: String
        let backupReceiptSHA256: String
        let exactApprovedRecords: [RecordPin]
    }
    struct HumanAuthorization: Codable {
        let schemaVersion: Int
        let operation: String
        let authorizationReference: String
        let approved: Bool
        let actualHumanAuthorizationFactPath: String
        let actualHumanAuthorizationFactSHA256: String
        let approvedSnapshotSHA256: String
        let planSHA256: String
        let exactApprovedRecords: [RecordPin]
    }
    private struct HumanFact: Codable {
        let schemaVersion: Int
        let kind: String
        let operation: String
        let questionCall: String
        let sourceBundleID: String
        let targetBundleID: String
        let approvedMissingHistorySnapshot: String
        let approvedMissingHistorySnapshotSHA256: String
        let approvedProposalSHA256: String
        let sourceFullyVerified: Bool
        let expectedOutcome: String
        let doesNotCertifyWritersFrozenOrBackupsOrCurrentSourceEquality: Bool
    }
    struct ApprovedSnapshot: Codable {
        let schemaVersion: Int
        let operation: String
        let authorizationReference: String
        let sourceJournalSHA256: String
        let sourceRecordCount: Int
        let exactApprovedRecords: [RecordPin]
        let remainingCompletedRecords: Int
    }
    struct FenceReceipt: Codable {
        let schemaVersion: Int
        let operation: String
        let receiptKind: String
        let sourceRoot: String
        let targetRoot: String
        let frozen: Bool
        let actualWriterFence: Bool
        let evidenceSHA256: String
        let actualFenceReceiptPath: String
        let actualFenceReceiptSHA256: String
    }
    struct Receipt: Codable, Equatable {
        let schemaVersion: Int
        let operation: String
        let migrationID: UUID
        let sourceRoot: String
        let targetRoot: String
        let sourceInstallationID: UUID
        let migrationCommitted: Bool
        let verificationStatus: String
        let sourceFullyVerified: Bool
        let plan: Plan
        let authoritySHA256: String
        let approvedSnapshotSHA256: String
        let humanAuthorizationSHA256: String
        let fenceReceiptSHA256: String
        let backupReceiptSHA256: String
        let historyRelativePath: String
        let sourceFiles: M.Tree
        let sourceMarkerRelativePath: String
        let historyManifestSHA256: String
        let entriesSHA256: String
        let reservedIdentitiesSHA256: String
        let ledgerDigestVerified: Bool
        let quarantinedPackageIntegrityVerified: Bool
        let grantsRequireNewHostAuthorization: Bool
        let importedAt: Date
    }
    private struct Identities: Codable {
        let schemaVersion: Int
        let operation: String
        let requestAndResultIDs: [UUID]
        let nonceSHA256: [String]
    }
    private struct State: Codable {
        let schemaVersion: Int
        let operation: String
        let migrationID: UUID
        let sourceRoot: String
        let targetRoot: String
        let authoritySHA256: String
        var phase: String
        var sourceTree: M.Tree?
        var targetTree: M.Tree?
        var marker: Data?
        var exchangeEvidence: Data?
        var receiptSHA256: String?
    }
    private struct Current {
        let receipt: Receipt
        let entries: [Entry]
        let identities: Identities
    }
    private final class Snapshot {
        let source: URL
        let store: DownloadStore
        let lock: Int32
        let database: DownloadDatabase
        let tree: M.Tree
        let marker: Data
        let preferences: Data
        let journal: Data
        let evidence: Data
        let records: [DownloadGaoExchangeRecord]
        let plan: Plan
        init(source: URL, store: DownloadStore, lock: Int32, database: DownloadDatabase, tree: M.Tree,
             marker: Data, preferences: Data, journal: Data, evidence: Data,
             records: [DownloadGaoExchangeRecord], plan: Plan) {
            self.source = source; self.store = store; self.lock = lock; self.database = database
            self.tree = tree; self.marker = marker; self.preferences = preferences; self.journal = journal
            self.evidence = evidence; self.records = records; self.plan = plan
        }
        deinit { close(lock) }
    }
    static func evidenceKey(root: URL) -> String { evidencePrefix + downloadDigest(Data(root.path.utf8)) }
    static func markerURL(root: URL) -> URL { root.deletingLastPathComponent().appendingPathComponent(".\(root.lastPathComponent).history-isolation-v2.json") }
    static func completionURL(root: URL) -> URL { root.deletingLastPathComponent().appendingPathComponent(".\(root.lastPathComponent).history-isolation-complete-v2.json") }
    private static func bad() -> DownloadGaoActionPackageError {
        DownloadGaoActionPackageError("exchange_recovery_required", "缺件历史的独立依据、资料或迁移事务不可读，已停止授权和交换；不会补造或重放历史。")
    }
    static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    static func recordURL(_ path: String) throws -> URL {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.hasPrefix("/"), path.utf8.count <= 16_384, parts.count > 1,
              parts.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw bad() }
        return URL(fileURLWithPath: path)
    }
    private static func validHash(_ value: String) -> Bool { value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil }
    private static func ordered(_ records: [RecordPin]) -> [RecordPin] { records.sorted { $0.recordID.uuidString < $1.recordID.uuidString } }
    private static func matching(_ a: [RecordPin], _ b: [RecordPin]) -> Bool { a.count == 4 && ordered(a) == ordered(b) && Set(a.map(\.recordID)).count == 4 }
    private static func boolean(_ raw: Data, key: String, equals expected: Bool) throws {
        guard let object = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let value = object[key] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID(), value.boolValue == expected else { throw bad() }
    }

    /// Safe bounded input for CLI records; also pins the named object and its physical parent.
    static func readRecord(_ url: URL, limit: Int = 32 * 1024 * 1024) throws -> Data {
        let physical = try M.physicalRoot(url)
        let parent = try openDirectoryNoLinks(physical.deletingLastPathComponent()); defer { close(parent) }
        let p = try statIdentity(parent)
        let fd = openat(parent, physical.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw bad() }; defer { close(fd) }
        let before = try statIdentity(fd)
        guard regularOwned(before), before.st_mode & 0o077 == 0, before.st_size >= 0, before.st_size <= Int64(limit) else { throw bad() }
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0, bytes.count + max(count, 0) <= limit else { throw bad() }
            if count == 0 { break }; bytes.append(contentsOf: buffer.prefix(count))
        }
        let after = try statIdentity(fd); var atPath = stat()
        let reopened = try openDirectoryNoLinks(physical.deletingLastPathComponent()); defer { close(reopened) }
        let currentParent = try statIdentity(reopened)
        guard regularOwned(after), after.st_mode & 0o077 == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, Int64(bytes.count) == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              fstatat(parent, physical.lastPathComponent, &atPath, AT_SYMLINK_NOFOLLOW) == 0,
              atPath.st_dev == after.st_dev, atPath.st_ino == after.st_ino,
              p.st_dev == currentParent.st_dev, p.st_ino == currentParent.st_ino else { throw bad() }
        return bytes
    }
    private static func missing(_ url: URL) throws -> Bool {
        let fd = try openDirectoryNoLinks(url.deletingLastPathComponent()); defer { close(fd) }
        try M.requirePrivateDirectory(fd)
        var value = stat()
        if fstatat(fd, url.lastPathComponent, &value, AT_SYMLINK_NOFOLLOW) == 0 {
            guard value.st_mode & S_IFMT == S_IFDIR, value.st_uid == getuid(), value.st_mode & 0o077 == 0 else { throw bad() }
            return false
        }
        guard errno == ENOENT else { throw bad() }; return true
    }
    private static func fields(_ value: Any, _ allowed: String) throws -> [String: Any] {
        guard let object = value as? [String: Any], Set(object.keys).isSubset(of: Set(allowed.split(separator: ",").map(String.init))) else { throw bad() }
        return object
    }
    private static func knownDatabase(_ raw: Data, marker: Data) throws {
        _ = try fields(JSONSerialization.jsonObject(with: marker), "schemaVersion,installationID")
        _ = try fields(JSONSerialization.jsonObject(with: raw), "payload,sha256")
        let envelope = try JSONDecoder().decode(M.DatabaseEnvelope.self, from: raw)
        let db = try fields(JSONSerialization.jsonObject(with: envelope.payload), "schemaVersion,revision,installationID,migrationHistory,items,jobs,destinations,settings")
        let lists = [
            "jobs": "id,requestID,itemIDs,createdAt",
            "destinations": "id,displayPath,bookmark,device,inode,volumeUUID,requiresReauthorization",
            "items": "id,jobID,destinationID,state,sourceURL,sourceFingerprint,displayURL,suggestedName,bytesReceived,expectedBytes,bytesPerSecond,sha256,errorMessage,errorCategory,retryAt,artifact,createdAt,etag,lastModified,attempts,resumeExplanation,stagingName,stagingDevice,stagingInode,pendingArtifact,partialSHA256"]
        for (key, allowed) in lists {
            guard let values = db[key] as? [[String: Any]] else { throw bad() }
            for value in values {
                _ = try fields(value, allowed)
                if key == "items" {
                    for name in ["artifact", "pendingArtifact"] {
                        if let item = value[name], !(item is NSNull) { _ = try fields(item, "fileName,byteCount,sha256,device,inode") }
                    }
                }
            }
        }
        guard let settings = db["settings"] else { throw bad() }
        _ = try fields(settings, "concurrency,speedLimitBytesPerSecond,maxItemBytes,maxStagingBytes,appearance")
    }
    private static func knownJournal(_ raw: Data) throws {
        let envelope = try fields(JSONSerialization.jsonObject(with: raw), "schemaVersion,identity,generation,records")
        guard let records = envelope["records"] as? [[String: Any]] else { throw bad() }
        func manifest(_ value: Any) throws {
            let m = try fields(value, "schemaVersion,kind,requestID,sourceBundleID,targetBundleID,action,createdAt,expiresAt,nonce,items,references,parameters,inReplyTo,status,errorCode,provenance")
            guard let items = m["items"] as? [[String: Any]] else { throw bad() }
            for item in items { _ = try fields(item, "id,relativePath,uti,byteCount,sha256") }
        }
        for record in records {
            _ = try fields(record, "id,sourceBundleID,urls,receivedAt,stage,taskIDs,outgoingURLs,hasFinalResult,itemIDs,outcomes,deliveries,manifest,manifestSHA256,packageName")
            guard let request = record["manifest"], let deliveries = record["deliveries"] as? [[String: Any]],
                  let outcomes = record["outcomes"] as? [[String: Any]] else { throw bad() }
            try manifest(request)
            for delivery in deliveries {
                _ = try fields(delivery, "packageName,manifest,fingerprint,attempts,handedOffAt,lastError")
                guard let result = delivery["manifest"] else { throw bad() }; try manifest(result)
            }
            for outcome in outcomes { _ = try fields(outcome, "taskID,itemID,state,artifactItemID,byteCount,sha256,errorCode") }
        }
    }
    private static func snapshot(_ legacy: URL, preferences: Data) throws -> Snapshot {
        guard preferences.count > 0, preferences.count <= 32 * 1024 * 1024,
              let domain = try PropertyListSerialization.propertyList(from: preferences, options: [], format: nil) as? [String: Any] else { throw bad() }
        let source = try M.physicalRoot(legacy)
        guard !(try M.exists(source.appendingPathComponent("ReadOnlyHistory"))), !(try M.exists(source.appendingPathComponent("MigrationEvidence"))) else { throw bad() }
        let store = try DownloadStore(root: source, readOnly: true), database = try store.load()
        let marker = try readRecord(M.markerURL(source), limit: 4096)
        try knownDatabase(readRecord(source.appendingPathComponent("downloads.json")), marker: marker)
        if try M.exists(source.appendingPathComponent("downloads.previous.json")) {
            let previous = try readRecord(source.appendingPathComponent("downloads.previous.json"))
            try knownDatabase(previous, marker: marker)
            _ = try DownloadStore.validateSnapshot(previous, marker: marker)
        }
        let exchange = source.appendingPathComponent("Exchange", isDirectory: true)
        let key = M.exchangeKey(directory: exchange, legacy: true)
        let filtered = domain.filter { $0.key.hasPrefix(M.legacyExchangeEvidencePrefix) }
        guard Set(filtered.keys) == [key], let evidence = filtered[key] as? Data else { throw bad() }
        let exchangeFD = try openDirectoryNoLinks(exchange); defer { close(exchangeFD) }; try M.requirePrivateDirectory(exchangeFD)
        let lock = openat(exchangeFD, "journal.lock", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard lock >= 0 else { throw bad() }
        do {
            guard regularOwned(try statIdentity(lock)), flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw bad() }
            let journal = try readRecord(exchange.appendingPathComponent("journal.json"), limit: 16 * 1024 * 1024)
            try knownJournal(journal)
            let records = try DownloadGaoExchangeJournal.validateHistoricalSnapshot(journal, evidence: evidence, directory: exchange)
            guard records.count == 5, database.jobs.count == 1, database.items.count == 1, database.destinations.count == 1,
                  records.allSatisfy({ $0.manifest.targetBundleID == DownloadGaoDownloadContract.legacyBundleID }) else { throw bad() }
            try M.validateMappings(records, database: database)
            let initialTree = try M.tree(source)
            guard !initialTree.directories.contains(where: { $0.hasSuffix(".app") }) else { throw bad() }
            var isolated: [RecordPin] = [], complete: [UUID] = []
            for record in records {
                var absent: [String] = []
                let packages = [("Incoming/" + record.packageName, record.manifest, record.manifestSHA256)]
                    + record.deliveries.map { ("Outgoing/" + $0.packageName, $0.manifest, $0.fingerprint) }
                for (path, manifest, hash) in packages {
                    let url = exchange.appendingPathComponent(path, isDirectory: true)
                    if try missing(url) { absent.append(path) }
                    else { try M.validateHistoricalPackage(url, manifest: manifest, sha256: hash) }
                }
                if absent.isEmpty {
                    guard record.stage == "completed", record.taskIDs.count == 1, record.itemIDs.count == 1,
                          database.jobs[0].requestID == record.id, database.jobs[0].id == record.taskIDs[0],
                          database.items[0].id == record.itemIDs[0], database.items[0].state == .completed,
                          record.hasFinalResult, record.deliveries.contains(where: { $0.manifest.status == "completed" }) else { throw bad() }
                    complete.append(record.id)
                } else {
                    guard record.stage == "cancelled", record.taskIDs.isEmpty, record.itemIDs.isEmpty, record.outcomes.isEmpty,
                          !database.jobs.contains(where: { $0.requestID == record.id }),
                          record.deliveries.allSatisfy({ $0.manifest.status == "cancelled"
                              && $0.manifest.provenance?["taskIDs"]?.array?.isEmpty == true }) else { throw bad() }
                    isolated.append(RecordPin(recordID: record.id, stage: record.stage, requestManifestSHA256: record.manifestSHA256,
                        nonceSHA256: downloadDigest(Data(record.manifest.nonce.utf8)), packageName: record.packageName,
                        missingRelativePackages: absent.sorted(), deliveries: record.deliveries.map {
                            DeliveryPin(packageName: $0.packageName, fingerprint: $0.fingerprint, status: $0.manifest.status ?? "")
                        }))
                }
            }
            guard isolated.count == 4, complete.count == 1 else { throw bad() }
            let tree = try M.tree(source)
            guard tree == initialTree, try M.tree(source) == tree, try readRecord(M.markerURL(source), limit: 4096) == marker,
                  tree.files["Exchange/journal.json"]?.sha256 == downloadDigest(journal) else { throw bad() }
            let plan = Plan(schemaVersion: 2, operation: operation, sourceRoot: source.path,
                sourceManifestSHA256: downloadDigest(try encoded(tree)), sourceMarkerSHA256: downloadDigest(marker),
                sourcePreferencesSHA256: downloadDigest(preferences), sourceJournalSHA256: downloadDigest(journal),
                sourceExchangeEvidenceSHA256: downloadDigest(evidence), sourceInstallationID: database.installationID,
                exactApprovedRecords: ordered(isolated), verifiedCompleteRecordIDs: complete,
                taskIDs: database.jobs.map(\.id), itemIDs: database.items.map(\.id), grantIDs: database.destinations.map(\.id), sourceFullyVerified: false)
            return Snapshot(source: source, store: store, lock: lock, database: database, tree: tree, marker: marker,
                preferences: preferences, journal: journal, evidence: evidence, records: records, plan: plan)
        } catch { close(lock); throw error }
    }
    static func preflight(legacyRootURL: URL, sourcePreferences: Data) throws -> Plan {
        let value = try snapshot(legacyRootURL, preferences: sourcePreferences)
        return withExtendedLifetime(value) { value.plan }
    }
    private static func state(_ root: URL, _ defaults: PortalDownloadMigrationDefaults) throws -> State? {
        guard let raw = defaults.object(forKey: evidenceKey(root: root)) else { return nil }
        guard let data = raw as? Data, data.count <= 32 * 1024 * 1024 else { throw bad() }
        let value = try JSONDecoder().decode(State.self, from: data)
        guard value.schemaVersion == 2, value.operation == operation, value.targetRoot == root.path,
              ["preparing", "validated", "committed"].contains(value.phase) else { throw bad() }; return value
    }
    private static func save(_ value: State, root: URL, defaults: PortalDownloadMigrationDefaults) throws {
        let data = try encoded(value); guard data.count <= 32 * 1024 * 1024 else { throw bad() }
        defaults.set(data, forKey: evidenceKey(root: root))
        guard defaults.synchronize(), defaults.data(forKey: evidenceKey(root: root)) == data else { throw bad() }
    }
    private static func current(_ rootURL: URL, defaults: PortalDownloadMigrationDefaults) throws -> Current? {
        let root = try M.physicalRoot(rootURL)
        guard let value = try state(root, defaults) else {
            guard !(try M.exists(markerURL(root: root))), !(try M.exists(completionURL(root: root))),
                  !(try M.exists(root.appendingPathComponent("ReadOnlyHistory"))) else { throw bad() }
            if try M.exists(root.appendingPathComponent(receiptPath)) {
                let raw = try readRecord(root.appendingPathComponent(receiptPath), limit: 8 * 1024 * 1024)
                if let fields = try JSONSerialization.jsonObject(with: raw) as? [String: Any], fields["operation"] as? String == operation { throw bad() }
            }
            return nil
        }
        guard value.phase == "committed", defaults.object(forKey: M.evidenceKey(destinationRootURL: root)) == nil,
              let receiptSHA = value.receiptSHA256,
              try readRecord(markerURL(root: root), limit: 4096) == Data(receiptSHA.utf8),
              try readRecord(completionURL(root: root), limit: 4096) == Data(downloadDigest(try encoded(value)).utf8) else { throw bad() }
        let raw = try readRecord(root.appendingPathComponent(receiptPath), limit: 8 * 1024 * 1024)
        guard downloadDigest(raw) == receiptSHA else { throw bad() }
        let receipt = try JSONDecoder().decode(Receipt.self, from: raw)
        guard receipt.schemaVersion == 2, receipt.operation == operation, receipt.targetRoot == root.path,
              receipt.migrationID == value.migrationID, receipt.authoritySHA256 == value.authoritySHA256,
              receipt.migrationCommitted, !receipt.sourceFullyVerified, !receipt.quarantinedPackageIntegrityVerified,
              receipt.verificationStatus == "committed_with_quarantined_missing_history",
              receipt.historyRelativePath == "ReadOnlyHistory/" + value.migrationID.uuidString else { throw bad() }
        let history = root.appendingPathComponent(receipt.historyRelativePath, isDirectory: true)
        let entriesRaw = try readRecord(history.appendingPathComponent("entries.json"), limit: 8 * 1024 * 1024)
        let identitiesRaw = try readRecord(history.appendingPathComponent("reserved-identities.json"), limit: 8 * 1024 * 1024)
        let manifest = try readRecord(history.appendingPathComponent("source-files.json"), limit: 16 * 1024 * 1024)
        guard downloadDigest(entriesRaw) == receipt.entriesSHA256, downloadDigest(identitiesRaw) == receipt.reservedIdentitiesSHA256,
              downloadDigest(manifest) == receipt.historyManifestSHA256,
              try JSONDecoder().decode(M.Tree.self, from: manifest) == receipt.sourceFiles,
              downloadDigest(try readRecord(history.appendingPathComponent("OriginalFiles/Exchange/journal.json"), limit: 16 * 1024 * 1024)) == receipt.plan.sourceJournalSHA256,
              downloadDigest(try readRecord(history.appendingPathComponent("source-preferences.plist"))) == receipt.plan.sourcePreferencesSHA256,
              downloadDigest(try readRecord(history.appendingPathComponent("source-exchange-evidence.bin"), limit: 4096)) == receipt.plan.sourceExchangeEvidenceSHA256 else { throw bad() }
        let entries = try JSONDecoder().decode([Entry].self, from: entriesRaw)
        let identities = try JSONDecoder().decode(Identities.self, from: identitiesRaw)
        guard entries.count == 4, Set(entries.map(\.id)) == Set(receipt.plan.exactApprovedRecords.map(\.recordID)),
              identities.schemaVersion == 2, identities.operation == operation,
              Set(identities.requestAndResultIDs).count == identities.requestAndResultIDs.count,
              Set(identities.nonceSHA256).count == identities.nonceSHA256.count,
              identities.nonceSHA256.allSatisfy(validHash) else { throw bad() }
        return Current(receipt: receipt, entries: entries, identities: identities)
    }
    static func readHistory(destinationRootURL: URL, targetDefaults: PortalDownloadMigrationDefaults = UserDefaults.standard) throws -> [Entry] {
        do { return try current(destinationRootURL, defaults: targetDefaults)?.entries ?? [] } catch { throw bad() }
    }
    static func guardNewRequest(root: URL, requestID: String, nonce: String? = nil,
                                targetDefaults: PortalDownloadMigrationDefaults = UserDefaults.standard) throws {
        let loaded: Current?
        do { loaded = try current(root, defaults: targetDefaults) } catch { throw bad() }
        guard let loaded else { return }
        if UUID(uuidString: requestID).map({ loaded.identities.requestAndResultIDs.contains($0) }) == true
            || nonce.map({ loaded.identities.nonceSHA256.contains(downloadDigest(Data($0.utf8))) }) == true {
            throw DownloadGaoActionPackageError("history_identity_reserved", "原下载历史身份已保留，不能作为新请求重放；缺件历史不会恢复执行。")
        }
    }
    static func readiness(destinationRootURL: URL, targetDefaults: PortalDownloadMigrationDefaults = UserDefaults.standard) -> PortalDownloadMigrationReadiness? {
        do {
            guard let value = try current(destinationRootURL, defaults: targetDefaults) else { return nil }
            let store = try DownloadStore(root: destinationRootURL, readOnly: true)
            guard try store.load().installationID == value.receipt.sourceInstallationID else { throw bad() }
            return .ready
        } catch { return .recoveryRequired("缺件历史或迁移独立依据需要核对；未创建空队列，也未把缺失历史记为完整通过。") }
    }
    /// Explicit maintenance verification of retained source bytes, with no SourceArchive dependency.
    static func verifyPreservedFiles(destinationRootURL: URL, targetDefaults: PortalDownloadMigrationDefaults = UserDefaults.standard) throws {
        guard let loaded = try current(destinationRootURL, defaults: targetDefaults) else { throw bad() }
        let history = destinationRootURL.appendingPathComponent(loaded.receipt.historyRelativePath)
        let original = try M.tree(history.appendingPathComponent("OriginalFiles"))
        let actual = M.Tree(files: original.files.filter { $0.key != "downloads.previous.json" }, directories: original.directories)
        let source = loaded.receipt.sourceFiles
        let expected = M.Tree(files: source.files.filter { $0.key != "downloads.previous.json" }, directories: source.directories)
        guard actual == expected,
              downloadDigest(try readRecord(history.appendingPathComponent("source-initialization.json"), limit: 4096)) == loaded.receipt.plan.sourceMarkerSHA256 else { throw bad() }
    }

    static func prepare(destinationRootURL: URL, legacyRootURL: URL, sourcePreferences: Data,
                        authority: Authority, approvedSnapshot: Data, humanAuthorization: Data,
                        fenceReceipt: Data, backupReceipt: Data,
                        trustedApprovedSnapshotSHA256: String, trustedHumanAuthorizationFactSHA256: String,
                        targetDefaults: PortalDownloadMigrationDefaults = UserDefaults.standard,
                        maintenanceGuard: () throws -> Void,
                        fault: ((String) throws -> Void)? = nil) throws -> Receipt {
        let root = try M.physicalRoot(destinationRootURL), source = try M.physicalRoot(legacyRootURL)
        guard root.path != source.path, !root.path.hasPrefix(source.path + "/"), !source.path.hasPrefix(root.path + "/"),
              authority.schemaVersion == 2, authority.operation == operation, authority.sourceFrozen,
              authority.sourceBundleID == "com.gaoseries.GaoXiaZai", authority.targetBundleID == "cn.mendao.launcher",
              authority.sourceRoot == source.path, authority.targetRoot == root.path,
              [authority.planSHA256, authority.approvedSnapshotSHA256, authority.humanAuthorizationSHA256,
               authority.fenceReceiptSHA256, authority.backupReceiptSHA256].allSatisfy(validHash),
              downloadDigest(approvedSnapshot) == authority.approvedSnapshotSHA256,
              authority.approvedSnapshotSHA256 == trustedApprovedSnapshotSHA256,
              validHash(trustedHumanAuthorizationFactSHA256),
              downloadDigest(humanAuthorization) == authority.humanAuthorizationSHA256,
              downloadDigest(fenceReceipt) == authority.fenceReceiptSHA256,
              downloadDigest(backupReceipt) == authority.backupReceiptSHA256,
              try JSONSerialization.jsonObject(with: backupReceipt) is [String: Any],
              targetDefaults.object(forKey: M.evidenceKey(destinationRootURL: root)) == nil else { throw bad() }
        let approved = try JSONDecoder().decode(ApprovedSnapshot.self, from: approvedSnapshot)
        let human = try JSONDecoder().decode(HumanAuthorization.self, from: humanAuthorization)
        let fence = try JSONDecoder().decode(FenceReceipt.self, from: fenceReceipt)
        try boolean(humanAuthorization, key: "approved", equals: true)
        try boolean(fenceReceipt, key: "frozen", equals: true)
        try boolean(fenceReceipt, key: "actualWriterFence", equals: true)
        let factRaw = try readRecord(recordURL(human.actualHumanAuthorizationFactPath))
        let fact = try JSONDecoder().decode(HumanFact.self, from: factRaw)
        try boolean(factRaw, key: "sourceFullyVerified", equals: false)
        try boolean(factRaw, key: "doesNotCertifyWritersFrozenOrBackupsOrCurrentSourceEquality", equals: true)
        let actualFence = try readRecord(recordURL(fence.actualFenceReceiptPath))
        guard let actualFenceFields = try JSONSerialization.jsonObject(with: actualFence) as? [String: Any],
              actualFenceFields["kind"] as? String == "fenced-observed",
              let transactionID = actualFenceFields["transactionID"] as? String, UUID(uuidString: transactionID) != nil,
              let previous = actualFenceFields["previousSHA256"] as? String, validHash(previous),
              let sources = actualFenceFields["sourceBundleIDs"] as? [String], sources.contains("com.gaoseries.GaoXiaZai"),
              let sourceRoots = actualFenceFields["sourceDataRoots"] as? [String: String], sourceRoots["download"] == source.path,
              let targetRoots = actualFenceFields["targetDataRoots"] as? [String: String], targetRoots["download"] == root.path else { throw bad() }
        for key in ["sourceFrozenAtThisObservation", "sourceFormalApplicationAbsentOrIsolated", "noSourceWriterObserved", "leaseMustRemainOwned"] {
            try boolean(actualFence, key: key, equals: true)
        }
        guard approved.schemaVersion == 1, approved.operation == operation,
              !approved.authorizationReference.isEmpty, approved.authorizationReference.utf8.count <= 1024,
              approved.sourceRecordCount == 5, approved.remainingCompletedRecords == 1,
              human.schemaVersion == 2, human.operation == operation, human.authorizationReference == approved.authorizationReference, human.approved,
              downloadDigest(factRaw) == trustedHumanAuthorizationFactSHA256,
              human.actualHumanAuthorizationFactSHA256 == trustedHumanAuthorizationFactSHA256,
              fact.schemaVersion == 1, fact.kind == "GaoSeriesHumanExplicitScopeAuthorization",
              fact.operation == "downloads-quarantine-missing-history", fact.questionCall == approved.authorizationReference,
              fact.sourceBundleID == authority.sourceBundleID, fact.targetBundleID == authority.targetBundleID,
              !fact.sourceFullyVerified, fact.doesNotCertifyWritersFrozenOrBackupsOrCurrentSourceEquality,
              fact.expectedOutcome == "committed_with_quarantined_missing_history", validHash(fact.approvedProposalSHA256),
              fact.approvedMissingHistorySnapshotSHA256 == trustedApprovedSnapshotSHA256,
              try readRecord(recordURL(fact.approvedMissingHistorySnapshot)) == approvedSnapshot,
              human.approvedSnapshotSHA256 == authority.approvedSnapshotSHA256, human.planSHA256 == authority.planSHA256,
              matching(human.exactApprovedRecords, approved.exactApprovedRecords), matching(authority.exactApprovedRecords, approved.exactApprovedRecords),
              fence.schemaVersion == 2, fence.operation == operation, fence.receiptKind == "actual-writer-fence", fence.frozen, fence.actualWriterFence,
              fence.sourceRoot == source.path, fence.targetRoot == root.path, validHash(fence.evidenceSHA256),
              fence.evidenceSHA256 == fence.actualFenceReceiptSHA256,
              downloadDigest(actualFence) == fence.actualFenceReceiptSHA256 else { throw bad() }
        try maintenanceGuard()
        let parent = try openDirectoryNoLinks(root.deletingLastPathComponent()); defer { close(parent) }; try M.requirePrivateDirectory(parent)
        let lock = openat(parent, ".DownloadCenter.migration.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw bad() }; defer { close(lock) }
        guard regularOwned(try statIdentity(lock)), flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw bad() }
        let authSHA = downloadDigest(try encoded(authority))
        var pending = try state(root, targetDefaults)
        if let previous = pending, previous.phase == "committed" {
            guard previous.authoritySHA256 == authSHA else { throw bad() }
            if !(try M.exists(completionURL(root: root))) {
                guard let expected = previous.targetTree, try M.tree(root) == expected else { throw bad() }
                try save(previous, root: root, defaults: targetDefaults)
                try M.write(Data(downloadDigest(try encoded(previous)).utf8), at: completionURL(root: root), replacing: false)
            }
            guard let loaded = try current(root, defaults: targetDefaults) else { throw bad() }
            return loaded.receipt
        }
        let snap = try snapshot(source, preferences: sourcePreferences); defer { withExtendedLifetime(snap) {} }
        guard downloadDigest(try encoded(snap.plan)) == authority.planSHA256,
              approved.sourceJournalSHA256 == snap.plan.sourceJournalSHA256,
              matching(snap.plan.exactApprovedRecords, approved.exactApprovedRecords) else { throw bad() }
        if let value = pending {
            guard value.phase == "validated", value.sourceRoot == source.path, value.authoritySHA256 == authSHA,
                  value.sourceTree == snap.tree else { throw bad() }
        } else {
            guard !(try M.exists(root)), !(try M.exists(M.markerURL(root))), !(try M.exists(markerURL(root: root))), !(try M.exists(completionURL(root: root))),
                  targetDefaults.object(forKey: M.exchangeKey(directory: root.appendingPathComponent("Exchange"))) == nil else { throw bad() }
            pending = State(schemaVersion: 2, operation: operation, migrationID: UUID(), sourceRoot: source.path,
                targetRoot: root.path, authoritySHA256: authSHA, phase: "preparing")
            try save(pending!, root: root, defaults: targetDefaults); try fault?("isolation.preparing")
        }
        var value = pending!
        let container = root.deletingLastPathComponent().appendingPathComponent(".DownloadCenter-Isolation-\(value.migrationID.uuidString).noindex", isDirectory: true)
        let staged = container.appendingPathComponent(root.lastPathComponent, isDirectory: true)
        if value.phase == "preparing" {
            guard !(try M.exists(container)), !(try M.exists(root)) else { throw bad() }
            try M.makeDirectory(container); try M.makeDirectory(staged)
            try M.makeDirectory(staged.appendingPathComponent("ReadOnlyHistory"))
            let relative = "ReadOnlyHistory/" + value.migrationID.uuidString
            let history = staged.appendingPathComponent(relative); try M.makeDirectory(history)
            let originals = history.appendingPathComponent("OriginalFiles"); try M.makeDirectory(originals)
            try M.copy(source, to: originals, expected: snap.tree, excluding: ["downloads.previous.json"])
            try M.write(snap.marker, at: history.appendingPathComponent("source-initialization.json"), replacing: false)
            try M.write(snap.preferences, at: history.appendingPathComponent("source-preferences.plist"), replacing: false)
            try M.write(snap.evidence, at: history.appendingPathComponent("source-exchange-evidence.bin"), replacing: false)
            let sourceFiles = try encoded(snap.tree); try M.write(sourceFiles, at: history.appendingPathComponent("source-files.json"), replacing: false)
            let isolatedIDs = Set(snap.plan.exactApprovedRecords.map(\.recordID))
            let entries = snap.records.filter { isolatedIDs.contains($0.id) }.map { record in
                Entry(id: record.id, sourceBundleID: record.sourceBundleID, receivedAt: record.receivedAt,
                    requestManifestSHA256: record.manifestSHA256,
                    missingPackages: snap.plan.exactApprovedRecords.first { $0.recordID == record.id }!.missingRelativePackages, originalStage: record.stage)
            }
            let entriesRaw = try encoded(entries); try M.write(entriesRaw, at: history.appendingPathComponent("entries.json"), replacing: false)
            let identityIDs = snap.records.flatMap { [$0.id] + $0.deliveries.compactMap { UUID(uuidString: $0.manifest.requestID) } }
            let nonceHashes = snap.records.flatMap { [downloadDigest(Data($0.manifest.nonce.utf8))] + $0.deliveries.map { downloadDigest(Data($0.manifest.nonce.utf8)) } }
            guard Set(identityIDs).count == identityIDs.count, Set(nonceHashes).count == nonceHashes.count else { throw bad() }
            let identitiesRaw = try encoded(Identities(schemaVersion: 2, operation: operation,
                requestAndResultIDs: identityIDs, nonceSHA256: nonceHashes))
            try M.write(identitiesRaw, at: history.appendingPathComponent("reserved-identities.json"), replacing: false)
            var database = snap.database; guard database.revision < UInt64.max else { throw bad() }; database.revision += 1
            database.migrationHistory.append("GaoXiaZai->GaoMenHu:cancelled-history-isolation:\(value.migrationID.uuidString)")
            for index in database.destinations.indices { database.destinations[index].requiresReauthorization = true }
            let payload = try encoded(database)
            try M.write(try encoded(M.DatabaseEnvelope(payload: payload, sha256: downloadDigest(payload))), at: staged.appendingPathComponent("downloads.json"), replacing: false)
            try M.write(Data(), at: staged.appendingPathComponent("store.lock"), replacing: false)
            try M.write(snap.marker, at: M.markerURL(staged), replacing: false)
            let exchange = staged.appendingPathComponent("Exchange"); try M.makeDirectory(exchange)
            for name in ["Incoming", "Outgoing"] { try M.makeDirectory(exchange.appendingPathComponent(name)) }
            try M.write(Data(), at: exchange.appendingPathComponent("journal.lock"), replacing: false)
            var envelope = try JSONDecoder().decode(M.ExchangeEnvelope.self, from: snap.journal)
            guard envelope.generation < Int.max else { throw bad() }; envelope.generation += 1
            envelope.records.removeAll { isolatedIDs.contains($0.id) }
            for index in envelope.records.indices {
                let record = envelope.records[index]
                let names = ["Incoming/" + record.packageName] + record.deliveries.map { "Outgoing/" + $0.packageName }
                for name in names {
                    let src = source.appendingPathComponent("Exchange/" + name), dst = exchange.appendingPathComponent(name)
                    try M.makeDirectory(dst); try M.copy(src, to: dst, expected: M.tree(src))
                }
                envelope.records[index].outgoingURLs = record.deliveries.map {
                    root.appendingPathComponent("Exchange/Outgoing", isDirectory: true).appendingPathComponent($0.packageName, isDirectory: true)
                }
            }
            let journalBytes = try encoded(envelope)
            let exchangeEvidence = try encoded(M.ExchangeEvidence(schemaVersion: 1, identity: envelope.identity,
                generation: envelope.generation, digest: downloadDigest(journalBytes), pending: false))
            _ = try DownloadGaoExchangeJournal.validateHistoricalSnapshot(journalBytes, evidence: exchangeEvidence, directory: root.appendingPathComponent("Exchange"))
            try M.write(journalBytes, at: exchange.appendingPathComponent("journal.json"), replacing: false)
            try M.makeDirectory(staged.appendingPathComponent("MigrationEvidence"))
            let receipt = Receipt(schemaVersion: 2, operation: operation, migrationID: value.migrationID, sourceRoot: source.path,
                targetRoot: root.path, sourceInstallationID: database.installationID, migrationCommitted: true,
                verificationStatus: "committed_with_quarantined_missing_history", sourceFullyVerified: false, plan: snap.plan,
                authoritySHA256: authSHA, approvedSnapshotSHA256: authority.approvedSnapshotSHA256,
                humanAuthorizationSHA256: authority.humanAuthorizationSHA256, fenceReceiptSHA256: authority.fenceReceiptSHA256,
                backupReceiptSHA256: authority.backupReceiptSHA256, historyRelativePath: relative, sourceFiles: snap.tree,
                sourceMarkerRelativePath: relative + "/source-initialization.json", historyManifestSHA256: downloadDigest(sourceFiles),
                entriesSHA256: downloadDigest(entriesRaw), reservedIdentitiesSHA256: downloadDigest(identitiesRaw),
                ledgerDigestVerified: true, quarantinedPackageIntegrityVerified: false, grantsRequireNewHostAuthorization: true, importedAt: Date())
            let receiptBytes = try encoded(receipt); try M.write(receiptBytes, at: staged.appendingPathComponent(receiptPath), replacing: false)
            do { let check = try DownloadStore(root: staged, readOnly: true); _ = try check.load() }
            guard try M.tree(source) == snap.tree, try readRecord(M.markerURL(source), limit: 4096) == snap.marker else { throw bad() }
            value.sourceTree = snap.tree; value.targetTree = try M.tree(staged); value.marker = snap.marker
            value.exchangeEvidence = exchangeEvidence; value.receiptSHA256 = downloadDigest(receiptBytes); value.phase = "validated"
            try save(value, root: root, defaults: targetDefaults); try fault?("isolation.validated")
        }
        guard let expected = value.targetTree, let marker = value.marker, let exchangeEvidence = value.exchangeEvidence,
              let receiptSHA = value.receiptSHA256 else { throw bad() }
        try maintenanceGuard()
        guard try M.tree(source) == snap.tree, try readRecord(M.markerURL(source), limit: 4096) == marker else { throw bad() }
        if try M.exists(root) { guard try M.tree(root) == expected, !(try M.exists(staged)) else { throw bad() } }
        else {
            guard try M.tree(staged) == expected else { throw bad() }
            let from = try openDirectoryNoLinks(container); defer { close(from) }
            guard renameatx_np(from, root.lastPathComponent, parent, root.lastPathComponent, UInt32(RENAME_EXCL)) == 0,
                  fsync(from) == 0, fsync(parent) == 0 else { throw bad() }
        }
        try fault?("isolation.rootPublished")
        for (url, bytes) in [(M.markerURL(root), marker), (markerURL(root: root), Data(receiptSHA.utf8))] {
            if try M.exists(url) { guard try readRecord(url, limit: 4096) == bytes else { throw bad() } }
            else { try M.write(bytes, at: url, replacing: false) }
        }
        let exchangeKey = M.exchangeKey(directory: root.appendingPathComponent("Exchange"))
        if let old = targetDefaults.object(forKey: exchangeKey) { guard old as? Data == exchangeEvidence else { throw bad() } }
        else { targetDefaults.set(exchangeEvidence, forKey: exchangeKey) }
        guard targetDefaults.synchronize(), targetDefaults.data(forKey: exchangeKey) == exchangeEvidence else { throw bad() }
        try fault?("isolation.evidencePublished")
        try maintenanceGuard()
        guard try M.tree(root) == expected, try M.tree(source) == snap.tree else { throw bad() }
        value.phase = "committed"; try save(value, root: root, defaults: targetDefaults); try fault?("isolation.committedSaved")
        try M.write(Data(downloadDigest(try encoded(value)).utf8), at: completionURL(root: root), replacing: false)
        try fault?("isolation.committed")
        guard let loaded = try current(root, defaults: targetDefaults) else { throw bad() }
        try verifyPreservedFiles(destinationRootURL: root, targetDefaults: targetDefaults)
        if try M.exists(M.markerURL(staged)) {
            guard try readRecord(M.markerURL(staged), limit: 4096) == marker else { throw bad() }
            guard unlink(M.markerURL(staged).path) == 0 else { throw bad() }
        }
        if try M.exists(container) { guard rmdir(container.path) == 0 else { throw bad() } }
        return loaded.receipt
    }
}
