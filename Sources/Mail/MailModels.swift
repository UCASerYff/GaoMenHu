import Foundation

struct MailIdentity: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var symbol: String
    var color: String
    static let defaults = [MailIdentity(name: "学校", symbol: "graduationcap.fill", color: "6366F1"), MailIdentity(name: "工作", symbol: "briefcase.fill", color: "14877D"), MailIdentity(name: "生活", symbol: "house.fill", color: "DA8C48")]
}

enum MailProvider: String, Codable, CaseIterable, Identifiable {
    case custom = "其他 / 企业 / 学校", qq = "QQ 邮箱", netease = "163 邮箱", vip163 = "VIP 163", netease126 = "126 邮箱", yeah = "yeah.net", outlook = "Outlook / Microsoft 365", gmail = "Gmail", icloud = "iCloud Mail", yahoo = "Yahoo Mail", ali = "阿里企业邮箱", tencent = "腾讯企业邮箱", feishu = "飞书邮箱", zoho = "Zoho Mail", fastmail = "Fastmail", mailcom = "mail.com"
    var id: String { rawValue }
    var servers: (String, Int, String, Int) {
        switch self {
        case .qq: return ("imap.qq.com",993,"smtp.qq.com",465)
        case .netease: return ("imap.163.com",993,"smtp.163.com",465)
        case .vip163: return ("imap.vip.163.com",993,"smtp.vip.163.com",465)
        case .netease126: return ("imap.126.com",993,"smtp.126.com",465)
        case .yeah: return ("imap.yeah.net",993,"smtp.yeah.net",465)
        case .outlook: return ("outlook.office365.com",993,"smtp-mail.outlook.com",587)
        case .gmail: return ("imap.gmail.com",993,"smtp.gmail.com",465)
        case .icloud: return ("imap.mail.me.com",993,"smtp.mail.me.com",587)
        case .yahoo: return ("imap.mail.yahoo.com",993,"smtp.mail.yahoo.com",465)
        case .ali: return ("imap.qiye.aliyun.com",993,"smtp.qiye.aliyun.com",465)
        case .tencent: return ("imap.exmail.qq.com",993,"smtp.exmail.qq.com",465)
        case .feishu: return ("imap.feishu.cn",993,"smtp.feishu.cn",465)
        case .zoho: return ("imap.zoho.com",993,"smtp.zoho.com",465)
        case .fastmail: return ("imap.fastmail.com",993,"smtp.fastmail.com",465)
        case .mailcom: return ("imap.mail.com",993,"smtp.mail.com",465)
        case .custom: return ("",993,"",465)
        }
    }
    var note: String {
        switch self {
        case .custom: return "可参考 iPhone 邮件中已有的 IMAP / SMTP 服务器配置。Exchange ActiveSync 账户需要另行确认 IMAP 是否开放。"
        case .outlook: return "使用微软 OAuth 授权。Microsoft 365 需按组织配置 SMTP 主机（通常为 smtp.office365.com），并确认管理员允许 IMAP / SMTP。"
        case .gmail: return "支持 Google OAuth；账户允许时也可选择专用应用密码。OAuth 首次使用需在设置中配置自己的客户端 ID。"
        case .qq, .netease, .netease126, .yeah, .vip163: return "请先在邮箱网页中开启 IMAP / SMTP，填写客户端授权码。"
        case .icloud: return "使用 Apple 账户生成的 App 专用密码。"
        case .zoho: return "外部客户端权限取决于套餐和数据中心；请核对账户中的服务器设置。"
        case .fastmail, .mailcom: return "需包含第三方客户端权限的套餐，并使用相应的应用密码。"
        default: return "填写邮箱服务商提供的服务器信息和客户端专用密码；企业账户需管理员允许接入。"
        }
    }
}

struct MailAccount: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = ""
    var email = ""
    var provider: MailProvider = .custom
    var identityID: UUID?
    var tags = ""
    var aliases = ""
    var signature = ""
    var enabled = false
    var auth = "password"
    var username = ""
    var imapHost = ""
    var imapPort = 993
    var imapTLS = "tls"
    var smtpHost = ""
    var smtpPort = 465
    var smtpTLS = "tls"
    var sentFolder: String? = nil
    var lastSync: Date?
    var syncError: String?
    var displayName: String { name.isEmpty ? email : name }
    mutating func applyProvider() {
        let preset = provider.servers
        imapHost = preset.0; imapPort = preset.1; smtpHost = preset.2; smtpPort = preset.3
        imapTLS = "tls"; smtpTLS = smtpPort == 587 ? "startTLS" : "tls"
        auth = provider == .outlook ? "microsoft" : (provider == .gmail ? "google" : "password")
    }
    var allowedAddresses: [String] { ([email] + aliases.components(separatedBy: CharacterSet(charactersIn: ",;\n，；"))).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
}

