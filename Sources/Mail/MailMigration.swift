import Foundation
import CryptoKit
import CoreFoundation
import Darwin

enum PortalMailMigrationReadiness: Equatable {
    case newInstallation, ready, requiresMigration, recoveryRequired(String)
}
struct PortalMailMigrationAuthority: Codable, Equatable {
    let schemaVersion: Int
    let sourceBundleID: String
    let targetBundleID: String
    let sourceFrozen: Bool
    let sourceRoot: String
    let targetRoot: String
    let sourceManifestSHA256: String
    let sourceLibrarySHA256: String
    let sourcePreferencesSHA256: String
    let backupReceiptSHA256: String
}
struct PortalMailMigrationPreflight: Codable, Equatable {
    let schemaVersion: Int
    let sourceRoot: String
    let sourceManifestSHA256: String
    let sourceLibrarySHA256: String
    let sourcePreferencesSHA256: String
    let accountCount: Int
    let draftCount: Int
    let messageCount: Int
    let embeddedAttachmentCount: Int
    let externalDraftAttachmentCount: Int
    let pendingOAuthTransactionCount: Int
    let unrecognizedFileCount: Int
}
struct PortalMailMigrationReceipt: Codable, Equatable {
    let schemaVersion: Int
    let migrationID: UUID
    let sourceRoot: String
    let targetRoot: String
    let sourceManifestSHA256: String
    let sourceLibrarySHA256: String
    let sourcePreferencesSHA256: String
    let authoritySHA256: String
    let backupReceiptSHA256: String
    let accountIDs: [UUID]
    let draftIDs: [UUID]
    let cachedMessageIDs: [String]
    let originalEnabledAccountIDs: [UUID]
    let attachmentPathMappings: [String: String]
    let externalDraftAttachmentPathsRequireAuthorization: [String]
    let pendingOAuthTransactionIDs: [UUID]
    let unrecognizedFilesPreservedWithoutSchemaCertification: [String]
    let initializedCacheFromVerifiedAbsence: Bool
    let credentialServicePreserved: String
    let newHostConnectionAuthorizationRequired: Bool
    let originalPreferencesArchived: Bool
    let importedAt: Date
}

