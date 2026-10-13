import Foundation
import CryptoKit
import Security
import Darwin

/// An envelope is a declaration, not authentication or an access grant.
enum GaoJSONValue: Codable, Equatable {
    case object([String: GaoJSONValue]), array([GaoJSONValue]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self), v.isFinite { self = .number(v) }
        else if let v = try? c.decode([GaoJSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: GaoJSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): guard v.isFinite else { throw GaoActionPackageError("invalidJSON", "数字无效") }; try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    var string: String? { if case .string(let v) = self { return v }; return nil }
    var object: [String: GaoJSONValue]? { if case .object(let v) = self { return v }; return nil }
    var array: [GaoJSONValue]? { if case .array(let v) = self { return v }; return nil }
    var foundationValue: Any {
        switch self {
        case .object(let v): return v.mapValues(\.foundationValue)
        case .array(let v): return v.map(\.foundationValue)
        case .string(let v): return v
        case .number(let v): return v
        case .bool(let v): return v
        case .null: return NSNull()
        }
    }
}
struct GaoActionItem: Codable, Equatable {
    var id: String
    var relativePath: String
    var uti: String
    var byteCount: Int64
    var sha256: String
}
struct GaoActionIdentity: Codable, Equatable {
    var volumeUUID: String?
    var device: UInt64?
    var inode: UInt64?
    var byteCount: Int64?
    var modifiedAt: String?
    enum CodingKeys: String, CodingKey { case volumeUUID, device, inode, byteCount, modifiedAt }
    init(volumeUUID: String? = nil, device: UInt64? = nil, inode: UInt64? = nil, byteCount: Int64? = nil, modifiedAt: String? = nil) {
        self.volumeUUID = volumeUUID; self.device = device; self.inode = inode; self.byteCount = byteCount; self.modifiedAt = modifiedAt
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(volumeUUID, forKey: .volumeUUID); try c.encode(device, forKey: .device)
        try c.encode(inode, forKey: .inode); try c.encode(byteCount, forKey: .byteCount); try c.encode(modifiedAt, forKey: .modifiedAt)
    }
}
struct GaoActionReference: Codable, Equatable {
    var id: String
    var kind: String
    var fileURL: String
    var displayName: String
    var declaredIdentity: GaoActionIdentity
    var bundleID: String?
    var sha256: String?
}
struct GaoActionManifest: Codable, Equatable {
    var schemaVersion: Int = 1
    var kind: String
    var requestID: String
    var sourceBundleID: String
    var targetBundleID: String
    var action: String
    var createdAt: String
    var expiresAt: String
    var nonce: String
    var items: [GaoActionItem]
    var references: [GaoActionReference]
    var parameters: [String: GaoJSONValue]
    var inReplyTo: String? = nil
    var status: String? = nil
    var errorCode: String? = nil
    var provenance: [String: GaoJSONValue]? = nil
    enum CodingKeys: String, CodingKey {
        case schemaVersion, kind, requestID, sourceBundleID, targetBundleID, action, createdAt, expiresAt, nonce, items, references, parameters
        case inReplyTo, status, errorCode, provenance
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion); try c.encode(kind, forKey: .kind)
        try c.encode(requestID, forKey: .requestID); try c.encode(sourceBundleID, forKey: .sourceBundleID)
        try c.encode(targetBundleID, forKey: .targetBundleID); try c.encode(action, forKey: .action)
        try c.encode(createdAt, forKey: .createdAt); try c.encode(expiresAt, forKey: .expiresAt); try c.encode(nonce, forKey: .nonce)
        try c.encode(items, forKey: .items); try c.encode(references, forKey: .references); try c.encode(parameters, forKey: .parameters)
        if kind == "result" {
            try c.encode(inReplyTo, forKey: .inReplyTo); try c.encode(status, forKey: .status)
            try c.encode(errorCode, forKey: .errorCode); try c.encode(provenance, forKey: .provenance)
        }
    }
}
struct GaoActionReceivedPackage {
    let manifest: GaoActionManifest
    let packageURL: URL
    let manifestSHA256: String
    var payloadURL: URL { packageURL.appendingPathComponent("payload", isDirectory: true) }
}
struct GaoActionPackageError: Error, LocalizedError {
    let code: String
    let message: String
    init(_ code: String, _ message: String) { self.code = code; self.message = message }
    var errorDescription: String? { message }
}

