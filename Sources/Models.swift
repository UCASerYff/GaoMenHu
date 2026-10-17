import Foundation
import Darwin

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

/// Debug hooks stop at real durability boundaries without touching a user's data.
#if DEBUG_TESTING
enum LibraryInitializationTesting {
    static var boundary: ((String) throws -> Void)?
}
#endif

final class LibraryStore {
    let directory: URL
    let file: URL
    let persistent: Bool
    var transientSnapshots: [String: Data] = [:]
    static let initializationKey = "GaoMenHu.LibraryInitialization.V1"
    private struct Evidence: Codable {
        let format: Int
        let phase: String
    }
    private enum Access { case unloaded, ready, blocked }
    private var access: Access = .unloaded
    private var baseline: Data?
    private let preferences: UserDefaults?
    /// Explicit fixture directories never read or write the real preferences domain.
    init(directory: URL? = nil, persistent: Bool = true, preferences: UserDefaults? = nil) {
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MenDao", isDirectory: true)
        self.file = self.directory.appendingPathComponent("library.json")
        self.persistent = persistent
        self.preferences = persistent ? (preferences ?? (directory == nil ? .standard : nil)) : nil
    }

    var isWritable: Bool { !persistent || access == .ready }

    func load(defaultBrowsers: [String]) throws -> Library {
        guard persistent else { return Library.initial(browsers: defaultBrowsers) }
        guard access != .blocked else { throw recoveryFailure() }
        do {
            let evidence = try readEvidence()
            guard evidence == nil || evidence?.phase == "ready" else { throw recoveryFailure() }
            guard let directoryKind = try kind(directory) else {
                guard evidence == nil, !hasHistoricalPreferences else { throw recoveryFailure() }
                return try initialize(Library.initial(browsers: defaultBrowsers))
            }
            guard directoryKind == S_IFDIR else { throw recoveryFailure() }
            try rejectPendingTransactions()
            // Even an empty existing directory may be the remains of a failed
            // migration. Only an absent, history-free path is genuine first use.
            guard try kind(file) == S_IFREG else { throw recoveryFailure() }
            let bytes = try read(file)
            let library = try JSONDecoder().decode(Library.self, from: bytes).validated()
            if evidence == nil {
                // The legacy library itself is sufficient migration evidence.
                // Its bytes, layout, accounts and profile bindings stay untouched.
                try writeEvidence("migrating")
                try boundary("migration.evidence")
                guard try read(file) == bytes else { throw recoveryFailure() }
                try boundary("migration.verified")
                try writeEvidence("ready")
            }
            baseline = bytes; access = .ready
            return library
        } catch {
            access = .blocked
            throw AppError.message("网站资料处于恢复保护状态，已停止自动保存。原资料、快照和附件保持不变；请检查主资料文件及未完成事务，恢复安全副本后重新启动。\n\(error.localizedDescription)")
        }
    }

    func save(_ library: Library) throws {
        _ = try library.validated()
        guard persistent else { return }
        // Existing callers may explicitly save their own first library. They may
        // never use save to reset an existing or previously initialized path.
        if access == .unloaded {
            do {
                guard try kind(directory) == nil, try readEvidence() == nil, !hasHistoricalPreferences else { throw recoveryFailure() }
                _ = try initialize(library)
                return
            } catch { access = .blocked; throw error }
        }
        try requireWritable()
        let bytes = try encoded(library)
        guard let previous = baseline else { access = .blocked; throw recoveryFailure() }
        guard bytes != previous else { return }
        let transaction = directory.appendingPathComponent(".gaomenhu-library-write-" + UUID().uuidString, isDirectory: true)
        let old = transaction.appendingPathComponent("previous.json")
        let next = transaction.appendingPathComponent("next.json")
        var replaced = false
        do {
            try writeEvidence("writing")
            try boundary("write.evidence")
            try FileManager.default.createDirectory(at: transaction, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try writePrivate(previous, to: old)
            try writePrivate(bytes, to: next)
            try boundary("write.staged")
            guard try read(file) == previous else { throw recoveryFailure() }
            guard rename(next.path, file.path) == 0 else { throw recoveryFailure() }
            replaced = true
            try synchronizeDirectory()
            try boundary("write.replaced")
            guard try read(file) == bytes else { throw recoveryFailure() }
            try boundary("write.verified")
            try writeEvidence("ready")
            try FileManager.default.removeItem(at: transaction)
            baseline = bytes
        } catch {
            // A reported in-process failure restores the exact previous bytes.
            // A process interruption leaves both the journal and independent
            // pending evidence, so the next launch blocks rather than guessing.
            if replaced, (try? read(file)) == bytes, (try? read(old)) == previous {
                _ = rename(old.path, file.path)
                try? synchronizeDirectory()
            }
            try? writeEvidence("writing")
            access = .blocked
            throw error
        }
    }

    /// Every persistent writer (including snapshots and restore) uses this gate.
    func requireWritable() throws {
        guard persistent else { return }
        do {
            guard access == .ready, let baseline, try readEvidence()?.phase == "ready" || preferences == nil,
                  try kind(directory) == S_IFDIR, try kind(file) == S_IFREG else { throw recoveryFailure() }
            try rejectPendingTransactions()
            guard try read(file) == baseline else { throw recoveryFailure() }
        } catch { access = .blocked; throw error }
    }

    /// A successful, separately verified full-restore transaction changes the
    /// same live file. Adopt it only after the transaction has finished safely.
    func adoptCommittedLibrary(_ library: Library) throws {
        guard persistent else { return }
        guard access == .ready else { throw recoveryFailure() }
        do {
            try rejectPendingTransactions()
            let bytes = try read(file)
            guard try JSONDecoder().decode(Library.self, from: bytes).validated() == library else { throw recoveryFailure() }
            baseline = bytes
        } catch { access = .blocked; throw error }
    }

    private func initialize(_ library: Library) throws -> Library {
        do {
            let bytes = try encoded(library)
            try writeEvidence("initializing")
            try boundary("initialization.evidence")
            try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard mkdir(directory.path, 0o700) == 0 else { throw recoveryFailure() }
            guard try kind(directory) == S_IFDIR else { throw recoveryFailure() }
            try boundary("initialization.directory")
            let staged = directory.appendingPathComponent(".gaomenhu-library-init-" + UUID().uuidString)
            try writePrivate(bytes, to: staged)
            try boundary("initialization.staged")
            // RENAME_EXCL never replaces a library that appeared concurrently.
            guard renameatx_np(AT_FDCWD, staged.path, AT_FDCWD, file.path, UInt32(RENAME_EXCL)) == 0 else { throw recoveryFailure() }
            try synchronizeDirectory()
            try boundary("initialization.installed")
            guard try read(file) == bytes else { throw recoveryFailure() }
            try boundary("initialization.verified")
            try writeEvidence("ready")
            baseline = bytes; access = .ready
            return library
        } catch { access = .blocked; throw error }
    }

    private func encoded(_ library: Library) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let bytes = try encoder.encode(library)
        guard bytes.count <= 30_000_000 else { throw recoveryFailure() }
        return bytes
    }

