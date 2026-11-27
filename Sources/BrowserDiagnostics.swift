import CryptoKit
import Darwin
import Foundation

enum PortalBrowserTarget: String, CaseIterable, Hashable {
    case chrome, edge

    var name: String { self == .chrome ? "Chrome" : "Edge" }

    func userManifest(in home: URL, hostName: String) -> URL {
        let directory = self == .chrome ? "Google/Chrome" : "Microsoft Edge"
        return home.appendingPathComponent("Library/Application Support/\(directory)/NativeMessagingHosts/\(hostName).json")
    }

    func systemManifest(in library: URL, hostName: String) -> URL {
        let directory = self == .chrome ? "Google/Chrome" : "Microsoft/Edge"
        return library.appendingPathComponent("\(directory)/NativeMessagingHosts/\(hostName).json")
    }
}

struct BrowserDiagnosticEvidence: Equatable {
    enum Status { case verified, issue, unknown }
    let status: Status
    let detail: String
}

struct BrowserDiagnosticSnapshot {
    let installed: Bool
    let running: Bool
    let extensionPackage: BrowserDiagnosticEvidence
    let nativeHost: BrowserDiagnosticEvidence
    let helperReady: Bool
    let bridgeRunning: Bool

    var browser: BrowserDiagnosticEvidence {
        if running { return .init(status: .verified, detail: "检测时浏览器正在运行。") }
        if installed { return .init(status: .verified, detail: "已找到浏览器，检测时未运行。") }
        return .init(status: .issue, detail: "系统未找到受支持的正式版浏览器。")
    }

    var bridge: BrowserDiagnosticEvidence {
        bridgeRunning
            ? .init(status: .verified, detail: "搞门户的本机桥接正在监听。")
            : .init(status: .issue, detail: "搞门户的本机桥接尚未启动。")
    }

    var canRepair: Bool {
        installed && extensionPackage.status == .verified && helperReady && (nativeHost.status == .issue || !bridgeRunning)
    }

    func connection(profileCount: Int) -> BrowserDiagnosticEvidence {
        if profileCount > 0 {
            return .init(status: .verified, detail: "已验证 \(profileCount) 个资料的连接。")
        }
        if !running {
            return .init(status: .unknown, detail: "检测时浏览器未运行，当前没有资料回报连接。")
        }
        return .init(status: .unknown, detail: "当前没有资料回报。请在目标资料的扩展管理页检查助手，再点助手弹窗中的「重新连接」。")
    }
}

struct BrowserDiagnostics {
    let home: URL
    let systemLibrary: URL
    let resources: URL
    let helper: URL
    let hostName: String

    private struct ExtensionManifest: Decodable {
        struct Background: Decodable { let service_worker: String }
        let manifest_version: Int
        let key: String
        let permissions: [String]
        let background: Background
    }

    private struct NativeManifest: Codable {
        let name: String
        let description: String
        let path: String
        let type: String
        let allowed_origins: [String]
    }

    private enum InspectionError: Error { case missing, invalid, unreadable }

    var extensionDirectory: URL { resources.appendingPathComponent("BrowserExtension", isDirectory: true) }

    func snapshot(for target: PortalBrowserTarget, installed: Bool, running: Bool, bridgeRunning: Bool) -> BrowserDiagnosticSnapshot {
        let extensionID: String?
        let package: BrowserDiagnosticEvidence
        do {
            extensionID = try validatedPackageID()
            package = .init(status: .verified, detail: "随应用提供的扩展文件、身份和原生消息权限已核对。")
        } catch InspectionError.missing {
            extensionID = nil
            package = .init(status: .issue, detail: "随应用提供的扩展文件不完整，请从正式发行版重新安装搞门户。")
        } catch InspectionError.invalid {
            extensionID = nil
            package = .init(status: .issue, detail: "随应用提供的扩展清单或身份异常，请从正式发行版重新安装搞门户。")
        } catch {
            extensionID = nil
            package = .init(status: .unknown, detail: "无法读取随应用提供的扩展文件，请检查搞门户的安装位置和权限。")
        }
        let helperReady = helperIsExecutable
        let registration: BrowserDiagnosticEvidence
        if !helperReady {
            registration = .init(status: .issue, detail: "当前搞门户的原生消息程序无法执行，请检查安装。")
        } else if let extensionID {
            registration = self.registration(for: target, extensionID: extensionID)
        } else {
            registration = .init(status: .unknown, detail: "需要先核对随应用提供的扩展身份。")
        }
        return .init(installed: installed, running: running, extensionPackage: package,
                     nativeHost: registration, helperReady: helperReady, bridgeRunning: bridgeRunning)
    }

