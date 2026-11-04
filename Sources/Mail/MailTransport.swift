import Foundation
import CoreFoundation

enum TransportSecurity: String, Codable, CaseIterable, Sendable {
    case tls, startTLS
}

struct TransportConnection: Sendable {
    var imapHost: String
    var imapPort: Int = 993
    var imapSecurity: TransportSecurity = .tls
    var smtpHost: String
    var smtpPort: Int = 465
    var smtpSecurity: TransportSecurity = .tls
    var username: String
    var password: String
    var oauthToken: String? = nil
    // Custom CA is used by isolated TLS integration tests. Verification is never disabled.
    var trustedCAFile: String? = nil
}

struct TransportFolder: Codable, Identifiable, Sendable, Hashable {
    var path: String
    var displayName: String
    var flags: [String]
    var delimiter: String?
    var id: String { path }
    var selectable: Bool { !flags.contains { $0.lowercased() == "\\noselect" } }
}

struct TransportAttachment: Codable, Identifiable, Sendable, Hashable {
    var id: String = UUID().uuidString
    var filename: String
    var mimeType: String = "application/octet-stream"
    var data: Data
    var contentID: String? = nil
    var isInline: Bool = false
}

struct TransportMessage: Codable, Identifiable, Sendable {
    var uid: UInt64
    var uidValidity: UInt64? = nil
    var subject: String
    var from: String
    var to: String
    var cc: String = ""
    var replyTo: String? = nil
    var date: Date
    var body: String
    var html: String? = nil
    var attachments: [TransportAttachment] = []
    var isRead: Bool
    var isFlagged: Bool
    var messageID: String? = nil
    var references: String? = nil
    var size: Int = 0
    var bodyLoaded: Bool = false
    var id: String { String(uid) }
}

struct TransportOutgoing: Sendable {
    var from: String
    var fromName: String = ""
    var to: [String]
    var cc: [String] = []
    var bcc: [String] = []
    var subject: String
    var body: String
    var attachments: [TransportAttachment] = []
    var inReplyTo: String? = nil
    var references: String? = nil
}

struct TransportSendResult: Sendable {
    var deliveredToServer: Bool
    var sentCopyWarning: String?
    var acceptedByServer: Bool { deliveredToServer }
}

enum TransportError: LocalizedError {
    case invalid(String)
    case connection(String)
    case authentication
    case certificate
    case server(String)
    case sendUncertain
    case cancelled
    var errorDescription: String? {
        switch self {
        case .invalid(let detail): return detail
        case .connection(let detail): return "连接失败：\(detail)"
        case .authentication: return "邮箱认证失败。请核对邮箱地址及客户端授权码；Gmail 和微软邮箱请重新授权。"
        case .certificate: return "服务器 TLS 证书验证失败。请核对服务器地址与电脑时间。"
        case .server(let detail): return "邮件服务器拒绝了操作：\(detail)"
        case .sendUncertain: return "发送过程中连接中断，服务器可能已经接收邮件。请先检查已发送邮件，再决定是否重试，避免重复发送。"
        case .cancelled: return "操作已取消。"
        }
    }
}

// Network work runs away from the main actor. Each operation owns a native libcurl handle.
// Passwords and OAuth tokens remain in memory; the native wrapper never logs outgoing protocol data.
enum MailTransport {
    static func testConnection(_ connection: TransportConnection) async throws {
        _ = try await listFolders(connection)
        _ = try await run(connection, smtp: true, command: "NOOP")
    }

    static func listFolders(_ connection: TransportConnection) async throws -> [TransportFolder] {
        let data = try await run(connection, command: "LIST \"\" \"*\"")
        return parseFolders(data)
    }

