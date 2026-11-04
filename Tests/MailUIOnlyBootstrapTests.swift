import Foundation
import Darwin

@main struct MailUIOnlyBootstrapTests {
    private struct Injected: Error {}
    private static var checks = 0
    private static var stage = "setup"
    private static func check(_ condition: @autoclosure () throws -> Bool) throws {
        guard try condition() else { fatalError("UI bootstrap check \(checks), \(stage)") }; checks += 1
    }
    private static func rejects(_ action: () throws -> Void) {
        do { try action(); fatalError("Unsafe UI bootstrap accepted: \(stage)") } catch { checks += 1 }
    }
    private final class Defaults: MailStorageDefaults, PortalMailUIOnlyBootstrapKeyInventory {
        var values: [String: Any] = [:]
        var synchronizations = 0
        var failAt: Int?
        func object(forKey key: String) -> Any? { values[key] }
        func set(_ value: Any?, forKey key: String) { values[key] = value }
        func removeObject(forKey key: String) { values.removeValue(forKey: key) }
        func synchronize() -> Bool { synchronizations += 1; return synchronizations != failAt }
        func bootstrapPreferenceKeyNames() -> [String] { Array(values.keys) }
    }
    private struct Proofs {
        let authority: Data
        let backup: Data
        let human: Data
        let fence: Data
        let trustedHumanFactSHA256: String
    }
    private final class Fixture {
        let home: URL
        let paths: PortalMailUIOnlyBootstrap.Paths
        let defaults = Defaults()
        var exported: Data
        var prefs: [String: Any]
        init(_ base: URL, preferences: [String: Any]? = nil) throws {
            home = base.appendingPathComponent(UUID().uuidString)
            paths = try PortalMailUIOnlyBootstrap.Paths(homeURL: home)
            prefs = preferences ?? ["gaoyoujian.appearance": "dark", "gaoyoujian.floating.visible": true,
                "gaoyoujian.floating.showPreviews": true, "gaoyoujian.floating.edge": "right",
                "gaoyoujian.floating.dockMode": "free", "gaoyoujian.floating.horizontalRatio": 0.75,
                "NSWindow Frame main": "20 30 1100 800 0 0 1728 1117 "]
            exported = try PropertyListSerialization.data(fromPropertyList: prefs, format: .xml, options: 0)
            for suffix in ["Library/Application Support/MenDao", "Library/Application Support/GaoSeries", "Library/Application Support/GaoSeriesRestore", "Library/Preferences", "Library/Containers", "Library/Saved Application State"] {
                try FileManager.default.createDirectory(at: home.appendingPathComponent(suffix), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            try writePreferences()
        }
        func writePreferences() throws {
            try MailUIOnlyBootstrapTests.write(PropertyListSerialization.data(fromPropertyList: prefs, format: .binary, options: 0), to: paths.preferences)
        }
        func plan() throws -> PortalMailUIOnlyBootstrapPlan {
            try PortalMailUIOnlyBootstrap.plan(homeURL: home, sourcePreferencesExport: exported, targetDefaults: defaults)
        }
        func ready() -> PortalMailUIOnlyBootstrapReadiness {
            PortalMailUIOnlyBootstrap.readiness(destinationRootURL: paths.target, legacyRootURL: paths.source, targetDefaults: defaults)
        }
        func proofs(modifyBackup: ((inout [String: Any]) -> Void)? = nil, modifyHuman: ((inout [String: Any]) -> Void)? = nil,
                    modifyFence: ((inout [String: Any]) -> Void)? = nil, modifyAuthority: ((inout [String: Any]) -> Void)? = nil,
                    modifyHumanFact: ((inout [String: Any]) -> Void)? = nil) throws -> Proofs {
            let plan = try self.plan(), id = UUID()
            let actualBackup = home.appendingPathComponent("actual-backup.json"), actualFence = home.appendingPathComponent("actual-fence.json")
            let actual = try MailUIOnlyBootstrapTests.json(["fixture": "synthetic-only"])
            try MailUIOnlyBootstrapTests.write(actual, to: actualBackup); try MailUIOnlyBootstrapTests.write(actual, to: actualFence)
            let common: [String: Any] = ["schemaVersion": 1, "operation": PortalMailUIOnlyBootstrap.operation,
                "bootstrapID": id.uuidString, "sourceBundleID": PortalMailUIOnlyBootstrap.sourceBundleID,
                "targetBundleID": PortalMailUIOnlyBootstrap.targetBundleID, "sourceRoot": paths.source.path, "targetRoot": paths.target.path]
            var backup = common
            backup.merge(["fullCurrentBackupRestoreVerified": true, "sourceUIPreferencesSHA256": plan.sourcePreferencesSHA256,
                "sourceUIPreferencesFileSHA256": plan.sourcePreferencesFileSHA256, "absentSourcePaths": plan.absences.map(\.path),
                "actualBackupReceiptPath": actualBackup.path, "actualBackupReceiptSHA256": PortalMailUIOnlyBootstrap.digest(actual)]) { _, new in new }
            modifyBackup?(&backup)
            let humanFactPath = home.appendingPathComponent("original-human-authorization.json")
            var humanFact: [String: Any] = ["schemaVersion": 1, "kind": "GaoSeriesHumanExplicitScopeAuthorization",
                "operation": PortalMailUIOnlyBootstrap.operation, "sourceBundleID": PortalMailUIOnlyBootstrap.sourceBundleID,
                "targetBundleID": PortalMailUIOnlyBootstrap.targetBundleID, "newLibrary": true, "dataMigrated": false,
                "notProofOfNeverHavingAnAccount": true, "doesNotCertifyWritersFrozenOrBackupsOrCurrentAbsence": true,
                "questionCall": "synthetic-question", "humanAnswer": "synthetic-human-answer", "scope": "synthetic-UI-only-new-library"]
            modifyHumanFact?(&humanFact)
            let factBytes = try MailUIOnlyBootstrapTests.json(humanFact), trustedHumanFactSHA = PortalMailUIOnlyBootstrap.digest(factBytes)
            try MailUIOnlyBootstrapTests.write(factBytes, to: humanFactPath)
            var human = common
            human.merge(["explicitHumanAuthorization": true, "newLibrary": true, "dataMigrated": false,
                "decision": "authorize-new-empty-mail-library-and-ui-preferences-only", "humanMessageReference": "synthetic-authorization-fixture",
                "actualHumanAuthorizationFactPath": humanFactPath.path, "actualHumanAuthorizationFactSHA256": trustedHumanFactSHA]) { _, new in new }
            modifyHuman?(&human)
            var fence = common
            fence.merge(["sourceFrozen": true, "hostStopped": true, "noSourceWriterObserved": true, "sourceFormalApplicationAbsentOrIsolated": true,
                "actualFenceReceiptPath": actualFence.path, "actualFenceReceiptSHA256": PortalMailUIOnlyBootstrap.digest(actual)]) { _, new in new }
            modifyFence?(&fence)
            let b = try MailUIOnlyBootstrapTests.json(backup), h = try MailUIOnlyBootstrapTests.json(human), f = try MailUIOnlyBootstrapTests.json(fence)
            var authority = common
            authority.merge(["sourceFrozen": true, "sourcePreferencesPath": plan.sourcePreferencesPath,
                "sourcePreferencesSHA256": plan.sourcePreferencesSHA256, "sourcePreferencesFileSHA256": plan.sourcePreferencesFileSHA256,
                "sourcePreferencesFileIdentity": try JSONSerialization.jsonObject(with: PortalMailUIOnlyBootstrap.encoded(plan.sourcePreferencesFileIdentity)),
                "absencePlanSHA256": PortalMailUIOnlyBootstrap.digest(try PortalMailUIOnlyBootstrap.encoded(plan)),
                "backupReceiptSHA256": PortalMailUIOnlyBootstrap.digest(b), "userAuthorizationProofSHA256": PortalMailUIOnlyBootstrap.digest(h),
                "fenceReceiptSHA256": PortalMailUIOnlyBootstrap.digest(f)]) { _, new in new }
            modifyAuthority?(&authority)
            return Proofs(authority: try MailUIOnlyBootstrapTests.json(authority), backup: b, human: h, fence: f, trustedHumanFactSHA256: trustedHumanFactSHA)
        }
        func apply(_ proofs: Proofs? = nil, trustedHumanFactSHA256: String? = nil,
                   guardOperation: @escaping () throws -> Void = {}, checkpoint: ((String) throws -> Void)? = nil) throws -> PortalMailUIOnlyBootstrapReceipt {
            let p = try proofs ?? self.proofs()
            return try PortalMailUIOnlyBootstrap.prepare(homeURL: home, sourcePreferencesExport: { self.exported }, authorityBytes: p.authority,
                backupReceipt: p.backup, userAuthorizationProof: p.human, fenceReceipt: p.fence, targetDefaults: defaults,
                trustedHumanAuthorizationFactSHA256: trustedHumanFactSHA256 ?? p.trustedHumanFactSHA256,
                operationalGuard: guardOperation, checkpoint: checkpoint)
        }
    }
    private static func json(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
    private static func write(_ bytes: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try bytes.write(to: url); guard chmod(url.path, 0o600) == 0 else { throw Injected() }
    }
    private static func recovery(_ value: PortalMailUIOnlyBootstrapReadiness) -> Bool { if case .recoveryRequired = value { return true }; return false }
    static func main() throws {
        let base = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("MailUIOnlyBootstrapFixtures-" + UUID().uuidString + ".noindex")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: base) }
        stage = "new plan without writes"
        let f = try Fixture(base), p = try f.plan()
        try check(p.newLibrary && !p.dataMigrated && p.absences.count == 7)
        try check(p.sourcePreferencesSHA256 != p.sourcePreferencesFileSHA256)
        try check(f.defaults.values.isEmpty && !FileManager.default.fileExists(atPath: f.paths.target.path))
        try check(f.ready() == .absent)
        if case .recoveryRequired = PortalMailMigration.readiness(destinationRootURL: f.paths.target, legacyRootURL: f.paths.source, sourcePreferences: f.exported, targetDefaults: f.defaults) { checks += 1 }
        else { fatalError("Normal full migration accepted missing source + nonempty UI preferences") }
        stage = "independent successful new library"
        var guards = 0
        let receipt = try f.apply(guardOperation: { guards += 1 })
        try check(guards == 4)
        try check(receipt.newLibrary && !receipt.dataMigrated && !receipt.keychainAccessed && !receipt.sourceBusinessDataReadOrRestored)
        try check(receipt.sourceUIPreferencesRead && receipt.compatibleUISettingsCopied)
        try check(receipt.initialAccountCount == 0 && receipt.initialDraftCount == 0 && receipt.initialMessageCount == 0 && receipt.initialIdentityCount == 0)
        try check(f.defaults.object(forKey: "gaomenhu.mail.floating.visible") as? Bool == false)
        try check(f.defaults.object(forKey: "gaomenhu.mail.floating.showPreviews") as? Bool == false)
        try check(f.defaults.object(forKey: "gaomenhu.mail.appearance") as? String == "dark")
        try check(f.defaults.object(forKey: "NSWindow Frame main") == nil)
        try check(f.defaults.object(forKey: PortalMailMigration.evidenceKey(destinationRootURL: f.paths.target)) == nil)
        try check(f.ready() == .ready)
        rejects { _ = try f.apply() }
        stage = "current business remains mutable without initial empty hash"
        do {
            let storage = MailStorage(root: f.paths.target, evidenceDefaults: f.defaults)
            var library = storage.load(); var account = MailAccount(); account.email = "synthetic@example.invalid"
            library.accounts.append(account); try storage.save(library)
            try check(f.ready() == .ready)
            library.accounts = []; try storage.save(library); try check(f.ready() == .ready)
        }
        stage = "retirement removes old prefs and proof archives without runtime dependency"
        try FileManager.default.removeItem(at: f.paths.preferences)
        try FileManager.default.removeItem(at: f.home.appendingPathComponent("actual-backup.json"))
        try FileManager.default.removeItem(at: f.home.appendingPathComponent("actual-fence.json"))
        try FileManager.default.removeItem(at: f.home.appendingPathComponent("original-human-authorization.json"))
        try check(f.ready() == .ready)
        stage = "orphan receipt and missing marker anchors"
        let independentKey = PortalMailUIOnlyBootstrap.evidenceKey(destinationRootURL: f.paths.target)
        let anchored = f.defaults.values[independentKey]
        f.defaults.values[independentKey] = nil; try check(recovery(f.ready()))
        f.defaults.values[independentKey] = anchored
        f.defaults.values[MailStorage.evidenceKey(root: f.paths.target)] = Data("bad".utf8); try check(recovery(f.ready()))

        stage = "strict known UI keys and CFBoolean distinction"
        let badPreferences: [[String: Any]] = [
            ["unknown": "x"], ["gaoyoujian.account": "x"], ["gaoyoujian.password": "x"],
            ["gaoyoujian.floating.visible": 1], ["gaoyoujian.floating.showPreviews": 0], ["gaoyoujian.sidebarHidden": 1],
            ["gaoyoujian.floating.opacity": true], ["gaoyoujian.floating.verticalRatio": 2.0],
            ["gaoyoujian.appearance": "invalid"], ["gaoyoujian.floating.edge": "top"], ["gaoyoujian.floating.dockMode": "automatic"],
            ["NSWindow Frame unknown": "0 0 10 10 0 0 100 100"], ["NSWindow Frame main": "x"],
            ["NSWindow Frame main": "0 0 10 10 0 0 100 nan"], ["NSWindow Frame main": "0 0 -10 10 0 0 100 100"],
            ["NSWindow Frame main": "0 0 1000001 10 0 0 100 100"], ["gaoyoujian.floating.display": Data([1, 2])]
        ]
        for preferences in badPreferences { let bad = try Fixture(base, preferences: preferences); rejects { _ = try bad.plan() }; try check(bad.defaults.values.isEmpty) }
        stage = "export/disk semantic divergence"
        let divergence = try Fixture(base); divergence.exported = try PropertyListSerialization.data(fromPropertyList: ["gaoyoujian.appearance": "light"], format: .xml, options: 0)
        rejects { _ = try divergence.plan() }
        stage = "fixed missing scopes cannot contain later data"
        for index in 0..<7 {
            let changed = try Fixture(base), path = changed.paths.absent[index]
            try write(Data("existing-source-fixture".utf8), to: path)
            rejects { _ = try changed.plan() }
        }
        stage = "linked ancestor and preferences, hardlink and writable input"
        let link = try Fixture(base)
        let realContainers = link.home.appendingPathComponent("real-containers")
        try FileManager.default.moveItem(at: link.home.appendingPathComponent("Library/Containers"), to: realContainers)
        try FileManager.default.createSymbolicLink(at: link.home.appendingPathComponent("Library/Containers"), withDestinationURL: realContainers)
        rejects { _ = try link.plan() }
        let linkedPrefs = try Fixture(base), actualPrefs = linkedPrefs.home.appendingPathComponent("other.plist")
        try FileManager.default.moveItem(at: linkedPrefs.paths.preferences, to: actualPrefs)
        try FileManager.default.createSymbolicLink(at: linkedPrefs.paths.preferences, withDestinationURL: actualPrefs)
        rejects { _ = try linkedPrefs.plan() }
        let hardlink = try Fixture(base)
        guard Darwin.link(hardlink.paths.preferences.path, hardlink.home.appendingPathComponent("second.plist").path) == 0 else { throw Injected() }
        rejects { _ = try hardlink.plan() }
        let writable = try Fixture(base); guard chmod(writable.paths.preferences.path, 0o622) == 0 else { throw Injected() }; rejects { _ = try writable.plan() }
        stage = "target data, markers, independent evidence and future transactions"
        for key in ["gaomenhu.mail.appearance", "GaoMenHu.MailFutureEvidence.unknown"] {
            let occupied = try Fixture(base); occupied.defaults.values[key] = "existing"; rejects { _ = try occupied.plan() }
        }
        let marker = try Fixture(base); try write(Data("existing".utf8), to: MailStorage.markerURL(root: marker.paths.target)); rejects { _ = try marker.plan() }
        let occupied = try Fixture(base); try FileManager.default.createDirectory(at: occupied.paths.target, withIntermediateDirectories: false); rejects { _ = try occupied.plan() }
        let orphan = try Fixture(base); try FileManager.default.createDirectory(at: orphan.paths.target.appendingPathComponent("UIOnlyBootstrapEvidence"), withIntermediateDirectories: true); try check(recovery(orphan.ready()))
        let pending = try Fixture(base); try FileManager.default.createDirectory(at: pending.paths.target.deletingLastPathComponent().appendingPathComponent(".MailCenter-Migration-fixture.noindex"), withIntermediateDirectories: false); rejects { _ = try pending.plan() }
        stage = "actual receipt paths and explicit-human proof semantics"
        let proofCases: [(inout [String: Any]) -> Void] = [
            { $0["actualBackupReceiptPath"] = "relative.json" }, { $0["actualBackupReceiptPath"] = "/private/tmp/../bad" },
            { $0["actualBackupReceiptSHA256"] = String(repeating: "0", count: 64) },
            { $0["fullCurrentBackupRestoreVerified"] = 1 }, { $0["schemaVersion"] = true }, { $0["absentSourcePaths"] = [] }
        ]
        for mutation in proofCases { let fixture = try Fixture(base); let proof = try fixture.proofs(modifyBackup: mutation); rejects { _ = try fixture.apply(proof) }; try check(fixture.defaults.values.isEmpty) }
        let noHuman = try Fixture(base), noHumanProof = try noHuman.proofs(modifyHuman: { $0["explicitHumanAuthorization"] = false }); rejects { _ = try noHuman.apply(noHumanProof) }
        let dataMigrated = try Fixture(base), migrationProof = try dataMigrated.proofs(modifyHuman: { $0["dataMigrated"] = true }); rejects { _ = try dataMigrated.apply(migrationProof) }
        let noFence = try Fixture(base), noFenceProof = try noFence.proofs(modifyFence: { $0["hostStopped"] = false }); rejects { _ = try noFence.apply(noFenceProof) }
        let relativeFence = try Fixture(base), relativeProof = try relativeFence.proofs(modifyFence: { $0["actualFenceReceiptPath"] = "relative.json" }); rejects { _ = try relativeFence.apply(relativeProof) }
        let noAuthority = try Fixture(base), noAuthorityProof = try noAuthority.proofs(modifyAuthority: { $0["sourceFrozen"] = false }); rejects { _ = try noAuthority.apply(noAuthorityProof) }
        stage = "actual human authorization is pinned independently of the wrapper"
        let badPin = try Fixture(base), badPinProof = try badPin.proofs()
        rejects { _ = try badPin.apply(badPinProof, trustedHumanFactSHA256: String(repeating: "0", count: 64)) }
        try check(badPin.defaults.values.isEmpty)
        let substituted = try Fixture(base), originalProof = try substituted.proofs()
        let substitutedProof = try substituted.proofs(modifyHumanFact: { $0["humanAnswer"] = "another-synthetic-answer" })
        rejects { _ = try substituted.apply(substitutedProof, trustedHumanFactSHA256: originalProof.trustedHumanFactSHA256) }
        try check(substituted.defaults.values.isEmpty)
        let invalidHumanFacts: [(inout [String: Any]) -> Void] = [
            { $0["kind"] = "other-fact" }, { $0["dataMigrated"] = true }, { $0["newLibrary"] = 1 },
            { $0["notProofOfNeverHavingAnAccount"] = false }, { $0["sourceBundleID"] = "other.source" }
        ]
        for mutation in invalidHumanFacts {
            let invalid = try Fixture(base), proof = try invalid.proofs(modifyHumanFact: mutation)
            rejects { _ = try invalid.apply(proof) }; try check(invalid.defaults.values.isEmpty)
        }
        let relativeHuman = try Fixture(base), relativeHumanProof = try relativeHuman.proofs(modifyHuman: { $0["actualHumanAuthorizationFactPath"] = "relative.json" })
        rejects { _ = try relativeHuman.apply(relativeHumanProof) }
        stage = "operational fence failure makes zero target/default writes"
        let running = try Fixture(base), runningProof = try running.proofs()
        rejects { _ = try running.apply(runningProof, guardOperation: { throw Injected() }) }
        try check(running.defaults.values.isEmpty && !FileManager.default.fileExists(atPath: running.paths.target.path))
        stage = "fresh absence/prefs CAS before intent and after intent"
        for at in ["beforeIntent", "afterIntent"] {
            let changed = try Fixture(base), proof = try changed.proofs()
            rejects { _ = try changed.apply(proof, checkpoint: { point in if point == at { try write(Data("late-source".utf8), to: changed.paths.source.appendingPathComponent("Library.json")) } }) }
            try check(!FileManager.default.fileExists(atPath: changed.paths.target.path))
            if at == "beforeIntent" { try check(changed.defaults.values.isEmpty) } else { try check(recovery(changed.ready())) }
        }
        let changedPrefs = try Fixture(base), changedProof = try changedPrefs.proofs()
        rejects { _ = try changedPrefs.apply(changedProof, checkpoint: { point in if point == "afterIntent" { changedPrefs.prefs["gaoyoujian.appearance"] = "light"; try changedPrefs.writePreferences() } }) }
        try check(recovery(changedPrefs.ready()) && !FileManager.default.fileExists(atPath: changedPrefs.paths.target.path))
        stage = "interruption keeps evidence and never auto-initializes or retries"
        for phase in ["afterIntent", "afterLibrary", "afterReceipt"] {
            let interrupted = try Fixture(base), proof = try interrupted.proofs()
            let sourceBytes = try Data(contentsOf: interrupted.paths.preferences)
            rejects { _ = try interrupted.apply(proof, checkpoint: { point in if point == phase { throw Injected() } }) }
            try check(recovery(interrupted.ready()))
            try check(try Data(contentsOf: interrupted.paths.preferences) == sourceBytes)
            rejects { _ = try interrupted.plan() }
        }
        stage = "commit-time operational check remains mandatory"
        let revive = try Fixture(base), reviveProof = try revive.proofs(); var calls = 0
        rejects { _ = try revive.apply(reviveProof, guardOperation: { calls += 1; if calls == 4 { throw Injected() } }) }
        try check(calls == 4 && recovery(revive.ready()))
        stage = "defaults synchronization failures retain a blocking intent"
        let failedSync = try Fixture(base), failedSyncProof = try failedSync.proofs(); failedSync.defaults.failAt = 1
        rejects { _ = try failedSync.apply(failedSyncProof) }
        try check(recovery(failedSync.ready()) && !FileManager.default.fileExists(atPath: failedSync.paths.target.path))
        stage = "final defaults commit failure cannot produce ready via in-memory committed value"
        let finalSync = try Fixture(base), finalSyncProof = try finalSync.proofs(); finalSync.defaults.failAt = 4
        rejects { _ = try finalSync.apply(finalSyncProof) }
        try check(finalSync.defaults.synchronizations == 4 && recovery(finalSync.ready()))
        try check(!FileManager.default.fileExists(atPath: finalSync.paths.target.appendingPathComponent("UIOnlyBootstrapEvidence/committed.json").path))
        print("PASS mail UI-only bootstrap \(checks) assertions; isolated synthetic roots/defaults/proofs only, zero Keychain/SMTP/GUI.")
    }
}
