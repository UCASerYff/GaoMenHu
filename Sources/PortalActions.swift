import Foundation
import Darwin
import CoreFoundation

/// Errors deliberately contain a code and fixed UI wording, never request URLs,
/// account details, profile paths, or arbitrary strings supplied by another app.
struct PortalActionError: LocalizedError, Equatable {
    let code: String
    let message: String
    var errorDescription: String? { message }

    static let invalidParameters = PortalActionError(code: "invalid_parameters", message: "交接参数无效或包含未支持的字段。")
    static let unsupportedAction = PortalActionError(code: "unsupported_action", message: "搞门户尚不支持这个交接动作。")
    static let invalidURL = PortalActionError(code: "invalid_url", message: "仅接受不含账号密码的完整 HTTP 或 HTTPS 网址。")
    static let siteNotFound = PortalActionError(code: "site_not_found", message: "交接引用的网站不存在，请重新选择。")
    static let workspaceNotFound = PortalActionError(code: "workspace_not_found", message: "交接引用的工作场景不存在或已变化。")
    static let invalidSite = PortalActionError(code: "invalid_site_configuration", message: "网站的浏览器、账号或登录范围配置无效，请先在搞门户检查。")
    static let browserNotAllowed = PortalActionError(code: "browser_not_allowed", message: "指定浏览器不在这个网站的允许列表中。")
    static let browserUnavailable = PortalActionError(code: "browser_unavailable", message: "指定或默认浏览器未安装，不能改用其他浏览器。")
    static let profileUnavailable = PortalActionError(code: "profile_unavailable", message: "指定浏览器资料尚未连接，请先打开该资料的搞门户助手。")
    static let profileAmbiguous = PortalActionError(code: "profile_ambiguous", message: "已连接多个浏览器资料，请先在搞门户绑定需要使用的资料。")
    static let insecureLoginScope = PortalActionError(code: "insecure_login_scope", message: "账号填充仅支持准确的 HTTPS 网站与登录域名，请先检查账号配置。")
    static let invalidLedger = PortalActionError(code: "invalid_request_ledger", message: "交接记录无法安全读取，已停止执行。原记录已保留，请检查后重试。")
    static let requestConflict = PortalActionError(code: "request_id_conflict", message: "这个请求编号已经用于不同内容，已拒绝重复执行。")
    static let invalidTransition = PortalActionError(code: "invalid_request_transition", message: "交接状态已经变化，不能再次执行。")
    static let ledgerFull = PortalActionError(code: "request_ledger_full", message: "交接记录已达到容量上限，请先检查已有交接。")
}

struct PortalRuntime {
    var installedBrowserIDs: Set<String>
    /// IDs are the existing helper's opaque profile tokens, never filesystem paths.
    var connectedProfiles: [String: Set<String>]
}

struct PortalSiteLaunch: Equatable {
    let siteID: String
    let browserID: String
    let profileID: String?
    let requiresAuthentication: Bool
}

struct PortalWorkspaceLaunch: Equatable {
    let workspaceID: String
    let sites: [PortalSiteLaunch]
}

struct PortalSiteProposal: Equatable {
    let url: String
    let title: String?
}

struct PortalDownloadURL: Equatable {
    let url: String
    let withoutQueryAndFragment: String
    /// Any query or fragment may contain private data. The receiver must show a
    /// review and offer the stripped URL before copying, exporting, or handing on.
    let requiresPrivacyReview: Bool
}

enum PortalActionPlan: Equatable {
    case openSite(PortalSiteLaunch)
    case openWorkspace(PortalWorkspaceLaunch)
    case focusSearch(String)
    case proposeSite(PortalSiteProposal)
    case prepareDownload([PortalDownloadURL])
}

enum PortalActionPlanner {
    static let actionNames: Set<String> = ["portal.openSite", "portal.openWorkspace", "portal.focusSearch", "portal.proposeSite", "portal.prepareDownload"]

