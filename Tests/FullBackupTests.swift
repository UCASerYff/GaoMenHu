import Foundation
import CryptoKit
import Darwin
import zlib

@main struct FullBackupTests {
    static func main() throws {
        var passed = 0
        func check(_ name: String, _ assertion: @autoclosure () throws -> Bool) {
            do { guard try assertion() else { fatalError(name) }; passed += 1 }
            catch { fatalError(name + ": " + error.localizedDescription) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gaomenhu-fullbackup-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var library = Library.initial(browsers: ["edge", "chrome"])
        library.sites[0].accounts = [Account(id: "test-account", label: "Fixture", username: "fixture-user", loginHosts: ["auth.example.com"], hasPassword: true)]
        library.sites[0].defaultAccount = "test-account"
        library.sites[0].icon = "data:image/png;base64,AA=="
        library.layoutDensity = "compact"; library.iconSize = 60
        library.workspaces = [Workspace(id: "fixture-scene", name: "Fixture", siteIDs: [library.sites[0].id])]
        let snapshot = FullBackup.Snapshot(metadata: LibrarySnapshot(id: UUID().uuidString, createdAt: 1_700_000_000,
                                                                    reason: "测试快照", siteCount: library.sites.count, folderCount: 0), library: library)
        let destination = root.appendingPathComponent(FullBackup.defaultFilename)
        let result = try FullBackup.export(library: library, snapshots: [snapshot], version: "1.05", destination: destination)
        let decoded = try FullBackup.read(destination, currentVersion: "1.05")
        check("round trip library, account metadata, icon, workspace and appearance", decoded.library == library)
        check("round trip complete snapshot", decoded.snapshots == [snapshot])
        check("manifest identity and version", decoded.manifest.appID == FullBackup.appID && decoded.manifest.format == 1 && decoded.manifest.version == "1.05")
        check("summary includes library manifest snapshot", result.fileCount == 3 && result.snapshotCount == 1 && result.zipBytes > 0)
        check("export permissions restrict backup to owner", (try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip"); process.arguments = ["-tqq", destination.path]
        try process.run(); process.waitUntilExit()
        check("export is a valid interoperable ZIP", process.terminationStatus == 0)

        var files = ["library.json": try encoder.encode(library), "Snapshots/" + snapshot.metadata.id + ".json": try encoder.encode(snapshot)]
        func manifest(_ payload: [String: Data]) throws -> Data {
            try encoder.encode(FullBackup.Manifest(appID: FullBackup.appID, format: 1, version: "1.05", createdAt: 1_700_000_000,
                                                 files: payload.mapValues { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }))
        }
        files["manifest.json"] = try manifest(files)
        func readEntries(_ entries: [FixtureEntry]) throws -> FullBackup.Payload {
            let url = root.appendingPathComponent("crafted.zip")
            try storedZIP(entries).write(to: url)
            return try FullBackup.read(url, currentVersion: "1.05")
        }
        func entries(_ values: [String: Data]) -> [FixtureEntry] { values.keys.sorted().map { FixtureEntry(path: $0, data: values[$0]!) } }
        func rejects(_ name: String, _ body: () throws -> Void) {
            do { try body(); fatalError(name) } catch { passed += 1 }
        }
        check("independent stored ZIP accepted", try readEntries(entries(files)).library == library)
        var missing = files; missing.removeValue(forKey: "manifest.json")
        rejects("missing manifest rejected") { _ = try readEntries(entries(missing)) }
        missing = files; missing.removeValue(forKey: "library.json")
        rejects("missing library rejected") { _ = try readEntries(entries(missing)) }
        var modified = files; modified["library.json"]!.append(0x20)
        rejects("valid JSON with wrong SHA256 rejected") { _ = try readEntries(entries(modified)) }
        var m = try JSONDecoder().decode(FullBackup.Manifest.self, from: files["manifest.json"]!)
        m.appID = "com.example.other-app"; modified = files; modified["manifest.json"] = try encoder.encode(m)
        rejects("wrong app identity rejected") { _ = try readEntries(entries(modified)) }
        m.appID = FullBackup.appID; m.format = 99; modified["manifest.json"] = try encoder.encode(m)
        rejects("future archive format rejected") { _ = try readEntries(entries(modified)) }
        m.format = 1; m.version = "1.06"; modified["manifest.json"] = try encoder.encode(m)
        rejects("future app version rejected") { _ = try readEntries(entries(modified)) }
        m.version = "garbage"; modified["manifest.json"] = try encoder.encode(m)
        rejects("malformed version rejected") { _ = try readEntries(entries(modified)) }
        m.version = "1.04"; modified["manifest.json"] = try encoder.encode(m)
        check("older compatible version accepted", try readEntries(entries(modified)).library == library)
        var badLibrary = library; badLibrary.schema = 2
        modified = files; modified.removeValue(forKey: "manifest.json"); modified["library.json"] = try encoder.encode(badLibrary); modified["manifest.json"] = try manifest(modified)
        rejects("valid hashes cannot authorize unsupported library schema") { _ = try readEntries(entries(modified)) }
        badLibrary = library; badLibrary.sites[0].allowedBrowsers = []
        modified = files; modified.removeValue(forKey: "manifest.json"); modified["library.json"] = try encoder.encode(badLibrary); modified["manifest.json"] = try manifest(modified)
        rejects("invalid browser configuration rejected") { _ = try readEntries(entries(modified)) }
        var badSnapshot = snapshot
        badSnapshot.metadata = LibrarySnapshot(id: snapshot.metadata.id, createdAt: snapshot.metadata.createdAt, reason: "Fixture", siteCount: 999, folderCount: 0)
        modified = files; modified.removeValue(forKey: "manifest.json"); modified["Snapshots/" + snapshot.metadata.id + ".json"] = try encoder.encode(badSnapshot); modified["manifest.json"] = try manifest(modified)
        rejects("snapshot metadata validated") { _ = try readEntries(entries(modified)) }
        modified = files; modified.removeValue(forKey: "manifest.json"); modified["Snapshots/" + UUID().uuidString + ".json"] = modified.removeValue(forKey: "Snapshots/" + snapshot.metadata.id + ".json"); modified["manifest.json"] = try manifest(modified)
        rejects("snapshot filename must match metadata id") { _ = try readEntries(entries(modified)) }
        for path in ["../library.json", "/library.json", "Snapshots/../../library.json", "Snapshots\\escape.json", "bridge.sock", "credentials.json", "__MACOSX/library.json", "Snapshots/"] {
            rejects("reject path: " + path) { _ = try readEntries(entries(files) + [FixtureEntry(path: path, data: Data("private-placeholder".utf8))]) }
        }
        rejects("duplicate ZIP name rejected") { _ = try readEntries(entries(files) + [FixtureEntry(path: "library.json", data: files["library.json"]!)]) }
        rejects("case insensitive snapshot duplicate rejected") {
            _ = try readEntries(entries(files) + [FixtureEntry(path: "Snapshots/" + snapshot.metadata.id.lowercased() + ".json", data: files["Snapshots/" + snapshot.metadata.id + ".json"]!)])
        }
        var custom = entries(files); custom[0].mode = 0o120777
        rejects("symbolic link rejected before content decoding") { _ = try readEntries(custom) }
        custom = entries(files); custom[0].flags = 1
        rejects("encrypted ZIP rejected") { _ = try readEntries(custom) }
        custom = entries(files); custom[0].flags = 8
        rejects("data descriptors rejected") { _ = try readEntries(custom) }
        custom = entries(files); custom[0].expanded = UInt32(FullBackup.maximumFileBytes + 1)
        rejects("declared expansion cap enforced before allocation") { _ = try readEntries(custom) }
        custom = entries(files); custom[0].centralName = "manifest.json"
        rejects("central and local name mismatch rejected") { _ = try readEntries(custom) }
        custom = entries(files); custom[0].crc = 123
        rejects("CRC32 mismatch rejected") { _ = try readEntries(custom) }
        let archive = try Data(contentsOf: destination)
        let damaged = root.appendingPathComponent("damaged.zip")
        try archive.dropLast(1).write(to: damaged)
        rejects("truncated ZIP rejected") { _ = try FullBackup.read(damaged, currentVersion: "1.05") }
        var appended = archive; appended.append(Data("trailing garbage".utf8)); try appended.write(to: damaged)
        rejects("trailing hidden payload rejected") { _ = try FullBackup.read(damaged, currentVersion: "1.05") }
        var bomb = archive
        // Lie about the first deflated entry in both local and central headers.
        // The bounded inflater must reject extra output even with a tiny advertised size.
        let centralStart = Int(read32(bomb, bomb.count - 6))
        put32(&bomb, 22, 1); put32(&bomb, centralStart + 24, 1); try bomb.write(to: damaged)
        rejects("lying deflate expansion size rejected") { _ = try FullBackup.read(damaged, currentVersion: "1.05") }
        var illegalOffset = archive; put32(&illegalOffset, centralStart + 42, UInt32.max); try illegalOffset.write(to: damaged)
        rejects("out of range local offset rejected without a crash") { _ = try FullBackup.read(damaged, currentVersion: "1.05") }
        var hiddenPrefix = Data([0]); hiddenPrefix.append(archive); try hiddenPrefix.write(to: damaged)
        rejects("hidden prefix rejected") { _ = try FullBackup.read(damaged, currentVersion: "1.05") }

        // Only allowlisted JSON snapshots are exported; unrelated local files stay local.
        let snapshots = root.appendingPathComponent("Snapshots")
        try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
        let snapshotURL = snapshots.appendingPathComponent(snapshot.metadata.id + ".json")
        try encoder.encode(snapshot).write(to: snapshotURL)
        try Data("not-exportable".utf8).write(to: snapshots.appendingPathComponent("credentials.json"))
        try Data("not-exportable".utf8).write(to: snapshots.appendingPathComponent("bridge.sock"))
        let fromDirectory = root.appendingPathComponent("directory.zip")
        _ = try FullBackup.export(library: library, snapshotDirectory: snapshots, version: "1.05", destination: fromDirectory)
        let directoryPayload = try FullBackup.read(fromDirectory, currentVersion: "1.05")
        check("snapshot whitelist excludes unrelated files", directoryPayload.manifest.files.count == 2 && directoryPayload.snapshots == [snapshot])
        let linkedDirectory = root.appendingPathComponent("snapshot-directory-link")
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: snapshots)
        rejects("snapshot directory symlink rejected") { _ = try FullBackup.export(library: library, snapshotDirectory: linkedDirectory, version: "1.05", destination: fromDirectory) }
        rejects("non-file snapshot URL rejected") { _ = try FullBackup.export(library: library, snapshotDirectory: URL(string: "https://example.com/Snapshots")!, version: "1.05", destination: fromDirectory) }
        rejects("duplicate snapshot IDs rejected on export") { _ = try FullBackup.export(library: library, snapshots: [snapshot, snapshot], version: "1.05", destination: fromDirectory) }
        let linkedInput = root.appendingPathComponent("input-link.zip")
        try FileManager.default.createSymbolicLink(at: linkedInput, withDestinationURL: destination)
        rejects("archive symlink rejected") { _ = try FullBackup.read(linkedInput, currentVersion: "1.05") }
        try FileManager.default.removeItem(at: snapshotURL)
        try FileManager.default.createSymbolicLink(at: snapshotURL, withDestinationURL: destination)
        rejects("snapshot symlink rejected") { _ = try FullBackup.export(library: library, snapshotDirectory: snapshots, version: "1.05", destination: fromDirectory) }
        check("snapshot failure retains old backup", try FullBackup.read(fromDirectory, currentVersion: "1.05").library == library)
        rejects("invalid source cannot overwrite valid backup") { _ = try FullBackup.export(library: badLibrary, snapshots: [], version: "1.05", destination: destination) }
        check("failed export retains previous exact ZIP bytes", try Data(contentsOf: destination) == archive)
        let target = root.appendingPathComponent("private-target"); let marker = Data("keep-original".utf8)
        try marker.write(to: target)
        let outputLink = root.appendingPathComponent("output-link.zip")
        try FileManager.default.createSymbolicLink(at: outputLink, withDestinationURL: target)
        rejects("export rejects destination symlink") { _ = try FullBackup.export(library: library, snapshots: [], version: "1.05", destination: outputLink) }
        check("symlink target stays unchanged", try Data(contentsOf: target) == marker)
        _ = try FullBackup.export(library: .empty(), snapshots: [], version: "1.05", destination: destination)
        check("successful atomic replacement updates existing backup", try FullBackup.read(destination, currentVersion: "1.05").library == .empty())
        check("no abandoned staged archives", try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".gaomenhu-backup-") })
        print("Full backup tests passed: \(passed)")
    }

    /// Independent stored-ZIP fixture writer permits hostile records the exporter
    /// deliberately cannot create. It does not share production ZIP serialization.
    struct FixtureEntry {
        var path: String
        var data: Data
        var mode: UInt32 = 0o100600
        var flags: UInt16 = 0
        var expanded: UInt32? = nil
        var centralName: String? = nil
        var crc: UInt32? = nil
    }
    static func storedZIP(_ entries: [FixtureEntry]) -> Data {
        var result = Data(), central = Data()
        for entry in entries {
            let name = Data(entry.path.utf8), centralName = Data((entry.centralName ?? entry.path).utf8)
            let crc = entry.crc ?? entry.data.withUnsafeBytes { UInt32(crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count))) }
            let offset = UInt32(result.count), expanded = entry.expanded ?? UInt32(entry.data.count)
            var record = Data(); append32(&record, 0x04034b50); append16(&record, 20); append16(&record, entry.flags)
            append16(&record, 0); append16(&record, 0); append16(&record, 0x21); append32(&record, crc)
            append32(&record, UInt32(entry.data.count)); append32(&record, expanded); append16(&record, UInt16(name.count)); append16(&record, 0)
            record.append(name); record.append(entry.data); result.append(record)
            append32(&central, 0x02014b50); append16(&central, 0x314); append16(&central, 20); append16(&central, entry.flags)
            append16(&central, 0); append16(&central, 0); append16(&central, 0x21); append32(&central, crc)
            append32(&central, UInt32(entry.data.count)); append32(&central, expanded); append16(&central, UInt16(centralName.count))
            append16(&central, 0); append16(&central, 0); append16(&central, 0); append16(&central, 0)
            append32(&central, entry.mode << 16); append32(&central, offset); central.append(centralName)
        }
        let start = UInt32(result.count)
        result.append(central); append32(&result, 0x06054b50); append16(&result, 0); append16(&result, 0)
        append16(&result, UInt16(entries.count)); append16(&result, UInt16(entries.count)); append32(&result, UInt32(central.count)); append32(&result, start); append16(&result, 0)
        return result
    }
    static func append16(_ data: inout Data, _ value: UInt16) { data.append(UInt8(truncatingIfNeeded: value)); data.append(UInt8(truncatingIfNeeded: value >> 8)) }
    static func append32(_ data: inout Data, _ value: UInt32) { append16(&data, UInt16(truncatingIfNeeded: value)); append16(&data, UInt16(truncatingIfNeeded: value >> 16)) }
    static func put32(_ data: inout Data, _ offset: Int, _ value: UInt32) { var bytes = Data(); append32(&bytes, value); data.replaceSubrange(offset..<offset + 4, with: bytes) }
    static func read32(_ data: Data, _ offset: Int) -> UInt32 { (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[offset + $1]) << ($1 * 8) } }
}
