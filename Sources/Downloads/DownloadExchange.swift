import Foundation
import AppKit
import Combine
import CryptoKit
import Darwin

struct DownloadGaoTaskOutcome {
    let taskID: UUID
    let itemID: UUID
    let state: String
    let fileURL: URL?
    let byteCount: Int64?
    let sha256: String?
    let errorCode: String?
}

struct DownloadGaoStoredTaskOutcome: Codable, Equatable {
    var taskID: UUID
    var itemID: UUID
    var state: String
    var artifactItemID: String?
    var byteCount: Int64?
    var sha256: String?
    var errorCode: String?
}

struct DownloadGaoResultDelivery: Codable, Equatable {
    var packageName: String
    var manifest: DownloadGaoActionManifest
    var fingerprint: String
    var attempts: Int
    var handedOffAt: Date?
    var lastError: String?
}

struct DownloadGaoExchangeRecord: Codable, Identifiable, Equatable {
    var id: UUID
    var sourceBundleID: String
    var urls: [String]
    var receivedAt: Date
    var stage: String
    var taskIDs: [UUID]
    var outgoingURLs: [URL]
    var hasFinalResult: Bool
    var itemIDs: [UUID] = []
    var outcomes: [DownloadGaoStoredTaskOutcome] = []
    var deliveries: [DownloadGaoResultDelivery] = []
    var manifest: DownloadGaoActionManifest
    var manifestSHA256: String
    var packageName: String

    /// Imported declarations remain historical evidence, never new approvals.
    var isLegacyHistory: Bool { manifest.targetBundleID == DownloadGaoDownloadContract.legacyBundleID }
}

/// Plain HTTP file handoff. The declared bundle ID and nonce never authenticate a sender.
enum DownloadGaoDownloadContract {
    static let bundleID = "cn.mendao.launcher"
    static let legacyBundleID = "com.gaoseries.GaoXiaZai"
    static let action = "downloads.prepare"
    static func validateRequest(_ m: DownloadGaoActionManifest) throws {
        try validateRequest(m, historical: false)
    }
    static func validateHistoricalRequest(_ m: DownloadGaoActionManifest) throws {
        try validateRequest(m, historical: true)
    }
    private static func validateRequest(_ m: DownloadGaoActionManifest, historical: Bool) throws {
        guard m.kind == "request", m.action == action,
              m.targetBundleID == bundleID || (historical && m.targetBundleID == legacyBundleID),
              m.items.isEmpty, m.references.isEmpty,
              Set(m.parameters.keys).isSubset(of: ["urls", "mediaType"]),
              let values = m.parameters["urls"]?.array, (1...32).contains(values.count) else { throw issue("invalid_parameters", "交接只接受 1 至 32 个 HTTP/HTTPS 文件链接。") }
        for value in values {
            guard let text = value.string, validHTTP(text) else { throw issue("invalid_url", "交接链接无效或包含账号密码。") }
        }
        if let media = m.parameters["mediaType"] { guard media.string == "file" else { throw issue("unsupported_media_type", "此版本仅接收普通文件直链。") } }
    }
    static func validHTTP(_ text: String) -> Bool {
        guard !text.isEmpty, text.utf8.count <= 16_384,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0) }),
              let c = URLComponents(string: text), let scheme = c.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = c.host, !host.isEmpty, c.user == nil, c.password == nil,
              let u = c.url, u.host != nil, c.fragment == nil else { return false }
        return true
    }
    static func validateResult(_ m: DownloadGaoActionManifest) throws {
        try validateResult(m, historical: false)
    }
    static func validateHistoricalResult(_ m: DownloadGaoActionManifest) throws {
        try validateResult(m, historical: true)
    }
    private static func validateResult(_ m: DownloadGaoActionManifest, historical: Bool) throws {
        guard m.kind == "result", m.action == action,
              m.sourceBundleID == bundleID || (historical && m.sourceBundleID == legacyBundleID),
              m.parameters.isEmpty, m.references.isEmpty,
              let p = m.provenance, Set(p.keys) == ["workflowState", "taskIDs"],
              let state = p["workflowState"]?.string, let raw = p["taskIDs"]?.array else { throw issue("invalid_result", "结果清单无效。") }
        let tasks = raw.compactMap(\.string)
        guard tasks.count == raw.count, tasks.count <= 32, Set(tasks).count == tasks.count, tasks.allSatisfy({ UUID(uuidString: $0) != nil }) else { throw issue("invalid_result", "结果任务编号无效。") }
        switch m.status {
        case "pending": guard state == "accepted", !tasks.isEmpty, m.items.isEmpty, m.errorCode == nil else { throw issue("invalid_result", "待完成结果必须关联已创建任务。") }
        case "completed", "partial": guard state == m.status, !tasks.isEmpty, !m.items.isEmpty, m.status != "completed" || m.errorCode == nil else { throw issue("invalid_result", "完成结果缺少已核验文件。") }
        case "failed", "cancelled": guard state == m.status, m.items.isEmpty else { throw issue("invalid_result", "失败或取消结果不能包含下载文件。") }
        default: throw issue("invalid_result", "不支持此结果状态。")
        }
    }
    static func issue(_ code: String, _ message: String) -> DownloadGaoActionPackageError { DownloadGaoActionPackageError(code, message) }
    static func safeCode(_ value: String?) -> Bool {
        guard let value else { return true }
        return !value.isEmpty && value.utf8.count <= 80 && value.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }
    }
}