    /// Parameter validation is useful before the receiver has loaded its library.
    /// Every listed action rejects all attachments, references, and unknown keys.
    static func validateParameters(action: String, parameters: [String: Any], itemCount: Int = 0, referenceCount: Int = 0) throws {
        guard itemCount == 0, referenceCount == 0 else { throw PortalActionError.invalidParameters }
        switch action {
        case "portal.openSite":
            try keys(parameters, required: ["siteID"], optional: ["browserID"])
            _ = try string(parameters, key: "siteID", maximum: 256, allowEmpty: false)
            if parameters["browserID"] != nil { _ = try string(parameters, key: "browserID", maximum: 64, allowEmpty: false) }
        case "portal.openWorkspace":
            try keys(parameters, required: ["workspaceID"], optional: [])
            _ = try string(parameters, key: "workspaceID", maximum: 256, allowEmpty: false)
        case "portal.focusSearch":
            try keys(parameters, required: [], optional: ["query"])
            if parameters["query"] != nil { _ = try string(parameters, key: "query", maximum: 4096, allowEmpty: true) }
        case "portal.proposeSite":
            try keys(parameters, required: ["url"], optional: ["title"])
            _ = try checkedURL(try string(parameters, key: "url", maximum: 8191, allowEmpty: false))
            if parameters["title"] != nil { _ = try string(parameters, key: "title", maximum: 256, allowEmpty: true) }
        case "portal.prepareDownload":
            try keys(parameters, required: ["urls"], optional: [])
            guard let urls = parameters["urls"] as? [String], !urls.isEmpty, urls.count <= 32 else { throw PortalActionError.invalidParameters }
            for url in urls { _ = try checkedURL(url) }
        default: throw PortalActionError.unsupportedAction
        }
    }

    static func plan(action: String, parameters: [String: Any], itemCount: Int = 0, referenceCount: Int = 0,
                     library: Library, runtime: PortalRuntime) throws -> PortalActionPlan {
        try validateParameters(action: action, parameters: parameters, itemCount: itemCount, referenceCount: referenceCount)
        switch action {
        case "portal.openSite":
            guard let site = uniqueSite(parameters["siteID"] as! String, in: library) else { throw PortalActionError.siteNotFound }
            return .openSite(try siteLaunch(site, browserID: parameters["browserID"] as? String, runtime: runtime))
        case "portal.openWorkspace":
            let id = parameters["workspaceID"] as! String
            let matches = (library.workspaces ?? []).filter { $0.id == id }
            guard matches.count == 1, let group = matches.first, !group.siteIDs.isEmpty, group.siteIDs.count <= 20,
                  Set(group.siteIDs).count == group.siteIDs.count else { throw PortalActionError.workspaceNotFound }
            let launches = try group.siteIDs.map { id -> PortalSiteLaunch in
                guard let site = uniqueSite(id, in: library) else { throw PortalActionError.workspaceNotFound }
                return try siteLaunch(site, browserID: nil, runtime: runtime)
            }
            return .openWorkspace(PortalWorkspaceLaunch(workspaceID: id, sites: launches))
        case "portal.focusSearch": return .focusSearch(parameters["query"] as? String ?? "")
        case "portal.proposeSite": return .proposeSite(PortalSiteProposal(url: parameters["url"] as! String, title: parameters["title"] as? String))
        case "portal.prepareDownload":
            return .prepareDownload(try (parameters["urls"] as! [String]).map { raw in
                let url = try checkedURL(raw)
                var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
                let review = components.query != nil || components.fragment != nil
                components.query = nil; components.fragment = nil
                return PortalDownloadURL(url: url.absoluteString, withoutQueryAndFragment: components.url!.absoluteString, requiresPrivacyReview: review)
            })
        default: throw PortalActionError.unsupportedAction
        }
    }

    static func siteLaunch(_ site: Website, browserID requestedBrowser: String?, runtime: PortalRuntime) throws -> PortalSiteLaunch {
        let known = Set(Browser.catalog.map(\.id))
        guard !site.allowedBrowsers.isEmpty, Set(site.allowedBrowsers).isSubset(of: known),
              site.allowedBrowsers.contains(site.defaultBrowser), (try? checkedURL(site.url)) != nil,
              site.defaultAccount == nil || site.accounts.filter({ $0.id == site.defaultAccount }).count == 1,
              site.accounts.allSatisfy({ $0.loginHosts.allSatisfy { normalizedHost($0) != nil } }) else { throw PortalActionError.invalidSite }
        let browserID = requestedBrowser ?? site.defaultBrowser
        guard known.contains(browserID), site.allowedBrowsers.contains(browserID) else { throw PortalActionError.browserNotAllowed }
        guard runtime.installedBrowserIDs.contains(browserID) else { throw PortalActionError.browserUnavailable }
        let profile = site.profiles[browserID].flatMap { $0.isEmpty ? nil : $0 }
        let connected = runtime.connectedProfiles[browserID] ?? []
        if let profile, !connected.contains(profile) { throw PortalActionError.profileUnavailable }
        if profile == nil, connected.count > 1 { throw PortalActionError.profileAmbiguous }
        let selectedAccount = site.accounts.first { $0.id == site.defaultAccount }
        if let selectedAccount, selectedAccount.hasPassword {
            guard (try? checkedURL(site.url))?.scheme?.lowercased() == "https",
                  selectedAccount.loginHosts.allSatisfy({ raw in
                      !raw.contains("://") || URLComponents(string: raw)?.scheme?.lowercased() == "https"
                  }) else { throw PortalActionError.insecureLoginScope }
        }
        return PortalSiteLaunch(siteID: site.id, browserID: browserID, profileID: profile ?? connected.first,
                                requiresAuthentication: selectedAccount?.hasPassword == true)
    }

