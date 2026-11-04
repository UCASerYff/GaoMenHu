import Foundation
import Darwin

/// Distinguishes an unused legacy preference domain from a damaged preference
/// file. A failed read must never authorize initializing an empty module store.
enum PortalLegacyPreferences {
    enum ReadError: Error { case unreadable }
    private static let budget = 32 * 1024 * 1024

    static func read(domain: [String: Any]?, file: URL) throws -> Data {
        guard file.isFileURL, file.path.hasPrefix("/"), file.pathComponents.count > 1,
              file.pathComponents.dropFirst().allSatisfy({ !["", ".", ".."].contains($0) }) else { throw ReadError.unreadable }
        var parent = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else { throw ReadError.unreadable }
        defer { close(parent) }
        for component in file.deletingLastPathComponent().pathComponents.dropFirst() {
            let next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw ReadError.unreadable }
            close(parent); parent = next
        }
        var pathInfo = stat()
        let present: Bool
        if fstatat(parent, file.lastPathComponent, &pathInfo, AT_SYMLINK_NOFOLLOW) == 0 { present = true }
        else if errno == ENOENT { present = false }
        else { throw ReadError.unreadable }
        var diskValue: [String: Any]?
        if present {
            let fd = openat(parent, file.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw ReadError.unreadable }
            defer { close(fd) }
            var before = stat()
            guard fstat(fd, &before) == 0, valid(before), before.st_size > 0, before.st_size <= budget,
                  before.st_dev == pathInfo.st_dev, before.st_ino == pathInfo.st_ino else { throw ReadError.unreadable }
            var bytes = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                guard count >= 0, bytes.count + max(0, count) <= budget else { throw ReadError.unreadable }
                if count == 0 { break }
                bytes.append(contentsOf: buffer.prefix(count))
            }
            var after = stat(), atPath = stat()
            guard fstat(fd, &after) == 0, valid(after), before.st_dev == after.st_dev, before.st_ino == after.st_ino,
                  before.st_size == after.st_size, Int64(bytes.count) == before.st_size,
                  before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                  before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
                  fstatat(parent, file.lastPathComponent, &atPath, AT_SYMLINK_NOFOLLOW) == 0,
                  valid(atPath), after.st_dev == atPath.st_dev, after.st_ino == atPath.st_ino,
                  let decoded = try PropertyListSerialization.propertyList(from: bytes, options: [], format: nil) as? [String: Any] else {
                throw ReadError.unreadable
            }
            diskValue = decoded
        }
        // Include values still cached by cfprefsd, but only after verifying that
        // any on-disk evidence is readable and actually a preference dictionary.
        let value = domain ?? diskValue ?? [:]
        if let diskValue, !diskValue.isEmpty, value.isEmpty { throw ReadError.unreadable }
        let result = try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
        guard result.count <= budget else { throw ReadError.unreadable }
        return result
    }

    private static func valid(_ info: stat) -> Bool {
        info.st_mode & S_IFMT == S_IFREG && info.st_uid == getuid() && info.st_nlink == 1 && info.st_mode & 0o022 == 0
    }
}
