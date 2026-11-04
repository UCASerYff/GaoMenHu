import Foundation
import Darwin

/// Real temporary files, descriptors, inodes and hashes. All old device values,
/// volume UUIDs, bookmarks and databases are synthetic; no panel or transfer runs.
@main struct DownloadMountEpochTests {
    struct Injected: Error {}
    static var checks = 0
    static var phase = "startup"
    static let replacementBookmark = Data("synthetic-renewed-bookmark".utf8)
    static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw DownloadError.message("Synthetic epoch check: " + message) }
        checks += 1
    }
    static func rejects(_ message: String, _ operation: () throws -> Void) throws {
        do { try operation() }
        catch { checks += 1; return }
        throw DownloadError.message("Synthetic epoch should reject: " + message)
    }
    static func metadata(_ url: URL) throws -> stat {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw Injected() }
        return value
    }
    static func write(_ bytes: Data, to url: URL) throws {
        try bytes.write(to: url)
        guard chmod(url.path, 0o600) == 0 else { throw Injected() }
    }

    final class Fixture {
        let root: URL
        let directory: URL
        let stageDirectory: URL
        let volume: String
        let payload: Data
        let grantID: UUID
        let jobID: UUID
        let itemID: UUID
        let device: UInt64
        let oldDevice: UInt64
        var grant: DestinationGrant
        var items: [DownloadItem]
        var completeURL: URL { directory.appendingPathComponent("finished.bin") }
        var partURL: URL { stageDirectory.appendingPathComponent(itemID.uuidString + ".part") }
        var pendingURL: URL { directory.appendingPathComponent("pending.bin") }

        init(_ kind: String = "completed") throws {
            // Construct entirely with locals until every stored property is set;
            // a failing setup removes only this fixture's unique temporary root.
            let localRoot = URL(fileURLWithPath: "/private/tmp/gaomenhu-mount-epoch-\(UUID().uuidString).noindex", isDirectory: true)
            let localDirectory = localRoot.appendingPathComponent("Selected", isDirectory: true)
            let localVolume = UUID().uuidString
            let localPayload = Data("synthetic-verified-content".utf8)
            let localGrantID = UUID(), localJobID = UUID(), localItemID = UUID()
            let localStage = localDirectory.appendingPathComponent(".GaoXiaZai-Staging-\(localGrantID.uuidString)", isDirectory: true)
            let localComplete = localDirectory.appendingPathComponent("finished.bin")
            let localPart = localStage.appendingPathComponent(localItemID.uuidString + ".part")
            let localPending = localDirectory.appendingPathComponent("pending.bin")
            var createdRoot = false
            do {
                try FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                createdRoot = true
                try FileManager.default.createDirectory(at: localDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                let current = try DownloadMountEpochTests.metadata(localDirectory)
                let localDevice = UInt64(current.st_dev)
                let localOldDevice = localDevice < UInt64.max - 16 ? localDevice + 16 : localDevice - 16
                let localGrant = DestinationGrant(id: localGrantID, displayPath: localDirectory.path,
                    bookmark: Data("synthetic-old-bookmark".utf8), device: localOldDevice,
                    inode: UInt64(current.st_ino), volumeUUID: localVolume.lowercased(), requiresReauthorization: true)
                var localItems = [DownloadItem(id: localItemID, jobID: localJobID, destinationID: localGrantID, state: .paused,
                    sourceURL: "https://example.invalid/fixture.bin", sourceFingerprint: downloadDigest(Data("https://example.invalid/fixture.bin".utf8)),
                    displayURL: "https://example.invalid/fixture.bin", suggestedName: "finished.bin",
                    bytesReceived: Int64(localPayload.count), expectedBytes: Int64(localPayload.count), bytesPerSecond: 0,
                    sha256: downloadDigest(localPayload), errorMessage: nil, retryAt: nil, artifact: nil,
                    createdAt: Date(timeIntervalSince1970: 1_800_000_000), stagingName: localItemID.uuidString + ".part")]
                if kind == "completed" {
                    try DownloadMountEpochTests.write(localPayload, to: localComplete)
                    let value = try DownloadMountEpochTests.metadata(localComplete)
                    localItems[0].state = .completed
                    localItems[0].artifact = PublishedArtifact(fileName: localComplete.lastPathComponent,
                        byteCount: Int64(localPayload.count), sha256: downloadDigest(localPayload), device: localOldDevice, inode: UInt64(value.st_ino))
                } else {
                    try FileManager.default.createDirectory(at: localStage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                    if kind != "pending-final-only" {
                        let bytes = kind == "partial-tail" ? localPayload + Data("uncommitted-tail".utf8) : localPayload
                        try DownloadMountEpochTests.write(bytes, to: localPart)
                    }
                    if kind == "pending-final-only" {
                        try DownloadMountEpochTests.write(localPayload, to: localPending)
                    } else if kind == "pending-pair" {
                        guard link(localPart.path, localPending.path) == 0 else { throw Injected() }
                    } else if kind == "pending-conflict" {
                        try DownloadMountEpochTests.write(localPayload, to: localPending)
                    }
                    let existing = kind == "pending-final-only" ? localPending : localPart
                    let value = try DownloadMountEpochTests.metadata(existing)
                    localItems[0].stagingDevice = localOldDevice
                    localItems[0].stagingInode = UInt64(value.st_ino)
                    localItems[0].partialSHA256 = downloadDigest(localPayload)
                    if kind.hasPrefix("pending-") {
                        localItems[0].pendingArtifact = PublishedArtifact(fileName: localPending.lastPathComponent,
                            byteCount: Int64(localPayload.count), sha256: downloadDigest(localPayload), device: localOldDevice, inode: UInt64(value.st_ino))
                    }
                }
                root = localRoot; directory = localDirectory; stageDirectory = localStage
                volume = localVolume; payload = localPayload
                grantID = localGrantID; jobID = localJobID; itemID = localItemID
                device = localDevice; oldDevice = localOldDevice; grant = localGrant; items = localItems
            } catch {
                if createdRoot { try? FileManager.default.removeItem(at: localRoot) }
                throw error
            }
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        func plan(selected: URL? = nil, bookmark: Data = DownloadMountEpochTests.replacementBookmark,
                  volumeUUID: (() throws -> String?)? = nil) throws -> DownloadMountEpoch.Plan {
            try DownloadMountEpoch.prepare(original: grant, items: items,
                selectedURL: selected ?? directory, renewedBookmark: bookmark,
                volumeUUID: volumeUUID ?? { self.volume.uppercased() })
        }
    }

    static func coreChecks() throws {
        phase = "core.completed"
        do {
            let f = try Fixture(), beforeGrant = try encoded(f.grant), beforeItems = try encoded(f.items)
            let originalBytes = try Data(contentsOf: f.completeURL), oldStat = try metadata(f.completeURL)
            let plan = try f.plan()
            try plan.validate()
            try check(plan.grant.id == f.grantID && plan.grant.inode == f.grant.inode, "grant identity preserved")
            try check(plan.grant.device == f.device && plan.grant.requiresReauthorization == false, "grant epoch renewed only in proposal")
            try check(plan.grant.bookmark == replacementBookmark, "new explicit bookmark")
            try check(plan.items[0].artifact?.device == f.device && plan.items[0].artifact?.inode == f.items[0].artifact?.inode, "artifact epoch only")
            try check(plan.items[0].state == .completed && plan.items[0].bytesReceived == f.items[0].bytesReceived, "completed remains completed")
            try check(try encoded(f.grant) == beforeGrant && encoded(f.items) == beforeItems, "input structs untouched")
            try check(try Data(contentsOf: f.completeURL) == originalBytes, "artifact bytes untouched")
            let now = try metadata(f.completeURL)
            try check(now.st_ino == oldStat.st_ino && now.st_size == oldStat.st_size && now.st_mtimespec.tv_sec == oldStat.st_mtimespec.tv_sec && now.st_mtimespec.tv_nsec == oldStat.st_mtimespec.tv_nsec, "no move or rewrite")
        }
        phase = "core.cancel"
        do {
            let f = try Fixture(), before = try encoded(f.items)
            var volumeCalls = 0
            try rejects("cancelled selection") {
                _ = try DownloadMountEpoch.prepare(original: f.grant, items: f.items, selectedURL: nil,
                    renewedBookmark: replacementBookmark, volumeUUID: { volumeCalls += 1; return f.volume })
            }
            try check(try (volumeCalls == 0 && encoded(f.items) == before && f.grant.requiresReauthorization == true), "cancel makes no authorization")
        }
        phase = "core.policy-rejections"
        for mode in ["different-volume", "missing-current-volume", "bad-current-volume", "missing-original-volume", "bad-original-volume", "directory-inode", "owner", "artifact-inode", "artifact-device", "artifact-sha", "artifact-size", "artifact-link", "selected-link", "directory-permissions", "empty-bookmark"] {
            let f = try Fixture(), original = try encoded(f.items)
            var originalGrant = f.grant, items = f.items
            var selected = f.directory, currentVolume: String? = f.volume
            var bookmark = replacementBookmark, uid = getuid()
            switch mode {
            case "different-volume": currentVolume = UUID().uuidString
            case "missing-current-volume": currentVolume = nil
            case "bad-current-volume": currentVolume = "not-a-volume-uuid"
            case "missing-original-volume": originalGrant.volumeUUID = nil
            case "bad-original-volume": originalGrant.volumeUUID = "not-a-volume-uuid"
            case "directory-inode": originalGrant.inode += 1
            case "owner": uid = uid == UInt32.max ? uid - 1 : uid + 1
            case "artifact-inode": items[0].artifact!.inode += 1
            case "artifact-device": items[0].artifact!.device += 1
            case "artifact-sha": items[0].artifact!.sha256 = String(repeating: "0", count: 64)
            case "artifact-size": items[0].artifact!.byteCount += 1
            case "artifact-link": guard link(f.completeURL.path, f.directory.appendingPathComponent("unexpected-hardlink").path) == 0 else { throw Injected() }
            case "selected-link":
                selected = f.root.appendingPathComponent("SelectionAlias", isDirectory: true)
                try FileManager.default.createSymbolicLink(at: selected, withDestinationURL: f.directory)
            case "directory-permissions": guard chmod(f.directory.path, 0o720) == 0 else { throw Injected() }
            case "empty-bookmark": bookmark = Data()
            default: break
            }
            try rejects(mode) {
                _ = try DownloadMountEpoch.prepare(original: originalGrant, items: items,
                    selectedURL: selected, renewedBookmark: bookmark, volumeUUID: { currentVolume }, expectedUID: uid)
            }
            try check(try encoded(f.items) == original && f.grant.requiresReauthorization == true, "rejection does not publish input mutation")
        }
        phase = "core.partial-pending"
        for kind in ["partial", "partial-tail", "pending-stage-only", "pending-final-only", "pending-pair"] {
            let f = try Fixture(kind), original = try encoded(f.items)
            let beforePart = FileManager.default.fileExists(atPath: f.partURL.path) ? try Data(contentsOf: f.partURL) : nil
            let beforeFinal = FileManager.default.fileExists(atPath: f.pendingURL.path) ? try Data(contentsOf: f.pendingURL) : nil
            let plan = try f.plan(); try plan.validate()
            try check(plan.items[0].stagingDevice == f.device && plan.items[0].stagingInode == f.items[0].stagingInode, kind + " staging epoch")
            try check(plan.items[0].state == f.items[0].state && plan.items[0].bytesReceived == f.items[0].bytesReceived, kind + " does not schedule or commit")
            try check(plan.items[0].partialSHA256 == f.items[0].partialSHA256 && plan.items[0].pendingArtifact?.sha256 == f.items[0].pendingArtifact?.sha256, kind + " digests preserved")
            if kind.hasPrefix("pending-") { try check(plan.items[0].pendingArtifact?.device == f.device, kind + " pending epoch") }
            if let beforePart { try check(try Data(contentsOf: f.partURL) == beforePart, kind + " no truncation") }
            if let beforeFinal { try check(try Data(contentsOf: f.pendingURL) == beforeFinal, kind + " no publication") }
            try check(try encoded(f.items) == original, kind + " input unchanged")
        }
        for kind in ["pending-conflict", "partial-missing-hash", "partial-bad-hash", "partial-missing", "pending-wrong-final"] {
            let f = try Fixture(kind.hasPrefix("partial") ? "partial" : "pending-pair")
            if kind == "pending-conflict" {
                try FileManager.default.removeItem(at: f.pendingURL)
                try write(f.payload, to: f.pendingURL)
            } else if kind == "partial-missing-hash" { f.items[0].partialSHA256 = nil }
            else if kind == "partial-bad-hash" { f.items[0].partialSHA256 = String(repeating: "f", count: 64) }
            else if kind == "partial-missing" { try FileManager.default.removeItem(at: f.partURL) }
            else if kind == "pending-wrong-final" { f.items[0].pendingArtifact!.sha256 = String(repeating: "f", count: 64) }
            try rejects(kind) { _ = try f.plan() }
        }
        do {
            let f = try Fixture("pending-pair")
            guard link(f.partURL.path, f.directory.appendingPathComponent("third-link.bin").path) == 0 else { throw Injected() }
            try rejects("pending transaction has third hardlink") { _ = try f.plan() }
        }
        phase = "core.cas"
        do {
            let f = try Fixture(); var volume = f.volume
            let plan = try f.plan(volumeUUID: { volume })
            volume = UUID().uuidString
            try rejects("volume changed before commit") { try plan.validate() }
        }
        do {
            let f = try Fixture(), plan = try f.plan()
            try write(Data(repeating: 0x41, count: f.payload.count), to: f.completeURL)
            try rejects("artifact changed after planning") { try plan.validate() }
        }
        do {
            let f = try Fixture("partial-tail"), plan = try f.plan()
            // The committed prefix still matches; a modified uncommitted tail
            // must nevertheless invalidate this exact authorization attempt.
            try write(f.payload + Data("changed-tail".utf8), to: f.partURL)
            try rejects("partial tail changed after planning") { try plan.validate() }
        }
        do {
            let f = try Fixture(), plan = try f.plan()
            guard chmod(f.directory.path, 0o720) == 0 else { throw Injected() }
            try rejects("directory permissions changed after planning") { try plan.validate() }
        }
        do {
            let f = try Fixture(), plan = try f.plan()
            let moved = f.root.appendingPathComponent("OriginalUnmovedData", isDirectory: true)
            try FileManager.default.moveItem(at: f.directory, to: moved)
            try FileManager.default.createDirectory(at: f.directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try rejects("directory path replaced") { try plan.validate() }
        }
        do {
            let f = try Fixture(), secondID = UUID()
            try write(Data("second".utf8), to: f.directory.appendingPathComponent("second.bin"))
            let value = try metadata(f.directory.appendingPathComponent("second.bin"))
            var second = f.items[0]; second.id = secondID
            second.artifact = PublishedArtifact(fileName: "second.bin", byteCount: 6,
                sha256: String(repeating: "0", count: 64), device: f.oldDevice, inode: UInt64(value.st_ino))
            second.bytesReceived = 6
            f.items.append(second)
            let before = try encoded(f.items)
            try rejects("second artifact fails after first was valid") { _ = try f.plan() }
            try check(try encoded(f.items) == before && f.grant.device == f.oldDevice, "no partial item or grant update")
        }
    }

    @MainActor static func savedDatabase(_ manager: DownloadManager) throws -> DownloadDatabase {
        struct Envelope: Decodable { let payload: Data; let sha256: String }
        let raw = try Data(contentsOf: manager.dataRootURL.appendingPathComponent("downloads.json"))
        let envelope = try JSONDecoder().decode(Envelope.self, from: raw)
        guard downloadDigest(envelope.payload) == envelope.sha256 else { throw Injected() }
        return try JSONDecoder().decode(DownloadDatabase.self, from: envelope.payload)
    }

    @MainActor static func manager(_ f: Fixture, withUnrelated: Bool = false) throws -> DownloadManager {
        let data = f.root.appendingPathComponent("Database", isDirectory: true)
        do {
            let store = try DownloadStore(root: data)
            var value = try store.load(); value.destinations = [f.grant]; value.items = f.items
            value.jobs = [DownloadJob(id: f.jobID, requestID: nil, itemIDs: f.items.map(\.id), createdAt: Date())]
            if withUnrelated {
                let otherDirectory = f.root.appendingPathComponent("OtherDestination", isDirectory: true)
                try FileManager.default.createDirectory(at: otherDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                let identity = try metadata(otherDirectory)
                var grant = f.grant; grant.id = UUID(); grant.displayPath = otherDirectory.path
                grant.inode = UInt64(identity.st_ino)
                var item = f.items[0]; item.id = UUID(); item.jobID = UUID(); item.destinationID = grant.id
                item.stagingName = item.id.uuidString + ".part"; item.state = .paused
                item.bytesReceived = 0; item.bytesPerSecond = 0; item.artifact = nil; item.sha256 = nil
                item.stagingDevice = nil; item.stagingInode = nil; item.partialSHA256 = nil; item.pendingArtifact = nil
                value.destinations.append(grant); value.items.append(item)
                value.jobs.append(DownloadJob(id: item.jobID, requestID: nil, itemIDs: [item.id], createdAt: Date()))
            }
            try store.save(value)
        }
        let result = DownloadManager(rootURL: data, evidenceDefaults: nil, monitorNetwork: false)
        guard result.recoveryIssue == nil else { throw DownloadError.message("Synthetic manager fixture failed: " + (result.recoveryIssue ?? "unknown")) }
        return result
    }
    @MainActor static func managerChecks() throws {
        phase = "manager.cancel"
        do {
            let f = try Fixture(), manager = try manager(f), before = try encoded(manager.destinations)
            let disk = try Data(contentsOf: manager.dataRootURL.appendingPathComponent("downloads.json"))
            var sideEffects = 0
            let result = try manager.reauthorizeDestination(nil, originalGrantID: f.grantID,
                volumeUUID: { _ in sideEffects += 1; return f.volume }, bookmarkData: { _ in sideEffects += 1; return replacementBookmark },
                persistCandidate: { _ in sideEffects += 1 })
            try check(result == nil && sideEffects == 0, "cancel is no-op before bookmark or I/O")
            try check(try encoded(manager.destinations) == before && Data(contentsOf: manager.dataRootURL.appendingPathComponent("downloads.json")) == disk, "cancel leaves disk and memory")
        }
        phase = "manager.success"
        do {
            let f = try Fixture(), manager = try manager(f), originalItem = manager.items[0]
            var preflightCalls = 0
            let grant = try manager.reauthorizeDestination(f.directory, originalGrantID: f.grantID,
                volumeUUID: { _ in f.volume.uppercased() }, bookmarkData: { _ in replacementBookmark },
                persistCandidate: { _ in preflightCalls += 1 })
            try check(preflightCalls == 1, "successful persistence hook still performs real store save")
            try check(grant?.device == f.device && manager.destinations[0].id == f.grantID, "manager publishes same grant after save")
            try check(manager.items[0].artifact?.device == f.device && manager.items[0].artifact?.inode == originalItem.artifact?.inode, "manager publishes verified artifact epoch")
            try check(manager.items[0].state == .completed && manager.jobs.count == 1 && manager.items.count == 1, "no new task or transfer state")
            struct Envelope: Decodable { let payload: Data; let sha256: String }
            let raw = try Data(contentsOf: manager.dataRootURL.appendingPathComponent("downloads.json"))
            let envelope = try JSONDecoder().decode(Envelope.self, from: raw)
            let saved = try JSONDecoder().decode(DownloadDatabase.self, from: envelope.payload)
            try check(downloadDigest(envelope.payload) == envelope.sha256 && saved.destinations[0].device == f.device && saved.items[0].artifact?.device == f.device, "single durable complete candidate")
            try check(saved.destinations[0].bookmark == replacementBookmark && saved.destinations[0].requiresReauthorization == false, "renewed bookmark persisted together")
        }
        phase = "manager.future-remount"
        do {
            let f = try Fixture("partial-tail")
            guard let actualVolume = try URL(fileURLWithPath: f.directory.path, isDirectory: true)
                .resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString,
                  UUID(uuidString: actualVolume) != nil else { throw Injected() }
            f.grant.volumeUUID = actualVolume.lowercased()
            f.grant.requiresReauthorization = false
            let before = try Data(contentsOf: f.partURL)
            let manager = try manager(f)
            try check(manager.recoveryIssue == nil && manager.destinations[0].requiresReauthorization == true,
                      "future remount enters explicit reauthorization instead of global recovery")
            try check(manager.destinations[0].device == f.oldDevice && manager.items[0].stagingDevice == f.oldDevice && manager.items[0].state == .waitingForDestination,
                      "readonly remount probe does not adopt new device or resume task")
            try check(try Data(contentsOf: f.partURL) == before, "readonly probe preserves uncommitted tail")
            _ = try manager.reauthorizeDestination(f.directory, originalGrantID: f.grantID,
                volumeUUID: { _ in actualVolume.uppercased() }, bookmarkData: { _ in replacementBookmark })
            try check(manager.recoveryIssue == nil && manager.destinations[0].device == f.device && manager.items[0].stagingDevice == f.device,
                      "future remount can explicitly renew original grant and partial together")
            try check(manager.items[0].state == .waitingForDestination && manager.items[0].bytesReceived == Int64(f.payload.count),
                      "renewing future remount does not automatically start or commit tail")
            try check(try Data(contentsOf: f.partURL) == before, "explicit remount renewal preserves full partial bytes")
        }
        phase = "manager.persist-failure"
        do {
            let f = try Fixture(), manager = try manager(f)
            let beforeGrant = try encoded(manager.destinations), beforeItems = try encoded(manager.items)
            let disk = try Data(contentsOf: manager.dataRootURL.appendingPathComponent("downloads.json"))
            var attempts = 0
            try rejects("persistence failure") {
                _ = try manager.reauthorizeDestination(f.directory, originalGrantID: f.grantID,
                    volumeUUID: { _ in f.volume }, bookmarkData: { _ in replacementBookmark },
                    persistCandidate: { _ in attempts += 1; throw Injected() })
            }
            try check(try (attempts == 1 && encoded(manager.destinations) == beforeGrant && encoded(manager.items) == beforeItems), "failed persistence publishes no arrays")
            try check(try Data(contentsOf: manager.dataRootURL.appendingPathComponent("downloads.json")) == disk, "failure hook before save preserves disk")
            try check(manager.recoveryIssue != nil && manager.items[0].state == .completed, "stop writing without starting a transfer")
        }
        phase = "manager.memory-cas"
        do {
            let f = try Fixture(), manager = try manager(f), disk = try Data(contentsOf: manager.dataRootURL.appendingPathComponent("downloads.json"))
            try rejects("memory changed during reauthorization") {
                _ = try manager.reauthorizeDestination(f.directory, originalGrantID: f.grantID,
                    volumeUUID: { _ in f.volume }, bookmarkData: { _ in replacementBookmark },
                    beforeCommit: { manager.items[0].errorMessage = "synthetic concurrent edit" })
            }
            try check(manager.destinations[0].device == f.oldDevice && manager.destinations[0].requiresReauthorization == true && manager.items[0].artifact?.device == f.oldDevice, "CAS failure retains old authorization")
            try check(manager.items[0].errorMessage == "synthetic concurrent edit", "does not overwrite concurrent state")
            try check(try Data(contentsOf: manager.dataRootURL.appendingPathComponent("downloads.json")) == disk, "CAS refusal has no disk write")
        }
        phase = "manager.final-file-cas"
        do {
            let f = try Fixture(), manager = try manager(f)
            let disk = try Data(contentsOf: manager.dataRootURL.appendingPathComponent("downloads.json"))
            var saveHookCalls = 0
            try rejects("artifact changes inside persistence preflight") {
                _ = try manager.reauthorizeDestination(f.directory, originalGrantID: f.grantID,
                    volumeUUID: { _ in f.volume }, bookmarkData: { _ in replacementBookmark },
                    persistCandidate: { _ in
                        saveHookCalls += 1
                        try write(Data(repeating: 0x43, count: f.payload.count), to: f.completeURL)
                    })
            }
            try check(saveHookCalls == 1 && manager.destinations[0].device == f.oldDevice && manager.items[0].artifact?.device == f.oldDevice,
                      "final external evidence guard publishes no candidate")
            try check(try Data(contentsOf: manager.dataRootURL.appendingPathComponent("downloads.json")) == disk,
                      "final external evidence guard retains authoritative snapshot")
        }
        phase = "manager.final-memory-cas"
        do {
            let f = try Fixture(), manager = try manager(f)
            let disk = try Data(contentsOf: manager.dataRootURL.appendingPathComponent("downloads.json"))
            try rejects("model changes inside persistence preflight") {
                _ = try manager.reauthorizeDestination(f.directory, originalGrantID: f.grantID,
                    volumeUUID: { _ in f.volume }, bookmarkData: { _ in replacementBookmark },
                    persistCandidate: { _ in manager.items[0].errorMessage = "synthetic late model edit" })
            }
            try check(manager.destinations[0].device == f.oldDevice && manager.items[0].artifact?.device == f.oldDevice && manager.items[0].errorMessage == "synthetic late model edit",
                      "final model guard preserves edit and old authorization")
            try check(try Data(contentsOf: manager.dataRootURL.appendingPathComponent("downloads.json")) == disk,
                      "final model guard retains authoritative snapshot")
        }
        phase = "manager.unrelated-progress"
        do {
            let f = try Fixture(), manager = try manager(f, withUnrelated: true)
            let unrelatedID = manager.items[1].id
            let durableBefore = try savedDatabase(manager)
            // Only model-level progress is injected; no transfer is constructed.
            manager.items[1].bytesReceived = 1; manager.items[1].bytesPerSecond = 42
            manager.items[1].errorMessage = "synthetic unrelated progress"
            _ = try manager.reauthorizeDestination(f.directory, originalGrantID: f.grantID,
                volumeUUID: { _ in f.volume }, bookmarkData: { _ in replacementBookmark })
            let durableAfter = try savedDatabase(manager)
            try check(manager.items[1].id == unrelatedID && manager.items[1].bytesReceived == 1 && manager.items[1].bytesPerSecond == 42 && manager.items[1].errorMessage == "synthetic unrelated progress",
                      "only related rows are published; unrelated live progress survives")
            let beforeOther = durableBefore.items.filter { $0.id == unrelatedID }
            let afterOther = durableAfter.items.filter { $0.id == unrelatedID }
            try check(try encoded(beforeOther) == encoded(afterOther), "unrelated unsaved progress is not included in epoch transaction")
            try check(durableAfter.revision == durableBefore.revision + 1 && durableAfter.items[0].state == .completed,
                      "epoch publication is one revision without replay")
        }
        phase = "manager.file-cas"
        do {
            let f = try Fixture(), manager = try manager(f), disk = try Data(contentsOf: manager.dataRootURL.appendingPathComponent("downloads.json"))
            try rejects("artifact changes before persistence") {
                _ = try manager.reauthorizeDestination(f.directory, originalGrantID: f.grantID,
                    volumeUUID: { _ in f.volume }, bookmarkData: { _ in replacementBookmark },
                    beforeCommit: { try write(Data(repeating: 0x42, count: f.payload.count), to: f.completeURL) })
            }
            try check(manager.destinations[0].device == f.oldDevice && manager.items[0].artifact?.device == f.oldDevice, "file CAS failure no epoch publication")
            try check(try Data(contentsOf: manager.dataRootURL.appendingPathComponent("downloads.json")) == disk, "file CAS failure no DB write")
        }
    }

    @MainActor static func main() {
        do {
            try coreChecks()
            try managerChecks()
            print("Download mount epoch: \(checks) targeted synthetic checks passed; no GUI, browser, external device, Keychain or transfer launched")
        } catch {
            fputs("Synthetic mount epoch failed at \(phase) after \(checks) checks (\(type(of:error))): \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
