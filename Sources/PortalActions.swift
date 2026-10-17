import Foundation
import Darwin
import CoreFoundation
import CryptoKit

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

/// This evidence must live outside MenDao, Exchange, and Journal. Deleting an
/// exchange folder must never make an old UUID look like a first installation.
/// Tests inject an isolated store and never read or write the real preferences.
protocol PortalLedgerEvidenceStore {
    func read() throws -> Data?
    func write(_ data: Data) throws
}

final class PortalLedgerPreferencesEvidence: PortalLedgerEvidenceStore {
    private let defaults: UserDefaults
    private let key = "GaoMenHu.PortalRequestLedgerEvidence.v1"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func read() throws -> Data? {
        guard defaults.synchronize() else { throw PortalActionError.invalidLedger }
        guard let object = defaults.object(forKey: key) else { return nil }
        guard let data = object as? Data else { throw PortalActionError.invalidLedger }
        return data
    }
    func write(_ data: Data) throws {
        defaults.set(data, forKey: key)
        guard defaults.synchronize(), defaults.data(forKey: key) == data else { throw PortalActionError.invalidLedger }
    }
}

/// Private, bounded idempotency journal. A separate, durable generation and digest
/// fence covers initialization, schema migration, every write, and crash recovery.
/// An unfinished transaction blocks reception; it never creates an empty history.
/// All source accesses are relative to a checked directory FD. The caller still
/// serializes access on its main queue and persists beginExecution before effects.
final class PortalRequestLedger {
    private struct Envelope: Codable {
        let schemaVersion: Int
        let ledgerID: String?
        let generation: UInt64?
        var records: [PortalRequestRecord]
    }
    private struct Evidence: Codable, Equatable {
        let schemaVersion: Int
        let ledgerID: String
        let generation: UInt64
        let phase: String
        let ledgerSHA256: String
    }
    let directory: URL
    let file: URL
    private let evidence: PortalLedgerEvidenceStore
    /// Deterministic, isolated fault injection. No request or external parameter
    /// can install a checkpoint, and production callers always use the nil default.
    private let checkpoint: ((String) throws -> Void)?
    private var records: [String: PortalRequestRecord] = [:]
    private var directoryFD: Int32 = -1
    private var expected: Evidence?
    private var usable = true
    static let maximumRecords = 10_000
    private static let maximumBytes = 16 * 1_048_576

    init(directory: URL, now: Date = Date(), evidence: PortalLedgerEvidenceStore = PortalLedgerPreferencesEvidence(),
         checkpoint: ((String) throws -> Void)? = nil) throws {
        self.directory = directory
        file = directory.appendingPathComponent("requests.json")
        self.evidence = evidence
        self.checkpoint = checkpoint
        var initialized = false
        defer { if !initialized, directoryFD >= 0 { close(directoryFD); directoryFD = -1 } }
        do {
            guard now.timeIntervalSince1970.isFinite else { throw PortalActionError.invalidLedger }
            let external = try evidence.read().map(Self.decodeEvidence)
            directoryFD = try Self.openDirectory(directory, create: false) ?? -1
            if let external {
                // Neither pending evidence nor missing folders/files can restart
                // initialization. Even a matching staged file needs explicit repair.
                guard external.phase == "ready", directoryFD >= 0 else { throw PortalActionError.invalidLedger }
                let data = try readFile()
                let decoded = try Self.decodeEnvelope(data)
                guard decoded.schemaVersion == 2, decoded.ledgerID == external.ledgerID,
                      decoded.generation == external.generation, Self.digest(data) == external.ledgerSHA256 else { throw PortalActionError.invalidLedger }
                records = try Self.validatedRecords(decoded.records)
                expected = external
                try requireCurrent()
            } else if directoryFD >= 0, try Self.entryExists(directoryFD, "requests.json") {
                // A valid V1 ledger is the only supported evidence-less migration.
                // A V2 file without its independent fence is not a fresh install.
                let data = try readFile()
                let decoded = try Self.decodeEnvelope(data)
                guard decoded.schemaVersion == 1 else { throw PortalActionError.invalidLedger }
                records = try Self.validatedRecords(decoded.records)
                let id = UUID().uuidString.lowercased()
                expected = Evidence(schemaVersion: 1, ledgerID: id, generation: 0, phase: "legacy", ledgerSHA256: Self.digest(data))
                interruptExecuting(now: now)
                try persist(records, operation: "migration", initializing: true)
            } else {
                // Even an empty existing V1 directory is ambiguous: it is
                // indistinguishable from a completed ledger whose file was lost.
                // Only an absent journal with no evidence/artifacts is first use.
                guard directoryFD < 0 else { throw PortalActionError.invalidLedger }
                try Self.rejectPriorExchangeArtifacts(directory)
                expected = Evidence(schemaVersion: 1, ledgerID: UUID().uuidString.lowercased(), generation: 0,
                                    phase: "new", ledgerSHA256: String(repeating: "0", count: 64))
                try persist([:], operation: "initialization", initializing: true)
            }
            if records.values.contains(where: { $0.state == .executing }) {
                var recovered = records
                for id in Array(recovered.keys) where recovered[id]?.state == .executing {
                    var record = recovered[id]!
                    record.state = .failed; record.updatedAt = max(now, record.updatedAt)
                    record.outcome = .failed("interrupted_execution"); recovered[id] = record
                }
                try persist(recovered, operation: "recovery"); records = recovered
            }
            initialized = true
        } catch {
            usable = false
            throw PortalActionError.invalidLedger
        }
    }

