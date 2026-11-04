import Foundation
import CryptoKit
import Darwin

func importDigest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func posixFailure(_ operation: String) -> DownloadError { .message("\(operation)失败（系统错误 \(errno)）。") }
func statIdentity(_ fd: Int32) throws -> stat { var s = stat(); guard fstat(fd, &s) == 0 else { throw posixFailure("读取文件身份") }; return s }
func regularOwned(_ s: stat) -> Bool { (s.st_mode & S_IFMT) == S_IFREG && s.st_uid == getuid() && s.st_nlink == 1 }
func openDirectoryNoLinks(_ url: URL) throws -> Int32 {
    guard url.isFileURL, url.path.hasPrefix("/") else { throw DownloadError.message("目标必须是本机绝对目录。") }
    var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard descriptor >= 0 else { throw posixFailure("打开目录") }
    do {
        for component in url.pathComponents.dropFirst() {
            guard component != "..", component != ".", !component.isEmpty else { throw DownloadError.message("目录路径无效。") }
            let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw posixFailure("安全打开目标目录") }
            close(descriptor); descriptor = next
        }
        return descriptor
    } catch { close(descriptor); throw error }
}
func hashDescriptor(_ fd: Int32, expected: Int64? = nil) throws -> (String, Int64) {
    let before = try statIdentity(fd)
    guard regularOwned(before) else { throw DownloadError.message("文件不是本用户独立拥有的普通文件。") }
    if let expected, before.st_size != expected { throw DownloadError.message("实际文件长度与已记录长度不符。") }
    var digest = SHA256(); var offset: Int64 = 0; var buffer = [UInt8](repeating: 0, count: 256 * 1024)
    while offset < before.st_size {
        let count = pread(fd, &buffer, min(buffer.count, Int(before.st_size - offset)), off_t(offset))
        guard count > 0 else { throw DownloadError.message("流式读取文件失败或文件已改变。") }
        digest.update(data: Data(buffer.prefix(count))); offset += Int64(count)
    }
    let after = try statIdentity(fd)
    guard before.st_dev == after.st_dev, before.st_ino == after.st_ino, before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw DownloadError.message("校验期间文件发生改变。") }
    return (digest.finalize().map { String(format: "%02x", $0) }.joined(), offset)
}
func safeDownloadName(_ raw: String) -> String {
    let bad = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
    let cleaned = raw.unicodeScalars.map { bad.contains($0) ? "_" : String($0) }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    var limited = ""
    for character in cleaned { if limited.utf8.count + String(character).utf8.count > 200 { break }; limited.append(character) }
    return limited.isEmpty || limited == "." || limited == ".." || limited.hasPrefix(".") ? "下载文件" : limited
}
func redactedDownloadURL(_ url: URL) -> String {
    var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
    c?.user = nil; c?.password = nil; c?.query = nil; c?.fragment = nil
    return c?.string ?? "有效下载链接"
}
func strongDownloadETag(_ raw: String?) -> String? {
    guard let raw, raw.utf8.count <= 1024, raw.first == "\"", raw.last == "\"", raw.utf8.count >= 2,
          raw.utf8.dropFirst().dropLast().allSatisfy({ $0 == 0x21 || (0x23...0x7e).contains($0) || $0 >= 0x80 }) else { return nil }
    return raw
}
func validatedDownloadURL(_ raw: String) throws -> URL {
    guard raw.utf8.count <= 16_384, let u = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)), let scheme = u.scheme?.lowercased(), ["http","https"].contains(scheme), u.host != nil, u.user == nil, u.password == nil, URLComponents(url: u, resolvingAgainstBaseURL: false)?.fragment == nil else { throw DownloadError.message("请输入不含用户名、密码或片段的 HTTP/HTTPS 文件直链。") }
    return u
}

