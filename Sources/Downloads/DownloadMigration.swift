import Foundation
import CryptoKit
import Darwin

protocol PortalDownloadMigrationDefaults: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    func synchronize() -> Bool
    func data(forKey key: String) -> Data?
}
extension UserDefaults: PortalDownloadMigrationDefaults {}

/// Startup only inspects evidence. It never imports, creates a queue, or opens an old grant.
enum PortalDownloadMigrationReadiness: Equatable {
    case newInstallation, ready, requiresMigration, recoveryRequired(String)
}

struct PortalDownloadMigrationAuthority: Codable, Equatable {
    let schemaVersion: Int
    let sourceBundleID: String
    let targetBundleID: String
    let sourceFrozen: Bool
    let sourceRoot: String
    let targetRoot: String
    let sourceManifestSHA256: String
    let sourceMarkerSHA256: String
    let sourcePreferencesSHA256: String
    let backupReceiptSHA256: String
}

struct PortalDownloadMigrationPreflight: Codable, Equatable {
    let schemaVersion: Int
    let sourceInstallationID: UUID
    let sourceRoot: String
    let sourceManifestSHA256: String
    let sourceMarkerSHA256: String
    let sourcePreferencesSHA256: String
    let jobCount: Int
    let itemCount: Int
    let destinationCount: Int
    let completedItems: Int
}

struct PortalDownloadMigrationReceipt: Codable, Equatable {
    let schemaVersion: Int
    let migrationID: UUID
    let sourceInstallationID: UUID
    let sourceRoot: String
    let targetRoot: String
    let sourceManifestSHA256: String
    let sourceMarkerSHA256: String
    let sourcePreferencesSHA256: String
    let taskIDs: [String]
    let itemIDs: [String]
    let destinationIDs: [String]
    let completedItems: Int
    let interruptedItems: Int
    let grantsRequireNewHostAuthorization: Bool
    let oldExchangeRetainedAsHistoryOnly: Bool
    let importedAt: Date
    var authoritySHA256: String? = nil
    var backupReceiptSHA256: String? = nil
}

