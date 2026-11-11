import Foundation
import CryptoKit
import Darwin

protocol MailStorageDefaults: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
    func synchronize() -> Bool
}
extension UserDefaults: MailStorageDefaults {}

/// Private native mail storage. No body, attachment or credential enters WebKit.
final class MailStorage {
    private struct Initialization: Codable { let schemaVersion: Int; let identity: UUID }
    let root: URL
    let libraryURL: URL
    var readFailure: String?
    var cacheWarning: String?
    private let defaults: MailStorageDefaults?
    private let blocked: Bool
    private var rootFD: Int32 = -1
    private var lockFD: Int32 = -1
    private var initialization: Data?
    private var libraryDigest: String?
    private var cacheDigest: String?
    private var submissionDigest: String?
    private var submissionsAnchored = false
    private struct SubmissionEvidence: Codable { var schemaVersion = 1; var current: String?; var pending: String? }
    static var encoder: JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted,.sortedKeys]; e.dateEncodingStrategy = .iso8601; return e }
    static var decoder: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
    static func markerURL(root: URL) -> URL { root.deletingLastPathComponent().appendingPathComponent("." + root.lastPathComponent + ".initialized-v1.json") }
    static func evidenceKey(root: URL) -> String { "GaoMenHu.MailStorageEvidence." + digest(Data(root.path.utf8)) }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func emptyLibrary() -> MailLibrary { var value = MailLibrary(); value.identities = []; return value }
    init(root: URL? = nil, blockedBecause: String? = nil, evidenceDefaults: MailStorageDefaults? = UserDefaults.standard) {
        self.root = root ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MenDao/MailCenter", isDirectory: true)
        libraryURL = self.root.appendingPathComponent("Library.json")
        defaults = evidenceDefaults; blocked = blockedBecause != nil; readFailure = blockedBecause
    }
    deinit { if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD) }; if rootFD >= 0 { close(rootFD) } }
    static func validateMessages(_ data: Data) throws -> [CachedMessage] {
        guard data.count <= 512 * 1024 * 1024 else { throw MailAppError.message("邮件缓存超过本次安全读取预算；原文件保持不变。") }
        let messages = try decoder.decode([CachedMessage].self, from: data)
        guard messages.count <= 100_000, Set(messages.map(\.id)).count == messages.count else { throw MailAppError.message("邮件缓存标识或数量无效。") }
        return messages
    }
    private func fail(_ message: String) -> MailAppError { readFailure = message; return .message(message) }
    private func openStorage() throws {
        guard !blocked, readFailure == nil else { throw MailAppError.message(readFailure ?? "邮件资料等待迁移复核。") }
        if rootFD >= 0 { return }
        let marker = Self.markerURL(root: root), key = Self.evidenceKey(root: root)
        let rootExists = try mailPathExists(root), markerExists = try mailPathExists(marker)
        let external = defaults?.object(forKey: key)
        if !rootExists && !markerExists && external == nil {
            let identity = try Self.encoder.encode(Initialization(schemaVersion: 1, identity: UUID()))
            // Independent evidence is durable before the first filesystem write.
            if let defaults {
                defaults.set(identity, forKey: key)
                guard defaults.synchronize(), (defaults.object(forKey: key) as? Data) == identity else { throw fail("无法保存邮件初始化证据，未创建默认资料。") }
            }
            let parent = try mailOpenDirectory(root.deletingLastPathComponent()); defer { close(parent) }
            guard mkdirat(parent, root.lastPathComponent, 0o700) == 0, fsync(parent) == 0 else { throw fail("无法创建私有邮件目录，保留初始化证据等待恢复。") }
            rootFD = try mailOpenDirectory(root)
            try acquireLock(create: true)
            try writeExclusive(Self.encoder.encode(MailLibrary()), name: "Library.json")
            try writeExclusive(Self.encoder.encode([CachedMessage]()), name: "MailCache.json")
            try mailWriteNew(identity, url: marker)
        } else {
            guard rootExists && markerExists else { throw fail("邮件主目录或独立初始化记录缺失；已停止写入，不以空白资料覆盖。") }
            // Invalid imported evidence or missing files must not even create
            // a new lock in a damaged tree. Re-read after obtaining ownership.
            let markerBytes = try mailRead(marker, maximum: 4096)
            let declared = try Self.decoder.decode(Initialization.self, from: markerBytes)
            guard declared.schemaVersion == 1, defaults == nil || (external as? Data) == markerBytes else { throw fail("邮件独立初始化证据不匹配，已停止读写。") }
            let existingLibrary = try Self.decoder.decode(MailLibrary.self, from: mailRead(libraryURL, maximum: 64 * 1024 * 1024))
            try MailValidation.validate(existingLibrary)
            _ = try Self.validateMessages(mailRead(root.appendingPathComponent("MailCache.json"), maximum: 512 * 1024 * 1024))
            rootFD = try mailOpenDirectory(root)
            try acquireLock(create: true)
        }
        let bytes = try mailRead(Self.markerURL(root: root), maximum: 4096)
        let value = try Self.decoder.decode(Initialization.self, from: bytes)
        guard value.schemaVersion == 1, defaults == nil || (defaults?.object(forKey: key) as? Data) == bytes else { throw fail("邮件独立初始化证据不匹配，已停止读写。") }
        initialization = bytes
    }
    private func acquireLock(create: Bool) throws {
        let info = try mailStat(rootFD)
        guard info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw fail("邮件私有目录所有者或权限不安全。") }
        lockFD = openat(rootFD, ".MailStore.lock", O_RDWR | O_NOFOLLOW | O_CLOEXEC | (create ? O_CREAT : 0), 0o600)
        guard lockFD >= 0, mailRegular(try mailStat(lockFD)), flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw fail("另一实例正在使用邮件资料，或原锁文件无效。") }
    }
    func load() -> MailLibrary {
        do {
            try openStorage()
            if libraryDigest != nil { try verifyAvailability() }
            let data = try mailRead(libraryURL, maximum: 64 * 1024 * 1024)
            let cache = try mailRead(root.appendingPathComponent("MailCache.json"), maximum: 512 * 1024 * 1024)
            let library = try Self.decoder.decode(MailLibrary.self, from: data); try MailValidation.validate(library)
            _ = try Self.validateMessages(cache)
            libraryDigest = Self.digest(data); cacheDigest = Self.digest(cache)
            return library
        } catch {
            if readFailure == nil { readFailure = "邮件资料或缓存读取失败；已停止写入并保留原文件、附件、草稿和凭据。" }
            return Self.emptyLibrary()
        }
    }
    func verifyAvailability() throws {
        guard !blocked, readFailure == nil, rootFD >= 0, lockFD >= 0,
              let initialization, let libraryDigest, let cacheDigest else { throw MailAppError.message(readFailure ?? "邮件资料尚未通过完整读取。") }
        do {
            let current = try mailOpenDirectory(root); defer { close(current) }
            let first = try mailStat(rootFD), second = try mailStat(current), lock = try mailStat(lockFD)
            var atPath = stat()
            guard first.st_dev == second.st_dev, first.st_ino == second.st_ino, second.st_uid == getuid(), second.st_mode & 0o077 == 0,
                  fstatat(current, ".MailStore.lock", &atPath, AT_SYMLINK_NOFOLLOW) == 0, mailRegular(atPath),
                  atPath.st_dev == lock.st_dev, atPath.st_ino == lock.st_ino,
                  try mailRead(Self.markerURL(root: root), maximum: 4096) == initialization,
                  defaults == nil || (defaults?.object(forKey: Self.evidenceKey(root: root)) as? Data) == initialization,
                  Self.digest(try mailRead(libraryURL, maximum: 64 * 1024 * 1024)) == libraryDigest,
                  Self.digest(try mailRead(root.appendingPathComponent("MailCache.json"), maximum: 512 * 1024 * 1024)) == cacheDigest else {
                throw MailAppError.message("邮件原资料、缓存、初始化记录或单实例锁已变化。")
            }
        } catch { throw fail("邮件资料在运行期间缺失、损坏或被替换，已停止写入并保留所有恢复证据。") }
    }
    func loadMessages() -> [CachedMessage] {
        do { try verifyAvailability(); return try Self.validateMessages(mailRead(root.appendingPathComponent("MailCache.json"), maximum: 512 * 1024 * 1024)) }
        catch { cacheWarning = "邮件缓存不可读，已停止缓存写入；原字节及本地发送记录保留。"; return [] }
    }
    private func writeExclusive(_ data: Data, name: String) throws {
        let fd = openat(rootFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw MailAppError.message("无法排他创建邮件事务文件。") }; defer { close(fd) }
        try mailWriteAll(data, fd: fd)
        guard fsync(fd) == 0, fsync(rootFD) == 0 else { throw MailAppError.message("无法同步邮件事务文件。") }
    }
    private func replace(_ data: Data, name: String) throws {
        let pending = "." + name + "." + UUID().uuidString + ".pending"
        try writeExclusive(data, name: pending)
        defer { unlinkat(rootFD, pending, 0) }
        try verifyAvailability()
        guard renameat(rootFD, pending, rootFD, name) == 0 else { throw MailAppError.message("邮件事务无法提交，原资料未被替换。") }
        if name == "Library.json" { libraryDigest = Self.digest(data) }
        if name == "MailCache.json" { cacheDigest = Self.digest(data) }
        // A successful rename is committed. Never roll back its Keychain item
        // because a later directory sync failed; keep recovery protection instead.
        if fsync(rootFD) != 0 { readFailure = "邮件资料已提交但目录同步失败；请保留现有凭据并检查磁盘。" }
    }
    func save(_ library: MailLibrary) throws {
        try verifyAvailability(); try MailValidation.validate(library)
        let previous = try mailRead(libraryURL, maximum: 64 * 1024 * 1024)
        try replace(previous, name: "Library.previous.json")
        try replace(Self.encoder.encode(library), name: "Library.json")
    }
    func prepareAccountAddition(_ library: MailLibrary) throws -> PreparedLibrarySave {
        try verifyAvailability(); try MailValidation.validate(library)
        try replace(mailRead(libraryURL, maximum: 64 * 1024 * 1024), name: "Library.previous.json")
        let data = try Self.encoder.encode(library), staged = root.appendingPathComponent(".Library." + UUID().uuidString + ".pending")
        try writeExclusive(data, name: staged.lastPathComponent)
        return PreparedLibrarySave(staged: staged, destination: libraryURL, beforeCommit: { try self.verifyAvailability() }, didCommit: { self.libraryDigest = Self.digest(data) })
    }
    func saveMessages(_ messages: [CachedMessage]) throws {
        try verifyAvailability(); let data = try Self.encoder.encode(messages); _ = try Self.validateMessages(data)
        try replace(data, name: "MailCache.json")
    }
    // A separate durable digest prevents a missing/modified send journal from
    // being mistaken for "never sent" after a restart. Pending digest is written
    // before rename; either known disk version can be reconciled without SMTP.
    private var submissionsURL: URL { root.appendingPathComponent("MailSubmissions.json") }
    private var submissionsEvidenceKey: String { "GaoMenHu.MailSubmissionEvidence." + Self.digest(Data(root.path.utf8)) }
    func loadSubmissions() throws -> MailSubmissionLedger {
        try verifyAvailability()
        let external = defaults?.object(forKey: submissionsEvidenceKey)
        guard try mailPathExists(submissionsURL) else {
            guard external == nil, !submissionsAnchored || submissionDigest == nil else {
                throw MailAppError.message("本机发送事务记录缺失，已停止发送；不能当作从未发送。")
            }
            submissionsAnchored = true; return MailSubmissionLedger()
        }
        let data = try mailRead(submissionsURL, maximum: MailSubmissionLedger.maximumBytes), digest = Self.digest(data)
        if let defaults {
            guard let bytes = external as? Data else { throw MailAppError.message("本机发送事务独立证据缺失，已停止发送。") }
            let evidence = try Self.decoder.decode(SubmissionEvidence.self, from: bytes)
            guard evidence.schemaVersion == 1, digest == evidence.current || digest == evidence.pending,
                  (defaults.object(forKey: submissionsEvidenceKey) as? Data) == bytes else {
                throw MailAppError.message("本机发送事务摘要不匹配，已停止发送。")
            }
        }
        guard !submissionsAnchored || submissionDigest == digest else { throw MailAppError.message("运行期间本机发送事务被替换，已停止发送。") }
        let ledger = try MailSubmissionLedger.decode(data)
        submissionDigest = digest; submissionsAnchored = true; return ledger
    }
    func hasDurableDraftMatching(_ input: MailDraft) throws -> Bool {
        try verifyAvailability()
        let disk = try Self.decoder.decode(MailLibrary.self, from: mailRead(libraryURL, maximum: 64 * 1024 * 1024))
        guard let saved = disk.drafts.first(where: { $0.id == input.id }) else { return false }
        return try MailSubmissionRecord.digest(of: saved) == MailSubmissionRecord.digest(of: input)
    }
    func saveSubmissions(_ ledger: MailSubmissionLedger) throws {
        let old = try loadSubmissions()
        let order: [MailSubmissionPhase: Int] = [.pending: 0, .accepted: 1, .completed: 2]
        let oldIDs = Set(old.records.map(\.draftID))
        for record in ledger.records where !oldIDs.contains(record.draftID) {
            guard record.phase == .pending else { throw MailAppError.message("新增发送事务必须先记录待确认意图。") }
        }
        for previous in old.records {
            guard let next = ledger.records.first(where: { $0.draftID == previous.draftID }),
                  next.accountID == previous.accountID, next.draftDigest == previous.draftDigest,
                  next.receiptDigest == previous.receiptDigest,
                  (order[next.phase] ?? -1) >= (order[previous.phase] ?? 0) else {
                throw MailAppError.message("不能删除、改写或倒退原发送事务。")
            }
        }
        let bytes = try Self.encoder.encode(ledger); _ = try MailSubmissionLedger.decode(bytes)
        let next = Self.digest(bytes)
        if let defaults {
            let evidence = try Self.encoder.encode(SubmissionEvidence(current: submissionDigest, pending: next))
            defaults.set(evidence, forKey: submissionsEvidenceKey)
            guard defaults.synchronize(), (defaults.object(forKey: submissionsEvidenceKey) as? Data) == evidence else {
                throw MailAppError.message("无法持久化发送事务证据，未继续发送。")
            }
        }
        // replace uses this store's held descriptor/lock, no-follow private
        // files, fsync and the original library/cache live-hash guard.
        try replace(bytes, name: submissionsURL.lastPathComponent)
        submissionDigest = next; submissionsAnchored = true
        try verifyAvailability()
        if let defaults {
            let evidence = try Self.encoder.encode(SubmissionEvidence(current: next, pending: nil))
            defaults.set(evidence, forKey: submissionsEvidenceKey)
            guard defaults.synchronize(), (defaults.object(forKey: submissionsEvidenceKey) as? Data) == evidence else {
                throw MailAppError.message("发送事务已落盘但独立证据同步未完成，请保留草稿核对；不能重复发送。")
            }
        }
    }
    func restore(_ library: MailLibrary) throws {
        // Called only after native confirmation. Original bytes remain in place
        // until the validated replacement commits atomically; no copy is created.
        guard !blocked else { throw MailAppError.message(readFailure ?? "邮件资料等待迁移复核。") }
        try MailValidation.validate(library)
        let restoringProtectedData = readFailure != nil
        if restoringProtectedData {
            let markerBytes = try mailRead(Self.markerURL(root: root), maximum: 4096)
            let declared = try Self.decoder.decode(Initialization.self, from: markerBytes)
            guard declared.schemaVersion == 1, defaults == nil || (defaults?.object(forKey: Self.evidenceKey(root: root)) as? Data) == markerBytes else {
                throw MailAppError.message("原邮件初始化证据不完整，不能从普通资料备份覆盖。")
            }
            if rootFD < 0 { rootFD = try mailOpenDirectory(root) }
            if lockFD < 0 { try acquireLock(create: true) }
            initialization = markerBytes
        } else { try verifyAvailability() }
        let originalLibrary = try mailRead(libraryURL, maximum: 64 * 1024 * 1024)
        let originalCache = try mailRead(root.appendingPathComponent("MailCache.json"), maximum: 512 * 1024 * 1024)
        // Rebind against the exact current bytes before the atomic replacement.
        libraryDigest = Self.digest(originalLibrary); cacheDigest = Self.digest(originalCache)
        readFailure = nil
        do { try verifyAvailability(); try replace(Self.encoder.encode(library), name: "Library.json") }
        catch { readFailure = "显式恢复未完成，已保留恢复前资料及缓存，停止继续写入。"; throw error }
    }
    func beginOAuthAddition(accountID: UUID) throws -> OAuthAdditionJournal {
        try verifyAvailability()
        let journal = OAuthAdditionJournal(accountID: accountID, transactionID: UUID())
        try writeExclusive(Self.encoder.encode(journal), name: journalURL(journal.transactionID).lastPathComponent)
        return journal
    }
    func lockOAuthAdditions() throws -> OAuthAdditionLock { try verifyAvailability(); return try OAuthAdditionLock(url: root.appendingPathComponent(".OAuthAddition.lock")) }
    func hasPendingOAuthAdditions() throws -> Bool { try verifyAvailability(); return try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".OAuthAddition.") && $0.hasSuffix(".json") } }
    func oauthRecoveryAccountIDs() throws -> Set<UUID> { try verifyAvailability(); return Set(try Self.decoder.decode(MailLibrary.self, from: mailRead(libraryURL, maximum: 64 * 1024 * 1024)).accounts.map(\.id)) }
    func pendingOAuthAdditions() throws -> [OAuthAdditionJournal] {
        try verifyAvailability()
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".OAuthAddition.") && $0.pathExtension == "json" }.map { url in
                let journal = try Self.decoder.decode(OAuthAdditionJournal.self, from: mailRead(url, maximum: 4096))
                guard url.lastPathComponent == journalURL(journal.transactionID).lastPathComponent else { throw MailAppError.message("授权恢复记录标识不匹配。") }
                return journal
            }
    }
    func finishOAuthAddition(_ journal: OAuthAdditionJournal) throws { try verifyAvailability(); let bytes = try mailRead(journalURL(journal.transactionID), maximum: 4096); let stored = try Self.decoder.decode(OAuthAdditionJournal.self, from: bytes); guard stored.accountID == journal.accountID, stored.transactionID == journal.transactionID else { throw MailAppError.message("授权恢复记录已变化。") }; guard unlinkat(rootFD, journalURL(journal.transactionID).lastPathComponent, 0) == 0 else { throw MailAppError.message("无法结束授权事务记录。") } }
    private func journalURL(_ id: UUID) -> URL { root.appendingPathComponent(".OAuthAddition." + id.uuidString + ".json") }
}

