import Foundation
import Darwin

@main struct IngressTests {
    static func main() throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("portal-ingress-\(UUID().uuidString).noindex", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        var checks = 0
        func expect(_ condition: @autoclosure () throws -> Bool) throws { let value = try condition(); precondition(value); checks += 1 }
        func package(_ name: String, _ object: [String: Any]) throws -> URL {
            let url = root.appendingPathComponent(name + ".gaoaction", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try JSONSerialization.data(withJSONObject: object).write(to: url.appendingPathComponent("manifest.json"))
            return url
        }
        let direct = try package("download", ["kind": "request", "action": "downloads.prepare", "targetBundleID": "cn.mendao.launcher"])
        try expect(PortalDownloadIngress.isDownloadPackage(direct))
        let site = try package("site", ["kind": "request", "action": "portal.openSite", "targetBundleID": "cn.mendao.launcher"])
        try expect(!PortalDownloadIngress.isDownloadPackage(site))
        let result = try package("result", ["kind": "result", "action": "downloads.prepare", "targetBundleID": "cn.mendao.launcher"])
        try expect(!PortalDownloadIngress.isDownloadPackage(result))
        let old = try package("old", ["kind": "request", "action": "downloads.prepare", "targetBundleID": "com.gaoseries.GaoXiaZai"])
        // Dispatch does not authorize this obsolete target; the full codec rejects it.
        try expect(PortalDownloadIngress.isDownloadPackage(old))
        let symlink = root.appendingPathComponent("link.gaoaction")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: direct)
        do { _ = try PortalDownloadIngress.isDownloadPackage(symlink); preconditionFailure("linked package accepted") } catch { checks += 1 }
        let linkedManifest = try package("linked-manifest", [:]); try FileManager.default.removeItem(at: linkedManifest.appendingPathComponent("manifest.json"))
        try FileManager.default.createSymbolicLink(at: linkedManifest.appendingPathComponent("manifest.json"), withDestinationURL: direct.appendingPathComponent("manifest.json"))
        do { _ = try PortalDownloadIngress.isDownloadPackage(linkedManifest); preconditionFailure("linked manifest accepted") } catch { checks += 1 }
        let oversized = try package("oversized", [:]); try Data(repeating: 32, count: 1_048_577).write(to: oversized.appendingPathComponent("manifest.json"))
        do { _ = try PortalDownloadIngress.isDownloadPackage(oversized); preconditionFailure("oversized manifest accepted") } catch { checks += 1 }
        print("Portal download ingress: \(checks) isolated checks passed")
    }
}
