import Foundation
import AppKit
import Combine
import Darwin

let portalDownloadVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.17"

@MainActor
final class PortalDownloadCoordinator: ObservableObject {
    let downloads: DownloadManager
    let exchange: DownloadGaoExchange
    @Published var showComposer = false
    @Published var showSettings = false
    @Published var incomingReview: UUID?
    @Published private(set) var composerURLs: [String] = []
    @Published private(set) var internalReviewID: UUID?
    @Published var selectedSection = DownloadSection.all
    @Published var alert: String?
    @Published var preparingResults: Set<UUID> = []
    @Published var shuttingDown = false
    @Published private(set) var isolatedHistory: [PortalDownloadHistoryIsolation.Entry] = []
    private var shutdownSubscription: AnyCancellable?
    private var internalCompletion: ((PortalActionOutcome) -> Void)?
    var onShowWindow: (() -> Void)?

    init(downloads: DownloadManager, exchange: DownloadGaoExchange) {
        self.downloads = downloads
        self.exchange = exchange
        if downloads.recoveryIssue == nil, exchange.recoveryIssue == nil {
            do { isolatedHistory = try PortalDownloadHistoryIsolation.readHistory(destinationRootURL: downloads.dataRootURL) }
            catch { downloads.recoveryIssue = "隔离历史或防重放依据无法核验；保留现有资料，已停止接收新的请求。" }
        }
    }

    func receive(_ urls: [URL]) {
        guard !shuttingDown else { return }
        for url in urls { exchange.receive(url) }
        selectedSection = .exchange
    }

    /// An in-process review. It never writes a handoff package or resolves the
    /// retired standalone app. Creation is deferred until explicit confirmation.
    func prepareInternal(urls: [String], parentRequestID: String? = nil,
                         completion: @escaping (PortalActionOutcome) -> Void) {
        guard !shuttingDown, downloads.recoveryIssue == nil else { completion(.failed("downloads_unavailable")); return }
        guard !showComposer, internalCompletion == nil else { completion(.failed("download_review_busy")); return }
        guard (1...32).contains(urls.count), urls.allSatisfy(DownloadGaoDownloadContract.validHTTP) else {
            completion(.failed("invalid_parameters")); return
        }
        let id: UUID
        if let parentRequestID {
            guard let parsed = UUID(uuidString: parentRequestID), !exchange.records.contains(where: { $0.id == parsed }) else {
                completion(.failed("download_request_conflict")); return
            }
            do {
                try PortalDownloadHistoryIsolation.guardNewRequest(root: downloads.dataRootURL, requestID: parentRequestID)
            } catch {
                if (error as? DownloadGaoActionPackageError)?.code != "history_identity_reserved" {
                    downloads.recoveryIssue = "下载历史的防重放依据无法核验；已停止接收新的请求，请保留现有资料。"
                }
                completion(.failed("download_request_conflict")); return
            }
            id = parsed
        } else { id = UUID() }
        composerURLs = urls
        internalReviewID = id
        internalCompletion = completion
        incomingReview = nil
        selectedSection = .all
        onShowWindow?()
        showComposer = true
    }

    func cancelComposer() {
        let callback = internalCompletion
        internalCompletion = nil; internalReviewID = nil; composerURLs = []
        incomingReview = nil; showComposer = false
        callback?(.cancelled)
    }

    func composerDidDismiss() { cancelComposer() }

    private func confirmInternal(urls: [String], destinationID: UUID) throws {
        try downloads.verifyAvailability()
        guard let id = internalReviewID, urls == composerURLs, internalCompletion != nil else {
            throw DownloadError.message("本次复核链接已变化，请重新从网站发起。")
        }
        do { try PortalDownloadHistoryIsolation.guardNewRequest(root: downloads.dataRootURL, requestID: id.uuidString) }
        catch {
            if (error as? DownloadGaoActionPackageError)?.code != "history_identity_reserved" {
                downloads.recoveryIssue = "下载历史的防重放依据无法核验；已停止创建任务，请保留现有资料。"
            }
            throw error
        }
        let previous = downloads.jobs.filter { $0.requestID == id }
        if previous.isEmpty {
            _ = try downloads.createJobs(urls: urls, destinationID: destinationID, requestID: id)
        } else {
            guard previous.count == urls.count else { throw DownloadError.message("原请求的实际任务映射不完整，未重新下载。") }
            for (index, job) in previous.enumerated() {
                guard job.itemIDs.count == 1,
                      let item = downloads.items.first(where: { $0.id == job.itemIDs[0] }),
                      item.jobID == job.id, item.destinationID == destinationID,
                      item.sourceURL == (try validatedDownloadURL(urls[index])).absoluteString else {
                    throw DownloadError.message("本次请求已关联另一组链接或保存目录，未重建任务。")
                }
            }
        }
        let callback = internalCompletion
        internalCompletion = nil; internalReviewID = nil; composerURLs = []
        incomingReview = nil; showComposer = false; selectedSection = .all
        callback?(PortalActionOutcome(status: .pending, workflowState: .accepted))
    }