    deinit { if directoryFD >= 0 { close(directoryFD) } }

    func verifyAvailability() throws { try requireCurrent() }

    func record(requestID: String) -> PortalRequestRecord? {
        guard (try? requireCurrent()) != nil else { return nil }
        return records[requestID.lowercased()]
    }
    var allRecords: [PortalRequestRecord] {
        guard (try? requireCurrent()) != nil else { return [] }
        return records.values.sorted { $0.receivedAt > $1.receivedAt }
    }

    func receive(requestID: String, fingerprint: String, action: String, now: Date = Date()) throws -> PortalRequestReceipt {
        try requireCurrent()
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

    /// Repeated approved or received records never grant an additional execution.
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
        try requireCurrent()
        let key = id.lowercased()
        guard var record = records[key], from.contains(record.state), now.timeIntervalSince1970.isFinite,
              now >= record.updatedAt, Self.validOutcome(outcome) else { throw PortalActionError.invalidTransition }
        record.state = to; record.updatedAt = now; record.outcome = outcome
        guard Self.valid(record) else { throw PortalActionError.invalidTransition }
        var updated = records; updated[key] = record
        try persist(updated); records = updated
        return record
    }

    private func interruptExecuting(now: Date) {
        for id in Array(records.keys) where records[id]?.state == .executing {
            var record = records[id]!
            record.state = .failed; record.updatedAt = max(now, record.updatedAt)
            record.outcome = .failed("interrupted_execution"); records[id] = record
        }
    }

    private func requireCurrent() throws {
        do {
            guard usable, let expected, expected.phase == "ready", directoryFD >= 0,
                  let current = try evidence.read().map(Self.decodeEvidence), current == expected else { throw PortalActionError.invalidLedger }
            try requireDirectoryIdentity()
            guard Self.digest(try readFile()) == expected.ledgerSHA256 else { throw PortalActionError.invalidLedger }
        } catch {
            usable = false
            throw PortalActionError.invalidLedger
        }
    }

