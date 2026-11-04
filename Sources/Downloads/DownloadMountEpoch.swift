import Foundation
import CryptoKit
import Darwin

/// An explicit directory selection can renew a grant across a remount. Device
/// numbers alone are not durable volume identities; UUID + inode and all owned
/// file evidence still have to match. This type never writes or starts work.
enum DownloadMountEpoch {
    static func sameVolumeID(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs, let a = UUID(uuidString: lhs), let b = UUID(uuidString: rhs) else { return false }
        return a == b
    }

    private static func issue(_ detail: String = "原目录或文件证据不一致，未更新授权或设备记录。") -> DownloadError { .message(detail) }
    private static func validHash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }
    private static func same(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_uid == b.st_uid && a.st_gid == b.st_gid
            && a.st_mode == b.st_mode && a.st_nlink == b.st_nlink && a.st_flags == b.st_flags && a.st_size == b.st_size
            && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
            && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
    private static func sameDirectory(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_uid == b.st_uid && a.st_gid == b.st_gid
            && a.st_mode == b.st_mode && a.st_flags == b.st_flags
    }

    static func prepare(original: DestinationGrant, items: [DownloadItem], selectedURL: URL?, renewedBookmark: Data,
                        volumeUUID: @escaping () throws -> String?, expectedUID: uid_t = getuid()) throws -> Plan {
        guard let selectedURL else { throw issue("已取消重新选择，未修改授权或任何文件。") }
        return try Plan(original: original, items: items, selectedURL: selectedURL, renewedBookmark: renewedBookmark,
                        volumeUUID: volumeUUID, expectedUID: expectedUID)
    }

    final class Plan {
        let originalGrant: DestinationGrant
        let originalItems: [DownloadItem]
        private(set) var grant: DestinationGrant
        private(set) var items: [DownloadItem]
        private let selected: URL
        private let volumeUUID: () throws -> String?
        private let originalVolumeID: UUID
        private let owner: uid_t
        private var rootFD: Int32 = -1
        private var stageFD: Int32 = -1
        private var rootIdentity = stat()
        private var stageIdentity: stat?
        private var stageMissing = false
        private var scoped = false
        private var files: [FileEvidence] = []
        private var absent: [(Int32, String)] = []
        private var stageName: String { ".GaoXiaZai-Staging-\(originalGrant.id.uuidString)" }

        private final class FileEvidence {
            let fd: Int32
            let parent: Int32
            let name: String
            let original: stat
            var digest: String?
            init(fd: Int32, parent: Int32, name: String, original: stat) {
                self.fd = fd; self.parent = parent; self.name = name; self.original = original
            }
            deinit { close(fd) }
        }

        fileprivate init(original: DestinationGrant, items: [DownloadItem], selectedURL: URL, renewedBookmark: Data,
                         volumeUUID: @escaping () throws -> String?, expectedUID: uid_t) throws {
            originalGrant = original; originalItems = items; grant = original; self.items = items
            selected = selectedURL; self.volumeUUID = volumeUUID; owner = expectedUID
            guard let recordedVolume = original.volumeUUID.flatMap({ UUID(uuidString: $0) }) else { throw issue() }
            originalVolumeID = recordedVolume
            guard selectedURL.isFileURL, selectedURL.host == nil || selectedURL.host == "localhost",
                  selectedURL.path.hasPrefix("/"), original.device > 0, original.inode > 0,
                  !renewedBookmark.isEmpty, renewedBookmark.count <= 1_048_576,
                  items.allSatisfy({ $0.destinationID == original.id }),
                  Set(items.map(\.id)).count == items.count else { throw issue() }
            scoped = selectedURL.startAccessingSecurityScopedResource()
            do {
                guard sameVolumeID(originalVolumeID.uuidString, try volumeUUID()) else { throw issue() }
                rootFD = try openDirectoryNoLinks(selectedURL)
                rootIdentity = try statIdentity(rootFD)
                guard rootIdentity.st_mode & S_IFMT == S_IFDIR, rootIdentity.st_uid == owner,
                      rootIdentity.st_mode & 0o022 == 0, UInt64(rootIdentity.st_ino) == original.inode,
                      faccessat(rootFD, ".", W_OK | X_OK, 0) == 0 else { throw issue() }
                grant.device = UInt64(rootIdentity.st_dev)
                grant.bookmark = renewedBookmark; grant.displayPath = selectedURL.path
                grant.volumeUUID = originalVolumeID.uuidString
                grant.requiresReauthorization = false
                for index in self.items.indices where self.items[index].destinationID == original.id {
                    try verifyItem(at: index)
                }
                try validate()
            } catch {
                files.removeAll()
                if stageFD >= 0 { close(stageFD); stageFD = -1 }
                if rootFD >= 0 { close(rootFD); rootFD = -1 }
                if scoped { selected.stopAccessingSecurityScopedResource(); scoped = false }
                throw error
            }
        }

        deinit {
            files.removeAll()
            if stageFD >= 0 { close(stageFD) }
            if rootFD >= 0 { close(rootFD) }
            if scoped { selected.stopAccessingSecurityScopedResource() }
        }

        /// The manager must also CAS its original grant/items and revision, then
        /// save the complete candidate once before publishing in-memory values.
        func validate() throws {
            guard rootFD >= 0, sameVolumeID(originalGrant.volumeUUID, try volumeUUID()) else { throw issue() }
            let reopened = try openDirectoryNoLinks(URL(fileURLWithPath: selected.path, isDirectory: true)); defer { close(reopened) }
            guard sameDirectory(rootIdentity, try statIdentity(rootFD)), sameDirectory(rootIdentity, try statIdentity(reopened)),
                  rootIdentity.st_uid == owner else { throw issue() }
            if let stageIdentity {
                var atPath = stat()
                guard stageFD >= 0, fstatat(rootFD, stageName, &atPath, AT_SYMLINK_NOFOLLOW) == 0,
                      sameDirectory(stageIdentity, atPath), sameDirectory(stageIdentity, try statIdentity(stageFD)) else { throw issue() }
            }
            for (parent, name) in absent {
                var value = stat()
                guard fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else { throw issue() }
            }
            for file in files {
                let sampled = try inspect(file)
                guard sampled.full == file.digest else { throw issue("核验期间文件内容发生变化，未更新授权。") }
            }
            // A later (possibly large) file hash must not hide an earlier file's
            // mutation. Recheck every descriptor/name and missing name together
            // at the end of this validation pass.
            for file in files { try validateIdentity(file) }
            for (parent, name) in absent {
                var value = stat()
                guard fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else { throw issue() }
            }
            let final = try openDirectoryNoLinks(URL(fileURLWithPath: selected.path, isDirectory: true)); defer { close(final) }
            guard sameDirectory(rootIdentity, try statIdentity(rootFD)), sameDirectory(rootIdentity, try statIdentity(final)),
                  faccessat(rootFD, ".", W_OK | X_OK, 0) == 0,
                  sameVolumeID(originalGrant.volumeUUID, try volumeUUID()) else { throw issue() }
            if let stageIdentity {
                var atPath = stat()
                guard fstatat(rootFD, stageName, &atPath, AT_SYMLINK_NOFOLLOW) == 0,
                      sameDirectory(stageIdentity, atPath), sameDirectory(stageIdentity, try statIdentity(stageFD)) else { throw issue() }
            }
        }

        private func staging() throws -> Int32? {
            if stageFD >= 0 { return stageFD }
            if stageMissing { return nil }
            var atPath = stat()
            if fstatat(rootFD, stageName, &atPath, AT_SYMLINK_NOFOLLOW) != 0 {
                guard errno == ENOENT else { throw issue() }
                stageMissing = true; absent.append((rootFD, stageName)); return nil
            }
            guard atPath.st_mode & S_IFMT == S_IFDIR else { throw issue() }
            let fd = openat(rootFD, stageName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw issue() }
            do {
                let value = try statIdentity(fd)
                guard sameDirectory(atPath, value), value.st_uid == owner, value.st_mode & 0o077 == 0,
                      value.st_dev == rootIdentity.st_dev else { throw issue() }
                stageFD = fd; stageIdentity = value; return fd
            } catch { close(fd); throw error }
        }

        private func openFile(_ parent: Int32, _ name: String) throws -> FileEvidence? {
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\") else { throw issue() }
            let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            if fd < 0 {
                guard errno == ENOENT else { throw issue() }
                absent.append((parent, name)); return nil
            }
            do {
                let value = try statIdentity(fd)
                guard value.st_mode & S_IFMT == S_IFREG, value.st_uid == owner, value.st_mode & 0o022 == 0,
                      value.st_dev == rootIdentity.st_dev, value.st_size >= 0, value.st_size <= 1_099_511_627_776,
                      value.st_nlink == 1 || value.st_nlink == 2 else { throw issue() }
                return FileEvidence(fd: fd, parent: parent, name: name, original: value)
            } catch { close(fd); throw error }
        }

        private func inspect(_ file: FileEvidence, prefix: Int64? = nil) throws -> (full: String, prefix: String) {
            let before = try statIdentity(file.fd)
            guard same(before, file.original), prefix == nil || (prefix! >= 0 && prefix! <= before.st_size) else { throw issue() }
            var full = SHA256(), prefixHash = SHA256(), offset: Int64 = 0
            var buffer = [UInt8](repeating: 0, count: 256 * 1024)
            while offset < before.st_size {
                let count = pread(file.fd, &buffer, min(buffer.count, Int(before.st_size - offset)), off_t(offset))
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw issue() }
                full.update(data: Data(buffer.prefix(count)))
                if let prefix, offset < prefix { prefixHash.update(data: Data(buffer.prefix(min(count, Int(prefix - offset))))) }
                offset += Int64(count)
            }
            try validateIdentity(file)
            return (full.finalize().map { String(format: "%02x", $0) }.joined(), prefixHash.finalize().map { String(format: "%02x", $0) }.joined())
        }

        private func validateIdentity(_ file: FileEvidence) throws {
            var atPath = stat()
            guard same(file.original, try statIdentity(file.fd)),
                  fstatat(file.parent, file.name, &atPath, AT_SYMLINK_NOFOLLOW) == 0,
                  same(file.original, atPath) else { throw issue() }
        }

        private func freeze(_ file: FileEvidence, expectedHash: String, byteCount: Int64, partial: Bool = false) throws {
            guard byteCount >= 0, validHash(expectedHash), partial ? file.original.st_size >= byteCount : file.original.st_size == byteCount else { throw issue() }
            let result = try inspect(file, prefix: partial ? byteCount : nil)
            guard (partial ? result.prefix : result.full) == expectedHash.lowercased() else { throw issue("原文件长度或 SHA-256 不一致，未更新设备记录。") }
            file.digest = result.full; files.append(file)
        }

        private func oldIdentity(_ artifact: PublishedArtifact, item: DownloadItem) throws {
            guard artifact.device == originalGrant.device, artifact.inode > 0, artifact.byteCount == item.bytesReceived,
                  artifact.byteCount >= 0, validHash(artifact.sha256), artifact.fileName == safeDownloadName(artifact.fileName) else { throw issue() }
        }
        private func oldStaging(_ item: DownloadItem) throws {
            guard item.stagingName == item.id.uuidString + ".part", item.stagingDevice == originalGrant.device,
                  let inode = item.stagingInode, inode > 0 else { throw issue() }
        }
        private func matching(_ file: FileEvidence, inode: UInt64) -> Bool { UInt64(file.original.st_ino) == inode }

        private func verifyItem(at index: Int) throws {
            let item = items[index]
            guard item.bytesReceived >= 0, (item.stagingDevice == nil) == (item.stagingInode == nil) else { throw issue() }
            if let artifact = item.artifact {
                try oldIdentity(artifact, item: item)
                guard item.state == .completed, item.pendingArtifact == nil,
                      let final = try openFile(rootFD, artifact.fileName), final.original.st_nlink == 1,
                      matching(final, inode: artifact.inode) else { throw issue() }
                try freeze(final, expectedHash: artifact.sha256, byteCount: artifact.byteCount)
                if item.stagingInode != nil {
                    try oldStaging(item)
                    guard item.stagingInode == artifact.inode else { throw issue() }
                    if let directory = try staging(), let part = try openFile(directory, item.stagingName) {
                        // A completed transaction has already removed its
                        // temporary link. Never adopt a newly occupied name.
                        _ = part; throw issue()
                    }
                    items[index].stagingDevice = grant.device
                }
                items[index].artifact?.device = grant.device
                return
            }
            if let pending = item.pendingArtifact {
                try oldIdentity(pending, item: item); try oldStaging(item)
                guard item.stagingInode == pending.inode else { throw issue() }
                let final = try openFile(rootFD, pending.fileName)
                let part = try staging().flatMap { try openFile($0, item.stagingName) }
                guard final != nil || part != nil else { throw issue() }
                for file in [final, part].compactMap({ $0 }) { guard matching(file, inode: pending.inode) else { throw issue() } }
                let links: nlink_t = final != nil && part != nil ? 2 : 1
                for file in [final, part].compactMap({ $0 }) {
                    guard file.original.st_nlink == links else { throw issue() }
                    try freeze(file, expectedHash: pending.sha256, byteCount: pending.byteCount)
                }
                items[index].pendingArtifact?.device = grant.device
                items[index].stagingDevice = grant.device
                return
            }
            if item.stagingInode != nil {
                try oldStaging(item)
                guard let directory = try staging(), let part = try openFile(directory, item.stagingName),
                      part.original.st_nlink == 1, matching(part, inode: item.stagingInode!) else { throw issue() }
                let expected: String
                if item.bytesReceived == 0 { expected = SHA256.hash(data: Data()).map { String(format: "%02x", $0) }.joined() }
                else { guard let hash = item.partialSHA256, validHash(hash) else { throw issue() }; expected = hash }
                try freeze(part, expectedHash: expected, byteCount: item.bytesReceived, partial: true)
                items[index].stagingDevice = grant.device
            } else {
                guard item.bytesReceived == 0 else { throw issue() }
            }
        }
    }
}