    static func checkedURL(_ raw: String) throws -> URL {
        guard !raw.isEmpty, raw.count < 8192, raw.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
              validPercentEscapes(raw), let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty, !host.contains("*"), !host.contains("\\"),
              components.user == nil, components.password == nil,
              components.port == nil || (1...65535).contains(components.port!), let url = components.url,
              validWebURL(url.absoluteString) != nil else { throw PortalActionError.invalidURL }
        return url
    }

    private static func uniqueSite(_ id: String, in library: Library) -> Website? {
        let matches = library.sites.filter { $0.id == id }
        return matches.count == 1 ? matches.first : nil
    }
    private static func keys(_ parameters: [String: Any], required: Set<String>, optional: Set<String>) throws {
        let actual = Set(parameters.keys)
        guard required.isSubset(of: actual), actual.isSubset(of: required.union(optional)) else { throw PortalActionError.invalidParameters }
    }
    private static func string(_ parameters: [String: Any], key: String, maximum: Int, allowEmpty: Bool) throws -> String {
        guard let value = parameters[key] as? String, value.count <= maximum, !value.contains("\0"),
              allowEmpty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PortalActionError.invalidParameters }
        return value
    }
    private static func validPercentEscapes(_ string: String) -> Bool {
        let bytes = Array(string.utf8)
        func hex(_ byte: UInt8) -> Bool { (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte) }
        for index in bytes.indices where bytes[index] == 37 {
            if index + 2 >= bytes.count || !hex(bytes[index + 1]) || !hex(bytes[index + 2]) { return false }
        }
        return true
    }
}

/// Explicit consent is represented by the selected ID set; an empty set exports
/// nothing. No URL, account, username, profile, usage, or remote icon is included.
struct UserExposedSiteCatalog: Codable, Equatable {
    struct Entry: Codable, Equatable { let siteID: String; let displayName: String }
    let schemaVersion: Int
    let sites: [Entry]

    init(library: Library, authorizedSiteIDs: Set<String>) throws {
        guard authorizedSiteIDs.isSubset(of: Set(library.sites.map(\.id))),
              Set(library.sites.map(\.id)).count == library.sites.count else { throw PortalActionError.siteNotFound }
        schemaVersion = 1
        sites = library.sites.filter { authorizedSiteIDs.contains($0.id) }.map { Entry(siteID: $0.id, displayName: $0.name) }
    }
}

struct PortalDownloadProviderCapability: Equatable {
    static let bundleID = "com.gaoseries.GaoXiaZai"
    let appVersion: String
    let supportedMediaTypes: Set<String>

