import Foundation
import CryptoKit
import CoreFoundation
import Darwin

/// This is an explicitly authorized NEW library, never a substitute for the
/// normal legacy-library migration. No credential/transport/store-host is used.
enum PortalMailUIOnlyBootstrapReadiness: Equatable {
    case absent, ready, recoveryRequired(String)
}

struct PortalMailUIOnlyBootstrapFileIdentity: Codable, Equatable {
    let device: UInt64
    let inode: UInt64
    let uid: UInt32
    let gid: UInt32
    let mode: UInt32
    let flags: UInt32
    let links: UInt64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64
}

struct PortalMailUIOnlyBootstrapAbsence: Codable, Equatable {
    let path: String
    let existingAncestor: String
    let ancestorDevice: UInt64
    let ancestorInode: UInt64
    let ancestorUID: UInt32
    let ancestorGID: UInt32
    let ancestorMode: UInt32
    let ancestorFlags: UInt32
    let missingComponents: [String]
}

struct PortalMailUIOnlyBootstrapPlan: Codable, Equatable {
    let schemaVersion: Int
    let operation: String
    let sourceRoot: String
    let targetRoot: String
    let sourcePreferencesPath: String
    /// Exact defaults-export bytes, independent of the physical plist encoding.
    let sourcePreferencesSHA256: String
    let sourcePreferencesFileSHA256: String
    let sourcePreferencesFileIdentity: PortalMailUIOnlyBootstrapFileIdentity
    let absences: [PortalMailUIOnlyBootstrapAbsence]
    let preferenceKeyTypes: [String: String]
    let mappedPreferenceKeys: [String]
    let ignoredWindowPreferenceKeys: [String]
    let newLibrary: Bool
    let dataMigrated: Bool
}

struct PortalMailUIOnlyBootstrapAuthority: Codable {
    let schemaVersion: Int
    let operation: String
    let bootstrapID: UUID
    let sourceBundleID: String
    let targetBundleID: String
    let sourceFrozen: Bool
    let sourceRoot: String
    let targetRoot: String
    let sourcePreferencesPath: String
    let sourcePreferencesSHA256: String
    let sourcePreferencesFileSHA256: String
    let sourcePreferencesFileIdentity: PortalMailUIOnlyBootstrapFileIdentity
    let absencePlanSHA256: String
    let backupReceiptSHA256: String
    let userAuthorizationProofSHA256: String
    let fenceReceiptSHA256: String
}

struct PortalMailUIOnlyBootstrapReceipt: Codable {
    let schemaVersion: Int
    let operation: String
    let bootstrapID: UUID
    let sourceBundleID: String
    let targetBundleID: String
    let sourceRoot: String
    let targetRoot: String
    let plan: PortalMailUIOnlyBootstrapPlan
    let authoritySHA256: String
    let backupReceiptSHA256: String
    let actualBackupReceiptSHA256: String
    let userAuthorizationProofSHA256: String
    let actualHumanAuthorizationFactSHA256: String
    let fenceReceiptSHA256: String
    let newLibrary: Bool
    let dataMigrated: Bool
    let initialIdentityCount: Int
    let initialAccountCount: Int
    let initialPlatformCount: Int
    let initialDraftCount: Int
    let initialMessageCount: Int
    let storageMarkerSHA256: String
    let credentialServicePreserved: String
    let keychainAccessed: Bool
    let sourceBusinessDataReadOrRestored: Bool
    let sourceUIPreferencesRead: Bool
    let compatibleUISettingsCopied: Bool
    let externalBackupVerificationIsRootAttestation: Bool
    let createdAt: Date
}

/// Only needed by isolated fixtures; real UserDefaults inventories its own
/// persistent target domain, without copying values into a report.
protocol PortalMailUIOnlyBootstrapKeyInventory {
    func bootstrapPreferenceKeyNames() -> [String]
}

