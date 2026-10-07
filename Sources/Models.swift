import Foundation

struct Browser: Codable, Equatable {
    let id: String
    let name: String
    let bundleID: String
    let supportsFill: Bool
    static let catalog: [Browser] = [
        Browser(id: "chrome", name: "Chrome", bundleID: "com.google.Chrome", supportsFill: true),
        Browser(id: "edge", name: "Edge", bundleID: "com.microsoft.edgemac", supportsFill: true),
        Browser(id: "safari", name: "Safari", bundleID: "com.apple.Safari", supportsFill: false),
        Browser(id: "firefox", name: "Firefox", bundleID: "org.mozilla.firefox", supportsFill: false)
    ]
}

struct Account: Codable, Equatable {
    var id: String
    var label: String
    var username: String
    var loginHosts: [String]
    var hasPassword: Bool
}

struct Website: Codable, Equatable {
    var id: String
    var name: String
    var url: String
    var color: String
    var icon: String?
    var allowedBrowsers: [String]
    var defaultBrowser: String
    var accounts: [Account]
    var defaultAccount: String?
    var profiles: [String: String]
    var iconSource: String? = nil
    var iconRevision: Int? = nil
    var iconSourcePixels: Int? = nil
    var iconCheckedAt: Double? = nil
    var aliases: String? = nil
}

struct Tile: Codable, Equatable {
    var id: String
    var kind: String
    var name: String?
    var children: [String]?
}

struct Workspace: Codable, Equatable {
    var id: String
    var name: String
    var siteIDs: [String]
}

struct Library: Codable, Equatable {
    var schema: Int = 1
    var sites: [Website]
    var tiles: [Tile]
    var appearance: String = "system"
    var layoutDensity: String? = nil
    var iconSize: Int? = nil
    var workspaces: [Workspace]? = nil

    static func empty() -> Library { Library(sites: [], tiles: []) }

    static func initial(browsers: [String]) -> Library {
        let standard = browsers.contains("chrome") ? "chrome" : (browsers.first ?? "safari")
        let choices = browsers.isEmpty ? ["safari"] : browsers
        let seeds: [(String, String, String)] = [
            ("Claude", "https://claude.ai", "#D97757"),
            ("ChatGPT", "https://chatgpt.com", "#248977"),
            ("Gemini", "https://gemini.google.com", "#537CE6"),
            ("GitHub", "https://github.com", "#35384B"),
            ("哔哩哔哩", "https://www.bilibili.com", "#ED83A7"),
            ("飞书", "https://www.feishu.cn", "#3F79EA")
        ]
        let sites = seeds.enumerated().map { i, seed in
            Website(id: "seed-\(i)", name: seed.0, url: seed.1, color: seed.2, icon: nil,
                    allowedBrowsers: seed.0 == "Claude" && choices.contains("chrome") ? ["chrome"] : choices, defaultBrowser: standard, accounts: [],
                    defaultAccount: nil, profiles: [:])
        }
        return Library(sites: sites, tiles: sites.map { Tile(id: $0.id, kind: "site", name: nil, children: nil) })
    }