    func confirm(urls: [String], destinationID: UUID, requestID: UUID?) throws {
        guard !shuttingDown else { throw DownloadError.message("正在安全退出，请稍候。") }
        guard downloads.recoveryIssue == nil else { throw DownloadError.message("下载资料已进入恢复保护，未接纳本次复核。") }
        if requestID == nil, internalReviewID != nil {
            try confirmInternal(urls: urls, destinationID: destinationID); return
        }
        try downloads.verifyAvailability()
        guard !exchange.isPackaging else { throw DownloadError.message("正在核验或准备结果，请完成后再确认新的请求。") }
        // The download store is the source of truth if an earlier approval was
        // interrupted between its two independent durable records.
        let previous = requestID.map { id in downloads.jobs.filter { $0.requestID == id } } ?? []
        if let requestID {
            if !previous.isEmpty { try verifyPreviousJobs(previous, requestID: requestID, urls: urls) }
            try exchange.preflightApproval(requestID, allowingPreviouslyCreatedTasks: !previous.isEmpty)
        }
        let taskIDs: [UUID]
        if !previous.isEmpty {
            guard previous.count == urls.count else { throw DownloadError.message("关联任务数量不一致，请保留资料并查看恢复说明。") }
            taskIDs = previous.map(\.id)
        } else {
            taskIDs = try downloads.createJobs(urls: urls, destinationID: destinationID, requestID: requestID)
        }
        if let requestID {
            do {
                try exchange.accept(requestID, taskIDs: taskIDs, allowingPreviouslyCreatedTasks: !previous.isEmpty)
                let itemIDs = try taskIDs.map { jobID -> UUID in
                    guard let job = downloads.jobs.first(where: { $0.id == jobID }), job.itemIDs.count == 1, let id = job.itemIDs.first else {
                        throw DownloadError.message("关联条目缺失，保留现有任务等待核对。")
                    }
                    return id
                }
                try exchange.bindItems(requestID, itemIDs: itemIDs)
                _ = try exchange.makePendingResult(requestID)
            } catch {
                for item in downloads.items where taskIDs.contains(item.jobID) && !item.state.isTerminal { downloads.pause(item.id) }
                throw error
            }
        }
        incomingReview = nil
        showComposer = false
        selectedSection = requestID == nil ? .all : .exchange
    }

    private func verifyPreviousJobs(_ jobs: [DownloadJob], requestID: UUID, urls: [String]) throws {
        guard let record = exchange.records.first(where: { $0.id == requestID }), jobs.count == urls.count,
              let created = requestDate(record.manifest.createdAt),
              let expires = requestDate(record.manifest.expiresAt) else {
            throw DownloadError.message("原请求与实际任务映射不完整，已停止重建。")
        }
        for (index, job) in jobs.enumerated() {
            guard job.requestID == requestID, job.createdAt >= created, job.createdAt <= expires,
                  job.itemIDs.count == 1, let id = job.itemIDs.first,
                  let item = downloads.items.first(where: { $0.id == id }), item.jobID == job.id,
                  item.sourceURL == (try validatedDownloadURL(urls[index])).absoluteString else {
                throw DownloadError.message("原任务的时间、来源或条目发生冲突，请保留资料后核对。")
            }
        }
    }

    func repairAcceptance(_ record: DownloadGaoExchangeRecord) {
        guard !shuttingDown, !exchange.isPackaging else { return }
        do {
            try downloads.verifyAvailability()
            let jobs = try record.taskIDs.map { id -> DownloadJob in
                guard let job = downloads.jobs.first(where: { $0.id == id }) else { throw DownloadError.message("关联任务缺失，请查看恢复说明。") }
                return job
            }
            try verifyPreviousJobs(jobs, requestID: record.id, urls: record.urls)
            try exchange.accept(record.id, taskIDs: jobs.map(\.id), allowingPreviouslyCreatedTasks: true)
            try exchange.bindItems(record.id, itemIDs: jobs.map { $0.itemIDs[0] })
            _ = try exchange.makePendingResult(record.id)
        } catch { alert = error.localizedDescription }
    }

