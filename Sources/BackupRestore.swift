import Foundation
import Darwin

#if DEBUG_TESTING
enum BackupRestoreTesting {
    /// Fails at verified staging, snapshot swap, library replacement or final verification.
    static var failAfterMove: Int?
    static var observeStep: ((Int) -> Void)?
}
#endif

extension LibraryStore {
    /// Restore portable data without replacing this Mac's account bindings or socket.
    /// A pre-restore snapshot is always retained; other local/imported snapshots
    /// share the remaining nine slots, newest first. Local IDs win collisions.
    func installBackup(_ payload: FullBackup.Payload, current: Library) throws -> Library {
        guard payload.manifest.appID == FullBackup.appID, payload.manifest.format == 1,
              payload.snapshots.count <= FullBackup.maximumSnapshots else {
            throw RestoreFiles.failure("完整资料身份或快照数量无效。")
        }
        let restored = try LibraryOperations.restore(payload.library, into: current)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var imported: [String: FullBackup.Snapshot] = [:]
        for snapshot in payload.snapshots {
            try RestoreFiles.validate(snapshot, id: snapshot.metadata.id)
            let key = snapshot.metadata.id.lowercased()
            guard imported[key] == nil else { throw RestoreFiles.failure("完整资料中存在重复快照编号。") }
            let normalized = try LibraryOperations.restore(snapshot.library, into: current)
            imported[key] = FullBackup.Snapshot(metadata: LibrarySnapshot(id: snapshot.metadata.id,
                createdAt: snapshot.metadata.createdAt, reason: snapshot.metadata.reason,
                siteCount: normalized.sites.count, folderCount: normalized.tiles.filter { $0.kind == "folder" }.count), library: normalized)
        }

        let baseline: RestoreFiles.Baseline
        if persistent {
            baseline = try RestoreFiles.capture(directory: directory, expected: current)
        } else {
            baseline = RestoreFiles.Baseline(library: nil, snapshots: transientSnapshots, hadSnapshots: !transientSnapshots.isEmpty)
        }
        for (id, data) in baseline.snapshots {
            let snapshot = try JSONDecoder().decode(FullBackup.Snapshot.self, from: data)
            try RestoreFiles.validate(snapshot, id: id)
            imported[id.lowercased()] = snapshot
        }
        let latest = imported.values.sorted {
            if $0.metadata.createdAt != $1.metadata.createdAt { return $0.metadata.createdAt > $1.metadata.createdAt }
            return $0.metadata.id < $1.metadata.id
        }.prefix(FullBackup.maximumSnapshots - 1)
        var safetyID = UUID().uuidString
        while imported[safetyID.lowercased()] != nil { safetyID = UUID().uuidString }
        let safety = FullBackup.Snapshot(metadata: LibrarySnapshot(id: safetyID,
            createdAt: Date().timeIntervalSince1970, reason: "恢复完整资料前",
            siteCount: current.sites.count, folderCount: current.tiles.filter { $0.kind == "folder" }.count), library: current)
        let snapshots = try Dictionary(uniqueKeysWithValues: (Array(latest) + [safety]).map {
            ($0.metadata.id, try encoder.encode($0))
        })
        let bytes = try encoder.encode(restored)
        guard bytes.count <= FullBackup.maximumFileBytes,
              snapshots.values.allSatisfy({ $0.count <= FullBackup.maximumFileBytes }),
              snapshots.values.reduce(bytes.count, { $0 + $1.count }) <= FullBackup.maximumTotalBytes else {
            throw RestoreFiles.failure("恢复后的资料超过完整备份大小限制，原资料未更改。")
        }
        if !persistent { transientSnapshots = snapshots; return restored }
        try RestoreFiles.commit(library: bytes, snapshots: snapshots, baseline: baseline, directory: directory, expected: current)
        return restored
    }
}

private enum RestoreFiles {
    struct Baseline: Equatable {
        let library: Data?
        let snapshots: [String: Data]
        let hadSnapshots: Bool
    }
    static func failure(_ text: String) -> AppError { .message(text) }

    static func validate(_ snapshot: FullBackup.Snapshot, id: String) throws {
        _ = try snapshot.library.validated()
        let m = snapshot.metadata
        guard UUID(uuidString: id) != nil, id == m.id,
              m.createdAt.isFinite, m.createdAt > 0, m.reason.count <= 100,
              m.siteCount == snapshot.library.sites.count,
              m.folderCount == snapshot.library.tiles.filter({ $0.kind == "folder" }).count else {
            throw failure("快照内容或编号无效，原资料未更改。")
        }
    }