final class DownloadStore {
    private struct Envelope: Codable { var payload: Data; var sha256: String }
    private struct Marker: Codable { var schemaVersion: Int; var installationID: UUID }
    let root: URL
    private let marker: URL
    private var rootFD: Int32 = -1
    private var lockFD: Int32 = -1
    private let readOnly: Bool
    private var initializing = false
    private var snapshotDigest: String?
    private var markerDigest: String?
    private let encoder: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return e }()
    init(root: URL, readOnly: Bool = false) throws {
        self.root = root
        self.readOnly = readOnly
        marker = root.deletingLastPathComponent().appendingPathComponent(".\(root.lastPathComponent).initialized-v1.json")
        let fm = FileManager.default
        func exists(_ url: URL) throws -> Bool {
            var info = stat()
            if lstat(url.path, &info) == 0 { return true }
            guard errno == ENOENT else { throw posixFailure("检查原资料") }
            return false
        }
        let rootExists = try exists(root), markerExists = try exists(marker)
        guard rootExists == markerExists, !readOnly || rootExists else {
            throw DownloadError.message("原资料目录或独立初始化记录缺失，已停止写入；不能以空队列代替原资料。")
        }
        do {
            if !rootExists {
                // Validate every existing ancestor before creation; a symlinked
                // parent must not cause even a transient write outside this root.
                let parent = try openDirectoryNoLinks(root.deletingLastPathComponent()); defer { close(parent) }
                guard mkdirat(parent, root.lastPathComponent, 0o700) == 0, fsync(parent) == 0 else { throw posixFailure("创建私有下载目录") }
            }
            rootFD = try openDirectoryNoLinks(root)
            let rs = try statIdentity(rootFD)
            guard rs.st_uid == getuid(), rs.st_mode & 0o077 == 0 else { throw DownloadError.message("私有资料目录所有者或权限不安全（要求 0700）。") }
            let flags = O_NOFOLLOW | O_CLOEXEC | (readOnly ? O_RDONLY : O_RDWR) | (rootExists ? 0 : O_CREAT | O_EXCL)
            lockFD = openat(rootFD, "store.lock", flags, 0o600)
            guard lockFD >= 0, regularOwned(try statIdentity(lockFD)),
                  flock(lockFD, (readOnly ? LOCK_SH : LOCK_EX) | LOCK_NB) == 0 else {
                throw DownloadError.message("资料已由另一实例使用，或原锁文件缺失／无效。")
            }
            if !rootExists {
                let contents = try fm.contentsOfDirectory(atPath: root.path).filter { $0 != "store.lock" }
                guard contents.isEmpty else { throw DownloadError.message("发现已有资料，已停止初始化。") }
                initializing = true
                let id = UUID(); try save(DownloadDatabase(installationID: id))
                initializing = false
                let parent = try openDirectoryNoLinks(marker.deletingLastPathComponent()); defer { close(parent) }
                let markerFD = openat(parent, marker.lastPathComponent, O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC, 0o600)
                guard markerFD >= 0 else { throw posixFailure("创建独立初始化记录") }; defer { close(markerFD) }
                let data = try encoder.encode(Marker(schemaVersion: 1, installationID: id))
                try writeAll(data, to: markerFD)
                guard fsync(markerFD) == 0, fsync(parent) == 0 else { throw posixFailure("同步独立初始化记录") }
                markerDigest = importDigest(data)
            }
        } catch {
            if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD); lockFD = -1 }
            if rootFD >= 0 { close(rootFD); rootFD = -1 }
            throw error
        }
    }
    deinit { if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD) }; if rootFD >= 0 { close(rootFD) } }
    static func validateSnapshot(_ bytes: Data, marker: Data) throws -> DownloadDatabase {
        guard bytes.count <= 32 * 1024 * 1024, marker.count <= 4096 else { throw DownloadError.message("下载资料超过读取预算。") }
        let record = try JSONDecoder().decode(Marker.self, from: marker)
        guard record.schemaVersion == 1 else { throw DownloadError.message("初始化记录版本不受支持。") }
        let envelope = try JSONDecoder().decode(Envelope.self, from: bytes)
        guard importDigest(envelope.payload) == envelope.sha256 else { throw DownloadError.message("下载资料摘要损坏，已停止写入。") }
        let db = try JSONDecoder().decode(DownloadDatabase.self, from: envelope.payload)
        guard db.schemaVersion == 1, db.installationID == record.installationID, db.items.count <= 5000, db.destinations.count <= 5000, db.migrationHistory.count <= 1024, Set(db.items.map(\.id)).count == db.items.count, Set(db.jobs.map(\.id)).count == db.jobs.count, Set(db.destinations.map(\.id)).count == db.destinations.count else { throw DownloadError.message("资料格式过新、身份不一致或任务结构无效，已停止写入。") }
        guard (1...2).contains(db.settings.concurrency), (0...1_073_741_824).contains(db.settings.speedLimitBytesPerSecond), (1024...1_099_511_627_776).contains(db.settings.maxItemBytes), (1024...2_199_023_255_552).contains(db.settings.maxStagingBytes), ["system","light","dark"].contains(db.settings.appearance), db.jobs.count <= 5000, db.items.allSatisfy({ item in
            guard item.bytesReceived >= 0, item.bytesReceived <= 1_099_511_627_776, item.expectedBytes == nil || (item.expectedBytes! >= 0 && item.expectedBytes! <= 1_099_511_627_776), (try? validatedDownloadURL(item.sourceURL)) != nil, (item.stagingDevice == nil) == (item.stagingInode == nil), item.attempts >= 0 && item.attempts < 10000, item.sourceFingerprint == downloadDigest(Data(item.sourceURL.utf8)), item.displayURL == redactedDownloadURL(URL(string: item.sourceURL)!), item.suggestedName == safeDownloadName(item.suggestedName), item.bytesPerSecond.isFinite && item.bytesPerSecond >= 0, item.etag == nil || strongDownloadETag(item.etag) == item.etag, item.partialSHA256 == nil || (item.partialSHA256!.count == 64 && item.partialSHA256!.allSatisfy({ $0.isHexDigit })) else { return false }
            for artifact in [item.artifact,item.pendingArtifact].compactMap({$0}) { guard artifact.fileName == safeDownloadName(artifact.fileName), artifact.byteCount == item.bytesReceived, artifact.sha256.count == 64, artifact.sha256.allSatisfy({$0.isHexDigit}) else { return false } }
            return item.artifact == nil || item.state == .completed
        }) else { throw DownloadError.message("任务字段、产物或预算记录无效，已停止写入。") }
        let ids = Set(db.items.map(\.id)); let grants = Set(db.destinations.map(\.id)); let jobs = Dictionary(uniqueKeysWithValues: db.jobs.map { ($0.id,$0) })
        guard db.items.allSatisfy({ grants.contains($0.destinationID) && jobs[$0.jobID]?.itemIDs.contains($0.id) == true && $0.bytesReceived >= 0 && $0.stagingName == "\($0.id.uuidString).part" }), db.jobs.allSatisfy({ job in !job.itemIDs.isEmpty && job.itemIDs.count <= 32 && Set(job.itemIDs).count == job.itemIDs.count && job.itemIDs.allSatisfy({ id in ids.contains(id) && db.items.first(where: { $0.id == id })?.jobID == job.id }) }), db.destinations.allSatisfy({ $0.displayPath.hasPrefix("/") && $0.displayPath.utf8.count <= 16_384 && !$0.bookmark.isEmpty && $0.bookmark.count <= 1_048_576 && $0.inode > 0 }) else { throw DownloadError.message("任务关联记录损坏，已停止写入。") }
        return db
    }
    func verifyAvailability() throws {
        guard let snapshotDigest, let markerDigest else { throw DownloadError.message("尚未核验原下载快照。") }
        let currentFD = try openDirectoryNoLinks(root); defer { close(currentFD) }
        let original = try statIdentity(rootFD), current = try statIdentity(currentFD)
        guard original.st_dev == current.st_dev, original.st_ino == current.st_ino,
              current.st_uid == getuid(), current.st_mode & 0o077 == 0 else { throw DownloadError.message("下载资料根目录身份或权限变化。") }
        var lockAtPath = stat(); let lock = try statIdentity(lockFD)
        guard fstatat(currentFD, "store.lock", &lockAtPath, AT_SYMLINK_NOFOLLOW) == 0,
              regularOwned(lockAtPath), lockAtPath.st_dev == lock.st_dev, lockAtPath.st_ino == lock.st_ino else {
            throw DownloadError.message("下载资料的原单实例锁已被替换或删除。")
        }
        guard importDigest(try readSafe(root.appendingPathComponent("downloads.json"), maximum: 32 * 1024 * 1024)) == snapshotDigest,
              importDigest(try readSafe(marker, maximum: 4096)) == markerDigest else {
            throw DownloadError.message("原资料或初始化记录在运行中变化，已停止写入。")
        }
    }
    func load() throws -> DownloadDatabase {
        if snapshotDigest != nil && markerDigest != nil { try verifyAvailability() }
        let markerData = try readSafe(marker, maximum: 4096)
        let stored = try readSafe(root.appendingPathComponent("downloads.json"), maximum: 32 * 1024 * 1024)
        let db = try Self.validateSnapshot(stored, marker: markerData)
        snapshotDigest = importDigest(stored); markerDigest = importDigest(markerData)
        return db
    }
    func save(_ database: DownloadDatabase, beforeAtomicCommit: (() throws -> Void)? = nil) throws {
        guard !readOnly else { throw DownloadError.message("来源资料仅供迁移读取，禁止写入。") }
        guard initializing || (snapshotDigest != nil && markerDigest != nil) else { throw DownloadError.message("尚未核验原资料，已停止写入。") }
        if !initializing { try verifyAvailability() }
        let currentFD = try openDirectoryNoLinks(root); defer { close(currentFD) }
        let original = try statIdentity(rootFD), current = try statIdentity(currentFD)
        guard original.st_dev == current.st_dev, original.st_ino == current.st_ino, current.st_uid == getuid(), current.st_mode & 0o077 == 0 else { throw DownloadError.message("资料根目录身份或权限变化，停止写入。") }
        let payload = try encoder.encode(database)
        guard payload.count <= 24 * 1024 * 1024 else { throw DownloadError.message("资料达到本机任务记录预算，请先清理历史。") }
        let data = try encoder.encode(Envelope(payload: payload, sha256: importDigest(payload)))
        let name = ".transaction-\(UUID().uuidString)"
        let fd = openat(rootFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posixFailure("创建资料事务") }
        defer { close(fd); unlinkat(rootFD, name, 0) }
        try writeAll(data, to: fd)
        guard fsync(fd) == 0 else { throw posixFailure("同步资料事务") }
        // The previous complete snapshot is retained as explicit recovery evidence.
        if faccessat(rootFD, "downloads.json", F_OK, AT_SYMLINK_NOFOLLOW) == 0 {
            let old = try readSafe(root.appendingPathComponent("downloads.json"), maximum: 32 * 1024 * 1024)
            let previousName = ".previous-\(UUID().uuidString)"
            let previousFD = openat(rootFD,previousName,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
            guard previousFD >= 0 else { throw posixFailure("创建上个有效快照") }; defer { close(previousFD); unlinkat(rootFD,previousName,0) }
            try writeAll(old,to:previousFD)
            guard fsync(previousFD) == 0, renameat(rootFD,previousName,rootFD,"downloads.previous.json") == 0 else { throw posixFailure("保留上个有效快照") }
        }
        // An explicit directory reauthorization may bind external file evidence
        // to this exact database publication. Recheck it at the final boundary.
        if let beforeAtomicCommit {
            try beforeAtomicCommit()
            if !initializing { try verifyAvailability() }
        }
        guard renameat(rootFD, name, rootFD, "downloads.json") == 0, fsync(rootFD) == 0 else { throw posixFailure("提交资料事务") }
        snapshotDigest = importDigest(data)
    }
    private func readSafe(_ url: URL, maximum: Int) throws -> Data {
        let directory = try openDirectoryNoLinks(url.deletingLastPathComponent()); defer { close(directory) }
        if url.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL {
            let original = try statIdentity(rootFD), current = try statIdentity(directory)
            guard original.st_dev == current.st_dev, original.st_ino == current.st_ino else { throw DownloadError.message("资料根目录已被替换。") }
        }
        let fd = openat(directory, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw DownloadError.message("必要资料或初始化记录缺失／不可读，已停止写入。") }; defer { close(fd) }
        let s = try statIdentity(fd); guard regularOwned(s), s.st_mode & 0o077 == 0, s.st_mode & 0o400 != 0, s.st_size > 0, s.st_size <= maximum else { throw DownloadError.message("资料文件类型、所有者、链接数或大小无效。") }
        var result = Data(); var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true { let n = read(fd, &buffer, buffer.count); guard n >= 0 else { throw posixFailure("读取资料") }; if n == 0 { break }; guard result.count + n <= maximum else { throw DownloadError.message("资料超过读取预算。") }; result.append(contentsOf: buffer.prefix(n)) }
        let after = try statIdentity(fd)
        guard s.st_dev == after.st_dev, s.st_ino == after.st_ino, s.st_size == after.st_size,
              s.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, s.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec, Int64(result.count) == s.st_size else {
            throw DownloadError.message("读取期间原资料发生变化，已停止写入。")
        }
        return result
    }
}
func writeAll(_ data: Data, to fd: Int32) throws {
    try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count { let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset); if n < 0 && errno == EINTR { continue }; guard n > 0 else { throw posixFailure("写入文件") }; offset += n }
    }
}