    private func requestDate(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = raw.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    func resumeOrRetry(_ item: DownloadItem) {
        guard !shuttingDown else { return }
        if [.failed, .partial, .cancelled].contains(item.state) { downloads.retry(item.id) }
        else { downloads.resume(item.id) }
    }

    func generateFinal(_ record: DownloadGaoExchangeRecord) {
        guard !shuttingDown, !preparingResults.contains(record.id), !exchange.isPackaging else { return }
        preparingResults.insert(record.id)
        do {
            try downloads.verifyAvailability()
            var snapshots: [DownloadItem] = []
            for jobID in record.taskIDs {
                guard let job = downloads.jobs.first(where: { $0.id == jobID }), !job.itemIDs.isEmpty else {
                    throw DownloadError.message("关联任务缺失，请保留资料并查看恢复说明。")
                }
                for itemID in job.itemIDs {
                    guard let item = downloads.items.first(where: { $0.id == itemID }), item.state.isTerminal else {
                        throw DownloadError.message("所有条目到达终态后，才能生成最终结果。")
                    }
                    snapshots.append(item)
                }
            }
            prepareOutcome(record.id, snapshots: snapshots, index: 0, outcomes: [])
        } catch { preparingResults.remove(record.id); alert = error.localizedDescription }
    }

    private func prepareOutcome(_ requestID: UUID, snapshots: [DownloadItem], index: Int, outcomes: [DownloadGaoTaskOutcome]) {
        guard index < snapshots.count else {
            exchange.makeFinalResultAsync(requestID, outcomes: outcomes) { [weak self] result in
                guard let self else { return }
                preparingResults.remove(requestID)
                if case .failure(let error) = result { alert = error.localizedDescription }
            }
            return
        }
        let item = snapshots[index]
        if item.state == .completed {
            downloads.validateArtifact(item) { [weak self] result in
                guard let self else { return }
                switch result {
                case .failure(let error): preparingResults.remove(requestID); alert = error.localizedDescription
                case .success(let file):
                    let outcome = DownloadGaoTaskOutcome(taskID: item.jobID, itemID: item.id, state: "completed", fileURL: file,
                        byteCount: item.artifact?.byteCount, sha256: item.artifact?.sha256, errorCode: nil)
                    prepareOutcome(requestID, snapshots: snapshots, index: index + 1, outcomes: outcomes + [outcome])
                }
            }
        } else {
            let state = item.state == .cancelled ? "cancelled" : "failed"
            let code = item.state == .cancelled ? "cancelled" : item.errorCategory ?? item.state.rawValue
            let outcome = DownloadGaoTaskOutcome(taskID: item.jobID, itemID: item.id, state: state, fileURL: nil, byteCount: nil, sha256: nil, errorCode: code)
            prepareOutcome(requestID, snapshots: snapshots, index: index + 1, outcomes: outcomes + [outcome])
        }
    }

    func openArtifact(_ item: DownloadItem, reveal: Bool) {
        downloads.validateArtifact(item) { [weak self] result in
            switch result {
            case .success(let url):
                if reveal { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                else { NSWorkspace.shared.open(url) }
            case .failure(let error): self?.alert = error.localizedDescription
            }
        }
    }

    func selectDirectory() -> DestinationGrant? {
        let panel = NSOpenPanel()
        panel.title = "选择下载保存目录"
        panel.message = "文件会先在此目录所在卷的私有临时区下载，验证后发布。"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do { return try downloads.addDestination(url) }
        catch { alert = error.localizedDescription; return nil }
    }

    /// A migrated bookmark is evidence, not a newly granted permission. Select
    /// the same directory normally, then let the manager renew that exact grant.
    func reauthorizeOriginalDirectory(for item: DownloadItem) {
        guard let original = downloads.destinations.first(where: { $0.id == item.destinationID }) else {
            alert = "原保存目录记录缺失，未修改任务。"; return
        }
        let panel = NSOpenPanel()
        panel.title = "重新授权原下载保存目录"
        panel.message = "请选择原保存目录以授权搞门户。不会把已有任务或片段移到另一目录。"
        panel.directoryURL = URL(fileURLWithPath: original.displayPath, isDirectory: true)
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try downloads.reauthorizeDestination(url,originalGrantID:original.id)
        } catch { alert = error.localizedDescription }
    }

    func importPackage() {
        let panel = NSOpenPanel()
        panel.title = "接收跨应用下载请求"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, url.pathExtension == "gaoaction" else { return }
        receive([url])
    }

    func shutdown(completion: @escaping () -> Void) {
        guard !shuttingDown else { return }
        cancelComposer()
        shuttingDown = true
        downloads.shutdown { [weak self] in
            guard let self else { completion(); return }
            // An in-flight result copy must finish its atomic publication or
            // report failure before termination closes the private journal.
            shutdownSubscription = Publishers.CombineLatest(exchange.$isPackaging, $preparingResults)
                .filter { !$0.0 && $0.1.isEmpty }.first()
                .sink { _ in completion() }
        }
    }
}
