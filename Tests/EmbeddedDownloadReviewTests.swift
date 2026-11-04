import Foundation
import Darwin

/// Real coordinator/store calls with no App, window, NSWorkspace, open panel,
/// or URLSession task. The main queue never yields between confirm and pause.
final class EmbeddedReviewEvidence: DownloadGaoExchangeEvidence {
    var value: Data?
    func load() throws -> Data? { value }
    func save(_ data: Data) throws { value = data }
}

@main
struct EmbeddedDownloadReviewTests {
    @MainActor static var checks = 0
    @MainActor static func check(_ value: @autoclosure () throws -> Bool, _ detail: String) throws {
        guard try value() else { throw DownloadError.message("内置复核检查失败：" + detail) }
        checks += 1
    }
    @MainActor static func rejects(_ detail: String, _ work: () throws -> Void) throws {
        do { try work() } catch { checks += 1; return }
        throw DownloadError.message("应拒绝：" + detail)
    }
    @MainActor static func main() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("GaoMenHu-Review-" + UUID().uuidString + ".noindex", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }
        let data = root.appendingPathComponent("Data", isDirectory: true)
        let manager = DownloadManager(rootURL: data, evidenceDefaults: nil, monitorNetwork: false)
        try check(manager.recoveryIssue == nil, "隔离下载库初始化")
        let directory = root.appendingPathComponent("Destination", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let grant = try manager.addDestination(directory)
        let exchange = DownloadGaoExchange(rootURL: data.appendingPathComponent("Exchange", isDirectory: true), evidence: EmbeddedReviewEvidence())
        let coordinator = PortalDownloadCoordinator(downloads: manager, exchange: exchange)
        var presented = 0
        coordinator.onShowWindow = { presented += 1 }
        let urls = ["http://127.0.0.1:1/fixture.bin"]
        let parent = UUID().uuidString
        var outcomes: [PortalActionOutcome] = []
        coordinator.prepareInternal(urls: urls, parentRequestID: parent) { outcomes.append($0) }
        try check(coordinator.showComposer && presented == 1 && manager.jobs.isEmpty, "复核前不能建任务")
        coordinator.cancelComposer()
        coordinator.composerDidDismiss()
        try check(outcomes == [.cancelled] && manager.jobs.isEmpty, "取消只回调一次且不建任务")

        coordinator.prepareInternal(urls: urls, parentRequestID: parent) { outcomes.append($0) }
        var busyOutcome: PortalActionOutcome?
        coordinator.prepareInternal(urls: urls) { busyOutcome = $0 }
        try check(busyOutcome?.errorCode == "download_review_busy" && manager.jobs.isEmpty, "复核中拒绝覆盖草案")
        try rejects("复核后的链接被换掉") {
            try coordinator.confirm(urls: ["http://127.0.0.1:1/changed.bin"], destinationID: grant.id, requestID: nil)
        }
        try check(manager.jobs.isEmpty && outcomes.count == 1, "改变草案不产生副作用")
        try coordinator.confirm(urls: urls, destinationID: grant.id, requestID: nil)
        // createJobs schedules on the main queue. Pause synchronously before any
        // event-loop yield; this fixture never creates a network session/task.
        manager.pauseAll()
        try check(manager.jobs.count == 1 && manager.items.count == 1, "确认创建真实任务和条目")
        try check(manager.jobs[0].requestID == UUID(uuidString: parent), "父请求关联真实任务")
        try check(outcomes.last?.status == .pending && outcomes.last?.workflowState == .accepted, "建任务不能声称下载完成")
        let ids = manager.jobs.map(\.id)
        let itemIDs = manager.items.map(\.id)
        let persisted = try Data(contentsOf: data.appendingPathComponent("downloads.json"))
        struct Envelope: Decodable { let payload: Data; let sha256: String }
        let snapshot = try JSONDecoder().decode(Envelope.self, from: persisted)
        try check(downloadDigest(snapshot.payload) == snapshot.sha256, "真实落盘快照摘要")
        let database = try JSONDecoder().decode(DownloadDatabase.self, from: snapshot.payload)
        try check(database.jobs.map(\.id) == ids && database.items.map(\.id) == itemIDs && database.items.allSatisfy { $0.state == .paused }, "父请求映射和暂停状态已持久化")

        coordinator.prepareInternal(urls: urls, parentRequestID: parent) { outcomes.append($0) }
        try coordinator.confirm(urls: urls, destinationID: grant.id, requestID: nil)
        try check(manager.jobs.map(\.id) == ids && manager.items.map(\.id) == itemIDs, "重复父请求复用任务不重下")
        try check(try Data(contentsOf: data.appendingPathComponent("downloads.json")) == persisted, "重复接受不改原任务快照")
        coordinator.prepareInternal(urls: ["http://127.0.0.1:1/other.bin"], parentRequestID: parent) { outcomes.append($0) }
        try rejects("同父请求不同URL") {
            try coordinator.confirm(urls: ["http://127.0.0.1:1/other.bin"], destinationID: grant.id, requestID: nil)
        }
        coordinator.cancelComposer()
        coordinator.prepareInternal(urls: urls, parentRequestID: parent) { outcomes.append($0) }
        try rejects("同父请求不同目录") {
            try coordinator.confirm(urls: urls, destinationID: UUID(), requestID: nil)
        }
        coordinator.cancelComposer()
        var invalid: PortalActionOutcome?
        coordinator.prepareInternal(urls: ["https://name:secret@example.invalid/"]) { invalid = $0 }
        try check(invalid?.errorCode == "invalid_parameters" && !coordinator.showComposer, "账号密码URL不能进入复核")
        try check(manager.jobs.map(\.id) == ids && exchange.records.isEmpty, "内部服务不生成外发请求包或新任务")
        try check(!fm.fileExists(atPath: data.appendingPathComponent("Exchange/Outgoing").path), "内部服务不写gaoaction外发包")
        coordinator.prepareInternal(urls: urls, parentRequestID: parent) { outcomes.append($0) }
        let countBeforeLoss = outcomes.count
        try fm.removeItem(at: data.appendingPathComponent("downloads.json"))
        try rejects("主库丢失后不能用内存旧任务接纳") {
            try coordinator.confirm(urls: urls, destinationID: grant.id, requestID: nil)
        }
        try check(outcomes.count == countBeforeLoss && coordinator.showComposer && manager.jobs.map(\.id) == ids,
                  "丢库拒绝不回调成功、不重建任务")
        try check(!fm.fileExists(atPath: data.appendingPathComponent("downloads.json").path) && manager.recoveryIssue != nil,
                  "丢库保护不写空队列覆盖")
        coordinator.cancelComposer()
        var shutdown = false
        coordinator.shutdown { shutdown = true }
        try check(shutdown && coordinator.shuttingDown, "未运行传输安全结束")
        print("EmbeddedDownloadReviewTests: \(checks) actual coordinator/store checks passed; no app, window, browser or network request launched")
    }
}