    /// Only the fixed V1 schema shape is consumed. A claimed bundle ID is not
    /// sender authentication; the caller also resolves the actual installed app
    /// by this exact identifier and reads its bundled capability resource.
    static func validated(data: Data, installedBundleID: String) throws -> Self {
        guard installedBundleID == bundleID, data.count <= 1_048_576,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == ["schemaVersion", "bundleID", "appVersion", "actions"],
              integer(root["schemaVersion"]) == 1, root["bundleID"] as? String == bundleID,
              let version = root["appVersion"] as? String, !version.isEmpty, version.count <= 64,
              version.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }),
              let actions = root["actions"] as? [[String: Any]], !actions.isEmpty, actions.count <= 64,
              Set(actions.compactMap { $0["action"] as? String }).count == actions.count,
              let action = actions.first(where: { $0["action"] as? String == "downloads.prepare" }),
              Set(action.keys) == ["action", "parameters", "items", "references"],
              zeroItems(action["items"]), zeroItems(action["references"]),
              let parameters = action["parameters"] as? [String: Any],
              Set(parameters.keys) == ["type", "properties", "required", "additionalProperties"],
              parameters["type"] as? String == "object", boolean(parameters["additionalProperties"]) == false,
              parameters["required"] as? [String] == ["urls"],
              let properties = parameters["properties"] as? [String: Any],
              Set(properties.keys).isSubset(of: ["urls", "mediaType"]),
              let urls = properties["urls"] as? [String: Any],
              Set(urls.keys) == ["type", "minItems", "maxItems", "items"],
              urls["type"] as? String == "array", integer(urls["minItems"]) == 1,
              integer(urls["maxItems"]) == 32,
              let urlItem = urls["items"] as? [String: Any], urlItem["type"] as? String == "string",
              Set(urlItem.keys).isSubset(of: ["type", "format"]),
              urlItem["format"] == nil || urlItem["format"] as? String == "uri" else { throw incompatible }
        var media: Set<String> = []
        if let raw = properties["mediaType"] {
            guard let field = raw as? [String: Any], Set(field.keys) == ["type", "enum"], field["type"] as? String == "string",
                  let values = field["enum"] as? [String], !values.isEmpty,
                  Set(values).count == values.count, Set(values).isSubset(of: ["file", "video", "audio", "image", "subtitle"]) else { throw incompatible }
            media = Set(values)
        }
        return Self(appVersion: version, supportedMediaTypes: media)
    }

    static let incompatible = PortalActionError(code: "download_provider_incompatible", message: "已安装的搞下载未声明兼容的下载复核能力，不能交接。")
    static let unavailable = PortalActionError(code: "download_provider_unavailable", message: "尚未安装支持交接的搞下载。可复核并复制本次选择的普通网址，或用浏览器打开。")
    private static func zeroItems(_ raw: Any?) -> Bool {
        guard let field = raw as? [String: Any], Set(field.keys) == ["maxCount"] else { return false }
        return integer(field["maxCount"]) == 0
    }
    private static func integer(_ raw: Any?) -> Int? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded(.towardZero) == number.doubleValue else { return nil }
        return Int(exactly: number.doubleValue)
    }
    private static func boolean(_ raw: Any?) -> Bool? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
}

enum PortalRequestState: String, Codable { case received, approved, executing, completed, cancelled, failed }
enum PortalResultStatus: String, Codable { case pending, completed, partial, cancelled, failed, unsupported }
enum PortalWorkflowState: String, Codable { case awaitingUser, accepted, opened, cancelled, failed, unsupported, handedOff }

struct PortalSiteOutcome: Codable, Equatable {
    let siteID: String
    let workflowState: PortalWorkflowState
    let errorCode: String?
}

struct PortalActionOutcome: Codable, Equatable {
    let status: PortalResultStatus
    let workflowState: PortalWorkflowState
    var errorCode: String? = nil
    var sites: [PortalSiteOutcome]? = nil

    static var awaitingUser: Self { Self(status: .pending, workflowState: .awaitingUser) }
    static var cancelled: Self { Self(status: .cancelled, workflowState: .cancelled) }
    static func failed(_ code: String) -> Self { Self(status: .failed, workflowState: .failed, errorCode: code) }

    /// Opening an ordinary site means it was handed to the chosen browser, never
    /// that login succeeded. Pending helper work stays pending in partial groups.
    static func workspace(_ outcomes: [PortalSiteOutcome]) -> Self {
        guard !outcomes.isEmpty else { return .failed("workspace_empty") }
        let opened = outcomes.filter { $0.workflowState == .opened }.count
        let accepted = outcomes.filter { $0.workflowState == .accepted || $0.workflowState == .awaitingUser }.count
        let cancelled = outcomes.filter { $0.workflowState == .cancelled }.count
        if opened == outcomes.count { return Self(status: .completed, workflowState: .opened, sites: outcomes) }
        if cancelled == outcomes.count { return Self(status: .cancelled, workflowState: .cancelled, sites: outcomes) }
        if accepted == outcomes.count { return Self(status: .pending, workflowState: .accepted, sites: outcomes) }
        if opened > 0 || accepted > 0 { return Self(status: .partial, workflowState: accepted > 0 ? .accepted : .opened, sites: outcomes) }
        return Self(status: .failed, workflowState: .failed, errorCode: "workspace_failed", sites: outcomes)
    }
}

struct PortalRequestRecord: Codable, Equatable {
    let requestID: String
    let fingerprint: String
    let action: String
    var state: PortalRequestState
    let receivedAt: Date
    var updatedAt: Date
    var outcome: PortalActionOutcome
}

