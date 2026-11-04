import Foundation
import Darwin

final class StagingBudget {
    private let lock = NSLock()
    private var used: Int64
    private var limit: Int64
    init(used: Int64, limit: Int64) { self.used = used; self.limit = limit }
    func updateLimit(_ value: Int64) { lock.lock(); limit = value; lock.unlock() }
    func consume(_ count: Int64) throws { lock.lock(); defer { lock.unlock() }; guard count >= 0, used <= limit - count else { throw DownloadError.message("总暂存空间预算已用尽。") }; used += count }
    func release(_ count: Int64) { lock.lock(); used = max(0, used - max(0,count)); lock.unlock() }
}
final class NetworkRateLimit: @unchecked Sendable {
    private let lock = NSLock()
    private var limit: Int64 = 0
    private var finish: TimeInterval = 0
    func update(_ bytesPerSecond: Int64) { lock.lock(); limit = max(0,bytesPerSecond); finish = ProcessInfo.processInfo.systemUptime; lock.unlock() }
    func delay(for bytes: Int) -> TimeInterval {
        lock.lock(); defer { lock.unlock() }; guard limit > 0 else { return 0 }
        let now = ProcessInfo.processInfo.systemUptime
        finish = max(now,finish) + Double(bytes)/Double(limit)
        return max(0,finish-now)
    }
}
enum TransferFailure {
    case restart(String)
    case transient(String, Date?)
    case network(String)
    case destination(String)
    case permanent(String)
    var errorCategory: String {
        switch self {
        case .restart: return "resource_changed"
        case .transient: return "server_retry"
        case .network: return "network_unavailable"
        case .destination: return "destination_unavailable"
        case .permanent: return "permanent_http"
        }
    }
}
enum TransferEvent {
    case response(expected: Int64?, etag: String?, modified: String?, name: String?)
    case progress(bytes: Int64, speed: Double)
    case ended(bytes: Int64, failure: TransferFailure?)
}