    static func fetchMessages(_ connection: TransportConnection, folder: String = "INBOX", limit: Int = 100) async throws -> [TransportMessage] {
        let search = try await run(connection, folder: folder, command: "UID SEARCH ALL")
        let searchText = String(decoding: search, as: UTF8.self)
        let uids = searchText.components(separatedBy: .newlines).filter { $0.uppercased().hasPrefix("* SEARCH") }
            .flatMap { $0.dropFirst(8).split(separator: " ").compactMap { UInt64($0) } }
        let selected = Array(Set(uids)).sorted().suffix(max(1, min(limit, 500)))
        guard !selected.isEmpty else { return [] }
        let uidSet = selected.map(String.init).joined(separator: ",")
        let command = "UID FETCH \(uidSet) (UID FLAGS INTERNALDATE RFC822.SIZE BODY.PEEK[HEADER.FIELDS (DATE FROM TO CC REPLY-TO SUBJECT MESSAGE-ID REFERENCES IN-REPLY-TO)])"
        let validity = UInt64(capture(#"UIDVALIDITY\s+(\d+)"#, in: searchText) ?? "")
        let result = try await run(connection, folder: folder, expectedUIDValidity: validity, command: command)
        return parseFetch(result, bodyLoaded: false).sorted { $0.uid > $1.uid }
    }

    static func fetchMessage(_ connection: TransportConnection, folder: String = "INBOX", uid: UInt64, expectedUIDValidity: UInt64? = nil) async throws -> TransportMessage {
        guard uid > 0 else { throw TransportError.invalid("邮件标识无效。") }
        let result = try await run(connection, folder: folder, expectedUIDValidity: expectedUIDValidity, command: "UID FETCH \(uid) (UID FLAGS INTERNALDATE RFC822.SIZE BODY.PEEK[])")
        guard let message = parseFetch(result, bodyLoaded: true).first(where: { $0.uid == uid }) else {
            throw TransportError.server("邮件已被移动或删除，请刷新列表。")
        }
        return message
    }

    static func setRead(_ connection: TransportConnection, folder: String, uids: [UInt64], read: Bool, expectedUIDValidity: UInt64? = nil) async throws {
        try await setFlag(connection, folder: folder, uids: uids, flag: "\\Seen", enabled: read, expectedUIDValidity: expectedUIDValidity)
    }

    static func setFlagged(_ connection: TransportConnection, folder: String, uids: [UInt64], flagged: Bool, expectedUIDValidity: UInt64? = nil) async throws {
        try await setFlag(connection, folder: folder, uids: uids, flag: "\\Flagged", enabled: flagged, expectedUIDValidity: expectedUIDValidity)
    }

    private static func setFlag(_ connection: TransportConnection, folder: String, uids: [UInt64], flag: String, enabled: Bool, expectedUIDValidity: UInt64?) async throws {
        let ids = Array(Set(uids.filter { $0 > 0 })).sorted()
        guard !ids.isEmpty else { return }
        _ = try await run(connection, folder: folder, expectedUIDValidity: expectedUIDValidity, command: "UID STORE \(ids.map(String.init).joined(separator: ",")) \(enabled ? "+" : "-")FLAGS.SILENT (\(flag))")
    }

    static func move(_ connection: TransportConnection, folder: String, uid: UInt64, destination: String, expectedUIDValidity: UInt64? = nil) async throws {
        guard uid > 0 else { throw TransportError.invalid("邮件标识无效。") }
        guard folder != destination else { return }
        let capabilities = String(decoding: try await run(connection, command: "CAPABILITY"), as: UTF8.self).uppercased()
        guard capabilities.components(separatedBy: .whitespacesAndNewlines).contains("MOVE") else {
            throw TransportError.server("此服务器不支持安全移动邮件（IMAP MOVE）。请在网页版完成归档或移入垃圾箱。")
        }
        let mailbox = try imapQuoted(destination)
        _ = try await run(connection, folder: folder, expectedUIDValidity: expectedUIDValidity, command: "UID MOVE \(uid) \(mailbox)")
    }

    static func send(_ connection: TransportConnection, message: TransportOutgoing, sentFolder: String? = nil) async throws -> TransportSendResult {
        let recipients = try (message.to + message.cc + message.bcc).map(validatedAddress)
        guard !recipients.isEmpty else { throw TransportError.invalid("请填写至少一位收件人。") }
        let from = try validatedAddress(message.from)
        let mime = try encode(message)
        _ = try await run(connection, smtp: true, command: nil, upload: mime, mailFrom: from, recipients: recipients)
        if let sentFolder, !sentFolder.isEmpty {
            do {
                _ = try await run(connection, folder: sentFolder, command: nil, upload: mime)
            } catch {
                return TransportSendResult(deliveredToServer: true, sentCopyWarning: "服务器已接受邮件，但保存已发送副本失败。请勿重复发送。" + error.localizedDescription)
            }
        }
        return TransportSendResult(deliveredToServer: true, sentCopyWarning: nil)
    }

    private static func run(_ connection: TransportConnection, folder: String? = nil, smtp: Bool = false, expectedUIDValidity: UInt64? = nil,
                            command: String?, upload: Data? = nil, mailFrom: String? = nil,
                            recipients: [String] = []) async throws -> Data {
        try Task.checkCancellation()
        return try await Task.detached(priority: .userInitiated) {
            try execute(connection, folder: folder, smtp: smtp, expectedUIDValidity: expectedUIDValidity, command: command, upload: upload, mailFrom: mailFrom, recipients: recipients)
        }.value
    }

    private static func execute(_ c: TransportConnection, folder: String?, smtp: Bool, expectedUIDValidity: UInt64?, command: String?,
                                upload: Data?, mailFrom: String?, recipients: [String]) throws -> Data {
        let host = (smtp ? c.smtpHost : c.imapHost).trimmingCharacters(in: .whitespacesAndNewlines)
        let port = smtp ? c.smtpPort : c.imapPort
        let security = smtp ? c.smtpSecurity : c.imapSecurity
        guard !host.isEmpty, !host.contains(where: { $0.isWhitespace || "/\\@?#\"".contains($0) }), (1...65535).contains(port) else {
            throw TransportError.invalid("请填写正确的邮件服务器地址和端口，服务器地址不包含协议前缀或路径。")
        }
        guard !c.username.isEmpty, !c.username.contains(where: { $0.isNewline || $0 == "\0" }) else {
            throw TransportError.invalid("请填写正确的登录用户名。")
        }
        let scheme = smtp ? (security == .tls ? "smtps" : "smtp") : (security == .tls ? "imaps" : "imap")
        var url = "\(scheme)://\(host):\(port)/"
        if let folder {
            guard !folder.contains(where: { $0.isNewline || $0 == "\0" }) else { throw TransportError.invalid("邮箱文件夹名称无效。") }
            url += folder.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "INBOX"
            if let expectedUIDValidity { url += ";UIDVALIDITY=\(expectedUIDValidity)" }
        }
        let payload = upload ?? Data()
        // libcurl URL-decodes custom IMAP commands. Preserve literal percent signs in folder names.
        let nativeCommand = (command ?? "").replacingOccurrences(of: "%", with: "%25")
        let response = payload.withUnsafeBytes { bytes in
            gm_mail_request(url, c.username, c.oauthToken == nil ? c.password : "", c.oauthToken ?? "", nativeCommand,
                            bytes.bindMemory(to: UInt8.self).baseAddress, payload.count, upload == nil ? 0 : 1,
                            smtp ? 1 : 0, mailFrom ?? "", recipients.joined(separator: "\n"), c.trustedCAFile ?? "")
        }
        guard let response else { throw TransportError.connection("无法分配网络请求所需的内存。") }
        defer { gm_mail_response_free(response) }
        let status = response.pointee.code
        if status != 0 {
            var safe = response.pointee.message.map { String(cString: $0) } ?? ""
            if !c.password.isEmpty { safe = safe.replacingOccurrences(of: c.password, with: "••••") }
            if let token = c.oauthToken, !token.isEmpty { safe = safe.replacingOccurrences(of: token, with: "••••") }
            safe = String(safe.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400))
            if smtp && upload != nil && response.pointee.uploaded_bytes > 0 && !(400...599).contains(response.pointee.smtp_final_code) { throw TransportError.sendUncertain }
            switch status {
            case 78 where expectedUIDValidity != nil: throw TransportError.server("邮箱文件夹已被重建，原邮件标识失效。请刷新后重新选择邮件。")
            case 67: throw TransportError.authentication
            case 51, 58, 60, 77, 83, 90, 91: throw TransportError.certificate
            case 5, 6: throw TransportError.connection("无法解析服务器地址，请核对设置与网络。")
            case 7: throw TransportError.connection("无法连接服务器，请核对端口、网络或单位的访问限制。")
            case 28: throw TransportError.connection("连接超时，请稍后重试。")
            case 64: throw TransportError.connection("服务器未提供要求的加密连接，请核对 TLS 设置与端口。")
            default: throw TransportError.server(safe.isEmpty ? "操作未成功（代码 \(status)）。" : safe)
            }
        }
        guard let bytes = response.pointee.bytes else { return Data() }
        let result = Data(bytes: bytes, count: response.pointee.length)
        return result
    }

    private static func imapQuoted(_ value: String) throws -> String {
        guard !value.contains(where: { $0.isNewline || $0 == "\0" }) else { throw TransportError.invalid("邮箱文件夹名称无效。") }
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func parseFolders(_ data: Data) -> [TransportFolder] {
        let text = String(decoding: data, as: UTF8.self)
        let pattern = #"(?im)^\* LIST \(([^)]*)\) (NIL|"(?:[^"\\]|\\.)*") ("(?:[^"\\]|\\.)*"|\{\d+\}\r?\n[^\r\n]*|[^\r\n]*)"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let ns = text as NSString
        var result: [TransportFolder] = []
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let flags = ns.substring(with: m.range(at: 1)).split(separator: " ").map(String.init)
            let delimiter = ns.substring(with: m.range(at: 2))
            var path = ns.substring(with: m.range(at: 3))
            if path.first == "{" { path = path.components(separatedBy: .newlines).last ?? path }
            path = unquote(path)
            guard !path.isEmpty else { continue }
            result.append(TransportFolder(path: path, displayName: decodeModifiedUTF7(path), flags: flags,
                                          delimiter: delimiter == "NIL" ? nil : unquote(delimiter)))
        }
        return result
    }

    private static func unquote(_ text: String) -> String {
        guard text.hasPrefix("\""), text.hasSuffix("\"") else { return text }
        return String(text.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
    }

    static func decodeModifiedUTF7(_ value: String) -> String {
        var output = "", rest = value[...]
        while let start = rest.firstIndex(of: "&") {
            output += rest[..<start]
            guard let end = rest[start...].firstIndex(of: "-") else { output += rest[start...]; return output }
            let part = String(rest[rest.index(after: start)..<end])
            if part.isEmpty { output += "&" }
            else {
                var base64 = part.replacingOccurrences(of: ",", with: "/")
                base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
                if let decoded = Data(base64Encoded: base64), let string = String(data: decoded, encoding: .utf16BigEndian) { output += string }
                else { output += rest[start...end] }
            }
            rest = rest[rest.index(after: end)...]
        }
        return output + rest
    }

    static func parseFetch(_ data: Data, bodyLoaded: Bool) -> [TransportMessage] {
        let bytes = [UInt8](data)
        var position = 0, results: [TransportMessage] = []
        let validity = UInt64(capture(#"UIDVALIDITY\s+(\d+)"#, in: String(decoding: data, as: UTF8.self)) ?? "")
        while position < bytes.count {
            guard let marker = findBytes(Array(" FETCH (".utf8), in: bytes, from: position),
                  let brace = bytes[marker...].firstIndex(of: 123) else { break }
            guard let close = bytes[brace...].firstIndex(of: 125), close - brace < 20,
                  let count = Int(String(decoding: bytes[(brace + 1)..<close], as: UTF8.self)) else { position = marker + 8; continue }
            var begin = close + 1
            if begin < bytes.count && bytes[begin] == 13 { begin += 1 }
            if begin < bytes.count && bytes[begin] == 10 { begin += 1 }
            guard count >= 0, begin + count <= bytes.count else { break }
            var metadata = String(decoding: bytes[marker..<brace], as: UTF8.self)
            position = begin + count
            let suffixEnd = bytes[position...].firstIndex(of: 10) ?? bytes.count
            metadata += " " + String(decoding: bytes[position..<suffixEnd], as: UTF8.self)
            guard let uidText = capture(#"\bUID\s+(\d+)"#, in: metadata), let uid = UInt64(uidText) else { continue }
            let raw = Data(bytes[begin..<(begin + count)])
            let headers = parseHeaders(raw).headers
            let mime = bodyLoaded ? parseMIME(raw) : MIMEContent()
            let flags = capture(#"FLAGS\s+\(([^)]*)\)"#, in: metadata) ?? ""
            let date = parseDate(headers["date"] ?? "") ?? parseDate(capture(#"INTERNALDATE\s+"([^"]+)""#, in: metadata) ?? "") ?? Date(timeIntervalSince1970: 0)
            results.append(TransportMessage(uid: uid, uidValidity: validity, subject: decodeHeader(headers["subject"] ?? "（无主题）"),
                from: decodeHeader(headers["from"] ?? ""), to: decodeHeader(headers["to"] ?? ""), cc: decodeHeader(headers["cc"] ?? ""), replyTo: headers["reply-to"].map(decodeHeader),
                date: date, body: mime.text, html: mime.html, attachments: mime.attachments,
                isRead: flags.lowercased().contains("\\seen"), isFlagged: flags.lowercased().contains("\\flagged"),
                messageID: headers["message-id"], references: headers["references"],
                size: Int(capture(#"RFC822\.SIZE\s+(\d+)"#, in: metadata) ?? "0") ?? 0, bodyLoaded: bodyLoaded))
        }
        return results
    }

    private static func findBytes(_ needle: [UInt8], in haystack: [UInt8], from: Int) -> Int? {
        guard !needle.isEmpty, from >= 0, from <= haystack.count - needle.count else { return nil }
        for i in from...(haystack.count - needle.count) where haystack[i] == needle[0] {
            if haystack[i..<(i + needle.count)].elementsEqual(needle) { return i }
        }
        return nil
    }

    private static func capture(_ pattern: String, in text: String) -> String? {
        guard let r = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = r.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), m.numberOfRanges > 1,
              let range = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    static func parseDate(_ text: String) -> Date? {
        let cleaned = text.replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for format in ["EEE, d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z", "d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm Z", "d-MMM-yyyy HH:mm:ss Z", "EEE, d MMM yy HH:mm:ss Z"] {
            f.dateFormat = format
            if let date = f.date(from: cleaned) { return date }
        }
        return nil
    }

    struct MIMEContent {
        var text = ""
        var html: String? = nil
        var attachments: [TransportAttachment] = []
    }

    static func parseHeaders(_ data: Data) -> (headers: [String: String], body: Data) {
        let bytes = [UInt8](data)
        let split = findBytes([13, 10, 13, 10], in: bytes, from: 0)
        let lfSplit = split == nil ? findBytes([10, 10], in: bytes, from: 0) : nil
        let end = split ?? lfSplit ?? bytes.count
        let bodyStart = min(bytes.count, end + (split != nil ? 4 : lfSplit != nil ? 2 : 0))
        let raw = String(decoding: bytes[..<end], as: UTF8.self)
        let lines = raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var headers: [String: String] = [:], key: String?
        for line in lines {
            if (line.hasPrefix(" ") || line.hasPrefix("\t")), let current = key {
                headers[current, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                let name = line[..<colon].lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if let old = headers[name] { headers[name] = old + ", " + value } else { headers[name] = value }
                key = name
            } else { key = nil }
        }
        return (headers, Data(bytes[bodyStart...]))
    }

    static func parseMIME(_ data: Data, depth: Int = 0) -> MIMEContent {
        guard depth < 20 else { return MIMEContent(text: "邮件嵌套层数过多，请在网页版查看。") }
        let parsed = parseHeaders(data), headers = parsed.headers
        let typeValue = headers["content-type"] ?? "text/plain; charset=utf-8"
        let mimeType = typeValue.components(separatedBy: ";").first!.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if mimeType.hasPrefix("multipart/"), let boundary = parameter("boundary", in: typeValue) {
            let parts = splitMultipart(parsed.body, boundary: boundary)
            var result = MIMEContent()
            for part in parts {
                let child = parseMIME(part, depth: depth + 1)
                if !child.text.isEmpty {
                    if mimeType == "multipart/alternative" { if result.text.isEmpty { result.text = child.text } }
                    else { result.text += (result.text.isEmpty ? "" : "\n\n") + child.text }
                }
                if let html = child.html { result.html = (result.html ?? "") + html }
                result.attachments.append(contentsOf: child.attachments)
            }
            return result
        }
        let decoded: Data
        switch (headers["content-transfer-encoding"] ?? "").lowercased() {
        case "base64": decoded = Data(base64Encoded: parsed.body, options: .ignoreUnknownCharacters) ?? parsed.body
        case "quoted-printable": decoded = decodeQuotedPrintable(parsed.body)
        default: decoded = parsed.body
        }
        let disposition = headers["content-disposition"] ?? ""
        let filename = parameter("filename", in: disposition) ?? parameter("name", in: typeValue)
        let isAttachment = disposition.lowercased().hasPrefix("attachment") || filename != nil || (!mimeType.hasPrefix("text/") && mimeType != "message/delivery-status")
        if isAttachment {
            let name = sanitizeFilename(decodeHeader(filename ?? (mimeType == "message/rfc822" ? "附带邮件.eml" : "附件")))
            return MIMEContent(attachments: [TransportAttachment(filename: name, mimeType: mimeType, data: decoded,
                contentID: headers["content-id"]?.trimmingCharacters(in: CharacterSet(charactersIn: "<>")),
                isInline: disposition.lowercased().hasPrefix("inline"))])
        }
        let string = decodeText(decoded, charset: parameter("charset", in: typeValue) ?? "utf-8")
        if mimeType == "text/html" { return MIMEContent(html: string) }
        if mimeType == "text/plain" { return MIMEContent(text: string) }
        return MIMEContent()
    }

    private static func splitMultipart(_ data: Data, boundary: String) -> [Data] {
        let bytes = [UInt8](data), marker = Array(("--" + boundary).utf8)
        var positions: [(start: Int, end: Int, closing: Bool)] = [], scan = 0
        while let found = findBytes(marker, in: bytes, from: scan) {
            let after = found + marker.count
            let atLineStart = found == 0 || bytes[found - 1] == 10
            let closing = after + 1 < bytes.count && bytes[after] == 45 && bytes[after + 1] == 45
            let validEnd = after == bytes.count || closing || bytes[after] == 13 || bytes[after] == 10 || bytes[after] == 32 || bytes[after] == 9
            if atLineStart && validEnd {
                let newline = bytes[after...].firstIndex(of: 10).map { $0 + 1 } ?? bytes.count
                positions.append((found, newline, closing))
                if closing { break }
            }
            scan = after
        }
        var parts: [Data] = []
        for (i, item) in positions.enumerated() where !item.closing {
            guard i + 1 < positions.count else { continue }
            var end = positions[i + 1].start
            if end > item.end && bytes[end - 1] == 10 { end -= 1 }
            if end > item.end && bytes[end - 1] == 13 { end -= 1 }
            if end >= item.end { parts.append(Data(bytes[item.end..<end])) }
        }
        return parts
    }

    static func parameter(_ name: String, in value: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        // RFC 2231 continuation and extended UTF-8 filenames.
        var chunks: [String] = []
        var extended = false
        for index in 0..<30 {
            let pattern = "(?:^|;)\\s*" + escaped + "\\*" + String(index) + "(\\*)?\\s*=\\s*(?:\"((?:[^\"\\\\]|\\\\.)*)\"|([^;]*))"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { break }
            let ns = value as NSString
            extended = extended || match.range(at: 1).location != NSNotFound
            let range = match.range(at: 2).location != NSNotFound ? match.range(at: 2) : match.range(at: 3)
            chunks.append(ns.substring(with: range).trimmingCharacters(in: .whitespaces))
        }
        if !chunks.isEmpty { return extended ? decodeExtended(chunks.joined()) : chunks.joined() }
        if let ext = capture("(?:^|;)\\s*" + escaped + "\\*\\s*=\\s*([^;]*)", in: value) { return decodeExtended(unquote(ext.trimmingCharacters(in: .whitespaces))) }
        if let quoted = capture("(?:^|;)\\s*" + escaped + "\\s*=\\s*\"((?:[^\"\\\\]|\\\\.)*)\"", in: value) {
            return quoted.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
        }
        return capture("(?:^|;)\\s*" + escaped + "\\s*=\\s*([^;]*)", in: value)?.trimmingCharacters(in: .whitespaces)
    }

    private static func decodeExtended(_ value: String) -> String {
        let parts = value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
        let charset = parts.count == 3 ? String(parts[0]) : "utf-8"
        let encoded = parts.count == 3 ? String(parts[2]) : value
        let bytes = Array(encoded.utf8)
        var output = Data(), i = 0
        while i < bytes.count {
            if bytes[i] == 37, i + 2 < bytes.count, let byte = UInt8(String(decoding: bytes[(i + 1)...(i + 2)], as: UTF8.self), radix: 16) {
                output.append(byte); i += 3
            } else { output.append(bytes[i]); i += 1 }
        }
        return decodeText(output, charset: charset)
    }

    static func decodeHeader(_ value: String) -> String {
        let merged = value.replacingOccurrences(of: #"(\?=)\s+(=\?)"#, with: "$1$2", options: .regularExpression)
        let regex = try! NSRegularExpression(pattern: #"=\?([^?]+)\?([bBqQ])\?([^?]*)\?="#)
        let ns = merged as NSString
        var result = merged
        for match in regex.matches(in: merged, range: NSRange(location: 0, length: ns.length)).reversed() {
            let charset = ns.substring(with: match.range(at: 1)), encoding = ns.substring(with: match.range(at: 2)).lowercased()
            let encoded = ns.substring(with: match.range(at: 3))
            let bytes = encoding == "b" ? Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) : decodeQuotedPrintable(Data(encoded.replacingOccurrences(of: "_", with: " ").utf8))
            if let bytes, let range = Range(match.range, in: result) { result.replaceSubrange(range, with: decodeText(bytes, charset: charset)) }
        }
        return result
    }

    static func decodeText(_ data: Data, charset: String) -> String {
        let cf = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
        if cf != kCFStringEncodingInvalidId {
            let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
            if let string = String(data: data, encoding: encoding) { return string }
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
    }

    static func decodeQuotedPrintable(_ data: Data) -> Data {
        let b = [UInt8](data)
        var result = Data(), i = 0
        while i < b.count {
            if b[i] == 61 {
                if i + 1 < b.count && b[i + 1] == 10 { i += 2; continue }
                if i + 2 < b.count && b[i + 1] == 13 && b[i + 2] == 10 { i += 3; continue }
                if i + 2 < b.count, let byte = UInt8(String(decoding: b[(i + 1)...(i + 2)], as: UTF8.self), radix: 16) { result.append(byte); i += 3; continue }
            }
            result.append(b[i]); i += 1
        }
        return result
    }

    static func sanitizeFilename(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\\", with: "_")
            .components(separatedBy: .controlCharacters).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "附件" : String(cleaned.prefix(180))
    }

    static func validatedAddress(_ input: String) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.contains(where: { $0.isNewline || $0 == "\0" }), !value.contains(","), !value.contains(";") else { throw TransportError.invalid("邮箱地址格式不正确：请分别填写每位收件人。") }
        let address: String
        if let left = value.lastIndex(of: "<"), value.hasSuffix(">") { address = String(value[value.index(after: left)..<value.index(before: value.endIndex)]) }
        else { address = value }
        guard address.count <= 254, address.unicodeScalars.allSatisfy({ $0.isASCII }),
              address.range(of: #"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$"#, options: .regularExpression) != nil else {
            throw TransportError.invalid("邮箱地址格式不正确。请填写完整地址，例如 name@example.com。")
        }
        return address
    }

    static func encode(_ message: TransportOutgoing) throws -> Data {
        let from = try validatedAddress(message.from)
        let to = try message.to.map(validatedAddress), cc = try message.cc.map(validatedAddress)
        _ = try message.bcc.map(validatedAddress)
        for header in [message.subject, message.fromName, message.inReplyTo ?? "", message.references ?? ""] {
            guard !header.contains(where: { $0.isNewline || $0 == "\0" }) else { throw TransportError.invalid("邮件标题或回复信息包含无效换行。") }
        }
        let boundary = "GaoYouJian-" + UUID().uuidString
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        var lines = ["Date: \(dateFormatter.string(from: Date()))", "Message-ID: <\(UUID().uuidString)@\(from.split(separator: "@").last!)>",
                     "From: \(message.fromName.isEmpty ? from : encodedWords(message.fromName) + " <" + from + ">")"]
        lines.append("To: " + (to.isEmpty ? "undisclosed-recipients:;" : to.joined(separator: ",\r\n ")))
        if !cc.isEmpty { lines.append("Cc: " + cc.joined(separator: ",\r\n ")) }
        // Bcc belongs only to the SMTP envelope and must never be serialized into the message headers.
        lines += ["Subject: " + encodedWords(message.subject), "MIME-Version: 1.0", "X-Mailer: GaoMenHu-Mail"]
        if let reply = message.inReplyTo, !reply.isEmpty { lines.append("In-Reply-To: " + reply) }
        if let references = message.references, !references.isEmpty { lines.append("References: " + references) }
        if message.attachments.isEmpty {
            lines += ["Content-Type: text/plain; charset=utf-8", "Content-Transfer-Encoding: base64", "", wrappedBase64(Data(normalizedNewlines(message.body).utf8))]
        } else {
            lines += ["Content-Type: multipart/mixed; boundary=\"\(boundary)\"", "", "--\(boundary)",
                      "Content-Type: text/plain; charset=utf-8", "Content-Transfer-Encoding: base64", "", wrappedBase64(Data(normalizedNewlines(message.body).utf8))]
            for attachment in message.attachments {
                let filename = sanitizeFilename(attachment.filename)
                let mime = attachment.mimeType.range(of: #"^[a-zA-Z0-9.+-]+/[a-zA-Z0-9.+-]+$"#, options: .regularExpression) != nil ? attachment.mimeType : "application/octet-stream"
                lines += ["--\(boundary)", "Content-Type: \(mime)", "Content-Disposition: attachment; filename=\"attachment\";\r\n " + encodedFilename(filename),
                          "Content-Transfer-Encoding: base64", "", wrappedBase64(attachment.data)]
            }
            lines.append("--\(boundary)--")
        }
        return Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }

    private static func encodedWords(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        var chunks: [String] = [], current = ""
        for scalar in text.unicodeScalars {
            if current.utf8.count + String(scalar).utf8.count > 42 { chunks.append(current); current = "" }
            current.unicodeScalars.append(scalar)
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks.map { "=?UTF-8?B?" + Data($0.utf8).base64EncodedString() + "?=" }.joined(separator: "\r\n ")
    }

    private static func encodedFilename(_ filename: String) -> String {
        var chunks: [String] = [], current = ""
        for byte in filename.utf8 {
            let token: String
            if (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) { token = String(UnicodeScalar(byte)) }
            else { token = String(format: "%%%02X", byte) }
            if current.count + token.count > 48 { chunks.append(current); current = "" }
            current += token
        }
        if !current.isEmpty { chunks.append(current) }
        if chunks.count < 2 { return "filename*=UTF-8''" + (chunks.first ?? "attachment") }
        return chunks.enumerated().map { "filename*\($0.offset)*=" + ($0.offset == 0 ? "UTF-8''" : "") + $0.element }.joined(separator: ";\r\n ")
    }

    private static func normalizedNewlines(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
    }

    private static func wrappedBase64(_ data: Data) -> String {
        data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
    }
}