final class PreparedLibrarySave {
    private let staged: URL
    private let destination: URL
    private let beforeCommit: () throws -> Void
    private let didCommit: () -> Void
    init(staged: URL, destination: URL, beforeCommit: @escaping () throws -> Void = {}, didCommit: @escaping () -> Void) { self.staged = staged; self.destination = destination; self.beforeCommit = beforeCommit; self.didCommit = didCommit }
    deinit { try? FileManager.default.removeItem(at: staged) }
    func commit() throws {
        try beforeCommit()
        let directory = try mailOpenDirectory(destination.deletingLastPathComponent()); defer { close(directory) }
        guard renameat(directory, staged.lastPathComponent, directory, destination.lastPathComponent) == 0 else { throw MailAppError.message("无法保存新邮箱，原资料未被替换。") }
        didCommit(); _ = fsync(directory)
    }
}
struct OAuthAdditionJournal: Codable { var accountID: UUID; var transactionID: UUID }
final class OAuthAdditionLock {
    private var descriptor: Int32
    init(url: URL) throws {
        let parent = try mailOpenDirectory(url.deletingLastPathComponent()); defer { close(parent) }
        descriptor = openat(parent, url.lastPathComponent, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw MailAppError.message("无法锁定邮箱授权保存目录。") }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0, mailRegular(attributes), flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { close(descriptor); descriptor = -1; throw MailAppError.message("另一程序正在保存或恢复邮箱授权。") }
    }
    func release() { guard descriptor >= 0 else { return }; flock(descriptor, LOCK_UN); close(descriptor); descriptor = -1 }
    deinit { release() }
}
private func mailRegular(_ value: stat) -> Bool { value.st_mode & S_IFMT == S_IFREG && value.st_uid == getuid() && value.st_nlink == 1 && value.st_mode & 0o077 == 0 }
private func mailStat(_ fd: Int32) throws -> stat { var result = stat(); guard fstat(fd, &result) == 0 else { throw MailAppError.message("无法读取邮件文件身份。") }; return result }
private func mailPathExists(_ url: URL) throws -> Bool { var value = stat(); if lstat(url.path, &value) == 0 { return true }; guard errno == ENOENT else { throw MailAppError.message("无法检查原邮件资料。") }; return false }
private func mailOpenDirectory(_ url: URL) throws -> Int32 {
    guard url.isFileURL, url.path.hasPrefix("/") else { throw MailAppError.message("邮件目录必须为本机绝对路径。") }
    var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard fd >= 0 else { throw MailAppError.message("无法安全打开邮件根目录。") }
    do { for part in url.pathComponents.dropFirst() { guard ![".","..",""].contains(part) else { throw MailAppError.message("邮件目录路径无效。") }; let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC); guard next >= 0 else { throw MailAppError.message("邮件目录缺失或包含链接。") }; close(fd); fd = next }; return fd }
    catch { close(fd); throw error }
}
private func mailRead(_ url: URL, maximum: Int) throws -> Data {
    let parent = try mailOpenDirectory(url.deletingLastPathComponent()); defer { close(parent) }
    let fd = openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw MailAppError.message("必要邮件文件缺失或不可读。") }; defer { close(fd) }
    let before = try mailStat(fd); guard mailRegular(before), before.st_mode & 0o400 != 0, before.st_size >= 0, before.st_size <= maximum else { throw MailAppError.message("邮件文件类型、权限或大小无效。") }
    var result = Data(), buffer = [UInt8](repeating: 0, count: 65536)
    while true { let n = read(fd, &buffer, buffer.count); guard n >= 0 else { throw MailAppError.message("读取邮件文件失败。") }; if n == 0 { break }; guard result.count + n <= maximum else { throw MailAppError.message("邮件文件超过预算。") }; result.append(contentsOf: buffer.prefix(n)) }
    let after = try mailStat(fd); guard before.st_dev == after.st_dev, before.st_ino == after.st_ino, before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec, Int64(result.count) == before.st_size else { throw MailAppError.message("读取期间邮件文件已变化。") }; return result
}
private func mailWriteAll(_ data: Data, fd: Int32) throws { try data.withUnsafeBytes { bytes in var offset = 0; while offset < bytes.count { let n = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count-offset); if n < 0 && errno == EINTR { continue }; guard n > 0 else { throw MailAppError.message("邮件文件写入失败。") }; offset += n } } }
private func mailWriteNew(_ data: Data, url: URL) throws { let parent = try mailOpenDirectory(url.deletingLastPathComponent()); defer { close(parent) }; let fd = openat(parent, url.lastPathComponent, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600); guard fd >= 0 else { throw MailAppError.message("无法创建邮件独立初始化记录。") }; defer { close(fd) }; try mailWriteAll(data, fd: fd); guard fsync(fd) == 0, fsync(parent) == 0 else { throw MailAppError.message("邮件初始化记录无法同步。") } }