final class HTTPTransfer: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    let itemID: UUID
    let access: DestinationAccess
    let stageFD: Int32
    let fileFD: Int32
    private let grant: DestinationGrant
    private let offset: Int64
    private let source: URL
    private let validator: String?
    private let previousExpected: Int64?
    private let itemLimit: Int64
    private let rateLimit: NetworkRateLimit
    private let budget: StagingBudget
    private let event: (TransferEvent) -> Void
    private let writeData: (Data,Int32) throws -> Void
    private let operationQueue: OperationQueue
    private var session: URLSession!
    private var task: URLSessionDataTask?
    private var failure: TransferFailure?
    private var expectedTotal: Int64?
    private var expectedBody: Int64?
    private var receivedBody: Int64 = 0
    private var bytes: Int64
    private var redirects = 0
    private var startTime = ProcessInfo.processInfo.systemUptime
    private var lastProgress = ProcessInfo.processInfo.systemUptime
    private var lastProgressBytes: Int64
    private var cancelled = false
    private let cancelLock = NSLock()
    init(item: DownloadItem, grant: DestinationGrant, access: DestinationAccess, stageFD: Int32, fileFD: Int32, settings: DownloadSettings, budget: StagingBudget, rateLimit: NetworkRateLimit, writeData: @escaping (Data,Int32) throws -> Void = { try writeAll($0,to:$1) }, event: @escaping (TransferEvent) -> Void) throws {
        itemID = item.id; self.grant = grant; self.access = access; self.stageFD = stageFD; self.fileFD = fileFD
        offset = item.bytesReceived; bytes = item.bytesReceived; lastProgressBytes = item.bytesReceived
        source = try validatedDownloadURL(item.sourceURL); validator = item.etag; previousExpected = item.expectedBytes; itemLimit = settings.maxItemBytes; self.rateLimit = rateLimit; self.budget = budget; self.writeData = writeData; self.event = event
        operationQueue = OperationQueue(); operationQueue.maxConcurrentOperationCount = 1; operationQueue.name = "GaoMenHu.Downloads.HTTP.\(item.id)"
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false; configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData; configuration.httpMaximumConnectionsPerHost = 1
        configuration.timeoutIntervalForRequest = 45; configuration.timeoutIntervalForResource = 24 * 60 * 60
        configuration.httpAdditionalHeaders = ["Accept-Encoding":"identity", "User-Agent":"GaoMenHu/" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.17")]
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: operationQueue)
        var request = URLRequest(url: source); request.httpMethod = "GET"
        if offset > 0, let validator { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range"); request.setValue(validator, forHTTPHeaderField: "If-Range") }
        task = session.dataTask(with: request)
    }
    func start() { startTime = ProcessInfo.processInfo.systemUptime; task?.resume() }
    func cancel() { cancelLock.lock(); cancelled = true; cancelLock.unlock(); task?.cancel() }
    private var isCancelled: Bool { cancelLock.lock(); defer { cancelLock.unlock() }; return cancelled }
    deinit { close(fileFD); close(stageFD) }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        redirects += 1
        guard redirects <= 5, let u = request.url, (try? validatedDownloadURL(u.absoluteString)) != nil, !(source.scheme == "https" && u.scheme == "http") else { failure = .permanent("重定向过多、目标无效或 HTTPS 被降级。"); completionHandler(nil); return }
        var safe = request; safe.setValue(nil, forHTTPHeaderField: "Authorization"); safe.setValue(nil, forHTTPHeaderField: "Cookie"); safe.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        completionHandler(safe)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Trust evaluation is performed by the system; credentials are never imported.
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust { completionHandler(.performDefaultHandling,nil) } else { completionHandler(.rejectProtectionSpace,nil) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else { failure = .permanent("收到非 HTTP 响应。"); completionHandler(.cancel); return }
        let status = response.statusCode
        guard status == 200 || status == 206 else {
            if status == 416 && offset > 0 { failure = .restart("服务器拒绝当前断点，已安全从零重下。") }
            else if status == 429 || (500...599).contains(status) {
                let rawRetry = response.value(forHTTPHeaderField:"Retry-After")
                let retryDate = retryAfter(rawRetry)
                let invalidNumber = rawRetry.flatMap(Double.init).map { !$0.isFinite || $0 > 7 * 86400 } ?? false
                if invalidNumber || (retryDate?.timeIntervalSinceNow ?? 0) > 7 * 86400 {
                    failure = .permanent("服务器要求等待超过本版本 7 天重试预算，或提供非有限等待值；已停止，不会提前重试。")
                } else { failure = .transient("服务器暂时不可用（HTTP \(status)）。", retryDate) }
            }
            else if status == 401 || status == 403 { failure = .permanent("服务器拒绝访问（HTTP \(status)）。本应用不读取登录凭据或绕过访问限制。") }
            else if status == 404 { failure = .permanent("下载文件不存在（HTTP 404）。") }
            else { failure = .permanent("服务器返回不支持的 HTTP 状态 \(status)。") }
            completionHandler(.cancel); return
        }
        let encoding = response.value(forHTTPHeaderField: "Content-Encoding")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "identity"
        guard encoding == "identity" || encoding.isEmpty else { failure = .permanent("服务器发送压缩内容；为防止透明解压导致长度和断点错误，本版本拒绝该响应。请使用原始文件直链。"); completionHandler(.cancel); return }
        let etagValue = response.value(forHTTPHeaderField: "ETag")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let strong = strongDownloadETag(etagValue)
        let contentLength: Int64?
        if let raw = response.value(forHTTPHeaderField: "Content-Length") {
            guard let n = Int64(raw), n >= 0 else { failure = .permanent("服务器提供无效 Content-Length。"); completionHandler(.cancel); return }; contentLength = n
        } else { contentLength = response.expectedContentLength >= 0 ? response.expectedContentLength : nil }
        if offset > 0 {
            guard status == 206 else { failure = .restart("服务器忽略 Range，已安全从零重下。"); completionHandler(.cancel); return }
            guard let validator, strong == validator else { failure = .restart("资源 ETag 已改变或缺失，已安全从零重下。"); completionHandler(.cancel); return }
            guard let raw = response.value(forHTTPHeaderField: "Content-Range"), let range = parseContentRange(raw), range.start == offset, range.end >= range.start, range.total > range.end, range.end == range.total - 1, previousExpected == nil || range.total == previousExpected, contentLength == nil || contentLength == range.end - range.start + 1 else { failure = .restart("服务器返回错误 Content-Range，已安全从零重下。"); completionHandler(.cancel); return }
            expectedTotal = range.total; expectedBody = range.end - range.start + 1
        } else {
            guard status == 200 else { failure = .permanent("未请求断点却收到部分响应，已拒绝不完整文件。"); completionHandler(.cancel); return }
            expectedTotal = contentLength; expectedBody = contentLength
        }
        if let expectedTotal, expectedTotal > itemLimit { failure = .permanent("响应超过单文件大小预算。"); completionHandler(.cancel); return }
        var name: String?
        if let disposition = response.value(forHTTPHeaderField: "Content-Disposition"), disposition.utf8.count < 8192 {
            for field in disposition.split(separator: ";").dropFirst() {
                let f = field.trimmingCharacters(in: .whitespaces)
                if f.lowercased().hasPrefix("filename*=utf-8''") { name = String(f.dropFirst(17)).removingPercentEncoding; break }
                if f.lowercased().hasPrefix("filename=") { name = String(f.dropFirst(9)).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            }
        }
        event(.response(expected: expectedTotal, etag: strong, modified: response.value(forHTTPHeaderField: "Last-Modified"), name: name.map(safeDownloadName)))
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil, !isCancelled else { dataTask.cancel(); return }
        do {
            guard Int64(data.count) <= itemLimit - bytes else { throw DownloadError.message("实际响应超过单文件大小预算。") }
            if let expectedBody { guard receivedBody <= expectedBody - Int64(data.count) else { throw DownloadError.message("实际响应超过服务器声明长度。") } }
            let delay = rateLimit.delay(for:data.count)
            if delay > 0.001 {
                // Suspend the actual task while this one bounded delegate chunk waits for its
                // shared byte budget. Delay before writing also covers the final queued chunk.
                dataTask.suspend()
                let deadline = ProcessInfo.processInfo.systemUptime + delay
                while !isCancelled && ProcessInfo.processInfo.systemUptime < deadline {
                    Thread.sleep(forTimeInterval:max(0,min(0.05,deadline-ProcessInfo.processInfo.systemUptime)))
                }
                if isCancelled { dataTask.cancel(); return }
                dataTask.resume()
            }
            try access.validate(grant)
            var space = statfs(); guard fstatfs(fileFD, &space) == 0, Int64(space.f_bavail) * Int64(space.f_bsize) > Int64(data.count) + 1_048_576 else { throw DownloadError.message("目标卷可用空间不足，已安全停止。") }
            try budget.consume(Int64(data.count))
            do { try writeData(data,fileFD) } catch { budget.release(Int64(data.count)); _ = ftruncate(fileFD,off_t(bytes)); _ = lseek(fileFD,off_t(bytes),SEEK_SET); throw error }
            bytes += Int64(data.count); receivedBody += Int64(data.count)
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastProgress >= 0.25 { event(.progress(bytes: bytes, speed: Double(bytes - lastProgressBytes) / max(0.001,now-lastProgress))); lastProgress = now; lastProgressBytes = bytes }

        } catch { failure = .destination(error.localizedDescription); dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if fsync(fileFD) != 0, failure == nil { failure = .destination("同步目标卷失败（可能磁盘已满或被卸载）。") }
        if failure == nil && !isCancelled {
            if let error = error as NSError? {
                if error.domain == NSURLErrorDomain && [-1009,-1005,-1004,-1001,-1003].contains(error.code) { failure = .network("网络不可用或连接中断，保留断点等待重试。") }
                else if error.domain == NSURLErrorDomain && (-1206 ... -1200).contains(error.code) { failure = .permanent("TLS 证书验证失败；未绕过系统证书检查。") }
                else { failure = .permanent("网络传输失败（系统错误 \(error.code)）。") }
            } else if let expectedBody, receivedBody != expectedBody { failure = .transient("响应被截断，实际长度与服务器声明不符。",nil) }
            else if let expectedTotal, bytes != expectedTotal { failure = .transient("响应未覆盖完整资源。",nil) }
        }
        event(.ended(bytes: bytes, failure: failure)); session.finishTasksAndInvalidate(); self.task = nil
    }
}
private func parseContentRange(_ value: String) -> (start: Int64, end: Int64, total: Int64)? {
    guard value.hasPrefix("bytes ") else { return nil }
    let halves = value.dropFirst(6).split(separator:"/",omittingEmptySubsequences:false)
    guard halves.count == 2, let total = Int64(halves[1]), total > 0 else { return nil }
    let bounds = halves[0].split(separator:"-",omittingEmptySubsequences:false)
    guard bounds.count == 2, let first = Int64(bounds[0]), let last = Int64(bounds[1]), first >= 0, last >= first else { return nil }
    return (first,last,total)
}
private func retryAfter(_ raw: String?) -> Date? {
    guard let raw else { return nil }
    if let seconds = TimeInterval(raw), seconds.isFinite, seconds >= 0 { return Date().addingTimeInterval(seconds) }
    let formatter = DateFormatter(); formatter.locale = Locale(identifier:"en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT:0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
    return formatter.date(from:raw).map { max(Date(), $0) }
}
