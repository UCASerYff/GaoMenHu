import Foundation
import Darwin

private final class MailMemoryDefaults: MailStorageDefaults {
    var values: [String: Any] = [:]
    var failSubmissionEvidence = false
    private var lastKey = ""
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value; lastKey = key }
    func removeObject(forKey key: String) { values[key] = nil }
    func synchronize() -> Bool { !(failSubmissionEvidence && lastKey.hasPrefix("GaoMenHu.MailSubmissionEvidence.")) }
}
private final class MailMemoryCredentials {
    var reads = 0, writes = 0, deletions = 0
    var items: [String: Data] = [:]
    var backend: OAuthCredentialStorage {
        OAuthCredentialStorage(read: { key in self.reads += 1; return self.items[key] },
            save: { data, key in self.writes += 1; self.items[key] = data }, insert: { data, key in self.writes += 1; self.items[key] = data },
            delete: { key in self.deletions += 1; self.items[key] = nil })
    }
}
@main @MainActor struct MailEmbeddedCoreTests {
    static var checks = 0
    static func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try value() else { throw MailAppError.message("失败：" + label) }; checks += 1; print("PASS \(checks) \(label)")
    }
    static func reject(_ label: String, _ work: () throws -> Void) throws {
        do { try work() } catch { checks += 1; print("PASS \(checks) \(label)"); return }; throw MailAppError.message("应拒绝：" + label)
    }
    static func rejectAsync(_ label: String, _ work: () async throws -> Void) async throws {
        do { try await work() } catch { checks += 1; print("PASS \(checks) \(label)"); return }
        throw MailAppError.message("应拒绝：" + label)
    }
    static func main() async {
        setbuf(stdout, nil)
        do { try await run(); print("Embedded native mail core: \(checks) isolated checks passed; no Keychain, GUI, browser or external connection.") }
        catch { fputs("Mail embedded core failure: \(error)\n", stderr); exit(1) }
    }
    static func run() async throws {
        let fm = FileManager.default, parent = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        guard parent.path.contains(".noindex/") else { throw MailAppError.message("测试根必须位于预建.noindex容器。") }
        try fm.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var sequence = 0
        func location() -> URL { sequence += 1; return parent.appendingPathComponent("MailCenter-" + String(sequence), isDirectory: true) }
        func fixture(_ root: URL, _ defaults: MailMemoryDefaults) throws -> MailAccount {
            let storage = MailStorage(root: root, evidenceDefaults: defaults)
            var library = storage.load(); guard storage.readFailure == nil else { throw MailAppError.message(storage.readFailure!) }
            var account = MailAccount(email: "mail-fixture@example.invalid", provider: .gmail)
            account.applyProvider(); account.enabled = true
            library.accounts.append(account); library.preferences.googleClientID = "synthetic-client-id"
            library.drafts = [MailDraft(accountID: account.id, from: account.email, to: "recipient@example.invalid", body: "private fixture draft")]
            try storage.save(library)
            let message = CachedMessage(id: account.id.uuidString + "|INBOX|42|1", accountID: account.id, folder: "INBOX", uid: 1,
                subject: "fixture cached subject", from: "sender@example.invalid", to: account.email, cc: "", date: Date(), preview: "cached",
                body: "fixture cached body", html: nil, isRead: false, isFlagged: false, messageID: "<fixture@example.invalid>", references: nil,
                attachments: [CachedAttachment(filename: "fixture.bin", mimeType: "application/octet-stream", data: Data([1,2,3]))], loaded: true)
            try storage.saveMessages([message]); return account
        }
        do {
            let root = location(), defaults = MailMemoryDefaults()
            let blocked = MailStore(root: root, startTimer: false, blockedBecause: "fixture migration pending", evidenceDefaults: defaults,
                readGoogleClientSecret: { throw MailAppError.message("must not read") })
            try check(blocked.problem != nil && blocked.library.accounts.isEmpty && blocked.library.identities.isEmpty, "迁移待复核只读界面不造默认资料")
            try check(!fm.fileExists(atPath: root.path) && defaults.values.isEmpty, "blocked构造不创建目录或初始化证据")
            blocked.prepareForApplicationExit(); try check(!fm.fileExists(atPath: root.path), "退出准备仅停计时不初始化")
        }
        do {
            let root = location(), defaults = MailMemoryDefaults(), account = try fixture(root, defaults)
            let originalLibrary = try Data(contentsOf: root.appendingPathComponent("Library.json"))
            let originalCache = try Data(contentsOf: root.appendingPathComponent("MailCache.json"))
            let journal = OAuthAdditionJournal(accountID: UUID(), transactionID: UUID())
            let journalURL = root.appendingPathComponent(".OAuthAddition." + journal.transactionID.uuidString + ".json")
            try MailStorage.encoder.encode(journal).write(to: journalURL, options: .withoutOverwriting)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
            let credentials = MailMemoryCredentials(); var secretReads = 0, browserOpens = 0
            let oauth = OAuthManager(credentials: credentials.backend, openBrowser: { _ in browserOpens += 1; return false })
            do {
                let store = MailStore(root: root, oauth: oauth, startTimer: false, evidenceDefaults: defaults, readGoogleClientSecret: { secretReads += 1; return nil })
                try check(store.library.accounts[0].id == account.id && store.messages.count == 1 && store.library.drafts.count == 1, "本机账号UUID缓存与草稿原样加载")
                try check(store.messages[0].attachments[0].data == Data([1,2,3]) && !store.messages[0].isRead, "缓存附件字节及未读状态保留")
                try check(credentials.reads == 0 && credentials.writes == 0 && credentials.deletions == 0 && secretReads == 0 && browserOpens == 0, "初次打开不读写Keychain/secret或触发浏览器")
                try check(fm.fileExists(atPath: journalURL.path), "旧OAuth事务不在打开时自动回滚或删除")
                do { _ = try await store.connection(for: account); try check(false, "未授权连接不能通过") } catch { checks += 1 }
                await store.syncAll()
                try check(credentials.reads == 0 && secretReads == 0 && store.folders.isEmpty, "未连接账号批量同步同样不取凭据或联网")
                do { _ = try await store.addAccountUsingBrowser(provider: .google); try check(false, "旧pending事务不能静默当新请求") } catch { checks += 1 }
                try check(credentials.deletions == 0 && credentials.reads == 0 && secretReads == 0 && browserOpens == 0, "新增流程对旧恢复事务停下且不清凭据")
                try store.authorizeHostConnection(accountID: account.id)
                try check(store.isHostConnectionAuthorized(accountID: account.id), "本人连接动作可授权精确现有账号")
                do { _ = try await store.connection(for: account); try check(false, "fixture没有凭据不应假造连接") } catch { checks += 1 }
                try check(credentials.reads == 1 && credentials.writes == 0 && credentials.deletions == 0, "仅明确连接后才可读注入凭据且缺失如实失败")
                let originalPreferences = store.library.preferences
                var preferences = originalPreferences; preferences.fetchLimit = 40; preferences.syncMinutes = 7
                try store.updatePreferences(preferences)
                try check(store.isHostConnectionAuthorized(accountID: account.id), "调整同步数量间隔保留本次主机授权")
                preferences.googleClientID = "different-synthetic-client"
                try store.updatePreferences(preferences)
                try check(!store.isHostConnectionAuthorized(accountID: account.id), "更换Google客户端ID撤销精确账号本次授权")
                let readsBeforeConfigurationRetry = credentials.reads
                do { _ = try await store.connection(for: account); try check(false, "新OAuth配置须再次确认") } catch { checks += 1 }
                try check(credentials.reads == readsBeforeConfigurationRetry, "OAuth设置变化后不自动读取或刷新原凭据")
                try store.updatePreferences(originalPreferences)
                try check(!store.isHostConnectionAuthorized(accountID: account.id), "回改旧配置也不能静默恢复已清除的授权")
                try store.authorizeHostConnection(accountID: account.id)
                store.library.accounts[0].imapHost = "changed.fixture.invalid"
                let changed = store.library.accounts[0], priorReads = credentials.reads
                do { _ = try await store.connection(for: changed); try check(false, "配置改变须再次确认") } catch { checks += 1 }
                try check(credentials.reads == priorReads, "服务器配置变化不能复用旧主机授权")
                try check(try store.pendingOAuthAdditionCount() == 1, "显式恢复审查可以只读列出未完成事务数量")
                try store.recoverPendingOAuthAdditionsAfterConfirmation()
                try check(!fm.fileExists(atPath: journalURL.path) && credentials.deletions == 0, "本人明确审查后无遗留凭据的事务可结束，不删其他凭据")
                store.prepareForApplicationExit()
            }
            do {
                let reopened = MailStore(root: root, oauth: oauth, startTimer: false, evidenceDefaults: defaults, readGoogleClientSecret: { nil })
                try check(!reopened.isHostConnectionAuthorized(accountID: account.id), "重新打开原enabled账号仍需本进程明确连接")
                reopened.prepareForApplicationExit()
            }
            try check(try Data(contentsOf: root.appendingPathComponent("Library.json")) == originalLibrary && Data(contentsOf: root.appendingPathComponent("MailCache.json")) == originalCache,
                      "缓存浏览与失败连接不改原资料字节")
        }
        do {
            let root = location(), defaults = MailMemoryDefaults(); _ = try fixture(root, defaults)
            var account: MailAccount!
            do {
                let storage = MailStorage(root: root, evidenceDefaults: defaults); var library = storage.load()
                library.accounts[0].provider = .outlook; library.accounts[0].applyProvider()
                library.preferences.microsoftClientID = "synthetic-microsoft-client"; library.preferences.microsoftTenant = "common"
                account = library.accounts[0]; try storage.save(library)
            }
            let credentials = MailMemoryCredentials(), oauth = OAuthManager(credentials: credentials.backend, openBrowser: { _ in false })
            let store = MailStore(root: root, oauth: oauth, startTimer: false, evidenceDefaults: defaults, readGoogleClientSecret: { nil })
            try store.authorizeHostConnection(accountID: account.id)
            var preferences = store.library.preferences; preferences.microsoftClientID = "changed-microsoft-client"
            try store.updatePreferences(preferences)
            try check(!store.isHostConnectionAuthorized(accountID: account.id), "Microsoft客户端ID变化撤销该账号主机授权")
            try store.authorizeHostConnection(accountID: account.id)
            preferences.microsoftTenant = UUID().uuidString; try store.updatePreferences(preferences)
            try check(!store.isHostConnectionAuthorized(accountID: account.id) && credentials.reads == 0, "Microsoft租户变化也需重连且未读原凭据")
            store.prepareForApplicationExit()
        }
        for damage in ["missing-cache", "bad-cache", "bad-library", "missing-marker"] {
            let root = location(), defaults = MailMemoryDefaults(); _ = try fixture(root, defaults)
            let cache = root.appendingPathComponent("MailCache.json"), library = root.appendingPathComponent("Library.json")
            if damage == "missing-cache" { try fm.removeItem(at: cache) }
            if damage == "bad-cache" { try Data("broken cache original".utf8).write(to: cache) }
            if damage == "bad-library" { try Data("broken library original".utf8).write(to: library) }
            if damage == "missing-marker" { try fm.removeItem(at: MailStorage.markerURL(root: root)) }
            let oldLibrary = try Data(contentsOf: library), oldCache = try? Data(contentsOf: cache)
            let storage = MailStorage(root: root, evidenceDefaults: defaults); let value = storage.load(); _ = storage.loadMessages()
            try check(storage.readFailure != nil && value.identities.isEmpty, damage + "进入只读保护不呈默认身份")
            try reject(damage + "拒绝保存空库") { try storage.save(MailLibrary()) }
            try check(try Data(contentsOf: library) == oldLibrary && (try? Data(contentsOf: cache)) == oldCache, damage + "原库及缓存不覆盖")
        }
        do {
            let root = location(), defaults = MailMemoryDefaults(); _ = try fixture(root, defaults)
            let file = root.appendingPathComponent("Library.json")
            var future = try MailStorage.decoder.decode(MailLibrary.self, from: Data(contentsOf: file)); future.schemaVersion = 99
            let bytes = try MailStorage.encoder.encode(future); try bytes.write(to: file)
            let storage = MailStorage(root: root, evidenceDefaults: defaults); _ = storage.load()
            try check(storage.readFailure != nil, "未来邮件schema进入保护而不是空库迁移")
            try reject("未来schema默认保存拒绝") { try storage.save(MailLibrary()) }
            try check(try Data(contentsOf: file) == bytes, "未来schema原字节保持不变")
        }
        do {
            let root = location(), defaults = MailMemoryDefaults(); _ = try fixture(root, defaults)
            let cache = root.appendingPathComponent("MailCache.json"), damaged = Data("preserve undecodable original cache".utf8)
            try damaged.write(to: cache)
            let storage = MailStorage(root: root, evidenceDefaults: defaults); _ = storage.load()
            // Explicit native recovery is different from ordinary save: it first
            // preserves both readable original files and then applies a known backup.
            try storage.restore(MailLibrary()); try storage.saveMessages([])
            let names = try fm.contentsOfDirectory(atPath: root.path)
            let snapshot = names.first { $0.hasPrefix("MailCache.beforeRestore.") }!
            try check(try Data(contentsOf: root.appendingPathComponent(snapshot)) == damaged, "显式恢复先保留不可解析缓存原字节")
            try check(try MailStorage.decoder.decode([CachedMessage].self, from: Data(contentsOf: cache)).isEmpty, "仅显式确认恢复可清空当前缓存视图")
        }
        do {
            let root = location(), defaults = MailMemoryDefaults(); _ = try fixture(root, defaults)
            try fm.removeItem(at: root)
            let storage = MailStorage(root: root, evidenceDefaults: defaults); _ = storage.load()
            try check(storage.readFailure != nil && !fm.fileExists(atPath: root.path), "整目录删除后独立依据禁止重新建空资料")
        }
        do {
            let root = location(), defaults = MailMemoryDefaults(); _ = try fixture(root, defaults)
            let storage = MailStorage(root: root, evidenceDefaults: defaults), value = storage.load()
            let file = root.appendingPathComponent("Library.json"); try Data("changed while open".utf8).write(to: file)
            try reject("运行中主库替换拒绝旧内存覆盖") { try storage.save(value) }
            try check(try Data(contentsOf: file) == Data("changed while open".utf8), "运行中坏字节保留不静默回滚")
        }
        for failingStep in [MailSubmissionLocalStep.cache, .library] {
            let root = location(), defaults = MailMemoryDefaults(), account = try fixture(root, defaults)
            let credentials = MailMemoryCredentials(), oauth = OAuthManager(credentials: credentials.backend, openBrowser: { _ in false })
            var transmissions = 0, resolutions = 0
            var original: MailDraft!
            do {
                let store = MailStore(root: root, oauth: oauth, evidenceDefaults: defaults, readGoogleClientSecret: { nil },
                    sendMail: { _, _, _ in transmissions += 1; return TransportSendResult(deliveredToServer: true, sentCopyWarning: nil) },
                    resolveSubmissionConnection: { _ in resolutions += 1; return TransportConnection(imapHost: "fixture.invalid", smtpHost: "fixture.invalid", username: "fixture", password: "synthetic-never-persist-this-password") },
                    submissionPersistenceHook: { step in if step == failingStep { throw MailAppError.message("fixture local persistence failed") } })
                original = store.library.drafts[0]
                try store.authorizeHostConnection(accountID: account.id)
                var acceptedError = false
                do { try await store.send(original) } catch { acceptedError = error.localizedDescription.contains("已接受发送") }
                try check(acceptedError && transmissions == 1 && resolutions == 1, "SMTP接受后本地写失败明确提示已接受且仅传输一次")
                try check(try store.submissionState(for: original.id)?.phase == .accepted, "本地失败保留durable accepted状态")
                try check(store.library.drafts.contains { $0.id == original.id }, "缓存或主库失败均保留原草稿")
                try store.saveDraft(original)
                try check(store.library.drafts.contains { $0.id == original.id }, "完全相同已提交草稿允许安全关闭保存no-op")
                var edited = original!; edited.body += "changed"
                try reject("已提交原草稿不能改写后重发") { try store.saveDraft(edited) }
                try await rejectAsync("同ID立即重试不能再次SMTP") { try await store.send(original) }
                try check(transmissions == 1 && resolutions == 1 && credentials.reads == 0, "提交后重复入口不取凭据或再次连接")
                let ledger = try String(contentsOf: root.appendingPathComponent("MailSubmissions.json"), encoding: .utf8)
                try check(!ledger.contains(original.body) && !ledger.contains(original.from) && !ledger.contains("synthetic-never-persist-this-password"), "发送ledger只含编号摘要阶段时间，不含正文收件地址或凭据")
                store.prepareForApplicationExit()
            }
            do {
                let reopened = MailStore(root: root, oauth: oauth, evidenceDefaults: defaults, readGoogleClientSecret: { nil },
                    sendMail: { _, _, _ in transmissions += 1; throw MailAppError.message("must not send") },
                    resolveSubmissionConnection: { _ in resolutions += 1; throw MailAppError.message("must not resolve") })
                try check(try reopened.submissionState(for: original.id)?.phase == .accepted, "重启accepted事务不退为普通草稿")
                try await rejectAsync("重启同ID不重新发信") { try await reopened.send(original) }
                try reopened.retrySubmissionLocalSave(draftID: original.id)
                try check(!reopened.library.drafts.contains { $0.id == original.id } && reopened.messages.filter { $0.id == account.id.uuidString + "|local|" + original.id.uuidString }.count == 1, "只重试本地保存完成缓存与草稿清理且副本不重复")
                try check(try reopened.submissionState(for: original.id)?.phase == .completed, "本地两写成功后完成发送事务")
                try reopened.retrySubmissionLocalSave(draftID: original.id)
                try await rejectAsync("完成事务仍不能重放旧ID") { try await reopened.send(original) }
                try check(transmissions == 1 && resolutions == 1 && credentials.reads == 0, "重启恢复与幂等本地重试不取Keychain或调用网络")
                reopened.prepareForApplicationExit()
            }
        }
        do {
            let root = location(), defaults = MailMemoryDefaults(), account = try fixture(root, defaults)
            var transmissions = 0
            let store = MailStore(root: root, evidenceDefaults: defaults, readGoogleClientSecret: { nil },
                sendMail: { _, _, _ in transmissions += 1; return TransportSendResult(deliveredToServer: true, sentCopyWarning: nil) },
                resolveSubmissionConnection: { _ in TransportConnection(imapHost: "fixture.invalid", smtpHost: "fixture.invalid", username: "fixture", password: "synthetic") })
            try store.authorizeHostConnection(accountID: account.id)
            let original = store.library.drafts[0]
            try await store.send(original)
            try check(try store.submissionState(for: original.id)?.phase == .completed, "正常发送完成缓存与草稿两写才返回成功")
            try await rejectAsync("正常完成后同ID也不得再次发送") { try await store.send(original) }
            try check(transmissions == 1 && store.library.drafts.isEmpty, "正常发送只有一次SMTP且不残留普通草稿")
            store.prepareForApplicationExit()
        }
        do {
            let root = location(), defaults = MailMemoryDefaults(), account = try fixture(root, defaults)
            var transmissions = 0, resolutions = 0
            let store = MailStore(root: root, evidenceDefaults: defaults, readGoogleClientSecret: { nil },
                sendMail: { _, _, _ in transmissions += 1; return TransportSendResult(deliveredToServer: true, sentCopyWarning: nil) },
                resolveSubmissionConnection: { _ in resolutions += 1; throw MailAppError.message("must not resolve") })
            try store.authorizeHostConnection(accountID: account.id)
            defaults.failSubmissionEvidence = true
            try await rejectAsync("写不下前置发送意图就停止") { try await store.send(store.library.drafts[0]) }
            try check(transmissions == 0 && resolutions == 0, "前置意图失败时OAuth连接解析与SMTP调用均为零")
            try check(store.library.drafts.count == 1 && !fm.fileExists(atPath: root.appendingPathComponent("MailSubmissions.json").path), "前置证据失败保留原草稿不冒充发送完成")
            try store.saveDraft(store.library.drafts[0])
            try check(store.library.drafts.count == 1, "意图记录失败也允许完全相同已持久原稿安全关闭")
            store.prepareForApplicationExit()
        }
        do {
            let root = location(), defaults = MailMemoryDefaults(), account = try fixture(root, defaults)
            var transmissions = 0, resolutions = 0
            var original: MailDraft!
            do {
                let store = MailStore(root: root, evidenceDefaults: defaults, readGoogleClientSecret: { nil },
                    sendMail: { _, _, _ in transmissions += 1; throw TransportError.connection("synthetic uncertain disconnect") },
                    resolveSubmissionConnection: { _ in resolutions += 1; return TransportConnection(imapHost: "fixture.invalid", smtpHost: "fixture.invalid", username: "fixture", password: "synthetic") })
                try store.authorizeHostConnection(accountID: account.id); original = store.library.drafts[0]
                try await rejectAsync("传输中断保留待确认意图") { try await store.send(original) }
                try check(try store.submissionState(for: original.id)?.phase == .pending, "传输异常不假称未发送或已接受")
                try reject("pending不能误作accepted本地补写") { try store.retrySubmissionLocalSave(draftID: original.id) }
                store.prepareForApplicationExit()
            }
            do {
                let reopened = MailStore(root: root, evidenceDefaults: defaults, readGoogleClientSecret: { nil },
                    sendMail: { _, _, _ in transmissions += 1; throw MailAppError.message("must not send") },
                    resolveSubmissionConnection: { _ in resolutions += 1; throw MailAppError.message("must not resolve") })
                try check(try reopened.submissionState(for: original.id)?.phase == .pending, "重启仍保留unknown/pending需人工核对")
                try await rejectAsync("unknown重启同ID禁止重发") { try await reopened.send(original) }
                try reopened.saveDraft(original)
                try check(transmissions == 1 && resolutions == 1, "unknown不自动重发或因关闭草稿再次连接")
                reopened.prepareForApplicationExit()
            }
            try fm.removeItem(at: root.appendingPathComponent("MailSubmissions.json"))
            let damaged = MailStore(root: root, evidenceDefaults: defaults, readGoogleClientSecret: { nil },
                sendMail: { _, _, _ in transmissions += 1; throw MailAppError.message("must not send") },
                resolveSubmissionConnection: { _ in resolutions += 1; throw MailAppError.message("must not resolve") })
            try await rejectAsync("删除发送ledger后独立证据阻止空白重发") { try await damaged.send(original) }
            try check(damaged.problem != nil && transmissions == 1 && resolutions == 1, "缺失记录只读停下保留原草稿不重建空记录")
            damaged.prepareForApplicationExit()
        }
    }
}
