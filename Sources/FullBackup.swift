import Foundation
import CryptoKit
import Darwin
import zlib

/// A portable, explicitly allowlisted archive. It never walks Application Support
/// or extracts archive paths onto the filesystem; Keychain and browser data stay local.
enum FullBackup {
    static let defaultFilename = "搞门户-完整资料.zip"
    static let appID = "cn.mendao.launcher"
    static let maximumFileBytes = 30_000_000
    static let maximumTotalBytes = 330_000_000
    static let maximumArchiveBytes = maximumTotalBytes + 1_000_000
    static let maximumSnapshots = 10

    struct Manifest: Codable, Equatable {
        var appID: String
        var format: Int
        var version: String
        var createdAt: Double
        var files: [String: String]
    }
    struct Snapshot: Codable, Equatable {
        var metadata: LibrarySnapshot
        var library: Library
    }
    struct Payload {
        let manifest: Manifest
        let library: Library
        let snapshots: [Snapshot]
    }
    struct Summary {
        let fileCount: Int
        let totalBytes: Int64
        let zipBytes: Int64
        let snapshotCount: Int
    }

    @discardableResult
    static func export(library: Library, snapshotDirectory: URL? = nil,
                       version: String, destination: URL) throws -> Summary {
        var snapshots: [Snapshot] = []
        if let directory = snapshotDirectory {
            let manager = FileManager.default
            // Inspect just this directory. Unknown files, sockets and sidecars are
            // never copied, and symlinks are never followed.
            guard directory.isFileURL else { throw failure("快照目录无效。") }
            var info = stat()
            if lstat(directory.path, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFDIR else { throw failure("快照目录无效。") }
                for url in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                    guard url.pathExtension == "json", UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil else { continue }
                    guard snapshots.count < maximumSnapshots else { throw failure("快照数量超过 10 份，请先检查快照目录。") }
                    let snapshot = try JSONDecoder().decode(Snapshot.self, from: boundedRead(url, limit: maximumFileBytes))
                    try validate(snapshot, filename: url.lastPathComponent)
                    snapshots.append(snapshot)
                }
            } else if errno != ENOENT { throw failure("无法读取快照目录。") }
        }
        return try export(library: library, snapshots: snapshots, version: version, destination: destination)
    }

    @discardableResult
    static func export(library: Library, snapshots: [Snapshot], version: String,
                       destination: URL) throws -> Summary {
        guard validVersion(version), destination.isFileURL, snapshots.count <= maximumSnapshots else { throw failure("备份参数无效。") }
        _ = try library.validated()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var files = ["library.json": try encoder.encode(library)]
        var snapshotIDs: Set<String> = []
        for snapshot in snapshots {
            try validate(snapshot, filename: snapshot.metadata.id + ".json")
            guard snapshotIDs.insert(snapshot.metadata.id.lowercased()).inserted else { throw failure("快照编号重复。") }
            files["Snapshots/" + snapshot.metadata.id + ".json"] = try encoder.encode(snapshot)
        }
        try validateSizes(files)
        let manifest = Manifest(appID: appID, format: 1, version: version,
                                createdAt: Date().timeIntervalSince1970, files: files.mapValues(digest))
        files["manifest.json"] = try encoder.encode(manifest)
        let archive = try makeZIP(files)
        // Verify the exact bytes before touching an existing destination.
        _ = try decode(archive, currentVersion: version)
        try writeAtomically(archive, to: destination)
        return Summary(fileCount: files.count, totalBytes: Int64(files.values.reduce(0) { $0 + $1.count }),
                       zipBytes: Int64(archive.count), snapshotCount: snapshots.count)
    }

    static func read(_ archive: URL, currentVersion: String) throws -> Payload {
        try decode(boundedRead(archive, limit: maximumArchiveBytes), currentVersion: currentVersion)
    }

    private static func decode(_ archive: Data, currentVersion: String) throws -> Payload {
        guard validVersion(currentVersion) else { throw failure("当前应用版本无效。") }
        let files = try readZIP(archive)
        guard let manifestData = files["manifest.json"], manifestData.count <= 100_000,
              let libraryData = files["library.json"] else { throw failure("备份缺少清单或网站资料。") }
        let decoder = JSONDecoder()
        let manifest = try decoder.decode(Manifest.self, from: manifestData)
        guard manifest.appID == appID, manifest.format == 1,
              validVersion(manifest.version), manifest.version.compare(currentVersion, options: .numeric) != .orderedDescending,
              manifest.createdAt.isFinite, manifest.createdAt > 0 else { throw failure("这不是兼容的搞门户完整资料备份；请确认应用和版本。") }
        let payloadFiles = files.filter { $0.key != "manifest.json" }
        guard manifest.files.count == payloadFiles.count, !manifest.files.isEmpty,
              manifest.files.allSatisfy({ path, hash in
                  hash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil && payloadFiles[path].map(digest) == hash
              }) else { throw failure("备份文件校验失败，资料可能不完整或已被修改。") }
        let library = try decoder.decode(Library.self, from: libraryData).validated()
        var snapshots: [Snapshot] = []
        for (path, data) in payloadFiles where path.hasPrefix("Snapshots/") {
            let snapshot = try decoder.decode(Snapshot.self, from: data)
            try validate(snapshot, filename: String(path.dropFirst("Snapshots/".count)))
            snapshots.append(snapshot)
        }
        snapshots.sort { $0.metadata.createdAt > $1.metadata.createdAt }
        return Payload(manifest: manifest, library: library, snapshots: snapshots)
    }

    private static func validate(_ snapshot: Snapshot, filename: String) throws {
        _ = try snapshot.library.validated()
        let metadata = snapshot.metadata
        guard UUID(uuidString: metadata.id) != nil, filename == metadata.id + ".json",
              metadata.createdAt.isFinite, metadata.createdAt > 0,
              metadata.reason.count <= 100, metadata.siteCount == snapshot.library.sites.count,
              metadata.folderCount == snapshot.library.tiles.filter({ $0.kind == "folder" }).count else {
            throw failure("快照格式或编号无效。")
        }
    }

    private static func validVersion(_ value: String) -> Bool {
        value.range(of: "^[1-9][0-9]{0,3}\\.[0-9]{2}$", options: .regularExpression) != nil
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func failure(_ text: String = "完整资料 ZIP 格式无效或已损坏。") -> AppError { .message(text) }
    private static func allowedPath(_ path: String) -> Bool {
        if path == "manifest.json" || path == "library.json" { return true }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "Snapshots", parts[1].hasSuffix(".json") else { return false }
        let id = String(parts[1].dropLast(5))
        return id.count == 36 && UUID(uuidString: id) != nil
    }
    private static func validateSizes(_ files: [String: Data]) throws {
        guard files.count <= maximumSnapshots + 2,
              files.allSatisfy({ allowedPath($0.key) && $0.value.count <= ($0.key == "manifest.json" ? 100_000 : maximumFileBytes) }),
              files.values.reduce(0, { $0 + $1.count }) <= maximumTotalBytes else {
            throw failure("备份资料过大：单个文件最多 30 MB，总计最多 330 MB。")
        }
    }

    private static func boundedRead(_ url: URL, limit: Int) throws -> Data {
        guard url.isFileURL else { throw failure("请选择本地备份文件。") }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw failure("无法读取备份文件，或文件是符号链接。") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0, info.st_size <= limit else { throw failure("备份文件不是普通文件或超过大小限制。") }
        var data = Data()
        while let chunk = try handle.read(upToCount: min(1_048_576, limit - data.count + 1)), !chunk.isEmpty {
            guard chunk.count <= limit - data.count else { throw failure("备份文件超过大小限制。") }
            data.append(chunk)
        }
        return data
    }

    private static func writeAtomically(_ data: Data, to destination: URL) throws {
        let manager = FileManager.default
        if let attributes = try? manager.attributesOfItem(atPath: destination.path) {
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw failure("请选择普通 ZIP 文件作为保存位置。") }
        }
        let sibling = destination.deletingLastPathComponent().appendingPathComponent(".gaomenhu-backup-" + UUID().uuidString + ".zip")
        defer { try? manager.removeItem(at: sibling) }
        let descriptor = open(sibling.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw failure("无法写入所选备份位置。") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do { try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        guard digest(try boundedRead(sibling, limit: maximumArchiveBytes)) == digest(data) else { throw failure("写入后的备份校验失败，原备份未替换。") }
        guard rename(sibling.path, destination.path) == 0 else { throw failure("无法替换所选备份，原备份已保留。") }
    }

    // Standard ZIP32 with raw DEFLATE. Parsing both central and local records
    // ourselves bounds all allocations and avoids filesystem extraction entirely.
    private struct ZIPEntry {
        let path: String
        let crc: UInt32
        let compressed: Int
        let expanded: Int
        let method: UInt16
        let flags: UInt16
        let offset: Int
    }
    private static func checksum(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { UInt32(crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(data.count))) }
    }
    private static func deflated(_ data: Data) throws -> Data {
        var stream = z_stream()
        guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -MAX_WBITS, 8, Z_DEFAULT_STRATEGY,
                            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw failure() }
        defer { deflateEnd(&stream) }
        var output = Data(count: Int(deflateBound(&stream, uLong(data.count))))
        let code: Int32 = data.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { buffer in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(input.count)
                stream.next_out = buffer.bindMemory(to: Bytef.self).baseAddress; stream.avail_out = uInt(buffer.count)
                return deflate(&stream, Z_FINISH)
            }
        }
        guard code == Z_STREAM_END, stream.total_in == data.count else { throw failure() }
        output.count = Int(stream.total_out); return output
    }
    private static func inflated(_ data: Data, expected: Int) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw failure() }
        defer { inflateEnd(&stream) }
        // One spare byte detects a lying expanded size without unbounded output.
        var output = Data(count: expected + 1)
        let code: Int32 = data.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { buffer in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(input.count)
                stream.next_out = buffer.bindMemory(to: Bytef.self).baseAddress; stream.avail_out = uInt(buffer.count)
                return inflate(&stream, Z_FINISH)
            }
        }
        guard code == Z_STREAM_END, stream.total_out == expected, stream.total_in == data.count else { throw failure("ZIP 解压长度不符，已停止恢复。") }
        output.count = expected; return output
    }

    private static func makeZIP(_ files: [String: Data]) throws -> Data {
        var archive = Data(), central = Data()
        for path in files.keys.sorted() {
            let original = files[path]!, compressed = try deflated(original), name = Data(path.utf8)
            let crc = checksum(original), offset = archive.count
            archive.le32(0x04034b50); archive.le16(20); archive.le16(0x800); archive.le16(8)
            archive.le16(0); archive.le16(0x21); archive.le32(crc)
            archive.le32(UInt32(compressed.count)); archive.le32(UInt32(original.count)); archive.le16(UInt16(name.count)); archive.le16(0)
            archive.append(name); archive.append(compressed)
            central.le32(0x02014b50); central.le16(0x314); central.le16(20); central.le16(0x800); central.le16(8)
            central.le16(0); central.le16(0x21); central.le32(crc); central.le32(UInt32(compressed.count)); central.le32(UInt32(original.count))
            central.le16(UInt16(name.count)); central.le16(0); central.le16(0); central.le16(0); central.le16(0)
            central.le32(UInt32(0o100600) << 16); central.le32(UInt32(offset)); central.append(name)
        }
        let centralOffset = archive.count
        archive.append(central); archive.le32(0x06054b50); archive.le16(0); archive.le16(0)
        archive.le16(UInt16(files.count)); archive.le16(UInt16(files.count)); archive.le32(UInt32(central.count)); archive.le32(UInt32(centralOffset)); archive.le16(0)
        guard archive.count <= maximumArchiveBytes else { throw failure("ZIP 文件超过大小限制。") }
        return archive
    }

    private static func readZIP(_ data: Data) throws -> [String: Data] {
        guard data.count >= 22, data.count <= maximumArchiveBytes else { throw failure() }
        // This format has no trailing comments, ZIP64, split volumes or data descriptors.
        let end = data.count - 22
        guard try data.u32(end) == 0x06054b50, try data.u16(end + 4) == 0, try data.u16(end + 6) == 0,
              try data.u16(end + 20) == 0 else { throw failure() }
        let count = Int(try data.u16(end + 10)), centralSize = Int(try data.u32(end + 12)), start = Int(try data.u32(end + 16))
        guard count >= 2, count <= maximumSnapshots + 2, try data.u16(end + 8) == count,
              start <= end, centralSize == end - start else { throw failure() }
        var cursor = start, entries: [ZIPEntry] = [], paths: Set<String> = [], total = 0
        for _ in 0..<count {
            guard cursor <= end - 46, try data.u32(cursor) == 0x02014b50 else { throw failure() }
            let flags = try data.u16(cursor + 8), method = try data.u16(cursor + 10)
            let compressed = Int(try data.u32(cursor + 20)), expanded = Int(try data.u32(cursor + 24))
            let nameLength = Int(try data.u16(cursor + 28)), extra = Int(try data.u16(cursor + 30)), comment = Int(try data.u16(cursor + 32))
            let attributes = try data.u32(cursor + 38), kind = (attributes >> 16) & 0xf000
            let next = cursor + 46 + nameLength + extra + comment
            guard next <= end, nameLength > 0, nameLength <= 100,
                  extra == 0, comment == 0, try data.u16(cursor + 6) <= 20, try data.u16(cursor + 34) == 0,
                  flags == 0 || flags == 0x800, method == 0 || method == 8,
                  kind == 0 || kind == 0x8000, attributes & 0x10 == 0,
                  compressed <= maximumArchiveBytes, expanded <= maximumFileBytes,
                  let path = String(data: data.subdata(in: cursor + 46..<cursor + 46 + nameLength), encoding: .utf8),
                  allowedPath(path), paths.insert(path.lowercased()).inserted else { throw failure("ZIP 包含不支持的路径、重复条目或文件类型。") }
            guard path != "manifest.json" || expanded <= 100_000 else { throw failure() }
            total += expanded
            guard total <= maximumTotalBytes else { throw failure("ZIP 展开后的资料超过大小限制。") }
            entries.append(ZIPEntry(path: path, crc: try data.u32(cursor + 16), compressed: compressed,
                                    expanded: expanded, method: method, flags: flags, offset: Int(try data.u32(cursor + 42))))
            cursor = next
        }
        guard cursor == end else { throw failure() }
        var files: [String: Data] = [:], localEnd = 0
        for entry in entries.sorted(by: { $0.offset < $1.offset }) {
            let offset = entry.offset
            guard offset == localEnd, offset <= start - 30, try data.u32(offset) == 0x04034b50,
                  try data.u16(offset + 4) <= 20, try data.u16(offset + 6) == entry.flags, try data.u16(offset + 8) == entry.method,
                  try data.u32(offset + 14) == entry.crc, try data.u32(offset + 18) == entry.compressed, try data.u32(offset + 22) == entry.expanded else { throw failure() }
            let nameLength = Int(try data.u16(offset + 26)), extra = Int(try data.u16(offset + 28))
            let payloadStart = offset + 30 + nameLength + extra
            localEnd = payloadStart + entry.compressed
            guard extra == 0, nameLength == entry.path.utf8.count, localEnd <= start,
                  data.subdata(in: offset + 30..<offset + 30 + nameLength) == Data(entry.path.utf8) else { throw failure() }
            let compressed = data.subdata(in: payloadStart..<localEnd)
            let content = entry.method == 0 ? compressed : try inflated(compressed, expected: entry.expanded)
            guard content.count == entry.expanded, checksum(content) == entry.crc else { throw failure("ZIP 文件校验失败。") }
            files[entry.path] = content
        }
        guard localEnd == start else { throw failure() }
        return files
    }
}

private extension Data {
    mutating func le16(_ value: UInt16) { append(UInt8(truncatingIfNeeded: value)); append(UInt8(truncatingIfNeeded: value >> 8)) }
    mutating func le32(_ value: UInt32) { le16(UInt16(truncatingIfNeeded: value)); le16(UInt16(truncatingIfNeeded: value >> 16)) }
    func u16(_ offset: Int) throws -> UInt16 {
        guard offset >= 0, offset <= count - 2 else { throw AppError.message("ZIP 数据不完整。") }
        return UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }
    func u32(_ offset: Int) throws -> UInt32 { UInt32(try u16(offset)) | UInt32(try u16(offset + 2)) << 16 }
}
