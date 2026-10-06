import Foundation
import Darwin

@main struct CoreTests {
    static func main() throws {
        var count = 0
        func check(_ name: String, _ assertion: @autoclosure () -> Bool) {
            guard assertion() else { fatalError(name) }
            count += 1
        }
        var library = Library.initial(browsers: ["chrome", "edge"])
        _ = try library.validated()
        check("seed", library.sites.count == 6)
        var bad = library; bad.sites[0].allowedBrowsers = []
        check("zero browsers", (try? bad.validated()) == nil)
        bad = library; bad.sites[0].allowedBrowsers = ["chrome"]; bad.sites[0].defaultBrowser = "edge"
        check("default not allowed", (try? bad.validated()) == nil)
        bad = library; bad.sites[0].url = "javascript:alert(1)"
        check("unsafe URL", (try? bad.validated()) == nil)
        bad = library; bad.tiles.append(bad.tiles[0])
        check("duplicate tile", (try? bad.validated()) == nil)
        bad = library; bad.tiles[0] = Tile(id: "folder", kind: "folder", name: "AI", children: ["seed-0","seed-1"])
        check("duplicate folder membership", (try? bad.validated()) == nil)
        bad.tiles.remove(at: 1)
        check("valid folder", (try? bad.validated()) != nil)
        library.tiles.removeFirst()
        check("archived website", (try? library.validated()) != nil)
        check("reject URL userinfo", validWebURL("https://user:password@example.com") == nil)
        check("reject wildcard", normalizedHost("*.example.com") == nil)
        check("reject login URL path", normalizedHost("example.com/login") == nil)
        check("normalized origin", origin("https://example.com:443/login") == "https://example.com")
        check("preserve non-default port", origin("https://example.com:8443/login") == "https://example.com:8443")
        let account = Account(id: "test", label: "Test", username: "dummy", loginHosts: ["auth.example.com"], hasPassword: true)
        let site = Website(id: "test", name: "Test", url: "https://example.com", color: "#D97757", allowedBrowsers: ["chrome"], defaultBrowser: "chrome", accounts: [account], defaultAccount: account.id, profiles: [:])
        let allowed = allowedOrigins(site: site, account: account)
        check("allowed login", allowed.contains("https://auth.example.com"))
        check("reject suffix phishing", !allowed.contains("https://example.com.evil.test"))
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mendao-core-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let store = LibraryStore(directory: temporary)
        try store.save(library)
        let reloaded = try store.load(defaultBrowsers: [])
        check("persistent layout", reloaded == library)
        let permissions = try FileManager.default.attributesOfItem(atPath: store.file.path)[.posixPermissions] as! NSNumber
        check("private file", permissions.intValue == 0o600)
        let vault = Vault(testing: true)
        try vault.save("dummy-test-password", id: account.id)
        let read = try vault.read(id: account.id)
        check("vault save and read", read == "dummy-test-password")
        try vault.remove(id: account.id)
        let removed = try vault.read(id: account.id)
        check("vault delete", removed.isEmpty)
        let json = try JSONEncoder().encode(site)
        check("no password in JSON", !String(data: json, encoding: .utf8)!.contains("dummy-test-password"))
        let legacySite = try JSONDecoder().decode(Website.self, from: json)
        check("legacy icon metadata optional", legacySite.iconSource == nil && legacySite.iconRevision == nil)
        var customSite = site
        customSite.iconSource = "custom"; customSite.iconRevision = 2; customSite.iconSourcePixels = 256
        let customRoundTrip = try JSONDecoder().decode(Website.self, from: JSONEncoder().encode(customSite))
        check("preserve custom icon provenance", customRoundTrip.iconSource == "custom")
        check("preserve icon resolution", customRoundTrip.iconSourcePixels == 256 && customRoundTrip.iconRevision == 2)
        var pair: [Int32] = [0,0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { fatalError("socketpair") }
        defer { close(pair[0]); close(pair[1]) }
        check("native frame write", writeFrame(pair[0], object: ["hello": "门道", "number": 42]))
        let received = readFrame(pair[1])
        check("native frame UTF8", received?["hello"] as? String == "门道")
        check("native frame integer", received?["number"] as? Int == 42)
        var oversized = UInt32(1_048_577).littleEndian
        _ = withUnsafeBytes(of: &oversized) { writeExactly(pair[0], data: Data($0)) }
        check("reject oversized frame", readFrame(pair[1]) == nil)
        print("Core tests passed: \(count)")
    }
}