enum PortalRequestReceipt { case new(PortalRequestRecord), repeated(PortalRequestRecord) }

/// Private, bounded idempotency journal. This stores hashes and safe result codes,
/// never full manifests, URL/query text, account data, or browser profile tokens.
/// The caller serializes access on its main queue and calls beginExecution before
/// any side effect. An executing entry recovered after a crash is never replayed.
final class PortalRequestLedger {
    private struct Envelope: Codable { let schemaVersion: Int; var records: [PortalRequestRecord] }
    let directory: URL
    let file: URL
    private var records: [String: PortalRequestRecord]
    static let maximumRecords = 10_000

    init(directory: URL, now: Date = Date()) throws {
        self.directory = directory
        file = directory.appendingPathComponent("requests.json")
        records = [:]
        try Self.ensureDirectory(directory)
        var info = stat()
        if lstat(file.path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1,
                  info.st_size <= 16 * 1_048_576, (info.st_mode & 0o077) == 0 else { throw PortalActionError.invalidLedger }
            let handle = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard handle >= 0 else { throw PortalActionError.invalidLedger }
            defer { close(handle) }
            var opened = stat()
            guard fstat(handle, &opened) == 0, opened.st_ino == info.st_ino, opened.st_dev == info.st_dev,
                  opened.st_size == info.st_size else { throw PortalActionError.invalidLedger }
            var data = Data(count: Int(opened.st_size))
            let count = data.withUnsafeMutableBytes { buffer in Darwin.read(handle, buffer.baseAddress, buffer.count) }
            guard count == data.count, let decoded = try? JSONDecoder().decode(Envelope.self, from: data),
                  decoded.schemaVersion == 1, decoded.records.count <= Self.maximumRecords else { throw PortalActionError.invalidLedger }
            for record in decoded.records {
                guard Self.valid(record), records[record.requestID] == nil else { throw PortalActionError.invalidLedger }
                records[record.requestID] = record
            }
        } else if errno != ENOENT { throw PortalActionError.invalidLedger }
        var recovered = false
        for id in Array(records.keys) where records[id]?.state == .executing {
            records[id]?.state = .failed; records[id]?.updatedAt = now
            records[id]?.outcome = .failed("interrupted_execution")
            recovered = true
        }
        if recovered { try persist(records) }
    }

    func record(requestID: String) -> PortalRequestRecord? { records[requestID.lowercased()] }
    var allRecords: [PortalRequestRecord] { records.values.sorted { $0.receivedAt > $1.receivedAt } }

    func receive(requestID: String, fingerprint: String, action: String, now: Date = Date()) throws -> PortalRequestReceipt {
        let id = requestID.lowercased()
        guard UUID(uuidString: id) != nil, Self.isSHA256(fingerprint), PortalActionPlanner.actionNames.contains(action), now.timeIntervalSince1970.isFinite else { throw PortalActionError.invalidParameters }
        if let existing = records[id] {
            guard existing.fingerprint == fingerprint, existing.action == action else { throw PortalActionError.requestConflict }
            return .repeated(existing)
        }
        guard records.count < Self.maximumRecords else { throw PortalActionError.ledgerFull }
        let next = PortalRequestRecord(requestID: id, fingerprint: fingerprint, action: action, state: .received,
                                       receivedAt: now, updatedAt: now, outcome: .awaitingUser)
        var updated = records; updated[id] = next
        try persist(updated); records = updated
        return .new(next)
    }

    /// Call only after the visible, specific confirmation. Repeated approved or
    /// received entries are displayed as records; they do not grant a new run.
    @discardableResult func approve(requestID: String, now: Date = Date()) throws -> PortalRequestRecord {
        try transition(requestID, from: [.received], to: .approved, outcome: .awaitingUser, now: now)
    }
    @discardableResult func beginExecution(requestID: String, now: Date = Date()) throws -> PortalRequestRecord {
        try transition(requestID, from: [.approved], to: .executing,
                       outcome: PortalActionOutcome(status: .pending, workflowState: .accepted), now: now)
    }
    @discardableResult func markAwaitingUser(requestID: String, now: Date = Date()) throws -> PortalRequestRecord {
        try transition(requestID, from: [.executing], to: .executing, outcome: .awaitingUser, now: now)
    }
    @discardableResult func finish(requestID: String, outcome: PortalActionOutcome, now: Date = Date()) throws -> PortalRequestRecord {
        let state: PortalRequestState
        switch outcome.status {
        case .cancelled: state = .cancelled
        case .failed, .unsupported: state = .failed
        case .completed, .partial, .pending: state = .completed // terminal dispatch, even when downstream work is pending
        }
        return try transition(requestID, from: [.executing], to: state, outcome: outcome, now: now)
    }
    @discardableResult func cancel(requestID: String, now: Date = Date()) throws -> PortalRequestRecord {
        try transition(requestID, from: [.received, .approved], to: .cancelled, outcome: .cancelled, now: now)
    }
    @discardableResult func fail(requestID: String, code: String, now: Date = Date()) throws -> PortalRequestRecord {
        try transition(requestID, from: [.received, .approved, .executing], to: .failed, outcome: .failed(code), now: now)
    }

