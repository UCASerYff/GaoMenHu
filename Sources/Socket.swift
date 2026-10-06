import Foundation
import Darwin

let nativeHostName = "cn.mendao.bridge"
let socketPath = NSHomeDirectory() + "/Library/Application Support/MenDao/bridge.sock"

func socketAddress(_ path: String) -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let bytes = Array(path.utf8) + [0]
    withUnsafeMutableBytes(of: &address.sun_path) { target in
        for (i, byte) in bytes.prefix(target.count).enumerated() { target[i] = byte }
    }
    return address
}

func readExactly(_ fd: Int32, count: Int) -> Data? {
    guard count >= 0, count <= 1024 * 1024 else { return nil }
    var buffer = [UInt8](repeating: 0, count: count)
    var offset = 0
    while offset < count {
        let amount = buffer.withUnsafeMutableBytes { bytes in Darwin.read(fd, bytes.baseAddress!.advanced(by: offset), count - offset) }
        if amount < 0 && errno == EINTR { continue }
        guard amount > 0 else { return nil }
        offset += amount
    }
    return Data(buffer)
}

@discardableResult func writeExactly(_ fd: Int32, data: Data) -> Bool {
    var offset = 0
    while offset < data.count {
        let amount = data.withUnsafeBytes { bytes in Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), data.count - offset) }
        if amount < 0 && errno == EINTR { continue }
        guard amount > 0 else { return false }
        offset += amount
    }
    return true
}

func readFrame(_ fd: Int32) -> [String: Any]? {
    guard let prefix = readExactly(fd, count: 4) else { return nil }
    let size = prefix.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
    guard size > 0, size <= 1024 * 1024, let data = readExactly(fd, count: Int(size)),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return object
}

@discardableResult func writeFrame(_ fd: Int32, object: [String: Any]) -> Bool {
    guard let data = try? JSONSerialization.data(withJSONObject: object), data.count <= 1024 * 1024 else { return false }
    var size = UInt32(data.count).littleEndian
    return withUnsafeBytes(of: &size) { writeExactly(fd, data: Data($0)) } && writeExactly(fd, data: data)
}

func processPath(_ pid: Int32) -> String? {
    var bytes = [CChar](repeating: 0, count: 4096)
    let count = proc_pidpath(pid, &bytes, UInt32(bytes.count))
    guard count > 0 else { return nil }
    return String(cString: bytes)
}

func exchangeWithApp(_ request: [String: Any]) -> [String: Any] {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return ["ok": false, "error": "搞门户未运行。"] }
    defer { close(fd) }
    var timeout = timeval(tv_sec: 8, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var noSig: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSig, socklen_t(MemoryLayout<Int32>.size))
    var address = socketAddress(socketPath)
    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0, writeFrame(fd, object: request), let response = readFrame(fd) else {
        return ["ok": false, "error": "请先打开搞门户 App。"]
    }
    return response
}