enum GaoActionPackage {
    static let maximumManifestBytes = 1_048_576
    static let maximumItems = 256
    static let maximumPayloadBytes: Int64 = 2 * 1024 * 1024 * 1024
    static let maximumTTL: TimeInterval = 120
    typealias ActionValidator = (GaoActionManifest) throws -> Void
    static func iso8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; f.timeZone = TimeZone(secondsFromGMT: 0)
        return f.string(from: date)
    }
    static func randomNonce() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw error("randomUnavailable", "无法生成安全随机数") }
        return Data(bytes).base64EncodedString()
    }
    static func manifestData(_ manifest: GaoActionManifest) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(manifest)
    }
    static func validate(data: Data, targetBundleID: String, now: Date, validateAction: ActionValidator) throws -> GaoActionManifest {
        guard !data.isEmpty, data.count <= maximumManifestBytes else { throw error("manifestTooLarge", "交接清单超出 1 MiB 限制") }
        try GaoStrictJSON.validate(data)
        let raw: Any
        do { raw = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) } catch { throw Self.error("invalidJSON", "交接清单不是有效 JSON") }
        guard let object = raw as? [String: Any] else { throw error("invalidManifest", "交接清单必须是对象") }
        let common: Set<String> = ["schemaVersion", "kind", "requestID", "sourceBundleID", "targetBundleID", "action", "createdAt", "expiresAt", "nonce", "items", "references", "parameters"]
        let result: Set<String> = ["inReplyTo", "status", "errorCode", "provenance"]
        let kind = object["kind"] as? String
        guard kind == "request" || kind == "result" else { throw error("invalidKind", "不支持的交接类型") }
        guard Set(object.keys) == common.union(kind == "result" ? result : []) else { throw error("unknownField", "交接清单含缺失或不支持的字段") }
        guard let schema = object["schemaVersion"] as? NSNumber, CFGetTypeID(schema) != CFBooleanGetTypeID(), schema.doubleValue == 1 else { throw error("unsupportedSchema", "不支持的 GaoAction 版本") }
        try validateJSON(raw, depth: 0)
        guard let items = object["items"] as? [[String: Any]], let references = object["references"] as? [[String: Any]], object["parameters"] is [String: Any] else { throw error("invalidManifest", "交接项目或参数格式无效") }
        guard items.count + references.count <= maximumItems else { throw error("tooManyItems", "交接项目超过 256 项，请分批选择") }
        for item in items { guard Set(item.keys) == ["id", "relativePath", "uti", "byteCount", "sha256"] else { throw error("unknownItemField", "文件项目字段无效") } }
        for reference in references {
            let required: Set<String> = ["id", "kind", "fileURL", "displayName", "declaredIdentity"]
            guard required.isSubset(of: Set(reference.keys)), Set(reference.keys).isSubset(of: required.union(["bundleID", "sha256"])), let identity = reference["declaredIdentity"] as? [String: Any], Set(identity.keys) == ["volumeUUID", "device", "inode", "byteCount", "modifiedAt"] else { throw error("invalidReference", "原件引用字段无效") }
        }
        let manifest: GaoActionManifest
        do { manifest = try JSONDecoder().decode(GaoActionManifest.self, from: data) } catch { throw Self.error("invalidManifest", "交接清单字段类型无效") }
        guard UUID(uuidString: manifest.requestID) != nil, validBundleID(manifest.sourceBundleID), manifest.targetBundleID == targetBundleID, validBundleID(targetBundleID) else { throw error("invalidIdentity", "请求或目标应用标识无效") }
        guard manifest.action.utf8.count <= 128, manifest.action.range(of: #"^[a-z][A-Za-z0-9]*(\.[A-Za-z][A-Za-z0-9]*)+$"#, options: .regularExpression) != nil else { throw error("unknownAction", "不支持的动作") }
        guard let created = parseDate(manifest.createdAt), let expires = parseDate(manifest.expiresAt), expires > created, expires.timeIntervalSince(created) <= maximumTTL else { throw error("invalidTTL", "交接有效期必须在 120 秒以内") }
        guard now >= created else { throw error("futureRequest", "交接请求尚未生效") }
        guard now < expires else { throw error("expired", "交接请求已过期，请重新发送") }
        guard let nonce = Data(base64Encoded: manifest.nonce), nonce.count == 32, nonce.base64EncodedString() == manifest.nonce else { throw error("invalidNonce", "交接随机数无效") }
        if kind == "result" {
            guard let reply = manifest.inReplyTo, UUID(uuidString: reply) != nil, let status = manifest.status, ["pending", "completed", "partial", "cancelled", "failed", "unsupported"].contains(status), manifest.provenance != nil else { throw error("invalidResult", "结果状态或关联请求无效") }
            if let code = manifest.errorCode { guard validShortText(code, max: 256) else { throw error("invalidResult", "结果错误码无效") } }
        }
        var total: Int64 = 0; var identifiers = Set<String>(); var paths = Set<String>()
        for item in manifest.items {
            guard validShortText(item.id, max: 256), identifiers.insert(item.id).inserted, validShortText(item.uti, max: 256), item.byteCount >= 0, item.byteCount <= maximumPayloadBytes, validDigest(item.sha256) else { throw error("invalidItem", "文件项目标识、长度或摘要无效") }
            let normalized = try payloadComponents(item.relativePath).joined(separator: "/")
            guard paths.insert(normalized).inserted else { throw error("duplicatePath", "交接文件路径重复") }
            let sum = total.addingReportingOverflow(item.byteCount)
            guard !sum.overflow, sum.partialValue <= maximumPayloadBytes else { throw error("payloadTooLarge", "交接文件超过 2 GiB，请分批选择") }; total = sum.partialValue
        }
        for reference in manifest.references {
            guard validShortText(reference.id, max: 256), identifiers.insert(reference.id).inserted, ["file", "directory", "application"].contains(reference.kind), validShortText(reference.displayName, max: 1024), canonicalFileURL(reference.fileURL) else { throw error("invalidReference", "原件引用无效") }
            if reference.kind == "application" { guard let bundle = reference.bundleID, validBundleID(bundle) else { throw error("invalidReference", "应用引用缺少应用标识") } }
            else if reference.bundleID != nil { throw error("invalidReference", "非应用引用不能携带应用标识") }
            if let digest = reference.sha256 { guard reference.kind == "file", validDigest(digest) else { throw error("invalidReference", "原件摘要无效") } }
            if let size = reference.declaredIdentity.byteCount { guard size >= 0 else { throw error("invalidReference", "原件长度无效") } }
            if let date = reference.declaredIdentity.modifiedAt { guard parseDate(date) != nil else { throw error("invalidReference", "原件修改时间无效") } }
            if let volume = reference.declaredIdentity.volumeUUID { guard UUID(uuidString: volume) != nil else { throw error("invalidReference", "原件卷标识无效") } }
        }
        if manifest.action.hasPrefix("portal.") && (!manifest.items.isEmpty || !manifest.references.isEmpty) { throw error("unexpectedPayload", "网站动作不接受文件或原件引用") }
        try validateAction(manifest)
        return manifest
    }
    /// All payload reads use fixed descriptors; business code receives only validated private copies.
    static func receive(at packageURL: URL, stagingRoot: URL, targetBundleID: String, now: Date = Date(), validateAction: ActionValidator) throws -> GaoActionReceivedPackage {
        guard packageURL.pathExtension.lowercased() == "gaoaction" else { throw error("invalidPackage", "请选择 .gaoaction 交接包") }
        let source = try openAbsoluteDirectory(packageURL); defer { close(source) }; try requirePrivateDirectory(source); try requireRootEntries(source)
        let manifestFD = try openRegular(at: source, name: "manifest.json"); defer { close(manifestFD) }
        let before = try metadata(manifestFD)
        guard before.st_size > 0, before.st_size <= maximumManifestBytes else { throw error("manifestTooLarge", "交接清单超出 1 MiB 限制") }
        let data = try readBounded(manifestFD, limit: maximumManifestBytes); try requireUnchanged(before, try metadata(manifestFD))
        let manifest = try validate(data: data, targetBundleID: targetBundleID, now: now, validateAction: validateAction)
        let payload = try openDirectory(at: source, name: "payload"); defer { close(payload) }; try requirePrivateDirectory(payload); try verifyPayloadTree(payload, items: manifest.items)
        let root = try ensurePrivateDirectory(stagingRoot); defer { close(root) }
        let name = UUID().uuidString + ".gaoaction"
        guard mkdirat(root, name, 0o700) == 0 else { throw error("stagingUnavailable", "无法创建私有交接暂存") }
        let destinationURL = stagingRoot.appendingPathComponent(name, isDirectory: true)
        var success = false; defer { if !success { try? FileManager.default.removeItem(at: destinationURL) } }
        let destination = try openDirectory(at: root, name: name); defer { close(destination) }
        guard mkdirat(destination, "payload", 0o700) == 0 else { throw error("stagingUnavailable", "无法创建私有附件暂存") }
        let targetPayload = try openDirectory(at: destination, name: "payload"); defer { close(targetPayload) }
        for item in manifest.items { try copyItem(item, sourcePayload: payload, targetPayload: targetPayload) }
        try requireUnchanged(before, try metadata(manifestFD)); try writeFile(data, directory: destination, name: "manifest.json")
        guard fsync(destination) == 0 else { throw error("stagingUnavailable", "无法完成私有交接暂存") }; success = true
        return GaoActionReceivedPackage(manifest: manifest, packageURL: destinationURL, manifestSHA256: digest(data))
    }
    /// payloads maps item IDs to explicitly selected files. References are never read or copied.
    static func write(manifest: GaoActionManifest, to packageURL: URL, payloads: [String: URL] = [:], now: Date = Date(), validateAction: ActionValidator) throws -> URL {
        guard packageURL.pathExtension.lowercased() == "gaoaction" else { throw error("invalidPackage", "交接包文件名无效") }
        let data = try manifestData(manifest); _ = try validate(data: data, targetBundleID: manifest.targetBundleID, now: now, validateAction: validateAction)
        guard Set(payloads.keys) == Set(manifest.items.map(\.id)) else { throw error("invalidItem", "附件选择与交接清单不一致") }
        let root = try ensurePrivateDirectory(packageURL.deletingLastPathComponent()); defer { close(root) }
        let finalName = packageURL.lastPathComponent; var existing = stat()
        guard fstatat(root, finalName, &existing, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else { throw error("destinationExists", "同名交接包已存在") }
        let tempName = "." + UUID().uuidString + ".gaoaction"
        guard mkdirat(root, tempName, 0o700) == 0 else { throw error("stagingUnavailable", "无法创建私有发送包") }
        let tempURL = packageURL.deletingLastPathComponent().appendingPathComponent(tempName, isDirectory: true)
        var success = false; defer { if !success { try? FileManager.default.removeItem(at: tempURL) } }
        let destination = try openDirectory(at: root, name: tempName); defer { close(destination) }
        guard mkdirat(destination, "payload", 0o700) == 0 else { throw error("stagingUnavailable", "无法创建附件目录") }
        let targetPayload = try openDirectory(at: destination, name: "payload"); defer { close(targetPayload) }
        for item in manifest.items {
            guard let url = payloads[item.id], url.isFileURL else { throw error("invalidItem", "附件不是本机文件") }
            let parent = try openAbsoluteDirectory(url.deletingLastPathComponent()); defer { close(parent) }
            let source = try openRegular(at: parent, name: url.lastPathComponent, requirePrivate: false); defer { close(source) }; try copyDescriptor(source, item: item, targetPayload: targetPayload, requirePrivateSource: false)
        }
        try writeFile(data, directory: destination, name: "manifest.json")
        guard fsync(destination) == 0 else { throw error("stagingUnavailable", "无法完成发送包") }
        guard renameatx_np(root, tempName, root, finalName, UInt32(RENAME_EXCL)) == 0 else { throw error("destinationExists", "交接包发布失败或同名包已存在") }
        guard fsync(root) == 0 else { throw error("stagingUnavailable", "无法完成发送包目录") }; success = true
        return packageURL
    }
    private static func error(_ code: String, _ message: String) -> GaoActionPackageError { GaoActionPackageError(code, message) }
    private static func validShortText(_ text: String, max: Int) -> Bool { !text.isEmpty && text.utf8.count <= max && !text.unicodeScalars.contains { $0.value < 32 || $0.value == 127 } }
    private static func validBundleID(_ value: String) -> Bool { value.utf8.count <= 255 && value.range(of: #"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$"#, options: .regularExpression) != nil }
    private static func validDigest(_ value: String) -> Bool { value.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil }
    private static func parseDate(_ value: String) -> Date? {
        guard value.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,9})?Z$"#, options: .regularExpression) != nil else { return nil }
        let f = ISO8601DateFormatter(); f.formatOptions = value.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]; return f.date(from: value)
    }
    private static func canonicalFileURL(_ value: String) -> Bool {
        guard let url = URL(string: value), url.isFileURL, url.host == nil || url.host == "", url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, url.path.hasPrefix("/"), !url.path.contains("\0"), !url.pathComponents.contains(".."), !url.pathComponents.contains(".") else { return false }
        return URL(fileURLWithPath: url.path, isDirectory: value.hasSuffix("/")).absoluteString == value
    }
    /// V1 accepts input.txt or payload/input.txt; both resolve strictly below the payload FD.
    private static func payloadComponents(_ path: String) throws -> [String] {
        guard !path.isEmpty, path.utf8.count <= 4096, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0") else { throw error("invalidPath", "附件相对路径无效") }
        var parts = path.components(separatedBy: "/"); if parts.first == "payload" { parts.removeFirst() }
        guard !parts.isEmpty, parts.count <= 32, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 && !$0.unicodeScalars.contains { $0.value < 32 || $0.value == 127 } }) else { throw error("invalidPath", "附件相对路径越界") }; return parts
    }
    private static func validateJSON(_ value: Any, depth: Int) throws {
        guard depth <= 24 else { throw error("invalidJSON", "交接清单嵌套过深") }
        if let object = value as? [String: Any] {
            guard object.count <= 1024 else { throw error("invalidJSON", "交接对象过大") }; for (key, child) in object { guard key.utf8.count <= 256 else { throw error("invalidJSON", "交接字段过长") }; try validateJSON(child, depth: depth + 1) }
        } else if let array = value as? [Any] { guard array.count <= 1024 else { throw error("invalidJSON", "交接数组过大") }; for child in array { try validateJSON(child, depth: depth + 1) }
        } else if let text = value as? String { guard text.utf8.count <= maximumManifestBytes else { throw error("invalidJSON", "交接文本过大") }
        } else if let number = value as? NSNumber { guard number.doubleValue.isFinite else { throw error("invalidJSON", "交接数字无效") }
        } else if !(value is NSNull) { throw error("invalidJSON", "交接字段类型无效") }
    }
    private static func metadata(_ fd: Int32) throws -> stat { var s = stat(); guard fstat(fd, &s) == 0 else { throw error("unreadable", "无法核验交接文件") }; return s }
    private static func requirePrivateDirectory(_ fd: Int32) throws {
        let s = try metadata(fd); guard (s.st_mode & S_IFMT) == S_IFDIR, s.st_uid == getuid(), (s.st_mode & 0o077) == 0, (s.st_mode & 0o500) == 0o500 else { throw error("unsafePermissions", "交接目录必须归当前用户并仅允许本人访问") }
    }
    private static func requireRegular(_ fd: Int32, requirePrivate: Bool = true) throws -> stat {
        let s = try metadata(fd); guard (s.st_mode & S_IFMT) == S_IFREG, s.st_uid == getuid(), s.st_nlink == 1, (s.st_mode & 0o400) != 0, !requirePrivate || (s.st_mode & 0o077) == 0 else { throw error("unsafeFile", "交接文件须为本人可读的私有普通文件，不能是链接或目录") }; return s
    }
    private static func openRegular(at parent: Int32, name: String, requirePrivate: Bool = true) throws -> Int32 {
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC); guard fd >= 0 else { throw error("unreadable", "无法安全读取交接文件") }
        do { _ = try requireRegular(fd, requirePrivate: requirePrivate); return fd } catch { close(fd); throw error }
    }
    private static func openDirectory(at parent: Int32, name: String) throws -> Int32 {
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC); guard fd >= 0 else { throw error("unsafeDirectory", "交接目录不可读或包含链接") }; return fd
    }
    private static func absoluteComponents(_ url: URL) throws -> [String] {
        guard url.isFileURL, url.host == nil || url.host == "", url.query == nil, url.fragment == nil, url.path.hasPrefix("/"), !url.path.contains("\0") else { throw error("invalidPath", "交接位置须为本机目录") }
        let components = url.path.components(separatedBy: "/").filter { !$0.isEmpty }
        guard components.allSatisfy({ $0 != "." && $0 != ".." && $0.utf8.count <= 255 }) else { throw error("invalidPath", "交接目录路径无效") }; return components
    }
    private static func openAbsoluteDirectory(_ url: URL) throws -> Int32 {
        _ = try absoluteComponents(url)
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw error("unsafeDirectory", "交接目录不可读或包含链接") }
        return fd
    }
    private static func ensurePrivateDirectory(_ url: URL) throws -> Int32 {
        let components = try absoluteComponents(url); guard !components.isEmpty else { throw error("unsafePermissions", "不能使用系统根目录暂存交接") }
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
            do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
            catch { throw Self.error("stagingUnavailable", "无法创建私有交接目录") }
        }
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw error("unsafeDirectory", "交接目录包含链接或不可读") }
        do { try requirePrivateDirectory(fd); return fd } catch { close(fd); throw error }
    }
    private static func entries(_ fd: Int32) throws -> [String] {
        let copied = dup(fd); guard copied >= 0, let directory = fdopendir(copied) else { if copied >= 0 { close(copied) }; throw error("unreadable", "无法列出交接目录") }; defer { closedir(directory) }
        rewinddir(directory); var result: [String] = []; errno = 0
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) } }
            if name != "." && name != ".." { result.append(name) }; guard result.count <= maximumItems * 33 + 2 else { throw error("tooManyItems", "交接目录项目过多") }
        }
        guard errno == 0 else { throw error("unreadable", "交接目录读取失败") }; return result
    }
    private static func requireRootEntries(_ fd: Int32) throws { guard Set(try entries(fd)) == ["manifest.json", "payload"] else { throw error("unexpectedFile", "交接包只能包含清单及 payload 目录") } }
    private static func verifyPayloadTree(_ root: Int32, items: [GaoActionItem]) throws {
        let expected = Set(try items.map { try payloadComponents($0.relativePath).joined(separator: "/") }); var directories = Set<String>()
        for path in expected { let p = path.components(separatedBy: "/"); if p.count > 1 { for count in 1..<p.count { directories.insert(p.prefix(count).joined(separator: "/")) } } }
        var seen = Set<String>()
        func visit(_ fd: Int32, prefix: String, depth: Int) throws {
            guard depth <= 32 else { throw error("invalidPath", "附件目录过深") }
            for name in try entries(fd) {
                let path = prefix.isEmpty ? name : prefix + "/" + name; var s = stat()
                guard fstatat(fd, name, &s, AT_SYMLINK_NOFOLLOW) == 0 else { throw error("unreadable", "附件核验失败") }
                if (s.st_mode & S_IFMT) == S_IFDIR {
                    guard directories.contains(path) else { throw error("unexpectedFile", "附件存在未声明目录") }
                    let child = try openDirectory(at: fd, name: name); defer { close(child) }; try requirePrivateDirectory(child); try visit(child, prefix: path, depth: depth + 1)
                } else {
                    guard expected.contains(path) else { throw error("unexpectedFile", "附件存在未声明文件") }; let file = try openRegular(at: fd, name: name); defer { close(file) }; seen.insert(path)
                }
            }
        }
        try visit(root, prefix: "", depth: 0); guard seen == expected else { throw error("missingPayload", "附件缺失，请重新发送") }
    }
    private static func readBounded(_ fd: Int32, limit: Int) throws -> Data {
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = Darwin.read(fd, &buffer, buffer.count); if n < 0 { if errno == EINTR { continue }; throw error("unreadable", "交接文件读取失败") }; if n == 0 { return data }
            guard data.count <= limit - n else { throw error("manifestTooLarge", "交接清单超出限制") }; data.append(contentsOf: buffer.prefix(n))
        }
    }
    private static func requireUnchanged(_ a: stat, _ b: stat) throws {
        guard a.st_dev == b.st_dev, a.st_ino == b.st_ino, a.st_uid == b.st_uid, a.st_mode == b.st_mode, a.st_nlink == b.st_nlink, a.st_size == b.st_size, a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec, a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec, a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec, a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec else { throw error("sourceChanged", "交接源内容在复制期间发生变化，请重新发送") }
    }
    private static func copyItem(_ item: GaoActionItem, sourcePayload: Int32, targetPayload: Int32) throws {
        let parts = try payloadComponents(item.relativePath); var parent = dup(sourcePayload); guard parent >= 0 else { throw error("unreadable", "无法读取附件目录") }; defer { close(parent) }
        for part in parts.dropLast() { let next = try openDirectory(at: parent, name: part); do { try requirePrivateDirectory(next) } catch { close(next); throw error }; close(parent); parent = next }
        let source = try openRegular(at: parent, name: parts.last!); defer { close(source) }; try copyDescriptor(source, item: item, targetPayload: targetPayload)
    }
    private static func copyDescriptor(_ source: Int32, item: GaoActionItem, targetPayload: Int32, requirePrivateSource: Bool = true) throws {
        let before = try requireRegular(source, requirePrivate: requirePrivateSource); guard before.st_size == item.byteCount else { throw error("sizeMismatch", "附件长度与声明不符") }
        let parts = try payloadComponents(item.relativePath); var parent = dup(targetPayload); guard parent >= 0 else { throw error("stagingUnavailable", "无法创建附件副本") }; defer { close(parent) }
        for part in parts.dropLast() {
            guard mkdirat(parent, part, 0o700) == 0 || errno == EEXIST else { throw error("stagingUnavailable", "无法创建附件子目录") }
            let next = try openDirectory(at: parent, name: part); do { try requirePrivateDirectory(next) } catch { close(next); throw error }; close(parent); parent = next
        }
        let destination = openat(parent, parts.last!, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard destination >= 0 else { throw error("stagingUnavailable", "无法创建私有附件副本") }; defer { close(destination) }
        var hasher = SHA256(); var total: Int64 = 0; var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = Darwin.read(source, &buffer, buffer.count); if n < 0 { if errno == EINTR { continue }; throw error("unreadable", "附件复制读取失败") }; if n == 0 { break }
            total += Int64(n); guard total <= item.byteCount, total <= maximumPayloadBytes else { throw error("sourceChanged", "附件复制期间长度发生变化") }
            let chunk = Data(buffer.prefix(n)); hasher.update(data: chunk); try writeAll(chunk, fd: destination)
        }
        try requireUnchanged(before, try metadata(source))
        guard total == item.byteCount, hasher.finalize().map({ String(format: "%02x", $0) }).joined() == item.sha256 else { throw error("digestMismatch", "附件复制后摘要不一致，请重新发送") }
        guard fsync(destination) == 0 else { throw error("stagingUnavailable", "附件副本写入失败") }
        let copied = try metadata(destination); guard copied.st_size == item.byteCount, copied.st_uid == getuid(), copied.st_nlink == 1, (copied.st_mode & 0o077) == 0 else { throw error("stagingUnavailable", "附件副本核验失败") }
        guard lseek(destination, 0, SEEK_SET) == 0 else { throw error("stagingUnavailable", "无法复核附件副本") }
        var copiedHasher = SHA256(); var copiedCount: Int64 = 0
        while true {
            let n = Darwin.read(destination, &buffer, buffer.count)
            if n < 0 { if errno == EINTR { continue }; throw error("stagingUnavailable", "无法读取附件副本") }; if n == 0 { break }
            copiedCount += Int64(n); guard copiedCount <= item.byteCount else { throw error("sourceChanged", "附件副本内容发生变化") }
            copiedHasher.update(data: Data(buffer.prefix(n)))
        }
        try requireUnchanged(copied, try metadata(destination))
        guard copiedCount == item.byteCount, copiedHasher.finalize().map({ String(format: "%02x", $0) }).joined() == item.sha256 else { throw error("digestMismatch", "附件副本摘要核验失败") }
    }
    private static func writeFile(_ data: Data, directory: Int32, name: String) throws {
        let fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600); guard fd >= 0 else { throw error("stagingUnavailable", "无法写入私有交接清单") }; defer { close(fd) }
        try writeAll(data, fd: fd); guard fsync(fd) == 0 else { throw error("stagingUnavailable", "交接清单写入失败") }
    }
    private static func writeAll(_ data: Data, fd: Int32) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }; var offset = 0
            while offset < raw.count { let n = Darwin.write(fd, base.advanced(by: offset), raw.count - offset); if n < 0, errno == EINTR { continue }; guard n > 0 else { throw error("stagingUnavailable", "交接文件写入失败") }; offset += n }
        }
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