    func registrationPayload() throws -> Data {
        let id: String
        do { id = try validatedPackageID() }
        catch { throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "随应用提供的浏览器助手无法核对，请检查安装。"]) }
        guard helperIsExecutable else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "搞门户的原生消息程序缺失或不可执行，请检查安装。"])
        }
        let manifest = NativeManifest(name: hostName, description: "搞门户浏览器助手", path: helper.path, type: "stdio",
                                      allowed_origins: ["chrome-extension://\(id)/"])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(manifest)
    }

    func writeRegistration(_ data: Data, for target: PortalBrowserTarget) throws {
        let url = target.userManifest(in: home, hostName: hostName)
        guard !isRedirected(url, below: home) else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSLocalizedDescriptionKey: "当前用户的原生消息登记路径经过重定向。"])
        }
        let manager = FileManager.default
        if (try? readFile(url)) == data,
           let attributes = try? manager.attributesOfItem(atPath: url.path),
           attributes[.posixPermissions] as? Int == 0o600 { return }
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func validatedPackageID() throws -> String {
        let idData = try readFile(resources.appendingPathComponent("extension-id.txt"), limit: 128)
        guard let id = String(data: idData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              id.utf8.count == 32, id.utf8.allSatisfy({ (97...112).contains($0) }) else { throw InspectionError.invalid }
        guard !isRedirected(extensionDirectory, below: resources) else { throw InspectionError.unreadable }
        let manifestData = try readFile(extensionDirectory.appendingPathComponent("manifest.json"))
        guard let manifest = try? JSONDecoder().decode(ExtensionManifest.self, from: manifestData),
              manifest.manifest_version == 3, let key = Data(base64Encoded: manifest.key), !key.isEmpty,
              extensionID(for: key) == id, manifest.permissions.contains("nativeMessaging"),
              manifest.background.service_worker == "background.js" else { throw InspectionError.invalid }
        for name in ["background.js", "content.js", "popup.html", "popup.js", "popup.css", "icon16.png", "icon48.png", "icon128.png"] {
            let file = try inspectedFile(extensionDirectory.appendingPathComponent(name))
            defer { close(file.descriptor) }
            guard file.size > 0 else { throw InspectionError.invalid }
        }
        return id
    }

    private func extensionID(for key: Data) -> String {
        let bytes = SHA256.hash(data: key).prefix(16).flatMap { [($0 >> 4) + 97, ($0 & 15) + 97] }
        return String(decoding: bytes, as: UTF8.self)
    }

    private var helperIsExecutable: Bool {
        guard let file = try? inspectedFile(helper) else { return false }
        defer { close(file.descriptor) }
        return file.size > 0 && FileManager.default.isExecutableFile(atPath: helper.path)
    }

    private func registration(for target: PortalBrowserTarget, extensionID: String) -> BrowserDiagnosticEvidence {
        let locations = [
            ("当前用户", target.userManifest(in: home, hostName: hostName), home),
            ("整台 Mac", target.systemManifest(in: systemLibrary, hostName: hostName), systemLibrary)
        ]
        for (scope, url, root) in locations {
            do {
                guard !isRedirected(url, below: root) else {
                    return .init(status: .unknown, detail: "\(scope)的原生消息登记路径经过重定向，无法核对。")
                }
                let data = try readFile(url)
                guard let manifest = try? JSONDecoder().decode(NativeManifest.self, from: data),
                      manifest.name == hostName, manifest.type == "stdio",
                      !manifest.description.isEmpty, manifest.allowed_origins == ["chrome-extension://\(extensionID)/"],
                      manifest.path.hasPrefix("/"), !manifest.path.contains("\0") else {
                    throw InspectionError.invalid
                }
                guard manifest.path == helper.path else {
                    return .init(status: .issue, detail: "\(scope)的登记未指向当前搞门户，可能来自旧位置。")
                }
                return .init(status: .verified, detail: "\(scope)的默认登记与当前搞门户及扩展匹配。")
            } catch InspectionError.missing {
                continue
            } catch InspectionError.invalid {
                return .init(status: .issue, detail: "\(scope)的原生消息清单无效。")
            } catch {
                return .init(status: .unknown, detail: "无法读取\(scope)的原生消息清单，请检查文件权限。")
            }
        }
        return .init(status: .issue, detail: "在当前用户及整台 Mac 的默认路径中均未找到原生消息登记。")
    }

    private func isRedirected(_ url: URL, below root: URL) -> Bool {
        var entry = url
        while entry.path != root.path {
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: entry.path)) != nil { return true }
            let parent = entry.deletingLastPathComponent()
            guard parent.path != entry.path else { return true }
            entry = parent
        }
        return false
    }

    private func inspectedFile(_ url: URL) throws -> (descriptor: Int32, size: off_t) {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { throw InspectionError.missing }
            throw InspectionError.unreadable
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { close(descriptor); throw InspectionError.unreadable }
        guard (info.st_mode & S_IFMT) == S_IFREG else { close(descriptor); throw InspectionError.invalid }
        return (descriptor, info.st_size)
    }

    private func readFile(_ url: URL, limit: Int = 64 * 1024) throws -> Data {
        let file = try inspectedFile(url)
        let handle = FileHandle(fileDescriptor: file.descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        guard file.size <= limit else { throw InspectionError.invalid }
        guard let data = try handle.read(upToCount: limit + 1), !data.isEmpty, data.count <= limit else {
            throw InspectionError.invalid
        }
        return data
    }
}
