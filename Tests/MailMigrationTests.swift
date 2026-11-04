import Foundation
import Darwin

@main
struct MailMigrationTests {
    static var checks = 0
    static var stage = "setup"
    static func check(_ value: Bool) { precondition(value, "mail migration check \(checks), \(stage)"); checks += 1 }
    static func rejects(_ action: () throws -> Void) {
        do { try action(); fatalError("Unsafe mail migration accepted at \(stage)") } catch { checks += 1 }
    }
    struct Injected: Error {}
    final class MemoryDefaults: MailStorageDefaults {
        var values: [String: Any] = [:]
        func object(forKey key: String) -> Any? { values[key] }
        func set(_ value: Any?, forKey key: String) { values[key] = value }
        func removeObject(forKey key: String) { values.removeValue(forKey: key) }
        func synchronize() -> Bool { true }
    }
    static func privateWrite(_ bytes: Data, to path: URL) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try bytes.write(to: path); guard chmod(path.path, 0o600) == 0 else { throw Injected() }
    }
    static func files(_ root: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for case let path as URL in FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])! {
            if try path.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true { result[String(path.path.dropFirst(root.path.count + 1))] = try Data(contentsOf: path) }
        }
        return result
    }
    struct Fixture {
        let root: URL
        let source: URL
        let target: URL
        let defaults = MemoryDefaults()
        let preferences: Data
        let library: MailLibrary
        let message: CachedMessage?
        let external: URL
        let internalFile: URL
        init(empty: Bool = false, cache: Bool = true, unknown: Bool = false, pending: Bool = false) throws {
            root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("portal-mail-migration-\(UUID().uuidString).noindex", isDirectory: true)
            source = root.appendingPathComponent("Legacy/GaoYouJian", isDirectory: true)
            target = root.appendingPathComponent("MenDao/MailCenter", isDirectory: true)
            external = root.appendingPathComponent("external-unreadable-original.txt")
            internalFile = source.appendingPathComponent("DraftFiles/original.txt")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var value = MailLibrary(); value.identities = []
            if !empty {
                let identity = MailIdentity(name: "合成资料", symbol: "envelope", color: "123456")
                var account = MailAccount(name: "Fixture", email: "fixture@example.invalid", identityID: identity.id)
                account.enabled = true; account.imapHost = "imap.example.invalid"; account.smtpHost = "smtp.example.invalid"
                account.username = account.email; account.lastSync = Date(timeIntervalSince1970: 1_700_000_000)
                value.identities = [identity]; value.accounts = [account]
                let draft = MailDraft(accountID: account.id, from: account.email, to: "recipient@example.invalid", subject: "fixture draft", body: "unsent draft", attachments: [DraftAttachment(path: internalFile.path), DraftAttachment(path: external.path)])
                value.drafts = [draft]
                try MailMigrationTests.privateWrite(Data("owned attachment".utf8), to: internalFile)
                try MailMigrationTests.privateWrite(Data("external original remains unread".utf8), to: external)
                guard chmod(external.path, 0) == 0 else { throw Injected() }
                message = CachedMessage(id: account.id.uuidString + "|INBOX|123|9", accountID: account.id, folder: "INBOX", uid: 9, uidValidity: 123,
                    subject: "fixture mail", from: "sender@example.invalid", to: account.email, cc: "", date: Date(timeIntervalSince1970: 1_700_000_000), preview: "fixture", body: "cached body", html: nil, isRead: false, isFlagged: true, messageID: "<fixture@example.invalid>", references: nil,
                    attachments: [CachedAttachment(filename: "inline.bin", mimeType: "application/octet-stream", data: Data([1, 2, 3, 4]))], loaded: true)
            } else { message = nil }
            library = value
            preferences = try PropertyListSerialization.data(fromPropertyList: ["gaoyoujian.appearance": "dark", "gaoyoujian.floating.visible": true, "gaoyoujian.floating.showPreviews": true, "gaoyoujian.floating.horizontalRatio": 0.75, "gaoyoujian.sidebarHidden": true], format: .binary, options: 0)
            try MailMigrationTests.privateWrite(MailStorage.encoder.encode(value), to: source.appendingPathComponent("Library.json"))
            try MailMigrationTests.privateWrite(MailStorage.encoder.encode(value), to: source.appendingPathComponent("Library.previous.json"))
            if cache { try MailMigrationTests.privateWrite(MailStorage.encoder.encode(message.map { [$0] } ?? []), to: source.appendingPathComponent("MailCache.json")) }
            if unknown { try MailMigrationTests.privateWrite(Data("opaque retained evidence".utf8), to: source.appendingPathComponent("future-evidence.bin")) }
            if pending {
                let journal = OAuthAdditionJournal(accountID: value.accounts[0].id, transactionID: UUID())
                try MailMigrationTests.privateWrite(MailStorage.encoder.encode(journal), to: source.appendingPathComponent(".OAuthAddition.\(journal.transactionID.uuidString).json"))
                try MailMigrationTests.privateWrite(MailStorage.encoder.encode(value), to: source.appendingPathComponent(".Library.\(UUID().uuidString).pending"))
            }
        }
        func cleanup() { try? chmod(external.path, 0o600); try? FileManager.default.removeItem(at: root) }
        func authority(frozen: Bool = true) throws -> PortalMailMigrationAuthority {
            let plan = try PortalMailMigration.preflight(legacyRootURL: source, sourcePreferences: preferences)
            return PortalMailMigrationAuthority(schemaVersion: 1, sourceBundleID: "com.gaoseries.GaoYouJian", targetBundleID: "cn.mendao.launcher", sourceFrozen: frozen,
                sourceRoot: source.path, targetRoot: target.path, sourceManifestSHA256: plan.sourceManifestSHA256,
                sourceLibrarySHA256: plan.sourceLibrarySHA256, sourcePreferencesSHA256: plan.sourcePreferencesSHA256,
                backupReceiptSHA256: String(repeating: "a", count: 64))
        }
        func apply(_ authority: PortalMailMigrationAuthority, fault: ((String) throws -> Void)? = nil) throws -> PortalMailMigrationReceipt {
            try PortalMailMigration.prepare(destinationRootURL: target, legacyRootURL: source, sourcePreferences: preferences, authority: authority, targetDefaults: defaults, fault: fault)
        }
        func readiness(_ data: Data? = nil) -> PortalMailMigrationReadiness {
            PortalMailMigration.readiness(destinationRootURL: target, legacyRootURL: source, sourcePreferences: data ?? preferences, targetDefaults: defaults)
        }
    }
    static func main() {
        setbuf(stdout, nil)
        do { try run() }
        catch { fputs("Mail migration failure: checks=\(checks), stage=\(stage), error=\(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func run() throws {
        stage = "complete source, mapping, cache-only gate, preserved opaque evidence"
        do {
            let f = try Fixture(unknown: true, pending: true); defer { f.cleanup() }
            let before = try files(f.source), authorization = try f.authority()
            check(f.readiness() == .requiresMigration)
            let plan = try PortalMailMigration.preflight(legacyRootURL: f.source, sourcePreferences: f.preferences)
            check(plan.accountCount == 1 && plan.draftCount == 1 && plan.messageCount == 1)
            check(plan.embeddedAttachmentCount == 1 && plan.externalDraftAttachmentCount == 1)
            check(plan.pendingOAuthTransactionCount == 1 && plan.unrecognizedFileCount == 1)
            check(try files(f.source) == before)
            let keyBefore = PortalMailMigration.evidenceKey(destinationRootURL: f.target)
            let receipt = try f.apply(authorization)
            check(receipt.accountIDs == f.library.accounts.map(\.id) && receipt.draftIDs == f.library.drafts.map(\.id))
            check(receipt.cachedMessageIDs == [f.message!.id] && receipt.originalEnabledAccountIDs == f.library.accounts.map(\.id))
            check(receipt.credentialServicePreserved == "com.gaoseries.GaoYouJian.credentials" && receipt.newHostConnectionAuthorizationRequired)
            check(receipt.pendingOAuthTransactionIDs.count == 1 && receipt.unrecognizedFilesPreservedWithoutSchemaCertification == ["future-evidence.bin"])
            check(receipt.externalDraftAttachmentPathsRequireAuthorization == [f.external.path])
            check(receipt.attachmentPathMappings[f.internalFile.path] == f.target.appendingPathComponent("DraftFiles/original.txt").path)
            check(try files(f.source) == before)
            let imported = try MailStorage.decoder.decode(MailLibrary.self, from: Data(contentsOf: f.target.appendingPathComponent("Library.json")))
            check(imported.accounts == f.library.accounts && imported.identities == f.library.identities)
            check(imported.preferences == f.library.preferences && imported.platforms == f.library.platforms)
            check(imported.drafts[0].id == f.library.drafts[0].id && imported.drafts[0].body == f.library.drafts[0].body)
            check(imported.drafts[0].attachments[0].id == f.library.drafts[0].attachments[0].id)
            check(imported.drafts[0].attachments[1].path == f.external.path)
            let cache = try MailStorage.decoder.decode([CachedMessage].self, from: Data(contentsOf: f.target.appendingPathComponent("MailCache.json")))
            check(cache == [f.message!] && cache[0].uid == 9 && cache[0].uidValidity == 123 && !cache[0].isRead)
            check((f.defaults.object(forKey: "gaomenhu.mail.floating.visible") as? Bool) == false)
            check((f.defaults.object(forKey: "gaomenhu.mail.floating.showPreviews") as? Bool) == false)
            check((f.defaults.object(forKey: "gaomenhu.mail.appearance") as? String) == "dark")
            check(f.readiness() == .ready && PortalMailMigration.evidenceKey(destinationRootURL: f.target) == keyBefore)
            do {
                let storage = MailStorage(root: f.target, evidenceDefaults: f.defaults)
                check(storage.load().accounts == f.library.accounts && storage.readFailure == nil)
                check(storage.loadMessages() == [f.message!] && storage.cacheWarning == nil)
            }
            let saved = try files(f.target); check(try f.apply(authorization) == receipt); check(try files(f.target) == saved)
            check(!FileManager.default.fileExists(atPath: f.target.appendingPathComponent("external-unreadable-original.txt").path))
        }
        stage = "atomic commit interruption replay"
        for point in ["mail.validated", "mail.rootPublished", "mail.markerPublished", "mail.evidencePublished"] {
            let f = try Fixture(); defer { f.cleanup() }
            let authority = try f.authority()
            rejects { _ = try f.apply(authority, fault: { if $0 == point { throw Injected() } }) }
            if case .recoveryRequired = f.readiness() { checks += 1 } else { fatalError("Pending migration not blocked") }
            let receipt = try f.apply(authority)
            check(receipt.accountIDs.count == 1 && receipt.draftIDs.count == 1 && f.readiness() == .ready)
        }
        stage = "interrupted preparation retained"
        for point in ["mail.preparing", "mail.copied"] {
            let f = try Fixture(); defer { f.cleanup() }
            let authority = try f.authority(), before = try files(f.source)
            rejects { _ = try f.apply(authority, fault: { if $0 == point { throw Injected() } }) }
            rejects { _ = try f.apply(authority) }
            let sourceUnchanged = try files(f.source) == before
            check(!FileManager.default.fileExists(atPath: f.target.path) && sourceUnchanged)
        }
        stage = "source frozen and stale plan"
        do {
            let f = try Fixture(); defer { f.cleanup() }
            let stale = try f.authority()
            rejects { _ = try f.apply(f.authority(frozen: false)) }
            check(f.defaults.object(forKey: PortalMailMigration.evidenceKey(destinationRootURL: f.target)) == nil)
            try privateWrite(Data("changed".utf8), to: f.internalFile)
            rejects { _ = try f.apply(stale) }
            check(f.defaults.object(forKey: PortalMailMigration.evidenceKey(destinationRootURL: f.target)) == nil)
        }
        stage = "missing source, known future formats, corrupt cache and attachment"
        do {
            let f = try Fixture(); defer { f.cleanup() }
            try FileManager.default.removeItem(at: f.source.appendingPathComponent("Library.json"))
            if case .recoveryRequired = f.readiness() { checks += 1 } else { fatalError("Missing library interpreted as empty") }
            rejects { _ = try f.authority() }
        }
        do {
            let f = try Fixture(); defer { f.cleanup() }
            var object = try JSONSerialization.jsonObject(with: Data(contentsOf: f.source.appendingPathComponent("Library.json"))) as! [String: Any]
            object["schemaVersion"] = 99
            try privateWrite(JSONSerialization.data(withJSONObject: object), to: f.source.appendingPathComponent("Library.json"))
            rejects { _ = try f.authority() }
        }
        do {
            let f = try Fixture(); defer { f.cleanup() }
            try privateWrite(Data("bad-cache".utf8), to: f.source.appendingPathComponent("MailCache.json"))
            rejects { _ = try f.authority() }
        }
        do {
            let f = try Fixture(); defer { f.cleanup() }
            try FileManager.default.removeItem(at: f.internalFile)
            rejects { _ = try f.authority() }
        }
        do {
            let f = try Fixture(); defer { f.cleanup() }
            try FileManager.default.removeItem(at: f.source)
            if case .recoveryRequired = f.readiness() { checks += 1 } else { fatalError("Missing initialized source interpreted as first use") }
        }
        stage = "Library runtime budget, including known recovery snapshots"
        for name in ["Library.json", "Library.previous.json", "BeforeRestore-budget.json", ".Library.\(UUID().uuidString).pending"] {
            let f = try Fixture(); defer { f.cleanup() }
            let authority = try f.authority(), file = f.source.appendingPathComponent(name)
            // Sparse bytes intentionally need no large JSON allocation. Assert the
            // byte-budget error specifically, rather than a later JSON error.
            let fd = open(file.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw Injected() }
            let resized = ftruncate(fd, off_t(65 * 1024 * 1024)); close(fd)
            guard resized == 0 else { throw Injected() }
            var before = stat(); guard lstat(file.path, &before) == 0 else { throw Injected() }
            let attempts: [() throws -> Void] = [
                { _ = try PortalMailMigration.preflight(legacyRootURL: f.source, sourcePreferences: f.preferences) },
                { _ = try f.apply(authority) }
            ]
            for attempt in attempts {
                do { try attempt(); fatalError("Oversized Library accepted") }
                catch { check(error.localizedDescription == "邮件资料文件超出安全大小上限（67108864 字节），未读取或迁入。") }
            }
            var after = stat(); guard lstat(file.path, &after) == 0 else { throw Injected() }
            check(before.st_dev == after.st_dev && before.st_ino == after.st_ino && before.st_size == after.st_size
                && before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec)
            check(!FileManager.default.fileExists(atPath: f.target.path)
                && f.defaults.object(forKey: PortalMailMigration.evidenceKey(destinationRootURL: f.target)) == nil)
        }
        stage = "safe cache absence and symlink refusal"
        do {
            let f = try Fixture(empty: true, cache: false); defer { f.cleanup() }
            let receipt = try f.apply(f.authority())
            check(receipt.initializedCacheFromVerifiedAbsence && receipt.accountIDs.isEmpty)
            check(try MailStorage.decoder.decode([CachedMessage].self, from: Data(contentsOf: f.target.appendingPathComponent("MailCache.json"))).isEmpty)
        }
        do {
            let f = try Fixture(cache: false); defer { f.cleanup() }
            rejects { _ = try f.authority() }
        }
        do {
            let f = try Fixture(); defer { f.cleanup() }
            let link = f.source.appendingPathComponent("linked.txt")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.external)
            rejects { _ = try f.authority() }
        }
        stage = "new host preference conflict remains recovery"
        do {
            let f = try Fixture(); defer { f.cleanup() }
            let authority = try f.authority()
            f.defaults.set("light", forKey: "gaomenhu.mail.appearance")
            rejects { _ = try f.apply(authority) }
            check((f.defaults.object(forKey: "gaomenhu.mail.appearance") as? String) == "light")
            if case .recoveryRequired = f.readiness() { checks += 1 } else { fatalError("Preference conflict opened writer") }
        }
        print("Mail migration: \(checks) isolated checks passed; no real mail, Keychain, server connection, send or app window used.")
    }
}