    /// lstat also detects dangling symlinks; fileExists alone would miss them.
    static func kind(_ url: URL) throws -> mode_t? {
        var info = stat()
        if lstat(url.path, &info) == 0 { return info.st_mode & S_IFMT }
        if errno == ENOENT { return nil }
        throw failure("无法检查恢复路径：\(url.lastPathComponent)（\(errno)）。")
    }
    static func require(_ url: URL, kind expected: mode_t) throws -> Bool {
        guard let actual = try kind(url) else { return false }
        guard actual == expected else { throw failure("恢复路径不是预期的普通文件或目录：\(url.lastPathComponent)。") }
        return true
    }
    static func read(_ url: URL) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw failure("无法安全读取恢复资料：\(url.lastPathComponent)。") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= FullBackup.maximumFileBytes else {
            throw failure("恢复资料文件类型或大小无效：\(url.lastPathComponent)。")
        }
        var data = Data()
        while let chunk = try handle.read(upToCount: min(1_048_576, FullBackup.maximumFileBytes - data.count + 1)), !chunk.isEmpty {
            guard chunk.count <= FullBackup.maximumFileBytes - data.count else { throw failure("恢复资料超过大小限制。") }
            data.append(chunk)
        }
        return data
    }
    static func capture(directory: URL, expected: Library) throws -> Baseline {
        guard directory.isFileURL else { throw failure("资料目录必须位于本机。") }
        guard try require(directory, kind: S_IFDIR) else { return Baseline(library: nil, snapshots: [:], hadSnapshots: false) }
        let libraryURL = directory.appendingPathComponent("library.json")
        let bytes = try require(libraryURL, kind: S_IFREG) ? read(libraryURL) : nil
        if let bytes {
            guard try JSONDecoder().decode(Library.self, from: bytes).validated() == expected else {
                throw failure("本机网站资料已变化，请重新预览后恢复。")
            }
        }
        let snapshotURL = directory.appendingPathComponent("Snapshots", isDirectory: true)
        let exists = try require(snapshotURL, kind: S_IFDIR)
        var snapshots: [String: Data] = [:]
        var ids: Set<String> = []
        var total = bytes?.count ?? 0
        if exists {
            let entries = try FileManager.default.contentsOfDirectory(at: snapshotURL, includingPropertiesForKeys: nil)
            guard entries.count <= 100 else { throw failure("本机快照数量异常，请先检查资料目录。") }
            for entry in entries {
                let id = entry.deletingPathExtension().lastPathComponent
                guard entry.pathExtension == "json", UUID(uuidString: id) != nil,
                      ids.insert(id.lowercased()).inserted, try require(entry, kind: S_IFREG) else {
                    throw failure("本机快照目录包含非快照文件或链接，未替换任何资料。")
                }
                let data = try read(entry)
                let snapshot = try JSONDecoder().decode(FullBackup.Snapshot.self, from: data)
                try validate(snapshot, id: id)
                total += data.count
                guard total <= FullBackup.maximumTotalBytes else { throw failure("本机恢复资料超过大小限制。") }
                snapshots[id] = data
            }
        }
        return Baseline(library: bytes, snapshots: snapshots, hadSnapshots: exists)
    }
    static func privateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                              attributes: [.posixPermissions: 0o700])
    }
    static func write(_ data: Data, to url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw failure("无法暂存恢复资料：\(url.lastPathComponent)。") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do { try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        guard try read(url) == data else { throw failure("恢复暂存文件校验失败。") }
    }
    static func stage(library: Data?, snapshots: [String: Data], hadSnapshots: Bool, at root: URL) throws {
        try privateDirectory(root)
        if let library { try write(library, to: root.appendingPathComponent("library.json")) }
        if hadSnapshots {
            let folder = root.appendingPathComponent("Snapshots", isDirectory: true)
            try privateDirectory(folder)
            for (id, data) in snapshots { try write(data, to: folder.appendingPathComponent(id + ".json")) }
        }
    }
    /// Both operations leave the old or new live object present at every instant.
    /// RENAME_SWAP is needed for nonempty directories; plain rename replaces files.
    static func replaceFile(_ source: URL, _ destination: URL) throws {
        _ = try require(source, kind: S_IFREG)
        _ = try require(destination, kind: S_IFREG)
        guard rename(source.path, destination.path) == 0 else {
            throw failure("无法原子替换网站资料（\(errno)）。")
        }
    }
    static func replaceDirectory(_ source: URL, _ destination: URL) throws {
        guard try require(source, kind: S_IFDIR) else { throw failure("缺少已验证的快照暂存目录。") }
        let result: Int32
        if try require(destination, kind: S_IFDIR) {
            result = renameatx_np(AT_FDCWD, source.path, AT_FDCWD, destination.path, UInt32(RENAME_SWAP))
        } else { result = rename(source.path, destination.path) }
        guard result == 0 else { throw failure("无法原子替换快照目录（\(errno)）。") }
    }
    static func commit(library: Data, snapshots: [String: Data], baseline: Baseline,
                       directory: URL, expected: Library) throws {
        let fm = FileManager.default
        if try !require(directory, kind: S_IFDIR) {
            // Resolve existing parent paths once; only the owned data directory is created.
            let parent = directory.deletingLastPathComponent()
            guard try require(parent, kind: S_IFDIR) else { throw failure("资料目录的父目录不存在。") }
            try privateDirectory(directory)
        }
        let transaction = directory.appendingPathComponent(".gaomenhu-restore-" + UUID().uuidString, isDirectory: true)
        try privateDirectory(transaction)
        let staged = transaction.appendingPathComponent("staged", isDirectory: true)
        let rollback = transaction.appendingPathComponent("rollback", isDirectory: true)
        var changed = false
        do {
            try stage(library: library, snapshots: snapshots, hadSnapshots: true, at: staged)
            // A separate verified copy exists before either live object changes.
            // Moving the live library aside would create a dangerous missing-file gap.
            try stage(library: baseline.library, snapshots: baseline.snapshots,
                      hadSnapshots: baseline.hadSnapshots, at: rollback)
            // Stage/validation may take time. Never overwrite data written meanwhile.
            guard try capture(directory: directory, expected: expected) == baseline else {
                throw failure("恢复准备期间本机资料已变化，请重新预览。")
            }
            func step(_ number: Int) throws {
                #if DEBUG_TESTING
                BackupRestoreTesting.observeStep?(number)
                if BackupRestoreTesting.failAfterMove == number { throw failure("测试：提交中途失败。") }
                #endif
            }
            try step(1)
            // Install the pre-restore safety snapshot before committing the library.
            // An interrupted transaction therefore keeps a usable library and history.
            try replaceDirectory(staged.appendingPathComponent("Snapshots"), directory.appendingPathComponent("Snapshots"))
            changed = true
            try step(2)
            try replaceFile(staged.appendingPathComponent("library.json"), directory.appendingPathComponent("library.json"))
            try step(3)
            guard try read(directory.appendingPathComponent("library.json")) == library else { throw failure("恢复后的资料校验失败。") }
            try step(4)
            // Keep baseline bytes until cleanup finishes. Even a cleanup failure
            // can reconstruct the old state and report failure without split UI state.
            try fm.removeItem(at: transaction)
        } catch {
            let original = error
            if changed {
                do {
                    if try kind(transaction) == nil { try privateDirectory(transaction) }
                    let recovery = transaction.appendingPathComponent("recovery-" + UUID().uuidString)
                    try stage(library: baseline.library, snapshots: baseline.snapshots,
                              hadSnapshots: baseline.hadSnapshots, at: recovery)
                    let snapshotDestination = directory.appendingPathComponent("Snapshots")
                    if baseline.hadSnapshots {
                        try replaceDirectory(recovery.appendingPathComponent("Snapshots"), snapshotDestination)
                    } else if try require(snapshotDestination, kind: S_IFDIR) {
                        try fm.moveItem(at: snapshotDestination, to: transaction.appendingPathComponent("failed-" + UUID().uuidString))
                    }
                    let libraryDestination = directory.appendingPathComponent("library.json")
                    if baseline.library != nil {
                        try replaceFile(recovery.appendingPathComponent("library.json"), libraryDestination)
                    } else if try require(libraryDestination, kind: S_IFREG) {
                        // No file existed before a first-time restore; preserve that absence.
                        try fm.moveItem(at: libraryDestination, to: transaction.appendingPathComponent("failed-" + UUID().uuidString))
                    }
                } catch {
                    throw failure("恢复失败，自动回滚未能完成。安全资料保留在 \(transaction.path)。原错误：\(original.localizedDescription)；回滚错误：\(error.localizedDescription)")
                }
            }
            do { if try kind(transaction) != nil { try fm.removeItem(at: transaction) } }
            catch {
                throw failure("恢复未完成，原资料已保留；临时恢复资料未能清理：\(transaction.path)。原错误：\(original.localizedDescription)；清理错误：\(error.localizedDescription)")
            }
            throw original
        }
    }
}
