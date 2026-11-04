import Foundation
import CryptoKit
import Darwin

final class EmbeddedDownloadMemoryEvidence: DownloadGaoExchangeEvidence {
    var data: Data?
    var failSave = false
    func load() throws -> Data? { data }
    func save(_ value: Data) throws { if failSave { throw DownloadGaoExchangeJournal.invalid }; data = value }
}

@main
struct EmbeddedDownloadExchangeTests {
    static var passed = 0
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw NSError(domain: "ExchangeTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }; passed += 1
    }
    static func rejects(_ message: String, _ action: () throws -> Void) throws {
        do { try action() } catch { passed += 1; return }; throw NSError(domain: "ExchangeTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "未拒绝：" + message])
    }
    static func manifest(id: UUID = UUID(), urls: [String] = ["https://example.invalid/test.bin"], media: String? = "file", source: String = "cn.mendao.launcher", now: Date = Date()) throws -> DownloadGaoActionManifest {
        var p: [String: DownloadGaoJSONValue] = ["urls": .array(urls.map(DownloadGaoJSONValue.string))]; if let media { p["mediaType"] = .string(media) }
        return DownloadGaoActionManifest(kind: "request", requestID: id.uuidString.lowercased(), sourceBundleID: source, targetBundleID: DownloadGaoDownloadContract.bundleID, action: "downloads.prepare", createdAt: DownloadGaoActionPackage.iso8601(now.addingTimeInterval(-1)), expiresAt: DownloadGaoActionPackage.iso8601(now.addingTimeInterval(119)), nonce: try DownloadGaoActionPackage.randomNonce(), items: [], references: [], parameters: p)
    }
    static func write(_ m: DownloadGaoActionManifest, _ root: URL, rawValidation: Bool = false) throws -> URL {
        let url = root.appendingPathComponent(UUID().uuidString + ".gaoaction", isDirectory: true)
        return try DownloadGaoActionPackage.write(manifest: m, to: url, validateAction: rawValidation ? { _ in } : DownloadGaoDownloadContract.validateRequest)
    }
    @MainActor
    static func main() throws {
        let temporary = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("GaoMenHu-EmbeddedExchange-Tests-" + UUID().uuidString + ".noindex", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let futureEvidenceDirectory = temporary.appendingPathComponent("EvidencePath", isDirectory: true)
        let initialKey = DownloadGaoExchangeDefaultsEvidence.evidenceKey(for: futureEvidenceDirectory)
        try FileManager.default.createDirectory(at: futureEvidenceDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try check(initialKey == DownloadGaoExchangeDefaultsEvidence.evidenceKey(for: futureEvidenceDirectory), "new evidence key must stay stable when the private physical directory comes into existence")
        let alias = URL(fileURLWithPath: futureEvidenceDirectory.path.replacingOccurrences(of: "/private/tmp/", with: "/tmp/"), isDirectory: true)
        try check(initialKey != DownloadGaoExchangeDefaultsEvidence.evidenceKey(for: alias), "unvalidated /tmp symlink alias must not replace the validated /private/tmp evidence path")
        let sources = temporary.appendingPathComponent("Sources", isDirectory: true)
        let sourceFD = try DownloadGaoActionPackage.ensurePrivateDirectory(sources); close(sourceFD)
        let m = try manifest()
        let package = try write(m, sources)
        let marker = EmbeddedDownloadMemoryEvidence()
        var exchange: DownloadGaoExchange? = DownloadGaoExchange(rootURL: temporary.appendingPathComponent("Exchange", isDirectory: true), evidence: marker)
        try check(exchange!.recoveryIssue == nil, "首次初始化失败")
        exchange!.receive(package)
        try check(exchange!.records.count == 1 && exchange!.records[0].stage == "awaitingReview" && exchange!.records[0].taskIDs.isEmpty, "接收包不得自动接受")
        exchange!.receive(package)
        try check(exchange!.records.count == 1, "重复包重复建记录")
        let id = UUID(uuidString: m.requestID)!
        try rejects("无真实任务的pending") { _ = try exchange!.makePendingResult(id) }
        var conflicting = m; conflicting.parameters["urls"] = .array([.string("https://example.invalid/different.bin")])
        exchange!.receive(try write(conflicting, sources))
        try check(exchange!.lastError != nil && exchange!.records[0].stage == "awaitingReview", "同UUID异内容必须拒绝")
        var reusedNonce = try manifest(); reusedNonce.nonce = m.nonce
        exchange!.receive(try write(reusedNonce, sources))
        try check(exchange!.records.count == 1 && exchange!.lastError != nil, "跨请求nonce重用未拒绝")
        for urls in [[], ["https://name:secret@example.invalid/a"], ["ftp://example.invalid/a"], ["https:///a"], Array(repeating: "https://example.invalid/a", count: 33)] {
            try rejects("URL契约") { try DownloadGaoDownloadContract.validateRequest(manifest(urls: urls)) }
        }
        try rejects("媒体类型") { try DownloadGaoDownloadContract.validateRequest(manifest(media: "video")) }
        try rejects("未知参数") { var v = try manifest(); v.parameters["command"] = .string("anything"); try DownloadGaoDownloadContract.validateRequest(v) }
        let jobs = [UUID()]; let items = [UUID()]
        try exchange!.accept(id, taskIDs: jobs); try exchange!.bindItems(id, itemIDs: items)
        try exchange!.accept(id, taskIDs: jobs)
        try check(exchange!.records[0].stage == "accepted", "真实任务接受失败")
        try rejects("改变已接受任务") { try exchange!.accept(id, taskIDs: [UUID()]) }
        let pending = try exchange!.makePendingResult(id)
        let pendingManifest = try JSONDecoder().decode(DownloadGaoActionManifest.self, from: Data(contentsOf: pending.appendingPathComponent("manifest.json")))
        try check(pendingManifest.status == "pending" && pendingManifest.provenance?["workflowState"]?.string == "accepted" && pendingManifest.items.isEmpty, "pending错误")
        let file = temporary.appendingPathComponent("actual-file.bin"); let content = Data("real committed file\n".utf8); try content.write(to: file)
        let digest = DownloadGaoActionPackage.digest(content)
        let outcome = DownloadGaoTaskOutcome(taskID: jobs[0], itemID: items[0], state: "completed", fileURL: file, byteCount: Int64(content.count), sha256: digest, errorCode: nil)
        let final = try exchange!.makeFinalResult(id, outcomes: [outcome])
        let finalManifest = try JSONDecoder().decode(DownloadGaoActionManifest.self, from: Data(contentsOf: final.appendingPathComponent("manifest.json")))
        try check(finalManifest.status == "completed" && finalManifest.inReplyTo == m.requestID && finalManifest.requestID != pendingManifest.requestID, "终态必须独立UUID关联原请求")
        try check(finalManifest.items.count == 2 && finalManifest.items.contains(where: { $0.uti == "public.json" }), "实际文件与任务回执缺失")
        try check(Set(finalManifest.provenance!.keys) == ["workflowState", "taskIDs"], "不兼容门户provenance")
        let verified = try DownloadGaoActionPackage.receive(at: final, stagingRoot: temporary.appendingPathComponent("PortalIncoming"), targetBundleID: "cn.mendao.launcher", validateAction: DownloadGaoDownloadContract.validateResult)
        try check(verified.manifest.items.contains(where: { $0.sha256 == digest && $0.id == items[0].uuidString.lowercased() }), "真实产物摘要或itemID丢失")
        let rootURL = exchange!.rootURL; exchange = nil
        exchange = DownloadGaoExchange(rootURL: rootURL, evidence: marker)
        try check(exchange!.recoveryIssue == nil && exchange!.records[0].hasFinalResult && exchange!.records[0].taskIDs == jobs && exchange!.records[0].itemIDs == items, "重启映射与结果未保留")
        try check(try exchange!.makeFinalResult(id, outcomes: [outcome]) == final, "终态重试重复打包")
        exchange!.receive(package)
        try check(exchange!.records[0].hasFinalResult && exchange!.records.count == 1, "重启重复prepare改变终态")
        // Corrupting an original committed output after packaging does not change its verified private copy.
        try Data("changed".utf8).write(to: file)
        let retry = try exchange!.makeFinalResult(id, outcomes: [outcome]); try check(retry == final, "发送重试不应重新下载")
        exchange = nil
        let journalURL = rootURL.appendingPathComponent("journal.json")
        let originalJournal = try Data(contentsOf: journalURL)
        try Data("broken".utf8).write(to: journalURL)
        let corrupted = DownloadGaoExchange(rootURL: rootURL, evidence: marker)
        try check(corrupted.recoveryIssue != nil && corrupted.records.isEmpty, "账本损坏未failclosed")
        try check(try Data(contentsOf: journalURL) == Data("broken".utf8), "损坏账本被覆盖")
        try originalJournal.write(to: journalURL)
        let missingRoot = temporary.appendingPathComponent("Missing", isDirectory: true)
        let missing = DownloadGaoExchange(rootURL: missingRoot, evidence: marker)
        try check(missing.recoveryIssue != nil && !FileManager.default.fileExists(atPath: missingRoot.path), "缺失原根目录被当新资料")
        let unmarkedRoot = temporary.appendingPathComponent("Unmarked", isDirectory: true)
        try FileManager.default.createDirectory(at: unmarkedRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let unmarked = DownloadGaoExchange(rootURL: unmarkedRoot, evidence: EmbeddedDownloadMemoryEvidence())
        try check(unmarked.recoveryIssue != nil, "已存在无marker根目录被重置")
        try awaitReviewAfterExpiry(temporary, sources)
        try partialAndFailure(temporary, sources)
        try transportRejections(temporary, sources)
        try legacyHistoryIsReadOnly(temporary, sources)
        print("EmbeddedDownloadExchangeTests: \(passed) targeted assertions passed; no app/browser launched")
    }
    @MainActor static func awaitReviewAfterExpiry(_ temporary: URL, _ sources: URL) throws {
        let now = Date(); let m = try manifest(now: now); let source = try write(m, sources)
        var clock = now
        let marker = EmbeddedDownloadMemoryEvidence(); let root = temporary.appendingPathComponent("Delayed", isDirectory: true)
        let exchange = DownloadGaoExchange(rootURL: root, evidence: marker, now: { clock }); exchange.receive(source)
        let id = UUID(uuidString: m.requestID)!
        clock = now.addingTimeInterval(121)
        try rejects("过期草案不得首次批准") { try exchange.preflightApproval(id) }
        try rejects("accept也验证首次TTL") { try exchange.accept(id, taskIDs: [UUID()]) }
        try check(exchange.records[0].stage == "awaitingReview" && exchange.records[0].taskIDs.isEmpty, "过期草案保留且不建假任务")
        // This opt-in is only for caller-verified core jobs created within the original TTL.
        try exchange.preflightApproval(id, allowingPreviouslyCreatedTasks: true)
        let existingJobs = [UUID()]; try exchange.accept(id, taskIDs: existingJobs)
        clock = now.addingTimeInterval(3600)
        try exchange.preflightApproval(id); try exchange.accept(id, taskIDs: existingJobs)
        _ = try exchange.makePendingResult(id)
        try check(exchange.records[0].stage == "accepted" && exchange.records[0].taskIDs == existingJobs, "有效期内既有真实任务不因原请求过期取消")
    }
    @MainActor static func partialAndFailure(_ temporary: URL, _ sources: URL) throws {
        let m = try manifest(urls: ["https://example.invalid/a", "https://example.invalid/b"])
        let exchange = DownloadGaoExchange(rootURL: temporary.appendingPathComponent("Partial", isDirectory: true), evidence: EmbeddedDownloadMemoryEvidence())
        exchange.receive(try write(m, sources)); let id = UUID(uuidString: m.requestID)!; let tasks = [UUID(), UUID()]; let items = [UUID(), UUID()]
        try exchange.accept(id, taskIDs: tasks); try exchange.bindItems(id, itemIDs: items); _ = try exchange.makePendingResult(id)
        let f = temporary.appendingPathComponent("partial-output"); let data = Data([1,2,3]); try data.write(to: f)
        let outcomes = [DownloadGaoTaskOutcome(taskID: tasks[0], itemID: items[0], state: "completed", fileURL: f, byteCount: 3, sha256: DownloadGaoActionPackage.digest(data), errorCode: nil), DownloadGaoTaskOutcome(taskID: tasks[1], itemID: items[1], state: "failed", fileURL: nil, byteCount: nil, sha256: nil, errorCode: "http_404")]
        try rejects("缺少任务终态") { _ = try exchange.makeFinalResult(id, outcomes: [outcomes[0]]) }
        let result = try exchange.makeFinalResult(id, outcomes: outcomes)
        let manifest = try JSONDecoder().decode(DownloadGaoActionManifest.self, from: Data(contentsOf: result.appendingPathComponent("manifest.json")))
        try check(manifest.status == "partial" && manifest.items.count == 2 && exchange.records[0].outcomes.map(\.state) == ["completed", "failed"], "partial映射丢失")
        let receipt = try Data(contentsOf: result.appendingPathComponent("payload/receipt/task-outcomes.json"))
        let receiptText = String(data: receipt, encoding: .utf8)!
        try check(receiptText.contains("http_404") && !receiptText.contains("https://") && !receiptText.contains(temporary.path), "回执缺失错误或泄漏路径URL")
        let cancel = try self.manifest(); let declined = DownloadGaoExchange(rootURL: temporary.appendingPathComponent("Declined", isDirectory: true), evidence: EmbeddedDownloadMemoryEvidence())
        declined.receive(try write(cancel, sources)); let cancelID = UUID(uuidString: cancel.requestID)!; declined.decline(cancelID)
        let cancelled = try declined.makeFinalResult(cancelID, outcomes: [])
        let value = try JSONDecoder().decode(DownloadGaoActionManifest.self, from: Data(contentsOf: cancelled.appendingPathComponent("manifest.json")))
        try check(value.status == "cancelled" && value.items.isEmpty && value.provenance?["taskIDs"]?.array == [], "未接受取消语义错误")
    }
    static func transportRejections(_ temporary: URL, _ sources: URL) throws {
        let m = try manifest(); let raw = try DownloadGaoActionPackage.manifestData(m)
        let text = String(data: raw, encoding: .utf8)!
        let duplicate = text.replacingOccurrences(of: "\"schemaVersion\" : 1", with: "\"schemaVersion\" : 1, \"schemaVersion\" : 1")
        try rejects("重复JSON字段") { _ = try DownloadGaoActionPackage.validate(data: Data(duplicate.utf8), targetBundleID: DownloadGaoDownloadContract.bundleID, now: Date(), validateAction: DownloadGaoDownloadContract.validateRequest) }
        var ttl = m; ttl.expiresAt = DownloadGaoActionPackage.iso8601(Date().addingTimeInterval(1000))
        try rejects("TTL超过120秒") { _ = try DownloadGaoActionPackage.validate(data: DownloadGaoActionPackage.manifestData(ttl), targetBundleID: DownloadGaoDownloadContract.bundleID, now: Date(), validateAction: DownloadGaoDownloadContract.validateRequest) }
        var nonce = m; nonce.nonce = "AA=="
        try rejects("无效nonce") { _ = try DownloadGaoActionPackage.validate(data: DownloadGaoActionPackage.manifestData(nonce), targetBundleID: DownloadGaoDownloadContract.bundleID, now: Date(), validateAction: DownloadGaoDownloadContract.validateRequest) }
        let linked = temporary.appendingPathComponent("linked-parent", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: sources)
        let package = try write(m, sources)
        try rejects("父目录符号链接") { _ = try DownloadGaoActionPackage.receive(at: linked.appendingPathComponent(package.lastPathComponent), stagingRoot: temporary.appendingPathComponent("Rejected"), targetBundleID: DownloadGaoDownloadContract.bundleID, validateAction: DownloadGaoDownloadContract.validateRequest) }
        let altered = try write(m, sources)
        try FileManager.default.createSymbolicLink(at: altered.appendingPathComponent("payload/extra"), withDestinationURL: temporary)
        try rejects("未声明附件/符号链接") { _ = try DownloadGaoActionPackage.receive(at: altered, stagingRoot: temporary.appendingPathComponent("Rejected"), targetBundleID: DownloadGaoDownloadContract.bundleID, validateAction: DownloadGaoDownloadContract.validateRequest) }
    }
    @MainActor static func legacyHistoryIsReadOnly(_ temporary: URL, _ sources: URL) throws {
        let m = try manifest()
        let root = temporary.appendingPathComponent("LegacyJournal", isDirectory: true)
        let marker = EmbeddedDownloadMemoryEvidence()
        var original: DownloadGaoExchange? = DownloadGaoExchange(rootURL: root, evidence: marker)
        original!.receive(try write(m, sources))
        try check(original!.records.count == 1, "canonical request should be registered")
        let journalURL = root.appendingPathComponent("journal.json")
        let raw = try Data(contentsOf: journalURL)
        original = nil
        var envelope = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
        var records = envelope["records"] as! [[String: Any]]
        var record = records[0]
        var declaration = record["manifest"] as! [String: Any]
        declaration["targetBundleID"] = DownloadGaoDownloadContract.legacyBundleID
        record["manifest"] = declaration
        let legacyManifest = try JSONDecoder().decode(DownloadGaoActionManifest.self, from: JSONSerialization.data(withJSONObject: declaration))
        let legacyManifestData = try DownloadGaoActionPackage.manifestData(legacyManifest)
        record["manifestSHA256"] = DownloadGaoActionPackage.digest(legacyManifestData)
        let incoming = root.appendingPathComponent("Incoming").appendingPathComponent(record["packageName"] as! String)
        try legacyManifestData.write(to: incoming.appendingPathComponent("manifest.json"))
        records[0] = record; envelope["records"] = records
        let legacyBytes = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        var evidence = try JSONSerialization.jsonObject(with: marker.data!) as! [String: Any]
        evidence["digest"] = DownloadGaoActionPackage.digest(legacyBytes)
        marker.data = try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys])
        let validated = try DownloadGaoExchangeJournal.validateHistoricalSnapshot(legacyBytes, evidence: marker.data!, directory: root)
        try check(validated.count == 1 && validated[0].isLegacyHistory, "legacy declarations retained only as migration history")
        try rejects("new contract must reject standalone provider") { try DownloadGaoDownloadContract.validateRequest(validated[0].manifest) }
        try legacyBytes.write(to: journalURL)
        let imported = DownloadGaoExchange(rootURL: root, evidence: marker)
        try check(imported.recoveryIssue == nil && imported.records[0].isLegacyHistory, "legacy history readable after migration")
        imported.receive(try write(legacyManifest, sources, rawValidation: true))
        try check(imported.lastError != nil && imported.records.count == 1, "retired provider request cannot be received as a new task")
        let id = validated[0].id
        try rejects("legacy approval cannot replay") { try imported.preflightApproval(id, allowingPreviouslyCreatedTasks: true) }
        try rejects("legacy cannot create new task mapping") { try imported.accept(id, taskIDs: [UUID()]) }
        try rejects("legacy cannot create new result") { _ = try imported.makePendingResult(id) }
        imported.decline(id)
        try check(imported.lastError != nil && imported.records[0].stage == "awaitingReview", "legacy history not mutated by UI decline")
        try check(try Data(contentsOf: journalURL) == legacyBytes, "legacy request bytes stay unchanged")
        var pendingMarker = evidence; pendingMarker["pending"] = true
        try rejects("migration cannot accept interrupted external evidence") {
            _ = try DownloadGaoExchangeJournal.validateHistoricalSnapshot(legacyBytes, evidence: JSONSerialization.data(withJSONObject: pendingMarker), directory: root)
        }
        var future = envelope; future["schemaVersion"] = 99
        let futureBytes = try JSONSerialization.data(withJSONObject: future)
        var futureMarker = evidence; futureMarker["digest"] = DownloadGaoActionPackage.digest(futureBytes)
        try rejects("migration cannot accept future journal schema") {
            _ = try DownloadGaoExchangeJournal.validateHistoricalSnapshot(futureBytes, evidence: JSONSerialization.data(withJSONObject: futureMarker), directory: root)
        }
        try rejects("migration cannot accept stale byte digest") {
            _ = try DownloadGaoExchangeJournal.validateHistoricalSnapshot(raw, evidence: marker.data!, directory: root)
        }
    }

}
