import Foundation
import Darwin

/// A bounded, read-only routing hint. The selected service still validates the
/// entire envelope, TTL, target, paths and payloads before copying or recording.
enum PortalDownloadIngress {
    static let canonicalBundleID = "cn.mendao.launcher"
    static let hostBundleID = "cn.mendao.launcher"
    static func isDownloadPackage(_ url: URL) throws -> Bool {
        guard url.isFileURL, url.pathExtension.lowercased() == "gaoaction" else { throw Failure.invalid }
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.invalid }
        defer { close(descriptor) }
        for component in url.pathComponents.dropFirst() {
            guard !component.isEmpty, component != ".", component != ".." else { throw Failure.invalid }
            let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw Failure.invalid }
            close(descriptor); descriptor = next
        }
        let fd = openat(descriptor, "manifest.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.invalid }; defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1,
              before.st_uid == getuid(), before.st_size > 0, before.st_size <= 1_048_576 else { throw Failure.invalid }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw Failure.invalid }
            if count == 0 { break }
            guard data.count + count <= 1_048_576 else { throw Failure.invalid }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard fstat(fd, &after) == 0, before.st_ino == after.st_ino, before.st_dev == after.st_dev,
              before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.invalid }
        return value["kind"] as? String == "request" && value["action"] as? String == "downloads.prepare"
    }
    enum Failure: Error { case invalid }
}