enum PortalMailUIOnlyBootstrap {
    static let operation = "mail-ui-only-bootstrap"
    static let sourceBundleID = "com.gaoseries.GaoYouJian"
    static let targetBundleID = "cn.mendao.launcher"
    static let receiptRelativePath = "UIOnlyBootstrapEvidence/receipt.json"
    private static let maximumRecordBytes = 32 * 1024 * 1024
    private struct State: Codable {
        let schemaVersion: Int
        let operation: String
        let bootstrapID: UUID
        let sourceRoot: String
        let targetRoot: String
        var phase: String
        var receiptSHA256: String?
        var storageMarkerSHA256: String?
    }
    private struct Marker: Codable { let schemaVersion: Int; let identity: UUID }
    private struct CommitSeal: Codable {
        let schemaVersion: Int
        let operation: String
        let bootstrapID: UUID
        let stateSHA256: String
        let receiptSHA256: String
    }
    struct Record { let data: Data; let identity: PortalMailUIOnlyBootstrapFileIdentity }
    struct Paths {
        let home: URL
        let source: URL
        let target: URL
        let preferences: URL
        let absent: [URL]
        init(homeURL: URL) throws {
            home = try physical(homeURL)
            let support = home.appendingPathComponent("Library/Application Support")
            source = support.appendingPathComponent("GaoSeries/GaoYouJian")
            target = support.appendingPathComponent("MenDao/MailCenter")
            preferences = home.appendingPathComponent("Library/Preferences/com.gaoseries.GaoYouJian.plist")
            absent = [source,
                home.appendingPathComponent("Library/Containers/com.gaoseries.GaoYouJian"),
                support.appendingPathComponent("com.gaoseries.GaoYouJian"),
                home.appendingPathComponent("Library/Saved Application State/com.gaoseries.GaoYouJian.savedState"),
                support.appendingPathComponent("GaoSeriesRestore/GaoYouJian"),
                support.appendingPathComponent("GaoSeries/GaoYouJian-Initialization.json"),
                support.appendingPathComponent("GaoSeries/.GaoYouJian.initialized-v1.json")]
        }
    }
    private static func issue() -> MailAppError {
        .message("邮件界面偏好初始化条件不完整或已变化；没有把缺失来源当作空库迁移，请保留当前资料与核验依据。")
    }
    static func digest(_ data: Data) -> String { MailStorage.digest(data) }
    static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    static func evidenceKey(destinationRootURL: URL) -> String {
        "GaoMenHu.MailUIOnlyBootstrap." + digest(Data(destinationRootURL.path.utf8))
    }
    private static func migrationKey(_ target: URL) -> String { "GaoMenHu.MailMigration." + digest(Data(target.path.utf8)) }
    private static func submissionKey(_ target: URL) -> String { "GaoMenHu.MailSubmissionEvidence." + digest(Data(target.path.utf8)) }
    private static func physical(_ url: URL) throws -> URL {
        guard url.isFileURL, url.host == nil || url.host == "localhost", url.path.hasPrefix("/"), url.path != "/",
              url.path.utf8.count <= 16_384,
              url.path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw issue() }
        return URL(fileURLWithPath: url.path)
    }
    static func absoluteRecordURL(_ raw: String) throws -> URL {
        guard raw.hasPrefix("/"), raw.utf8.count <= 16_384,
              raw.split(separator: "/", omittingEmptySubsequences: false).dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw issue() }
        return URL(fileURLWithPath: raw)
    }
    private static func metadata(_ fd: Int32) throws -> stat { var value = stat(); guard fstat(fd, &value) == 0 else { throw issue() }; return value }
    private static func identity(_ value: stat) -> PortalMailUIOnlyBootstrapFileIdentity {
        PortalMailUIOnlyBootstrapFileIdentity(device: UInt64(value.st_dev), inode: UInt64(value.st_ino), uid: value.st_uid,
            gid: value.st_gid, mode: UInt32(value.st_mode), flags: value.st_flags, links: UInt64(value.st_nlink), size: value.st_size,
            modifiedSeconds: Int64(value.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec),
            changedSeconds: Int64(value.st_ctimespec.tv_sec), changedNanoseconds: Int64(value.st_ctimespec.tv_nsec))
    }
    private static func directory(_ url: URL) throws -> Int32 {
        let value = try physical(url)
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw issue() }
        do {
            for component in value.pathComponents.dropFirst() {
                let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw issue() }; close(fd); fd = next
            }
            return fd
        } catch { close(fd); throw error }
    }
    private static func existsWithoutLinks(_ url: URL) throws -> Bool {
        let path = try physical(url), components = Array(path.pathComponents.dropFirst())
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw issue() }; defer { close(fd) }
        for (index, component) in components.enumerated() {
            var value = stat()
            if fstatat(fd, component, &value, AT_SYMLINK_NOFOLLOW) != 0 {
                guard errno == ENOENT else { throw issue() }; return false
            }
            guard value.st_mode & S_IFMT != S_IFLNK else { throw issue() }
            if index == components.count - 1 { return true }
            guard value.st_mode & S_IFMT == S_IFDIR else { throw issue() }
            let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw issue() }
            do { guard sameDirectory(value, try metadata(next)) else { throw issue() } }
            catch { close(next); throw error }
            close(fd); fd = next
        }
        throw issue()
    }
    private static func sameDirectory(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_uid == b.st_uid && a.st_gid == b.st_gid && a.st_mode == b.st_mode && a.st_flags == b.st_flags
    }
    /// A no-follow walk proves the first missing component and pins its nearest
    /// real parent. ENOTDIR, EACCES, links and other I/O failures are not absence.
    static func absence(_ url: URL) throws -> PortalMailUIOnlyBootstrapAbsence {
        let value = try physical(url), components = Array(value.pathComponents.dropFirst())
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC), ancestor = "/"
        guard fd >= 0 else { throw issue() }; defer { close(fd) }
        for (index, component) in components.enumerated() {
            var atPath = stat()
            if fstatat(fd, component, &atPath, AT_SYMLINK_NOFOLLOW) != 0 {
                guard errno == ENOENT else { throw issue() }
                let current = try metadata(fd)
                let reopened: Int32
                if ancestor == "/" { reopened = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC) }
                else { reopened = try directory(URL(fileURLWithPath: ancestor)) }
                guard reopened >= 0 else { throw issue() }; defer { close(reopened) }
                guard sameDirectory(current, try metadata(reopened)), fstatat(fd, component, &atPath, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else { throw issue() }
                return PortalMailUIOnlyBootstrapAbsence(path: value.path, existingAncestor: ancestor,
                    ancestorDevice: UInt64(current.st_dev), ancestorInode: UInt64(current.st_ino), ancestorUID: current.st_uid,
                    ancestorGID: current.st_gid, ancestorMode: UInt32(current.st_mode), ancestorFlags: current.st_flags,
                    missingComponents: Array(components[index...]))
            }
            guard index < components.count - 1, atPath.st_mode & S_IFMT == S_IFDIR else { throw issue() }
            let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw issue() }
            let opened = try metadata(next)
            guard sameDirectory(atPath, opened) else { close(next); throw issue() }
            close(fd); fd = next
            ancestor = ancestor == "/" ? "/" + component : ancestor + "/" + component
        }
        throw issue()
    }
    static func readRecord(_ url: URL, privateOnly: Bool = true, maximum: Int = maximumRecordBytes) throws -> Record {
        let path = try physical(url), parent = try directory(path.deletingLastPathComponent()); defer { close(parent) }
        let parentIdentity = try metadata(parent)
        let fd = openat(parent, path.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw issue() }; defer { close(fd) }
        let before = try metadata(fd)
        guard before.st_mode & S_IFMT == S_IFREG, before.st_uid == getuid(), before.st_nlink == 1,
              before.st_mode & (privateOnly ? 0o077 : 0o022) == 0, before.st_mode & 0o400 != 0,
              before.st_size > 0, before.st_size <= maximum else { throw issue() }
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0, bytes.count + max(0, count) <= maximum else { throw issue() }
            if count == 0 { break }; bytes.append(contentsOf: buffer.prefix(count))
        }
        let after = try metadata(fd); var atPath = stat()
        guard identity(before) == identity(after), bytes.count == Int(after.st_size),
              fstatat(parent, path.lastPathComponent, &atPath, AT_SYMLINK_NOFOLLOW) == 0, identity(after) == identity(atPath) else { throw issue() }
        let reopened = try directory(path.deletingLastPathComponent()); defer { close(reopened) }
        guard sameDirectory(parentIdentity, try metadata(reopened)) else { throw issue() }
        return Record(data: bytes, identity: identity(after))
    }
    private static func writeNew(_ data: Data, to url: URL) throws {
        let parent = try directory(url.deletingLastPathComponent()); defer { close(parent) }
        let fd = openat(parent, url.lastPathComponent, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw issue() }; defer { close(fd) }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }; guard count > 0 else { throw issue() }; offset += count
            }
        }
        guard fsync(fd) == 0, fsync(parent) == 0 else { throw issue() }
    }
    private static let windowKeys: Set<String> = ["NSWindow Frame GaoYouJian.MainWindow", "NSWindow Frame com_apple_SwiftUI_Settings_window", "NSWindow Frame main"]
    private static let suffixes: Set<String> = ["appearance", "sidebarHidden", "floating.opacity", "floating.display", "floating.horizontalRatio", "floating.verticalRatio", "floating.edge", "floating.dockMode", "floating.visible", "floating.showPreviews"]
    private static func windowFrame(_ text: String) -> Bool {
        guard text.utf8.count <= 512 else { return false }
        let parts = text.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count == 8 else { return false }
        var values: [Double] = []
        for part in parts {
            let raw = String(part)
            guard raw.range(of: "^-?[0-9]+(?:\\.[0-9]+)?$", options: .regularExpression) != nil,
                  let number = Double(raw), number.isFinite, abs(number) <= 1_000_000 else { return false }
            values.append(number)
        }
        return [2, 3, 6, 7].allSatisfy { values[$0] > 0 && values[$0] <= 100_000 }
    }
    private static func preferences(_ bytes: Data) throws -> (original: [String: Any], mapped: [String: Any], types: [String: String]) {
        guard bytes.count > 0, bytes.count <= maximumRecordBytes,
              let original = try PropertyListSerialization.propertyList(from: bytes, options: [], format: nil) as? [String: Any], !original.isEmpty else { throw issue() }
        var mapped: [String: Any] = ["gaomenhu.mail.floating.visible": false, "gaomenhu.mail.floating.showPreviews": false], types: [String: String] = [:]
        for (key, value) in original {
            if windowKeys.contains(key) {
                guard let text = value as? String, windowFrame(text) else { throw issue() }
                types[key] = "string"; continue
            }
            guard key.hasPrefix("gaoyoujian.") else { throw issue() }
            let suffix = String(key.dropFirst("gaoyoujian.".count)); guard suffixes.contains(suffix) else { throw issue() }
            switch suffix {
            case "appearance": guard let text = value as? String, ["system", "light", "dark"].contains(text) else { throw issue() }; types[key] = "string"
            case "sidebarHidden", "floating.visible", "floating.showPreviews":
                guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw issue() }; types[key] = "boolean"
            case "floating.opacity", "floating.horizontalRatio", "floating.verticalRatio":
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite, (0...1).contains(number.doubleValue) else { throw issue() }; types[key] = "number"
            case "floating.display": guard let text = value as? String, text.utf8.count <= 1024, !text.contains("\0") else { throw issue() }; types[key] = "string"
            case "floating.edge": guard let text = value as? String, ["left", "right"].contains(text) else { throw issue() }; types[key] = "string"
            case "floating.dockMode": guard let text = value as? String, ["left", "right", "free"].contains(text) else { throw issue() }; types[key] = "string"
            default: throw issue()
            }
            if !["floating.visible", "floating.showPreviews"].contains(suffix) { mapped["gaomenhu.mail." + suffix] = value }
        }
        return (original, mapped, types)
    }
    private static func keyNames(_ defaults: MailStorageDefaults) throws -> [String] {
        if let defaults = defaults as? UserDefaults { return Array((defaults.persistentDomain(forName: targetBundleID) ?? [:]).keys) }
        if let inventory = defaults as? PortalMailUIOnlyBootstrapKeyInventory { return inventory.bootstrapPreferenceKeyNames() }
        throw issue()
    }
    private static func targetEmpty(_ paths: Paths, defaults: MailStorageDefaults) throws {
        _ = try absence(paths.target); _ = try absence(MailStorage.markerURL(root: paths.target))
        let known = [MailStorage.evidenceKey(root: paths.target), migrationKey(paths.target), submissionKey(paths.target), evidenceKey(destinationRootURL: paths.target)]
        guard known.allSatisfy({ defaults.object(forKey: $0) == nil }),
              try keyNames(defaults).allSatisfy({ !$0.hasPrefix("gaomenhu.mail.") && !$0.hasPrefix("GaoMenHu.Mail") }) else { throw issue() }
        let parent = try directory(paths.target.deletingLastPathComponent()); defer { close(parent) }
        let info = try metadata(parent)
        guard info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw issue() }
        for name in try FileManager.default.contentsOfDirectory(atPath: paths.target.deletingLastPathComponent().path) {
            guard !name.hasPrefix(".MailCenter-Migration-"), !name.hasPrefix(".MailCenter-UIBootstrap-"), !name.hasPrefix(".MailCenter-UIOnlyBootstrap-") else { throw issue() }
        }
        let reopened = try directory(paths.target.deletingLastPathComponent()); defer { close(reopened) }
        guard sameDirectory(info, try metadata(reopened)) else { throw issue() }
    }
    static func plan(homeURL: URL, sourcePreferencesExport: Data, targetDefaults: MailStorageDefaults) throws -> PortalMailUIOnlyBootstrapPlan {
        let paths = try Paths(homeURL: homeURL)
        let exported = try preferences(sourcePreferencesExport)
        let disk = try readRecord(paths.preferences, privateOnly: false), physical = try preferences(disk.data)
        guard NSDictionary(dictionary: exported.original).isEqual(to: physical.original) else { throw issue() }
        let absences = try paths.absent.map(absence)
        try targetEmpty(paths, defaults: targetDefaults)
        guard try paths.absent.map(absence) == absences, try readRecord(paths.preferences, privateOnly: false).identity == disk.identity else { throw issue() }
        return PortalMailUIOnlyBootstrapPlan(schemaVersion: 1, operation: operation, sourceRoot: paths.source.path, targetRoot: paths.target.path,
            sourcePreferencesPath: paths.preferences.path, sourcePreferencesSHA256: digest(sourcePreferencesExport),
            sourcePreferencesFileSHA256: digest(disk.data), sourcePreferencesFileIdentity: disk.identity, absences: absences,
            preferenceKeyTypes: exported.types, mappedPreferenceKeys: exported.mapped.keys.sorted(),
            ignoredWindowPreferenceKeys: exported.original.keys.filter { windowKeys.contains($0) }.sorted(), newLibrary: true, dataMigrated: false)
    }
    private static func json(_ bytes: Data) throws -> [String: Any] {
        guard bytes.count > 0, bytes.count <= maximumRecordBytes, let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw issue() }; return object
    }
    private static func boolean(_ object: [String: Any], _ key: String, _ expected: Bool) -> Bool {
        guard let number = object[key] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }; return number.boolValue == expected
    }
    private static func proofIdentity(_ object: [String: Any], authority: PortalMailUIOnlyBootstrapAuthority) -> Bool {
        guard let version = object["schemaVersion"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(), version.intValue == 1, version.doubleValue == 1 else { return false }
        return (object["operation"] as? String) == operation
            && (object["bootstrapID"] as? String).flatMap(UUID.init(uuidString:)) == authority.bootstrapID
            && (object["sourceBundleID"] as? String) == sourceBundleID && (object["targetBundleID"] as? String) == targetBundleID
            && (object["sourceRoot"] as? String) == authority.sourceRoot && (object["targetRoot"] as? String) == authority.targetRoot
    }
    private static func humanAuthorizationFact(_ wrapper: [String: Any], trustedSHA256: String) throws -> String {
        // The trust anchor is provided independently by the private compiled
        // coordinator CLI (or a synthetic test). A wrapper cannot choose it.
        guard trustedSHA256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              wrapper["actualHumanAuthorizationFactSHA256"] as? String == trustedSHA256,
              let path = wrapper["actualHumanAuthorizationFactPath"] as? String else { throw issue() }
        let bytes = try readRecord(absoluteRecordURL(path)).data
        guard digest(bytes) == trustedSHA256 else { throw issue() }
        let fact = try json(bytes)
        guard let version = fact["schemaVersion"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1,
              fact["kind"] as? String == "GaoSeriesHumanExplicitScopeAuthorization", fact["operation"] as? String == operation,
              fact["sourceBundleID"] as? String == sourceBundleID, fact["targetBundleID"] as? String == targetBundleID,
              boolean(fact, "newLibrary", true), boolean(fact, "dataMigrated", false),
              boolean(fact, "notProofOfNeverHavingAnAccount", true),
              boolean(fact, "doesNotCertifyWritersFrozenOrBackupsOrCurrentAbsence", true) else { throw issue() }
        for field in ["questionCall", "humanAnswer", "scope"] {
            guard let value = fact[field] as? String, !value.isEmpty, value.utf8.count <= 16_384 else { throw issue() }
        }
        return trustedSHA256
    }
    private static func validateProofs(authority: PortalMailUIOnlyBootstrapAuthority, plan: PortalMailUIOnlyBootstrapPlan,
        backupReceipt: Data, userAuthorizationProof: Data, fenceReceipt: Data,
        trustedHumanAuthorizationFactSHA256: String) throws -> (backup: String, human: String) {
        guard authority.schemaVersion == 1, authority.operation == operation, authority.sourceFrozen,
              authority.sourceBundleID == sourceBundleID, authority.targetBundleID == targetBundleID,
              authority.sourceRoot == plan.sourceRoot, authority.targetRoot == plan.targetRoot,
              authority.sourcePreferencesPath == plan.sourcePreferencesPath,
              authority.sourcePreferencesSHA256 == plan.sourcePreferencesSHA256,
              authority.sourcePreferencesFileSHA256 == plan.sourcePreferencesFileSHA256,
              authority.sourcePreferencesFileIdentity == plan.sourcePreferencesFileIdentity,
              authority.absencePlanSHA256 == digest(try encoded(plan)),
              authority.backupReceiptSHA256 == digest(backupReceipt), authority.userAuthorizationProofSHA256 == digest(userAuthorizationProof),
              authority.fenceReceiptSHA256 == digest(fenceReceipt) else { throw issue() }
        let backup = try json(backupReceipt), human = try json(userAuthorizationProof), fence = try json(fenceReceipt)
        guard proofIdentity(backup, authority: authority), proofIdentity(human, authority: authority), proofIdentity(fence, authority: authority),
              boolean(backup, "fullCurrentBackupRestoreVerified", true),
              backup["sourceUIPreferencesSHA256"] as? String == plan.sourcePreferencesSHA256,
              backup["sourceUIPreferencesFileSHA256"] as? String == plan.sourcePreferencesFileSHA256,
              backup["absentSourcePaths"] as? [String] == plan.absences.map(\.path),
              boolean(human, "explicitHumanAuthorization", true), boolean(human, "newLibrary", true), boolean(human, "dataMigrated", false),
              human["decision"] as? String == "authorize-new-empty-mail-library-and-ui-preferences-only",
              let reference = human["humanMessageReference"] as? String, !reference.isEmpty, reference.utf8.count <= 4096,
              boolean(fence, "sourceFrozen", true), boolean(fence, "hostStopped", true), boolean(fence, "noSourceWriterObserved", true),
              boolean(fence, "sourceFormalApplicationAbsentOrIsolated", true),
              let actualPath = backup["actualBackupReceiptPath"] as? String, let actualHash = backup["actualBackupReceiptSHA256"] as? String,
              let fencePath = fence["actualFenceReceiptPath"] as? String, let fenceHash = fence["actualFenceReceiptSHA256"] as? String else { throw issue() }
        let actual = try readRecord(absoluteRecordURL(actualPath)).data
        let actualFence = try readRecord(absoluteRecordURL(fencePath)).data
        _ = try json(actual); _ = try json(actualFence)
        guard digest(actual) == actualHash, digest(actualFence) == fenceHash else { throw issue() }
        return (actualHash, try humanAuthorizationFact(human, trustedSHA256: trustedHumanAuthorizationFactSHA256))
    }
    private static func save(_ state: State, defaults: MailStorageDefaults, key: String) throws {
        let bytes = try encoded(state); defaults.set(bytes, forKey: key)
        guard defaults.synchronize(), defaults.object(forKey: key) as? Data == bytes else { throw issue() }
    }
    /// Every source observation is repeated before any target/defaults write,
    /// immediately before MailStorage initialization, and before final commit.
    /// A failure keeps all evidence; no automatic cleanup/retry or rebaseline.
    static func prepare(homeURL: URL, sourcePreferencesExport: () throws -> Data, authorityBytes: Data,
        backupReceipt: Data, userAuthorizationProof: Data, fenceReceipt: Data, targetDefaults: MailStorageDefaults,
        trustedHumanAuthorizationFactSHA256: String,
        operationalGuard: () throws -> Void,
        checkpoint: ((String) throws -> Void)? = nil) throws -> PortalMailUIOnlyBootstrapReceipt {
        try operationalGuard()
        let paths = try Paths(homeURL: homeURL), firstExport = try sourcePreferencesExport()
        let first = try plan(homeURL: homeURL, sourcePreferencesExport: firstExport, targetDefaults: targetDefaults)
        let authority = try JSONDecoder().decode(PortalMailUIOnlyBootstrapAuthority.self, from: authorityBytes)
        let actualProofs = try validateProofs(authority: authority, plan: first, backupReceipt: backupReceipt,
            userAuthorizationProof: userAuthorizationProof, fenceReceipt: fenceReceipt,
            trustedHumanAuthorizationFactSHA256: trustedHumanAuthorizationFactSHA256)
        let parent = try directory(paths.target.deletingLastPathComponent()); defer { close(parent) }
        let parentIdentity = try metadata(parent)
        // Lock the existing parent FD, creating no filesystem entry before the
        // durable preparing intent. There is no lock-file unlink race.
        guard flock(parent, LOCK_EX | LOCK_NB) == 0 else { throw issue() }
        try checkpoint?("beforeIntent")
        try operationalGuard()
        guard try plan(homeURL: homeURL, sourcePreferencesExport: sourcePreferencesExport(), targetDefaults: targetDefaults) == first else { throw issue() }
        let key = evidenceKey(destinationRootURL: paths.target)
        var state = State(schemaVersion: 1, operation: operation, bootstrapID: authority.bootstrapID,
            sourceRoot: paths.source.path, targetRoot: paths.target.path, phase: "preparing", receiptSHA256: nil, storageMarkerSHA256: nil)
        try save(state, defaults: targetDefaults, key: key)
        try checkpoint?("afterIntent")
        func verifySource() throws {
            _ = try humanAuthorizationFact(json(userAuthorizationProof), trustedSHA256: trustedHumanAuthorizationFactSHA256)
            let nextExport = try sourcePreferencesExport(), disk = try readRecord(paths.preferences, privateOnly: false)
            _ = try preferences(nextExport); _ = try preferences(disk.data)
            guard digest(nextExport) == first.sourcePreferencesSHA256, digest(disk.data) == first.sourcePreferencesFileSHA256,
                  disk.identity == first.sourcePreferencesFileIdentity, try paths.absent.map(absence) == first.absences else { throw issue() }
            let reopened = try directory(paths.target.deletingLastPathComponent()); defer { close(reopened) }
            guard sameDirectory(parentIdentity, try metadata(reopened)) else { throw issue() }
        }
        try operationalGuard()
        try verifySource()
        _ = try absence(paths.target); _ = try absence(MailStorage.markerURL(root: paths.target))
        guard targetDefaults.object(forKey: MailStorage.evidenceKey(root: paths.target)) == nil,
              targetDefaults.object(forKey: migrationKey(paths.target)) == nil,
              targetDefaults.object(forKey: submissionKey(paths.target)) == nil else { throw issue() }
        let storage = MailStorage(root: paths.target, evidenceDefaults: targetDefaults)
        _ = storage.load(); guard storage.readFailure == nil else { throw issue() }
        try storage.save(MailStorage.emptyLibrary()); try storage.verifyAvailability()
        let library = storage.load(), messages = storage.loadMessages()
        guard storage.readFailure == nil, storage.cacheWarning == nil, library.accounts.isEmpty, library.identities.isEmpty,
              library.platforms.isEmpty, library.drafts.isEmpty, messages.isEmpty else { throw issue() }
        try checkpoint?("afterLibrary")
        try verifySource(); try storage.verifyAvailability()
        let mapped = try preferences(firstExport).mapped
        for name in mapped.keys.sorted() {
            guard targetDefaults.object(forKey: name) == nil else { throw issue() }
            targetDefaults.set(mapped[name], forKey: name)
        }
        guard targetDefaults.synchronize(), mapped.allSatisfy({ name, value in
            guard let current = targetDefaults.object(forKey: name) else { return false }
            return NSDictionary(dictionary: [name: value]).isEqual(to: [name: current])
        }) else { throw issue() }
        let marker = try readRecord(MailStorage.markerURL(root: paths.target), maximum: 4096).data
        guard targetDefaults.object(forKey: MailStorage.evidenceKey(root: paths.target)) as? Data == marker else { throw issue() }
        let receipt = PortalMailUIOnlyBootstrapReceipt(schemaVersion: 1, operation: operation, bootstrapID: authority.bootstrapID,
            sourceBundleID: sourceBundleID, targetBundleID: targetBundleID, sourceRoot: paths.source.path, targetRoot: paths.target.path,
            plan: first, authoritySHA256: digest(authorityBytes), backupReceiptSHA256: digest(backupReceipt), actualBackupReceiptSHA256: actualProofs.backup,
            userAuthorizationProofSHA256: digest(userAuthorizationProof), actualHumanAuthorizationFactSHA256: actualProofs.human,
            fenceReceiptSHA256: digest(fenceReceipt), newLibrary: true, dataMigrated: false,
            initialIdentityCount: library.identities.count, initialAccountCount: library.accounts.count, initialPlatformCount: library.platforms.count,
            initialDraftCount: library.drafts.count, initialMessageCount: messages.count, storageMarkerSHA256: digest(marker),
            credentialServicePreserved: "com.gaoseries.GaoYouJian.credentials", keychainAccessed: false, sourceBusinessDataReadOrRestored: false,
            sourceUIPreferencesRead: true, compatibleUISettingsCopied: true,
            externalBackupVerificationIsRootAttestation: true, createdAt: Date())
        let root = try directory(paths.target); defer { close(root) }
        guard mkdirat(root, "UIOnlyBootstrapEvidence", 0o700) == 0, fsync(root) == 0 else { throw issue() }
        let receiptBytes = try encoded(receipt)
        try writeNew(receiptBytes, to: paths.target.appendingPathComponent(receiptRelativePath))
        try checkpoint?("afterReceipt")
        try operationalGuard()
        try verifySource(); try storage.verifyAvailability()
        guard try readRecord(paths.target.appendingPathComponent(receiptRelativePath)).data == receiptBytes else { throw issue() }
        state.phase = "committed"; state.receiptSHA256 = digest(receiptBytes); state.storageMarkerSHA256 = digest(marker)
        try save(state, defaults: targetDefaults, key: key)
        // A failed final defaults synchronize may leave an in-memory committed
        // value. Only after it succeeds is this independent durable seal made;
        // readiness requires both, so that failed commit is never ready.
        let seal = CommitSeal(schemaVersion: 1, operation: operation, bootstrapID: state.bootstrapID,
            stateSHA256: digest(try encoded(state)), receiptSHA256: digest(receiptBytes))
        try writeNew(encoded(seal), to: paths.target.appendingPathComponent("UIOnlyBootstrapEvidence/committed.json"))
        return receipt
    }
    static func readiness(destinationRootURL: URL, legacyRootURL: URL, targetDefaults: MailStorageDefaults = UserDefaults.standard) -> PortalMailUIOnlyBootstrapReadiness {
        do {
            let target = try physical(destinationRootURL), source = try physical(legacyRootURL), key = evidenceKey(destinationRootURL: target)
            guard let external = targetDefaults.object(forKey: key) else {
                // A deleted independent anchor must not conceal a surviving
                // bootstrap receipt, including an empty evidence directory.
                guard !(try existsWithoutLinks(target.appendingPathComponent("UIOnlyBootstrapEvidence"))) else { throw issue() }
                return .absent
            }
            guard let bytes = external as? Data, bytes.count <= maximumRecordBytes else { throw issue() }
            let state = try JSONDecoder().decode(State.self, from: bytes)
            guard state.schemaVersion == 1, state.operation == operation, state.sourceRoot == source.path, state.targetRoot == target.path,
                  state.phase == "committed", targetDefaults.object(forKey: migrationKey(target)) == nil else { throw issue() }
            let receiptBytes = try readRecord(target.appendingPathComponent(receiptRelativePath)).data
            let receipt = try JSONDecoder().decode(PortalMailUIOnlyBootstrapReceipt.self, from: receiptBytes)
            let seal = try JSONDecoder().decode(CommitSeal.self, from: readRecord(target.appendingPathComponent("UIOnlyBootstrapEvidence/committed.json"), maximum: 4096).data)
            let marker = try readRecord(MailStorage.markerURL(root: target), maximum: 4096).data
            let declared = try JSONDecoder().decode(Marker.self, from: marker)
            guard digest(receiptBytes) == state.receiptSHA256, digest(marker) == state.storageMarkerSHA256,
                  seal.schemaVersion == 1, seal.operation == operation, seal.bootstrapID == state.bootstrapID,
                  seal.stateSHA256 == digest(bytes), seal.receiptSHA256 == digest(receiptBytes),
                  declared.schemaVersion == 1, receipt.schemaVersion == 1, receipt.operation == operation,
                  receipt.bootstrapID == state.bootstrapID, receipt.sourceBundleID == sourceBundleID, receipt.targetBundleID == targetBundleID,
                  receipt.sourceRoot == source.path, receipt.targetRoot == target.path, receipt.newLibrary, !receipt.dataMigrated,
                  receipt.storageMarkerSHA256 == digest(marker), receipt.initialIdentityCount == 0, receipt.initialAccountCount == 0,
                  receipt.initialPlatformCount == 0, receipt.initialDraftCount == 0, receipt.initialMessageCount == 0,
                  targetDefaults.object(forKey: MailStorage.evidenceKey(root: target)) as? Data == marker else { throw issue() }
            let library = try MailStorage.decoder.decode(MailLibrary.self, from: readRecord(target.appendingPathComponent("Library.json"), maximum: 64 * 1024 * 1024).data)
            try MailValidation.validate(library)
            let messages = try MailStorage.validateMessages(readRecord(target.appendingPathComponent("MailCache.json"), maximum: 512 * 1024 * 1024).data)
            let accounts = Set(library.accounts.map(\.id))
            guard messages.allSatisfy({ accounts.contains($0.accountID) }) else { throw issue() }
            // These are current data, not the original empty-library hashes.
            // Old source prefs/proofs/archives need not survive retirement.
            return .ready
        } catch { return .recoveryRequired("邮件界面偏好初始化未完成或独立证据不匹配；保留现有资料，不回退为普通空库初始化。") }
    }
}
