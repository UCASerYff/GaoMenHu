import Foundation
import Darwin

@main
struct DownloadMigrationTests {
    static var checks = 0
    static var stage = "startup"
    static var fixtures = 0
    static func progress(_ value: String) {
        stage = value; print("migration fixture progress: checks=\(checks), stage=\(stage)"); fflush(stdout)
    }
    static func check(_ value: Bool) { precondition(value); checks += 1 }
    static func rejects(_ action: () throws -> Void) {
        do { try action(); fatalError("Unsafe migration accepted") } catch { checks += 1 }
    }
    struct Injected: Error {}
    final class MemoryDefaults: PortalDownloadMigrationDefaults {
        private var values: [String: Any] = [:]
        func object(forKey key: String) -> Any? { values[key] }
        func set(_ value: Any?, forKey key: String) { values[key] = value }
        func synchronize() -> Bool { true }
        func data(forKey key: String) -> Data? { values[key] as? Data }
    }
    struct Fixture {
        let root: URL
        let source: URL
        let target: URL
        let defaults: MemoryDefaults
        let id: UUID
        let jobID: UUID
        let itemID: UUID
        let grantID: UUID
        init(state: DownloadState = .running, withExchange: Bool = false) throws {
            DownloadMigrationTests.fixtures += 1
            DownloadMigrationTests.progress("fixture \(DownloadMigrationTests.fixtures) initialize")
            root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("portal-migration-\(UUID().uuidString).noindex", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let parent = root.appendingPathComponent("Legacy", isDirectory: true)
            let newParent = root.appendingPathComponent("MenDao", isDirectory: true)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try FileManager.default.createDirectory(at: newParent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            source = parent.appendingPathComponent("GaoXiaZai", isDirectory: true)
            target = newParent.appendingPathComponent("DownloadCenter", isDirectory: true)
            defaults = MemoryDefaults()
            jobID = UUID(); itemID = UUID(); grantID = UUID()
            let store = try DownloadStore(root: source)
            var data = try store.load(); id = data.installationID
            let url = "https://example.org/download.bin"
            data.jobs = [DownloadJob(id: jobID, requestID: nil, itemIDs: [itemID], createdAt: Date())]
            data.destinations = [DestinationGrant(id: grantID, displayPath: "/fixture/original-directory", bookmark: Data([1,2,3]), device: 1, inode: 2, volumeUUID: "fixture")]
            data.settings.speedLimitBytesPerSecond = 1024 * 1024
            data.items = [DownloadItem(id: itemID, jobID: jobID, destinationID: grantID, state: state,
                sourceURL: url, sourceFingerprint: downloadDigest(Data(url.utf8)), displayURL: url, suggestedName: "download.bin",
                bytesReceived: 8, expectedBytes: 16, bytesPerSecond: 20, sha256: nil, errorMessage: nil,
                retryAt: Date(), artifact: nil, createdAt: Date(), etag: "\"strong-version-1\"", lastModified: nil,
                stagingName: itemID.uuidString + ".part", stagingDevice: 1, stagingInode: 9,
                partialSHA256: String(repeating: "a", count: 64))]
            if state == .completed {
                data.items[0].artifact = PublishedArtifact(fileName: "download.bin", byteCount: 8,
                    sha256: String(repeating: "b", count: 64), device: 1, inode: 9)
            }
            try store.save(data)
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
        func prepare(preferences: [String: Data] = [:], retired: Bool = true, authority: PortalDownloadMigrationAuthority? = nil, fault: ((String) throws -> Void)? = nil) throws -> PortalDownloadMigrationReceipt {
            let normalized = source.standardizedFileURL
            let marker = normalized.deletingLastPathComponent().appendingPathComponent(".\(normalized.lastPathComponent).initialized-v1.json")
            var sourceInfo = stat(), markerInfo = stat()
            let sourceRC = lstat(normalized.path, &sourceInfo), markerRC = lstat(marker.path, &markerInfo)
            print("synthetic path diagnostic: raw=\(source.path); normalized=\(normalized.path); parts=\(normalized.pathComponents); sourceType=\(sourceInfo.st_mode & S_IFMT), sourceRC=\(sourceRC); marker=\(marker.path), markerType=\(markerInfo.st_mode & S_IFMT), markerRC=\(markerRC)")
            return try PortalDownloadMigration.prepare(destinationRootURL: target, legacyRootURL: source,
                sourcePreferences: preferences, targetDefaults: defaults, sourceRetired: retired, authority: authority, fault: { checkpoint in
                    DownloadMigrationTests.progress("fixture \(DownloadMigrationTests.fixtures) " + checkpoint)
                    try fault?(checkpoint)
                })
        }
        func readiness(_ preferences: [String: Data] = [:]) -> PortalDownloadMigrationReadiness {
            PortalDownloadMigration.readiness(destinationRootURL: target, legacyRootURL: source,
                sourcePreferences: preferences, targetDefaults: defaults)
        }
    }
    static func bytes(_ root: URL) throws -> [String: Data] {
        var output: [String: Data] = [:]
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])!
        for case let path as URL in enumerator {
            if try path.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                output[String(path.path.dropFirst(root.path.count + 1))] = try Data(contentsOf: path)
            }
        }
        return output
    }
    final class MemoryExchangeEvidence: DownloadGaoExchangeEvidence {
        var data: Data?
        func load() throws -> Data? { data }
        func save(_ value: Data) throws { data = value }
    }
    static func privateWrite(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: url); guard chmod(url.path, 0o600) == 0 else { throw Injected() }
    }
    static func legacyExchange(_ f: Fixture) throws -> [String: Data] {
        let evidence = MemoryExchangeEvidence()
        let directory = f.source.appendingPathComponent("Exchange", isDirectory: true)
        let requestID = UUID(), resultID = UUID().uuidString.lowercased(), now = Date()
        do {
            let store = try DownloadStore(root: f.source); var database = try store.load()
            database.jobs[0].requestID = requestID; try store.save(database)
        }
        let journal = try DownloadGaoExchangeJournal(directory: directory, evidence: evidence)
        let request = DownloadGaoActionManifest(kind: "request", requestID: requestID.uuidString.lowercased(),
            sourceBundleID: "com.gaoseries.GaoCaoZuo", targetBundleID: "com.gaoseries.GaoXiaZai", action: "downloads.prepare",
            createdAt: DownloadGaoActionPackage.iso8601(now), expiresAt: DownloadGaoActionPackage.iso8601(now.addingTimeInterval(120)),
            nonce: try DownloadGaoActionPackage.randomNonce(), items: [], references: [], parameters: ["urls": .array([.string("https://example.org/download.bin")])])
        var result = DownloadGaoActionManifest(kind: "result", requestID: resultID,
            sourceBundleID: "com.gaoseries.GaoXiaZai", targetBundleID: "com.gaoseries.GaoCaoZuo", action: "downloads.prepare",
            createdAt: request.createdAt, expiresAt: request.expiresAt, nonce: try DownloadGaoActionPackage.randomNonce(),
            items: [], references: [], parameters: [:])
        result.inReplyTo = requestID.uuidString.lowercased(); result.status = "pending"
        result.provenance = ["workflowState": .string("accepted"), "taskIDs": .array([.string(f.jobID.uuidString.lowercased())])]
        let requestData = try DownloadGaoActionPackage.manifestData(request), resultData = try DownloadGaoActionPackage.manifestData(result)
        let delivery = DownloadGaoResultDelivery(packageName: resultID + ".gaoaction", manifest: result,
            fingerprint: downloadDigest(resultData), attempts: 1, handedOffAt: now, lastError: nil)
        let record = DownloadGaoExchangeRecord(id: requestID, sourceBundleID: request.sourceBundleID,
            urls: ["https://example.org/download.bin"], receivedAt: now, stage: "accepted", taskIDs: [f.jobID],
            outgoingURLs: [directory.appendingPathComponent("Outgoing", isDirectory: true).appendingPathComponent(delivery.packageName, isDirectory: true)],
            hasFinalResult: false, itemIDs: [f.itemID], outcomes: [], deliveries: [delivery], manifest: request,
            manifestSHA256: downloadDigest(requestData), packageName: request.requestID + ".gaoaction")
        try journal.append(record)
        try privateWrite(requestData, to: directory.appendingPathComponent("Incoming/" + record.packageName + "/manifest.json"))
        try privateWrite(resultData, to: directory.appendingPathComponent("Outgoing/" + delivery.packageName + "/manifest.json"))
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Incoming/" + record.packageName + "/payload"), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Outgoing/" + delivery.packageName + "/payload"), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return [PortalDownloadMigration.exchangeKey(directory: directory, legacy: true): evidence.data!]
    }
    @MainActor static func main() {
        setbuf(stdout, nil)
        do { try run() }
        catch {
            fputs("Download migration failure: checks=\(checks), stage=\(stage), error=\(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
    @MainActor static func run() throws {
        do {
            let f = try Fixture(); defer { f.cleanup() }
            let original = try bytes(f.source)
            check(f.readiness() == .requiresMigration)
            rejects { _ = try f.prepare(retired: false) }
            check(!FileManager.default.fileExists(atPath: f.target.path))
            let receipt = try f.prepare()
            check(receipt.sourceInstallationID == f.id)
            check(receipt.taskIDs == [f.jobID.uuidString] && receipt.itemIDs == [f.itemID.uuidString])
            check(receipt.destinationIDs == [f.grantID.uuidString] && receipt.interruptedItems == 1)
            check(try bytes(f.source) == original)
            do {
                let store = try DownloadStore(root: f.target, readOnly: true); let data = try store.load()
                check(data.items.count == 1 && data.jobs.count == 1 && data.destinations.count == 1)
                check(data.items[0].state == .waitingForDestination && data.items[0].bytesReceived == 8)
                check(data.items[0].etag == "\"strong-version-1\"" && data.items[0].partialSHA256 == String(repeating: "a", count: 64))
                check(data.items[0].stagingInode == 9 && data.items[0].stagingDevice == 1)
                check(data.destinations[0].requiresReauthorization == true)
                check(data.settings.speedLimitBytesPerSecond == 1024 * 1024)
                rejects { _ = try DestinationAccess(data.destinations[0]) }
            }
            check(f.readiness() == .ready)
            let imported = try bytes(f.target)
            check(try f.prepare() == receipt)
            check(try bytes(f.target) == imported)
            let lock = open(f.source.appendingPathComponent("store.lock").path, O_RDONLY)
            defer { if lock >= 0 { close(lock) } }
            check(lock >= 0 && flock(lock, LOCK_EX | LOCK_NB) == 0)
            // Committed retry never rewrites the target even if the retired source is locked.
            check(try f.prepare() == receipt)
            flock(lock, LOCK_UN)
        }
        do {
            let f = try Fixture(state: .completed); defer { f.cleanup() }
            let receipt = try f.prepare(); check(receipt.completedItems == 1 && receipt.interruptedItems == 0)
            let store = try DownloadStore(root: f.target, readOnly: true); let data = try store.load()
            check(data.items[0].state == .completed && data.items[0].artifact?.byteCount == 8)
        }
        for point in ["migration.validated", "migration.rootPublished", "migration.markerPublished", "migration.evidencePublished"] {
            let f = try Fixture(); defer { f.cleanup() }
            rejects { _ = try f.prepare(fault: { if $0 == point { throw Injected() } }) }
            if case .recoveryRequired = f.readiness() { checks += 1 } else { fatalError("Pending migration not blocked") }
            let receipt = try f.prepare()
            check(receipt.taskIDs == [f.jobID.uuidString])
            let store = try DownloadStore(root: f.target, readOnly: true); check(try store.load().items.count == 1)
        }
        for point in ["migration.preparing", "migration.copied"] {
            let f = try Fixture(); defer { f.cleanup() }
            let original = try bytes(f.source)
            rejects { _ = try f.prepare(fault: { if $0 == point { throw Injected() } }) }
            rejects { _ = try f.prepare() }
            check(!FileManager.default.fileExists(atPath: f.target.path))
            check(try bytes(f.source) == original)
        }
        do {
            let f = try Fixture(); defer { f.cleanup() }
            try FileManager.default.removeItem(at: f.source.appendingPathComponent("downloads.json"))
            rejects { _ = try f.prepare() }
            check(!FileManager.default.fileExists(atPath: f.target.path))
        }
        do {
            let f = try Fixture(); defer { f.cleanup() }
            try FileManager.default.removeItem(at: f.source)
            if case .recoveryRequired = f.readiness() { checks += 1 } else { fatalError("Missing initialized source not blocked") }
            rejects { _ = try f.prepare() }
        }
        do {
            let f = try Fixture(); defer { f.cleanup() }
            let previous = f.source.appendingPathComponent("downloads.previous.json")
            try Data("broken".utf8).write(to: previous)
            rejects { _ = try f.prepare() }
            check(!FileManager.default.fileExists(atPath: f.target.path))
        }
        do {
            let f = try Fixture(); defer { f.cleanup() }
            let lock = open(f.source.appendingPathComponent("store.lock").path, O_RDWR)
            defer { if lock >= 0 { close(lock) } }
            check(lock >= 0 && flock(lock, LOCK_EX | LOCK_NB) == 0)
            rejects { _ = try f.prepare() }
            check(!FileManager.default.fileExists(atPath: f.target.path))
        }
        do {
            let f = try Fixture(); defer { f.cleanup() }
            let external = f.root.appendingPathComponent("unrelated.txt"); try Data("unrelated".utf8).write(to: external)
            let link = f.source.appendingPathComponent("linked.txt")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
            rejects { _ = try f.prepare() }
            check(try Data(contentsOf: external) == Data("unrelated".utf8))
        }
        do {
            let f = try Fixture(); defer { f.cleanup() }
            let key = PortalDownloadMigration.exchangeKey(directory: f.source.appendingPathComponent("Exchange"), legacy: true)
            rejects { _ = try f.prepare(preferences: [key: Data("orphan-evidence".utf8)]) }
        }
        do {
            let f = try Fixture(); defer { f.cleanup() }
            let exchange = f.source.appendingPathComponent("Exchange", isDirectory: true)
            try FileManager.default.createDirectory(at: exchange, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            rejects { _ = try f.prepare() }
        }
        do {
            let f = try Fixture(); defer { f.cleanup() }
            rejects { _ = try f.prepare(fault: { if $0 == "migration.validated" { throw Injected() } }) }
            try Data("changed-source".utf8).write(to: f.source.appendingPathComponent("changed.txt"))
            rejects { _ = try f.prepare() }
            check(!FileManager.default.fileExists(atPath: f.target.path))
        }
        do {
            let f = try Fixture(); defer { f.cleanup() }
            let preferences = try legacyExchange(f), original = try bytes(f.source)
            let receipt = try f.prepare(preferences: preferences)
            check(receipt.taskIDs == [f.jobID.uuidString] && receipt.oldExchangeRetainedAsHistoryOnly)
            check(try bytes(f.source) == original)
            let targetExchange = f.target.appendingPathComponent("Exchange", isDirectory: true)
            let evidence = f.defaults.data(forKey: PortalDownloadMigration.exchangeKey(directory: targetExchange))!
            let records = try DownloadGaoExchangeJournal.validateHistoricalSnapshot(Data(contentsOf: targetExchange.appendingPathComponent("journal.json")), evidence: evidence, directory: targetExchange)
            check(records.count == 1 && records[0].isLegacyHistory)
            check(records[0].taskIDs == [f.jobID] && records[0].itemIDs == [f.itemID])
            check(records[0].outgoingURLs[0].path.hasPrefix(targetExchange.path + "/Outgoing/"))
            check(try Data(contentsOf: records[0].outgoingURLs[0].appendingPathComponent("manifest.json")) == DownloadGaoActionPackage.manifestData(records[0].deliveries[0].manifest))
            rejects { try DownloadGaoDownloadContract.validateRequest(records[0].manifest) }
            check(f.readiness(preferences) == .ready)
        }
        do {
            let f = try Fixture(); defer { f.cleanup() }
            var preferences = try legacyExchange(f)
            let key = preferences.keys.first!; preferences[key] = Data("broken".utf8)
            rejects { _ = try f.prepare(preferences: preferences) }
            check(!FileManager.default.fileExists(atPath: f.target.path))
        }
        do {
            let f = try Fixture(); defer { f.cleanup() }
            let preferences = try legacyExchange(f)
            let incoming = f.source.appendingPathComponent("Exchange/Incoming")
            let package = try FileManager.default.contentsOfDirectory(at: incoming, includingPropertiesForKeys: nil)[0]
            try FileManager.default.removeItem(at: package.appendingPathComponent("manifest.json"))
            rejects { _ = try f.prepare(preferences: preferences) }
            check(!FileManager.default.fileExists(atPath: f.target.path))
        }
        do {
            let f = try Fixture(); defer { f.cleanup() }
            let before = try bytes(f.source)
            let plan = try PortalDownloadMigration.preflight(legacyRootURL: f.source, sourcePreferences: [:])
            check(plan.itemCount == 1 && plan.jobCount == 1 && plan.sourceInstallationID == f.id)
            check(try bytes(f.source) == before)
            func authority(frozen: Bool = true) -> PortalDownloadMigrationAuthority {
                PortalDownloadMigrationAuthority(schemaVersion: 1, sourceBundleID: "com.gaoseries.GaoXiaZai", targetBundleID: "cn.mendao.launcher",
                    sourceFrozen: frozen, sourceRoot: f.source.path, targetRoot: f.target.path,
                    sourceManifestSHA256: plan.sourceManifestSHA256, sourceMarkerSHA256: plan.sourceMarkerSHA256,
                    sourcePreferencesSHA256: plan.sourcePreferencesSHA256, backupReceiptSHA256: String(repeating: "c", count: 64))
            }
            rejects { _ = try f.prepare(authority: authority(frozen: false)) }
            check(f.defaults.object(forKey: PortalDownloadMigration.evidenceKey(destinationRootURL: f.target)) == nil)
            try privateWrite(Data("source changed after fence plan".utf8), to: f.source.appendingPathComponent("later.txt"))
            rejects { _ = try f.prepare(authority: authority()) }
            check(f.defaults.object(forKey: PortalDownloadMigration.evidenceKey(destinationRootURL: f.target)) == nil)
            try FileManager.default.removeItem(at: f.source.appendingPathComponent("later.txt"))
            let accepted = authority(), receipt = try f.prepare(authority: accepted)
            check(receipt.backupReceiptSHA256 == accepted.backupReceiptSHA256 && receipt.authoritySHA256 != nil)
            check(try f.prepare(authority: accepted) == receipt)
        }
        do {
            let f = try Fixture(); defer { f.cleanup() }
            let keyBefore = PortalDownloadMigration.evidenceKey(destinationRootURL: f.target)
            _ = try f.prepare()
            check(PortalDownloadMigration.evidenceKey(destinationRootURL: f.target) == keyBefore)
            check(f.defaults.data(forKey: keyBefore) != nil && f.readiness() == .ready)
            var info = stat()
            if lstat("/tmp", &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK {
                let aliasSource = URL(fileURLWithPath: "/tmp" + f.source.path.dropFirst("/private/tmp".count), isDirectory: true)
                rejects {
                    _ = try PortalDownloadMigration.preflight(legacyRootURL: aliasSource, sourcePreferences: [:])
                }
            }
        }
        print("Download migration: \(checks) isolated checks passed; no real app, source database, credentials, grants or downloads used.")
    }
}