    private func persist(_ value: [String: PortalRequestRecord], operation: String = "write", initializing: Bool = false) throws {
        var locked = false
        defer { if locked { flock(directoryFD, LOCK_UN) } }
        do {
            guard usable, let previous = expected, previous.generation < UInt64.max else { throw PortalActionError.invalidLedger }
            if directoryFD >= 0 {
                guard flock(directoryFD, LOCK_EX | LOCK_NB) == 0 else { throw PortalActionError.invalidLedger }
                locked = true
            }
            if !initializing { try requireCurrent() }
            else if previous.phase == "legacy" {
                guard try evidence.read() == nil else { throw PortalActionError.invalidLedger }
                try requireDirectoryIdentity()
                guard Self.digest(try readFile()) == previous.ledgerSHA256 else { throw PortalActionError.invalidLedger }
            } else {
                guard previous.phase == "new", try evidence.read() == nil else { throw PortalActionError.invalidLedger }
                if directoryFD >= 0, try Self.hasEntries(directoryFD) { throw PortalActionError.invalidLedger }
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(Envelope(schemaVersion: 2, ledgerID: previous.ledgerID,
                generation: previous.generation + 1, records: value.values.sorted { $0.requestID < $1.requestID }))
            guard data.count <= Self.maximumBytes else { throw PortalActionError.ledgerFull }
            let pending = Evidence(schemaVersion: 1, ledgerID: previous.ledgerID, generation: previous.generation + 1,
                                   phase: operation, ledgerSHA256: Self.digest(data))
            try saveEvidence(pending)
            try checkpoint?(operation + ".prepared")
            if directoryFD < 0 { directoryFD = try Self.openDirectory(directory, create: true) ?? -1 }
            if !locked {
                guard directoryFD >= 0, flock(directoryFD, LOCK_EX | LOCK_NB) == 0 else { throw PortalActionError.invalidLedger }
                locked = true
            }
            guard let currentFence = try evidence.read().map(Self.decodeEvidence), currentFence == pending else { throw PortalActionError.invalidLedger }
            try requireDirectoryIdentity()
            let staging = ".requests-" + UUID().uuidString.lowercased()
            let descriptor = openat(directoryFD, staging, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw PortalActionError.invalidLedger }
            defer { close(descriptor); unlinkat(directoryFD, staging, 0) }
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if written < 0 && errno == EINTR { continue }
                    guard written > 0 else { throw PortalActionError.invalidLedger }
                    offset += written
                }
            }
            guard fsync(descriptor) == 0 else { throw PortalActionError.invalidLedger }
            try checkpoint?(operation + ".staged")
            try requireDirectoryIdentity()
            if previous.phase == "new" {
                guard !(try Self.entryExists(directoryFD, "requests.json")) else { throw PortalActionError.invalidLedger }
            } else {
                guard Self.digest(try readFile()) == previous.ledgerSHA256 else { throw PortalActionError.invalidLedger }
            }
            guard renameat(directoryFD, staging, directoryFD, "requests.json") == 0 else { throw PortalActionError.invalidLedger }
            try checkpoint?(operation + ".renamed")
            guard fsync(directoryFD) == 0 else { throw PortalActionError.invalidLedger }
            try checkpoint?(operation + ".synced")
            try requireDirectoryIdentity()
            guard try readFile() == data else { throw PortalActionError.invalidLedger }
            let ready = Evidence(schemaVersion: pending.schemaVersion, ledgerID: pending.ledgerID,
                                 generation: pending.generation, phase: "ready", ledgerSHA256: pending.ledgerSHA256)
            try saveEvidence(ready)
            try checkpoint?(operation + ".committed")
            expected = ready
        } catch {
            // The object is also fenced after errors. Keeping an older in-memory
            // dictionary alive cannot bypass an interrupted on-disk transaction.
            usable = false
            throw (error as? PortalActionError) ?? PortalActionError.invalidLedger
        }
    }

    private func saveEvidence(_ value: Evidence) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        try evidence.write(data)
        guard try evidence.read() == data else { throw PortalActionError.invalidLedger }
    }

    private func requireDirectoryIdentity() throws {
        guard directoryFD >= 0, let current = try Self.openDirectory(directory, create: false) else { throw PortalActionError.invalidLedger }
        defer { close(current) }
        var oldInfo = stat(), currentInfo = stat()
        guard fstat(directoryFD, &oldInfo) == 0, fstat(current, &currentInfo) == 0,
              oldInfo.st_ino == currentInfo.st_ino, oldInfo.st_dev == currentInfo.st_dev else { throw PortalActionError.invalidLedger }
    }

    private func readFile() throws -> Data {
        var info = stat()
        guard directoryFD >= 0, fstatat(directoryFD, "requests.json", &info, AT_SYMLINK_NOFOLLOW) == 0,
              Self.privateFile(info) else { throw PortalActionError.invalidLedger }
        let handle = openat(directoryFD, "requests.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard handle >= 0 else { throw PortalActionError.invalidLedger }
        defer { close(handle) }
        var opened = stat()
        guard fstat(handle, &opened) == 0, Self.privateFile(opened), opened.st_ino == info.st_ino,
              opened.st_dev == info.st_dev, opened.st_size == info.st_size else { throw PortalActionError.invalidLedger }
        var data = Data(count: Int(opened.st_size))
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let amount = Darwin.read(handle, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if amount < 0 && errno == EINTR { continue }
                guard amount > 0 else { throw PortalActionError.invalidLedger }
                offset += amount
            }
        }
        var after = stat()
        guard fstat(handle, &after) == 0, Self.privateFile(after), after.st_ino == opened.st_ino,
              after.st_dev == opened.st_dev, after.st_size == opened.st_size,
              after.st_mtimespec.tv_sec == opened.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == opened.st_mtimespec.tv_nsec,
              after.st_ctimespec.tv_sec == opened.st_ctimespec.tv_sec,
              after.st_ctimespec.tv_nsec == opened.st_ctimespec.tv_nsec else { throw PortalActionError.invalidLedger }
        return data
    }

    private static func privateFile(_ info: stat) -> Bool {
        (info.st_mode & S_IFMT) == S_IFREG && info.st_uid == getuid() && info.st_nlink == 1
            && info.st_size > 0 && info.st_size <= maximumBytes && (info.st_mode & 0o7777) == 0o600
    }
    private static func entryExists(_ descriptor: Int32, _ name: String) throws -> Bool {
        var info = stat()
        if fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { return true }
        guard errno == ENOENT else { throw PortalActionError.invalidLedger }
        return false
    }
    private static func hasEntries(_ descriptor: Int32) throws -> Bool {
        let copied = dup(descriptor)
        guard copied >= 0 else { throw PortalActionError.invalidLedger }
        guard let stream = fdopendir(copied) else { close(copied); throw PortalActionError.invalidLedger }
        defer { closedir(stream) }
        rewinddir(stream)
        errno = 0
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name != ".", name != ".." { return true }
        }
        guard errno == 0 else { throw PortalActionError.invalidLedger }
        return false
    }

    /// Walk without following any symlink, including parent components. Creation
    /// is allowed only after the independent pending fence was durably recorded.
    private static func openDirectory(_ url: URL, create: Bool) throws -> Int32? {
        guard url.isFileURL, url.path.hasPrefix("/"), url.path != "/" else { throw PortalActionError.invalidLedger }
        let components = url.path.split(separator: "/").map(String.init)
        guard !components.contains("."), !components.contains("..") else { throw PortalActionError.invalidLedger }
        var current = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard current >= 0 else { throw PortalActionError.invalidLedger }
        do {
            for (index, component) in components.enumerated() {
                var prior = stat()
                if fstatat(current, component, &prior, AT_SYMLINK_NOFOLLOW) != 0 {
                    guard errno == ENOENT else { throw PortalActionError.invalidLedger }
                    if !create { close(current); return nil }
                    guard mkdirat(current, component, 0o700) == 0,
                          fstatat(current, component, &prior, AT_SYMLINK_NOFOLLOW) == 0 else { throw PortalActionError.invalidLedger }
                }
                guard (prior.st_mode & S_IFMT) == S_IFDIR else { throw PortalActionError.invalidLedger }
                let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw PortalActionError.invalidLedger }
                var opened = stat()
                guard fstat(next, &opened) == 0, opened.st_ino == prior.st_ino, opened.st_dev == prior.st_dev,
                      index != components.count - 1 || (opened.st_uid == getuid() && (opened.st_mode & 0o7777) == 0o700) else {
                    close(next); throw PortalActionError.invalidLedger
                }
                close(current); current = next
            }
            return current
        } catch { close(current); throw PortalActionError.invalidLedger }
    }

    private static func rejectPriorExchangeArtifacts(_ directory: URL) throws {
        // V1 wrote contexts before dispatch. Retained contexts/receipts are enough
        // to make a missing legacy ledger ambiguous, even before V2 evidence exists.
        guard directory.lastPathComponent == "Journal" else { return }
        let parent = directory.deletingLastPathComponent()
        guard let descriptor = try openDirectory(parent, create: false) else { return }
        defer { close(descriptor) }
        for name in ["Contexts", "Incoming", "Outgoing"] where try entryExists(descriptor, name) {
            throw PortalActionError.invalidLedger
        }
    }

    private static func decodeEvidence(_ data: Data) throws -> Evidence {
        guard data.count <= 4096, let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(raw.keys) == ["schemaVersion", "ledgerID", "generation", "phase", "ledgerSHA256"],
              let value = try? JSONDecoder().decode(Evidence.self, from: data), value.schemaVersion == 1,
              UUID(uuidString: value.ledgerID) != nil, value.ledgerID == value.ledgerID.lowercased(),
              isSHA256(value.ledgerSHA256), ["ready", "initialization", "migration", "write", "recovery"].contains(value.phase),
              value.generation > 0 else { throw PortalActionError.invalidLedger }
        return value
    }
    private static func decodeEnvelope(_ data: Data) throws -> Envelope {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = try? JSONDecoder().decode(Envelope.self, from: data), value.schemaVersion == 1 || value.schemaVersion == 2,
              Set(raw.keys) == (value.schemaVersion == 1 ? ["schemaVersion", "records"] : ["schemaVersion", "ledgerID", "generation", "records"]),
              value.schemaVersion == 1 || (value.ledgerID.flatMap(UUID.init(uuidString:)) != nil && value.ledgerID == value.ledgerID?.lowercased() && (value.generation ?? 0) > 0),
              value.records.count <= maximumRecords else { throw PortalActionError.invalidLedger }
        return value
    }
    private static func validatedRecords(_ values: [PortalRequestRecord]) throws -> [String: PortalRequestRecord] {
        var result: [String: PortalRequestRecord] = [:]
        for record in values {
            guard valid(record), result[record.requestID] == nil else { throw PortalActionError.invalidLedger }
            result[record.requestID] = record
        }
        return result
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private static func valid(_ record: PortalRequestRecord) -> Bool {
        guard UUID(uuidString: record.requestID) != nil, record.requestID == record.requestID.lowercased(), isSHA256(record.fingerprint),
              PortalActionPlanner.actionNames.contains(record.action), record.receivedAt.timeIntervalSince1970.isFinite,
              record.updatedAt.timeIntervalSince1970.isFinite, record.updatedAt >= record.receivedAt, validOutcome(record.outcome) else { return false }
        switch record.state {
        case .received, .approved: return record.outcome == .awaitingUser
        case .executing: return record.outcome.status == .pending && [.awaitingUser, .accepted].contains(record.outcome.workflowState)
        case .completed: return [.completed, .partial, .pending].contains(record.outcome.status)
        case .cancelled: return record.outcome.status == .cancelled
        case .failed: return [.failed, .unsupported].contains(record.outcome.status)
        }
    }
    private static func validOutcome(_ outcome: PortalActionOutcome) -> Bool {
        func code(_ value: String?) -> Bool {
            guard let value else { return true }
            return !value.isEmpty && value.utf8.count <= 80 && value.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }
        }
        let pair: Bool
        switch outcome.status {
        case .pending: pair = [.awaitingUser, .accepted, .handedOff].contains(outcome.workflowState)
        case .completed: pair = outcome.workflowState == .opened
        case .partial: pair = [.opened, .accepted].contains(outcome.workflowState)
        case .cancelled: pair = outcome.workflowState == .cancelled
        case .failed: pair = outcome.workflowState == .failed
        case .unsupported: pair = outcome.workflowState == .unsupported
        }
        return pair && code(outcome.errorCode) && (outcome.sites?.count ?? 0) <= 20
            && (outcome.sites ?? []).allSatisfy { !$0.siteID.isEmpty && $0.siteID.count <= 256 && code($0.errorCode) }
    }
    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
