import Foundation
import Combine
import AppKit
import Network
import Darwin

@MainActor final class DownloadManager: ObservableObject {
    @Published var items: [DownloadItem] = []
    @Published var jobs: [DownloadJob] = []
    @Published var destinations: [DestinationGrant] = []
    @Published var settings = DownloadSettings()
    @Published var recoveryIssue: String?
    @Published var lastError: String?
    private var durableBytes: [UUID:Int64] = [:]
    private let rateLimit = NetworkRateLimit()
    private var database: DownloadDatabase?
    private var store: DownloadStore?
    private var transfers: [UUID:HTTPTransfer] = [:]
    private var verifying: Set<UUID> = []
    private enum StopIntent { case pause; case cancel(Bool) }
    private var stopIntents: [UUID:StopIntent] = [:]
    private var stopCompletions: [()->Void] = []
    private var stopping = false
    private var retryTimer: Timer?
    private var budget = StagingBudget(used:0,limit:40*1024*1024*1024)
    private let networkMonitor = NWPathMonitor()
    private var observedNetwork = false
    // Only work explicitly started in this process may auto-retry after a network change.
    private var sessionAuthorizedIDs: Set<UUID> = []
    private var automaticRestarts: [UUID:Int] = [:]
    let dataRootURL: URL
    init(blockedBecause issue: String) {
        dataRootURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MenDao/DownloadCenter", isDirectory: true)
        recoveryIssue = issue
    }
    init(rootURL: URL? = nil, evidenceDefaults: UserDefaults? = .standard, monitorNetwork: Bool = true) {
        dataRootURL = rootURL ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MenDao/DownloadCenter",isDirectory:true)
        do {
            // Keep the physical path spelling stable before and after directory creation.
            // standardization can turn /private/tmp into the /tmp symlink alias.
            let exchangePath = dataRootURL.appendingPathComponent("Exchange").path
            let evidenceKey = "GaoMenHu.DownloadExchangeEvidence." + downloadDigest(Data(exchangePath.utf8))
            let coreMarker = dataRootURL.deletingLastPathComponent().appendingPathComponent(".\(dataRootURL.lastPathComponent).initialized-v1.json")
            if evidenceDefaults?.object(forKey:evidenceKey) != nil {
                guard FileManager.default.fileExists(atPath:dataRootURL.appendingPathComponent("downloads.json").path), FileManager.default.fileExists(atPath:coreMarker.path) else { throw DownloadError.message("独立跨应用初始化证据仍存在，但主资料或核心初始化记录缺失。已停止写入，请恢复完整备份。") }
            }
            let s = try DownloadStore(root:dataRootURL); let loaded = try s.load(); store = s; database = loaded
            items = loaded.items; jobs = loaded.jobs; destinations = loaded.destinations; settings = loaded.settings
            durableBytes = Dictionary(uniqueKeysWithValues: items.map { ($0.id,$0.bytesReceived) }); rateLimit.update(settings.speedLimitBytesPerSecond)
            budget = StagingBudget(used:items.filter { $0.artifact == nil }.reduce(0) { $0 + $1.bytesReceived },limit:settings.maxStagingBytes)
            try recover()
        } catch { recoveryIssue = "资料恢复保护：\(error.localizedDescription)" }
        if monitorNetwork {
            networkMonitor.pathUpdateHandler = { [weak self] path in DispatchQueue.main.async {
                guard let self else { return }
                if self.observedNetwork && path.status == .satisfied { self.retryAuthorizedNetworkWork() }
                self.observedNetwork = true
            } }
            networkMonitor.start(queue:DispatchQueue(label:"GaoMenHu.Downloads.Network"))
        }
        // Existing work resumes only after explicit user action; no silent replay after a crash.
    }
    deinit { networkMonitor.cancel(); retryTimer?.invalidate() }
    func verifyAvailability() throws {
        guard recoveryIssue == nil, let store, database != nil else { throw DownloadError.message(recoveryIssue ?? "资料不可用。") }
        do { try store.verifyAvailability() }
        catch {
            recoveryIssue = "原下载资料已变化，停止接收与保存：\(error.localizedDescription)"
            for transfer in transfers.values { transfer.cancel() }
            throw error
        }
    }
    private func requireWritable() throws { try verifyAvailability() }
    @discardableResult private func persist() -> Bool {
        guard recoveryIssue == nil, var db = database, let store else { return false }
        db.items = items.map { item in
            var durable = item
            if item.artifact == nil { durable.bytesReceived = durableBytes[item.id,default:0]; durable.bytesPerSecond = 0 }
            return durable
        }; db.jobs = jobs; db.destinations = destinations; db.settings = settings; db.revision += 1
        do { try store.save(db); database = db; return true }
        catch { recoveryIssue = "保存资料失败，已停止新写入：\(error.localizedDescription)"; for transfer in transfers.values { transfer.cancel() }; return false }
    }
    func addDestination(_ url: URL) throws -> DestinationGrant {
        try requireWritable(); let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let fd = try openDirectoryNoLinks(url); defer { close(fd) }; let s = try statIdentity(fd)
        guard faccessat(fd,".",W_OK,0) == 0 else { throw DownloadError.message("所选目录不可写。") }
        let bookmark = try url.bookmarkData(options:[.withSecurityScope],includingResourceValuesForKeys:[.volumeUUIDStringKey],relativeTo:nil)
        let volume = try URL(fileURLWithPath:url.path,isDirectory:true).resourceValues(forKeys:[.volumeUUIDStringKey]).volumeUUIDString
        // A remount is not a new destination. Only the explicit original-grant
        // transaction can rebind its device and all related file evidence.
        if let original = destinations.first(where:{ $0.inode == UInt64(s.st_ino) && (($0.requiresReauthorization == true && $0.device == UInt64(s.st_dev)) || (DownloadMountEpoch.sameVolumeID($0.volumeUUID,volume) && ($0.device != UInt64(s.st_dev) || $0.requiresReauthorization == true))) }) {
            guard let renewed = try reauthorizeDestination(url,originalGrantID:original.id) else { throw DownloadError.message("未完成原目录重新授权。") }
            return renewed
        }
        if let index = destinations.firstIndex(where:{ $0.device == UInt64(s.st_dev) && $0.inode == UInt64(s.st_ino) }) {
            if let originalVolume = destinations[index].volumeUUID {
                guard DownloadMountEpoch.sameVolumeID(volume,originalVolume) else { throw DownloadError.message("所选目录的原卷身份不一致；未更新授权或复用旧分片。") }
            }
            destinations[index].bookmark = bookmark; destinations[index].displayPath = url.path; destinations[index].volumeUUID = volume; destinations[index].requiresReauthorization = false
            guard persist() else { throw DownloadError.message(recoveryIssue ?? "保存授权失败。") }; return destinations[index]
        }
        let grant = DestinationGrant(id:UUID(),displayPath:url.path,bookmark:bookmark,device:UInt64(s.st_dev),inode:UInt64(s.st_ino),volumeUUID:volume)
        destinations.append(grant); guard persist() else { throw DownloadError.message(recoveryIssue ?? "保存授权失败。") }; return grant
    }