struct PlatformHistory: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    var text: String
}
struct PlatformRecord: Codable, Identifiable, Equatable {
    var id = UUID()
    var accountID: UUID?
    var name = ""
    var url = ""
    var username = ""
    var address = ""
    var kind = "网站"
    var loginMethod = "邮箱登录"
    var roles = ["登录"]
    var status = "使用中"
    var notes = ""
    var checkedAt: Date?
    var updatedAt = Date()
    var history: [PlatformHistory] = []
}

struct DraftAttachment: Codable, Identifiable, Equatable {
    var id = UUID()
    var path: String
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
}
struct MailDraft: Codable, Identifiable, Equatable {
    var id = UUID()
    var accountID: UUID?
    var from = ""
    var to = ""
    var cc = ""
    var bcc = ""
    var subject = ""
    var body = ""
    var attachments: [DraftAttachment] = []
    var inReplyTo: String?
    var references: String?
    var updatedAt = Date()
}

struct CachedAttachment: Codable, Identifiable, Equatable {
    var id = UUID()
    var filename: String
    var mimeType: String
    var data: Data
}
struct CachedMessage: Codable, Identifiable, Equatable {
    var id: String
    var accountID: UUID
    var folder: String
    var uid: UInt64
    var uidValidity: UInt64? = nil
    var subject: String
    var from: String
    var replyTo: String? = nil
    var to: String
    var cc: String
    var date: Date
    var preview: String
    var body: String
    var html: String?
    var isRead: Bool
    var isFlagged: Bool
    var messageID: String?
    var references: String?
    var attachments: [CachedAttachment]
    var loaded: Bool
}

struct MailPreferences: Codable, Equatable {
    var syncMinutes = 5
    var fetchLimit = 80
    var notifyNewMail = false
    var googleClientID = ""
    var microsoftClientID = ""
    var microsoftTenant = "common"
}
struct MailLibrary: Codable {
    var schemaVersion = 1
    var identities = MailIdentity.defaults
    var accounts: [MailAccount] = []
    var platforms: [PlatformRecord] = []
    var drafts: [MailDraft] = []
    var preferences = MailPreferences()
}