    func validated() throws -> Library {
        guard schema == 1, sites.count <= 5000, tiles.count <= 5000 else { throw AppError.message("数据格式不受支持。") }
        guard layoutDensity == nil || ["compact", "comfortable"].contains(layoutDensity!),
              iconSize == nil || [60, 76, 92].contains(iconSize!) else { throw AppError.message("启动台布局设置无效。") }
        let ids = sites.map(\.id)
        guard Set(ids).count == ids.count else { throw AppError.message("网站编号重复。") }
        var seen: Set<String> = []
        var accountIDs: Set<String> = []
        for site in sites {
            guard !site.id.isEmpty, !site.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  site.name.count <= 100, (site.aliases?.count ?? 0) <= 500, validWebURL(site.url) != nil,
                  !site.allowedBrowsers.isEmpty,
                  site.allowedBrowsers.allSatisfy({ Browser.catalog.map(\.id).contains($0) }),
                  site.allowedBrowsers.contains(site.defaultBrowser),
                  site.accounts.count <= 100,
                  site.defaultAccount == nil || site.accounts.contains(where: { $0.id == site.defaultAccount }) else {
                throw AppError.message("网站配置无效：请填写名称、网址，并选择至少一个浏览器。")
            }
            for account in site.accounts {
                guard !account.id.isEmpty, accountIDs.insert(account.id).inserted,
                      account.loginHosts.allSatisfy({ normalizedHost($0) != nil }) else {
                    throw AppError.message("账号或登录域名配置无效。")
                }
            }
        }
        var tileIDs: Set<String> = []
        for tile in tiles {
            guard tileIDs.insert(tile.id).inserted else { throw AppError.message("图标编号重复。") }
            if tile.kind == "site" {
                guard ids.contains(tile.id), seen.insert(tile.id).inserted else { throw AppError.message("网站排列重复。") }
            } else if tile.kind == "folder" {
                guard !ids.contains(tile.id), let children = tile.children, !children.isEmpty,
                      !(tile.name ?? "").isEmpty else { throw AppError.message("文件夹配置无效。") }
                for id in children {
                    guard ids.contains(id), seen.insert(id).inserted else { throw AppError.message("文件夹内的网站排列重复。") }
                }
            } else { throw AppError.message("图标类型无效。") }
        }
        var workspaceIDs: Set<String> = []
        guard (workspaces?.count ?? 0) <= 100 else { throw AppError.message("工作场景不能超过 100 个。") }
        for workspace in workspaces ?? [] {
            guard !workspace.id.isEmpty, workspaceIDs.insert(workspace.id).inserted,
                  !workspace.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  workspace.name.count <= 60, !workspace.siteIDs.isEmpty,
                  workspace.siteIDs.count <= 20, Set(workspace.siteIDs).count == workspace.siteIDs.count,
                  workspace.siteIDs.allSatisfy({ ids.contains($0) }) else {
                throw AppError.message("工作场景配置无效：每组请选择 1 至 20 个网站。")
            }
        }
        return self
    }
}

enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

func validWebURL(_ value: String) -> URL? {
    guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
          ["https", "http"].contains(scheme), let host = url.host, !host.isEmpty,
          url.user == nil, url.password == nil, value.count < 8192 else { return nil }
    return url
}

func normalizedHost(_ input: String) -> String? {
    let text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !text.isEmpty else { return nil }
    let source = text.contains("://") ? text : "https://" + text
    guard let url = validWebURL(source), let host = url.host?.lowercased(),
          !host.contains("*"), !host.contains(" "), url.port == nil,
          (url.path.isEmpty || url.path == "/"), url.query == nil, url.fragment == nil else { return nil }
    return host
}

func allowedOrigins(site: Website, account: Account) -> Set<String> {
    var origins: Set<String> = []
    if let value = origin(site.url), value.hasPrefix("https://") { origins.insert(value) }
    for host in account.loginHosts { if let normalized = normalizedHost(host) { origins.insert("https://" + normalized) } }
    return origins
}

func origin(_ value: String) -> String? {
    guard let url = validWebURL(value), let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
    let port = url.port
    let suffix = port == nil || (scheme == "https" && port == 443) || (scheme == "http" && port == 80) ? "" : ":\(port!)"
    return "\(scheme)://\(host)\(suffix)"
}

final class LibraryStore {
    let directory: URL
    let file: URL
    let persistent: Bool
    var transientSnapshots: [String: Data] = [:]
    init(directory: URL? = nil, persistent: Bool = true) {
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MenDao", isDirectory: true)
        self.file = self.directory.appendingPathComponent("library.json")
        self.persistent = persistent
    }
    func load(defaultBrowsers: [String]) throws -> Library {
        guard persistent else { return Library.initial(browsers: defaultBrowsers) }
        if FileManager.default.fileExists(atPath: directory.path) {
            let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            if let pending = entries.first(where: { $0.lastPathComponent.hasPrefix(".gaomenhu-restore-") }) {
                throw AppError.message("检测到上次未完成的资料恢复，已停止写入以保护原资料。恢复资料保留在：\(pending.path)。请先检查并恢复其中的安全副本，再重新启动。")
            }
        }
        guard FileManager.default.fileExists(atPath: file.path) else { return Library.initial(browsers: defaultBrowsers) }
        return try JSONDecoder().decode(Library.self, from: Data(contentsOf: file)).validated()
    }
    func save(_ library: Library) throws {
        _ = try library.validated()
        guard persistent else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(library).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