    private var hasHistoricalPreferences: Bool {
        preferences?.dictionaryRepresentation().keys.contains {
            $0 != Self.initializationKey && ($0.hasPrefix("GaoMenHu.") || $0.hasPrefix("MenDao.") || $0.hasPrefix("NSWindow Frame MenDao."))
        } ?? false
    }
    private func readEvidence() throws -> Evidence? {
        guard let value = preferences?.object(forKey: Self.initializationKey) else { return nil }
        guard let bytes = value as? Data,
              let evidence = try? JSONDecoder().decode(Evidence.self, from: bytes),
              evidence.format == 1, ["ready", "initializing", "migrating", "writing"].contains(evidence.phase) else { throw recoveryFailure() }
        return evidence
    }
    private func writeEvidence(_ phase: String) throws {
        guard let preferences else { return }
        let bytes = try JSONEncoder().encode(Evidence(format: 1, phase: phase))
        preferences.set(bytes, forKey: Self.initializationKey)
        guard preferences.synchronize(), preferences.data(forKey: Self.initializationKey) == bytes else { throw recoveryFailure() }
    }
    private func rejectPendingTransactions() throws {
        let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        guard !entries.contains(where: {
            $0.lastPathComponent.hasPrefix(".gaomenhu-restore-") ||
            $0.lastPathComponent.hasPrefix(".gaomenhu-library-write-") ||
            $0.lastPathComponent.hasPrefix(".gaomenhu-library-init-")
        }) else { throw recoveryFailure() }
    }
    private func recoveryFailure() -> AppError { .message("资料缺失、不可读、版本不受支持或事务未完成；请保留现有文件并恢复安全副本。") }
    private func boundary(_ name: String) throws {
        #if DEBUG_TESTING
        try LibraryInitializationTesting.boundary?(name)
        #endif
    }
    private func kind(_ url: URL) throws -> mode_t? {
        var info = stat()
        if lstat(url.path, &info) == 0 { return info.st_mode & S_IFMT }
        guard errno == ENOENT else { throw recoveryFailure() }
        return nil
    }
    private func read(_ url: URL) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw recoveryFailure() }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o444 != 0, info.st_size >= 0, info.st_size <= 30_000_000 else { throw recoveryFailure() }
        var bytes = Data()
        while let chunk = try handle.read(upToCount: min(1_048_576, 30_000_000 - bytes.count + 1)), !chunk.isEmpty {
            guard chunk.count <= 30_000_000 - bytes.count else { throw recoveryFailure() }
            bytes.append(chunk)
        }
        return bytes
    }
    private func writePrivate(_ data: Data, to url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw recoveryFailure() }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do { try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        guard try read(url) == data else { throw recoveryFailure() }
    }
    private func synchronizeDirectory() throws {
        let fd = open(directory.path, O_RDONLY | O_NOFOLLOW | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw recoveryFailure() }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw recoveryFailure() }
    }
}