enum MailValidation {
    static func address(_ value: String) -> Bool {
        let s = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.utf8.count <= 320, !s.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              s.range(of: "^[^\\s@<>(),;:\\\"\\\\\\[\\]]+@[^\\s@<>(),;:\\\"\\\\\\[\\]]+\\.[^\\s@<>(),;:\\\"\\\\\\[\\]]+$", options: .regularExpression) != nil else { return false }
        let parts = s.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].hasPrefix("."), !parts[0].hasSuffix("."), !parts[0].contains("..") else { return false }
        return parts[1].split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && !label.hasPrefix("-") && !label.hasSuffix("-") && label.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" }
        }
    }
    static func recipients(_ value: String) -> [String] {
        value.components(separatedBy: CharacterSet(charactersIn: ",;，；\n")).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    static func bareAddress(_ value: String) -> String {
        if let a = value.lastIndex(of: "<"), let b = value[a...].firstIndex(of: ">") { return String(value[value.index(after:a)..<b]) }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func webURL(_ value: String) -> URL? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }), let u = URL(string: text.contains("://") ? text : "https://" + text), let scheme = u.scheme?.lowercased(), ["https", "http"].contains(scheme), let host = u.host, !host.isEmpty, u.user == nil, u.password == nil else { return nil }
        return u
    }
    static func host(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 255, !value.contains(where: { $0.isWhitespace || $0.isNewline }),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
        if value.hasPrefix("[") && value.hasSuffix("]") {
            let inside = value.dropFirst().dropLast()
            return inside.contains(":") && inside.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "0123456789abcdefABCDEF:.").contains($0) }
        }
        let text = value.hasSuffix(".") ? String(value.dropLast()) : value
        return text.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-") && label.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" }
        }
    }
    static func validate(_ library: MailLibrary) throws {
        guard library.schemaVersion == 1 else { throw MailAppError.message("备份格式版本暂不支持。") }
        guard Set(library.accounts.map(\.id)).count == library.accounts.count, Set(library.identities.map(\.id)).count == library.identities.count, Set(library.platforms.map(\.id)).count == library.platforms.count, Set(library.drafts.map(\.id)).count == library.drafts.count else { throw MailAppError.message("资料中有重复的记录标识。") }
        let identities = Set(library.identities.map(\.id)); let accounts = Set(library.accounts.map(\.id))
        for i in library.identities {
            guard !i.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !i.symbol.isEmpty,
                  i.color.range(of: "^#?[0-9a-fA-F]{6}$", options: .regularExpression) != nil else { throw MailAppError.message("身份名称、图标或颜色无效。") }
        }
        let emails = library.accounts.map { $0.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard Set(emails).count == emails.count else { throw MailAppError.message("资料中有重复的邮箱地址。") }
        for a in library.accounts {
            guard address(a.email), a.identityID == nil || identities.contains(a.identityID!), (1...65535).contains(a.imapPort), (1...65535).contains(a.smtpPort),
                  ["password", "google", "microsoft"].contains(a.auth), ["tls", "startTLS"].contains(a.imapTLS), ["tls", "startTLS"].contains(a.smtpTLS),
                  a.allowedAddresses.allSatisfy(address), !a.username.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw MailAppError.message("邮箱记录、登录方式、别名或身份关联无效。") }
            if a.enabled && (!host(a.imapHost) || !host(a.smtpHost)) { throw MailAppError.message("已开启收发的邮箱需要有效的 IMAP / SMTP 主机名；仅登记时可以留空。") }
            if let sent = a.sentFolder, sent.contains(where: { $0.isNewline || $0 == "\0" }) { throw MailAppError.message("已发送文件夹名称不能包含换行或空字符。") }
        }
        for p in library.platforms {
            guard !p.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, p.accountID == nil || accounts.contains(p.accountID!),
                  p.address.isEmpty || address(p.address), p.url.isEmpty || webURL(p.url) != nil else { throw MailAppError.message("平台名称、邮箱关联或网址无效。") }
        }
        for d in library.drafts {
            guard d.accountID == nil || accounts.contains(d.accountID!), Set(d.attachments.map(\.id)).count == d.attachments.count else { throw MailAppError.message("草稿中的邮箱关联或附件标识无效。") }
        }
        guard (1...1440).contains(library.preferences.syncMinutes), (1...500).contains(library.preferences.fetchLimit) else { throw MailAppError.message("同步间隔应为 1–1440 分钟，每个文件夹同步数量应为 1–500 封。") }
    }
}
enum MailAppError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(s) = self { return s }; return nil }
}

enum PlatformCSV {
    static let headers = ["平台名称","邮箱","账号","网址","类型","登录方式","关联用途","状态","备注"]
    static func encode(_ records: [PlatformRecord], accounts: [MailAccount]) -> String {
        var rows = [headers]
        for r in records { rows.append([r.name, r.address.isEmpty ? accounts.first(where:{$0.id == r.accountID})?.email ?? "" : r.address, r.username,r.url,r.kind,r.loginMethod,r.roles.joined(separator:" / "),r.status,r.notes]) }
        return "\u{FEFF}" + rows.map { $0.map { cell in
            var v = cell
            if ["=","+","-","@","\t","\r"].contains(where: { v.hasPrefix($0) }) { v = "'" + v }
            return "\"" + v.replacingOccurrences(of:"\"",with:"\"\"") + "\""
        }.joined(separator:",") }.joined(separator:"\r\n")
    }
    static func parse(_ text: String) throws -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false, afterQuote = false
        let chars = Array(text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" { if i+1 < chars.count && chars[i+1] == "\"" { field.append("\""); i += 1 } else { quoted = false; afterQuote = true } } else { field.append(c) }
            } else if c == "\"" && field.isEmpty && !afterQuote { quoted = true }
            else if c == "," { row.append(field); field = ""; afterQuote = false }
            else if c == "\n" || c == "\r" || c == "\r\n" { row.append(field); rows.append(row); row = []; field = ""; afterQuote = false; if c == "\r" && i+1 < chars.count && chars[i+1] == "\n" { i += 1 } }
            else { if afterQuote || c == "\"" { throw MailAppError.message("CSV 引号位置或引号后的内容无效。") }; field.append(c) }
            i += 1
        }
        if quoted { throw MailAppError.message("CSV 的引号没有闭合。") }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows.filter { !$0.allSatisfy(\.isEmpty) }
    }
}
