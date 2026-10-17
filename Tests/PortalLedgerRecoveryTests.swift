import Foundation
import Darwin
import CryptoKit

private final class RecoveryEvidence: PortalLedgerEvidenceStore {
    var value: Data?
    var failReads = false
    var failWrites = false
    func read() throws -> Data? {
        if failReads { throw PortalActionError.invalidLedger }
        return value
    }
    func write(_ data: Data) throws {
        if failWrites { throw PortalActionError.invalidLedger }
        value = data
    }
}
private struct LegacyJournal: Encodable { let schemaVersion = 1; let records: [PortalRequestRecord] }

@main struct PortalLedgerRecoveryTests {
    static func main() throws {
        let fm = FileManager.default
        let temporary = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("mendao-ledger-recovery-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: temporary) }
        let now = Date(timeIntervalSince1970: 1_760_270_400)
        let requestID = "22222222-2222-4222-8222-000000000001"
        let fingerprint = String(repeating: "a", count: 64)
        var count = 0
        func check(_ name: String, _ body: @autoclosure () throws -> Bool) {
            guard (try? body()) == true else { fatalError(name) }
            count += 1
        }
        func rejected(_ name: String, _ body: () throws -> Void) {
            do { try body(); fatalError("Expected fail-closed: " + name) }
            catch let error as PortalActionError { check(name, error.code == "invalid_request_ledger") }
            catch { fatalError("Unexpected failure type: " + name) }
        }
        func fixture(_ name: String) throws -> (URL, RecoveryEvidence) {
            let base = temporary.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            return (base.appendingPathComponent("MenDao/Exchange/Journal", isDirectory: true), RecoveryEvidence())
        }
        func open(_ directory: URL, _ evidence: RecoveryEvidence, at date: Date? = nil,
                  checkpoint: ((String) throws -> Void)? = nil) throws -> PortalRequestLedger {
            try PortalRequestLedger(directory: directory, now: date ?? now, evidence: evidence, checkpoint: checkpoint)
        }
        func completed(_ ledger: PortalRequestLedger) throws {
            _ = try ledger.receive(requestID: requestID, fingerprint: fingerprint, action: "portal.openSite", now: now)
            _ = try ledger.approve(requestID: requestID, now: now)
            _ = try ledger.beginExecution(requestID: requestID, now: now)
            _ = try ledger.finish(requestID: requestID, outcome: PortalActionOutcome(status: .completed, workflowState: .opened), now: now)
        }
        func repeated(_ ledger: PortalRequestLedger) throws -> Bool {
            if case .repeated(let record) = try ledger.receive(requestID: requestID, fingerprint: fingerprint, action: "portal.openSite", now: now) {
                return record.requestID == requestID && record.state != .received
            }
            return false
        }
        func bytes(_ directory: URL) throws -> Data { try Data(contentsOf: directory.appendingPathComponent("requests.json")) }
        func fingerprintOfTree(_ root: URL) throws -> [String: String] {
            guard fm.fileExists(atPath: root.path) else { return [:] }
            var values: [String: String] = [:]
            let items = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])!
            for case let url as URL in items {
                if (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
                    values[String(url.path.dropFirst(root.path.count))] = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
                }
            }
            return values
        }
        func legacy(_ name: String, state: PortalRequestState = .completed) throws -> (URL, RecoveryEvidence) {
            let (directory, evidence) = try fixture(name)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let record = PortalRequestRecord(requestID: requestID, fingerprint: fingerprint, action: "portal.openSite", state: state,
                receivedAt: now, updatedAt: now, outcome: state == .executing ? PortalActionOutcome(status: .pending, workflowState: .accepted) : PortalActionOutcome(status: .completed, workflowState: .opened))
            let data = try JSONEncoder().encode(LegacyJournal(records: [record]))
            try data.write(to: directory.appendingPathComponent("requests.json"))
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: directory.appendingPathComponent("requests.json").path)
            return (directory, evidence)
        }

        // Real first use writes an empty V2 ledger and the independent evidence
        // before any request is accepted, rather than keeping an unmarked folder.
        let (freshDirectory, freshEvidence) = try fixture("fresh")
        let fresh = try open(freshDirectory, freshEvidence)
        check("true first use creates private durable empty journal", fresh.allRecords.isEmpty && freshEvidence.value != nil && fm.fileExists(atPath: fresh.file.path))
        let initial = try JSONSerialization.jsonObject(with: bytes(freshDirectory)) as! [String: Any]
        check("new envelope uses fenced schema and first generation", initial["schemaVersion"] as? Int == 2 && initial["generation"] as? Int == 1)
        check("empty initialized journal reloads", try open(freshDirectory, freshEvidence).allRecords.isEmpty)
        try completed(fresh)
        let completedBytes = try bytes(freshDirectory)
        let evidenceBytes = freshEvidence.value
        check("completed UUID survives cold ledger reopen", try repeated(open(freshDirectory, freshEvidence)))
        check("cold reopen preserves completed ledger bytes", try bytes(freshDirectory) == completedBytes && freshEvidence.value == evidenceBytes)
        try fm.removeItem(at: fresh.file)
        rejected("deleted completed journal cannot initialize as empty") { _ = try open(freshDirectory, freshEvidence) }
        rejected("live object cannot accept old UUID after source deletion") { _ = try fresh.receive(requestID: requestID, fingerprint: fingerprint, action: "portal.openSite", now: now) }
        check("missing completed ledger is not recreated", !fm.fileExists(atPath: fresh.file.path) && freshEvidence.value == evidenceBytes)

        for component in ["Journal", "Exchange", "MenDao"] {
            let (directory, evidence) = try fixture("removed-" + component)
            let ledger = try open(directory, evidence); try completed(ledger)
            let prior = evidence.value
            var removed = directory
            while removed.lastPathComponent != component { removed.deleteLastPathComponent() }
            try fm.removeItem(at: removed)
            rejected("independent evidence survives entire " + component + " deletion") { _ = try open(directory, evidence) }
            check("deleted " + component + " not manufactured again", !fm.fileExists(atPath: removed.path) && evidence.value == prior)
        }
        let (missingEvidenceDirectory, missingEvidence) = try fixture("missing-independent-evidence")
        let missingEvidenceLedger = try open(missingEvidenceDirectory, missingEvidence); try completed(missingEvidenceLedger)
        let missingEvidenceBytes = try bytes(missingEvidenceDirectory)
        missingEvidence.value = nil
        rejected("V2 cannot migrate after its fence disappears") { _ = try open(missingEvidenceDirectory, missingEvidence) }
        check("missing fence never overwrites V2", try bytes(missingEvidenceDirectory) == missingEvidenceBytes && missingEvidence.value == nil)

        // V1 migration keeps old UUIDs and timestamps. An uncertain execution is
        // terminal interrupted, with no callback or site/browser effect replay.
        let (legacyDirectory, legacyEvidence) = try legacy("legacy-valid")
        let oldBytes = try bytes(legacyDirectory)
        let migrated = try open(legacyDirectory, legacyEvidence)
        check("valid V1 records migrate and stay repeated", try repeated(migrated))
        check("V1 migration changes only journal format", migrated.record(requestID: requestID)?.receivedAt == now && migrated.record(requestID: requestID)?.outcome.workflowState == .opened)
        check("migration creates independent evidence and V2 envelope", try legacyEvidence.value != nil && bytes(legacyDirectory) != oldBytes)
        let (executingLegacy, executingEvidence) = try legacy("legacy-executing", state: .executing)
        let migratedInterrupted = try open(executingLegacy, executingEvidence)
        check("legacy executing becomes interrupted rather than replay", migratedInterrupted.record(requestID: requestID)?.outcome.errorCode == "interrupted_execution" && migratedInterrupted.record(requestID: requestID)?.state == .failed)
        check("legacy interrupted UUID remains repeated", try repeated(migratedInterrupted))

        for artifact in ["Contexts", "Incoming", "Outgoing"] {
            let (directory, evidence) = try fixture("legacy-missing-" + artifact)
            let prior = directory.deletingLastPathComponent().appendingPathComponent(artifact)
            try fm.createDirectory(at: prior, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let source = prior.appendingPathComponent("old-receipt.json")
            try Data("retained-private-fixture".utf8).write(to: source)
            let before = try fingerprintOfTree(directory.deletingLastPathComponent())
            rejected("legacy " + artifact + " proves missing ledger is not first use") { _ = try open(directory, evidence) }
            check("legacy " + artifact + " and missing journal remain untouched", try fingerprintOfTree(directory.deletingLastPathComponent()) == before && !fm.fileExists(atPath: directory.path) && evidence.value == nil)
        }
        let (emptyLegacyDirectory, emptyLegacyEvidence) = try fixture("legacy-empty-ambiguous")
        try fm.createDirectory(at: emptyLegacyDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        rejected("existing empty unfenced journal is ambiguous history") { _ = try open(emptyLegacyDirectory, emptyLegacyEvidence) }
        check("ambiguous empty journal receives no replacement or evidence", (try fm.contentsOfDirectory(atPath: emptyLegacyDirectory.path)).isEmpty && emptyLegacyEvidence.value == nil)
        let (lostLegacyDirectory, lostLegacyEvidence) = try legacy("legacy-completed-deleted-before-upgrade")
        try fm.removeItem(at: lostLegacyDirectory.appendingPathComponent("requests.json"))
        rejected("completed V1 file lost before upgrade cannot be first use") { _ = try open(lostLegacyDirectory, lostLegacyEvidence) }
        check("lost V1 journal not recreated during upgrade", (try fm.contentsOfDirectory(atPath: lostLegacyDirectory.path)).isEmpty && lostLegacyEvidence.value == nil)

        let (stagingDirectory, stagingEvidence) = try fixture("orphaned-staging")
        try fm.createDirectory(at: stagingDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let orphan = stagingDirectory.appendingPathComponent(".requests-interrupted")
        try Data("orphan".utf8).write(to: orphan)
        rejected("unfenced orphan is historical state, not empty journal") { _ = try open(stagingDirectory, stagingEvidence) }
        check("unfenced orphan preserved", try Data(contentsOf: orphan) == Data("orphan".utf8) && stagingEvidence.value == nil)

        // Missing, bad, future, and permission failures all preserve original
        // bytes and fence; there is no chmod repair or default replacement.
        for corruption in ["malformed", "future", "unknown-state", "wrong-outcome", "generation"] {
            let (directory, evidence) = try fixture(corruption)
            let ledger = try open(directory, evidence); try completed(ledger)
            var object = try JSONSerialization.jsonObject(with: bytes(directory)) as! [String: Any]
            switch corruption {
            case "future": object["schemaVersion"] = 500
            case "generation": object["generation"] = 0
            case "unknown-state":
                var list = object["records"] as! [[String: Any]]; list[0]["state"] = "unknownExecuting"; object["records"] = list
            case "wrong-outcome":
                var list = object["records"] as! [[String: Any]]; list[0]["state"] = "received"; object["records"] = list
            default: break
            }
            let broken = corruption == "malformed" ? Data("{broken".utf8) : try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            try broken.write(to: ledger.file)
            let priorEvidence = evidence.value
            rejected(corruption + " ledger blocks startup") { _ = try open(directory, evidence) }
            rejected(corruption + " ledger blocks live receive") { _ = try ledger.receive(requestID: requestID, fingerprint: fingerprint, action: "portal.openSite", now: now) }
            check(corruption + " evidence and ledger unchanged", try bytes(directory) == broken && evidence.value == priorEvidence)
        }
        for mode in [0o000, 0o400, 0o644, 0o700] {
            let (directory, evidence) = try fixture("file-mode-" + String(mode))
            let ledger = try open(directory, evidence); try completed(ledger)
            let original = try bytes(directory); let priorEvidence = evidence.value
            try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: ledger.file.path)
            rejected("unsafe or unreadable file mode " + String(mode)) { _ = try open(directory, evidence) }
            check("file permission failure retains evidence", evidence.value == priorEvidence)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ledger.file.path)
            check("file permission failure retains original bytes", try bytes(directory) == original)
        }
        for mode in [0o000, 0o500, 0o755] {
            let (directory, evidence) = try fixture("directory-mode-" + String(mode))
            let ledger = try open(directory, evidence); try completed(ledger)
            let original = try bytes(directory); let priorEvidence = evidence.value
            try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: directory.path)
            rejected("unsafe or inaccessible journal mode " + String(mode)) { _ = try open(directory, evidence) }
            check("directory permission failure retains fence", evidence.value == priorEvidence)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            check("directory permission failure retains original bytes", try bytes(directory) == original)
        }
        let (futureFenceDirectory, futureFence) = try fixture("future-fence")
        let futureFenceLedger = try open(futureFenceDirectory, futureFence); try completed(futureFenceLedger)
        let futureFenceBytes = try bytes(futureFenceDirectory)
        var futureFenceObject = try JSONSerialization.jsonObject(with: futureFence.value!) as! [String: Any]
        futureFenceObject["schemaVersion"] = 100
        futureFence.value = try JSONSerialization.data(withJSONObject: futureFenceObject)
        let futureFenceOriginal = futureFence.value
        rejected("future independent evidence not overwritten") { _ = try open(futureFenceDirectory, futureFence) }
        check("future fence and ledger preserved", try bytes(futureFenceDirectory) == futureFenceBytes && futureFence.value == futureFenceOriginal)
        futureFence.value = Data("not-json".utf8)
        rejected("damaged evidence not ignored") { _ = try open(futureFenceDirectory, futureFence) }
        check("damaged evidence preserved", futureFence.value == Data("not-json".utf8))

        let (identityDirectory, identityEvidence) = try fixture("identity")
        let identityLedger = try open(identityDirectory, identityEvidence); try completed(identityLedger)
        let hardLink = identityDirectory.appendingPathComponent("linked")
        check("hardlink fixture creation", link(identityLedger.file.path, hardLink.path) == 0)
        rejected("hardlinked source rejected") { _ = try open(identityDirectory, identityEvidence) }
        try fm.removeItem(at: hardLink)
        let renamedDirectory = identityDirectory.deletingLastPathComponent().appendingPathComponent("Renamed")
        try fm.moveItem(at: identityDirectory, to: renamedDirectory)
        try fm.createSymbolicLink(at: identityDirectory, withDestinationURL: renamedDirectory)
        rejected("directory symlink rejected") { _ = try open(identityDirectory, identityEvidence) }
        rejected("pinned FD cannot hide a source directory replacement") { _ = try identityLedger.receive(requestID: UUID().uuidString, fingerprint: fingerprint, action: "portal.focusSearch", now: now) }
        check("directory swap did not alter original ledger", try bytes(renamedDirectory).count > 0)
        let parentAlias = temporary.appendingPathComponent("parent-alias")
        try fm.createSymbolicLink(at: parentAlias, withDestinationURL: renamedDirectory.deletingLastPathComponent())
        rejected("symlink ancestor rejected") { _ = try open(parentAlias.appendingPathComponent("Renamed"), identityEvidence) }

        let (staleDirectory, staleEvidence) = try fixture("stale-instance")
        let firstInstance = try open(staleDirectory, staleEvidence)
        let staleInstance = try open(staleDirectory, staleEvidence)
        try completed(firstInstance)
        let staleBytes = try bytes(staleDirectory)
        rejected("stale in-memory copy cannot roll back generation") { _ = try staleInstance.receive(requestID: UUID().uuidString, fingerprint: fingerprint, action: "portal.focusSearch", now: now) }
        check("stale instance leaves newest bytes unchanged", try bytes(staleDirectory) == staleBytes)
        let (lockedDirectory, lockedEvidence) = try fixture("concurrent-writer-lock")
        let lockedLedger = try open(lockedDirectory, lockedEvidence)
        let beforeLock = try bytes(lockedDirectory); let beforeLockEvidence = lockedEvidence.value
        let externalLock = Darwin.open(lockedDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        check("isolated directory lock descriptor", externalLock >= 0)
        check("isolated writer lock acquired", flock(externalLock, LOCK_EX | LOCK_NB) == 0)
        rejected("second writer cannot run same transition concurrently") { _ = try lockedLedger.receive(requestID: requestID, fingerprint: fingerprint, action: "portal.openSite", now: now) }
        check("writer lock conflict does not alter bytes or fence", try bytes(lockedDirectory) == beforeLock && lockedEvidence.value == beforeLockEvidence)
        flock(externalLock, LOCK_UN); close(externalLock)
        check("writer lock conflict original empty journal remains safe", try open(lockedDirectory, lockedEvidence).allRecords.isEmpty)

        let (rollbackDirectory, rollbackEvidence) = try fixture("rolled-back-file")
        let rollbackLedger = try open(rollbackDirectory, rollbackEvidence)
        let emptyBytes = try bytes(rollbackDirectory)
        try completed(rollbackLedger)
        try emptyBytes.write(to: rollbackLedger.file)
        rejected("previous valid empty ledger is not current watermark") { _ = try open(rollbackDirectory, rollbackEvidence) }
        check("rollback bytes preserved for recovery", try bytes(rollbackDirectory) == emptyBytes)

        let (readFailureDirectory, readFailureEvidence) = try fixture("evidence-read-failure")
        let readFailureLedger = try open(readFailureDirectory, readFailureEvidence); try completed(readFailureLedger)
        let readFailureBytes = try bytes(readFailureDirectory)
        readFailureEvidence.failReads = true
        rejected("unreadable independent evidence blocks startup") { _ = try open(readFailureDirectory, readFailureEvidence) }
        rejected("unreadable independent evidence blocks active instance") { _ = try readFailureLedger.receive(requestID: requestID, fingerprint: fingerprint, action: "portal.openSite", now: now) }
        check("evidence read failure leaves journal untouched", try bytes(readFailureDirectory) == readFailureBytes)
        let (writeFailureDirectory, writeFailureEvidence) = try fixture("evidence-write-failure")
        let writeFailureLedger = try open(writeFailureDirectory, writeFailureEvidence)
        let writeFailureBytes = try bytes(writeFailureDirectory)
        writeFailureEvidence.failWrites = true
        rejected("cannot receive if durable fence write fails") { _ = try writeFailureLedger.receive(requestID: requestID, fingerprint: fingerprint, action: "portal.openSite", now: now) }
        check("fence write failure preserves journal bytes", try bytes(writeFailureDirectory) == writeFailureBytes)
        writeFailureEvidence.failWrites = false
        rejected("failed transaction object stays fenced") { _ = try writeFailureLedger.receive(requestID: requestID, fingerprint: fingerprint, action: "portal.openSite", now: now) }
        check("failed fence write permits safe reopening of original empty state", try open(writeFailureDirectory, writeFailureEvidence).allRecords.isEmpty)

        // Each transaction boundary is deterministic: a pending independent
        // fence blocks reopen, even if the file is a valid old or new JSON file.
        // At the committed boundary the durable state can reopen but never replay.
        let boundaries = ["prepared", "staged", "renamed", "synced", "committed"]
        for boundary in boundaries {
            let (directory, evidence) = try fixture("initialization-" + boundary)
            rejected("initialization interruption at " + boundary) {
                _ = try open(directory, evidence, checkpoint: { if $0 == "initialization." + boundary { throw PortalActionError.invalidLedger } })
            }
            check("initialization interruption leaves independent evidence", evidence.value != nil)
            if boundary == "committed" {
                check("committed initialization reopens true empty first use", try open(directory, evidence).allRecords.isEmpty)
            } else {
                let after = try fingerprintOfTree(directory.deletingLastPathComponent().deletingLastPathComponent())
                rejected("unfinished initialization refuses reopen " + boundary) { _ = try open(directory, evidence) }
                check("unfinished initialization never changes retained bytes " + boundary, try fingerprintOfTree(directory.deletingLastPathComponent().deletingLastPathComponent()) == after)
            }
            let (migrationDirectory, migrationEvidence) = try legacy("migration-" + boundary)
            let beforeMigration = try bytes(migrationDirectory)
            rejected("migration interruption at " + boundary) {
                _ = try open(migrationDirectory, migrationEvidence, checkpoint: { if $0 == "migration." + boundary { throw PortalActionError.invalidLedger } })
            }
            if boundary == "committed" {
                check("committed migration keeps old UUID terminal " + boundary, try repeated(open(migrationDirectory, migrationEvidence)))
            } else {
                let afterMigration = try bytes(migrationDirectory)
                rejected("unfinished migration refuses reopen " + boundary) { _ = try open(migrationDirectory, migrationEvidence) }
                check("unfinished migration retains original or staged record bytes " + boundary, try bytes(migrationDirectory) == afterMigration)
                if boundary == "prepared" || boundary == "staged" {
                    check("pre-rename migration preserves V1 exactly " + boundary, afterMigration == beforeMigration)
                }
            }

            let (writeDirectory, writeEvidence) = try fixture("write-" + boundary)
            var shouldInterrupt = false
            let writeLedger = try open(writeDirectory, writeEvidence, checkpoint: {
                if shouldInterrupt && $0 == "write." + boundary { throw PortalActionError.invalidLedger }
            })
            _ = try writeLedger.receive(requestID: requestID, fingerprint: fingerprint, action: "portal.openSite", now: now)
            _ = try writeLedger.approve(requestID: requestID, now: now)
            let beforeWrite = try bytes(writeDirectory)
            shouldInterrupt = true
            rejected("execution transition interruption at " + boundary) { _ = try writeLedger.beginExecution(requestID: requestID, now: now) }
            rejected("interrupted live instance cannot receive " + boundary) { _ = try writeLedger.receive(requestID: requestID, fingerprint: fingerprint, action: "portal.openSite", now: now) }
            if boundary == "committed" {
                let reopened = try open(writeDirectory, writeEvidence, at: now.addingTimeInterval(1))
                check("committed uncertain execution becomes interrupted " + boundary, reopened.record(requestID: requestID)?.state == .failed && reopened.record(requestID: requestID)?.outcome.errorCode == "interrupted_execution")
                check("committed uncertain UUID is repeated " + boundary, try repeated(reopened))
            } else {
                let afterWrite = try bytes(writeDirectory)
                rejected("unfinished write refuses reopen " + boundary) { _ = try open(writeDirectory, writeEvidence) }
                check("unfinished write retains byte state " + boundary, try bytes(writeDirectory) == afterWrite)
                if boundary == "prepared" || boundary == "staged" { check("pre-rename write preserves source exactly " + boundary, beforeWrite == afterWrite) }
            }

            let (recoveryDirectory, recoveryEvidence) = try fixture("recovery-" + boundary)
            let executing = try open(recoveryDirectory, recoveryEvidence)
            _ = try executing.receive(requestID: requestID, fingerprint: fingerprint, action: "portal.openSite", now: now)
            _ = try executing.approve(requestID: requestID, now: now)
            _ = try executing.beginExecution(requestID: requestID, now: now)
            let beforeRecovery = try bytes(recoveryDirectory)
            rejected("recovery interruption at " + boundary) {
                _ = try open(recoveryDirectory, recoveryEvidence, at: now.addingTimeInterval(1), checkpoint: { if $0 == "recovery." + boundary { throw PortalActionError.invalidLedger } })
            }
            if boundary == "committed" {
                let reopened = try open(recoveryDirectory, recoveryEvidence, at: now.addingTimeInterval(2))
                check("committed recovery is terminal interrupted " + boundary, reopened.record(requestID: requestID)?.state == .failed && reopened.record(requestID: requestID)?.outcome.errorCode == "interrupted_execution")
                check("committed recovery UUID remains repeated " + boundary, try repeated(reopened))
            } else {
                let afterRecovery = try bytes(recoveryDirectory)
                rejected("unfinished recovery refuses reopen " + boundary) { _ = try open(recoveryDirectory, recoveryEvidence) }
                check("unfinished recovery retains byte state " + boundary, try bytes(recoveryDirectory) == afterRecovery)
                if boundary == "prepared" || boundary == "staged" { check("pre-rename recovery preserves source exactly " + boundary, beforeRecovery == afterRecovery) }
            }
        }
        print("Portal ledger recovery tests passed: \(count)")
    }
}
