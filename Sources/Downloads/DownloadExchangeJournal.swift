import Foundation
import CryptoKit
import Darwin

protocol DownloadGaoExchangeEvidence: AnyObject {
    func load() throws -> Data?
    func save(_ value: Data) throws
}

/// Independent initialization evidence survives deletion of the private Exchange directory.
final class DownloadGaoExchangeDefaultsEvidence: DownloadGaoExchangeEvidence {
    private let key: String
    private let defaults: UserDefaults
    init(directory: URL, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        key = Self.evidenceKey(for: directory)
    }
    /// This new namespace binds the caller's validated physical path. Foundation
    /// standardization can rewrite /private/tmp to its /tmp alias depending on
    /// existence; it must not change independent evidence between launches.
    static func evidenceKey(for directory: URL) -> String {
        "GaoMenHu.DownloadExchangeEvidence." + DownloadGaoActionPackage.digest(Data(directory.path.utf8))
    }
    func load() throws -> Data? {
        guard let value = defaults.object(forKey: key) else { return nil }
        guard let data = value as? Data else { throw DownloadGaoExchangeJournal.invalid }; return data
    }
    func save(_ value: Data) throws {
        defaults.set(value, forKey: key)
        guard defaults.synchronize(), defaults.data(forKey: key) == value else { throw DownloadGaoExchangeJournal.invalid }
    }
}

/// One process owns the journal. Pending evidence causes recovery mode after any interrupted commit.
final class DownloadGaoExchangeJournal {
    static let invalid = DownloadGaoActionPackageError("exchange_recovery_required", "跨应用账本缺失、损坏或恢复未完成，已停止接收和发送。请保留原资料并恢复完整备份。")
    private struct Envelope: Codable { var schemaVersion = 1; var identity: UUID; var generation: Int; var records: [DownloadGaoExchangeRecord] }
    private struct Marker: Codable { var schemaVersion = 1; var identity: UUID; var generation: Int; var digest: String; var pending: Bool }
    private let directory: URL
    private let evidence: DownloadGaoExchangeEvidence
    private let historyDefaults: PortalDownloadMigrationDefaults
    private var envelope: Envelope
    private var digest: String
    private let directoryFD: Int32
    private let lockFD: Int32
    private var valid = true
    var records: [DownloadGaoExchangeRecord] { envelope.records }