    private func transition(_ id: String, from: Set<PortalRequestState>, to: PortalRequestState, outcome: PortalActionOutcome, now: Date) throws -> PortalRequestRecord {
        let key = id.lowercased()
        guard var record = records[key], from.contains(record.state), now.timeIntervalSince1970.isFinite,
              now >= record.receivedAt, Self.validOutcome(outcome) else { throw PortalActionError.invalidTransition }
        record.state = to; record.updatedAt = now; record.outcome = outcome
        var updated = records; updated[key] = record
        try persist(updated); records = updated
        return record
    }

    private func persist(_ value: [String: PortalRequestRecord]) throws {
        try Self.ensureDirectory(directory)
        if FileManager.default.fileExists(atPath: file.path) {
            var info = stat()
            guard lstat(file.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(),
                  info.st_nlink == 1, (info.st_mode & 0o077) == 0 else { throw PortalActionError.invalidLedger }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Envelope(schemaVersion: 1, records: value.values.sorted { $0.requestID < $1.requestID }))
        guard data.count <= 16 * 1_048_576 else { throw PortalActionError.ledgerFull }
        let staging = directory.appendingPathComponent(".requests-" + UUID().uuidString)
        let descriptor = open(staging.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw PortalActionError.invalidLedger }
        defer { close(descriptor); try? FileManager.default.removeItem(at: staging) }
        var offset = 0
        try data.withUnsafeBytes { bytes in
            while offset < bytes.count {
                let written = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw PortalActionError.invalidLedger }
                offset += written
            }
        }
        guard fsync(descriptor) == 0, rename(staging.path, file.path) == 0 else { throw PortalActionError.invalidLedger }
        let directoryDescriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryDescriptor >= 0 else { throw PortalActionError.invalidLedger }
        defer { close(directoryDescriptor) }
        guard fsync(directoryDescriptor) == 0 else { throw PortalActionError.invalidLedger }
    }

    private static func ensureDirectory(_ directory: URL) throws {
        // Reject symlinks in every existing ancestor, not only the final component.
        // Keep the actual absolute spelling: on macOS standardizedFileURL can
        // abbreviate an existing /private/tmp path through the /tmp symlink.
        var cursor = directory
        while cursor.path != "/" {
            var info = stat()
            if lstat(cursor.path, &info) == 0 {
                guard (info.st_mode & S_IFMT) == S_IFDIR else { throw PortalActionError.invalidLedger }
            } else if errno != ENOENT { throw PortalActionError.invalidLedger }
            cursor.deleteLastPathComponent()
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_uid == getuid(), (info.st_mode & 0o077) == 0 else { throw PortalActionError.invalidLedger }
    }

    private static func valid(_ record: PortalRequestRecord) -> Bool {
        UUID(uuidString: record.requestID) != nil && record.requestID == record.requestID.lowercased() && isSHA256(record.fingerprint)
        && PortalActionPlanner.actionNames.contains(record.action) && record.receivedAt.timeIntervalSince1970.isFinite
        && record.updatedAt.timeIntervalSince1970.isFinite && record.updatedAt >= record.receivedAt && validOutcome(record.outcome)
    }
    private static func validOutcome(_ outcome: PortalActionOutcome) -> Bool {
        func code(_ value: String?) -> Bool {
            guard let value else { return true }
            return !value.isEmpty && value.utf8.count <= 80 && value.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }
        }
        return code(outcome.errorCode) && (outcome.sites?.count ?? 0) <= 20
            && (outcome.sites ?? []).allSatisfy { !$0.siteID.isEmpty && $0.siteID.count <= 256 && code($0.errorCode) }
    }
    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