/// An explicit offline copy of the legacy mail tree. It never reads credentials,
/// resolves external draft attachments, opens a connection, or executes recovery.
/// Source V1.10 has no general writer lock: the authority must be issued only
/// while the coordinator actually fences the old app, after verified backup/restore.
enum PortalMailMigration {
    private struct FileRecord: Codable, Equatable { let byteCount: Int64; let sha256: String }
    private struct Tree: Codable, Equatable { let files: [String: FileRecord]; let directories: [String] }
    private struct Initialization: Codable { let schemaVersion: Int; let identity: UUID }
    private struct Transaction: Codable {
        let schemaVersion: Int
        let migrationID: UUID
        let sourceRoot: String
        let targetRoot: String
        let containerName: String
        let authoritySHA256: String
        var phase: String
        var sourceTree: Tree?
        var targetTree: Tree?
        var initialization: Data?
        var mappedPreferences: Data?
        var receiptSHA256: String?
    }
    private struct Source {
        let root: URL
        let tree: Tree
        let libraryBytes: Data
        let library: MailLibrary
        let messages: [CachedMessage]
        let knownLibraryFiles: [String]
        let unknownFiles: [String]
        let externalAttachments: [String]
        let pending: [UUID]
        let cacheExists: Bool
    }
    private static let receiptName = "MigrationEvidence/receipt.json"
    private static let maxTotalBytes: Int64 = 16 * 1024 * 1024 * 1024
    private static let maxFiles = 65_536
    // Match MailStorage's runtime Library read budget; caches have a separate limit.
    private static let maximumLibraryBytes = 64 * 1024 * 1024
    private static let maximumCacheBytes = 512 * 1024 * 1024
    private static func issue(_ text: String = "邮件迁移资料、恢复依据或授权不完整；未创建空库，请保留来源及完整备份。") -> MailAppError { .message(text) }
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value)
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func physical(_ value: URL) throws -> URL {
        guard value.isFileURL, value.host == nil || value.host == "localhost", value.path.hasPrefix("/"), value.path != "/",
              value.path.utf8.count <= 16_384,
              value.pathComponents.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw issue() }
        // Do not let Foundation shorten /private/tmp to the symlink /tmp.
        return URL(fileURLWithPath: value.path, isDirectory: true)
    }
    static func evidenceKey(destinationRootURL: URL) -> String { "GaoMenHu.MailMigration." + digest(Data(destinationRootURL.path.utf8)) }
    static func storageEvidenceKey(root: URL) -> String { MailStorage.evidenceKey(root: root) }
    static func initializationURL(root: URL) -> URL { MailStorage.markerURL(root: root) }
    private static func exists(_ url: URL) throws -> Bool {
        var info = stat(); if lstat(url.path, &info) == 0 { return true }; guard errno == ENOENT else { throw issue() }; return false
    }
    private static func preferences(_ bytes: Data) throws -> [String: Any] {
        guard bytes.count <= 32 * 1024 * 1024,
              let value = try PropertyListSerialization.propertyList(from: bytes, options: [], format: nil) as? [String: Any] else { throw issue("原邮件偏好无法读取，不能当作未使用过的空白资料。") }
        return value
    }
    private static func transaction(_ defaults: MailStorageDefaults, key: String) throws -> Transaction? {
        guard let value = defaults.object(forKey: key) else { return nil }
        guard let bytes = value as? Data, bytes.count <= 32 * 1024 * 1024,
              let record = try? JSONDecoder().decode(Transaction.self, from: bytes), record.schemaVersion == 1,
              ["preparing", "validated", "committed"].contains(record.phase),
              record.containerName == ".MailCenter-Migration-\(record.migrationID.uuidString).noindex" else { throw issue() }
        return record
    }
    private static func save(_ record: Transaction, defaults: MailStorageDefaults, key: String) throws {
        let bytes = try encode(record); defaults.set(bytes, forKey: key)
        guard defaults.synchronize(), (defaults.object(forKey: key) as? Data) == bytes else { throw issue() }
    }
    static func readiness(destinationRootURL: URL, legacyRootURL: URL, sourcePreferences: Data,
                          targetDefaults: MailStorageDefaults = UserDefaults.standard) -> PortalMailMigrationReadiness {
        do {
            let target = try physical(destinationRootURL), source = try physical(legacyRootURL)
            let targetExists = try exists(target), markerExists = try exists(initializationURL(root: target))
            if let transaction = try transaction(targetDefaults, key: evidenceKey(destinationRootURL: target)) {
                guard transaction.sourceRoot == source.path, transaction.targetRoot == target.path else { throw issue() }
                guard transaction.phase == "committed" else { return .recoveryRequired("邮件迁移尚未完成，请继续原事务；不会初始化空库。") }
                guard targetExists, markerExists,
                      digest(try read(target.appendingPathComponent(receiptName), limit: 16 * 1024 * 1024)) == transaction.receiptSHA256 else { throw issue() }
                try validateTarget(target, defaults: targetDefaults, expectedIdentity: transaction.migrationID)
                return .ready
            }
            if targetExists || markerExists || targetDefaults.object(forKey: storageEvidenceKey(root: target)) != nil {
                guard targetExists, markerExists, !(try exists(target.appendingPathComponent(receiptName))),
                      !(try exists(source)), try preferences(sourcePreferences).isEmpty else { throw issue() }
                try validateTarget(target, defaults: targetDefaults); return .ready
            }
            if try exists(source) {
                guard try exists(source.appendingPathComponent("Library.json")) else { throw issue("已有邮件目录缺少主库；未用空邮箱覆盖缓存、草稿和恢复资料。") }
                return .requiresMigration
            }
            guard try preferences(sourcePreferences).isEmpty else { throw issue("邮件主目录缺失，但原偏好仍存在；请先恢复完整来源。") }
            return .newInstallation
        } catch { return .recoveryRequired("邮件资料或迁移依据不可读，已停止写入；请保留原资料和备份。") }
    }
    static func preflight(legacyRootURL: URL, sourcePreferences: Data) throws -> PortalMailMigrationPreflight {
        _ = try preferences(sourcePreferences)
        let source = try readSource(physical(legacyRootURL))
        guard try tree(source.root) == source.tree,
              try read(source.root.appendingPathComponent("Library.json"), limit: maximumLibraryBytes) == source.libraryBytes else { throw issue() }
        return PortalMailMigrationPreflight(schemaVersion: 1, sourceRoot: source.root.path,
            sourceManifestSHA256: digest(try encode(source.tree)), sourceLibrarySHA256: digest(source.libraryBytes),
            sourcePreferencesSHA256: digest(sourcePreferences), accountCount: source.library.accounts.count,
            draftCount: source.library.drafts.count, messageCount: source.messages.count,
            embeddedAttachmentCount: source.messages.reduce(0) { $0 + $1.attachments.count },
            externalDraftAttachmentCount: source.externalAttachments.count, pendingOAuthTransactionCount: source.pending.count,
            unrecognizedFileCount: source.unknownFiles.count)
    }
    static func prepare(destinationRootURL: URL, legacyRootURL: URL, sourcePreferences: Data,
                        authority: PortalMailMigrationAuthority, targetDefaults: MailStorageDefaults = UserDefaults.standard,
                        fault: ((String) throws -> Void)? = nil) throws -> PortalMailMigrationReceipt {
        let target = try physical(destinationRootURL), root = try physical(legacyRootURL)
        _ = try preferences(sourcePreferences)
        try validateAuthority(authority, source: root, target: target)
        guard !target.path.hasPrefix(root.path + "/"), !root.path.hasPrefix(target.path + "/"), target.path != root.path else { throw issue() }
        let authoritySHA = digest(try encode(authority)), parent = target.deletingLastPathComponent()
        let parentFD = try openDirectory(parent); defer { close(parentFD) }; try requirePrivateDirectory(parentFD)
        let lock = openat(parentFD, ".MailCenter.migration.lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw issue() }; defer { close(lock) }
        guard regular(try metadata(lock)), flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw issue("另一个邮件迁移正在进行，未改写任何资料。") }
        let key = evidenceKey(destinationRootURL: target)
        var pending = try transaction(targetDefaults, key: key)
        if let committed = pending, committed.phase == "committed" {
            guard committed.sourceRoot == root.path, committed.targetRoot == target.path, committed.authoritySHA256 == authoritySHA else { throw issue() }
            let bytes = try read(target.appendingPathComponent(receiptName), limit: 16 * 1024 * 1024)
            guard digest(bytes) == committed.receiptSHA256 else { throw issue() }
            try validateTarget(target, defaults: targetDefaults, expectedIdentity: committed.migrationID)
            return try JSONDecoder().decode(PortalMailMigrationReceipt.self, from: bytes)
        }
        let source = try readSource(root)
        guard authority.sourceManifestSHA256 == digest(try encode(source.tree)),
              authority.sourceLibrarySHA256 == digest(source.libraryBytes),
              authority.sourcePreferencesSHA256 == digest(sourcePreferences) else { throw issue("来源已改变或迁移授权过期，未开始迁移事务。") }
        if let value = pending {
            guard value.phase == "validated", value.sourceRoot == root.path, value.targetRoot == target.path,
                  value.authoritySHA256 == authoritySHA, value.sourceTree == source.tree else { throw issue() }
        } else {
            guard !(try exists(target)), !(try exists(initializationURL(root: target))),
                  targetDefaults.object(forKey: storageEvidenceKey(root: target)) == nil else { throw issue() }
            let id = UUID()
            pending = Transaction(schemaVersion: 1, migrationID: id, sourceRoot: root.path, targetRoot: target.path,
                containerName: ".MailCenter-Migration-\(id.uuidString).noindex", authoritySHA256: authoritySHA, phase: "preparing")
            try save(pending!, defaults: targetDefaults, key: key); try fault?("mail.preparing")
        }
        var value = pending!
        let container = parent.appendingPathComponent(value.containerName, isDirectory: true)
        let staged = container.appendingPathComponent(target.lastPathComponent, isDirectory: true)
        if value.phase == "preparing" {
            guard !(try exists(container)), !(try exists(target)) else { throw issue() }
            try makeDirectory(container); try makeDirectory(staged)
            let automaticBackups = Set(source.tree.files.keys.filter { isAutomaticBackup($0) })
            try copy(root, to: staged, expected: source.tree, excluding: automaticBackups)
            guard source.tree.files[".MailStore.lock"] == nil else { throw issue("来源含有接收端保留的锁文件，未复用未知写入依据。") }
            try write(Data(), at: staged.appendingPathComponent(".MailStore.lock"), replacing: false)
            try fault?("mail.copied")
            let evidence = staged.appendingPathComponent("MigrationEvidence", isDirectory: true)
            try makeDirectory(evidence); try makeDirectory(evidence.appendingPathComponent("OriginalLibraries", isDirectory: true))
            try write(sourcePreferences, at: evidence.appendingPathComponent("source-preferences.plist"), replacing: false)
            try write(try encode(source.tree), at: evidence.appendingPathComponent("source-files.json"), replacing: false)
            var mappings: [String: String] = [:]
            for relative in source.knownLibraryFiles where !isAutomaticBackup(relative) {
                let original = try read(root.appendingPathComponent(relative), limit: maximumLibraryBytes)
                let (mapped, changed) = try mapOwnedAttachments(original, source: source, target: target)
                if !changed.isEmpty {
                    // Current and pending library files retain their original bytes
                    // for transaction review; automatic backups are never copied.
                    try write(original, at: evidence.appendingPathComponent("OriginalLibraries").appendingPathComponent(relative), replacing: false)
                    try write(mapped, at: staged.appendingPathComponent(relative), replacing: true)
                    for (from, to) in changed { mappings[from] = to }
                }
            }
            if !source.cacheExists { try write(Data("[]".utf8), at: staged.appendingPathComponent("MailCache.json"), replacing: false) }
            let marker = try encode(Initialization(schemaVersion: 1, identity: value.migrationID))
            let receipt = PortalMailMigrationReceipt(schemaVersion: 1, migrationID: value.migrationID, sourceRoot: root.path, targetRoot: target.path,
                sourceManifestSHA256: authority.sourceManifestSHA256, sourceLibrarySHA256: authority.sourceLibrarySHA256,
                sourcePreferencesSHA256: authority.sourcePreferencesSHA256, authoritySHA256: authoritySHA, backupReceiptSHA256: authority.backupReceiptSHA256,
                accountIDs: source.library.accounts.map(\.id), draftIDs: source.library.drafts.map(\.id), cachedMessageIDs: source.messages.map(\.id),
                originalEnabledAccountIDs: source.library.accounts.filter(\.enabled).map(\.id), attachmentPathMappings: mappings,
                externalDraftAttachmentPathsRequireAuthorization: source.externalAttachments, pendingOAuthTransactionIDs: source.pending,
                unrecognizedFilesPreservedWithoutSchemaCertification: source.unknownFiles,
                initializedCacheFromVerifiedAbsence: !source.cacheExists, credentialServicePreserved: "com.gaoseries.GaoYouJian.credentials",
                newHostConnectionAuthorizationRequired: true, originalPreferencesArchived: true, importedAt: Date())
            let receiptBytes = try encode(receipt)
            try write(receiptBytes, at: staged.appendingPathComponent(receiptName), replacing: false)
            try validateMainAndCache(staged)
            guard try tree(root) == source.tree else { throw issue() }
            value.sourceTree = source.tree; value.targetTree = try tree(staged); value.initialization = marker
            value.receiptSHA256 = digest(receiptBytes); value.mappedPreferences = try mappedPreferences(sourcePreferences)
            value.phase = "validated"; try save(value, defaults: targetDefaults, key: key); try fault?("mail.validated")
        }
        guard let expected = value.targetTree, let marker = value.initialization, let mapped = value.mappedPreferences else { throw issue() }
        if try exists(target) { guard try tree(target) == expected, !(try exists(staged)) else { throw issue() } }
        else {
            guard try tree(staged) == expected else { throw issue() }
            let fd = try openDirectory(container); defer { close(fd) }
            guard renameatx_np(fd, target.lastPathComponent, parentFD, target.lastPathComponent, UInt32(RENAME_EXCL)) == 0,
                  fsync(fd) == 0, fsync(parentFD) == 0 else { throw issue() }
        }
        try fault?("mail.rootPublished")
        let markerURL = initializationURL(root: target)
        if try exists(markerURL) { guard try read(markerURL, limit: 4096) == marker else { throw issue() } }
        else { try write(marker, at: markerURL, replacing: false) }
        try fault?("mail.markerPublished")
        let storageKey = storageEvidenceKey(root: target)
        if let old = targetDefaults.object(forKey: storageKey) { guard (old as? Data) == marker else { throw issue() } }
        else { targetDefaults.set(marker, forKey: storageKey) }
        let settings = try preferences(mapped)
        for (setting, new) in settings {
            if let old = targetDefaults.object(forKey: setting) {
                guard NSDictionary(dictionary: [setting: old]).isEqual(to: [setting: new]) else { throw issue("门户已设置的邮件偏好与迁移计划冲突，未自动覆盖。") }
            } else { targetDefaults.set(new, forKey: setting) }
        }
        guard targetDefaults.synchronize(), (targetDefaults.object(forKey: storageKey) as? Data) == marker else { throw issue() }
        try fault?("mail.evidencePublished")
        try validateTarget(target, defaults: targetDefaults, expectedIdentity: value.migrationID)
        guard try tree(target) == expected, try tree(root) == source.tree else { throw issue() }
        value.phase = "committed"; try save(value, defaults: targetDefaults, key: key); try fault?("mail.committed")
        if try exists(container) { guard rmdir(container.path) == 0 else { throw issue("邮件迁移已提交，保留额外事务目录内容等待核对。") } }
        return try JSONDecoder().decode(PortalMailMigrationReceipt.self, from: read(target.appendingPathComponent(receiptName), limit: 16 * 1024 * 1024))
    }

    private static func validateAuthority(_ value: PortalMailMigrationAuthority, source: URL, target: URL) throws {
        func hash(_ text: String) -> Bool { text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
        guard value.schemaVersion == 1, value.sourceBundleID == "com.gaoseries.GaoYouJian", value.targetBundleID == "cn.mendao.launcher",
              value.sourceFrozen, value.sourceRoot == source.path, value.targetRoot == target.path,
              [value.sourceManifestSHA256, value.sourceLibrarySHA256, value.sourcePreferencesSHA256, value.backupReceiptSHA256].allSatisfy(hash) else { throw issue() }
    }
    private static func validateTarget(_ target: URL, defaults: MailStorageDefaults, expectedIdentity: UUID? = nil) throws {
        let marker = try read(initializationURL(root: target), limit: 4096)
        let value = try JSONDecoder().decode(Initialization.self, from: marker)
        guard value.schemaVersion == 1, expectedIdentity == nil || expectedIdentity == value.identity,
              (defaults.object(forKey: storageEvidenceKey(root: target)) as? Data) == marker else { throw issue() }
        try validateMainAndCache(target)
    }
    private static func validateMainAndCache(_ root: URL) throws {
        let library = try decodeLibrary(read(root.appendingPathComponent("Library.json"), limit: maximumLibraryBytes))
        _ = try decodeMessages(read(root.appendingPathComponent("MailCache.json"), limit: maximumCacheBytes), accounts: Set(library.accounts.map(\.id)))
    }
    private static func readSource(_ root: URL) throws -> Source {
        guard try exists(root), try exists(root.appendingPathComponent("Library.json")) else { throw issue() }
        let before = try tree(root)
        let main = try read(root.appendingPathComponent("Library.json"), limit: maximumLibraryBytes), library = try decodeLibrary(main)
        let cacheExists = try exists(root.appendingPathComponent("MailCache.json"))
        let messages = try cacheExists ? decodeMessages(read(root.appendingPathComponent("MailCache.json"), limit: maximumCacheBytes), accounts: Set(library.accounts.map(\.id))) : []
        var known = Set(["Library.json"]), libraries = ["Library.json"], pending: [UUID] = [], external = Set<String>()
        var cacheHistoryExpected = !library.accounts.isEmpty || before.files.keys.contains { $0.hasPrefix("MailCache.") }
        if cacheExists { known.insert("MailCache.json") }
        for relative in before.files.keys.sorted() where !relative.contains("/") {
            if relative == "Library.previous.json" || (relative.hasPrefix("BeforeRestore-") && relative.hasSuffix(".json")) || (relative.hasPrefix(".Library.") && relative.hasSuffix(".pending")) {
                _ = try decodeLibrary(read(root.appendingPathComponent(relative), limit: maximumLibraryBytes)); known.insert(relative); libraries.append(relative)
            } else if relative.hasPrefix("MailCache.beforeRestore.") && relative.hasSuffix(".json") {
                _ = try decodeMessages(read(root.appendingPathComponent(relative), limit: maximumCacheBytes), accounts: nil); known.insert(relative)
            } else if relative.hasPrefix(".OAuthAddition.") && relative.hasSuffix(".json") {
                let bytes = try read(root.appendingPathComponent(relative), limit: 4096)
                guard let fields = try JSONSerialization.jsonObject(with: bytes) as? [String: Any], Set(fields.keys) == ["accountID", "transactionID"] else { throw issue() }
                let journal = try MailStorage.decoder.decode(OAuthAdditionJournal.self, from: bytes)
                guard relative == ".OAuthAddition.\(journal.transactionID.uuidString).json" else { throw issue() }
                known.insert(relative); pending.append(journal.transactionID)
            } else if relative == ".OAuthAddition.lock" { known.insert(relative) }
        }
        for relative in libraries {
            let value = try decodeLibrary(read(root.appendingPathComponent(relative), limit: maximumLibraryBytes))
            if !value.accounts.isEmpty { cacheHistoryExpected = true }
            for draft in value.drafts {
                for attachment in draft.attachments {
                    let path = attachment.path
                    guard path.hasPrefix("/"), path.utf8.count <= 16_384,
                          URL(fileURLWithPath: path).pathComponents.dropFirst().allSatisfy({ $0 != "." && $0 != ".." }) else { throw issue() }
                    if path.hasPrefix(root.path + "/") {
                        let key = String(path.dropFirst(root.path.count + 1))
                        guard before.files[key] != nil else { throw issue("草稿自有附件缺失，未把缺失附件当作空白迁移。") }; known.insert(key)
                    } else { external.insert(path) }
                }
            }
        }
        guard cacheExists || !cacheHistoryExpected else { throw issue("原邮箱账号或缓存历史仍在，但邮件缓存缺失；未新建空缓存覆盖历史。") }
        guard digest(main) == before.files["Library.json"]?.sha256, try tree(root) == before else { throw issue() }
        return Source(root: root, tree: before, libraryBytes: main, library: library, messages: messages,
            knownLibraryFiles: libraries, unknownFiles: before.files.keys.filter { !known.contains($0) }.sorted(),
            externalAttachments: external.sorted(), pending: pending.sorted { $0.uuidString < $1.uuidString }, cacheExists: cacheExists)
    }
    private static func decodeLibrary(_ bytes: Data) throws -> MailLibrary {
        guard bytes.count <= maximumLibraryBytes else { throw readBudgetIssue(maximumLibraryBytes) }
        guard let root = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              Set(root.keys).isSubset(of: ["schemaVersion", "identities", "accounts", "platforms", "drafts", "preferences"]) else { throw issue() }
        let fields: [String: Set<String>] = [
            "identities": ["id", "name", "symbol", "color"],
            "accounts": ["id", "name", "email", "provider", "identityID", "tags", "aliases", "signature", "enabled", "auth", "username", "imapHost", "imapPort", "imapTLS", "smtpHost", "smtpPort", "smtpTLS", "sentFolder", "lastSync", "syncError"],
            "platforms": ["id", "accountID", "name", "url", "username", "address", "kind", "loginMethod", "roles", "status", "notes", "checkedAt", "updatedAt", "history"],
            "drafts": ["id", "accountID", "from", "to", "cc", "bcc", "subject", "body", "attachments", "inReplyTo", "references", "updatedAt"]]
        for (key, allowed) in fields {
            guard let values = root[key] as? [[String: Any]], values.allSatisfy({ Set($0.keys).isSubset(of: allowed) }) else { throw issue() }
        }
        guard let preferences = root["preferences"] as? [String: Any], Set(preferences.keys).isSubset(of: ["syncMinutes", "fetchLimit", "notifyNewMail", "googleClientID", "microsoftClientID", "microsoftTenant"]) else { throw issue() }
        for draft in root["drafts"] as! [[String: Any]] {
            guard let values = draft["attachments"] as? [[String: Any]], values.allSatisfy({ Set($0.keys) == ["id", "path"] }) else { throw issue() }
        }
        for platform in root["platforms"] as! [[String: Any]] {
            guard let values = platform["history"] as? [[String: Any]], values.allSatisfy({ Set($0.keys).isSubset(of: ["id", "date", "text"]) }) else { throw issue() }
        }
        let library = try MailStorage.decoder.decode(MailLibrary.self, from: bytes); try MailValidation.validate(library)
        guard library.accounts.count <= 5000, library.drafts.count <= 10_000 else { throw issue() }
        return library
    }
    private static func decodeMessages(_ bytes: Data, accounts: Set<UUID>?) throws -> [CachedMessage] {
        guard let raw = try JSONSerialization.jsonObject(with: bytes) as? [[String: Any]] else { throw issue() }
        let allowed: Set<String> = ["id", "accountID", "folder", "uid", "uidValidity", "subject", "from", "replyTo", "to", "cc", "date", "preview", "body", "html", "isRead", "isFlagged", "messageID", "references", "attachments", "loaded"]
        for message in raw {
            guard Set(message.keys).isSubset(of: allowed), let attachments = message["attachments"] as? [[String: Any]],
                  attachments.allSatisfy({ Set($0.keys) == ["id", "filename", "mimeType", "data"] }) else { throw issue() }
        }
        let values = try MailStorage.validateMessages(bytes)
        guard values.count <= 100_000, Set(values.map(\.id)).count == values.count else { throw issue() }
        for message in values {
            guard !message.id.isEmpty, !message.folder.isEmpty, message.date.timeIntervalSince1970.isFinite,
                  accounts == nil || accounts!.contains(message.accountID),
                  Set(message.attachments.map(\.id)).count == message.attachments.count else { throw issue() }
        }
        return values
    }
    private static func mapOwnedAttachments(_ bytes: Data, source: Source, target: URL) throws -> (Data, [String: String]) {
        guard var root = try JSONSerialization.jsonObject(with: bytes) as? [String: Any], var drafts = root["drafts"] as? [[String: Any]] else { throw issue() }
        var mappings: [String: String] = [:]
        for index in drafts.indices {
            guard var attachments = drafts[index]["attachments"] as? [[String: Any]] else { throw issue() }
            for number in attachments.indices {
                guard let path = attachments[number]["path"] as? String else { throw issue() }
                if path.hasPrefix(source.root.path + "/") {
                    let relative = String(path.dropFirst(source.root.path.count + 1))
                    guard source.tree.files[relative] != nil else { throw issue() }
                    let replacement = target.appendingPathComponent(relative).path
                    attachments[number]["path"] = replacement; mappings[path] = replacement
                }
            }
            drafts[index]["attachments"] = attachments
        }
        guard !mappings.isEmpty else { return (bytes, [:]) }
        root["drafts"] = drafts
        let mapped = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
        _ = try decodeLibrary(mapped); return (mapped, mappings)
    }
    private static func mappedPreferences(_ bytes: Data) throws -> Data {
        let original = try preferences(bytes)
        var mapped: [String: Any] = ["gaomenhu.mail.floating.visible": false, "gaomenhu.mail.floating.showPreviews": false]
        let allowed: Set<String> = ["appearance", "sidebarHidden", "floating.opacity", "floating.display", "floating.horizontalRatio", "floating.verticalRatio", "floating.edge", "floating.dockMode"]
        for suffix in allowed {
            guard let value = original["gaoyoujian." + suffix] else { continue }
            switch suffix {
            case "appearance": guard let value = value as? String, ["system", "light", "dark"].contains(value) else { throw issue() }
            case "sidebarHidden": guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { throw issue() }
            case "floating.opacity", "floating.horizontalRatio", "floating.verticalRatio":
                guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite, (0...1).contains(value.doubleValue) else { throw issue() }
            case "floating.display": guard value is String else { throw issue() }
            case "floating.edge": guard let value = value as? String, ["left", "right"].contains(value) else { throw issue() }
            case "floating.dockMode": guard let value = value as? String, ["left", "right", "free"].contains(value) else { throw issue() }
            default: throw issue()
            }
            mapped["gaomenhu.mail." + suffix] = value
        }
        return try PropertyListSerialization.data(fromPropertyList: mapped, format: .binary, options: 0)
    }
    private static func metadata(_ fd: Int32) throws -> stat {
        var value = stat(); guard fstat(fd, &value) == 0 else { throw issue() }; return value
    }
    private static func regular(_ value: stat) -> Bool { (value.st_mode & S_IFMT) == S_IFREG && value.st_uid == getuid() && value.st_nlink == 1 }
    private static func openDirectory(_ root: URL) throws -> Int32 {
        let value = try physical(root)
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw issue() }
        do {
            for component in value.pathComponents.dropFirst() {
                let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw issue() }; close(fd); fd = next
            }
            return fd
        } catch { close(fd); throw error }
    }
    private static func writeBytes(_ bytes: Data, to fd: Int32) throws {
        try bytes.withUnsafeBytes { pointer in
            var offset = 0
            while offset < pointer.count {
                let size = Darwin.write(fd, pointer.baseAddress!.advanced(by: offset), pointer.count - offset)
                if size < 0 && errno == EINTR { continue }; guard size > 0 else { throw issue() }; offset += size
            }
        }
    }
    private static func hashFile(_ fd: Int32) throws -> (String, Int64) {
        let before = try metadata(fd); guard regular(before) else { throw issue() }
        var sha = SHA256(), offset: Int64 = 0, buffer = [UInt8](repeating: 0, count: 256 * 1024)
        while offset < before.st_size {
            let size = pread(fd, &buffer, min(buffer.count, Int(before.st_size - offset)), off_t(offset))
            guard size > 0 else { throw issue() }; sha.update(data: Data(buffer.prefix(size))); offset += Int64(size)
        }
        let after = try metadata(fd)
        guard before.st_dev == after.st_dev, before.st_ino == after.st_ino, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw issue() }
        return (sha.finalize().map { String(format: "%02x", $0) }.joined(), offset)
    }
    private static func requirePrivateDirectory(_ fd: Int32) throws {
        let s = try metadata(fd)
        guard (s.st_mode & S_IFMT) == S_IFDIR, s.st_uid == getuid(), s.st_mode & 0o077 == 0 else { throw issue() }
    }
    private static func makeDirectory(_ url: URL) throws {
        let parent = try openDirectory(url.deletingLastPathComponent()); defer { close(parent) }
        guard mkdirat(parent, url.lastPathComponent, 0o700) == 0, fsync(parent) == 0 else { throw issue() }
    }
    private static func readBudgetIssue(_ limit: Int) -> MailAppError {
        issue("邮件资料文件超出安全大小上限（\(limit) 字节），未读取或迁入。")
    }
    private static func read(_ url: URL, limit: Int) throws -> Data {
        let parent = try openDirectory(url.deletingLastPathComponent()); defer { close(parent) }
        let fd = openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw issue() }; defer { close(fd) }
        let s = try metadata(fd)
        guard regular(s), s.st_mode & 0o077 == 0, s.st_size >= 0 else { throw issue() }
        guard s.st_size <= limit else { throw readBudgetIssue(limit) }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = Darwin.read(fd, &buffer, buffer.count)
            guard n >= 0 else { throw issue() }; if n == 0 { break }
            guard result.count + n <= limit else { throw issue() }; result.append(contentsOf: buffer.prefix(n))
        }
        let after = try metadata(fd)
        guard s.st_dev == after.st_dev, s.st_ino == after.st_ino, s.st_size == after.st_size,
              s.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, s.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw issue() }
        return result
    }
    private static func write(_ data: Data, at url: URL, replacing: Bool) throws {
        let parent = try openDirectory(url.deletingLastPathComponent()); defer { close(parent) }
        let temp = ".migration-write-\(UUID().uuidString)"
        let fd = openat(parent, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw issue() }; defer { close(fd); unlinkat(parent, temp, 0) }
        try writeBytes(data, to: fd); guard fsync(fd) == 0 else { throw issue() }
        if replacing { guard renameat(parent, temp, parent, url.lastPathComponent) == 0 else { throw issue() } }
        else { guard renameatx_np(parent, temp, parent, url.lastPathComponent, UInt32(RENAME_EXCL)) == 0 else { throw issue() } }
        guard fsync(parent) == 0 else { throw issue() }
    }
    private static func tree(_ root: URL) throws -> Tree {
        let rootFD = try openDirectory(root); defer { close(rootFD) }; try requirePrivateDirectory(rootFD)
        let original = try metadata(rootFD)
        var files: [String: FileRecord] = [:], directories: [String] = [], total: Int64 = 0
        func visit(_ directory: URL, _ relative: String) throws {
            let fd = try openDirectory(directory); defer { close(fd) }; try requirePrivateDirectory(fd)
            let before = try metadata(fd)
            guard relative.split(separator: "/").count <= 32 else { throw issue() }
            for name in try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() {
                guard files.count + directories.count < maxFiles else { throw issue("迁移资料超过安全预算；没有截断或删除历史。") }
                guard name != ".", name != "..", !name.contains("/") else { throw issue() }
                let path = relative.isEmpty ? name : relative + "/" + name
                var s = stat(); guard fstatat(fd, name, &s, AT_SYMLINK_NOFOLLOW) == 0 else { throw issue() }
                if (s.st_mode & S_IFMT) == S_IFDIR { directories.append(path); try visit(directory.appendingPathComponent(name, isDirectory: true), path) }
                else {
                    let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                    guard file >= 0 else { throw issue() }; defer { close(file) }
                    let current = try metadata(file)
                    guard regular(current), current.st_mode & 0o077 == 0, current.st_dev == s.st_dev,
                          current.st_ino == s.st_ino, current.st_size <= 2 * 1024 * 1024 * 1024 else { throw issue() }
                    let (digest, size) = try hashFile(file)
                    total += size; guard total <= maxTotalBytes, files.count < maxFiles else { throw issue("迁移资料超过安全预算；没有截断或删除历史。") }
                    files[path] = FileRecord(byteCount: size, sha256: digest)
                }
            }
            let after = try metadata(fd)
            guard before.st_dev == after.st_dev, before.st_ino == after.st_ino,
                  before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw issue() }
        }
        try visit(root, "")
        let reopened = try openDirectory(root); defer { close(reopened) }
        let final = try metadata(reopened)
        guard original.st_dev == final.st_dev, original.st_ino == final.st_ino else { throw issue() }
        return Tree(files: files, directories: directories.sorted())
    }
    private static func isAutomaticBackup(_ path: String) -> Bool {
        guard !path.contains("/") else { return false }
        return path == "Library.previous.json"
            || (path.hasPrefix("BeforeRestore-") && path.hasSuffix(".json"))
            || (path.hasPrefix("MailCache.beforeRestore.") && path.hasSuffix(".json"))
    }
    private static func copy(_ source: URL, to target: URL, expected: Tree, excluding: Set<String> = []) throws {
        for path in expected.directories.sorted(by: { $0.split(separator: "/").count < $1.split(separator: "/").count }) {
            try makeDirectory(target.appendingPathComponent(path, isDirectory: true))
        }
        for (path, record) in expected.files where !excluding.contains(path) {
            let src = source.appendingPathComponent(path), dst = target.appendingPathComponent(path)
            let sourceParent = try openDirectory(src.deletingLastPathComponent()); defer { close(sourceParent) }
            let targetParent = try openDirectory(dst.deletingLastPathComponent()); defer { close(targetParent) }
            let input = openat(sourceParent, src.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard input >= 0 else { throw issue() }; defer { close(input) }
            let before = try metadata(input); guard regular(before), before.st_mode & 0o077 == 0 else { throw issue() }
            let output = openat(targetParent, dst.lastPathComponent, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard output >= 0 else { throw issue() }; defer { close(output) }
            var sha = SHA256(), count: Int64 = 0, buffer = [UInt8](repeating: 0, count: 256 * 1024)
            while true {
                let n = Darwin.read(input, &buffer, buffer.count); guard n >= 0 else { throw issue() }; if n == 0 { break }
                let bytes = Data(buffer.prefix(n)); try writeBytes(bytes, to: output); sha.update(data: bytes); count += Int64(n)
                guard count <= record.byteCount else { throw issue() }
            }
            guard fsync(output) == 0, fsync(targetParent) == 0,
                  count == record.byteCount, sha.finalize().map({ String(format: "%02x", $0) }).joined() == record.sha256 else { throw issue() }
            let after = try metadata(input)
            guard before.st_dev == after.st_dev, before.st_ino == after.st_ino, before.st_size == after.st_size,
                  before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw issue() }
        }
        let retained = Tree(files: expected.files.filter { !excluding.contains($0.key) }, directories: expected.directories)
        guard try tree(target) == retained else { throw issue() }
    }
}