    init(directory: URL, evidence: DownloadGaoExchangeEvidence? = nil,
         historyDefaults: PortalDownloadMigrationDefaults = UserDefaults.standard) throws {
        self.directory = directory; self.evidence = evidence ?? DownloadGaoExchangeDefaultsEvidence(directory: directory)
        self.historyDefaults = historyDefaults
        _ = try PortalDownloadHistoryIsolation.readHistory(destinationRootURL: directory.deletingLastPathComponent(), targetDefaults: historyDefaults)
        let external = try self.evidence.load()
        var info = stat(); let exists = lstat(directory.path, &info) == 0
        guard exists || errno == ENOENT else { throw Self.invalid }
        if external == nil { guard !exists else { throw Self.invalid } }
        else { guard exists else { throw Self.invalid } }
        let first = Envelope(identity: UUID(), generation: 1, records: [])
        let firstData = try JSONEncoder().encode(first)
        // Set the external marker before any directory creation: interrupted first initialization cannot look new.
        if external == nil { try self.evidence.save(try JSONEncoder().encode(Marker(identity: first.identity, generation: 1, digest: DownloadGaoActionPackage.digest(firstData), pending: true))) }
        let dir = try DownloadGaoActionPackage.ensurePrivateDirectory(directory)
        var lock: Int32 = -1
        do {
            lock = openat(dir, "journal.lock", O_RDWR | O_NOFOLLOW | O_CLOEXEC | (external == nil ? O_CREAT | O_EXCL : 0), 0o600)
            guard lock >= 0 else { throw Self.invalid }
            _ = try DownloadGaoActionPackage.requireRegular(lock)
            guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw Self.invalid }
            if let external {
                let marker = try JSONDecoder().decode(Marker.self, from: external)
                let bytes = try Self.read(at: dir)
                let value = try JSONDecoder().decode(Envelope.self, from: bytes)
                guard marker.schemaVersion == 1, !marker.pending, marker.generation > 0,
                      value.schemaVersion == 1, value.identity == marker.identity, value.generation == marker.generation,
                      marker.digest == DownloadGaoActionPackage.digest(bytes), Self.validRecords(value.records, root: directory) else { throw Self.invalid }
                self.envelope = value; self.digest = marker.digest
            } else {
                try Self.write(firstData, at: dir, initial: true)
                let hash = DownloadGaoActionPackage.digest(firstData)
                try self.evidence.save(try JSONEncoder().encode(Marker(identity: first.identity, generation: 1, digest: hash, pending: false)))
                self.envelope = first; self.digest = hash
            }
            self.directoryFD = dir; self.lockFD = lock
        } catch { if lock >= 0 { close(lock) }; close(dir); throw Self.invalid }
    }
    deinit { close(lockFD); close(directoryFD) }

    /// Pure validation for a read-only migration snapshot. It never creates an
    /// empty journal, takes ownership of the legacy store, or touches defaults.
    static func validateHistoricalSnapshot(_ raw: Data, evidence: Data, directory: URL) throws -> [DownloadGaoExchangeRecord] {
        guard raw.count > 0, raw.count <= 16 * 1_048_576, evidence.count <= 4096 else { throw Self.invalid }
        let marker = try JSONDecoder().decode(Marker.self, from: evidence)
        let value = try JSONDecoder().decode(Envelope.self, from: raw)
        guard marker.schemaVersion == 1, !marker.pending, marker.generation > 0,
              value.schemaVersion == 1, value.identity == marker.identity,
              value.generation == marker.generation, marker.digest == DownloadGaoActionPackage.digest(raw),
              Self.validRecords(value.records, root: directory) else { throw Self.invalid }
        return value.records
    }

    func verify() throws {
        guard valid else { throw Self.invalid }
        do {
            _ = try PortalDownloadHistoryIsolation.readHistory(destinationRootURL: directory.deletingLastPathComponent(), targetDefaults: historyDefaults)
            let reopened = try DownloadGaoActionPackage.openAbsoluteDirectory(directory); defer { close(reopened) }
            try DownloadGaoActionPackage.requirePrivateDirectory(reopened)
            let a = try DownloadGaoActionPackage.metadata(reopened); let b = try DownloadGaoActionPackage.metadata(directoryFD)
            let lock = try DownloadGaoActionPackage.openRegular(at: reopened, name: "journal.lock"); defer { close(lock) }
            let c = try DownloadGaoActionPackage.metadata(lock); let d = try DownloadGaoActionPackage.metadata(lockFD)
            guard a.st_dev == b.st_dev, a.st_ino == b.st_ino, c.st_dev == d.st_dev, c.st_ino == d.st_ino,
                  let raw = try evidence.load() else { throw Self.invalid }
            let marker = try JSONDecoder().decode(Marker.self, from: raw)
            guard marker.schemaVersion == 1, !marker.pending, marker.identity == envelope.identity,
                  marker.generation == envelope.generation, marker.digest == digest,
                  DownloadGaoActionPackage.digest(try Self.read(at: directoryFD)) == digest else { throw Self.invalid }
        } catch { valid = false; throw Self.invalid }
    }
    func append(_ record: DownloadGaoExchangeRecord) throws {
        try PortalDownloadHistoryIsolation.guardNewRequest(root: directory.deletingLastPathComponent(), requestID: record.id.uuidString,
            nonce: record.manifest.nonce, targetDefaults: historyDefaults)
        guard !envelope.records.contains(where: { $0.id == record.id }), envelope.records.count < 4096 else { throw Self.invalid }
        var next = envelope; next.records.append(record); try persist(next)
    }
    func replace(_ record: DownloadGaoExchangeRecord) throws {
        guard let index = envelope.records.firstIndex(where: { $0.id == record.id }) else { throw Self.invalid }
        if !(try PortalDownloadHistoryIsolation.readHistory(destinationRootURL: directory.deletingLastPathComponent(), targetDefaults: historyDefaults)).isEmpty {
            let old = envelope.records[index]
            try PortalDownloadHistoryIsolation.guardNewRequest(root: directory.deletingLastPathComponent(), requestID: record.id.uuidString,
                nonce: record.manifest.nonce, targetDefaults: historyDefaults)
            guard !old.isLegacyHistory, !record.isLegacyHistory, old.manifest == record.manifest,
                  old.manifestSHA256 == record.manifestSHA256, old.packageName == record.packageName,
                  old.sourceBundleID == record.sourceBundleID, old.urls == record.urls, old.receivedAt == record.receivedAt else { throw Self.invalid }
        }
        var next = envelope; next.records[index] = record; try persist(next)
    }
    private func persist(_ value: Envelope) throws {
        try verify(); var next = value
        guard next.generation < Int.max else { throw Self.invalid }; next.generation += 1
        guard Self.validRecords(next.records, root: directory) else { throw Self.invalid }
        let raw = try JSONEncoder().encode(next); let hash = DownloadGaoActionPackage.digest(raw)
        guard raw.count <= 16 * 1_048_576 else { throw Self.invalid }
        do {
            try evidence.save(try JSONEncoder().encode(Marker(identity: next.identity, generation: next.generation, digest: hash, pending: true)))
            try Self.write(raw, at: directoryFD, initial: false)
            try evidence.save(try JSONEncoder().encode(Marker(identity: next.identity, generation: next.generation, digest: hash, pending: false)))
            envelope = next; digest = hash
        } catch { valid = false; throw Self.invalid }
    }
    private static func validRecords(_ records: [DownloadGaoExchangeRecord], root: URL) -> Bool {
        guard records.count <= 4096, Set(records.map(\.id)).count == records.count else { return false }
        var tasks = Set<UUID>(); var itemIDs = Set<UUID>(); var resultIDs = Set<String>(); var nonces = Set<String>()
        for record in records {
            guard UUID(uuidString: record.manifest.requestID) == record.id, record.sourceBundleID == record.manifest.sourceBundleID,
                  record.urls == record.manifest.parameters["urls"]?.array?.compactMap(\.string),
                  record.receivedAt.timeIntervalSince1970.isFinite,
                  record.manifestSHA256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                  safePackageName(record.packageName), nonces.insert(record.manifest.nonce).inserted,
                  ["awaitingReview", "accepted", "completed", "partial", "failed", "cancelled"].contains(record.stage),
                  record.taskIDs.isEmpty || record.taskIDs.count == record.urls.count,
                  Set(record.taskIDs).count == record.taskIDs.count, tasks.isDisjoint(with: record.taskIDs),
                  record.itemIDs.isEmpty || record.itemIDs.count == record.taskIDs.count,
                  Set(record.itemIDs).count == record.itemIDs.count, itemIDs.isDisjoint(with: record.itemIDs),
                  record.deliveries.count <= 256, record.deliveries.count == record.outgoingURLs.count else { return false }
            do { try DownloadGaoDownloadContract.validateHistoricalRequest(record.manifest) } catch { return false }
            tasks.formUnion(record.taskIDs); itemIDs.formUnion(record.itemIDs)
            if record.stage == "awaitingReview", !record.taskIDs.isEmpty || !record.deliveries.isEmpty { return false }
            if record.stage == "accepted", record.taskIDs.isEmpty { return false }
            if !record.outcomes.isEmpty {
                guard record.outcomes.count == record.taskIDs.count,
                      record.outcomes.map(\.taskID) == record.taskIDs, record.outcomes.map(\.itemID) == record.itemIDs,
                      record.outcomes.allSatisfy({ ["completed", "failed", "cancelled"].contains($0.state) && DownloadGaoDownloadContract.safeCode($0.errorCode) }) else { return false }
            }
            for (index, delivery) in record.deliveries.enumerated() {
                let m = delivery.manifest
                guard safePackageName(delivery.packageName), delivery.packageName == m.requestID + ".gaoaction",
                      resultIDs.insert(m.requestID.lowercased()).inserted, UUID(uuidString: m.requestID) != nil,
                      !records.contains(where: { $0.id == UUID(uuidString: m.requestID) }),
                      m.inReplyTo == record.id.uuidString.lowercased(), m.targetBundleID == record.sourceBundleID,
                      m.sourceBundleID == record.manifest.targetBundleID,
                      m.provenance?["taskIDs"]?.array?.compactMap(\.string) == record.taskIDs.map({ $0.uuidString.lowercased() }),
                      delivery.fingerprint == (try? DownloadGaoActionPackage.digest(DownloadGaoActionPackage.manifestData(m))),
                      delivery.attempts >= 0, delivery.handedOffAt == nil || delivery.handedOffAt!.timeIntervalSince1970.isFinite,
                      record.outgoingURLs[index] == root.appendingPathComponent("Outgoing").appendingPathComponent(delivery.packageName, isDirectory: true) else { return false }
                do { try DownloadGaoDownloadContract.validateHistoricalResult(m) } catch { return false }
            }
            let hasFinal = record.deliveries.contains { $0.manifest.status != "pending" }
            guard record.hasFinalResult == hasFinal else { return false }
            if hasFinal { guard record.stage != "accepted", record.stage != "awaitingReview" else { return false } }
        }
        return true
    }
    private static func safePackageName(_ name: String) -> Bool { !name.contains("/") && !name.contains("\\") && name.hasSuffix(".gaoaction") && UUID(uuidString: String(name.dropLast(10))) != nil }
    private static func read(at parent: Int32) throws -> Data {
        let fd = try DownloadGaoActionPackage.openRegular(at: parent, name: "journal.json"); defer { close(fd) }
        let before = try DownloadGaoActionPackage.requireRegular(fd)
        guard before.st_size > 0, before.st_size <= 16 * 1_048_576 else { throw Self.invalid }
        let bytes = try DownloadGaoActionPackage.readBounded(fd, limit: 16 * 1_048_576)
        try DownloadGaoActionPackage.requireUnchanged(before, DownloadGaoActionPackage.metadata(fd))
        guard Int64(bytes.count) == before.st_size else { throw Self.invalid }; return bytes
    }
    private static func write(_ data: Data, at parent: Int32, initial: Bool) throws {
        let name = ".journal-" + UUID().uuidString
        try DownloadGaoActionPackage.writeFile(data, directory: parent, name: name)
        defer { unlinkat(parent, name, 0) }
        if initial { guard renameatx_np(parent, name, parent, "journal.json", UInt32(RENAME_EXCL)) == 0 else { throw Self.invalid } }
        else { guard renameat(parent, name, parent, "journal.json") == 0 else { throw Self.invalid } }
        guard fsync(parent) == 0 else { throw Self.invalid }
    }
}
