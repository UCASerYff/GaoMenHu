import Foundation

@main struct BackupRestoreTests {
    static func main() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp/gmh-restore-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        var checks = 0
        func check(_ name: String, _ condition: Bool) {
            guard condition else { fatalError(name) }; checks += 1
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

        let restored = try LibraryOperations.restore(incoming, into: current)
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

        let store = LibraryStore(directory: root.appendingPathComponent("Data"))
        try store.save(current)
        let unrelated = store.directory.appendingPathComponent("unrelated.txt")
        let marker = Data("unrelated local file".utf8); try marker.write(to: unrelated)
        try store.save(restored)
        check("disk library equals restored state", (try? store.load(defaultBrowsers: ["edge"])) == restored)
        check("unrelated files are untouched", (try? Data(contentsOf: unrelated)) == marker)
        check("committed library is private", (try? fm.attributesOfItem(atPath: store.file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        check("restore creates no Snapshots directory", !fm.fileExists(atPath: store.directory.appendingPathComponent("Snapshots").path))
        let memory = LibraryStore(directory: root.appendingPathComponent("never-created"), persistent: false)
        try memory.save(restored)
        check("memory restoration never writes to disk", !fm.fileExists(atPath: memory.directory.path))
        print("Current-data restore tests passed: \(checks)")
    }
}