/// An explicit, fail-closed import. The coordinator must stop/fence the old writer
/// before setting sourceRetired. No source file, grant, partial, or download is modified.
/// A validated transaction can be retried without duplicating tasks. An interrupted
/// preparation is retained for recovery rather than being mistaken for a new queue.
enum PortalDownloadMigration {
    struct FileRecord: Codable, Equatable {
        let byteCount: Int64
        let sha256: String
    }
    struct Tree: Codable, Equatable {
        let files: [String: FileRecord]
        let directories: [String]
    }
    struct DatabaseEnvelope: Codable { let payload: Data; let sha256: String }
    struct ExchangeEnvelope: Codable {
        var schemaVersion: Int
        var identity: UUID
        var generation: Int
        var records: [DownloadGaoExchangeRecord]
    }
    struct ExchangeEvidence: Codable {
        var schemaVersion: Int
        var identity: UUID
        var generation: Int
        var digest: String
        var pending: Bool
    }
    private struct Transaction: Codable {
        let schemaVersion: Int
        let migrationID: UUID
        var phase: String
        let sourceRoot: String
        let targetRoot: String
        let containerName: String
        var sourceTree: Tree?
        var targetTree: Tree?
        var marker: Data?
        var sourcePreferencesSHA256: String?
        var exchangeEvidence: Data?
        var receiptSHA256: String?
        var authoritySHA256: String? = nil
    }
    static let evidencePrefix = "GaoMenHu.DownloadMigration."
    static let exchangeEvidencePrefix = "GaoMenHu.DownloadExchangeEvidence."
    static let legacyExchangeEvidencePrefix = "GaoXiaZai.ExchangeEvidence."
    private static let receiptName = "MigrationEvidence/receipt.json"
    private static let maxTotalBytes: Int64 = 8 * 1024 * 1024 * 1024
    private static let maxFiles = 65_536
    static func issue(_ text: String = "下载迁移证据缺失、冲突或不完整；已停止写入，请保留来源资料和完整备份。") -> DownloadError { .message(text) }
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value)
    }
    static func evidenceKey(destinationRootURL: URL) -> String {
        evidencePrefix + downloadDigest(Data(destinationRootURL.path.utf8))
    }
    static func exchangeKey(directory: URL, legacy: Bool = false) -> String {
        if legacy { return legacyExchangeEvidencePrefix + downloadDigest(Data(directory.standardizedFileURL.path.utf8)) }
        return DownloadGaoExchangeDefaultsEvidence.evidenceKey(for: directory)
    }
    static func physicalRoot(_ value: URL) throws -> URL {
        // Foundation.standardizedFileURL shortens an existing /private/tmp to
        // /tmp on macOS. That alias is itself a symlink and must not replace a
        // caller's already physical FD-safe path, or change evidence after mkdir.
        guard value.isFileURL, value.host == nil || value.host == "localhost",
              value.path.hasPrefix("/"), value.path != "/", value.path.utf8.count <= 16_384,
              value.pathComponents.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw issue() }
        return URL(fileURLWithPath: value.path, isDirectory: true)
    }
    static func markerURL(_ root: URL) -> URL {
        root.deletingLastPathComponent().appendingPathComponent(".\(root.lastPathComponent).initialized-v1.json")
    }
    static func exists(_ url: URL) throws -> Bool {
        var info = stat()
        if lstat(url.path, &info) == 0 { return true }
        guard errno == ENOENT else { throw issue() }; return false
    }
    private static func transaction(_ defaults: PortalDownloadMigrationDefaults, key: String) throws -> Transaction? {
        guard let raw = defaults.object(forKey: key) else { return nil }
        guard let data = raw as? Data, data.count <= 32 * 1024 * 1024,
              let value = try? JSONDecoder().decode(Transaction.self, from: data), value.schemaVersion == 1,
              ["preparing", "validated", "committed"].contains(value.phase),
              value.containerName == ".DownloadCenter-Migration-\(value.migrationID.uuidString).noindex" else { throw issue() }
        return value
    }
    private static func save(_ value: Transaction, defaults: PortalDownloadMigrationDefaults, key: String) throws {
        let data = try encode(value); defaults.set(data, forKey: key)
        guard defaults.synchronize(), defaults.data(forKey: key) == data else { throw issue("迁移独立证据无法持久保存，未开放下载队列。") }
    }
    static func readiness(destinationRootURL: URL, legacyRootURL: URL,
                          sourcePreferences: [String: Data], targetDefaults: PortalDownloadMigrationDefaults = UserDefaults.standard) -> PortalDownloadMigrationReadiness {
        do {
            let target = try physicalRoot(destinationRootURL), source = try physicalRoot(legacyRootURL)
            if let isolated = PortalDownloadHistoryIsolation.readiness(destinationRootURL: target, targetDefaults: targetDefaults) { return isolated }
            let targetExists = try exists(target), targetMarker = try exists(markerURL(target))
            if let pending = try transaction(targetDefaults, key: evidenceKey(destinationRootURL: target)) {
                guard pending.targetRoot == target.path, pending.sourceRoot == source.path else { throw issue() }
                guard pending.phase == "committed" else { return .recoveryRequired("下载迁移尚未完成；请继续原迁移事务，不创建空队列。") }
                guard targetExists, targetMarker else { throw issue() }
                let raw = try read(target.appendingPathComponent(receiptName), limit: 8 * 1024 * 1024)
                guard downloadDigest(raw) == pending.receiptSHA256 else { throw issue() }
                let receipt = try JSONDecoder().decode(PortalDownloadMigrationReceipt.self, from: raw)
                let store = try DownloadStore(root: target, readOnly: true)
                guard try store.load().installationID == receipt.sourceInstallationID else { throw issue() }
                return .ready
            }
            if targetExists || targetMarker {
                guard targetExists, targetMarker,
                      !(try exists(target.appendingPathComponent(receiptName))),
                      !(try exists(source)), !(try exists(markerURL(source))),
                      !sourcePreferences.keys.contains(where: { $0.hasPrefix(legacyExchangeEvidencePrefix) }) else {
                    throw issue("已有目标队列与旧下载资料并存或迁移独立证据缺失；未覆盖任何一边，请协调合并恢复。")
                }
                let store = try DownloadStore(root: target, readOnly: true); _ = try store.load()
                return .ready
            }
            guard targetDefaults.object(forKey: exchangeKey(directory: target.appendingPathComponent("Exchange", isDirectory: true))) == nil else { throw issue() }
            let sourceExists = try exists(source), sourceMarker = try exists(markerURL(source))
            let historical = sourcePreferences.keys.contains { $0.hasPrefix(legacyExchangeEvidencePrefix) }
            if !sourceExists && (sourceMarker || historical) { throw issue("旧下载资料缺失，但初始化或交换依据仍存在；未创建空队列，请恢复完整来源。") }
            if sourceExists || sourceMarker || historical { return .requiresMigration }
            return .newInstallation
        } catch { return .recoveryRequired((error as? DownloadError)?.localizedDescription ?? "下载迁移依据不可读，已停止写入。") }
    }

    /// Read-only source plan used after the coordinator fences the old writer.
    /// The same sorted file manifest encoding is used by prepare's authority gate.
    static func preflight(legacyRootURL: URL, sourcePreferences: [String: Data]) throws -> PortalDownloadMigrationPreflight {
        let source = try physicalRoot(legacyRootURL)
        guard try exists(source), try exists(markerURL(source)) else { throw issue() }
        let store = try DownloadStore(root: source, readOnly: true)
        let database = try store.load(), marker = try read(markerURL(source), limit: 4096)
        if try exists(source.appendingPathComponent("downloads.previous.json")) {
            _ = try DownloadStore.validateSnapshot(read(source.appendingPathComponent("downloads.previous.json"), limit: 32 * 1024 * 1024), marker: marker)
        }
        let exchange = source.appendingPathComponent("Exchange", isDirectory: true)
        let key = exchangeKey(directory: exchange, legacy: true)
        let evidenceKeys = Set(sourcePreferences.keys.filter { $0.hasPrefix(legacyExchangeEvidencePrefix) })
        guard evidenceKeys.isEmpty || evidenceKeys == [key],
              try exists(exchange) == (sourcePreferences[key] != nil) else { throw issue() }
        var journalLock: Int32 = -1
        defer { if journalLock >= 0 { close(journalLock) }; withExtendedLifetime(store) {} }
        if let evidence = sourcePreferences[key] {
            let fd = try openDirectoryNoLinks(exchange); defer { close(fd) }; try requirePrivateDirectory(fd)
            journalLock = openat(fd, "journal.lock", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard journalLock >= 0, regularOwned(try statIdentity(journalLock)), flock(journalLock, LOCK_EX | LOCK_NB) == 0 else { throw issue() }
            let journal = try read(exchange.appendingPathComponent("journal.json"), limit: 16 * 1024 * 1024)
            let records = try DownloadGaoExchangeJournal.validateHistoricalSnapshot(journal, evidence: evidence, directory: exchange)
            guard records.allSatisfy({ $0.manifest.targetBundleID == DownloadGaoDownloadContract.legacyBundleID }) else { throw issue() }
            try validateMappings(records, database: database)
            for record in records {
                try validateHistoricalPackage(exchange.appendingPathComponent("Incoming", isDirectory: true).appendingPathComponent(record.packageName, isDirectory: true), manifest: record.manifest, sha256: record.manifestSHA256)
                for delivery in record.deliveries {
                    try validateHistoricalPackage(exchange.appendingPathComponent("Outgoing", isDirectory: true).appendingPathComponent(delivery.packageName, isDirectory: true), manifest: delivery.manifest, sha256: delivery.fingerprint)
                }
            }
        }
        let snapshot = try tree(source)
        guard try tree(source) == snapshot, try read(markerURL(source), limit: 4096) == marker else { throw issue() }
        let preferences = try encode(sourcePreferences)
        guard preferences.count <= 32 * 1024 * 1024 else { throw issue() }
        return PortalDownloadMigrationPreflight(schemaVersion: 1, sourceInstallationID: database.installationID,
            sourceRoot: source.path, sourceManifestSHA256: downloadDigest(try encode(snapshot)),
            sourceMarkerSHA256: downloadDigest(marker), sourcePreferencesSHA256: downloadDigest(preferences),
            jobCount: database.jobs.count, itemCount: database.items.count, destinationCount: database.destinations.count,
            completedItems: database.items.filter { $0.state == .completed }.count)
    }
    private static func validateAuthorityShape(_ value: PortalDownloadMigrationAuthority, source: URL, target: URL) throws {
        func digest(_ value: String) -> Bool { value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
        guard value.schemaVersion == 1, value.sourceBundleID == "com.gaoseries.GaoXiaZai",
              value.targetBundleID == "cn.mendao.launcher", value.sourceFrozen,
              value.sourceRoot == source.path, value.targetRoot == target.path,
              [value.sourceManifestSHA256, value.sourceMarkerSHA256, value.sourcePreferencesSHA256, value.backupReceiptSHA256].allSatisfy(digest) else {
            throw issue("迁移授权的宿主、停写状态、路径或完整备份摘要无效，未开始迁移事务。")
        }
    }

    static func prepare(destinationRootURL: URL, legacyRootURL: URL,
                        sourcePreferences: [String: Data], targetDefaults: PortalDownloadMigrationDefaults = UserDefaults.standard,
                        sourceRetired: Bool = false, authority: PortalDownloadMigrationAuthority? = nil,
                        fault: ((String) throws -> Void)? = nil) throws -> PortalDownloadMigrationReceipt {
        guard targetDefaults.object(forKey: PortalDownloadHistoryIsolation.evidenceKey(root: destinationRootURL)) == nil else { throw issue("隔离历史迁移已有独立事务；不能改用正常迁移覆盖。") }
        guard sourceRetired else { throw issue("请先由迁移协调停止旧下载宿主并完成备份与切换；本程序不会自动迁移或启动旧应用。") }
        let target = try physicalRoot(destinationRootURL), source = try physicalRoot(legacyRootURL)
        guard target.isFileURL, source.isFileURL, target.path != source.path,
              !target.path.hasPrefix(source.path + "/"), !source.path.hasPrefix(target.path + "/") else { throw issue() }
        if let authority { try validateAuthorityShape(authority, source: source, target: target) }
        let authoritySHA256 = try authority.map { downloadDigest(try encode($0)) }
        let parent = target.deletingLastPathComponent()
        let parentFD = try openDirectoryNoLinks(parent); defer { close(parentFD) }
        try requirePrivateDirectory(parentFD)
        try fault?("migration.parentOpened")
        let key = evidenceKey(destinationRootURL: target)
        let lock = openat(parentFD, ".DownloadCenter.migration.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw issue() }; defer { close(lock) }
        guard regularOwned(try statIdentity(lock)), flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw issue("另一下载迁移正在进行，未写入任何任务。") }
        var pending = try transaction(targetDefaults, key: key)
        if let committed = pending, committed.phase == "committed" {
            guard committed.targetRoot == target.path, committed.sourceRoot == source.path,
                  try exists(target), try exists(markerURL(target)),
                  committed.authoritySHA256 == authoritySHA256 else { throw issue() }
            let raw = try read(target.appendingPathComponent(receiptName), limit: 8 * 1024 * 1024)
            guard downloadDigest(raw) == committed.receiptSHA256 else { throw issue() }
            // Never overwrite a live queue with the old snapshot on an idempotent retry.
            let receipt = try JSONDecoder().decode(PortalDownloadMigrationReceipt.self, from: raw)
            let store = try DownloadStore(root: target, readOnly: true)
            guard try store.load().installationID == receipt.sourceInstallationID else { throw issue() }
            return receipt
        }
        guard try exists(source), try exists(markerURL(source)),
              !(try exists(target)) || pending?.phase == "validated",
              !(try exists(markerURL(target))) || pending?.phase == "validated" else { throw issue() }
        // A read-only source store takes the existing shared flock. The original
        // writer takes exclusive flock, so it cannot mutate while import is open.
        let sourceStore = try DownloadStore(root: source, readOnly: true)
        try fault?("migration.sourceStoreOpened")
        let database = try sourceStore.load()
        try fault?("migration.sourceLoaded")
        let sourceMarker = try read(markerURL(source), limit: 4096)
        try fault?("migration.sourceMarkerRead")
        if try exists(source.appendingPathComponent("downloads.previous.json")) {
            _ = try DownloadStore.validateSnapshot(read(source.appendingPathComponent("downloads.previous.json"), limit: 32 * 1024 * 1024), marker: sourceMarker)
        }
        try fault?("migration.previousRead")
        let preferenceBytes = try encode(sourcePreferences)
        let exchange = source.appendingPathComponent("Exchange", isDirectory: true)
        let oldEvidenceKey = exchangeKey(directory: exchange, legacy: true)
        let oldEvidence = sourcePreferences[oldEvidenceKey]
        let evidenceKeys = Set(sourcePreferences.keys.filter { $0.hasPrefix(legacyExchangeEvidencePrefix) })
        guard evidenceKeys.isEmpty || evidenceKeys == [oldEvidenceKey] else { throw issue("旧下载交换依据属于其他资料路径，请先核对完整备份与原目录，未丢弃任何历史。") }
        let exchangeExists = try exists(exchange)
        guard exchangeExists == (oldEvidence != nil) else { throw issue("旧下载交换目录与独立证据不匹配，不能丢弃历史后导入空账本。") }
        var journalLock: Int32 = -1
        defer { if journalLock >= 0 { close(journalLock) }; withExtendedLifetime(sourceStore) {} }
        if exchangeExists {
            let fd = try openDirectoryNoLinks(exchange); defer { close(fd) }; try requirePrivateDirectory(fd)
            journalLock = openat(fd, "journal.lock", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard journalLock >= 0, regularOwned(try statIdentity(journalLock)), flock(journalLock, LOCK_EX | LOCK_NB) == 0 else { throw issue("旧下载交换账本仍在使用，未开始切换。") }
        }
        try fault?("migration.sourceExchangeChecked")
        let originalTree = try tree(source)
        try fault?("migration.sourceTreeRead")
        if let authority {
            guard authority.sourceManifestSHA256 == downloadDigest(try encode(originalTree)),
                  authority.sourceMarkerSHA256 == downloadDigest(sourceMarker),
                  authority.sourcePreferencesSHA256 == downloadDigest(preferenceBytes) else { throw issue("来源摘要已改变或授权依据过期，未开始迁移事务。") }
        }
        if let value = pending {
            guard value.phase == "validated", value.sourceRoot == source.path, value.targetRoot == target.path,
                  value.sourceTree == originalTree, value.marker == sourceMarker,
                  value.sourcePreferencesSHA256 == downloadDigest(preferenceBytes),
                  value.authoritySHA256 == authoritySHA256 else { throw issue() }
        } else {
            let id = UUID()
            pending = Transaction(schemaVersion: 1, migrationID: id, phase: "preparing", sourceRoot: source.path,
                targetRoot: target.path, containerName: ".DownloadCenter-Migration-\(id.uuidString).noindex",
                authoritySHA256: authoritySHA256)
            try save(pending!, defaults: targetDefaults, key: key)
            try fault?("migration.preparing")
        }
        var value = pending!
        let container = parent.appendingPathComponent(value.containerName, isDirectory: true)
        let staged = container.appendingPathComponent(target.lastPathComponent, isDirectory: true)
        if value.phase == "preparing" {
            guard !(try exists(container)), !(try exists(target)), !(try exists(markerURL(target))) else { throw issue() }
            try makeDirectory(container); try makeDirectory(staged)
            try copy(source, to: staged, expected: originalTree)
            try write(sourceMarker, at: markerURL(staged), replacing: false)
            try fault?("migration.copied")
            let evidenceDirectory = staged.appendingPathComponent("MigrationEvidence", isDirectory: true)
            try makeDirectory(evidenceDirectory)
            try write(sourceMarker, at: evidenceDirectory.appendingPathComponent("source-initialization.json"), replacing: false)
            try write(preferenceBytes, at: evidenceDirectory.appendingPathComponent("source-preferences.json"), replacing: false)
            try write(try encode(originalTree), at: evidenceDirectory.appendingPathComponent("source-files.json"), replacing: false)
            try write(try read(staged.appendingPathComponent("downloads.json"), limit: 32 * 1024 * 1024),
                      at: evidenceDirectory.appendingPathComponent("source-downloads.json"), replacing: false)
            var next = database
            guard next.revision < UInt64.max else { throw issue() }
            next.revision += 1
            next.migrationHistory.append("GaoXiaZai->GaoMenHu:\(value.migrationID.uuidString)")
            for index in next.destinations.indices { next.destinations[index].requiresReauthorization = true }
            for index in next.items.indices where !next.items[index].state.isTerminal {
                // Keep pendingArtifact/staging identity and validators intact.
                next.items[index].state = .waitingForDestination
                next.items[index].bytesPerSecond = 0
                next.items[index].retryAt = nil
                next.items[index].resumeExplanation = "迁移已保留原断点；请在搞门户重新选择原目录，核验身份、片段摘要和资源版本后手动恢复。"
            }
            let payload = try encode(next)
            try write(try encode(DatabaseEnvelope(payload: payload, sha256: downloadDigest(payload))),
                      at: staged.appendingPathComponent("downloads.json"), replacing: true)
            var migratedExchangeEvidence: Data?
            if exchangeExists, let oldEvidence {
                let journal = try read(exchange.appendingPathComponent("journal.json"), limit: 16 * 1024 * 1024)
                let historical = try DownloadGaoExchangeJournal.validateHistoricalSnapshot(journal, evidence: oldEvidence, directory: exchange)
                guard historical.allSatisfy({ $0.manifest.targetBundleID == DownloadGaoDownloadContract.legacyBundleID }) else { throw issue("来源账本含非旧下载宿主的请求，未将它们当作可执行的新请求导入。") }
                try validateMappings(historical, database: database)
                for record in historical {
                    try validateHistoricalPackage(exchange.appendingPathComponent("Incoming", isDirectory: true).appendingPathComponent(record.packageName, isDirectory: true), manifest: record.manifest, sha256: record.manifestSHA256)
                    for delivery in record.deliveries {
                        try validateHistoricalPackage(exchange.appendingPathComponent("Outgoing", isDirectory: true).appendingPathComponent(delivery.packageName, isDirectory: true), manifest: delivery.manifest, sha256: delivery.fingerprint)
                    }
                }
                try write(journal, at: evidenceDirectory.appendingPathComponent("source-journal.json"), replacing: false)
                var envelope = try JSONDecoder().decode(ExchangeEnvelope.self, from: journal)
                guard envelope.generation < Int.max else { throw issue() }; envelope.generation += 1
                for index in envelope.records.indices {
                    envelope.records[index].outgoingURLs = envelope.records[index].deliveries.map {
                        target.appendingPathComponent("Exchange/Outgoing", isDirectory: true).appendingPathComponent($0.packageName, isDirectory: true)
                    }
                }
                let bytes = try encode(envelope)
                let external = try encode(ExchangeEvidence(schemaVersion: 1, identity: envelope.identity,
                    generation: envelope.generation, digest: downloadDigest(bytes), pending: false))
                _ = try DownloadGaoExchangeJournal.validateHistoricalSnapshot(bytes, evidence: external,
                    directory: target.appendingPathComponent("Exchange", isDirectory: true))
                try write(bytes, at: staged.appendingPathComponent("Exchange/journal.json"), replacing: true)
                migratedExchangeEvidence = external
            }
            var receipt = PortalDownloadMigrationReceipt(schemaVersion: 1, migrationID: value.migrationID,
                sourceInstallationID: database.installationID, sourceRoot: source.path, targetRoot: target.path,
                sourceManifestSHA256: downloadDigest(try encode(originalTree)), sourceMarkerSHA256: downloadDigest(sourceMarker),
                sourcePreferencesSHA256: downloadDigest(preferenceBytes), taskIDs: database.jobs.map { $0.id.uuidString },
                itemIDs: database.items.map { $0.id.uuidString }, destinationIDs: database.destinations.map { $0.id.uuidString },
                completedItems: database.items.filter { $0.state == .completed }.count,
                interruptedItems: database.items.filter { !$0.state.isTerminal }.count,
                grantsRequireNewHostAuthorization: true, oldExchangeRetainedAsHistoryOnly: true, importedAt: Date())
            receipt.authoritySHA256 = authoritySHA256
            receipt.backupReceiptSHA256 = authority?.backupReceiptSHA256
            let receiptData = try encode(receipt)
            try write(receiptData, at: staged.appendingPathComponent(receiptName), replacing: false)
            do { let store = try DownloadStore(root: staged, readOnly: true); _ = try store.load() }
            guard try tree(source) == originalTree,
                  try read(markerURL(source), limit: 4096) == sourceMarker else { throw issue("迁移期间来源资料变化，保留全部证据，未切换下载库。") }
            value.sourceTree = originalTree; value.targetTree = try tree(staged)
            value.marker = sourceMarker; value.sourcePreferencesSHA256 = downloadDigest(preferenceBytes)
            value.exchangeEvidence = migratedExchangeEvidence; value.receiptSHA256 = downloadDigest(receiptData)
            value.phase = "validated"; try save(value, defaults: targetDefaults, key: key)
            try fault?("migration.validated")
        }
        guard value.phase == "validated", let expected = value.targetTree, let marker = value.marker else { throw issue() }
        if try exists(target) { guard try tree(target) == expected, !(try exists(staged)) else { throw issue() } }
        else {
            guard try tree(staged) == expected else { throw issue() }
            let containerFD = try openDirectoryNoLinks(container); defer { close(containerFD) }
            guard renameatx_np(containerFD, target.lastPathComponent, parentFD, target.lastPathComponent, UInt32(RENAME_EXCL)) == 0,
                  fsync(parentFD) == 0, fsync(containerFD) == 0 else { throw issue() }
        }
        try fault?("migration.rootPublished")
        if try exists(markerURL(target)) { guard try read(markerURL(target), limit: 4096) == marker else { throw issue() } }
        else { try write(marker, at: markerURL(target), replacing: false) }
        try fault?("migration.markerPublished")
        let newExchangeKey = exchangeKey(directory: target.appendingPathComponent("Exchange", isDirectory: true))
        if let evidence = value.exchangeEvidence {
            if let current = targetDefaults.object(forKey: newExchangeKey) {
                guard (current as? Data) == evidence else { throw issue() }
            } else {
                targetDefaults.set(evidence, forKey: newExchangeKey)
                guard targetDefaults.synchronize(), targetDefaults.data(forKey: newExchangeKey) == evidence else { throw issue() }
            }
        } else { guard targetDefaults.object(forKey: newExchangeKey) == nil else { throw issue() } }
        try fault?("migration.evidencePublished")
        guard try tree(target) == expected, try tree(source) == originalTree,
              try read(markerURL(source), limit: 4096) == sourceMarker else { throw issue() }
        value.phase = "committed"; try save(value, defaults: targetDefaults, key: key)
        try fault?("migration.committed")
        // Only empty owned transaction containers are removed. Original history,
        // copied marker and all migration evidence stay available for rollback.
        if try exists(markerURL(staged)) { guard try read(markerURL(staged), limit: 4096) == marker else { throw issue() }; try FileManager.default.removeItem(at: markerURL(staged)) }
        if try exists(container) {
            let fd = try openDirectoryNoLinks(container); try requirePrivateDirectory(fd); close(fd)
            // rmdir refuses unexpected contents rather than recursively deleting evidence.
            guard rmdir(container.path) == 0 else { throw issue("迁移已提交；事务目录出现额外内容，保留该目录等待核对。") }
        }
        return try JSONDecoder().decode(PortalDownloadMigrationReceipt.self,
            from: read(target.appendingPathComponent(receiptName), limit: 8 * 1024 * 1024))
    }

    static func validateHistoricalPackage(_ package: URL, manifest: DownloadGaoActionManifest, sha256: String) throws {
        let raw = try read(package.appendingPathComponent("manifest.json"), limit: 1_048_576)
        guard downloadDigest(raw) == sha256 else { throw issue("历史请求或结果包与账本摘要不一致，已停止导入。") }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = manifest.createdAt.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        guard let created = formatter.date(from: manifest.createdAt) else { throw issue() }
        // Validate historical structure at its original validity window, never
        // turn an expired historical request into a currently executable one.
        let decoded = try DownloadGaoActionPackage.validate(data: raw, targetBundleID: manifest.targetBundleID,
            now: created, validateAction: {
                if $0.kind == "request" { try DownloadGaoDownloadContract.validateHistoricalRequest($0) }
                else { try DownloadGaoDownloadContract.validateHistoricalResult($0) }
            })
        guard decoded == manifest else { throw issue() }
        let snapshot = try tree(package)
        var expectedDirectories: Set<String> = ["payload"]
        for item in manifest.items {
            let components = item.relativePath.split(separator: "/").map(String.init)
            guard components.first == "payload", components.count > 1,
                  snapshot.files[item.relativePath] == FileRecord(byteCount: item.byteCount, sha256: item.sha256) else { throw issue("历史结果附件缺失或摘要损坏，未导入空结果。") }
            if components.count > 1 {
                for count in 1..<components.count { expectedDirectories.insert(components.prefix(count).joined(separator: "/")) }
            }
        }
        guard Set(snapshot.files.keys) == Set(["manifest.json"] + manifest.items.map(\.relativePath)),
              Set(snapshot.directories) == expectedDirectories else { throw issue("历史交接包包含缺失或未声明内容，保留来源等待恢复。") }
    }

    static func validateMappings(_ records: [DownloadGaoExchangeRecord], database: DownloadDatabase) throws {
        let jobs = Dictionary(uniqueKeysWithValues: database.jobs.map { ($0.id, $0) })
        let items = Dictionary(uniqueKeysWithValues: database.items.map { ($0.id, $0) })
        let recordIDs = Set(records.map(\.id))
        guard database.jobs.allSatisfy({ $0.requestID == nil || recordIDs.contains($0.requestID!) }) else { throw issue("旧任务与请求账本的关联缺失，未导入为新任务。") }
        for record in records {
            let associated = database.jobs.filter { $0.requestID == record.id }
            if record.taskIDs.isEmpty {
                guard associated.isEmpty else { throw issue("旧请求批准事务未完成，请先恢复来源的任务映射。") }; continue
            }
            guard Set(associated.map(\.id)) == Set(record.taskIDs), record.taskIDs.count == record.urls.count else { throw issue() }
            for (index, taskID) in record.taskIDs.enumerated() {
                guard let job = jobs[taskID], job.requestID == record.id, job.itemIDs.count == 1,
                      let itemID = job.itemIDs.first, let item = items[itemID],
                      item.sourceURL == (try validatedDownloadURL(record.urls[index])).absoluteString,
                      record.itemIDs.isEmpty || record.itemIDs[index] == itemID else { throw issue("旧请求与任务、链接或结果映射冲突，未重建或重下。") }
            }
        }
    }

    static func requirePrivateDirectory(_ fd: Int32) throws {
        let s = try statIdentity(fd)
        guard (s.st_mode & S_IFMT) == S_IFDIR, s.st_uid == getuid(), s.st_mode & 0o077 == 0 else { throw issue() }
    }
    static func makeDirectory(_ url: URL) throws {
        let parent = try openDirectoryNoLinks(url.deletingLastPathComponent()); defer { close(parent) }
        guard mkdirat(parent, url.lastPathComponent, 0o700) == 0, fsync(parent) == 0 else { throw issue() }
    }
    static func read(_ url: URL, limit: Int) throws -> Data {
        let parent = try openDirectoryNoLinks(url.deletingLastPathComponent()); defer { close(parent) }
        let fd = openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw issue() }; defer { close(fd) }
        let s = try statIdentity(fd)
        guard regularOwned(s), s.st_mode & 0o077 == 0, s.st_size >= 0, s.st_size <= limit else { throw issue() }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = Darwin.read(fd, &buffer, buffer.count)
            guard n >= 0 else { throw issue() }; if n == 0 { break }
            guard result.count + n <= limit else { throw issue() }; result.append(contentsOf: buffer.prefix(n))
        }
        let after = try statIdentity(fd)
        guard s.st_dev == after.st_dev, s.st_ino == after.st_ino, s.st_size == after.st_size,
              s.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, s.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw issue() }
        return result
    }
    static func write(_ data: Data, at url: URL, replacing: Bool) throws {
        let parent = try openDirectoryNoLinks(url.deletingLastPathComponent()); defer { close(parent) }
        let temp = ".migration-write-\(UUID().uuidString)"
        let fd = openat(parent, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw issue() }; defer { close(fd); unlinkat(parent, temp, 0) }
        try writeAll(data, to: fd); guard fsync(fd) == 0 else { throw issue() }
        if replacing { guard renameat(parent, temp, parent, url.lastPathComponent) == 0 else { throw issue() } }
        else { guard renameatx_np(parent, temp, parent, url.lastPathComponent, UInt32(RENAME_EXCL)) == 0 else { throw issue() } }
        guard fsync(parent) == 0 else { throw issue() }
    }
    static func tree(_ root: URL) throws -> Tree {
        let rootFD = try openDirectoryNoLinks(root); defer { close(rootFD) }; try requirePrivateDirectory(rootFD)
        let original = try statIdentity(rootFD)
        var files: [String: FileRecord] = [:], directories: [String] = [], total: Int64 = 0
        func visit(_ directory: URL, _ relative: String) throws {
            let fd = try openDirectoryNoLinks(directory); defer { close(fd) }; try requirePrivateDirectory(fd)
            let before = try statIdentity(fd)
            guard relative.split(separator: "/").count <= 32 else { throw issue() }
            for name in try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() {
                guard files.count + directories.count < maxFiles else { throw issue("迁移资料超过安全预算；没有截断或删除历史。") }
                guard name != ".", name != "..", !name.contains("/") else { throw issue() }
                let path = relative.isEmpty ? name : relative + "/" + name
                var s = stat(); guard fstatat(fd, name, &s, AT_SYMLINK_NOFOLLOW) == 0 else { throw issue() }
                if (s.st_mode & S_IFMT) == S_IFDIR { directories.append(path); try visit(directory.appendingPathComponent(name, isDirectory: true), path) }
                else {
                    guard (s.st_mode & S_IFMT) == S_IFREG else { throw issue() }
                    let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                    guard file >= 0 else { throw issue() }; defer { close(file) }
                    let current = try statIdentity(file)
                    guard regularOwned(current), current.st_mode & 0o077 == 0, current.st_dev == s.st_dev,
                          current.st_ino == s.st_ino, current.st_size <= 2 * 1024 * 1024 * 1024 else { throw issue() }
                    let (digest, size) = try hashDescriptor(file)
                    total += size; guard total <= maxTotalBytes, files.count < maxFiles else { throw issue("迁移资料超过安全预算；没有截断或删除历史。") }
                    files[path] = FileRecord(byteCount: size, sha256: digest)
                }
            }
            let after = try statIdentity(fd)
            guard before.st_dev == after.st_dev, before.st_ino == after.st_ino,
                  before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw issue() }
        }
        try visit(root, "")
        let reopened = try openDirectoryNoLinks(root); defer { close(reopened) }
        let final = try statIdentity(reopened)
        guard original.st_dev == final.st_dev, original.st_ino == final.st_ino else { throw issue() }
        return Tree(files: files, directories: directories.sorted())
    }
    static func copy(_ source: URL, to target: URL, expected: Tree, excluding: Set<String> = []) throws {
        for path in expected.directories.sorted(by: { $0.split(separator: "/").count < $1.split(separator: "/").count }) {
            try makeDirectory(target.appendingPathComponent(path, isDirectory: true))
        }
        for (path, record) in expected.files where !excluding.contains(path) {
            let src = source.appendingPathComponent(path), dst = target.appendingPathComponent(path)
            let sourceParent = try openDirectoryNoLinks(src.deletingLastPathComponent()); defer { close(sourceParent) }
            let targetParent = try openDirectoryNoLinks(dst.deletingLastPathComponent()); defer { close(targetParent) }
            let input = openat(sourceParent, src.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard input >= 0 else { throw issue() }; defer { close(input) }
            let before = try statIdentity(input); guard regularOwned(before), before.st_mode & 0o077 == 0 else { throw issue() }
            let output = openat(targetParent, dst.lastPathComponent, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard output >= 0 else { throw issue() }; defer { close(output) }
            var sha = SHA256(), count: Int64 = 0, buffer = [UInt8](repeating: 0, count: 256 * 1024)
            while true {
                let n = Darwin.read(input, &buffer, buffer.count); guard n >= 0 else { throw issue() }; if n == 0 { break }
                let bytes = Data(buffer.prefix(n)); try writeAll(bytes, to: output); sha.update(data: bytes); count += Int64(n)
                guard count <= record.byteCount else { throw issue() }
            }
            guard fsync(output) == 0, fsync(targetParent) == 0,
                  count == record.byteCount, sha.finalize().map({ String(format: "%02x", $0) }).joined() == record.sha256 else { throw issue() }
            let after = try statIdentity(input)
            guard before.st_dev == after.st_dev, before.st_ino == after.st_ino, before.st_size == after.st_size,
                  before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw issue() }
        }
        let retained = Tree(files: expected.files.filter { !excluding.contains($0.key) }, directories: expected.directories)
        guard try tree(target) == retained else { throw issue() }
    }
}