final class DestinationAccess: @unchecked Sendable {
    let url: URL
    let fd: Int32
    private let scoped: Bool
    init(_ grant: DestinationGrant) throws {
        guard grant.requiresReauthorization != true else { throw DownloadError.message("此目录来自旧下载资料，请在搞门户重新选择原目录后恢复；未读取或改动原文件。") }
        var stale = false
        let resolved = try URL(resolvingBookmarkData: grant.bookmark, options: [.withSecurityScope, .withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale else { throw DownloadError.message("目标授权书签已失效，请重新选择原目录。") }
        scoped = resolved.startAccessingSecurityScopedResource()
        var canonical = [CChar](repeating:0,count:Int(PATH_MAX))
        guard realpath(resolved.path,&canonical) != nil else { if scoped { resolved.stopAccessingSecurityScopedResource() }; throw posixFailure("定位授权目录") }
        url = URL(fileURLWithPath:String(cString:canonical),isDirectory:true)
        do { fd = try openDirectoryNoLinks(url) } catch { if scoped { resolved.stopAccessingSecurityScopedResource() }; throw error }
        do {
            let selected = try openDirectoryNoLinks(URL(fileURLWithPath:grant.displayPath,isDirectory:true)); defer { close(selected) }
            let currentSelection = try statIdentity(selected)
            guard UInt64(currentSelection.st_dev) == grant.device, UInt64(currentSelection.st_ino) == grant.inode else { throw DownloadError.message("原保存路径已被替换或移动，请重新授权原目录。") }
            let s = try statIdentity(fd)
            guard UInt64(s.st_dev) == grant.device, UInt64(s.st_ino) == grant.inode else { throw DownloadError.message("目标目录或所在卷已被替换，等待重新授权原目录。") }
            if let volume = grant.volumeUUID {
                guard let expected = UUID(uuidString: volume),
                      let current = try resolved.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString.flatMap(UUID.init(uuidString:)),
                      expected == current else { throw DownloadError.message("目标卷身份发生改变。") }
            }
            guard faccessat(fd, ".", W_OK, 0) == 0 else { throw DownloadError.message("目标目录只读或已撤权。") }
        } catch { close(fd); if scoped { resolved.stopAccessingSecurityScopedResource() }; throw error }
    }
    deinit { close(fd); if scoped { url.stopAccessingSecurityScopedResource() } }
    func validate(_ grant: DestinationGrant) throws {
        let fresh = try openDirectoryNoLinks(url); defer { close(fresh) }; let s = try statIdentity(fresh)
        guard UInt64(s.st_dev) == grant.device, UInt64(s.st_ino) == grant.inode else { throw DownloadError.message("下载期间目标目录已被替换。") }
    }
    func stagingDirectory(grantID: UUID, create: Bool) throws -> Int32 {
        // Keep the established physical name so migrated partial identities survive.
        let name = ".GaoXiaZai-Staging-\(grantID.uuidString)"
        if create && mkdirat(fd, name, 0o700) != 0 && errno != EEXIST { throw posixFailure("创建目标卷暂存目录") }
        let stage = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard stage >= 0 else { throw posixFailure("打开自有暂存目录") }
        do { let s = try statIdentity(stage); guard s.st_uid == getuid(), s.st_mode & 0o077 == 0 else { throw DownloadError.message("暂存目录身份或权限无效。") }; return stage } catch { close(stage); throw error }
    }
}