    /// Called only after the user explicitly selects the original directory.
    /// The optional hooks support isolated fault/CAS checks; a successful hook
    /// never replaces the real atomic store save.
    @discardableResult
    func reauthorizeDestination(_ selectedURL: URL?, originalGrantID: UUID,
                                volumeUUID: ((URL) throws -> String?)? = nil,
                                bookmarkData: ((URL) throws -> Data)? = nil,
                                beforeCommit: (() throws -> Void)? = nil,
                                persistCandidate: ((DownloadDatabase) throws -> Void)? = nil) throws -> DestinationGrant? {
        guard let selectedURL else { return nil }
        try requireWritable()
        guard !stopping, let originalDatabase = database, let store,
              let original = originalDatabase.destinations.first(where:{ $0.id == originalGrantID }) else {
            throw DownloadError.message("原保存目录记录不可用，未修改任务或授权。")
        }
        let originalItems = originalDatabase.items.filter { $0.destinationID == originalGrantID }
        let jobIDs = Set(originalItems.map(\.jobID))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let databaseBytes = try encoder.encode(originalDatabase)
        let grantBytes = try encoder.encode([original])
        let itemBytes = try encoder.encode(originalItems)
        let jobBytes = try encoder.encode(originalDatabase.jobs.filter { jobIDs.contains($0.id) })
        func validateModel() throws {
            guard recoveryIssue == nil, !stopping, let current = database,
                  try encoder.encode(current) == databaseBytes,
                  try encoder.encode(destinations.filter { $0.id == originalGrantID }) == grantBytes,
                  try encoder.encode(items.filter { $0.destinationID == originalGrantID }) == itemBytes,
                  try encoder.encode(jobs.filter { jobIDs.contains($0.id) }) == jobBytes,
                  originalItems.allSatisfy({ item in
                      transfers[item.id] == nil && !verifying.contains(item.id) && stopIntents[item.id] == nil
                          && !item.state.isActive && item.state != .queued && item.state != .retryScheduled
                          && durableBytes[item.id] == item.bytesReceived
                  }) else {
                throw DownloadError.message("关联任务尚在运行或记录发生变化；请先暂停并保留原目录，未更新授权。")
            }
        }
        try validateModel()
        let scoped = selectedURL.startAccessingSecurityScopedResource()
        defer { if scoped { selectedURL.stopAccessingSecurityScopedResource() } }
        let bookmark = try bookmarkData?(selectedURL) ?? selectedURL.bookmarkData(options:[.withSecurityScope],includingResourceValuesForKeys:[.volumeUUIDStringKey],relativeTo:nil)
        let readVolume = {
            if let volumeUUID { return try volumeUUID(selectedURL) }
            // A fresh URL avoids a cached NSURL resource value across checks.
            return try URL(fileURLWithPath:selectedURL.path,isDirectory:true).resourceValues(forKeys:[.volumeUUIDStringKey]).volumeUUIDString
        }
        let plan = try DownloadMountEpoch.prepare(original:original,items:originalItems,selectedURL:selectedURL,
                                                  renewedBookmark:bookmark,volumeUUID:readVolume)
        var candidate = originalDatabase
        guard candidate.revision < UInt64.max,
              let grantIndex = candidate.destinations.firstIndex(where:{ $0.id == originalGrantID }) else {
            throw DownloadError.message("原目录事务版本不可用，未更新授权。")
        }
        candidate.destinations[grantIndex] = plan.grant
        let replacements = Dictionary(uniqueKeysWithValues:plan.items.map { ($0.id,$0) })
        for index in candidate.items.indices {
            if let replacement = replacements[candidate.items[index].id] { candidate.items[index] = replacement }
        }
        candidate.revision += 1
        try beforeCommit?()
        try validateModel(); try plan.validate()
        do {
            try persistCandidate?(candidate)
            try validateModel(); try plan.validate()
            try store.save(candidate,beforeAtomicCommit: {
                try validateModel(); try plan.validate()
            })
        } catch {
            // A post-rename fsync error may leave the whole new snapshot on
            // disk. Do not publish a partial model or overwrite recovery files.
            recoveryIssue = "保存目录重授权失败，已停止新写入并保留原资料：\(error.localizedDescription)"
            for transfer in transfers.values { transfer.cancel() }
            throw error
        }
        database = candidate
        if let index = destinations.firstIndex(where:{ $0.id == originalGrantID }) { destinations[index] = plan.grant }
        for index in items.indices {
            if let replacement = replacements[items[index].id] {
                items[index] = replacement
                sessionAuthorizedIDs.remove(replacement.id)
            }
        }
        // No recover(), scheduling, retry, filesystem move or partial truncation.
        return plan.grant
    }
    func createJobs(urls: [String], destinationID: UUID, requestID: UUID? = nil) throws -> [UUID] {
        try requireWritable()
        if let requestID { let previous = jobs.filter { $0.requestID == requestID }; if !previous.isEmpty { return previous.map(\.id) } }
        guard (1...32).contains(urls.count), items.count + urls.count <= 5000, destinations.contains(where:{$0.id == destinationID && $0.requiresReauthorization != true}) else { throw DownloadError.message("每批需要 1–32 个链接、有效保存目录，历史总量不超过 5000 项。") }
        let parsed = try urls.map(validatedDownloadURL)
        var ids: [UUID] = []
        for url in parsed {
            let jobID = UUID(), itemID = UUID(), now = Date()
            sessionAuthorizedIDs.insert(itemID)
            jobs.append(DownloadJob(id:jobID,requestID:requestID,itemIDs:[itemID],createdAt:now)); ids.append(jobID)
            items.append(DownloadItem(id:itemID,jobID:jobID,destinationID:destinationID,state:.queued,sourceURL:url.absoluteString,sourceFingerprint:downloadDigest(Data(url.absoluteString.utf8)),displayURL:redactedDownloadURL(url),suggestedName:safeDownloadName(url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent),bytesReceived:0,expectedBytes:nil,bytesPerSecond:0,sha256:nil,errorMessage:nil,retryAt:nil,artifact:nil,createdAt:now,etag:nil,lastModified:nil,stagingName:"\(itemID.uuidString).part"))
        }
        guard persist() else { throw DownloadError.message(recoveryIssue ?? "创建任务事务失败。") }
        DispatchQueue.main.async { [weak self] in self?.schedule() }; return ids
    }
    func pause(_ id: UUID) {
        sessionAuthorizedIDs.remove(id)
        guard recoveryIssue == nil, let i = index(id), !items[i].state.isTerminal else { return }
        if transfers[id] != nil || verifying.contains(id) { stopIntents[id] = .pause; items[i].state = .pausing; _ = persist(); transfers[id]?.cancel() }
        else { items[i].state = .paused; items[i].retryAt = nil; items[i].bytesPerSecond = 0; _ = persist() }
    }
    func resume(_ id: UUID) {
        guard recoveryIssue == nil, let i = index(id), items[i].state.canResume, transfers[id] == nil, !verifying.contains(id), items[i].artifact == nil else { return }
        sessionAuthorizedIDs.insert(id)
        stopIntents[id] = nil; automaticRestarts[id] = 0; items[i].state = .queued; items[i].retryAt = nil; items[i].errorMessage = nil; items[i].errorCategory = nil
        _ = persist(); schedule()
    }
    func cancel(_ id: UUID, removePartial: Bool = false) {
        sessionAuthorizedIDs.remove(id)
        guard recoveryIssue == nil, let i = index(id), items[i].state != .completed else { return }
        if transfers[id] != nil || verifying.contains(id) { stopIntents[id] = .cancel(removePartial); items[i].state = .pausing; _ = persist(); transfers[id]?.cancel() }
        else { items[i].state = .cancelled; items[i].retryAt = nil; items[i].bytesPerSecond = 0; _ = persist(); if removePartial { removePartialFiles(id) } }
    }
    func retry(_ id: UUID) { guard let i = index(id), items[i].state.canResume else { return }; items[i].attempts = 0; resume(id) }
    func pauseAll() { for id in items.filter({ !$0.state.isTerminal && $0.state != .paused }).map(\.id) { pause(id) } }
    func resumeAll() { for id in items.filter({ $0.state.canResume && $0.state != .cancelled && $0.state != .failed }).map(\.id) { resume(id) } }
    func retryWaiting() { guard !stopping else { return }; for id in items.filter({ [.waitingForNetwork,.waitingForDestination].contains($0.state) }).map(\.id) { resume(id) } }
    private func retryAuthorizedNetworkWork() {
        guard !stopping else { return }
        for id in items.filter({ $0.state == .waitingForNetwork && sessionAuthorizedIDs.contains($0.id) }).map(\.id) { resume(id) }
    }
    func deleteHistory(_ id: UUID) {
        guard recoveryIssue == nil, let i = index(id), items[i].state.isTerminal || items[i].state == .paused, transfers[id] == nil, !verifying.contains(id) else { return }
        // An owned partial remains discoverable until the user explicitly removes it.
        guard jobs.first(where:{$0.id == items[i].jobID})?.requestID == nil else { lastError = "跨应用任务的持久请求映射必须保留，不能单独删除历史。"; return }
        guard items[i].bytesReceived == 0 || items[i].artifact != nil || items[i].stagingInode == nil else { lastError = "此项仍有自有暂存数据。请先使用“清理暂存”或保留历史以便恢复。"; return }
        let jobID = items[i].jobID; items.remove(at:i); jobs.removeAll { $0.id == jobID }; durableBytes[id] = nil; _ = persist()
    }
    func removePartialFiles(_ id: UUID) {
        guard recoveryIssue == nil, let i = index(id), transfers[id] == nil, !verifying.contains(id), items[i].artifact == nil else { return }
        do {
            try verifyAvailability()
            guard let grant = destinations.first(where:{$0.id == items[i].destinationID}) else { throw DownloadError.message("缺少原目标授权。") }
            let access = try DestinationAccess(grant); let dir = try access.stagingDirectory(grantID:grant.id,create:false); defer { close(dir) }
            let fd = openat(dir,items[i].stagingName,O_RDONLY|O_NOFOLLOW|O_CLOEXEC)
            if fd < 0 && errno == ENOENT { guard items[i].bytesReceived == 0 else { throw DownloadError.message("已记录暂存文件缺失，保留任务以便恢复。") }; return }
            guard fd >= 0 else { throw posixFailure("打开待清理暂存文件") }; defer { close(fd) }
            let s = try statIdentity(fd); try validateStaging(s,item:items[i]); try access.validate(grant)
            var current = stat(); guard fstatat(dir,items[i].stagingName,&current,AT_SYMLINK_NOFOLLOW) == 0, current.st_ino == s.st_ino, current.st_dev == s.st_dev, unlinkat(dir,items[i].stagingName,0) == 0, fsync(dir) == 0 else { throw posixFailure("清理自有暂存文件") }
            budget.release(Int64(s.st_size)); durableBytes[id] = 0; items[i].partialSHA256 = nil; items[i].bytesReceived = 0; items[i].expectedBytes = nil; items[i].etag = nil; items[i].stagingInode = nil; items[i].stagingDevice = nil; items[i].pendingArtifact = nil; _ = persist()
        } catch { lastError = "未清理暂存：\(error.localizedDescription)" }
    }
    func updateSettings(_ value: DownloadSettings) {
        guard recoveryIssue == nil else { return }; var v = value
        v.concurrency = min(2,max(1,v.concurrency)); v.speedLimitBytesPerSecond = min(1024*1024*1024,max(0,v.speedLimitBytesPerSecond)); v.maxItemBytes = min(1024*1024*1024*1024,max(1024,v.maxItemBytes)); v.maxStagingBytes = min(2*1024*1024*1024*1024,max(1024,v.maxStagingBytes)); if !["system","light","dark"].contains(v.appearance) { v.appearance = "system" }
        settings = v; budget.updateLimit(v.maxStagingBytes); rateLimit.update(v.speedLimitBytesPerSecond); _ = persist(); schedule()
    }
    func shutdown(completion: @escaping ()->Void) {
        sessionAuthorizedIDs.removeAll()
        stopping = true; retryTimer?.invalidate(); retryTimer = nil; stopCompletions.append(completion); pauseAll(); finishStoppingIfReady()
    }
    func pauseAllAndWait(completion: @escaping ()->Void) { shutdown(completion:completion) }
    private func finishStoppingIfReady() {
        guard stopping, transfers.isEmpty, verifying.isEmpty else { return }; _ = persist(); stopping = false; let callbacks = stopCompletions; stopCompletions = []; for callback in callbacks { callback() }
    }
    func artifactURL(_ item: DownloadItem) throws -> URL {
        let (current,grant) = try artifactSnapshot(item)
        return try verifiedArtifactURL(current,grant:grant)
    }
    func validateArtifact(_ item: DownloadItem, completion: @escaping (Result<URL,Error>)->Void) {
        do {
            let (current,grant) = try artifactSnapshot(item)
            DispatchQueue.global(qos:.utility).async {
                let result = Result { try verifiedArtifactURL(current,grant:grant) }
                DispatchQueue.main.async { completion(result) }
            }
        } catch { completion(.failure(error)) }
    }
    private func artifactSnapshot(_ item: DownloadItem) throws -> (DownloadItem,DestinationGrant) {
        try verifyAvailability()
        guard let current = items.first(where:{$0.id == item.id}), current.state == .completed, let artifact = current.artifact, artifact.fileName == safeDownloadName(artifact.fileName), let grant = destinations.first(where:{$0.id == current.destinationID}) else { throw DownloadError.message("该条目尚无已发布文件。") }
        return (current,grant)
    }
    private func index(_ id: UUID) -> Int? { items.firstIndex { $0.id == id } }
    private func recover() throws {
        // A same-volume remount can invalidate a previously local grant too.
        // This metadata-only observation revokes access; it never updates the
        // recorded device, resolves a bookmark, or opens/truncates any file.
        for index in destinations.indices where destinations[index].requiresReauthorization != true {
            let grant = destinations[index]
            let url = URL(fileURLWithPath:grant.displayPath,isDirectory:true)
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let fd = try? openDirectoryNoLinks(url) else { continue }
            defer { close(fd) }
            let current = try statIdentity(fd)
            guard UInt64(current.st_dev) != grant.device, UInt64(current.st_ino) == grant.inode,
                  current.st_uid == getuid(), current.st_mode & 0o022 == 0,
                  faccessat(fd,".",W_OK | X_OK,0) == 0,
                  let volume = try? URL(fileURLWithPath:grant.displayPath,isDirectory:true).resourceValues(forKeys:[.volumeUUIDStringKey]).volumeUUIDString,
                  DownloadMountEpoch.sameVolumeID(grant.volumeUUID,volume) else { continue }
            destinations[index].requiresReauthorization = true
        }
        for i in items.indices {
            if destinations.first(where: { $0.id == items[i].destinationID })?.requiresReauthorization == true {
                // Preserve completed history and exact partial/publication evidence.
                // Imported permissions do not authorize file access in this host.
                if !items[i].state.isTerminal {
                    items[i].state = .waitingForDestination; items[i].bytesPerSecond = 0; items[i].retryAt = nil
                    items[i].errorMessage = "等待在搞门户重新选择原保存目录；不会自动重新下载。"
                }
                continue
            }
            if items[i].artifact == nil, items[i].stagingInode != nil {
                guard let grant = destinations.first(where:{$0.id == items[i].destinationID}) else { throw DownloadError.message("暂存归属缺少目标记录。") }
                let access = try DestinationAccess(grant); let dir = try access.stagingDirectory(grantID:grant.id,create:false); defer { close(dir) }
                let fd = openat(dir,items[i].stagingName,O_RDWR|O_NOFOLLOW|O_CLOEXEC)
                if fd < 0 && items[i].pendingArtifact != nil && errno == ENOENT {
                    // A persisted publication may legitimately have already unlinked staging.
                } else {
                    guard fd >= 0 else { throw DownloadError.message("登记的暂存缺失或目标未挂载，已停止新任务。恢复原目标后重新打开应用。") }; defer { close(fd) }
                    let s = try statIdentity(fd)
                    if items[i].pendingArtifact == nil {
                        try validateStaging(s,item:items[i]); guard s.st_size >= items[i].bytesReceived else { throw DownloadError.message("暂存文件小于已提交范围，已停止写入。") }
                        if s.st_size > items[i].bytesReceived {
                            guard ftruncate(fd,off_t(items[i].bytesReceived)) == 0, fsync(fd) == 0 else { throw posixFailure("丢弃崩溃后未提交尾数据") }
                            items[i].resumeExplanation = "崩溃后已丢弃未提交尾数据；恢复前仍须核验本地断点摘要。"
                        }
                    } else {
                        guard (s.st_mode & S_IFMT) == S_IFREG, s.st_uid == getuid(), items[i].stagingDevice == UInt64(s.st_dev), items[i].stagingInode == UInt64(s.st_ino), s.st_size == items[i].bytesReceived else { throw DownloadError.message("中断发布暂存身份或长度无效。") }
                    }
                }
            }
            if items[i].state == .completed {
                guard items[i].artifact != nil else { throw DownloadError.message("完成条目缺少已发布产物记录。") }
                // Large files are revalidated on open/export; never fabricate a completion on recovery.
                continue
            }
            if items[i].pendingArtifact != nil { items[i].state = .paused; items[i].errorMessage = "上次在文件发布事务中中断。请重试以核验已发布文件；不会直接标记完成。" }
            else if items[i].state.isActive || items[i].state == .queued || items[i].state == .retryScheduled { items[i].state = .paused; items[i].errorMessage = "应用关闭或中断，任务已暂停；请确认后恢复。" }
            items[i].bytesPerSecond = 0; items[i].retryAt = nil
        }
        _ = persist()
    }
    private func schedule() {
        guard recoveryIssue == nil, !stopping else { return }
        retryTimer?.invalidate(); retryTimer = nil
        for i in items.indices where items[i].state == .retryScheduled && (items[i].retryAt ?? .distantFuture) <= Date() { items[i].state = .queued; items[i].retryAt = nil }
        while transfers.count + verifying.count < settings.concurrency {
            let activeHosts = Set(transfers.keys.compactMap { id in items.first(where:{$0.id == id}).flatMap { URL(string:$0.sourceURL)?.host?.lowercased() } })
            guard let next = items.first(where:{ $0.state == .queued && !activeHosts.contains(URL(string:$0.sourceURL)?.host?.lowercased() ?? "") }) else { break }
            start(next.id)
        }
        if let earliest = items.filter({$0.state == .retryScheduled}).compactMap(\.retryAt).min() {
            retryTimer = Timer.scheduledTimer(withTimeInterval:max(0.1,earliest.timeIntervalSinceNow),repeats:false) { [weak self] _ in Task { @MainActor in self?.schedule() } }
        }
    }
    private func start(_ id: UUID) {
        guard let i = index(id), let grant = destinations.first(where:{$0.id == items[i].destinationID}) else { return }
        guard items[i].attempts < 6 else { items[i].state = .failed; items[i].errorMessage = "已达总自动尝试上限，请检查来源和网络后手动重试。"; items[i].errorCategory = "server_retry_exhausted"; _ = persist(); return }
        do {
            try verifyAvailability()
            let access = try DestinationAccess(grant)
            if let pending = items[i].pendingArtifact { verifyPending(id,grant:grant,access:access,artifact:pending); return }
            let dir = try access.stagingDirectory(grantID:grant.id,create:true)
            var ownsDirectoryFD = true; defer { if ownsDirectoryFD { close(dir) } }
            let existing = items[i].stagingInode != nil
            let flags = O_RDWR|O_NOFOLLOW|O_CLOEXEC|(existing ? 0 : O_CREAT|O_EXCL)
            let fd = openat(dir,items[i].stagingName,flags,0o600)
            guard fd >= 0 else { throw DownloadError.message(existing ? "已记录暂存文件缺失／不可读；没有创建空白文件覆盖。" : "暂存路径已被占用或目标不可写。") }
            var ownsFD = true; defer { if ownsFD { close(fd) } }
            let s = try statIdentity(fd); guard regularOwned(s) else { throw DownloadError.message("暂存文件类型、所有者或链接数无效。") }
            if existing { try validateStaging(s,item:items[i]); guard s.st_size >= items[i].bytesReceived else { throw DownloadError.message("暂存文件小于已提交范围，停止恢复。") } }
            else { items[i].stagingDevice = UInt64(s.st_dev); items[i].stagingInode = UInt64(s.st_ino) }
            if items[i].bytesReceived > 0 && items[i].etag == nil && items[i].expectedBytes != items[i].bytesReceived { budget.release(items[i].bytesReceived); durableBytes[id] = 0; items[i].partialSHA256 = nil; items[i].bytesReceived = 0; items[i].resumeExplanation = "服务器没有可靠强 ETag，本次安全从零重新下载。" }
            guard ftruncate(fd,off_t(items[i].bytesReceived)) == 0, lseek(fd,off_t(items[i].bytesReceived),SEEK_SET) >= 0 else { throw posixFailure("恢复已提交断点") }
            items[i].state = .running; items[i].attempts += 1; items[i].errorMessage = nil; items[i].errorCategory = nil
            guard persist() else { return }
            let transfer = try HTTPTransfer(item:items[i],grant:grant,access:access,stageFD:dir,fileFD:fd,settings:settings,budget:budget,rateLimit:rateLimit) { [weak self] event in DispatchQueue.main.async { self?.handle(id,event:event) } }
            ownsFD = false; ownsDirectoryFD = false; transfers[id] = transfer
            if items[i].bytesReceived > 0 {
                let expectedHash = items[i].partialSHA256; let expectedCount = items[i].bytesReceived
                items[i].state = .verifying; verifying.insert(id); _ = persist()
                DispatchQueue.global(qos:.utility).async { [weak self] in
                    let result = Result { try hashDescriptor(transfer.fileFD,expected:expectedCount) }
                    DispatchQueue.main.async { guard let self, let i = self.index(id) else { return }
                        self.verifying.remove(id)
                        if self.stopIntents[id] != nil || self.transfers[id] == nil { return }
                        switch result {
                        case .success(let (digest,_)) where digest == expectedHash:
                            if self.items[i].expectedBytes == self.items[i].bytesReceived {
                                self.items[i].state = .verifying; self.verifying.insert(id); _ = self.persist(); self.verify(id,transfer:transfer)
                            } else { self.items[i].state = .running; _ = self.persist(); transfer.start() }
                        default:
                            self.transfers[id] = nil; transfer.cancel(); self.items[i].state = .partial; self.items[i].errorMessage = "已保存断点的本地 SHA-256 不符或缺失，未发送续传请求。可清理本项暂存后重新下载。"; self.items[i].errorCategory = "integrity_failure"; _ = self.persist(); self.schedule(); self.finishStoppingIfReady()
                        }
                    }
                }
            } else { transfer.start() }
        } catch { items[i].state = .waitingForDestination; items[i].errorMessage = error.localizedDescription; items[i].errorCategory = "destination_unavailable"; items[i].bytesPerSecond = 0; _ = persist() }
    }
    private func handle(_ id: UUID, event: TransferEvent) {
        guard let i = index(id), let transfer = transfers[id] else { return }
        switch event {
        case let .response(expected,etag,modified,name): items[i].expectedBytes = expected; items[i].etag = etag; items[i].lastModified = modified; if let name { items[i].suggestedName = name }; _ = persist()
        case let .progress(bytes,speed): items[i].bytesReceived = bytes; items[i].bytesPerSecond = speed
        case let .ended(bytes,failure):
            items[i].bytesReceived = bytes; items[i].bytesPerSecond = 0; verifying.insert(id)
            // Progress stays in memory. Only fsynced, stream-hashed prefixes become durable checkpoints.
            DispatchQueue.global(qos:.utility).async { [weak self] in
                let result = Result { guard fsync(transfer.fileFD) == 0 else { throw posixFailure("同步已提交断点") }; return try hashDescriptor(transfer.fileFD,expected:bytes) }
                DispatchQueue.main.async { guard let self, let i = self.index(id) else { return }
                    self.verifying.remove(id)
                    switch result {
                    case .success(let (digest,count)): self.durableBytes[id] = count; self.items[i].partialSHA256 = digest; self.finishEnded(id,transfer:transfer,bytes:bytes,failure:failure)
                    case .failure(let error): self.verificationFailed(id,error:error)
                    }
                }
            }
        }
    }
    private func finishEnded(_ id: UUID,transfer:HTTPTransfer,bytes:Int64,failure:TransferFailure?) {
        guard let i = index(id) else { return }
            items[i].bytesReceived = bytes; items[i].bytesPerSecond = 0
            if let intent = stopIntents.removeValue(forKey:id) {
                transfers[id] = nil
                switch intent { case .pause: items[i].state = .paused; case .cancel(let remove): items[i].state = .cancelled; _ = persist(); if remove { removePartialFiles(id) } }
                _ = persist(); schedule(); finishStoppingIfReady(); return
            }
            guard recoveryIssue == nil else { transfers[id] = nil; finishStoppingIfReady(); return }
            if let failure {
                items[i].errorCategory = failure.errorCategory
                transfers[id] = nil
                switch failure {
                case .restart(let reason):
                    let count = automaticRestarts[id,default:0] + 1; automaticRestarts[id] = count
                    if count <= 2 {
                        if ftruncate(transfer.fileFD,0) == 0 && fsync(transfer.fileFD) == 0 { budget.release(items[i].bytesReceived); durableBytes[id] = 0; items[i].partialSHA256 = nil; items[i].bytesReceived = 0; items[i].etag = nil; items[i].expectedBytes = nil; items[i].resumeExplanation = reason; items[i].state = .queued }
                        else { items[i].state = .waitingForDestination; items[i].errorMessage = "无法安全重置本任务暂存文件。" }
                    } else { items[i].state = .failed; items[i].errorMessage = "服务器断点响应持续不一致，已停止重试。" }
                case .transient(let reason,let retryDate):
                    if items[i].attempts < 6 { items[i].state = .retryScheduled; let delay = min(300,pow(2,Double(items[i].attempts))) + Double.random(in:0...1); items[i].retryAt = max(retryDate ?? Date(),Date().addingTimeInterval(delay)); items[i].errorMessage = reason }
                    else { items[i].state = .failed; items[i].errorMessage = "已达自动重试上限。\(reason)" }
                case .network(let reason): items[i].state = .waitingForNetwork; items[i].errorMessage = reason
                case .destination(let reason): items[i].state = reason.contains("预算") ? .partial : .waitingForDestination; items[i].errorMessage = reason
                case .permanent(let reason): items[i].state = .failed; items[i].errorMessage = reason
                }
                _ = persist(); schedule(); finishStoppingIfReady()
            } else { items[i].state = .verifying; _ = persist(); verifying.insert(id); verify(id,transfer:transfer) }
    }
    private func validateStaging(_ s: stat, item: DownloadItem) throws {
        guard regularOwned(s), item.stagingDevice == UInt64(s.st_dev), item.stagingInode == UInt64(s.st_ino) else { throw DownloadError.message("暂存文件身份变化，已停止读取或清理。") }
    }
    private func verify(_ id: UUID, transfer: HTTPTransfer) {
        guard let i = index(id) else { return }; let snapshot = items[i]
        DispatchQueue.global(qos:.utility).async { [weak self] in
            let result = Result { try hashDescriptor(transfer.fileFD,expected:snapshot.expectedBytes ?? snapshot.bytesReceived) }
            DispatchQueue.main.async {
                guard let self, let i = self.index(id) else { return }
                if self.stopIntents[id] != nil { self.completeStoppedVerification(id); return }
                switch result {
                case .failure(let error): self.verificationFailed(id,error:error)
                case .success(let (digest,count)):
                    self.items[i].sha256 = digest; self.items[i].state = .committing
                    do {
                        let s = try statIdentity(transfer.fileFD)
                        let artifact = PublishedArtifact(fileName:self.items[i].suggestedName,byteCount:count,sha256:digest,device:UInt64(s.st_dev),inode:UInt64(s.st_ino))
                        self.items[i].pendingArtifact = artifact
                        guard self.persist() else { self.verificationFailed(id,error:DownloadError.message("保存发布事务失败。")); return }
                        self.commit(id,transfer:transfer,artifact:artifact)
                    } catch { self.verificationFailed(id,error:error) }
                }
            }
        }
    }
    private func commit(_ id: UUID, transfer: HTTPTransfer, artifact: PublishedArtifact, collision: Int = 0, baseName: String? = nil) {
        guard let i = index(id), let grant = destinations.first(where:{$0.id == items[i].destinationID}) else { return }
        guard collision < 1000 else { verificationFailed(id,error:DownloadError.message("同名文件过多，没有覆盖任何原文件。")); return }
        let base = baseName ?? artifact.fileName
        var candidateArtifact = artifact; candidateArtifact.fileName = collisionName(base,index:collision)
        items[i].pendingArtifact = candidateArtifact
        guard persist() else { verificationFailed(id,error:DownloadError.message("保存待发布精确文件名失败。")); return }
        let snapshot = items[i], output = candidateArtifact
        DispatchQueue.global(qos:.utility).async { [weak self] in
            let result: Result<Bool,Error> = Result {
                try transfer.access.validate(grant); let s = try statIdentity(transfer.fileFD)
                guard regularOwned(s), UInt64(s.st_dev) == output.device, UInt64(s.st_ino) == output.inode else { throw DownloadError.message("提交前暂存文件身份已改变。") }
                var atPath = stat(); guard fstatat(transfer.stageFD,snapshot.stagingName,&atPath,AT_SYMLINK_NOFOLLOW) == 0, atPath.st_ino == s.st_ino, atPath.st_dev == s.st_dev else { throw DownloadError.message("提交前暂存路径被替换。") }
                // Persist the exact intended name before each atomic, no-overwrite link attempt.
                if linkat(transfer.stageFD,snapshot.stagingName,transfer.access.fd,output.fileName,0) != 0 {
                    if errno == EEXIST { return false }; throw posixFailure("无覆盖发布文件")
                }
                guard fsync(transfer.access.fd) == 0 else { throw posixFailure("同步发布目录") }
                let digest = try hashAllowKnownPair(transfer.fileFD,expected:output.byteCount)
                guard digest == output.sha256 else { throw DownloadError.message("发布期间文件内容发生变化，保留事务以便恢复。") }
                return true
            }
            DispatchQueue.main.async {
                guard let self, let i = self.index(id) else { return }
                switch result {
                case .failure(let error): self.verificationFailed(id,error:error)
                case .success(false):
                    if self.stopIntents[id] != nil { self.items[i].pendingArtifact = nil; self.completeStoppedVerification(id) }
                    else { self.commit(id,transfer:transfer,artifact:artifact,collision:collision+1,baseName:base) }
                case .success(true):
                    self.items[i].pendingArtifact = output
                    guard self.persist() else { self.verificationFailed(id,error:DownloadError.message("发布记录保存失败，保留文件和暂存以恢复。")); return }
                    if unlinkat(transfer.stageFD,snapshot.stagingName,0) != 0 || fsync(transfer.stageFD) != 0 { self.verificationFailed(id,error:DownloadError.message("文件已发布但暂存链接清理失败；保留恢复记录。")); return }
                    self.items[i].artifact = output; self.items[i].pendingArtifact = nil; self.items[i].state = .completed; self.items[i].bytesReceived = output.byteCount; self.items[i].errorMessage = nil; self.items[i].errorCategory = nil; self.budget.release(output.byteCount)
                    transfer.cancel(); self.transfers[id] = nil; self.verifying.remove(id); self.stopIntents[id] = nil; _ = self.persist(); self.schedule(); self.finishStoppingIfReady()
                }
            }
        }
    }
    private func verificationFailed(_ id: UUID, error: Error) { guard let i = index(id) else { return }; transfers[id]?.cancel(); transfers[id] = nil; verifying.remove(id); items[i].state = .partial; items[i].errorMessage = error.localizedDescription; items[i].errorCategory = "integrity_failure"; _ = persist(); schedule(); finishStoppingIfReady() }
    private func completeStoppedVerification(_ id: UUID) {
        guard let i = index(id), let intent = stopIntents.removeValue(forKey:id) else { return }; transfers[id] = nil; verifying.remove(id)
        switch intent { case .pause: items[i].state = .paused; case .cancel(let remove): items[i].state = .cancelled; _ = persist(); if remove { removePartialFiles(id) } }
        _ = persist(); schedule(); finishStoppingIfReady()
    }
    private func verifyPending(_ id: UUID, grant: DestinationGrant, access: DestinationAccess, artifact: PublishedArtifact) {
        guard let i = index(id) else { return }; let snapshot = items[i]
        verifying.insert(id); items[i].state = .verifying; _ = persist()
        DispatchQueue.global(qos:.utility).async { [weak self] in
            let result:Result<Bool,Error> = Result {
                let fd = openat(access.fd,artifact.fileName,O_RDONLY|O_NOFOLLOW|O_CLOEXEC)
                let finalStat = fd >= 0 ? try statIdentity(fd) : nil
                if fd < 0 || finalStat.map({ UInt64($0.st_dev) != artifact.device || UInt64($0.st_ino) != artifact.inode }) == true {
                    if fd >= 0 { close(fd) }
                    // The app may have stopped after recording intent, before linkat. Verify staging,
                    // then retry only the publication transaction; no new network transfer is needed.
                    let dir = try access.stagingDirectory(grantID:grant.id,create:false); defer { close(dir) }
                    let partialFD = openat(dir,snapshot.stagingName,O_RDONLY|O_NOFOLLOW|O_CLOEXEC)
                    guard partialFD >= 0 else { throw DownloadError.message("中断发布的产物和自有暂存均不可读取。") }; defer { close(partialFD) }
                    let stage = try statIdentity(partialFD)
                    guard regularOwned(stage), UInt64(stage.st_dev) == artifact.device, UInt64(stage.st_ino) == artifact.inode else { throw DownloadError.message("中断发布暂存身份无效，不能重新发布。") }
                    let (digest,count) = try hashDescriptor(partialFD,expected:artifact.byteCount)
                    guard digest == artifact.sha256, count == artifact.byteCount, snapshot.expectedBytes == nil || snapshot.expectedBytes == count else { throw DownloadError.message("中断发布暂存长度或摘要不符。") }
                    try access.validate(grant); return false
                }
                defer { close(fd) }
                guard let s = finalStat, (s.st_mode & S_IFMT) == S_IFREG, s.st_uid == getuid(), s.st_nlink == 1 || s.st_nlink == 2 else { throw DownloadError.message("中断产物身份无效。") }
                if s.st_nlink == 2 {
                    let dir = try access.stagingDirectory(grantID:grant.id,create:false); defer { close(dir) }; var stage = stat()
                    guard fstatat(dir,snapshot.stagingName,&stage,AT_SYMLINK_NOFOLLOW) == 0, stage.st_ino == s.st_ino, stage.st_dev == s.st_dev else { throw DownloadError.message("中断产物存在未知硬链接，不能恢复。") }
                    let digest = try hashAllowKnownPair(fd,expected:artifact.byteCount); guard digest == artifact.sha256 else { throw DownloadError.message("中断产物摘要不符。") }
                    guard unlinkat(dir,snapshot.stagingName,0) == 0, fsync(dir) == 0 else { throw posixFailure("完成中断发布") }
                }
                let (digest,count) = try hashDescriptor(fd,expected:artifact.byteCount); guard digest == artifact.sha256, count == artifact.byteCount, snapshot.expectedBytes == nil || snapshot.expectedBytes == count else { throw DownloadError.message("中断产物长度或摘要不符。") }; try access.validate(grant); return true
            }
            DispatchQueue.main.async { guard let self, let i = self.index(id) else { return }; switch result {
                case .success(false):
                    self.items[i].pendingArtifact = nil; self.items[i].expectedBytes = artifact.byteCount; self.items[i].partialSHA256 = artifact.sha256; self.items[i].state = .queued; self.verifying.remove(id)
                    if self.stopIntents[id] != nil { self.completeStoppedVerification(id) } else { _ = self.persist(); self.schedule(); self.finishStoppingIfReady() }
                case .success(true):
                    self.items[i].artifact = artifact; self.items[i].pendingArtifact = nil; self.items[i].state = .completed; self.items[i].errorMessage = nil; self.items[i].errorCategory = nil; self.budget.release(artifact.byteCount); self.verifying.remove(id); self.stopIntents[id] = nil; _ = self.persist(); self.schedule(); self.finishStoppingIfReady()
                case .failure(let error): self.verificationFailed(id,error:error)
            } }
        }
    }

}
private func collisionName(_ name: String,index: Int) -> String {
    if index == 0 { return safeDownloadName(name) }
    let u = URL(fileURLWithPath:name); let rawExtension = u.pathExtension
    let ext = rawExtension.utf8.count <= 32 ? rawExtension : ""
    let rawStem = ext.isEmpty ? name : u.deletingPathExtension().lastPathComponent
    var stem = ""; for character in rawStem { if stem.utf8.count + String(character).utf8.count > 170 { break }; stem.append(character) }
    return safeDownloadName("\(stem) (\(index))" + (ext.isEmpty ? "" : ".\(ext)"))
}
private func hashAllowKnownPair(_ fd: Int32,expected: Int64) throws -> String {
    // Fixed descriptor, known two-name transaction. Stream without materializing the file.
    let before = try statIdentity(fd); guard before.st_size == expected else { throw DownloadError.message("中断产物长度不符。") }
    var digest = CryptoKit.SHA256(); var offset: Int64 = 0; var buffer = [UInt8](repeating:0,count:256*1024)
    while offset < expected { let n = pread(fd,&buffer,min(buffer.count,Int(expected-offset)),off_t(offset)); guard n > 0 else { throw posixFailure("校验中断产物") }; digest.update(data:Data(buffer.prefix(n))); offset += Int64(n) }
    let after = try statIdentity(fd); guard before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw DownloadError.message("校验期间产物变化。") }
    return digest.finalize().map { String(format:"%02x",$0) }.joined()
}
import CryptoKit

private func verifiedArtifactURL(_ item:DownloadItem,grant:DestinationGrant) throws -> URL {
    guard let artifact = item.artifact else { throw DownloadError.message("缺少产物记录。") }
    let access = try DestinationAccess(grant); let fd = openat(access.fd,artifact.fileName,O_RDONLY|O_NOFOLLOW|O_CLOEXEC)
    guard fd >= 0 else { throw DownloadError.message("已发布文件缺失或不可读。") }; defer { close(fd) }; let s = try statIdentity(fd)
    guard UInt64(s.st_dev) == artifact.device, UInt64(s.st_ino) == artifact.inode else { throw DownloadError.message("已发布文件已被替换。") }
    let (digest,count) = try hashDescriptor(fd,expected:artifact.byteCount); guard digest == artifact.sha256, count == artifact.byteCount else { throw DownloadError.message("已发布文件摘要不符。") }
    try access.validate(grant); return access.url.appendingPathComponent(artifact.fileName)
}
