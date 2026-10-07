import Foundation
import Darwin

@main struct BackupRestoreTests {
    static func main() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp/gmh-r-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        var checks = 0
        func check(_ name: String, _ condition: Bool) {
            guard condition else { fatalError(name) }; checks += 1
        }
        func fails(_ name: String, _ action: () throws -> Void) {
            do { try action(); fatalError(name) } catch { checks += 1 }
        }
        func site(_ id: String, _ host: String) -> Website {
            Website(id: id, name: id, url: "https://" + host, color: "#123456",
                    allowedBrowsers: ["edge"], defaultBrowser: "edge", accounts: [], profiles: [:])
        }
        func tile(_ id: String) -> Tile { Tile(id: id, kind: "site", name: nil, children: nil) }
        var local = site("local", "local.example")
        local.accounts = [Account(id: "local-account", label: "Current", username: "local@example.test", loginHosts: [], hasPassword: true)]
        local.defaultAccount = "local-account"; local.profiles = ["edge": UUID().uuidString]
        let extra = site("extra", "extra.example")
        let current = Library(sites: [local, extra], tiles: [tile(local.id), tile(extra.id)])
        var importedLocal = local
        importedLocal.name = "Restored title"; importedLocal.accounts[0].username = "stale@example.test"
        importedLocal.accounts[0].hasPassword = false; importedLocal.profiles = ["edge": UUID().uuidString]
        var foreign = site("foreign", "foreign.example")
        foreign.accounts = [Account(id: "foreign-account", label: "Foreign", username: "foreign@example.test", loginHosts: [], hasPassword: true)]
        foreign.defaultAccount = "foreign-account"; foreign.profiles = ["edge": UUID().uuidString]
        var incoming = Library(sites: [importedLocal, foreign], tiles: [Tile(id: "folder", kind: "folder", name: "Restored folder", children: [foreign.id, local.id])])
        incoming.layoutDensity = "comfortable"; incoming.iconSize = 92
        incoming.workspaces = [Workspace(id: "workspace", name: "Restored workspace", siteIDs: [foreign.id, local.id])]
        func snapshot(_ library: Library, id: String = UUID().uuidString, date: Double = Date().timeIntervalSince1970, reason: String = "Imported") -> FullBackup.Snapshot {
            FullBackup.Snapshot(metadata: LibrarySnapshot(id: id, createdAt: date, reason: reason,
                siteCount: library.sites.count, folderCount: library.tiles.filter { $0.kind == "folder" }.count), library: library)
        }
        func payload(_ snapshots: [FullBackup.Snapshot] = [], library: Library? = nil) -> FullBackup.Payload {
            FullBackup.Payload(manifest: FullBackup.Manifest(appID: FullBackup.appID, format: 1, version: "1.05", createdAt: Date().timeIntervalSince1970, files: [:]), library: library ?? incoming, snapshots: snapshots)
        }
        func diskStore(_ label: String) throws -> LibraryStore {
            let store = LibraryStore(directory: root.appendingPathComponent(label))
            try store.save(current)
            _ = try store.checkpoint(current, reason: "Local snapshot")
            return store
        }
        func ownedFiles(_ store: LibraryStore) throws -> [String: Data] {
            var result: [String: Data] = [:]
            if fm.fileExists(atPath: store.file.path) { result["library.json"] = try Data(contentsOf: store.file) }
            let folder = store.directory.appendingPathComponent("Snapshots")
            if fm.fileExists(atPath: folder.path) {
                for file in try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
                    result["Snapshots/" + file.lastPathComponent] = try Data(contentsOf: file)
                }
            }
            return result
        }
        func noIntermediates(_ store: LibraryStore) throws -> Bool {
            try !fm.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: nil).contains { $0.lastPathComponent.hasPrefix(".gaomenhu-restore-") }
        }

        let memory = LibraryStore(directory: root.appendingPathComponent("never-created"), persistent: false)
        let old = snapshot(current, date: Date().timeIntervalSince1970 + 100, reason: "Local ID wins")
        memory.transientSnapshots[old.metadata.id] = try JSONEncoder().encode(old)
        var ten = (0..<10).map { snapshot(incoming, date: Date().timeIntervalSince1970 - Double($0), reason: "Incoming \($0)") }
        ten[0] = snapshot(incoming, id: old.metadata.id, date: Date().timeIntervalSince1970 + 200, reason: "Must not replace local history")
        let restored = try memory.installBackup(payload(ten), current: current)
        check("same-site account fields and password binding stay local", restored.sites.first(where: { $0.id == local.id })?.accounts == local.accounts)
        check("browser profile stays local", restored.sites.first(where: { $0.id == local.id })?.profiles == local.profiles)
        let newSite = restored.sites.first(where: { $0.url == foreign.url })!
        check("foreign account gets a new identity", newSite.accounts[0].id != foreign.accounts[0].id)
        check("foreign password claim is removed", !newSite.accounts[0].hasPassword)
        check("foreign browser profile is removed", newSite.profiles.isEmpty)
        check("omitted local site remains archived", restored.sites.contains(extra) && !restored.tiles.contains { $0.id == extra.id || ($0.children ?? []).contains(extra.id) })
        check("folder ordering is remapped", restored.tiles.first?.children == [newSite.id, local.id])
        check("workspace ordering is remapped", restored.workspaces?.first?.siteIDs == [newSite.id, local.id])
        check("appearance preferences restore", restored.layoutDensity == "comfortable" && restored.iconSize == 92)
        check("memory snapshot count bounded at ten", memory.transientSnapshots.count == 10)
        check("memory restoration never writes to disk", !fm.fileExists(atPath: memory.directory.path))
        let memorySnapshots = try memory.transientSnapshots.values.map { try JSONDecoder().decode(FullBackup.Snapshot.self, from: $0) }
        check("current library always has a safety snapshot", memorySnapshots.contains { $0.metadata.reason == "恢复完整资料前" && $0.library == current })
        check("local ID collision preserves local snapshot", memorySnapshots.contains(old))
        for entry in memorySnapshots where entry.metadata.reason.hasPrefix("Incoming") {
            let foreignSite = entry.library.sites.first(where: { $0.url == foreign.url })!
            check("imported snapshot cannot restore a foreign password", foreignSite.accounts.allSatisfy { !$0.hasPassword } && foreignSite.profiles.isEmpty)
            check("imported snapshot counts reflect local archives", entry.metadata.siteCount == entry.library.sites.count && entry.library.sites.contains(extra))
        }
        let beforeMemory = memory.transientSnapshots
        fails("excess archive snapshots rejected") { _ = try memory.installBackup(payload(ten + [snapshot(incoming)]), current: current) }
        check("invalid payload leaves memory unchanged", memory.transientSnapshots == beforeMemory)
        fails("duplicate archive snapshot IDs rejected") { _ = try memory.installBackup(payload([ten[0], ten[0]]), current: current) }
        let malformed = FullBackup.Snapshot(metadata: LibrarySnapshot(id: UUID().uuidString,
            createdAt: Date().timeIntervalSince1970, reason: "Wrong counts", siteCount: 999, folderCount: 0), library: incoming)
        fails("invalid snapshot metadata is rejected before mutation") { _ = try memory.installBackup(payload([malformed]), current: current) }
        check("rejected snapshot metadata leaves memory unchanged", memory.transientSnapshots == beforeMemory)

        let disk = try diskStore("ok")
        let socketMarker = disk.directory.appendingPathComponent("bridge.sock")
        check("socket placeholder setup", mkfifo(socketMarker.path, 0o600) == 0)
        let unrelated = disk.directory.appendingPathComponent("unrelated.txt")
        let marker = Data("unrelated local file".utf8); try marker.write(to: unrelated)
        let diskResult = try disk.installBackup(payload([snapshot(incoming)]), current: current)
        check("disk library equals returned state", (try? disk.load(defaultBrowsers: ["edge"])) == diskResult)
        check("disk snapshots include old imported and safety", (try? disk.snapshots().count) == 3)
        var socketInfo = stat(); _ = lstat(socketMarker.path, &socketInfo)
        check("bridge socket path is untouched", socketInfo.st_mode & S_IFMT == S_IFIFO)
        check("unrelated files are untouched", (try? Data(contentsOf: unrelated)) == marker)
        check("committed library is private", (try? fm.attributesOfItem(atPath: disk.file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        check("committed snapshots directory is private", (try? fm.attributesOfItem(atPath: disk.directory.appendingPathComponent("Snapshots").path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        check("successful transaction is cleaned", try noIntermediates(disk))

        #if DEBUG_TESTING
        for step in 1...4 {
            let store = try diskStore("fail-\(step)")
            let before = try ownedFiles(store)
            var observed = 0
            BackupRestoreTesting.observeStep = { boundary in
                observed += 1
                check("live library is never missing at boundary \(boundary)", fm.fileExists(atPath: store.file.path))
                let live = (try? Data(contentsOf: store.file)).flatMap { try? JSONDecoder().decode(Library.self, from: $0).validated() }
                check("live library always decodes at boundary \(boundary)", live != nil)
                let snapshots = try? store.snapshots()
                check("live snapshots stay readable at boundary \(boundary)", snapshots?.isEmpty == false)
                if boundary >= 2 {
                    check("safety snapshot precedes library commit at boundary \(boundary)", snapshots?.contains { $0.reason == "恢复完整资料前" } == true)
                }
            }
            BackupRestoreTesting.failAfterMove = step
            fails("mid-commit failure is reported at move \(step)") { _ = try store.installBackup(payload([snapshot(incoming)]), current: current) }
            BackupRestoreTesting.failAfterMove = nil; BackupRestoreTesting.observeStep = nil
            check("requested transaction boundary was reached", observed == step)
            check("rollback restores exact bytes after move \(step)", try ownedFiles(store) == before)
            check("rollback restores readable library after move \(step)", (try? store.load(defaultBrowsers: [])) == current)
            check("rolled back intermediates cleaned at move \(step)", try noIntermediates(store))
        }
        #else
        fatalError("Compile BackupRestoreTests with -D DEBUG_TESTING")
        #endif

        let changed = try diskStore("stale")
        var concurrent = current; concurrent.sites[0].name = "Changed after preview"; try changed.save(concurrent)
        let changedBytes = try ownedFiles(changed)
        fails("stale preview cannot overwrite newly saved data") { _ = try changed.installBackup(payload(), current: current) }
        check("concurrent data survives", try ownedFiles(changed) == changedBytes)

        let destination = root.appendingPathComponent("outside.json")
        let outside = Data("must stay untouched".utf8); try outside.write(to: destination)
        let linkedFile = try diskStore("link-file")
        try fm.removeItem(at: linkedFile.file); try fm.createSymbolicLink(at: linkedFile.file, withDestinationURL: destination)
        fails("library symlink is rejected") { _ = try linkedFile.installBackup(payload(), current: current) }
        check("symlink target stays unchanged", (try? Data(contentsOf: destination)) == outside)
        let linkedSnapshots = try diskStore("link-snapshots")
        let snapshotID = UUID().uuidString
        try fm.createSymbolicLink(at: linkedSnapshots.directory.appendingPathComponent("Snapshots/\(snapshotID).json"), withDestinationURL: destination)
        let localBytes = try Data(contentsOf: linkedSnapshots.file)
        fails("snapshot symlink is rejected") { _ = try linkedSnapshots.installBackup(payload(), current: current) }
        check("snapshot symlink failure leaves library untouched", (try? Data(contentsOf: linkedSnapshots.file)) == localBytes)
        let snapshotDirectoryLink = try diskStore("snapshot-dir-link")
        let sourceDirectory = snapshotDirectoryLink.directory.appendingPathComponent("Snapshots")
        let movedDirectory = root.appendingPathComponent("external-snapshots")
        try fm.moveItem(at: sourceDirectory, to: movedDirectory)
        try fm.createSymbolicLink(at: sourceDirectory, withDestinationURL: movedDirectory)
        let linkedDirectoryLibrary = try Data(contentsOf: snapshotDirectoryLink.file)
        fails("snapshot directory symlink is rejected") { _ = try snapshotDirectoryLink.installBackup(payload(), current: current) }
        check("snapshot directory refusal preserves library", (try? Data(contentsOf: snapshotDirectoryLink.file)) == linkedDirectoryLibrary)
        let real = try diskStore("real-directory")
        let linkedDirectory = root.appendingPathComponent("linked-directory")
        try fm.createSymbolicLink(at: linkedDirectory, withDestinationURL: real.directory)
        let realBytes = try ownedFiles(real)
        fails("data directory symlink is rejected") { _ = try LibraryStore(directory: linkedDirectory).installBackup(payload(), current: current) }
        check("real data behind symlink survives", try ownedFiles(real) == realBytes)
        let broken = try diskStore("broken-symlink")
        try fm.removeItem(at: broken.file)
        try fm.createSymbolicLink(at: broken.file, withDestinationURL: root.appendingPathComponent("missing-target"))
        fails("dangling library symlink is rejected") { _ = try broken.installBackup(payload(), current: current) }
        let unknown = try diskStore("unknown-file")
        try marker.write(to: unknown.directory.appendingPathComponent("Snapshots/private-note.txt"))
        let unknownBytes = try ownedFiles(unknown)
        fails("unknown snapshot directory contents are preserved by refusing restore") { _ = try unknown.installBackup(payload(), current: current) }
        check("unknown file refusal is nondestructive", try ownedFiles(unknown) == unknownBytes)
        let corrupt = try diskStore("corrupt-snapshot")
        let corruptID = UUID().uuidString
        try Data("invalid snapshot".utf8).write(to: corrupt.directory.appendingPathComponent("Snapshots/\(corruptID).json"))
        let corruptBytes = try ownedFiles(corrupt)
        fails("unreadable existing history is not silently discarded") { _ = try corrupt.installBackup(payload(), current: current) }
        check("corrupt history refusal preserves every byte", try ownedFiles(corrupt) == corruptBytes)

        let fresh = LibraryStore(directory: root.appendingPathComponent("fresh"))
        let freshResult = try fresh.installBackup(payload(), current: .empty())
        check("first-time restore creates library", (try? fresh.load(defaultBrowsers: [])) == freshResult)
        check("first-time restore retains empty pre-restore snapshot", (try? fresh.snapshots().count) == 1)
        let interrupted = LibraryStore(directory: root.appendingPathComponent("interrupted"))
        let pending = interrupted.directory.appendingPathComponent(".gaomenhu-restore-" + UUID().uuidString)
        try fm.createDirectory(at: pending, withIntermediateDirectories: true)
        fails("interrupted restore cannot fall back to default websites") { _ = try interrupted.load(defaultBrowsers: ["edge"]) }
        check("interrupted restore does not create a default library file", !fm.fileExists(atPath: interrupted.file.path))
        print("Backup restore tests passed: \(checks)")
    }
}
