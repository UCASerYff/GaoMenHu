import Foundation
import CryptoKit
import Darwin

@main
struct GaoActionPackageTests {
    static var passed = 0
    static let fm = FileManager.default
    static let now = ISO8601DateFormatter().date(from: "2026-10-12T12:00:00Z")!
    static let hash = "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03"
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { fatalError(message) }; passed += 1
    }
    static func reject(_ code: String? = nil, _ message: String, _ action: () throws -> Void) {
        do { try action(); fatalError("accepted: " + message) }
        catch let e as GaoActionPackageError { if let code { guard e.code == code else { fatalError(message + ": " + e.code) } }; passed += 1 }
        catch { fatalError(message + ": wrong error " + String(describing: error)) }
    }
    static func validateAction(_ m: GaoActionManifest) throws {
        let actions = ["documents.newText", "storage.inspect", "ocr.files", "portal.focusSearch", "portal.openSite"]
        guard actions.contains(m.action) else { throw GaoActionPackageError("unknownAction", "测试不支持此动作") }
        let allowed: Set<String>
        switch m.action {
        case "documents.newText": allowed = ["suggestedTitle"]
        case "storage.inspect": allowed = ["mode"]
        case "portal.focusSearch": allowed = ["query"]
        case "portal.openSite": allowed = ["siteID", "browserID"]
        default: allowed = []
        }
        guard Set(m.parameters.keys).isSubset(of: allowed) else { throw GaoActionPackageError("unknownParameter", "未允许参数") }
    }
    static func base() -> GaoActionManifest {
        GaoActionManifest(kind: "request", requestID: "11111111-1111-4111-8111-000000000004", sourceBundleID: "com.gaoseries.GaoActionFixture", targetBundleID: "cn.mendao.launcher", action: "portal.focusSearch", createdAt: "2026-10-12T12:00:00Z", expiresAt: "2026-10-12T12:02:00Z", nonce: Data(repeating: 0, count: 32).base64EncodedString(), items: [], references: [], parameters: [:])
    }
    static func validate(_ m: GaoActionManifest, at date: Date = now) throws -> GaoActionManifest {
        try GaoActionPackage.validate(data: GaoActionPackage.manifestData(m), targetBundleID: m.targetBundleID, now: date, validateAction: validateAction)
    }
    static func privateDirectory(_ url: URL) throws { try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); guard chmod(url.path, 0o700) == 0 else { fatalError("chmod") } }
    static func privateFile(_ data: Data, _ url: URL) throws { try data.write(to: url); guard chmod(url.path, 0o600) == 0 else { fatalError("chmod") } }
    static func package(_ root: URL, manifest: GaoActionManifest, bytes: Data = Data("hello\n".utf8), relativePath: String = "input.txt") throws -> URL {
        let url = root.appendingPathComponent(UUID().uuidString + ".gaoaction", isDirectory: true)
        try privateDirectory(url.appendingPathComponent("payload", isDirectory: true))
        try privateFile(GaoActionPackage.manifestData(manifest), url.appendingPathComponent("manifest.json"))
        if !manifest.items.isEmpty {
            let file = url.appendingPathComponent("payload").appendingPathComponent(relativePath)
            try privateDirectory(file.deletingLastPathComponent()); try privateFile(bytes, file)
        }
        return url
    }
    static func receive(_ url: URL, _ staging: URL, target: String = "cn.mendao.launcher") throws -> GaoActionReceivedPackage {
        try GaoActionPackage.receive(at: url, stagingRoot: staging, targetBundleID: target, now: now, validateAction: validateAction)
    }
    static func document() -> GaoActionManifest {
        var m = base(); m.action = "documents.newText"; m.targetBundleID = "com.gaoseries.GaoWenJian"
        m.items = [GaoActionItem(id: "input", relativePath: "payload/input.txt", uti: "public.utf8-plain-text", byteCount: 6, sha256: hash)]
        m.parameters = ["suggestedTitle": .string("交接测试")]; return m
    }
    static func main() throws {
        let root = URL(fileURLWithPath: "/private/tmp/gaomenhu-action-tests." + UUID().uuidString, isDirectory: true)
        try privateDirectory(root); defer { try? fm.removeItem(at: root) }
        let staging = root.appendingPathComponent("Staging", isDirectory: true)
        let source = try package(root, manifest: base())
        let received = try receive(source, staging)
        try check(received.manifest == base(), "empty portal roundtrip")
        try check(received.packageURL != source && fm.fileExists(atPath: source.path), "source retained and staging independent")
        try check(received.manifestSHA256.count == 64, "manifest fingerprint")
        var statResult = stat(); _ = stat(received.packageURL.path, &statResult)
        try check(statResult.st_mode & 0o777 == 0o700, "private package mode")
        _ = stat(received.packageURL.appendingPathComponent("manifest.json").path, &statResult)
        try check(statResult.st_mode & 0o777 == 0o600, "private manifest mode")
        let doc = document(); let docURL = try package(root, manifest: doc)
        let copy = try receive(docURL, staging, target: doc.targetBundleID)
        try check(try Data(contentsOf: copy.payloadURL.appendingPathComponent("input.txt")) == Data("hello\n".utf8), "descriptor copied content")
        try privateFile(Data("changed\n".utf8), docURL.appendingPathComponent("payload/input.txt"))
        try check(try Data(contentsOf: copy.payloadURL.appendingPathComponent("input.txt")) == Data("hello\n".utf8), "copy independent of sender changes")
        var shortPath = doc; shortPath.items[0].relativePath = "input.txt"
        let shortURL = try package(root, manifest: shortPath); _ = try receive(shortURL, staging, target: doc.targetBundleID); passed += 1
        var nested = doc; nested.items[0].relativePath = "payload/one/two/input.txt"
        let nestedURL = try package(root, manifest: nested, relativePath: "one/two/input.txt")
        let nestedCopy = try receive(nestedURL, staging, target: doc.targetBundleID)
        try check(fm.fileExists(atPath: nestedCopy.payloadURL.appendingPathComponent("one/two/input.txt").path), "nested ordinary payload")
        var m = base(); m.schemaVersion = 2; reject("unsupportedSchema", "new schema") { _ = try validate(m) }
        m = base(); m.requestID = "invalid"; reject("invalidIdentity", "non UUID") { _ = try validate(m) }
        reject("invalidIdentity", "target mismatch") { _ = try GaoActionPackage.validate(data: GaoActionPackage.manifestData(base()), targetBundleID: "com.other.App", now: now, validateAction: validateAction) }
        m = base(); m.sourceBundleID = "../../App"; reject("invalidIdentity", "bundle declaration") { _ = try validate(m) }
        m = base(); m.nonce = "not nonce"; reject("invalidNonce", "nonce length") { _ = try validate(m) }
        reject("expired", "expires boundary") { _ = try validate(base(), at: now.addingTimeInterval(120)) }
        reject("futureRequest", "future created") { _ = try validate(base(), at: now.addingTimeInterval(-1)) }
        m = base(); m.expiresAt = "2026-10-12T12:02:01Z"; reject("invalidTTL", "TTL upper bound") { _ = try validate(m) }
        m = base(); m.expiresAt = m.createdAt; reject("invalidTTL", "zero TTL") { _ = try validate(m) }
        m = base(); m.createdAt = "2026-10-12T12:00:00+00:00"; reject("invalidTTL", "UTC Z required") { _ = try validate(m) }
        m = base(); m.action = "unknown.action"; reject("unknownAction", "unknown action") { _ = try validate(m) }
        m = base(); m.parameters = ["shell": .string("example")]; reject("unknownParameter", "commands refused by action schema") { _ = try validate(m) }
        m = base(); m.items = doc.items; reject("unexpectedPayload", "portal files refused") { _ = try validate(m) }
        let portalPayload = try package(root, manifest: m)
        try fm.removeItem(at: portalPayload.appendingPathComponent("payload/input.txt"))
        guard symlink("/no/such/private/file", portalPayload.appendingPathComponent("payload/input.txt").path) == 0 else { fatalError("symlink") }
        reject("unexpectedPayload", "portal rejects before touching attached links") { _ = try receive(portalPayload, staging) }
        for path in ["../input.txt", "payload/../input.txt", "/input.txt", "payload/", "payload/./input.txt", "payload//input.txt", "payload/a\\b", "payload/a\0b"] {
            m = doc; m.items[0].relativePath = path; reject("invalidPath", "path escape") { _ = try validate(m) }
        }
        m = doc; var duplicate = m.items[0]; duplicate.id = "input2"; duplicate.relativePath = "input.txt"; m.items.append(duplicate)
        reject("duplicatePath", "equivalent payload spellings") { _ = try validate(m) }
        m = doc; m.items[0].byteCount = GaoActionPackage.maximumPayloadBytes + 1; reject("invalidItem", "individual limit") { _ = try validate(m) }
        m = doc; m.items[0].byteCount = GaoActionPackage.maximumPayloadBytes; duplicate = m.items[0]; duplicate.id = "input2"; duplicate.relativePath = "two.txt"; m.items.append(duplicate)
        reject("payloadTooLarge", "total limit") { _ = try validate(m) }
        m = doc; m.items = (0...256).map { GaoActionItem(id: String($0), relativePath: "x\($0)", uti: "public.data", byteCount: 0, sha256: hash) }
        reject("tooManyItems", "project limit") { _ = try validate(m) }
        m = doc; m.items[0].sha256 = hash.uppercased(); reject("invalidItem", "canonical digest") { _ = try validate(m) }
        var raw = try JSONSerialization.jsonObject(with: GaoActionPackage.manifestData(base())) as! [String: Any]
        raw["callbackURL"] = "example://callback"; reject("unknownField", "top level callbacks") { _ = try GaoActionPackage.validate(data: JSONSerialization.data(withJSONObject: raw), targetBundleID: base().targetBundleID, now: now, validateAction: validateAction) }
        raw.removeValue(forKey: "callbackURL"); raw["schemaVersion"] = true; reject("unsupportedSchema", "bool is not schema integer") { _ = try GaoActionPackage.validate(data: JSONSerialization.data(withJSONObject: raw), targetBundleID: base().targetBundleID, now: now, validateAction: validateAction) }
        let normalData = try GaoActionPackage.manifestData(base()); var text = String(data: normalData, encoding: .utf8)!
        text = text.replacingOccurrences(of: "\"schemaVersion\" : 1", with: "\"schemaVersion\":2,\"schemaVersion\":1")
        reject("invalidJSON", "duplicate JSON keys") { _ = try GaoActionPackage.validate(data: Data(text.utf8), targetBundleID: base().targetBundleID, now: now, validateAction: validateAction) }
        reject("manifestTooLarge", "manifest limit") { _ = try GaoActionPackage.validate(data: Data(repeating: 32, count: GaoActionPackage.maximumManifestBytes + 1), targetBundleID: base().targetBundleID, now: now, validateAction: validateAction) }
        let badHashURL = try package(root, manifest: doc, bytes: Data("other\n".utf8))
        let stageBefore = try fm.contentsOfDirectory(atPath: staging.path).count
        reject("digestMismatch", "copied digest mismatch") { _ = try receive(badHashURL, staging, target: doc.targetBundleID) }
        try check(try fm.contentsOfDirectory(atPath: staging.path).count == stageBefore, "failure staging removed")
        let badSizeURL = try package(root, manifest: doc, bytes: Data("too long\n".utf8))
        reject("sizeMismatch", "source size mismatch") { _ = try receive(badSizeURL, staging, target: doc.targetBundleID) }
        let linkURL = try package(root, manifest: doc); let linkFile = linkURL.appendingPathComponent("payload/input.txt")
        let selected = root.appendingPathComponent("selected.txt"); try privateFile(Data("hello\n".utf8), selected)
        try fm.removeItem(at: linkFile); guard symlink(selected.path, linkFile.path) == 0 else { fatalError("symlink") }
        reject("unreadable", "symlink attachment") { _ = try receive(linkURL, staging, target: doc.targetBundleID) }
        try fm.removeItem(at: linkFile); guard link(selected.path, linkFile.path) == 0 else { fatalError("hardlink") }
        reject("unsafeFile", "hardlink attachment") { _ = try receive(linkURL, staging, target: doc.targetBundleID) }; try fm.removeItem(at: linkFile)
        let directoryURL = try package(root, manifest: doc); try fm.removeItem(at: directoryURL.appendingPathComponent("payload/input.txt")); try privateDirectory(directoryURL.appendingPathComponent("payload/input.txt"))
        reject("unexpectedFile", "directory cannot be ordinary attachment") { _ = try receive(directoryURL, staging, target: doc.targetBundleID) }
        let extraURL = try package(root, manifest: base()); try privateFile(Data("secret".utf8), extraURL.appendingPathComponent("payload/undeclared"))
        reject("unexpectedFile", "undeclared payload") { _ = try receive(extraURL, staging) }
        let rootExtra = try package(root, manifest: base()); try privateFile(Data("secret".utf8), rootExtra.appendingPathComponent("other"))
        reject("unexpectedFile", "undeclared root file") { _ = try receive(rootExtra, staging) }
        let publicURL = try package(root, manifest: base()); _ = chmod(publicURL.path, 0o755)
        reject("unsafePermissions", "public source directory") { _ = try receive(publicURL, staging) }
        let publicFileURL = try package(root, manifest: base()); _ = chmod(publicFileURL.appendingPathComponent("manifest.json").path, 0o644)
        reject("unsafeFile", "public manifest") { _ = try receive(publicFileURL, staging) }
        let symlinkRoot = root.appendingPathComponent("link.gaoaction"); guard symlink(source.path, symlinkRoot.path) == 0 else { fatalError("symlink") }
        reject("unsafeDirectory", "symlink package") { _ = try receive(symlinkRoot, staging) }
        let symlinkStaging = root.appendingPathComponent("staging-link"); guard symlink(staging.path, symlinkStaging.path) == 0 else { fatalError("symlink") }
        reject("unsafeDirectory", "symlink staging root") { _ = try receive(source, symlinkStaging) }
        let outgoing = root.appendingPathComponent("Outgoing", isDirectory: true); try privateDirectory(outgoing)
        let outgoingURL = outgoing.appendingPathComponent(UUID().uuidString + ".gaoaction")
        _ = chmod(selected.path, 0o644)
        _ = try GaoActionPackage.write(manifest: doc, to: outgoingURL, payloads: ["input": selected], now: now, validateAction: validateAction)
        let outgoingCopy = try receive(outgoingURL, staging, target: doc.targetBundleID)
        try check(try Data(contentsOf: outgoingCopy.payloadURL.appendingPathComponent("input.txt")) == Data("hello\n".utf8), "ordinary readable selected file copied privately")
        reject("destinationExists", "outgoing cannot overwrite") { _ = try GaoActionPackage.write(manifest: doc, to: outgoingURL, payloads: ["input": selected], now: now, validateAction: validateAction) }
        reject("invalidItem", "outgoing map must match") { _ = try GaoActionPackage.write(manifest: doc, to: outgoing.appendingPathComponent("bad.gaoaction"), now: now, validateAction: validateAction) }
        let random1 = try GaoActionPackage.randomNonce(); let random2 = try GaoActionPackage.randomNonce()
        try check(random1 != random2 && Data(base64Encoded: random1)?.count == 32, "production secure nonce")
        try fixtures(root: root, staging: staging)
        print("GaoAction package: \(passed) checks passed")
    }
    static func fixtures(root: URL, staging: URL) throws {
        let fixtureRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/GaoActionV1")
        let names = ["v1-documents-newText", "v1-storage-directory", "v1-ocr-partial", "v1-duplicate-request", "v1-expired", "v1-path-traversal", "v1-unknown-action", "v2-unsupported"]
        for (index, name) in names.enumerated() {
            let fixture = fixtureRoot.appendingPathComponent(name)
            var manifest = try JSONDecoder().decode(GaoActionManifest.self, from: Data(contentsOf: fixture.appendingPathComponent("manifest.json")))
            try check(manifest.requestID == String(format: "11111111-1111-4111-8111-%012d", index + 1), "fixed fixture ID")
            if name == "v1-storage-directory" {
                let original = root.appendingPathComponent("original-directory", isDirectory: true); try privateDirectory(original)
                var s = stat(); guard stat(original.path, &s) == 0 else { fatalError("stat fixture directory") }
                manifest.references[0].fileURL = original.absoluteString
                manifest.references[0].declaredIdentity = GaoActionIdentity(device: UInt64(s.st_dev), inode: UInt64(s.st_ino), byteCount: Int64(s.st_size), modifiedAt: GaoActionPackage.iso8601(Date(timeIntervalSince1970: Double(s.st_mtimespec.tv_sec))))
            }
            if index < 4 {
                let url = try package(root, manifest: manifest, relativePath: name == "v1-ocr-partial" ? "page1.txt" : "input.txt")
                let received = try receive(url, staging, target: manifest.targetBundleID)
                try check(received.manifest == manifest, "legal fixture roundtrip")
                if name == "v1-ocr-partial" { try check(received.manifest.status == "partial" && received.manifest.inReplyTo == manifest.requestID, "partial mapped with correct reply") }
                if name == "v1-duplicate-request" { let again = try receive(url, staging, target: manifest.targetBundleID); try check(received.manifestSHA256 == again.manifestSHA256, "duplicate same fingerprint for App ledger") }
            } else {
                let code = ["expired", "invalidPath", "unknownAction", "unsupportedSchema"][index - 4]
                reject(code, "invalid shared fixture") { _ = try validate(manifest) }
            }
        }
    }
}
