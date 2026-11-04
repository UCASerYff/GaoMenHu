import Foundation
import Darwin

@main
struct PortalMailPreferencesTests {
    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw Failure(description: "Expected an existing isolated .noindex container") }
        let container = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        var info = stat()
        guard container.path.hasPrefix("/private/tmp/"), container.lastPathComponent.hasSuffix(".noindex"),
              lstat(container.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw Failure(description: "Fixture container must be a private existing real directory")
        }
        let root = container.appendingPathComponent("preferences-fixtures-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        var checks = 0
        func expect(_ condition: Bool, _ message: String) throws {
            guard condition else { throw Failure(description: message) }
            checks += 1
        }
        func plist(_ value: Any) throws -> Data {
            try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
        }
        func dictionary(_ bytes: Data) throws -> NSDictionary {
            guard let value = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? NSDictionary else {
                throw Failure(description: "Reader returned a non-dictionary")
            }
            return value
        }
        func write(_ name: String, _ bytes: Data) throws -> URL {
            let file = root.appendingPathComponent(name)
            try bytes.write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return file
        }
        func rejects(_ file: URL, domain: [String: Any]? = nil, _ message: String) throws {
            var rejected = false
            do { _ = try PortalLegacyPreferences.read(domain: domain, file: file) }
            catch { rejected = true }
            try expect(rejected, message)
        }

        let absent = root.appendingPathComponent("not-created.plist")
        let empty = try dictionary(PortalLegacyPreferences.read(domain: nil, file: absent))
        try expect(empty.count == 0, "A genuinely absent domain and file must allow an empty preference dictionary")
        try expect(!FileManager.default.fileExists(atPath: absent.path), "Reading absent preferences must not create a file")

        let disk: [String: Any] = ["gaoyoujian.appearance": "dark", "fixtureBoolean": true, "fixtureBlob": Data([1, 2, 3])]
        let diskFile = try write("on-disk.plist", plist(disk))
        let preserved = try dictionary(PortalLegacyPreferences.read(domain: nil, file: diskFile))
        try expect(preserved.isEqual(to: disk), "A nil cached domain must preserve verified on-disk fields")

        let cached: [String: Any] = ["gaoyoujian.appearance": "light", "notFlushedYet": "fixture"]
        let notFlushed = try dictionary(PortalLegacyPreferences.read(domain: cached, file: absent))
        try expect(notFlushed.isEqual(to: cached), "A cached domain not yet written to disk must be retained")
        let newest = try dictionary(PortalLegacyPreferences.read(domain: cached, file: diskFile))
        try expect(newest.isEqual(to: cached), "A nonempty cached domain must retain its current values after disk verification")
        try rejects(diskFile, domain: [:], "A nonempty disk dictionary must not be hidden by an empty cached domain")

        let emptyDictionary = try write("valid-empty.plist", plist([String: String]()))
        let verifiedEmpty = try dictionary(PortalLegacyPreferences.read(domain: nil, file: emptyDictionary))
        try expect(verifiedEmpty.count == 0, "A verified empty plist dictionary is readable")
        let malformed = try write("broken.plist", Data("not a property list".utf8))
        try rejects(malformed, "Malformed plist data must not become an empty dictionary")
        try rejects(malformed, domain: cached, "A valid cached domain must not bypass a corrupt existing plist")
        let array = try write("array.plist", plist(["unexpected", "array"]))
        try rejects(array, "A plist array must not become an empty preference dictionary")
        let zeroBytes = try write("zero.plist", Data())
        try rejects(zeroBytes, "A zero-byte preference file must not become an empty dictionary")

        let fileLink = root.appendingPathComponent("file-link.plist")
        try FileManager.default.createSymbolicLink(at: fileLink, withDestinationURL: diskFile)
        try rejects(fileLink, "A symbolic-link preference file must be refused")
        let actualDirectory = root.appendingPathComponent("real-parent", isDirectory: true)
        try FileManager.default.createDirectory(at: actualDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let nested = actualDirectory.appendingPathComponent("preferences.plist")
        try plist(disk).write(to: nested)
        let ancestorLink = root.appendingPathComponent("linked-parent", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: ancestorLink, withDestinationURL: actualDirectory)
        try rejects(ancestorLink.appendingPathComponent("preferences.plist"), "A symbolic-link ancestor must be refused")

        let hardLink = root.appendingPathComponent("hard-link.plist")
        guard link(diskFile.path, hardLink.path) == 0 else { throw Failure(description: "Could not create the isolated hard-link fixture") }
        try rejects(hardLink, "A hard-linked preference file must be refused")
        try rejects(diskFile, "The original path of a multiply linked preference file must also be refused")

        let oversized = try write("oversized.plist", Data([0]))
        let handle = try FileHandle(forWritingTo: oversized)
        do { try handle.truncate(atOffset: UInt64(32 * 1024 * 1024 + 1)); try handle.close() }
        catch { try? handle.close(); throw error }
        try rejects(oversized, "A preference file larger than 32 MiB must be refused")
        let oversizedDomain: [String: Any] = ["fixtureBlob": Data(repeating: 0, count: 32 * 1024 * 1024 + 1)]
        try rejects(absent, domain: oversizedDomain, "A cached domain larger than the serialization budget must be refused")
        print("Portal mail preferences: \(checks) isolated checks passed")
    }
}
