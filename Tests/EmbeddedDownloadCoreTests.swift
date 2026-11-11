// Real loopback transfer and isolated persistence tests for the embedded engine.
// No GUI, external services, browser credentials or actual user directories.
import Foundation
import Darwin

@main struct EmbeddedDownloadCoreTests {
    @MainActor static var checks = 0
    @MainActor static func check(_ value: @autoclosure () throws -> Bool, _ name: String) throws {
        guard try value() else { throw DownloadError.message("断言失败：" + name) }
        checks += 1; print("PASS \(checks) \(name)")
    }
    @MainActor static func reject(_ body: () throws -> Void, _ name: String) throws {
        do { try body() } catch { checks += 1; print("PASS \(checks) \(name)"); return }
        throw DownloadError.message("应拒绝：" + name)
    }
    @MainActor static func wait(_ m: DownloadManager, _ id: UUID, until: (DownloadItem) -> Bool) async throws -> DownloadItem {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if let issue = m.recoveryIssue { throw DownloadError.message(issue) }
            if let value = m.items.first(where: { $0.id == id }), until(value) { return value }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw DownloadError.message("隔离下载等待超时")
    }
    @MainActor static func stop(_ m: DownloadManager) async { await withCheckedContinuation { done in m.shutdown { done.resume() } } }
    @MainActor static func main() async {
        setbuf(stdout, nil)
        do { try await run(); print("Embedded download engine: \(checks) checks passed; no user data or GUI touched.") }
        catch { fputs("Embedded download tests failed: \(error)\n", stderr); exit(1) }
    }
    @MainActor static func run() async throws {
        let ports = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Int]
        let base = "http://127.0.0.1:\(ports["http"]!)"
        let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        guard root.path.contains(".noindex/") else { throw DownloadError.message("仅允许预建不索引隔离目录") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fm = FileManager.default
        func privateDir(_ name: String) throws -> URL {
            let u = root.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: u, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); return u
        }
        func fresh(_ name: String) throws -> (DownloadManager, DestinationGrant, URL) {
            let parent = try privateDir(name), dest = parent.appendingPathComponent("destination", isDirectory: true)
            try fm.createDirectory(at: dest, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let m = DownloadManager(rootURL: parent.appendingPathComponent("data", isDirectory: true), evidenceDefaults: nil, monitorNetwork: false)
            guard m.recoveryIssue == nil else { throw DownloadError.message(m.recoveryIssue!) }
            let grant = try m.addDestination(dest)
            guard !fm.fileExists(atPath: m.dataRootURL.appendingPathComponent("downloads.previous.json").path) else { throw DownloadError.message("不得创建自动下载历史备份") }
            return (m, grant, dest)
        }
        try check(strongDownloadETag("\"version-1\"") != nil && strongDownloadETag("W/\"version-1\"") == nil && strongDownloadETag("\"bad\nvalue\"") == nil, "只有可靠强ETag允许续传")
        do {
            let parent = try privateDir("store"), u = parent.appendingPathComponent("data", isDirectory: true)
            let missing = parent.appendingPathComponent("missing", isDirectory: true)
            try reject({ _ = try DownloadStore(root: missing, readOnly: true) }, "只读迁移拒绝不存在来源")
            try check(!fm.fileExists(atPath: missing.path), "来源只读检查不创建空库")
            var expected = Data()
            do { let store = try DownloadStore(root: u); let db = try store.load(); expected = try Data(contentsOf: u.appendingPathComponent("downloads.json")); try check(db.items.isEmpty, "真正首次安装可初始化私有下载库") }
            do {
                let reader = try DownloadStore(root: u, readOnly: true), db = try reader.load()
                try reject({ try reader.save(db) }, "来源只读锁禁止保存")
                try reject({ _ = try DownloadStore(root: u) }, "迁移读取期间排斥旧宿主写锁")
            }
            try check(try Data(contentsOf: u.appendingPathComponent("downloads.json")) == expected, "只读检查保持原快照字节")
            do {
                let store = try DownloadStore(root: u); let db = try store.load()
                try fm.removeItem(at: u.appendingPathComponent("downloads.json"))
                try reject({ try store.save(db) }, "已载入资料被删后不得重建空快照")
                try check(!fm.fileExists(atPath: u.appendingPathComponent("downloads.json").path), "缺失资料保存拒绝无副作用")
            }
        }
        do {
            let blank = try privateDir("existing-empty")
            try reject({ _ = try DownloadStore(root: blank) }, "已有空目录无初始化证据拒绝覆盖")
            try check(try fm.contentsOfDirectory(atPath: blank.path).isEmpty, "无初始化依据不创建锁或默认数据")
            let parent = try privateDir("missing-marker"), u = parent.appendingPathComponent("data")
            do { let s = try DownloadStore(root: u); _ = try s.load() }
            try fm.removeItem(at: parent.appendingPathComponent(".data.initialized-v1.json"))
            try reject({ _ = try DownloadStore(root: u) }, "已有主库却缺独立marker拒绝重新初始化")
        }
        do {
            let actual = try privateDir("no-symlink-target"), link = root.appendingPathComponent("linked-parent")
            try fm.createSymbolicLink(at: link, withDestinationURL: actual)
            try reject({ _ = try DownloadStore(root: link.appendingPathComponent("data")) }, "初始化不穿过父目录符号链接")
            try check(try fm.contentsOfDirectory(atPath: actual.path).isEmpty, "拒绝父目录链接前未创建任何外部内容")
        }
        do {
            let parent = try privateDir("tampered"), u = parent.appendingPathComponent("data")
            let s = try DownloadStore(root: u); let db = try s.load()
            try Data("damaged".utf8).write(to: u.appendingPathComponent("downloads.json"))
            try reject({ try s.save(db) }, "运行期间原快照被改时停止写入")
            try check(try Data(contentsOf: u.appendingPathComponent("downloads.json")) == Data("damaged".utf8), "损坏原字节不被备份内存覆盖")
        }
        do {
            let (m, g, dest) = try fresh("normal-collision")
            try Data("user-original".utf8).write(to: dest.appendingPathComponent("file"))
            let req = UUID(); let jobs = try m.createJobs(urls: [base + "/file?token=private-sample"], destinationID: g.id, requestID: req)
            let replay = try m.createJobs(urls: [base + "/file?token=private-sample"], destinationID: g.id, requestID: req)
            try check(jobs == replay && m.items.count == 1, "请求幂等返回同一真实任务")
            let item = try await wait(m, m.items[0].id) { $0.state == .completed }
            let data = try Data(contentsOf: m.artifactURL(item))
            try check(data.count == 524288 && item.artifact?.sha256 == downloadDigest(data), "真实URLSession落盘长度与SHA正确")
            try check(try String(contentsOf: dest.appendingPathComponent("file"), encoding: .utf8) == "user-original" && item.artifact?.fileName != "file", "同卷发布不覆盖原同名文件")
            try check(!item.displayURL.contains("token") && !item.displayURL.contains("private-sample"), "显示与日志标签不暴露URL查询参数")
            await stop(m)
        }
        do {
            var storedRoot: URL!, selectedDirectory: URL!
            do {
                let (m, _, dest) = try fresh("reauthorization-volume-identity")
                storedRoot = m.dataRootURL; selectedDirectory = dest; await stop(m)
            }
            do {
                let store = try DownloadStore(root: storedRoot); var db = try store.load()
                db.destinations[0].requiresReauthorization = true
                db.destinations[0].volumeUUID = "fixture-original-volume-identity"
                try store.save(db)
            }
            let m = DownloadManager(rootURL: storedRoot, evidenceDefaults: nil, monitorNetwork: false)
            try reject({ _ = try m.addDestination(selectedDirectory) }, "相同dev/inode但原卷UUID不同不得复用旧授权")
            try check(m.destinations[0].requiresReauthorization == true && m.destinations[0].volumeUUID == "fixture-original-volume-identity",
                      "重授权卷身份拒绝后保留原书签证据与待授权标记")
            await stop(m)
        }
        for change in ["delete", "replace"] {
            let (m, g, _) = try fresh("request-replay-" + change); let request = UUID()
            _ = try m.createJobs(urls: [base + "/file"], destinationID: g.id, requestID: request)
            m.pauseAll()
            let file = m.dataRootURL.appendingPathComponent("downloads.json")
            if change == "delete" { try fm.removeItem(at: file) }
            else { try Data("unexpected replacement".utf8).write(to: file) }
            try reject({ _ = try m.createJobs(urls: [base + "/file"], destinationID: g.id, requestID: request) },
                       "主库" + change + "后相同requestID不从内存假接纳")
            try check(m.recoveryIssue != nil && m.jobs.count == 1, "拒绝幂等复用同时保留历史并显示恢复保护")
            await stop(m)
        }
        do {
            // Reuse a genuine completed artifact from the ordinary GET case,
            // alongside synthetic cancelled/failed/partial historical records.
            let storedRoot = root.appendingPathComponent("normal-collision/data", isDirectory: true)
            let terminalStates: [DownloadState] = [.completed, .cancelled, .failed, .partial]
            do {
                let store = try DownloadStore(root: storedRoot); var db = try store.load()
                let completed = db.items[0]
                db.destinations[0].requiresReauthorization = true
                for state in terminalStates.dropFirst() {
                    var item = completed; item.id = UUID(); item.jobID = UUID(); item.state = state
                    item.artifact = nil; item.pendingArtifact = nil; item.bytesReceived = 0; item.bytesPerSecond = 0
                    item.stagingName = "\(item.id.uuidString).part"; item.stagingDevice = nil; item.stagingInode = nil
                    item.partialSHA256 = nil; item.sha256 = nil; item.expectedBytes = nil
                    item.errorCategory = state == .cancelled ? nil : "fixture_historical_failure"
                    db.jobs.append(DownloadJob(id: item.jobID, requestID: UUID(), itemIDs: [item.id], createdAt: item.createdAt))
                    db.items.append(item)
                }
                try store.save(db)
            }
            let m = DownloadManager(rootURL: storedRoot, evidenceDefaults: nil, monitorNetwork: false)
            try check(m.recoveryIssue == nil && m.items.map(\.state) == terminalStates,
                      "迁入待重授权目录保留完成/取消/失败/部分终态")
            try await Task.sleep(nanoseconds: 80_000_000)
            try check(m.items.map(\.state) == terminalStates && m.items.dropFirst().allSatisfy({ $0.bytesReceived == 0 }),
                      "终态历史不排队或重新下载")
            try reject({ _ = try m.artifactURL(m.items[0]) }, "完成历史同样需本App重授权才能读取产物")
            await stop(m)
        }
        do {
            var rootURL: URL!, destination: URL!, grantID: UUID!, itemID: UUID!, prefix: String!, checkpoint: Int64 = 0
            do {
                let (m, g, dest) = try fresh("migrated-range"); rootURL = m.dataRootURL; destination = dest; grantID = g.id
                _ = try m.createJobs(urls: [base + "/range"], destinationID: g.id); itemID = m.items[0].id
                _ = try await wait(m, itemID) { $0.state == .running && $0.bytesReceived > 65536 }
                m.pause(itemID); let paused = try await wait(m, itemID) { $0.state == .paused }
                prefix = paused.partialSHA256; checkpoint = paused.bytesReceived
                try check(prefix != nil && checkpoint > 0 && paused.etag == "\"fixture-v1\"", "暂停持久fsync断点摘要与强ETag")
                await stop(m)
            }
            do { let s = try DownloadStore(root: rootURL); var db = try s.load(); db.destinations[0].requiresReauthorization = true; db.items[0].state = .waitingForNetwork; try s.save(db) }
            let partial = destination.appendingPathComponent(".GaoXiaZai-Staging-\(grantID.uuidString)/\(itemID.uuidString).part")
            let before = try Data(contentsOf: partial)
            let m = DownloadManager(rootURL: rootURL, evidenceDefaults: nil, monitorNetwork: false)
            try check(m.recoveryIssue == nil && m.items[0].state == .waitingForDestination, "迁入任务等本App重授权不读取旧分片")
            try check(m.items[0].bytesReceived == checkpoint && m.items[0].partialSHA256 == prefix && (try Data(contentsOf: partial)) == before, "等待授权保留原分片及持久断点")
            try reject({ _ = try DestinationAccess(m.destinations[0]) }, "旧目录书签不能视为自动转授权")
            let renewed = try m.addDestination(destination)
            try check(renewed.id == grantID && renewed.requiresReauthorization == false, "正常重选同目录复用原授权ID并解除待授权")
            m.resume(itemID); let item = try await wait(m, itemID) { $0.state == .completed }
            let bytes = try Data(contentsOf: m.artifactURL(item))
            try check(bytes.count == 2097152 && item.artifact?.sha256 == downloadDigest(bytes), "重授权后核本地SHA并真正续传完成")
            let (stats, _) = try await URLSession.shared.data(from: URL(string: base + "/stats")!)
            let values = try JSONSerialization.jsonObject(with: stats) as! [String: Any]
            try check((values["ranges"] as! [String: Int])["/range", default: 0] > 0, "HTTP服务实际收到Range请求")
            await stop(m)
        }
        do {
            let (m, g, _) = try fresh("budget"); var settings = m.settings; settings.maxItemBytes = 32768; m.updateSettings(settings)
            _ = try m.createJobs(urls: [base + "/file"], destinationID: g.id)
            let item = try await wait(m, m.items[0].id) { $0.state == .failed }
            try check(item.artifact == nil && item.bytesReceived == 0, "单文件预算在响应体写入前停止")
            await stop(m)
        }
        do {
            let (m, g, _) = try fresh("forbidden"); _ = try m.createJobs(urls: [base + "/forbidden"], destinationID: g.id)
            let item = try await wait(m, m.items[0].id) { $0.state == .failed }
            try check(item.artifact == nil && item.errorCategory == "permanent_http", "403不绕登录限制且不伪报完成")
            await stop(m)
        }
        do {
            let (m, g, _) = try fresh("retry-date"); _ = try m.createJobs(urls: [base + "/retry-date"], destinationID: g.id)
            let item = try await wait(m, m.items[0].id) { $0.state == .failed }
            try check(item.retryAt == nil && item.attempts == 1, "HTTP日期形式Retry-After同样遵守七天等待预算")
            await stop(m)
        }
        do {
            let (m, g, _) = try fresh("cancel"); _ = try m.createJobs(urls: [base + "/slow"], destinationID: g.id)
            let id = m.items[0].id; _ = try await wait(m, id) { $0.bytesReceived > 65536 }
            m.cancel(id); let item = try await wait(m, id) { $0.state == .cancelled }
            try check(item.artifact == nil && item.partialSHA256 != nil, "取消保留可核验分片不生成正式文件")
            m.removePartialFiles(id)
            try check(m.items[0].bytesReceived == 0 && m.items[0].stagingInode == nil, "显式清理仅删除登记自有分片")
            await stop(m)
        }
    }
}