/// Reject duplicate (including escaped-equivalent) JSON keys before Foundation's last-value-wins parser.
private enum GaoStrictJSON {
    static func validate(_ data: Data) throws {
        var parser = Parser(bytes: Array(data)); try parser.value(depth: 0); parser.space()
        guard parser.index == parser.bytes.count else { throw parser.failure() }
    }
    private struct Parser {
        var bytes: [UInt8]; var index = 0
        func failure() -> GaoActionPackageError { GaoActionPackageError("invalidJSON", "交接 JSON 含重复字段或无效结构") }
        mutating func space() { while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
        mutating func consume(_ value: UInt8) -> Bool { space(); guard index < bytes.count, bytes[index] == value else { return false }; index += 1; return true }
        mutating func string() throws -> String {
            space(); guard index < bytes.count, bytes[index] == 34 else { throw failure() }; let start = index; index += 1
            while index < bytes.count {
                let c = bytes[index]; index += 1
                if c == 34 { guard let value = try? JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) else { throw failure() }; return value }
                if c == 92 { guard index < bytes.count else { throw failure() }; index += 1 }
                else if c < 32 { throw failure() }
            }
            throw failure()
        }
        mutating func value(depth: Int) throws {
            guard depth <= 24 else { throw failure() }; space(); guard index < bytes.count else { throw failure() }
            if bytes[index] == 123 {
                index += 1; if consume(125) { return }; var keys = Set<String>()
                while true {
                    let key = try string(); guard keys.insert(key).inserted, consume(58) else { throw failure() }; try value(depth: depth + 1)
                    if consume(125) { return }; guard consume(44) else { throw failure() }
                }
            }
            if bytes[index] == 91 {
                index += 1; if consume(93) { return }
                while true { try value(depth: depth + 1); if consume(93) { return }; guard consume(44) else { throw failure() } }
            }
            if bytes[index] == 34 { _ = try string(); return }
            let start = index
            while index < bytes.count, ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 }
            guard index > start else { throw failure() }
            let atom = Data(bytes[start..<index])
            guard (try? JSONSerialization.jsonObject(with: atom, options: [.fragmentsAllowed])) != nil else { throw failure() }
        }
    }
}
