import Foundation

@main struct BrowserDiagnosticsTests {
    static func main() throws {
        var count = 0
        func check(_ name: String, _ condition: @autoclosure () -> Bool) {
            guard condition() else { fatalError("Browser diagnostic fixture failed: " + name) }
            count += 1
        }
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("mendao-browser-diagnostics-\(UUID().uuidString)")
        try manager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: root) }
        let home = root.appendingPathComponent("Home", isDirectory: true)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let resources = root.appendingPathComponent("Resources", isDirectory: true)
        let helper = root.appendingPathComponent("MenDaoBridge")
        let hostName = "cn.mendao.bridge"
        let inspector = BrowserDiagnostics(home: home, systemLibrary: library, resources: resources, helper: helper, hostName: hostName)
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let extensionSource = project.appendingPathComponent("BrowserExtension", isDirectory: true)
        try manager.createDirectory(at: resources, withIntermediateDirectories: false)
        try manager.copyItem(at: extensionSource, to: inspector.extensionDirectory)
        try manager.copyItem(at: extensionSource.appendingPathComponent("extension-id.txt"), to: resources.appendingPathComponent("extension-id.txt"))
        try Data("synthetic helper".utf8).write(to: helper)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)

        func inspect(_ target: PortalBrowserTarget = .chrome, installed: Bool = true, running: Bool = true, bridge: Bool = true) -> BrowserDiagnosticSnapshot {
            inspector.snapshot(for: target, installed: installed, running: running, bridgeRunning: bridge)
        }
        let chrome = PortalBrowserTarget.chrome.userManifest(in: home, hostName: hostName)
        let edge = PortalBrowserTarget.edge.userManifest(in: home, hostName: hostName)
        let systemEdge = PortalBrowserTarget.edge.systemManifest(in: library, hostName: hostName)
        check("Chrome stable per-user location", chrome.path == home.path + "/Library/Application Support/Google/Chrome/NativeMessagingHosts/cn.mendao.bridge.json")
        check("Edge stable system location", systemEdge.path == library.path + "/Microsoft/Edge/NativeMessagingHosts/cn.mendao.bridge.json")
        let payload = try inspector.registrationPayload()
        let missing = inspect()
        check("bundled manifest, key, permission and resources verify", missing.extensionPackage.status == .verified)
        check("default host registration missing", missing.nativeHost.status == .issue && missing.canRepair)
        check("listener is separate from registration", missing.bridge.status == .verified)
        check("a connected profile is the end-to-end evidence", missing.connection(profileCount: 1).status == .verified)
        check("no active profile remains indeterminate", missing.connection(profileCount: 0).status == .unknown)
        check("unknown browser install is visible", inspect(installed: false, running: false).browser.status == .issue)

        try inspector.writeRegistration(payload, for: .chrome)
        let permissions = try manager.attributesOfItem(atPath: chrome.path)[.posixPermissions] as? Int
        check("Chrome repair writes own private manifest", permissions == 0o600 && inspect().nativeHost.status == .verified)
        let earlier = Date(timeIntervalSince1970: 1_000_000)
        try manager.setAttributes([.modificationDate: earlier], ofItemAtPath: chrome.path)
        try inspector.writeRegistration(payload, for: .chrome)
        let modified = try manager.attributesOfItem(atPath: chrome.path)[.modificationDate] as? Date
        check("known-good registration is not rewritten", modified == earlier)
        check("Chrome repair leaves Edge unchanged", !manager.fileExists(atPath: edge.path) && inspect(.edge).nativeHost.status == .issue)
        check("stopped listener exposes repair even with correct manifest", inspect(bridge: false).canRepair && inspect(bridge: false).bridge.status == .issue)
        check("healthy local setup has no repair action", !inspect().canRepair)

        try manager.createDirectory(at: systemEdge.deletingLastPathComponent(), withIntermediateDirectories: true)
        try payload.write(to: systemEdge)
        check("system default is reported when user host is absent", inspect(.edge).nativeHost.detail.contains("整台 Mac"))
        var altered = try JSONSerialization.jsonObject(with: payload) as! [String: Any]
        altered["path"] = root.appendingPathComponent("Old/MenDaoBridge").path
        let stale = try JSONSerialization.data(withJSONObject: altered)
        try inspector.writeRegistration(stale, for: .edge)
        check("user registration wins over system with stale helper path", inspect(.edge).nativeHost.status == .issue && inspect(.edge).canRepair)
        try inspector.writeRegistration(payload, for: .edge)
        check("restored host resolves to the current bundle", inspect(.edge).nativeHost.status == .verified)
        altered["path"] = helper.path
        altered["allowed_origins"] = ["chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/"]
        try inspector.writeRegistration(JSONSerialization.data(withJSONObject: altered), for: .edge)
        check("unrelated allowed origin is rejected", inspect(.edge).nativeHost.status == .issue)
        try Data(repeating: 0, count: 64 * 1024 + 1).write(to: edge)
        check("oversized manifest is rejected", inspect(.edge).nativeHost.status == .issue)
        try manager.removeItem(at: edge)
        try manager.createSymbolicLink(at: edge, withDestinationURL: systemEdge)
        check("redirected manifest is indeterminate", inspect(.edge).nativeHost.status == .unknown)
        var refusedRedirect = false
        do { try inspector.writeRegistration(payload, for: .edge) }
        catch { refusedRedirect = true }
        check("locally managed repair refuses redirected manifest", refusedRedirect && inspect(.edge).nativeHost.status == .unknown)

        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: helper.path)
        check("nonexecutable helper requires fixing the app installation", inspect().nativeHost.status == .issue && !inspect().canRepair)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let id = resources.appendingPathComponent("extension-id.txt")
        let actualID = try Data(contentsOf: id)
        try Data("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa".utf8).write(to: id)
        check("bundle ID that differs from extension key is rejected", inspect().extensionPackage.status == .issue && inspect().nativeHost.status == .unknown)
        try actualID.write(to: id)
        try manager.removeItem(at: inspector.extensionDirectory.appendingPathComponent("popup.js"))
        check("incomplete package is detected", inspect().extensionPackage.status == .issue && !inspect().canRepair)
        print("Browser diagnostic fixture passed: \(count) checks")
    }
}
