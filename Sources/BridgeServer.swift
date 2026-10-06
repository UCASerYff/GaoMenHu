import Foundation
import Darwin

final class BridgeServer {
    private var fd: Int32 = -1
    private let queue = DispatchQueue(label: "cn.mendao.socket", qos: .utility)
    var handler: (([String: Any]) -> [String: Any])?
    let expectedHostPath: String
    init(expectedHostPath: String) { self.expectedHostPath = expectedHostPath }
    func start() throws {
        let directory = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard socketPath.utf8.count < 104 else { throw AppError.message("用户目录过长，无法连接浏览器。") }
        unlink(socketPath)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AppError.message("浏览器连接服务启动失败。") }
        var address = socketAddress(socketPath)
        let status = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard status == 0, chmod(socketPath, 0o600) == 0, listen(fd, 12) == 0 else {
            close(fd); fd = -1; throw AppError.message("浏览器连接服务启动失败。")
        }
        let listener = fd
        queue.async { [weak self] in
            while self != nil {
                let client = accept(listener, nil, nil)
                guard client >= 0 else { break }
                defer { close(client) }
                var timeout = timeval(tv_sec: 5, tv_usec: 0)
                setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                var noSig: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSig, socklen_t(MemoryLayout<Int32>.size))
                var uid: uid_t = 0; var gid: gid_t = 0
                guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { continue }
                var pid: Int32 = 0; var size = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(client, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0,
                      let path = processPath(pid), path == self?.expectedHostPath,
                      let request = readFrame(client) else { continue }
                var response: [String: Any] = ["ok": false]
                DispatchQueue.main.sync { response = self?.handler?(request) ?? ["ok": false] }
                writeFrame(client, object: response)
            }
        }
    }
    func stop() {
        if fd >= 0 { shutdown(fd, SHUT_RDWR); close(fd); fd = -1; unlink(socketPath) }
    }
}

struct BrowserClient {
    var id: String
    var browser: String
    var label: String
    var lastSeen: Date
}

struct LaunchRequest {
    var id: String
    var browser: String
    var profileID: String?
    var siteID: String
    var accountID: String?
    var url: String
    var allowed: Set<String>
    var expires: Date
    var claimedProfile: String?
    var tabID: Int?
    var filled: Bool = false
    var createdAt: Date = Date()
}