@MainActor
final class DownloadGaoExchange: ObservableObject {
    @Published var records: [DownloadGaoExchangeRecord] = []
    @Published var lastError: String?
    @Published var recoveryIssue: String?
    let rootURL: URL
    private var journal: DownloadGaoExchangeJournal?
    private let historyDefaults: PortalDownloadMigrationDefaults
    @Published private(set) var isPackaging = false
    private var packagingIDs = Set<UUID>()
    private var previouslyCreatedApprovals = Set<UUID>()
    private var currentDate: () -> Date = Date.init

    init(rootURL: URL) {
        self.rootURL = rootURL
        self.historyDefaults = UserDefaults.standard
        do { journal = try DownloadGaoExchangeJournal(directory: self.rootURL); reload() }
        catch { recoveryIssue = error.localizedDescription }
    }
    init(blockedBecause issue: String) {
        self.rootURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MenDao/DownloadCenter/Exchange", isDirectory: true)
        self.historyDefaults = UserDefaults.standard
        self.recoveryIssue = issue
    }
    /// Test-only injection keeps synthetic evidence outside the real preferences domain.
    init(rootURL: URL, evidence: DownloadGaoExchangeEvidence, now: @escaping () -> Date = Date.init,
         historyDefaults: PortalDownloadMigrationDefaults = UserDefaults.standard) {
        self.rootURL = rootURL
        self.historyDefaults = historyDefaults
        self.currentDate = now
        do { journal = try DownloadGaoExchangeJournal(directory: rootURL, evidence: evidence, historyDefaults: historyDefaults); reload() }
        catch { recoveryIssue = error.localizedDescription }
    }
    func receive(_ url: URL) {
        do {
            let journal = try available(); try enforceBudget()
            let receivedAt = currentDate()
            let received = try DownloadGaoActionPackage.receive(at: url, stagingRoot: rootURL.appendingPathComponent("Incoming"), targetBundleID: DownloadGaoDownloadContract.bundleID, now: receivedAt, validateAction: DownloadGaoDownloadContract.validateRequest)
            var keep = false
            defer { if !keep { try? FileManager.default.removeItem(at: received.packageURL) } }
            let id = UUID(uuidString: received.manifest.requestID)!
            try PortalDownloadHistoryIsolation.guardNewRequest(root: rootURL.deletingLastPathComponent(), requestID: received.manifest.requestID,
                nonce: received.manifest.nonce, targetDefaults: historyDefaults)
            if let existing = journal.records.first(where: { $0.id == id }) {
                guard existing.manifestSHA256 == received.manifestSHA256 else { throw DownloadGaoDownloadContract.issue("replay_conflict", "相同请求编号包含不同内容，已拒绝。") }
                lastError = nil; reload(); return
            }
            guard !journal.records.contains(where: { $0.manifest.nonce == received.manifest.nonce }) else { throw DownloadGaoDownloadContract.issue("nonce_reused", "交接随机数已被其他请求使用。") }
            let m = received.manifest
            let record = DownloadGaoExchangeRecord(id: id, sourceBundleID: m.sourceBundleID, urls: m.parameters["urls"]!.array!.compactMap(\.string), receivedAt: receivedAt, stage: "awaitingReview", taskIDs: [], outgoingURLs: [], hasFinalResult: false, manifest: m, manifestSHA256: received.manifestSHA256, packageName: received.packageURL.lastPathComponent)
            try journal.append(record); keep = true; lastError = nil; reload()
        } catch { report(error) }
    }
    /// First approval must occur inside the original TTL. The caller may opt in only after
    /// proving the existing core jobs were created during that TTL with this exact URL mapping.
    func preflightApproval(_ recordID: UUID, allowingPreviouslyCreatedTasks: Bool = false) throws {
        let record = try record(recordID)
        try requireCurrentRequest(record)
        guard record.stage == "awaitingReview" || record.stage == "accepted" else { throw DownloadGaoDownloadContract.issue("already_resolved", "此请求已经复核。") }
        let useOriginalTime = record.stage == "accepted" || allowingPreviouslyCreatedTasks
        try verifyRequest(record, approvalAt: useOriginalTime ? record.receivedAt : currentDate())
        if allowingPreviouslyCreatedTasks && record.stage == "awaitingReview" { previouslyCreatedApprovals.insert(recordID) }
    }
    /// The caller creates real jobs first and reuses those IDs if a preceding commit was interrupted.
    func accept(_ recordID: UUID, taskIDs: [UUID], allowingPreviouslyCreatedTasks: Bool = false) throws {
        do {
            let journal = try available(); var record = try record(recordID)
            try requireCurrentRequest(record)
            try verifyRequest(record, approvalAt: record.stage == "awaitingReview" && !allowingPreviouslyCreatedTasks && !previouslyCreatedApprovals.contains(recordID) ? currentDate() : record.receivedAt)
            guard taskIDs.count == record.urls.count, Set(taskIDs).count == taskIDs.count,
                  journal.records.filter({ $0.id != recordID }).allSatisfy({ Set($0.taskIDs).isDisjoint(with: taskIDs) }) else { throw DownloadGaoDownloadContract.issue("invalid_task_mapping", "实际任务编号与复核链接不匹配。") }
            if record.stage != "awaitingReview" { guard record.taskIDs == taskIDs, !record.taskIDs.isEmpty else { throw DownloadGaoDownloadContract.issue("already_resolved", "此请求已经复核，不能建立另一批任务。") }; return }
            record.stage = "accepted"; record.taskIDs = taskIDs
            try journal.replace(record); previouslyCreatedApprovals.remove(recordID); reload()
        } catch { report(error); throw error }
    }
    func bindItems(_ recordID: UUID, itemIDs: [UUID]) throws {
        let journal = try available(); var record = try record(recordID)
        try requireCurrentRequest(record)
        guard !record.taskIDs.isEmpty, itemIDs.count == record.taskIDs.count, Set(itemIDs).count == itemIDs.count,
              record.itemIDs.isEmpty || record.itemIDs == itemIDs,
              journal.records.filter({ $0.id != recordID }).allSatisfy({ Set($0.itemIDs).isDisjoint(with: itemIDs) }) else { throw DownloadGaoDownloadContract.issue("invalid_item_mapping", "下载条目编号与已接受任务不匹配。") }
        if record.itemIDs == itemIDs { return }
        record.itemIDs = itemIDs; try journal.replace(record); reload()
    }
    func decline(_ recordID: UUID) {
        do {
            let journal = try available(); var record = try record(recordID)
            try requireCurrentRequest(record)
            guard record.stage == "awaitingReview" || (record.stage == "cancelled" && record.taskIDs.isEmpty) else { throw DownloadGaoDownloadContract.issue("already_accepted", "已创建的任务需要在任务列表中取消。") }
            try verifyRequest(record); record.stage = "cancelled"; try journal.replace(record); previouslyCreatedApprovals.remove(recordID); reload()
        } catch { report(error) }
    }
    func makePendingResult(_ recordID: UUID) throws -> URL {
        guard packagingIDs.isEmpty else { throw DownloadGaoDownloadContract.issue("packaging_busy", "正在准备结果，请稍候。") }
        let record = try record(recordID)
        try requireCurrentRequest(record)
        guard !record.taskIDs.isEmpty else { throw DownloadGaoDownloadContract.issue("not_accepted", "尚未创建真实下载任务，不能发送接受结果。") }
        if let old = record.deliveries.last(where: { $0.manifest.status == "pending" }) { return try usableDelivery(old, recordID: recordID) }
        guard !record.hasFinalResult else { throw DownloadGaoDownloadContract.issue("already_final", "终态已经记录。") }
        return try publish(recordID: recordID, status: "pending", items: [], payloads: [:], errorCode: nil)
    }
    private struct FinalPlan {
        var status: String
        var items: [DownloadGaoActionItem]
        var payloads: [String: URL]
        var existing: DownloadGaoResultDelivery?
        var errorCode: String? { status == "partial" ? "some_tasks_failed" : status == "failed" ? "download_failed" : nil }
    }
    func makeFinalResult(_ recordID: UUID, outcomes: [DownloadGaoTaskOutcome]) throws -> URL {
        guard packagingIDs.isEmpty else { throw DownloadGaoDownloadContract.issue("packaging_busy", "正在准备本次结果，请稍候。") }
        let plan = try prepareFinal(recordID, outcomes: outcomes)
        if let existing = plan.existing { return try usableDelivery(existing, recordID: recordID) }
        return try publish(recordID: recordID, status: plan.status, items: plan.items, payloads: plan.payloads, errorCode: plan.errorCode)
    }
    /// Hashing and fixed-descriptor payload copying run on a utility executor, with serialized journal commits.
    func makeFinalResultAsync(_ recordID: UUID, outcomes: [DownloadGaoTaskOutcome], completion: @escaping (Result<URL, Error>) -> Void) {
        guard packagingIDs.isEmpty else { completion(.failure(DownloadGaoDownloadContract.issue("packaging_busy", "正在准备本次结果，请稍候。"))); return }
        do {
            let plan = try prepareFinal(recordID, outcomes: outcomes)
            packagingIDs.insert(recordID); isPackaging = true
            Task { @MainActor in
                do {
                    let result: URL
                    if let existing = plan.existing { result = try await usableDeliveryAsync(existing, recordID: recordID) }
                    else { result = try await publishAsync(recordID: recordID, status: plan.status, items: plan.items, payloads: plan.payloads, errorCode: plan.errorCode) }
                    packagingIDs.remove(recordID); isPackaging = !packagingIDs.isEmpty; completion(.success(result))
                } catch { packagingIDs.remove(recordID); isPackaging = !packagingIDs.isEmpty; report(error); completion(.failure(error)) }
            }
        } catch { report(error); completion(.failure(error)) }
    }
    private func prepareFinal(_ recordID: UUID, outcomes: [DownloadGaoTaskOutcome]) throws -> FinalPlan {
        let journal = try available(); var record = try record(recordID)
        try requireCurrentRequest(record)
        if record.hasFinalResult {
            guard let old = record.deliveries.last(where: { $0.manifest.status != "pending" }) else { throw DownloadGaoExchangeJournal.invalid }
            return FinalPlan(status: old.manifest.status!, items: [], payloads: [:], existing: old)
        }
        if record.taskIDs.isEmpty {
            guard record.stage == "cancelled", outcomes.isEmpty else { throw DownloadGaoDownloadContract.issue("not_accepted", "尚未创建下载任务。") }
            return FinalPlan(status: "cancelled", items: [], payloads: [:], existing: nil)
        }
        guard record.deliveries.contains(where: { $0.manifest.status == "pending" }),
              outcomes.count == record.taskIDs.count, Set(outcomes.map(\.taskID)) == Set(record.taskIDs),
              Set(outcomes.map(\.itemID)).count == outcomes.count,
              outcomes.allSatisfy({ ["completed", "failed", "cancelled"].contains($0.state) && DownloadGaoDownloadContract.safeCode($0.errorCode) }) else { throw DownloadGaoDownloadContract.issue("invalid_outcomes", "请先生成接受结果，并等待每个任务获得独立终态。") }
        let sorted = record.taskIDs.map { id in outcomes.first(where: { $0.taskID == id })! }
        guard record.itemIDs.isEmpty || record.itemIDs == sorted.map(\.itemID) else { throw DownloadGaoDownloadContract.issue("invalid_item_mapping", "终态条目与已确认任务不匹配。") }
        var items: [DownloadGaoActionItem] = []; var payloads: [String: URL] = [:]; var stored: [DownloadGaoStoredTaskOutcome] = []
        for outcome in sorted {
            if outcome.state == "completed" {
                guard let file = outcome.fileURL, let bytes = outcome.byteCount, bytes >= 0, let digest = outcome.sha256,
                      digest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil, outcome.errorCode == nil else { throw DownloadGaoDownloadContract.issue("missing_artifact", "完成任务缺少已发布文件及其校验值。") }
                let id = outcome.itemID.uuidString.lowercased()
                items.append(DownloadGaoActionItem(id: id, relativePath: "payload/" + outcome.taskID.uuidString.lowercased() + "/" + id, uti: "public.data", byteCount: bytes, sha256: digest)); payloads[id] = file
                stored.append(DownloadGaoStoredTaskOutcome(taskID: outcome.taskID, itemID: outcome.itemID, state: outcome.state, artifactItemID: id, byteCount: bytes, sha256: digest, errorCode: nil))
            } else {
                guard outcome.fileURL == nil, outcome.byteCount == nil, outcome.sha256 == nil else { throw DownloadGaoDownloadContract.issue("uncommitted_artifact", "失败或取消任务不能作为完成文件回送。") }
                stored.append(DownloadGaoStoredTaskOutcome(taskID: outcome.taskID, itemID: outcome.itemID, state: outcome.state, artifactItemID: nil, byteCount: nil, sha256: nil, errorCode: outcome.errorCode))
            }
        }
        record.itemIDs = sorted.map(\.itemID); record.outcomes = stored
        // Persist every terminal item before packaging. A packaging or delivery failure never starts jobs again.
        try journal.replace(record); reload()
        let status: String
        if items.count == outcomes.count { status = "completed" }
        else if !items.isEmpty { status = "partial" }
        else if outcomes.allSatisfy({ $0.state == "cancelled" }) { status = "cancelled" }
        else { status = "failed" }
        if !items.isEmpty {
            struct Receipt: Encodable { let schemaVersion = 1; let requestID: UUID; let outcomes: [DownloadGaoStoredTaskOutcome] }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(Receipt(requestID: recordID, outcomes: stored))
            let receipts = rootURL.appendingPathComponent("Receipts", isDirectory: true)
            let fd = try DownloadGaoActionPackage.ensurePrivateDirectory(receipts); defer { close(fd) }
            let name = UUID().uuidString.lowercased() + ".json"; try DownloadGaoActionPackage.writeFile(data, directory: fd, name: name)
            let id = UUID().uuidString.lowercased()
            items.append(DownloadGaoActionItem(id: id, relativePath: "payload/receipt/task-outcomes.json", uti: "public.json", byteCount: Int64(data.count), sha256: DownloadGaoActionPackage.digest(data))); payloads[id] = receipts.appendingPathComponent(name)
        }
        return FinalPlan(status: status, items: items, payloads: payloads, existing: nil)
    }
    /// User-initiated only. A successful open is handoff evidence, never a receipt or business completion.
    func sendResult(_ packageURL: URL, for recordID: UUID) {
        guard packagingIDs.isEmpty else { report(DownloadGaoDownloadContract.issue("packaging_busy", "正在核验结果，请稍候。")); return }
        do {
            _ = try available(); let record = try record(recordID)
            try requireCurrentRequest(record)
            guard let delivery = record.deliveries.first(where: { rootURL.appendingPathComponent("Outgoing").appendingPathComponent($0.packageName).standardizedFileURL == packageURL.standardizedFileURL }) else { throw DownloadGaoDownloadContract.issue("unknown_result", "结果不属于本次请求。") }
            packagingIDs.insert(recordID); isPackaging = true
            Task { @MainActor in
                do {
                    let url = try await usableDeliveryAsync(delivery, recordID: recordID)
                    try dispatchVerified(url, recordID: recordID)
                } catch { packagingIDs.remove(recordID); isPackaging = !packagingIDs.isEmpty; report(error) }
            }
        } catch { report(error) }
    }
    private func dispatchVerified(_ url: URL, recordID: UUID) throws {
        let journal = try available(); let current = try self.record(recordID)
        guard let index = current.deliveries.firstIndex(where: { $0.packageName == url.lastPathComponent }) else { throw DownloadGaoExchangeJournal.invalid }
        if current.deliveries[index].manifest.status != "pending", !current.taskIDs.isEmpty,
           !current.deliveries.contains(where: { $0.manifest.status == "pending" && $0.handedOffAt != nil }) {
            throw DownloadGaoDownloadContract.issue("pending_first", "请先显式发送接受结果，再发送最终结果；若门户未记录，请重新发送接受结果。")
        }
        guard let target = compatibleApp(current.sourceBundleID) else { throw DownloadGaoDownloadContract.issue("receiver_unavailable", "未找到兼容的来源应用。结果包已保留，可稍后重试。") }
        var next = current; next.deliveries[index].attempts += 1; next.deliveries[index].lastError = nil
        try journal.replace(next); reload()
        let configuration = NSWorkspace.OpenConfiguration(); configuration.allowsRunningApplicationSubstitution = false
        NSWorkspace.shared.open([url], withApplicationAt: target, configuration: configuration) { [weak self] _, error in
            Task { @MainActor in
                guard let self else { return }
                defer { self.packagingIDs.remove(recordID); self.isPackaging = !self.packagingIDs.isEmpty }
                do {
                    let journal = try self.available(); var updated = try self.record(recordID)
                    guard let idx = updated.deliveries.firstIndex(where: { $0.packageName == url.lastPathComponent }) else { throw DownloadGaoExchangeJournal.invalid }
                    if error == nil { updated.deliveries[idx].handedOffAt = Date(); updated.deliveries[idx].lastError = nil }
                    else { updated.deliveries[idx].lastError = "handoff_failed" }
                    try journal.replace(updated); self.reload()
                    self.lastError = error == nil ? nil : "来源应用未能接收结果，文件与投递记录已保留。"
                } catch { self.report(error) }
            }
        }
    }
    private func publishAsync(recordID: UUID, status: String, items: [DownloadGaoActionItem], payloads: [String: URL], errorCode: String?) async throws -> URL {
        _ = try available(); let snapshot = try record(recordID)
        try enforceBudget(additionalBytes: items.reduce(0) { $0 + $1.byteCount })
        let now = Date()
        var m = DownloadGaoActionManifest(kind: "result", requestID: UUID().uuidString.lowercased(), sourceBundleID: DownloadGaoDownloadContract.bundleID, targetBundleID: snapshot.sourceBundleID, action: DownloadGaoDownloadContract.action, createdAt: DownloadGaoActionPackage.iso8601(now), expiresAt: DownloadGaoActionPackage.iso8601(now.addingTimeInterval(120)), nonce: try DownloadGaoActionPackage.randomNonce(), items: items, references: [], parameters: [:])
        m.inReplyTo = recordID.uuidString.lowercased(); m.status = status; m.errorCode = errorCode
        m.provenance = ["workflowState": .string(status == "pending" ? "accepted" : status), "taskIDs": .array(snapshot.taskIDs.map { .string($0.uuidString.lowercased()) })]
        let manifest = m
        let url = rootURL.appendingPathComponent("Outgoing").appendingPathComponent(m.requestID + ".gaoaction", isDirectory: true)
        _ = try await Task.detached(priority: .utility) {
            try DownloadGaoActionPackage.write(manifest: manifest, to: url, payloads: payloads, refreshResultTTL: true, validateAction: DownloadGaoDownloadContract.validateResult)
        }.value
        var saved = false; defer { if !saved { try? FileManager.default.removeItem(at: url) } }
        let actual = try readPublishedManifest(url)
        let journal = try available(); var current = try record(recordID)
        guard current.taskIDs == snapshot.taskIDs, current.itemIDs == snapshot.itemIDs else { throw DownloadGaoExchangeJournal.invalid }
        current.deliveries.append(DownloadGaoResultDelivery(packageName: url.lastPathComponent, manifest: actual.manifest, fingerprint: actual.digest, attempts: 0, handedOffAt: nil, lastError: nil)); current.outgoingURLs.append(url)
        if status != "pending" { current.stage = status; current.hasFinalResult = true }
        try journal.replace(current); saved = true; reload(); return url
    }
    private func usableDeliveryAsync(_ delivery: DownloadGaoResultDelivery, recordID: UUID) async throws -> URL {
        let url = rootURL.appendingPathComponent("Outgoing").appendingPathComponent(delivery.packageName, isDirectory: true)
        try enforceBudget(additionalBytes: delivery.manifest.items.reduce(0) { $0 + $1.byteCount } + Int64(DownloadGaoActionPackage.maximumManifestBytes))
        let validation = rootURL.appendingPathComponent("Validation", isDirectory: true)
        let validationTime = Self.date(delivery.manifest.createdAt)!.addingTimeInterval(0.1)
        let verified = try await Task.detached(priority: .utility) {
            try DownloadGaoActionPackage.receive(at: url, stagingRoot: validation, targetBundleID: delivery.manifest.targetBundleID, now: validationTime, validateAction: DownloadGaoDownloadContract.validateResult)
        }.value
        defer { try? FileManager.default.removeItem(at: verified.packageURL) }
        guard verified.manifestSHA256 == delivery.fingerprint else { throw DownloadGaoDownloadContract.issue("result_changed", "保留结果包已变化，停止发送。") }
        if Date() < Self.date(delivery.manifest.expiresAt)! { return url }
        var payloads: [String: URL] = [:]
        for item in verified.manifest.items {
            var relative = item.relativePath; if relative.hasPrefix("payload/") { relative.removeFirst(8) }
            payloads[item.id] = verified.payloadURL.appendingPathComponent(relative)
        }
        return try await publishAsync(recordID: recordID, status: delivery.manifest.status!, items: delivery.manifest.items, payloads: payloads, errorCode: delivery.manifest.errorCode)
    }
    private func publish(recordID: UUID, status: String, items: [DownloadGaoActionItem], payloads: [String: URL], errorCode: String?) throws -> URL {
        let journal = try available(); var record = try record(recordID); try enforceBudget(additionalBytes: items.reduce(0) { $0 + $1.byteCount })
        let now = Date()
        var m = DownloadGaoActionManifest(kind: "result", requestID: UUID().uuidString.lowercased(), sourceBundleID: DownloadGaoDownloadContract.bundleID, targetBundleID: record.sourceBundleID, action: DownloadGaoDownloadContract.action, createdAt: DownloadGaoActionPackage.iso8601(now), expiresAt: DownloadGaoActionPackage.iso8601(now.addingTimeInterval(120)), nonce: try DownloadGaoActionPackage.randomNonce(), items: items, references: [], parameters: [:])
        m.inReplyTo = recordID.uuidString.lowercased(); m.status = status; m.errorCode = errorCode
        m.provenance = ["workflowState": .string(status == "pending" ? "accepted" : status), "taskIDs": .array(record.taskIDs.map { .string($0.uuidString.lowercased()) })]
        let url = rootURL.appendingPathComponent("Outgoing").appendingPathComponent(m.requestID + ".gaoaction", isDirectory: true)
        _ = try DownloadGaoActionPackage.write(manifest: m, to: url, payloads: payloads, refreshResultTTL: true, validateAction: DownloadGaoDownloadContract.validateResult)
        var saved = false; defer { if !saved { try? FileManager.default.removeItem(at: url) } }
        let actual = try readPublishedManifest(url)
        record.deliveries.append(DownloadGaoResultDelivery(packageName: url.lastPathComponent, manifest: actual.manifest, fingerprint: actual.digest, attempts: 0, handedOffAt: nil, lastError: nil)); record.outgoingURLs.append(url)
        if status != "pending" { record.stage = status; record.hasFinalResult = true }
        try journal.replace(record); saved = true; reload(); return url
    }
    private func readPublishedManifest(_ url: URL) throws -> (manifest: DownloadGaoActionManifest, digest: String) {
        let dir = try DownloadGaoActionPackage.openAbsoluteDirectory(url); defer { close(dir) }; try DownloadGaoActionPackage.requirePrivateDirectory(dir)
        let fd = try DownloadGaoActionPackage.openRegular(at: dir, name: "manifest.json"); defer { close(fd) }
        let before = try DownloadGaoActionPackage.metadata(fd)
        let data = try DownloadGaoActionPackage.readBounded(fd, limit: DownloadGaoActionPackage.maximumManifestBytes)
        try DownloadGaoActionPackage.requireUnchanged(before, DownloadGaoActionPackage.metadata(fd))
        let decoded = try JSONDecoder().decode(DownloadGaoActionManifest.self, from: data)
        guard let reply = decoded.inReplyTo, let id = UUID(uuidString: reply) else { throw DownloadGaoExchangeJournal.invalid }
        let target = try record(id).sourceBundleID
        let m = try DownloadGaoActionPackage.validate(data: data, targetBundleID: target, now: Date(), validateAction: DownloadGaoDownloadContract.validateResult)
        return (m, DownloadGaoActionPackage.digest(data))
    }
    private func usableDelivery(_ delivery: DownloadGaoResultDelivery, recordID: UUID) throws -> URL {
        let url = rootURL.appendingPathComponent("Outgoing").appendingPathComponent(delivery.packageName, isDirectory: true)
        try enforceBudget(additionalBytes: delivery.manifest.items.reduce(0) { $0 + $1.byteCount } + Int64(DownloadGaoActionPackage.maximumManifestBytes))
        let validationTime = Self.date(delivery.manifest.createdAt)!.addingTimeInterval(0.1)
        let verified = try DownloadGaoActionPackage.receive(at: url, stagingRoot: rootURL.appendingPathComponent("Validation"), targetBundleID: delivery.manifest.targetBundleID, now: validationTime, validateAction: DownloadGaoDownloadContract.validateResult)
        defer { try? FileManager.default.removeItem(at: verified.packageURL) }
        guard verified.manifestSHA256 == delivery.fingerprint else { throw DownloadGaoDownloadContract.issue("result_changed", "保留结果包已变化，停止发送。") }
        if Date() < Self.date(delivery.manifest.expiresAt)! { return url }
        // Fresh UUID/TTL from verified private copies. No transfer is created or resumed.
        var sources: [String: URL] = [:]
        for item in verified.manifest.items {
            var path = item.relativePath; if path.hasPrefix("payload/") { path.removeFirst(8) }
            sources[item.id] = verified.payloadURL.appendingPathComponent(path)
        }
        return try publish(recordID: recordID, status: delivery.manifest.status!, items: delivery.manifest.items, payloads: sources, errorCode: delivery.manifest.errorCode)
    }
    private func verifyRequest(_ record: DownloadGaoExchangeRecord, approvalAt: Date? = nil) throws {
        try requireCurrentRequest(record)
        let url = rootURL.appendingPathComponent("Incoming").appendingPathComponent(record.packageName)
        let verified = try DownloadGaoActionPackage.receive(at: url, stagingRoot: rootURL.appendingPathComponent("Validation"), targetBundleID: DownloadGaoDownloadContract.bundleID, now: approvalAt ?? record.receivedAt, validateAction: DownloadGaoDownloadContract.validateRequest)
        defer { try? FileManager.default.removeItem(at: verified.packageURL) }
        guard verified.manifestSHA256 == record.manifestSHA256, verified.manifest == record.manifest else { throw DownloadGaoDownloadContract.issue("request_changed", "待复核请求已变化，未创建接受结果。") }
    }
    private func requireCurrentRequest(_ record: DownloadGaoExchangeRecord) throws {
        guard !record.isLegacyHistory, record.manifest.targetBundleID == DownloadGaoDownloadContract.bundleID else {
            throw DownloadGaoDownloadContract.issue("legacy_history_read_only", "迁入的旧下载请求仅保留历史和任务映射，不能重新审批、重放或发送旧提供方结果。请按需要创建新的下载请求。")
        }
        try PortalDownloadHistoryIsolation.guardNewRequest(root: rootURL.deletingLastPathComponent(), requestID: record.id.uuidString,
            nonce: record.manifest.nonce, targetDefaults: historyDefaults)
    }
    private func available() throws -> DownloadGaoExchangeJournal {
        guard let journal, recoveryIssue == nil else { throw DownloadGaoExchangeJournal.invalid }; try journal.verify(); return journal
    }
    private func record(_ id: UUID) throws -> DownloadGaoExchangeRecord {
        let journal = try available(); guard let record = journal.records.first(where: { $0.id == id }) else { throw DownloadGaoDownloadContract.issue("unknown_request", "未找到交接请求。") }; return record
    }
    private func reload() { records = journal?.records.sorted { $0.receivedAt > $1.receivedAt } ?? [] }
    private func report(_ error: Error) { lastError = error.localizedDescription; if (error as? DownloadGaoActionPackageError)?.code == "exchange_recovery_required" { recoveryIssue = error.localizedDescription } }
    private func compatibleApp(_ bundleID: String) -> URL? {
        guard let found = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let url = found.standardizedFileURL
        let allowed = ["/Applications/", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path + "/"]
        guard allowed.contains(where: { url.path.hasPrefix($0) }), url == found.resolvingSymlinksInPath().standardizedFileURL,
              let b = Bundle(url: url), b.bundleIdentifier == bundleID,
              let version = b.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String, !version.isEmpty,
              let resource = b.url(forResource: "DownloadGaoCapabilities", withExtension: "json"),
              let capabilityData = Self.boundedCapability(at: resource),
              let capability = try? JSONSerialization.jsonObject(with: capabilityData) as? [String: Any],
              let schema = capability["schemaVersion"] as? NSNumber, CFGetTypeID(schema) != CFBooleanGetTypeID(), schema.doubleValue == 1,
              capability["bundleID"] as? String == bundleID, capability["appVersion"] as? String == version,
              let types = b.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]],
              types.contains(where: { ($0["LSItemContentTypes"] as? [String])?.contains("com.gaoseries.action-package") == true }) else { return nil }
        return url
    }
    private static func boundedCapability(at url: URL) -> Data? {
        do {
            let parent = try DownloadGaoActionPackage.openAbsoluteDirectory(url.deletingLastPathComponent()); defer { close(parent) }
            let fd = openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { return nil }; defer { close(fd) }
            let before = try DownloadGaoActionPackage.metadata(fd)
            guard (before.st_mode & S_IFMT) == S_IFREG, before.st_size > 0, before.st_size <= DownloadGaoActionPackage.maximumManifestBytes else { return nil }
            let data = try DownloadGaoActionPackage.readBounded(fd, limit: DownloadGaoActionPackage.maximumManifestBytes)
            try DownloadGaoActionPackage.requireUnchanged(before, DownloadGaoActionPackage.metadata(fd))
            guard data.count == before.st_size else { return nil }; return data
        } catch { return nil }
    }
    private func enforceBudget(additionalBytes: Int64 = 0) throws {
        let fd = try DownloadGaoActionPackage.ensurePrivateDirectory(rootURL); defer { close(fd) }
        var packageCount = 0; var entries = 0; var bytes: Int64 = 0
        func visit(_ parent: Int32, depth: Int) throws {
            guard depth <= 40 else { throw DownloadGaoDownloadContract.issue("exchange_budget", "交接目录过深，已停止新增包。") }
            for name in try DownloadGaoActionPackage.entries(parent) {
                entries += 1; guard entries <= 65_536 else { throw DownloadGaoDownloadContract.issue("exchange_budget", "交接留存达到限制，请先归档。") }
                var s = stat(); guard fstatat(parent, name, &s, AT_SYMLINK_NOFOLLOW) == 0 else { throw DownloadGaoExchangeJournal.invalid }
                if (s.st_mode & S_IFMT) == S_IFDIR {
                    if name.hasSuffix(".gaoaction") { packageCount += 1 }
                    let child = try DownloadGaoActionPackage.openDirectory(at: parent, name: name); defer { close(child) }; try DownloadGaoActionPackage.requirePrivateDirectory(child); try visit(child, depth: depth + 1)
                } else {
                    let file = try DownloadGaoActionPackage.openRegular(at: parent, name: name); defer { close(file) }; let info = try DownloadGaoActionPackage.requireRegular(file)
                    guard info.st_size >= 0, bytes <= 8 * 1024 * 1024 * 1024 - info.st_size else { throw DownloadGaoDownloadContract.issue("exchange_budget", "交接留存达到 8 GiB 限制。") }; bytes += info.st_size
                }
            }
        }
        try visit(fd, depth: 0)
        guard packageCount < 128, additionalBytes >= 0, bytes <= 8 * 1024 * 1024 * 1024 - additionalBytes else { throw DownloadGaoDownloadContract.issue("exchange_budget", "交接留存达到 128 包或 8 GiB 限制，请先归档。") }
    }
    private static func date(_ value: String) -> Date? { let f = ISO8601DateFormatter(); f.formatOptions = value.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]; return f.date(from: value) }
}
