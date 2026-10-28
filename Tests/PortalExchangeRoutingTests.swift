import Foundation
import CryptoKit
import Darwin

private final class RoutingRequestEvidence: PortalLedgerEvidenceStore {
    var data: Data?
    func read() throws -> Data? { data }
    func write(_ value: Data) throws { data = value }
}
private final class RoutingDownloadEvidence: PortalDownloadEvidenceStore {
    var data: Data?
    func load() throws -> Data? { data }
    func save(_ value: Data) throws { data = value }
}

/// CLI-only reproduction of the missing old journal beside independently
/// initialized downloads. All files and evidence are synthetic and disposable.
@main struct PortalExchangeRoutingTests {
    static func main() throws {
        var count = 0
        func check(_ label: String, _ condition: @autoclosure () throws -> Bool) {
            guard (try? condition()) == true else { fatalError(label) }; count += 1
        }
        func rejects(_ label: String, _ code: String, _ body: () throws -> Void) {
            do { try body(); fatalError(label) }
            catch let error as PortalActionError { check(label, error.code == code) }
            catch { fatalError(label + ": unexpected " + String(describing: type(of: error))) }
        }
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("gaomenhu-routing-" + UUID().uuidString + ".noindex", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let exchange = root.appendingPathComponent("Exchange", isDirectory: true)
        let oldDirectory = exchange.appendingPathComponent("Journal", isDirectory: true)
        try FileManager.default.createDirectory(at: oldDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let oldEvidence = RoutingRequestEvidence()
        rejects("ambiguous old journal stays unavailable", "invalid_request_ledger") {
            _ = try PortalRequestLedger(directory: oldDirectory, evidence: oldEvidence)
        }
        check("old journal is not silently initialized", !FileManager.default.fileExists(atPath: oldDirectory.appendingPathComponent("requests.json").path) && oldEvidence.data == nil)

        let downloadsDirectory = exchange.appendingPathComponent("Downloads", isDirectory: true)
        let downloadsEvidence = RoutingDownloadEvidence()
        let downloads = try PortalDownloadJournal(directory: downloadsDirectory, evidence: downloadsEvidence)
        check("independent downloads can initialize beside protected old history", downloads.allRecords.isEmpty && downloadsEvidence.data != nil)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let requestID = UUID().uuidString.lowercased()
        let outgoing = GaoActionManifest(kind: "request", requestID: requestID,
            sourceBundleID: "cn.mendao.launcher", targetBundleID: "com.gaoseries.GaoXiaZai", action: "downloads.prepare",
            createdAt: GaoActionPackage.iso8601(now), expiresAt: GaoActionPackage.iso8601(now.addingTimeInterval(120)),
            nonce: try GaoActionPackage.randomNonce(), items: [], references: [], parameters: ["urls": .array([.string("https://example.test/public-file")])])
        try downloads.register(outgoing, now: now)
        check("direct outgoing request persists without old action ledger", downloads.allRecords.map(\.requestID) == [requestID])

        var oldGateCalls = 0
        func authorize(_ manifest: GaoActionManifest) throws {
            if manifest.kind == "result" { try PortalDownloadJournal.validateResult(manifest) }
            else { try PortalActionPlanner.validateParameters(action: manifest.action, parameters: manifest.parameters.mapValues(\.foundationValue), itemCount: manifest.items.count, referenceCount: manifest.references.count) }
            _ = try PortalExchangeRouting.route(kind: manifest.kind, inReplyTo: manifest.inReplyTo,
                requireRequestLedger: {
                    oldGateCalls += 1
                    let ledger = try PortalRequestLedger(directory: oldDirectory, evidence: oldEvidence)
                    try ledger.verifyAvailability()
                }, requireDownloadRequest: { reply in
                    try downloads.verifyAvailability()
                    guard downloads.allRecords.contains(where: { $0.requestID == reply }) else { throw PortalDownloadJournal.mismatch }
                })
        }
        let incoming = exchange.appendingPathComponent("Incoming", isDirectory: true)
        func pending() throws -> GaoActionManifest {
            var value = GaoActionManifest(kind: "result", requestID: UUID().uuidString.lowercased(),
                sourceBundleID: "com.gaoseries.GaoXiaZai", targetBundleID: "cn.mendao.launcher", action: "downloads.prepare",
                createdAt: GaoActionPackage.iso8601(now.addingTimeInterval(1)), expiresAt: GaoActionPackage.iso8601(now.addingTimeInterval(121)),
                nonce: try GaoActionPackage.randomNonce(), items: [], references: [], parameters: [:])
            value.inReplyTo = requestID; value.status = "pending"
            value.provenance = ["workflowState": .string("accepted"), "taskIDs": .array([.string("synthetic-task-1")])]
            return value
        }
        func source(_ manifest: GaoActionManifest, payloads: [String: URL] = [:]) throws -> URL {
            let package = root.appendingPathComponent("Source", isDirectory: true).appendingPathComponent(UUID().uuidString + ".gaoaction", isDirectory: true)
            return try GaoActionPackage.write(manifest: manifest, to: package, payloads: payloads, now: now.addingTimeInterval(2), validateAction: { value in
                if value.kind == "result" { try PortalDownloadJournal.validateResult(value) }
                else { try PortalActionPlanner.validateParameters(action: value.action, parameters: value.parameters.mapValues(\.foundationValue)) }
            })
        }
        func receive(_ package: URL) throws -> GaoActionReceivedPackage {
            try GaoActionPackage.receive(at: package, stagingRoot: incoming, targetBundleID: "cn.mendao.launcher", now: now.addingTimeInterval(3), validateAction: authorize)
        }
        func incomingNames() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: incoming.path).sorted()
        }
        let accepted = try pending()
        let copy = try receive(source(accepted))
        try authorize(copy.manifest)
        _ = try downloads.receive(copy, now: now.addingTimeInterval(4))
        check("known pending passes copy and consumption with old recovery active", downloads.allRecords[0].results.last?.status == "pending")
        check("download route never consults unavailable action history", oldGateCalls == 0)

        var oldRequest = outgoing
        oldRequest.targetBundleID = "cn.mendao.launcher"; oldRequest.sourceBundleID = "com.gaoseries.GaoCaoZuo"
        oldRequest.requestID = UUID().uuidString.lowercased(); oldRequest.action = "portal.focusSearch"; oldRequest.parameters = ["query": .string("public synthetic query")]
        let beforeOld = try incomingNames()
        rejects("old action request still fails before copy", "invalid_request_ledger") { _ = try receive(source(oldRequest)) }
        check("failed old action does not create private copy", try incomingNames() == beforeOld)
        check("old action consulted only its own ledger", oldGateCalls == 1 && downloads.allRecords[0].results.count == 1)

        let bytes = Data("Synthetic public file; no account or credentials.\n".utf8)
        let artifactDigest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let artifact = root.appendingPathComponent("public.txt")
        try bytes.write(to: artifact); guard chmod(artifact.path, 0o600) == 0 else { fatalError("fixture permission") }
        var final = try pending(); final.status = "completed"; final.provenance?["workflowState"] = .string("completed")
        final.items = [GaoActionItem(id: "public-file-1", relativePath: "payload/public.txt", uti: "public.plain-text", byteCount: Int64(bytes.count), sha256: artifactDigest)]
        let finalSource = try source(final, payloads: ["public-file-1": artifact])
        var unknown = final; unknown.requestID = UUID().uuidString.lowercased(); unknown.inReplyTo = UUID().uuidString.lowercased()
        let beforeUnknown = try incomingNames()
        rejects("unknown download correlation fails before file copy", "unmatched_download_result") { _ = try receive(source(unknown, payloads: ["public-file-1": artifact])) }
        check("unknown result does not create private copy", try incomingNames() == beforeUnknown)
        let finalCopy = try receive(finalSource)
        check("known completion payload is privately copied despite old recovery", try Data(contentsOf: finalCopy.payloadURL.appendingPathComponent("public.txt")) == bytes)
        check("payload verified against manifest digest", finalCopy.manifest.items[0].sha256 == artifactDigest)
        try FileManager.default.removeItem(at: downloadsDirectory.appendingPathComponent("outgoing.json"))
        rejects("lost download history blocks consumption after copy", "invalid_download_journal") { try authorize(finalCopy.manifest) }
        let beforeLost = try incomingNames()
        rejects("lost download history blocks future copies", "invalid_download_journal") { _ = try receive(finalSource) }
        let afterLost = try incomingNames()
        check("lost download history is not rebuilt", !FileManager.default.fileExists(atPath: downloadsDirectory.appendingPathComponent("outgoing.json").path) && afterLost == beforeLost)
        check("old protected journal bytes and evidence remain untouched", try FileManager.default.contentsOfDirectory(atPath: oldDirectory.path).isEmpty && oldEvidence.data == nil)
        print("Portal exchange routing tests passed: \(count); synthetic CLI only, no App or browser launched")
    }
}
