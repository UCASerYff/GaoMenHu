import Foundation
import CryptoKit
import Darwin

/// Metadata only: URLs, browser state and credentials are never written here.
struct PortalDownloadResultRecord: Codable, Equatable {
    let requestID: String
    let fingerprint: String
    let status: String
    let workflowState: String
    let taskIDs: [String]
    let errorCode: String?
    let items: [GaoActionItem]
    let stagedPackageName: String
    let receivedAt: Date
}
struct PortalDownloadRequestRecord: Codable, Equatable {
    let requestID: String
    let fingerprint: String
    let parentRequestID: String?
    let createdAt: Date
    var taskIDs: [String]
    var results: [PortalDownloadResultRecord]
    var terminal: Bool { results.last.map { $0.status != "pending" } ?? false }
}
enum PortalDownloadReceipt { case received(PortalDownloadRequestRecord, PortalDownloadResultRecord), repeated(PortalDownloadRequestRecord, PortalDownloadResultRecord) }

protocol PortalDownloadEvidenceStore: AnyObject {
    func load() throws -> Data?
    func save(_ value: Data) throws
}
final class PortalDownloadDefaultsEvidence: PortalDownloadEvidenceStore {
    private let key: String
    init(directory: URL) {
        key = "GaoMenHu.DownloadReturnEvidence." + SHA256.hash(data: Data(directory.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func load() throws -> Data? {
        guard let value = UserDefaults.standard.object(forKey: key) else { return nil }
        guard let data = value as? Data else { throw PortalDownloadJournal.invalid }
        return data
    }
    func save(_ value: Data) throws {
        UserDefaults.standard.set(value, forKey: key)
        guard UserDefaults.standard.synchronize(), UserDefaults.standard.data(forKey: key) == value else { throw PortalDownloadJournal.invalid }
    }
}

/// Separate durable outgoing/result journal, anchored outside MenDao by defaults.
/// Any missing/corrupt/interrupted evidence blocks receipt, rather than forgetting IDs.
final class PortalDownloadJournal {
    static let sourceBundleID = "cn.mendao.launcher"
    static let targetBundleID = "com.gaoseries.GaoXiaZai"
    static let action = "downloads.prepare"
    static let invalid = PortalActionError(code: "invalid_download_journal", message: "下载交接记录缺失、已变化或恢复未完成，已停止接收；请保留原资料并恢复备份。")
    static let mismatch = PortalActionError(code: "unmatched_download_result", message: "下载结果与已发送请求或已确认任务不匹配，未接纳文件。")
    private struct Envelope: Codable { let schemaVersion: Int; let identity: String; var generation: Int; var records: [PortalDownloadRequestRecord] }
    private struct Evidence: Codable { let schemaVersion: Int; let identity: String; let generation: Int; let sha256: String; let pending: Bool }
    let directory: URL
    private let evidence: PortalDownloadEvidenceStore
    private var envelope: Envelope
    private var currentDigest: String
    private let directoryFD: Int32
    private let lockFD: Int32
    private var valid = true
    static let maximumRecords = 4096

    init(directory: URL, evidence: PortalDownloadEvidenceStore? = nil) throws {
        self.directory = directory
        self.evidence = evidence ?? PortalDownloadDefaultsEvidence(directory: directory)
        let external = try self.evidence.load()
        var existing = stat()
        let exists = lstat(directory.path, &existing) == 0
        if !exists, errno != ENOENT { throw Self.invalid }
        if external == nil {
            // New feature may initialize beside an old Exchange, but never over a
            // pre-existing Downloads directory or a retained initialization marker.
            guard !exists else { throw Self.invalid }
            let parent = try Self.privateDirectory(directory.deletingLastPathComponent(), create: true)
            defer { close(parent) }
            guard mkdirat(parent, directory.lastPathComponent, 0o700) == 0, fsync(parent) == 0 else { throw Self.invalid }
        } else { guard exists else { throw Self.invalid } }
        let fd = try Self.privateDirectory(directory, create: false)
        var acquiredLock: Int32 = -1
        do {
            let lockFlags = O_RDWR | O_NOFOLLOW | O_CLOEXEC | (external == nil ? O_CREAT | O_EXCL : 0)
            acquiredLock = openat(fd, "journal.lock", lockFlags, 0o600)
            guard acquiredLock >= 0 else { throw Self.invalid }
            _ = try Self.regular(acquiredLock)
            guard flock(acquiredLock, LOCK_EX | LOCK_NB) == 0 else { throw Self.invalid }
            let decoded: Envelope; let digest: String
            if let external {
                let marker = try JSONDecoder().decode(Evidence.self, from: external)
                guard marker.schemaVersion == 1, !marker.pending, UUID(uuidString: marker.identity) != nil, marker.generation > 0 else { throw Self.invalid }
                let data = try Self.readFile("outgoing.json", at: fd)
                digest = Self.hash(data)
                decoded = try JSONDecoder().decode(Envelope.self, from: data)
                guard decoded.schemaVersion == 1, decoded.identity == marker.identity, decoded.generation == marker.generation,
                      digest == marker.sha256, Self.validRecords(decoded.records) else { throw Self.invalid }
            } else {
                decoded = Envelope(schemaVersion: 1, identity: UUID().uuidString.lowercased(), generation: 1, records: [])
                let data = try JSONEncoder().encode(decoded); digest = Self.hash(data)
                try self.evidence.save(try JSONEncoder().encode(Evidence(schemaVersion: 1, identity: decoded.identity, generation: 1, sha256: digest, pending: true)))
                try Self.replace(data, at: fd, new: true)
                try self.evidence.save(try JSONEncoder().encode(Evidence(schemaVersion: 1, identity: decoded.identity, generation: 1, sha256: digest, pending: false)))
            }
            self.envelope = decoded; self.currentDigest = digest; self.directoryFD = fd; self.lockFD = acquiredLock
        } catch {
            if acquiredLock >= 0 { close(acquiredLock) }; close(fd); throw Self.invalid
        }
    }
    deinit { close(lockFD); close(directoryFD) }
    var allRecords: [PortalDownloadRequestRecord] { envelope.records.sorted { $0.createdAt > $1.createdAt } }
    func verifyAvailability() throws { try assertCurrent() }

    /// Outgoing package must already exist; this commit precedes NSWorkspace.open.
    func register(_ manifest: GaoActionManifest, parentRequestID: String? = nil, now: Date = Date()) throws {
        guard manifest.kind == "request", manifest.sourceBundleID == Self.sourceBundleID, manifest.targetBundleID == Self.targetBundleID,
              manifest.action == Self.action, manifest.items.isEmpty, manifest.references.isEmpty,
              parentRequestID == nil || UUID(uuidString: parentRequestID!) != nil else { throw Self.mismatch }
        _ = try GaoActionPackage.validate(data: GaoActionPackage.manifestData(manifest), targetBundleID: Self.targetBundleID, now: now) { value in
            guard Set(value.parameters.keys).isSubset(of: ["urls", "mediaType"]), value.parameters["urls"] != nil else { throw Self.mismatch }
            var p = value.parameters.mapValues(\.foundationValue); p.removeValue(forKey: "mediaType")
            try PortalActionPlanner.validateParameters(action: "portal.prepareDownload", parameters: p)
            if let media = value.parameters["mediaType"] { guard let type = media.string, ["file", "video", "audio", "image", "subtitle"].contains(type) else { throw Self.mismatch } }
        }
        let id = manifest.requestID.lowercased(); let fingerprint = Self.hash(try GaoActionPackage.manifestData(manifest))
        try assertCurrent()
        if let old = envelope.records.first(where: { $0.requestID == id }) {
            guard old.fingerprint == fingerprint, old.parentRequestID == parentRequestID?.lowercased() else { throw Self.mismatch }; return
        }
        guard envelope.records.count < Self.maximumRecords, let created = Self.date(manifest.createdAt) else { throw Self.invalid }
        var next = envelope
        next.records.append(PortalDownloadRequestRecord(requestID: id, fingerprint: fingerprint, parentRequestID: parentRequestID?.lowercased(), createdAt: created, taskIDs: [], results: []))
        try persist(next)
    }

    /// Called by the FD codec before copying anything into private Incoming.
    static func validateResult(_ manifest: GaoActionManifest) throws {
        guard manifest.kind == "result", manifest.action == action, manifest.sourceBundleID == targetBundleID,
              manifest.targetBundleID == sourceBundleID, manifest.parameters.isEmpty, manifest.references.isEmpty,
              let provenance = manifest.provenance, Set(provenance.keys) == ["workflowState", "taskIDs"],
              let state = provenance["workflowState"]?.string,
              let rawTasks = provenance["taskIDs"]?.array else { throw mismatch }
        let tasks = rawTasks.compactMap(\.string)
        guard tasks.count == rawTasks.count, tasks.count <= 256, Set(tasks).count == tasks.count,
              tasks.allSatisfy(Self.validTask), validErrorCode(manifest.errorCode), let status = manifest.status else { throw mismatch }
        switch status {
        case "pending":
            guard state == "accepted", !tasks.isEmpty, manifest.items.isEmpty, manifest.errorCode == nil else { throw mismatch }
        case "completed", "partial":
            guard state == status, !tasks.isEmpty, !manifest.items.isEmpty, status != "completed" || manifest.errorCode == nil else { throw mismatch }
        case "failed", "cancelled", "unsupported":
            guard state == status, manifest.items.isEmpty else { throw mismatch }
        default: throw mismatch
        }
    }
    /// The codec has already verified ordinary payload files and all their hashes.
    /// This method revalidates the envelope/time and never follows original references.
    func receive(_ package: GaoActionReceivedPackage, now: Date = Date()) throws -> PortalDownloadReceipt {
        let manifest = package.manifest
        _ = try GaoActionPackage.validate(data: GaoActionPackage.manifestData(manifest), targetBundleID: Self.sourceBundleID, now: now, validateAction: Self.validateResult)
        try assertCurrent()
        guard let reply = manifest.inReplyTo?.lowercased(), let index = envelope.records.firstIndex(where: { $0.requestID == reply }),
              let created = Self.date(manifest.createdAt), created >= envelope.records[index].createdAt else { throw Self.mismatch }
        let id = manifest.requestID.lowercased()
        guard !envelope.records.contains(where: { $0.requestID == id }) else { throw Self.mismatch }
        // Result IDs are globally unique across outgoing requests, not just within one.
        for record in envelope.records {
            if let previous = record.results.first(where: { $0.requestID == id }) {
                guard record.requestID == reply, previous.fingerprint == package.manifestSHA256 else { throw Self.mismatch }
                return .repeated(record, previous)
            }
        }
        var record = envelope.records[index]
        guard !record.terminal, record.results.count < 256 else { throw Self.mismatch }
        let tasks = manifest.provenance!["taskIDs"]!.array!.compactMap(\.string).sorted()
        if !record.taskIDs.isEmpty { guard tasks == record.taskIDs else { throw Self.mismatch } }
        if manifest.status == "completed" || manifest.status == "partial" {
            // Lost pending must be redelivered; an arbitrary new task ID cannot close a request.
            guard !record.taskIDs.isEmpty else { throw Self.mismatch }
        }
        if manifest.status == "pending" {
            guard envelope.records.enumerated().allSatisfy({ $0.offset == index || Set($0.element.taskIDs).isDisjoint(with: tasks) }) else { throw Self.mismatch }
            record.taskIDs = tasks
        } else if record.taskIDs.isEmpty { guard tasks.isEmpty else { throw Self.mismatch } }
        let name = package.packageURL.lastPathComponent
        guard UUID(uuidString: package.packageURL.deletingPathExtension().lastPathComponent) != nil,
              package.packageURL.pathExtension == "gaoaction", Self.isDigest(package.manifestSHA256) else { throw Self.mismatch }
        let result = PortalDownloadResultRecord(requestID: id, fingerprint: package.manifestSHA256, status: manifest.status!,
            workflowState: manifest.provenance!["workflowState"]!.string!, taskIDs: tasks, errorCode: manifest.errorCode,
            items: manifest.items, stagedPackageName: name, receivedAt: now)
        record.results.append(result)
        var next = envelope; next.records[index] = record; try persist(next)
        return .received(record, result)
    }

    private func assertCurrent() throws {
        guard valid else { throw Self.invalid }
        do {
            let opened = try Self.privateDirectory(directory, create: false); defer { close(opened) }
            let reopenedLock = openat(opened, "journal.lock", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard reopenedLock >= 0 else { throw Self.invalid }; defer { close(reopenedLock) }
            let lockNow = try Self.regular(reopenedLock); let lockOriginal = try Self.regular(lockFD)
            guard lockNow.st_dev == lockOriginal.st_dev, lockNow.st_ino == lockOriginal.st_ino else { throw Self.invalid }
            var a = stat(); var b = stat()
            guard fstat(opened, &a) == 0, fstat(directoryFD, &b) == 0, a.st_dev == b.st_dev, a.st_ino == b.st_ino,
                  let data = try evidence.load(), let marker = try? JSONDecoder().decode(Evidence.self, from: data),
                  marker.schemaVersion == 1, marker.identity == envelope.identity, marker.generation == envelope.generation,
                  !marker.pending, marker.sha256 == currentDigest, Self.hash(try Self.readFile("outgoing.json", at: directoryFD)) == currentDigest else { throw Self.invalid }
        } catch { valid = false; throw Self.invalid }
    }
    private func persist(_ value: Envelope) throws {
        try assertCurrent()
        var next = value; next.generation = envelope.generation + 1
        guard next.generation > envelope.generation, Self.validRecords(next.records) else { throw Self.invalid }
        let data = try JSONEncoder().encode(next); let digest = Self.hash(data)
        guard data.count <= 16 * 1_048_576 else { throw Self.invalid }
        do {
            try evidence.save(try JSONEncoder().encode(Evidence(schemaVersion: 1, identity: next.identity, generation: next.generation, sha256: digest, pending: true)))
            try Self.replace(data, at: directoryFD, new: false)
            try evidence.save(try JSONEncoder().encode(Evidence(schemaVersion: 1, identity: next.identity, generation: next.generation, sha256: digest, pending: false)))
            envelope = next; currentDigest = digest
        } catch { valid = false; throw Self.invalid }
    }
    private static func validRecords(_ records: [PortalDownloadRequestRecord]) -> Bool {
        guard records.count <= maximumRecords, Set(records.map(\.requestID)).count == records.count else { return false }
        var resultIDs = Set<String>()
        for record in records {
            guard UUID(uuidString: record.requestID) != nil, record.requestID == record.requestID.lowercased(), isDigest(record.fingerprint),
                  record.createdAt.timeIntervalSince1970.isFinite, record.parentRequestID == nil || UUID(uuidString: record.parentRequestID!) != nil,
                  record.taskIDs == record.taskIDs.sorted(), Set(record.taskIDs).count == record.taskIDs.count,
                  record.taskIDs.allSatisfy(validTask), record.results.count <= 256 else { return false }
            for (index, result) in record.results.enumerated() {
                guard UUID(uuidString: result.requestID) != nil, resultIDs.insert(result.requestID).inserted, isDigest(result.fingerprint),
                      result.receivedAt >= record.createdAt, result.receivedAt.timeIntervalSince1970.isFinite,
                      UUID(uuidString: URL(fileURLWithPath: result.stagedPackageName).deletingPathExtension().lastPathComponent) != nil,
                      !result.stagedPackageName.contains("/"), result.stagedPackageName.hasSuffix(".gaoaction"),
                      result.taskIDs == result.taskIDs.sorted(), Set(result.taskIDs).count == result.taskIDs.count,
                      result.taskIDs.allSatisfy(validTask), result.taskIDs == record.taskIDs, validErrorCode(result.errorCode),
                      result.status == "pending" || index == record.results.count - 1 else { return false }
                switch result.status {
                case "pending": guard result.workflowState == "accepted", !result.taskIDs.isEmpty, result.items.isEmpty, result.errorCode == nil else { return false }
                case "completed", "partial": guard result.workflowState == result.status, !result.items.isEmpty, !result.taskIDs.isEmpty, index > 0,
                    result.status != "completed" || result.errorCode == nil else { return false }
                case "failed", "cancelled", "unsupported": guard result.workflowState == result.status, result.items.isEmpty else { return false }
                default: return false
                }
                guard result.items.count <= GaoActionPackage.maximumItems, result.items.allSatisfy({ isDigest($0.sha256) && $0.byteCount >= 0 }) else { return false }
            }
        }
        return true
    }
    private static func validErrorCode(_ code: String?) -> Bool {
        guard let code else { return true }
        return !code.isEmpty && code.utf8.count <= 80 && code.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }
    }
    private static func validTask(_ id: String) -> Bool {
        id.utf8.count <= 256 && id.range(of: "^[A-Za-z0-9][A-Za-z0-9._:-]*$", options: .regularExpression) != nil
    }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func isDigest(_ value: String) -> Bool { value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil }
    private static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = value.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return formatter.date(from: value)
    }
    private static func privateDirectory(_ url: URL, create: Bool) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0") else { throw invalid }
        var current = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC); guard current >= 0 else { throw invalid }
        do {
            let components = url.path.components(separatedBy: "/").filter { !$0.isEmpty }
            guard !components.isEmpty, components.allSatisfy({ $0 != "." && $0 != ".." }) else { throw invalid }
            for component in components {
                var next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0, create, errno == ENOENT {
                    guard mkdirat(current, component, 0o700) == 0, fsync(current) == 0 else { throw invalid }
                    next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else { throw invalid }; close(current); current = next
            }
            var info = stat()
            guard fstat(current, &info) == 0, info.st_uid == getuid(), (info.st_mode & 0o077) == 0,
                  (info.st_mode & 0o700) == 0o700 else { throw invalid }
            return current
        } catch { close(current); throw error }
    }
    private static func regular(_ fd: Int32) throws -> stat {
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(),
              info.st_nlink == 1, (info.st_mode & 0o077) == 0, (info.st_mode & 0o600) == 0o600 else { throw invalid }
        return info
    }
    private static func readFile(_ name: String, at parent: Int32) throws -> Data {
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC); guard fd >= 0 else { throw invalid }; defer { close(fd) }
        let before = try regular(fd); guard before.st_size > 0, before.st_size <= 16 * 1_048_576 else { throw invalid }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count); if count < 0, errno == EINTR { continue }
            guard count >= 0, data.count + max(0, count) <= 16 * 1_048_576 else { throw invalid }
            if count == 0 { break }; data.append(contentsOf: buffer.prefix(count))
        }
        let after = try regular(fd)
        guard before.st_dev == after.st_dev, before.st_ino == after.st_ino, before.st_size == after.st_size, Int64(data.count) == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw invalid }
        return data
    }
    private static func replace(_ data: Data, at parent: Int32, new: Bool) throws {
        let name = "." + UUID().uuidString + ".staging"
        let fd = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600); guard fd >= 0 else { throw invalid }
        defer { close(fd); unlinkat(parent, name, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }; guard count > 0 else { throw invalid }; offset += count
            }
        }
        guard fsync(fd) == 0 else { throw invalid }
        if new { guard renameatx_np(parent, name, parent, "outgoing.json", UInt32(RENAME_EXCL)) == 0 else { throw invalid } }
        else { guard renameat(parent, name, parent, "outgoing.json") == 0 else { throw invalid } }
        guard fsync(parent) == 0 else { throw invalid }
    }
}
