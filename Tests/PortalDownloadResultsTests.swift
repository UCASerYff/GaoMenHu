import Foundation
import CryptoKit
import Darwin

private final class MemoryDownloadEvidence: PortalDownloadEvidenceStore {
    var value: Data?
    var saves = 0
    var failOnSave: Int?
    func load() throws -> Data? { value }
    func save(_ data: Data) throws {
        saves += 1
        if saves == failOnSave { throw PortalDownloadJournal.invalid }
        value = data
    }
}
@main struct PortalDownloadResultsTests {
    static var count = 0
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static func check(_ name: String, _ value: Bool) {
        count += 1; guard value else { fatalError(name) }
    }
    static func reject(_ name: String, _ body: () throws -> Void) {
        count += 1; do { try body(); fatalError("Expected rejection: " + name) } catch {}
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func main() throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("mendao-download-result-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        func path(_ name: String) -> URL { root.appendingPathComponent(name) }
        func outgoing(_ id: String = UUID().uuidString) throws -> GaoActionManifest {
            GaoActionManifest(kind: "request", requestID: id, sourceBundleID: "cn.mendao.launcher", targetBundleID: "com.gaoseries.GaoXiaZai", action: "downloads.prepare",
                createdAt: GaoActionPackage.iso8601(now), expiresAt: GaoActionPackage.iso8601(now.addingTimeInterval(120)), nonce: try GaoActionPackage.randomNonce(), items: [], references: [], parameters: ["urls": .array([.string("https://example.test/personal?credential=must-not-persist")])])
        }
        func result(_ request: GaoActionManifest, status: String = "pending", tasks: [String] = ["task-1"], time: Date = now.addingTimeInterval(10)) throws -> GaoActionManifest {
            var value = GaoActionManifest(kind: "result", requestID: UUID().uuidString, sourceBundleID: "com.gaoseries.GaoXiaZai", targetBundleID: "cn.mendao.launcher", action: "downloads.prepare",
                createdAt: GaoActionPackage.iso8601(time), expiresAt: GaoActionPackage.iso8601(time.addingTimeInterval(120)), nonce: try GaoActionPackage.randomNonce(), items: [], references: [], parameters: [:])
            value.inReplyTo = request.requestID
            value.status = status; value.provenance = ["workflowState": .string(status == "pending" ? "accepted" : status), "taskIDs": .array(tasks.map(GaoJSONValue.string))]
            return value
        }
        func received(_ manifest: GaoActionManifest, content: Data? = nil, time: Date = now.addingTimeInterval(11), staging: String = "Incoming") throws -> GaoActionReceivedPackage {
            var payloads: [String: URL] = [:]
            if let content {
                let file = path(UUID().uuidString + ".txt"); try content.write(to: file); _ = chmod(file.path, 0o600)
                payloads["output-1"] = file
            }
            let source = path("Outgoing").appendingPathComponent(UUID().uuidString + ".gaoaction")
            _ = try GaoActionPackage.write(manifest: manifest, to: source, payloads: payloads, now: time, validateAction: PortalDownloadJournal.validateResult)
            return try GaoActionPackage.receive(at: source, stagingRoot: path(staging), targetBundleID: "cn.mendao.launcher", now: time, validateAction: PortalDownloadJournal.validateResult)
        }
        let evidence = MemoryDownloadEvidence()
        var journal: PortalDownloadJournal? = try PortalDownloadJournal(directory: path("Downloads"), evidence: evidence)
        check("real first use creates independent initialized journal", journal!.allRecords.isEmpty && evidence.value != nil)
        let request = try outgoing(); try journal!.register(request, now: now)
        let initialFile = try Data(contentsOf: path("Downloads/outgoing.json"))
        check("register contains safe mapping only", journal!.allRecords.count == 1 && !String(decoding: initialFile, as: UTF8.self).contains("example.test") && !String(decoding: initialFile, as: UTF8.self).contains("credential"))
        try journal!.register(request, now: now)
        check("register same request idempotent", try Data(contentsOf: path("Downloads/outgoing.json")) == initialFile)
        var badRequest = request; badRequest.parameters = ["urls": .array([.string("https://other.test")])]
        reject("register changed request ID conflicts") { try journal!.register(badRequest, now: now) }
        badRequest = request; badRequest.parameters["mediaType"] = .number(1)
        reject("media type must be declared string") { try journal!.register(badRequest, now: now) }
        badRequest = request; badRequest.sourceBundleID = "other.app"
        reject("outgoing source fixed") { try journal!.register(badRequest, now: now) }
        badRequest = request; badRequest.targetBundleID = "other.app"
        reject("outgoing target fixed") { try journal!.register(badRequest, now: now) }
        badRequest = request; badRequest.action = "portal.prepareDownload"
        reject("outgoing action fixed") { try journal!.register(badRequest, now: now) }
        let unsafeErrorCodes = ["https://example.test/?token=secret", "token=secret", "", String(repeating: "a", count: 81), "UPPER_code", "spaces not_codes", "密码", "\n", "failed\n", "failed\r", "\0", "failed\t"]
        for code in unsafeErrorCodes {
            var failed = try result(request, status: "failed", tasks: [])
            failed.errorCode = code
            reject("unsafe error code rejected at result boundary") { try PortalDownloadJournal.validateResult(failed) }
        }
        for code: String? in [nil, "some_items_failed", String(repeating: "a", count: 80)] {
            var failed = try result(request, status: "failed", tasks: [])
            failed.errorCode = code
            try PortalDownloadJournal.validateResult(failed)
            check("nil and bounded snake error code accepted", true)
        }
        var pending = try result(request)
        var bad = pending; bad.provenance?["taskIDs"] = .array([])
        reject("pending must carry real task IDs") { try PortalDownloadJournal.validateResult(bad) }
        bad = pending; bad.provenance?["taskIDs"] = .array([.string("task-1"), .string("task-1")])
        reject("duplicate task IDs rejected") { try PortalDownloadJournal.validateResult(bad) }
        bad = pending; bad.provenance?["taskIDs"] = .array([.number(1)])
        reject("task ID types strict") { try PortalDownloadJournal.validateResult(bad) }
        bad = pending; bad.provenance?["taskIDs"] = .array([.string("task\n1")])
        reject("task ID controls rejected") { try PortalDownloadJournal.validateResult(bad) }
        bad = pending; bad.provenance?["workflowState"] = .string("handedOff")
        reject("handoff cannot claim task accepted") { try PortalDownloadJournal.validateResult(bad) }
        bad = pending; bad.provenance?["cookies"] = .string("not allowed")
        reject("extra private result fields rejected") { try PortalDownloadJournal.validateResult(bad) }
        bad = pending; bad.parameters["url"] = .string("https://example.test")
        reject("result parameters empty") { try PortalDownloadJournal.validateResult(bad) }
        bad = pending; bad.sourceBundleID = "other.app"
        reject("result source matched") { _ = try received(bad) }
        bad = pending; bad.targetBundleID = "other.app"
        reject("result target matched") { _ = try received(bad) }
        bad = pending; bad.action = "portal.prepareDownload"
        reject("result action matched") { _ = try received(bad) }
        bad = pending; bad.kind = "request"
        reject("result does not route as request") { _ = try received(bad) }
        bad = pending; bad.inReplyTo = UUID().uuidString
        reject("unknown inReplyTo rejected") { _ = try journal!.receive(received(bad), now: now.addingTimeInterval(11)) }
        reject("fresh result TTL enforced") { _ = try received(pending, time: now.addingTimeInterval(131)) }
        reject("future result blocked") { _ = try received(pending, time: now) }
        bad = pending; bad.requestID = request.requestID
        reject("result UUID must differ from original request UUID") { _ = try journal!.receive(received(bad), now: now.addingTimeInterval(11)) }
        let pendingCopy = try received(pending)
        if case .received(let record, let value) = try journal!.receive(pendingCopy, now: now.addingTimeInterval(11)) {
            check("pending recorded without files", record.taskIDs == ["task-1"] && value.items.isEmpty && value.status == "pending" && !record.terminal)
        } else { fatalError("not new pending") }
        if case .repeated = try journal!.receive(pendingCopy, now: now.addingTimeInterval(12)) { check("same pending UUID deduped", true) } else { fatalError("not repeated") }
        let persisted = try Data(contentsOf: path("Downloads/outgoing.json"))
        journal = nil
        journal = try PortalDownloadJournal(directory: path("Downloads"), evidence: evidence)
        if case .repeated = try journal!.receive(pendingCopy, now: now.addingTimeInterval(12)) { check("pending duplicate survives restart", true) } else { fatalError("not repeated") }
        bad = pending; bad.provenance?["taskIDs"] = .array([.string("forged-task")])
        reject("same result UUID different content rejected") { _ = try journal!.receive(received(bad), now: now.addingTimeInterval(11)) }
        bad = try result(request, tasks: ["forged-task"])
        reject("new result cannot replace accepted task IDs") { _ = try journal!.receive(received(bad), now: now.addingTimeInterval(11)) }
        check("bad result keeps exact journal", try Data(contentsOf: path("Downloads/outgoing.json")) == persisted)
        let second = try outgoing(); try journal!.register(second, now: now)
        reject("task ID cannot attach to another outgoing request") { _ = try journal!.receive(received(result(second)), now: now.addingTimeInterval(11)) }
        let ordinary = Data("synthetic downloaded content\n".utf8)
        var final = try result(request, status: "completed", time: now.addingTimeInterval(300))
        reject("completed without actual files rejected") { try PortalDownloadJournal.validateResult(final) }
        let item = GaoActionItem(id: "output-1", relativePath: "result.txt", uti: "public.plain-text", byteCount: Int64(ordinary.count), sha256: hash(ordinary))
        final.items = [item]
        var wrongDigest = final; wrongDigest.items[0].sha256 = String(repeating: "0", count: 64)
        reject("actual hash required by FD codec") { _ = try received(wrongDigest, content: ordinary, time: now.addingTimeInterval(301)) }
        var earlyFinal = final; earlyFinal.inReplyTo = second.requestID
        reject("unaccepted tasks cannot complete unrelated request") { _ = try journal!.receive(received(earlyFinal, content: ordinary, time: now.addingTimeInterval(301)), now: now.addingTimeInterval(301)) }
        let finalCopy = try received(final, content: ordinary, time: now.addingTimeInterval(301))
        check("private staging independent from provider source", finalCopy.packageURL.deletingLastPathComponent() == path("Incoming") && finalCopy.packageURL.lastPathComponent != final.requestID + ".gaoaction")
        check("private payload exists and SHA matches", try Data(contentsOf: finalCopy.payloadURL.appendingPathComponent("result.txt")) == ordinary)
        let original = path("user-download.txt"); try Data("user original".utf8).write(to: original)
        if case .received(let record, let value) = try journal!.receive(finalCopy, now: now.addingTimeInterval(301)) {
            check("terminal arrives after original request expiry", record.terminal && value.items.count == 1 && value.status == "completed")
        } else { fatalError("not new final") }
        check("no automatic overwrite", try Data(contentsOf: original) == Data("user original".utf8))
        if case .repeated = try journal!.receive(finalCopy, now: now.addingTimeInterval(302)) { check("final result retry deduped", true) } else { fatalError("not repeated") }
        pending = try result(request, time: now.addingTimeInterval(310))
        reject("terminal cannot regress to later pending") { _ = try journal!.receive(received(pending, time: now.addingTimeInterval(311)), now: now.addingTimeInterval(311)) }
        let secondPending = try result(second, tasks: ["task-a", "task-b"])
        _ = try journal!.receive(received(secondPending), now: now.addingTimeInterval(11))
        var partial = try result(second, status: "partial", tasks: ["task-b", "task-a"])
        partial.items = [item]; partial.errorCode = "some_items_failed"
        if case .received(let record, let value) = try journal!.receive(received(partial, content: ordinary), now: now.addingTimeInterval(11)) {
            check("partial stores actual files and multiple matching tasks", record.terminal && value.status == "partial" && value.taskIDs == ["task-a", "task-b"])
        } else { fatalError("not partial") }
        for status in ["failed", "cancelled", "unsupported"] {
            let req = try outgoing(); try journal!.register(req, now: now)
            let fail = try result(req, status: status, tasks: [])
            if case .received(let record, let value) = try journal!.receive(received(fail), now: now.addingTimeInterval(11)) {
                check("preaccept \(status) no false tasks/files", record.terminal && value.items.isEmpty && record.taskIDs.isEmpty)
            } else { fatalError("not cancelled") }
        }
        journal = nil
        journal = try PortalDownloadJournal(directory: path("Downloads"), evidence: evidence)
        check("all terminal mappings durable", journal!.allRecords.count == 5 && journal!.allRecords.allSatisfy(\.terminal))
        reject("exclusive live journal lock blocks second writer") { _ = try PortalDownloadJournal(directory: path("Downloads"), evidence: evidence) }
        let last = try Data(contentsOf: path("Downloads/outgoing.json"))
        try FileManager.default.removeItem(at: path("Downloads/outgoing.json"))
        reject("live missing outgoing file blocks new work") { try journal!.register(outgoing(), now: now) }
        journal = nil
        reject("initialized missing outgoing file not reset") { _ = try PortalDownloadJournal(directory: path("Downloads"), evidence: evidence) }
        check("missing file not recreated", !FileManager.default.fileExists(atPath: path("Downloads/outgoing.json").path))
        try last.write(to: path("Downloads/outgoing.json")); _ = chmod(path("Downloads/outgoing.json").path, 0o600)
        journal = try PortalDownloadJournal(directory: path("Downloads"), evidence: evidence)
        check("verified exact restoration readable", journal!.allRecords.count == 5)
        journal = nil
        try FileManager.default.moveItem(at: path("Downloads"), to: path("Downloads-retained"))
        reject("whole initialized directory missing blocks") { _ = try PortalDownloadJournal(directory: path("Downloads"), evidence: evidence) }
        check("missing directory not recreated", !FileManager.default.fileExists(atPath: path("Downloads").path))
        try FileManager.default.moveItem(at: path("Downloads-retained"), to: path("Downloads"))
        try Data("corrupt".utf8).write(to: path("Downloads/outgoing.json"))
        reject("corruption blocks without reset") { _ = try PortalDownloadJournal(directory: path("Downloads"), evidence: evidence) }
        check("corruption preserved", try Data(contentsOf: path("Downloads/outgoing.json")) == Data("corrupt".utf8))
        try last.write(to: path("Downloads/outgoing.json")); _ = chmod(path("Downloads/outgoing.json").path, 0o644)
        reject("nonprivate journal blocked") { _ = try PortalDownloadJournal(directory: path("Downloads"), evidence: evidence) }
        _ = chmod(path("Downloads/outgoing.json").path, 0o600)
        _ = chmod(path("Downloads").path, 0o500)
        reject("readonly journal directory blocked") { _ = try PortalDownloadJournal(directory: path("Downloads"), evidence: evidence) }
        _ = chmod(path("Downloads").path, 0o700)
        guard symlink(path("Downloads").path, path("Downloads-link").path) == 0 else { fatalError("symlink fixture") }
        reject("symlink journal rejected") { _ = try PortalDownloadJournal(directory: path("Downloads-link"), evidence: evidence) }
        let lostEvidence = MemoryDownloadEvidence()
        reject("existing directory missing external evidence not reset") { _ = try PortalDownloadJournal(directory: path("Downloads"), evidence: lostEvidence) }
        let interruptedEvidence = MemoryDownloadEvidence()
        var interruptedJournal: PortalDownloadJournal? = try PortalDownloadJournal(directory: path("interrupted-lock"), evidence: interruptedEvidence)
        try FileManager.default.moveItem(at: path("interrupted-lock/journal.lock"), to: path("interrupted-lock/original-lock-retained"))
        FileManager.default.createFile(atPath: path("interrupted-lock/journal.lock").path, contents: Data(), attributes: [.posixPermissions: 0o600])
        reject("replaced lock inode prevents competing writes") { try interruptedJournal!.register(outgoing(), now: now) }
        interruptedJournal = nil
        let futureEvidence = MemoryDownloadEvidence()
        var futureJournal: PortalDownloadJournal? = try PortalDownloadJournal(directory: path("future-schema"), evidence: futureEvidence)
        check("future fixture initializes empty", futureJournal!.allRecords.isEmpty)
        futureJournal = nil
        let futureFile = path("future-schema/outgoing.json")
        var futureObject = try JSONSerialization.jsonObject(with: Data(contentsOf: futureFile)) as! [String: Any]
        futureObject["schemaVersion"] = 2
        let futureData = try JSONSerialization.data(withJSONObject: futureObject)
        try futureData.write(to: futureFile)
        var futureMarker = try JSONSerialization.jsonObject(with: futureEvidence.value!) as! [String: Any]
        futureMarker["sha256"] = hash(futureData)
        futureEvidence.value = try JSONSerialization.data(withJSONObject: futureMarker)
        reject("future schema rejected even when digest matches") { _ = try PortalDownloadJournal(directory: path("future-schema"), evidence: futureEvidence) }
        check("future schema bytes retained", try Data(contentsOf: futureFile) == futureData)
        let persistedCodeEvidence = MemoryDownloadEvidence()
        let persistedCodeDirectory = path("persisted-error-code")
        var persistedCodeJournal: PortalDownloadJournal? = try PortalDownloadJournal(directory: persistedCodeDirectory, evidence: persistedCodeEvidence)
        let persistedCodeRequest = try outgoing(); try persistedCodeJournal!.register(persistedCodeRequest, now: now)
        var safeFailure = try result(persistedCodeRequest, status: "failed", tasks: [])
        safeFailure.errorCode = "some_items_failed"
        _ = try persistedCodeJournal!.receive(received(safeFailure), now: now.addingTimeInterval(11))
        persistedCodeJournal = nil
        let persistedCodeFile = persistedCodeDirectory.appendingPathComponent("outgoing.json")
        let safeCodeData = try Data(contentsOf: persistedCodeFile)
        let safeCodeEvidence = persistedCodeEvidence.value!
        for code in unsafeErrorCodes {
            var object = try JSONSerialization.jsonObject(with: safeCodeData) as! [String: Any]
            var records = object["records"] as! [[String: Any]]
            var results = records[0]["results"] as! [[String: Any]]
            results[0]["errorCode"] = code; records[0]["results"] = results; object["records"] = records
            let data = try JSONSerialization.data(withJSONObject: object)
            try data.write(to: persistedCodeFile)
            var marker = try JSONSerialization.jsonObject(with: safeCodeEvidence) as! [String: Any]
            marker["sha256"] = hash(data)
            persistedCodeEvidence.value = try JSONSerialization.data(withJSONObject: marker)
            reject("unsafe persisted error code rejected even with matching evidence") { _ = try PortalDownloadJournal(directory: persistedCodeDirectory, evidence: persistedCodeEvidence) }
        }
        try safeCodeData.write(to: persistedCodeFile); persistedCodeEvidence.value = safeCodeEvidence
        let restoredCodeJournal = try PortalDownloadJournal(directory: persistedCodeDirectory, evidence: persistedCodeEvidence)
        check("normal persisted snake code remains readable", restoredCodeJournal.allRecords.first?.results.first?.errorCode == "some_items_failed")
        for save in 1...2 {
            let failedEvidence = MemoryDownloadEvidence(); failedEvidence.failOnSave = save
            let dir = path("initialization-\(save)")
            reject("initialization interruption at save \(save)") { _ = try PortalDownloadJournal(directory: dir, evidence: failedEvidence) }
            failedEvidence.failOnSave = nil
            reject("interrupted initialization cannot reset") { _ = try PortalDownloadJournal(directory: dir, evidence: failedEvidence) }
        }
        for failAfter in 1...2 {
            let failedEvidence = MemoryDownloadEvidence(); let dir = path("transaction-\(failAfter)")
            var failedJournal: PortalDownloadJournal? = try PortalDownloadJournal(directory: dir, evidence: failedEvidence)
            failedEvidence.failOnSave = failedEvidence.saves + failAfter
            reject("transaction interruption save \(failAfter)") { try failedJournal!.register(outgoing(), now: now) }
            failedJournal = nil; failedEvidence.failOnSave = nil
            if failAfter == 1 {
                // An injected failure before publishing pending evidence leaves the exact old committed generation.
                let recovered = try PortalDownloadJournal(directory: dir, evidence: failedEvidence)
                check("failed precommit retains exact empty generation", recovered.allRecords.isEmpty)
            } else { reject("interrupted final evidence blocks restart") { _ = try PortalDownloadJournal(directory: dir, evidence: failedEvidence) } }
        }
        print("Portal download result checks passed: \(count)")
    }
}
