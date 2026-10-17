import Foundation
import Darwin
import CryptoKit

@main struct LibraryInitializationTests {
    enum Stop: Error { case interrupted }
    static func main() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mendao-library-initialization-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        var suites: [String] = []
        defer {
            LibraryInitializationTesting.boundary = nil
            for name in suites {
                if let prefs = UserDefaults(suiteName: name) { prefs.removePersistentDomain(forName: name); _ = prefs.synchronize() }
            }
            try? fm.removeItem(at: root)
        }
        var checks = 0
        func check(_ name: String, _ value: @autoclosure () throws -> Bool) {
            do { guard try value() else { fatalError(name) }; checks += 1 }
            catch { fatalError(name + ": " + error.localizedDescription) }
        }
        func fails(_ name: String, _ block: () throws -> Void) {
            do { try block(); fatalError(name) } catch { checks += 1 }
        }
        func preferences() -> UserDefaults {
            let name = "cn.mendao.fixture.library-init." + UUID().uuidString
            suites.append(name)
            let prefs = UserDefaults(suiteName: name)!; prefs.removePersistentDomain(forName: name)
            return prefs
        }
        func phase(_ prefs: UserDefaults) -> String? {
            guard let data = prefs.data(forKey: LibraryStore.initializationKey),
                  let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return value["phase"] as? String
        }
        func evidence(_ prefs: UserDefaults, format: Int = 1, phase: String = "ready") throws {
            prefs.set(try JSONSerialization.data(withJSONObject: ["format": format, "phase": phase]), forKey: LibraryStore.initializationKey)
            _ = prefs.synchronize()
        }
        func store(_ name: String, _ prefs: UserDefaults) -> LibraryStore {
            LibraryStore(directory: root.appendingPathComponent(name), preferences: prefs)
        }
        func encoded(_ library: Library) throws -> Data {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(library)
        }
        func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        func hashes(_ directory: URL) throws -> [String: String] {
            guard fm.fileExists(atPath: directory.path) else { return [:] }
            var result: [String: String] = [:]
            let entries = fm.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])!
            while let url = entries.nextObject() as? URL {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if values.isSymbolicLink == true { result[String(url.path.dropFirst(directory.path.count + 1))] = "symlink:" + (try fm.destinationOfSymbolicLink(atPath: url.path)); entries.skipDescendants() }
                else if values.isRegularFile == true { result[String(url.path.dropFirst(directory.path.count + 1))] = digest(try Data(contentsOf: url)) }
            }
            return result
        }
        func legacy(_ name: String, prefs: UserDefaults, library: Library) throws -> LibraryStore {
            let value = store(name, prefs)
            try fm.createDirectory(at: value.directory, withIntermediateDirectories: false)
            try encoded(library).write(to: value.file)
            return value
        }
        let account = Account(id: "fixture-account", label: "Fixture", username: "fixture@example.test", loginHosts: ["auth.example.test"], hasPassword: true)
        let website = Website(id: "fixture-site", name: "Retained site", url: "https://example.test", color: "#123456", allowedBrowsers: ["edge", "chrome"], defaultBrowser: "edge", accounts: [account], defaultAccount: account.id, profiles: ["edge": "fixture-profile"])
        var retained = Library(sites: [website], tiles: [Tile(id: "fixture-folder", kind: "folder", name: "Fixture folder", children: [website.id])])
        retained.workspaces = [Workspace(id: "fixture-workspace", name: "Fixture scene", siteIDs: [website.id])]
        retained.layoutDensity = "comfortable"; retained.iconSize = 92

        let freshPrefs = preferences(), fresh = store("genuine-first-use", freshPrefs)
        check("new store is not writable before classification", !fresh.isWritable)
        let first = try fresh.load(defaultBrowsers: ["edge", "chrome"])
        check("genuine absent path creates six starter sites once", first.sites.count == 6)
        check("first use commits before returning", try JSONDecoder().decode(Library.self, from: Data(contentsOf: fresh.file)) == first)
        check("independent initialization evidence is durable", phase(freshPrefs) == "ready")
        check("successful first use unlocks writes", fresh.isWritable)
        check("first-use file is private", (try fm.attributesOfItem(atPath: fresh.file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let firstHash = try hashes(fresh.directory)
        check("subsequent load is idempotent", try store("genuine-first-use", freshPrefs).load(defaultBrowsers: ["safari"]) == first)
        check("subsequent load preserves every byte", try hashes(fresh.directory) == firstHash)

        let explicitPrefs = preferences(), explicit = store("explicit-first-save", explicitPrefs)
        try explicit.save(retained)
        check("explicit first save never seeds over supplied layout", try explicit.load(defaultBrowsers: []) == retained)
        check("explicit first save establishes independent evidence", phase(explicitPrefs) == "ready")

        let oldPrefs = preferences(), old = try legacy("legacy-valid", prefs: oldPrefs, library: retained)
        try fm.createDirectory(at: old.directory.appendingPathComponent("Snapshots"), withIntermediateDirectories: false)
        try Data("opaque existing snapshot; load must not rewrite".utf8).write(to: old.directory.appendingPathComponent("Snapshots/retained.json"))
        try Data("private attachment fixture".utf8).write(to: old.directory.appendingPathComponent("retained-attachment.bin"))
        let oldHashes = try hashes(old.directory)
        check("legacy valid library migration retains sites folders profiles accounts and scene", try old.load(defaultBrowsers: []) == retained)
        check("legacy migration never rewrites existing files", try hashes(old.directory) == oldHashes)
        check("legacy migration establishes independent ready evidence", phase(oldPrefs) == "ready")
        check("legacy migration is idempotent", try store("legacy-valid", oldPrefs).load(defaultBrowsers: []) == retained)
        check("idempotent migration leaves all digests identical", try hashes(old.directory) == oldHashes)
        let emptyPrefs = preferences(), empty = try legacy("legacy-valid-empty", prefs: emptyPrefs, library: .empty())
        check("a deliberately empty legacy library remains empty", try empty.load(defaultBrowsers: ["edge"]).sites.isEmpty)

        for marker in ["empty-directory", "Snapshots", "Attachments", "Exchange", ".gaomenhu-restore-fixture"] {
            let prefs = preferences(), value = store("existing-" + marker.replacingOccurrences(of: ".", with: "_"), prefs)
            try fm.createDirectory(at: value.directory, withIntermediateDirectories: false)
            if marker != "empty-directory" {
                try fm.createDirectory(at: value.directory.appendingPathComponent(marker), withIntermediateDirectories: false)
                try Data("existing history fixture".utf8).write(to: value.directory.appendingPathComponent(marker + "/retained.bin"))
            }
            let before = try hashes(value.directory)
            fails("existing \(marker) without main library cannot create starter sites") { _ = try value.load(defaultBrowsers: ["chrome"]) }
            check("missing-main classification blocks subsequent save \(marker)", !value.isWritable)
            fails("save cannot bypass missing-main protection \(marker)") { try value.save(.empty()) }
            check("no replacement main library created \(marker)", !fm.fileExists(atPath: value.file.path))
            check("all existing file digests unchanged \(marker)", try hashes(value.directory) == before)
        }
        for key in ["GaoMenHu.Floating.Enabled", "GaoMenHu.WebsiteLaunchHistory", "NSWindow Frame MenDao.Main", "MenDao.LegacySetting"] {
            let prefs = preferences(); prefs.set("fixture", forKey: key)
            let value = store("settings-only-" + UUID().uuidString, prefs)
            fails("historical setting blocks first-use guess \(key)") { _ = try value.load(defaultBrowsers: ["chrome"]) }
            fails("historical setting cannot be bypassed through save \(key)") { try value.save(.empty()) }
            check("settings-only case creates no data directory", !fm.fileExists(atPath: value.directory.path))
            check("historical setting stays untouched", prefs.string(forKey: key) == "fixture")
        }
        for deletion in ["file", "directory"] {
            let prefs = preferences(), value = store("deleted-" + deletion, prefs)
            try value.save(retained)
            try fm.removeItem(at: deletion == "file" ? value.file : value.directory)
            let reopened = store("deleted-" + deletion, prefs)
            fails("independent evidence detects deleted \(deletion)") { _ = try reopened.load(defaultBrowsers: ["chrome"]) }
            fails("deleted \(deletion) never becomes an empty save") { try reopened.save(.empty()) }
            check("deleted \(deletion) never regenerates starter library", !fm.fileExists(atPath: value.file.path))
            check("deleted \(deletion) preserves initialization evidence", phase(prefs) == "ready")
        }
        for malformed in ["corrupt", "future-schema", "unreadable", "directory-instead-file", "symlink", "dangling-symlink", "fifo"] {
            let prefs = preferences(), value = store("bad-" + malformed, prefs)
            try fm.createDirectory(at: value.directory, withIntermediateDirectories: false)
            let outside = root.appendingPathComponent("outside-" + malformed)
            let sentinel = Data("must remain untouched".utf8)
            try sentinel.write(to: outside)
            switch malformed {
            case "corrupt": try Data("{broken".utf8).write(to: value.file)
            case "future-schema": var future = retained; future.schema = 2; try encoded(future).write(to: value.file)
            case "unreadable": try encoded(retained).write(to: value.file); try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: value.file.path)
            case "directory-instead-file": try fm.createDirectory(at: value.file, withIntermediateDirectories: false)
            case "symlink": try fm.createSymbolicLink(at: value.file, withDestinationURL: outside)
            case "dangling-symlink": try fm.createSymbolicLink(at: value.file, withDestinationURL: root.appendingPathComponent("absent"))
            default: check("FIFO fixture created", mkfifo(value.file.path, 0o600) == 0)
            }
            let original = malformed == "unreadable" || malformed == "fifo" ? nil : try hashes(value.directory)
            fails("invalid main library is rejected \(malformed)") { _ = try value.load(defaultBrowsers: ["chrome"]) }
            fails("invalid main library cannot be replaced by save \(malformed)") { try value.save(.empty()) }
            check("invalid main library keeps store blocked \(malformed)", !value.isWritable)
            if let original { check("invalid main library digests unchanged \(malformed)", try hashes(value.directory) == original) }
            if malformed == "unreadable" {
                check("unreadable library permissions unchanged", (try fm.attributesOfItem(atPath: value.file.path)[.posixPermissions] as? NSNumber)?.intValue == 0)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: value.file.path)
                check("unreadable library bytes unchanged", try Data(contentsOf: value.file) == encoded(retained))
            }
            check("external symlink target bytes unchanged \(malformed)", try Data(contentsOf: outside) == sentinel)
            check("invalid load never claims successful initialization \(malformed)", prefs.object(forKey: LibraryStore.initializationKey) == nil)
        }
        for value in [Data("invalid evidence".utf8), try JSONSerialization.data(withJSONObject: ["format": 2, "phase": "ready"]), try JSONSerialization.data(withJSONObject: ["format": 1, "phase": "unknown"])] {
            let prefs = preferences(), name = "bad-evidence-" + UUID().uuidString
            let disk = try legacy(name, prefs: prefs, library: retained)
            prefs.set(value, forKey: LibraryStore.initializationKey)
            let before = try hashes(disk.directory)
            fails("corrupt or future independent evidence blocks library load") { _ = try disk.load(defaultBrowsers: []) }
            fails("corrupt or future independent evidence blocks save") { try disk.save(.empty()) }
            check("unrecognized evidence is not rewritten", prefs.data(forKey: LibraryStore.initializationKey) == value)
            check("unrecognized evidence retains every library byte", try hashes(disk.directory) == before)
        }
        for boundary in ["initialization.evidence", "initialization.directory", "initialization.staged", "initialization.installed", "initialization.verified"] {
            let prefs = preferences(), name = "interrupt-" + boundary
            let disk = store(name, prefs)
            LibraryInitializationTesting.boundary = { if $0 == boundary { throw Stop.interrupted } }
            fails("first-use interruption is surfaced \(boundary)") { _ = try disk.load(defaultBrowsers: ["edge"]) }
            LibraryInitializationTesting.boundary = nil
            let before = try hashes(disk.directory)
            fails("interrupted first-use instance cannot save \(boundary)") { try disk.save(.empty()) }
            fails("interrupted first use never auto-recovers to starter sites \(boundary)") { _ = try store(name, prefs).load(defaultBrowsers: ["chrome"]) }
            check("interrupted first use retains every existing byte \(boundary)", try hashes(disk.directory) == before)
            check("interrupted first use retains pending independent evidence \(boundary)", phase(prefs) == "initializing")
        }
        for boundary in ["migration.evidence", "migration.verified"] {
            let prefs = preferences(), name = "interrupt-" + boundary
            let disk = try legacy(name, prefs: prefs, library: retained)
            let before = try hashes(disk.directory)
            LibraryInitializationTesting.boundary = { if $0 == boundary { throw Stop.interrupted } }
            fails("legacy migration interruption is surfaced \(boundary)") { _ = try disk.load(defaultBrowsers: []) }
            LibraryInitializationTesting.boundary = nil
            fails("interrupted migration cannot save \(boundary)") { try disk.save(.empty()) }
            fails("interrupted migration is not assumed complete on restart \(boundary)") { _ = try store(name, prefs).load(defaultBrowsers: []) }
            check("interrupted migration retains exact original digests \(boundary)", try hashes(disk.directory) == before)
            check("interrupted migration retains independent pending phase \(boundary)", phase(prefs) == "migrating")
        }
        for boundary in ["write.evidence", "write.staged", "write.replaced", "write.verified"] {
            let prefs = preferences(), name = "interrupt-" + boundary, disk = store(name, prefs)
            try disk.save(retained)
            let attachment = disk.directory.appendingPathComponent("retained-attachment.bin")
            try Data("retained attachment".utf8).write(to: attachment)
            let before = try hashes(disk.directory)
            var changed = retained; changed.sites[0].name = "Changed fixture"
            LibraryInitializationTesting.boundary = { if $0 == boundary { throw Stop.interrupted } }
            fails("write interruption is surfaced \(boundary)") { try disk.save(changed) }
            LibraryInitializationTesting.boundary = nil
            let after = try hashes(disk.directory)
            check("failed write preserves exact library and attachment digests \(boundary)", before.allSatisfy { after[$0.key] == $0.value })
            fails("failed write cannot be followed by empty save \(boundary)") { try disk.save(.empty()) }
            fails("interrupted write blocks automatic restart \(boundary)") { _ = try store(name, prefs).load(defaultBrowsers: ["chrome"]) }
            check("interrupted write retains independent pending phase \(boundary)", phase(prefs) == "writing")
        }
        for boundary in ["staging", "snapshot-swap", "main-commit", "verification"] {
            let prefs = preferences(), name = "restore-pending-" + boundary, disk = store(name, prefs)
            try disk.save(retained)
            let transaction = disk.directory.appendingPathComponent(".gaomenhu-restore-" + UUID().uuidString)
            try fm.createDirectory(at: transaction, withIntermediateDirectories: false)
            try fm.createDirectory(at: transaction.appendingPathComponent("rollback"), withIntermediateDirectories: false)
            try encoded(retained).write(to: transaction.appendingPathComponent("rollback/library.json"))
            var incoming = retained; incoming.sites[0].name = "Incoming restore fixture"
            if boundary == "staging" {
                try encoded(incoming).write(to: transaction.appendingPathComponent("staged-library.json"))
            } else {
                try fm.createDirectory(at: disk.directory.appendingPathComponent("Snapshots"), withIntermediateDirectories: false)
                try encoded(retained).write(to: disk.directory.appendingPathComponent("Snapshots/pre-restore-fixture.json"))
            }
            if boundary == "main-commit" || boundary == "verification" { try encoded(incoming).write(to: disk.file) }
            let before = try hashes(disk.directory)
            fails("pending restore blocks even currently loaded writer \(boundary)") { try disk.save(.empty()) }
            fails("pending restore blocks restart \(boundary)") { _ = try store(name, prefs).load(defaultBrowsers: ["chrome"]) }
            check("pending restore bytes remain identical \(boundary)", try hashes(disk.directory) == before)
        }
        for pending in ["initializing", "migrating", "writing"] {
            let prefs = preferences(), disk = try legacy("pending-evidence-" + pending, prefs: prefs, library: retained)
            try evidence(prefs, phase: pending)
            let before = try hashes(disk.directory)
            fails("pending independent evidence blocks a valid main file \(pending)") { _ = try disk.load(defaultBrowsers: []) }
            fails("valid main file cannot bypass pending evidence \(pending)") { try disk.save(.empty()) }
            check("pending independent evidence retains main digest \(pending)", try hashes(disk.directory) == before)
        }
        let adoptPrefs = preferences(), adoptDisk = store("adopt-verified-restore", adoptPrefs)
        try adoptDisk.save(retained)
        var restored = retained; restored.sites[0].name = "Verified restored fixture"
        try encoded(restored).write(to: adoptDisk.file)
        try adoptDisk.adoptCommittedLibrary(restored)
        try adoptDisk.requireWritable()
        check("verified full restore adopts the committed file", try adoptDisk.load(defaultBrowsers: []) == restored)
        var editedRestore = restored; editedRestore.sites[0].name = "Edited after verified restore"
        try adoptDisk.save(editedRestore)
        check("verified restore can continue ordinary saves", try adoptDisk.load(defaultBrowsers: []) == editedRestore)
        let wrongPrefs = preferences(), wrongDisk = store("reject-unverified-adoption", wrongPrefs)
        try wrongDisk.save(retained)
        let wrongBefore = try hashes(wrongDisk.directory)
        fails("unverified restore cannot adopt mismatching content") { try wrongDisk.adoptCommittedLibrary(restored) }
        fails("unverified restore cannot save through blocked instance") { try wrongDisk.save(.empty()) }
        check("unverified restore does not rewrite the main library", try hashes(wrongDisk.directory) == wrongBefore)
        let changedPrefs = preferences(), changedDisk = store("stale-after-load", changedPrefs)
        try changedDisk.save(retained)
        var other = retained; other.sites[0].name = "External change"
        try encoded(other).write(to: changedDisk.file)
        let externalBytes = try Data(contentsOf: changedDisk.file)
        fails("stale in-memory writer refuses external replacement") { try changedDisk.save(.empty()) }
        check("external replacement stays byte-for-byte intact", try Data(contentsOf: changedDisk.file) == externalBytes)
        check("external replacement blocks all later writes", !changedDisk.isWritable)
        let deletedPrefs = preferences(), deletedDisk = store("deleted-after-load", deletedPrefs)
        try deletedDisk.save(retained); try fm.removeItem(at: deletedDisk.file)
        fails("loaded instance detects disappearance before save") { try deletedDisk.save(.empty()) }
        check("loaded instance never recreates missing main", !fm.fileExists(atPath: deletedDisk.file.path))
        let finalPrefs = preferences(), finalDisk = store("successful-save", finalPrefs)
        try finalDisk.save(retained); var finalLibrary = retained; finalLibrary.sites[0].name = "Successful edit"
        try finalDisk.save(finalLibrary)
        check("successful write remains readable", try finalDisk.load(defaultBrowsers: []) == finalLibrary)
        check("successful write returns durable evidence to ready", phase(finalPrefs) == "ready")
        check("successful write removes only its own staging journal", try fm.contentsOfDirectory(atPath: finalDisk.directory.path) == ["library.json"])
        let memory = LibraryStore(directory: root.appendingPathComponent("memory-never-created"), persistent: false)
        _ = try memory.load(defaultBrowsers: ["edge"]); try memory.save(retained)
        check("isolated memory mode never creates directory", !fm.fileExists(atPath: memory.directory.path))
        print("Library initialization tests passed: \(checks)")
    }
}
