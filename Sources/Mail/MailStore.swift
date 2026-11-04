import AppKit
import Combine
import UserNotifications
import UniformTypeIdentifiers

@MainActor final class MailStore: ObservableObject {
    @Published var library: MailLibrary
    @Published var messages: [CachedMessage]
    @Published var folders: [UUID: [TransportFolder]] = [:]
    @Published var busy = Set<UUID>()
    @Published var detailBusy = Set<String>()
    @Published var sending = false
    @Published private(set) var submissionRevision = 0
    private var volatileAcceptedSubmissions: [UUID: MailSubmissionRecord] = [:]
    private var volatileSubmissionReceipts: [UUID: CachedMessage] = [:]
    private let sendMail: (TransportConnection, TransportOutgoing, String?) async throws -> TransportSendResult
    private let resolveSubmissionConnection: ((MailAccount) async throws -> TransportConnection)?
    private let submissionPersistenceHook: (MailSubmissionLocalStep) throws -> Void
    @Published var notice: String?
    @Published var problem: String?
    @Published var compose: MailDraft?
    @Published var route = "overview"
    @Published var identityFilter: UUID?
    @Published var mailboxFilter: UUID?
    @Published var folder = "INBOX"
    @Published var search = ""
    @Published var selectedMessageID: String?
    let storage: MailStorage
    let oauth: OAuthManager
    @Published private(set) var browserLoginStatus: String?
    private var browserAdditionActive = false
    private let checkBrowserConnection: (TransportConnection) async throws -> Void
    private let readGoogleClientSecret: () throws -> String?
    private var timer: Timer?
    private var ticks = 0
    @Published private(set) var authorizedHostAccounts = Set<UUID>()
    private var authorizationConfigurations: [UUID: String] = [:]
    private var automaticallySynchronizedAccounts = Set<UUID>()
    init(root: URL? = nil, oauth: OAuthManager? = nil, startTimer: Bool = false, blockedBecause: String? = nil, evidenceDefaults: MailStorageDefaults? = UserDefaults.standard,
         checkBrowserConnection: @escaping (TransportConnection) async throws -> Void = { try await MailTransport.testConnection($0) },
         readGoogleClientSecret: @escaping () throws -> String? = { try MailCredentialVault.read("oauth.googleClientSecret") },
         sendMail: @escaping (TransportConnection, TransportOutgoing, String?) async throws -> TransportSendResult = { try await MailTransport.send($0, message: $1, sentFolder: $2) },
         resolveSubmissionConnection: ((MailAccount) async throws -> TransportConnection)? = nil,
         submissionPersistenceHook: @escaping (MailSubmissionLocalStep) throws -> Void = { _ in }) {
        self.oauth = oauth ?? OAuthManager()
        self.checkBrowserConnection = checkBrowserConnection
        self.readGoogleClientSecret = readGoogleClientSecret
        self.sendMail = sendMail; self.resolveSubmissionConnection = resolveSubmissionConnection
        self.submissionPersistenceHook = submissionPersistenceHook
        storage = MailStorage(root: root, blockedBecause: blockedBecause, evidenceDefaults: evidenceDefaults)
        library = storage.load(); messages = storage.loadMessages()
        problem = storage.readFailure ?? storage.cacheWarning
        if problem == nil {
            do { _ = try storage.loadSubmissions() } catch { problem = error.localizedDescription }
        }
        // Opening this native module is cache-only. Imported OAuth journals
        // and Keychain items remain untouched until an explicit recovery review.
        // startTimer is retained for source/API compatibility; even true cannot
        // start polling before a connection succeeds in this host session.
        _ = startTimer
    }
    func isHostConnectionAuthorized(accountID: UUID) -> Bool {
        guard let account = account(accountID) else { return false }
        return authorizedHostAccounts.contains(accountID) && authorizationConfigurations[accountID] == connectionIdentity(account)
    }
    /// The native UI calls this only after the user confirms connecting this
    /// mailbox and its displayed IMAP/SMTP endpoints in the new host.
    func authorizeHostConnection(accountID: UUID) throws {
        try storage.verifyAvailability()
        guard let account = account(accountID), account.enabled else { throw MailAppError.message("请先选择并启用需要连接的邮箱。") }
        authorizationConfigurations[accountID] = connectionIdentity(account)
        authorizedHostAccounts.insert(accountID)
    }
    private func connectionIdentity(_ value: MailAccount) -> String {
        var fields = [value.email.lowercased(), value.username, value.auth, value.imapHost, String(value.imapPort), value.imapTLS,
                      value.smtpHost, String(value.smtpPort), value.smtpTLS]
        // Public OAuth configuration belongs to the explicit host consent. Do
        // not read a Keychain client secret simply to render or compare it.
        if value.auth == "google" { fields += [library.preferences.googleClientID] }
        if value.auth == "microsoft" { fields += [library.preferences.microsoftClientID, library.preferences.microsoftTenant] }
        return fields.joined(separator: "\u{001f}")
    }
    private func requireHostConnection(_ value: MailAccount) throws {
        try storage.verifyAvailability()
        guard authorizedHostAccounts.contains(value.id), authorizationConfigurations[value.id] == connectionIdentity(value) else {
            throw MailAppError.message("请先在搞门户为此邮箱点击“连接／授权”并确认；尚未读取原钥匙串凭据或连接服务器。")
        }
    }
    private func connectionSucceeded(_ value: MailAccount) {
        guard isHostConnectionAuthorized(accountID: value.id) else { return }
        automaticallySynchronizedAccounts.insert(value.id)
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in Task { @MainActor in
            guard let self else { return }; self.ticks += 1
            if self.ticks >= max(1, self.library.preferences.syncMinutes) {
                self.ticks = 0
                for account in self.library.accounts where account.enabled && self.automaticallySynchronizedAccounts.contains(account.id) && self.isHostConnectionAuthorized(accountID: account.id) {
                    await self.sync(account.id, folder: "INBOX")
                }
            }
        } }
    }
    func stopAutomaticSynchronization() {
        timer?.invalidate(); timer = nil; ticks = 0
        automaticallySynchronizedAccounts.removeAll()
    }
    /// Never cancel SMTP here: once DATA has started its outcome may be unknown.
    /// The host first refuses exit while sending and saves any native draft.
    func prepareForApplicationExit() { stopAutomaticSynchronization() }
    deinit { timer?.invalidate() }
    var filteredAccounts: [MailAccount] { library.accounts.filter { identityFilter == nil || $0.identityID == identityFilter } }
    var filteredMessages: [CachedMessage] {
        let ids = Set(filteredAccounts.map(\.id)); let query = search.trimmingCharacters(in:.whitespacesAndNewlines)
        return messages.filter { m in ids.contains(m.accountID) && (mailboxFilter == nil || m.accountID == mailboxFilter) && (m.folder == folder || (m.folder.lowercased() == "inbox" && folder.lowercased() == "inbox")) && (query.isEmpty || [m.subject,m.from,m.to,m.body,m.preview].joined(separator:" ").localizedCaseInsensitiveContains(query)) }.sorted {$0.date > $1.date}
    }
    var filteredPlatforms: [PlatformRecord] {
        let ids = Set(filteredAccounts.map(\.id))
        return library.platforms.filter { p in
            (identityFilter == nil || (p.accountID != nil && ids.contains(p.accountID!))) && (mailboxFilter == nil || p.accountID == mailboxFilter) && (search.isEmpty || [p.name,p.username,p.address,p.url,p.notes,p.status,account(p.accountID)?.email ?? ""].joined(separator:" ").localizedCaseInsensitiveContains(search))
        }.sorted {$0.updatedAt > $1.updatedAt}
    }
    func account(_ id: UUID?) -> MailAccount? { library.accounts.first {$0.id == id} }
    /// Navigation only: the floating panel never downloads or marks mail on its own.
    func openCachedInbox(accountID: UUID? = nil, messageID: String? = nil) {
        identityFilter = nil; search = ""; route = "inbox"; folder = "INBOX"
        mailboxFilter = account(accountID)?.id
        selectedMessageID = messageID.flatMap { id in filteredMessages.first(where:{$0.id == id})?.id }
    }
    func retainVisibleMessageSelection() {
        if let id = selectedMessageID, !filteredMessages.contains(where:{$0.id == id}) { selectedMessageID = nil }
    }
    func identity(_ id: UUID?) -> MailIdentity? { library.identities.first {$0.id == id} }
    func identityName(for account: MailAccount?) -> String { identity(account?.identityID)?.name ?? "未分类" }
    func commit(_ value: MailLibrary) throws { try storage.save(value); library = value }
    func publish(_ error: Error) { problem = error.localizedDescription }
    func updatePreferences(_ preferences: MailPreferences) throws {
        let previous = library.preferences
        var v = library; v.preferences = preferences; try commit(v)
        for account in library.accounts where (account.auth == "google" && previous.googleClientID != preferences.googleClientID)
            || (account.auth == "microsoft" && (previous.microsoftClientID != preferences.microsoftClientID || previous.microsoftTenant != preferences.microsoftTenant)) {
            authorizedHostAccounts.remove(account.id); authorizationConfigurations[account.id] = nil; automaticallySynchronizedAccounts.remove(account.id)
        }
        notice = "设置已保存"
    }
    func saveIdentity(_ identity: MailIdentity) throws {
        guard !identity.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw MailAppError.message("请填写身份名称。") }
        var v = library
        if let i = v.identities.firstIndex(where:{$0.id == identity.id}) { v.identities[i] = identity } else { v.identities.append(identity) }
        try commit(v)
    }
    func deleteIdentity(_ id: UUID) {
        do { var v = library; v.identities.removeAll {$0.id == id}; for i in v.accounts.indices where v.accounts[i].identityID == id { v.accounts[i].identityID = nil }; try commit(v); if identityFilter == id { identityFilter = nil } } catch { publish(error) }
    }
    func saveAccount(_ input: MailAccount, password: String?) throws {
        var a = input; a.email = a.email.trimmingCharacters(in:.whitespacesAndNewlines); a.username = a.username.trimmingCharacters(in:.whitespacesAndNewlines)
        if a.username.isEmpty { a.username = a.email }
        guard !busy.contains(a.id), !sending, !detailBusy.contains(where:{$0.hasPrefix(a.id.uuidString + "|")}) else { throw MailAppError.message("此邮箱正在收发或读取邮件，请稍后再保存。") }
        let oldAccount = account(a.id)
        if let oldAccount, oldAccount.email.lowercased() != a.email.lowercased() { throw MailAppError.message("已有邮箱地址不能直接更换。请另行添加新邮箱，以保留正确的邮件和平台归属。") }
        let connectionChanged = oldAccount.map { connectionIdentity($0) != connectionIdentity(a) } ?? false
        if connectionChanged { a.lastSync = nil; a.syncError = nil }
        guard MailValidation.address(a.email) else { throw MailAppError.message("请填写有效的完整邮箱地址。") }
        guard !library.accounts.contains(where:{$0.id != a.id && $0.email.lowercased() == a.email.lowercased()}) else { throw MailAppError.message("这个邮箱已经添加过了。") }
        if a.enabled && (a.imapHost.isEmpty || a.smtpHost.isEmpty) { throw MailAppError.message("请填写收件和发件服务器，或选择仅登记资料。") }
        for alias in a.allowedAddresses where !MailValidation.address(alias) { throw MailAppError.message("邮箱别名格式不正确：" + alias) }
        let key = "account." + a.id.uuidString + ".password"
        try storage.verifyAvailability()
        let writesPassword = password?.isEmpty == false
        if writesPassword && oldAccount != nil { try requireHostConnection(oldAccount!) }
        let previous = writesPassword && oldAccount != nil ? try MailCredentialVault.read(key) : nil
        if let password, writesPassword {
            if oldAccount == nil { try MailCredentialVault.insertData(Data(password.utf8), for: key) }
            else { try MailCredentialVault.save(password, for: key) }
        }
        do {
            var v = library
            if let i = v.accounts.firstIndex(where:{$0.id == a.id}) { v.accounts[i] = a } else { v.accounts.append(a) }
            try commit(v)
        } catch {
            if writesPassword { if let previous { try? MailCredentialVault.save(previous,for:key) } else { try? MailCredentialVault.delete(key) } }
            throw error
        }
        if connectionChanged {
            authorizedHostAccounts.remove(a.id); authorizationConfigurations[a.id] = nil; automaticallySynchronizedAccounts.remove(a.id)
            messages.removeAll {$0.accountID == a.id && $0.folder != "__local_sent__"}; folders[a.id] = nil
            do { try storage.saveMessages(messages) } catch { publish(error) }
        }
        notice = "邮箱资料已保存"
    }
    func deleteAccount(_ id: UUID) {
        do {
            guard !busy.contains(id) && !sending && !detailBusy.contains(where:{$0.hasPrefix(id.uuidString + "|")}) else { throw MailAppError.message("邮箱正在同步、读取或发送，请稍后再移除。") }
            var v = library; v.accounts.removeAll {$0.id == id}
            for i in v.platforms.indices where v.platforms[i].accountID == id { v.platforms[i].accountID = nil; v.platforms[i].history.append(PlatformHistory(text:"已移除原邮箱，保留平台记录")) }
            for i in v.drafts.indices where v.drafts[i].accountID == id { v.drafts[i].accountID = nil }
            try commit(v); messages.removeAll {$0.accountID == id}; try storage.saveMessages(messages)
            // Removing this account is an explicit native operation. Keep other
            // accounts and all unrelated credential identifiers untouched.
            try MailCredentialVault.delete("account." + id.uuidString + ".password"); try oauth.disconnect(accountID:id.uuidString)
            authorizedHostAccounts.remove(id); authorizationConfigurations[id] = nil; automaticallySynchronizedAccounts.remove(id)
            if mailboxFilter == id { mailboxFilter = nil }; notice = "邮箱已移除，平台记录已保留"
        } catch { publish(error) }
    }
    func savePlatform(_ input: PlatformRecord) throws {
        var p = input; p.name = p.name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !p.name.isEmpty else { throw MailAppError.message("请填写平台名称。") }
        if !p.url.isEmpty { guard let u = MailValidation.webURL(p.url) else { throw MailAppError.message("平台网址应为有效的 http / https 地址。") }; p.url = u.absoluteString }
        if p.address.isEmpty { p.address = account(p.accountID)?.email ?? "" }
        if !p.address.isEmpty && !MailValidation.address(p.address) { throw MailAppError.message("实际关联邮箱地址格式不正确。") }
        p.updatedAt = Date()
        var v = library
        if let i = v.platforms.firstIndex(where:{$0.id == p.id}) {
            let old = v.platforms[i]
            var changes: [String] = []
            if old.address != p.address { changes.append("邮箱：\(old.address) → \(p.address)") }
            if old.status != p.status { changes.append("状态：\(old.status) → \(p.status)") }
            if old.loginMethod != p.loginMethod { changes.append("登录方式：\(p.loginMethod)") }
            p.history = old.history
            p.history.append(PlatformHistory(text:changes.isEmpty ? "更新了平台资料" : changes.joined(separator:"；")))
            v.platforms[i] = p
        } else { p.history = [PlatformHistory(text:"手动登记关联平台")]; v.platforms.append(p) }
        try commit(v); notice = "平台关联已保存"
    }
    func deletePlatform(_ id: UUID) { do { var v = library; v.platforms.removeAll {$0.id == id}; try commit(v) } catch { publish(error) } }
    func saveDraft(_ input: MailDraft) throws {
        let ledger: MailSubmissionLedger
        do { ledger = try storage.loadSubmissions() }
        catch {
            // A broken intent record must prevent sending, but an exactly
            // matching already-durable draft can still be closed without writes.
            if (try? storage.hasDurableDraftMatching(input)) == true { return }
            throw error
        }
        if let record = ledger.records.first(where: { $0.draftID == input.id }) {
            guard try record.matchesDraft(input) else { throw MailAppError.message("此草稿已有发送事务，不能修改后再次发送。请先核对发送状态。") }
            return // The original draft/receipt is already durable; never resurrect it.
        }
        var d = input; d.updatedAt = Date(); var v = library
        if let i = v.drafts.firstIndex(where:{$0.id == d.id}) { v.drafts[i] = d } else { v.drafts.append(d) }
        try commit(v)
    }
    func deleteDraft(_ id: UUID) {
        do {
            guard try submissionState(for: id) == nil else { throw MailAppError.message("此草稿已有发送事务，请先核对发送状态；不能当普通草稿删除。") }
            var v = library; v.drafts.removeAll { $0.id == id }; try commit(v)
        } catch { publish(error) }
    }
    func newDraft(accountID: UUID? = nil) {
        guard compose == nil else {return}
        let a = account(accountID ?? mailboxFilter) ?? filteredAccounts.first(where:{$0.enabled}) ?? filteredAccounts.first
        compose = MailDraft(accountID:a?.id,from:a?.email ?? "",body:a?.signature.isEmpty == false ? "\n\n" + a!.signature : "")
    }
    func reply(_ m: CachedMessage, all: Bool = false, forward: Bool = false) {
        guard compose == nil else {return}
        let a = account(m.accountID)
        let own = Set(a?.allowedAddresses.map{$0.lowercased()} ?? [])
        let source = MailValidation.bareAddress(m.replyTo ?? m.from)
        var recipients = own.contains(source.lowercased()) ? MailValidation.recipients(m.to).map(MailValidation.bareAddress) : [source]
        if all { recipients += MailValidation.recipients(m.to + "," + m.cc).map(MailValidation.bareAddress) }
        var seen = Set<String>(); recipients = recipients.filter{MailValidation.address($0) && !own.contains($0.lowercased()) && seen.insert($0.lowercased()).inserted}
        let prefix = forward ? "Fwd: " : "Re: "
        let quoted = m.body.components(separatedBy:"\n").map{"> " + $0}.joined(separator:"\n")
        let text = "\n\n" + (a?.signature ?? "") + "\n\n—— 原邮件 · \(m.from) ——\n" + quoted
        compose = MailDraft(accountID:m.accountID,from:a?.email ?? "",to:forward ? "" : recipients.joined(separator:", "),subject:m.subject.lowercased().hasPrefix(prefix.lowercased()) ? m.subject : prefix + m.subject,body:text,inReplyTo:forward ? nil : m.messageID,references:forward ? nil : [m.references,m.messageID].compactMap{$0}.joined(separator:" "))
    }
    func oauthConfiguration(for a: MailAccount) throws -> OAuthConfiguration {
        let p = library.preferences
        if a.auth == "google" { return OAuthConfiguration(provider:.google,clientID:p.googleClientID,clientSecret:try readGoogleClientSecret()) }
        return OAuthConfiguration(provider:.microsoft,clientID:p.microsoftClientID,tenant:p.microsoftTenant)
    }
    func authorize(_ a: MailAccount) async throws {
        try storage.verifyAvailability()
        let configuration = try oauthConfiguration(for: a)
        try await oauth.authorizeUsingBrowser(accountID: a.id.uuidString, configuration: configuration, loginHint: a.email) { result, checkActive in
            try checkActive()
            guard self.account(a.id) == a else { throw MailAppError.message("邮箱资料在授权期间已改变，请重新授权。") }
            guard try self.oauthConfiguration(for: a) == configuration else { throw OAuthError.credentialChanged }
            try self.oauth.save(result.credential, accountID: a.id.uuidString, configuration: configuration)
            self.authorizationConfigurations[a.id] = self.connectionIdentity(a); self.authorizedHostAccounts.insert(a.id)
        }
    }

    /// Read only public settings here; rendering the UI must never prompt for Keychain access.
    func browserLoginAvailability(provider: OAuthProvider) -> String? {
        do { try browserConfiguration(provider: provider, includeSecret: false).validate(); return nil }
        catch { return error.localizedDescription }
    }

    private func browserConfiguration(provider: OAuthProvider, includeSecret: Bool) throws -> OAuthConfiguration {
        let p = library.preferences
        return provider == .google
            ? OAuthConfiguration(provider: .google, clientID: p.googleClientID, clientSecret: includeSecret ? try readGoogleClientSecret() : nil)
            : OAuthConfiguration(provider: .microsoft, clientID: p.microsoftClientID, tenant: p.microsoftTenant)
    }

    func addAccountUsingBrowser(provider: OAuthProvider, identityID: UUID? = nil) async throws -> MailAccount {
        try Task.checkCancellation()
        guard !browserAdditionActive else { throw MailAppError.message("上次网页登录或收发检查尚未结束。若刚取消，正在进行的连接最多需要 90 秒结束，请稍后重试。") }
        if let failure = storage.readFailure { throw MailAppError.message(failure) }
        if let identityID, identity(identityID) == nil { throw MailAppError.message("所选身份已被删除，请重新选择。") }
        try browserConfiguration(provider: provider, includeSecret: false).validate()
        try storage.verifyAvailability()
        guard try !storage.hasPendingOAuthAdditions() else { throw MailAppError.message("原邮箱仍有授权恢复事务；已保留原记录与凭据，请先单独核对恢复，未自动清理或添加新邮箱。") }
        let configuration = try browserConfiguration(provider: provider, includeSecret: true)
        browserAdditionActive = true
        browserLoginStatus = "正在打开官方网页登录…"
        defer { browserAdditionActive = false; browserLoginStatus = nil }
        return try await oauth.authorizeUsingBrowser(configuration: configuration) { result, checkActive in
            try checkActive()
            guard MailValidation.address(result.email) else { throw OAuthError.identityInvalid }
            var account = MailAccount(email: result.email, provider: provider == .google ? .gmail : .outlook, identityID: identityID)
            account.applyProvider()
            account.enabled = true
            account.username = result.email
            if provider == .microsoft {
                guard let tenant = result.microsoftTenantID else { throw OAuthError.identityInvalid }
                account.smtpHost = tenant.lowercased() == "9188040d-6c67-4c5b-b112-36a304b66dad" ? "smtp-mail.outlook.com" : "smtp.office365.com"
            }
            @MainActor func validateCurrentState() throws {
                try checkActive()
                guard try self.browserConfiguration(provider: provider, includeSecret: true) == configuration else { throw OAuthError.credentialChanged }
                guard !self.library.accounts.contains(where: { $0.email.caseInsensitiveCompare(account.email) == .orderedSame || $0.id == account.id }) else {
                    throw MailAppError.message("这个邮箱已经添加过了，未更改已有邮箱或授权。")
                }
                if let identityID, self.identity(identityID) == nil { throw MailAppError.message("所选身份在登录期间已被删除，请重新选择并登录。") }
                if let failure = self.storage.readFailure { throw MailAppError.message(failure) }
            }
            try validateCurrentState()
            self.browserLoginStatus = "网页登录已完成，正在检查收发连接…"
            let connection = TransportConnection(imapHost: account.imapHost, imapPort: account.imapPort,
                imapSecurity: TransportSecurity(rawValue: account.imapTLS) ?? .tls,
                smtpHost: account.smtpHost, smtpPort: account.smtpPort,
                smtpSecurity: TransportSecurity(rawValue: account.smtpTLS) ?? .startTLS,
                username: account.username, password: "", oauthToken: result.credential.accessToken)
            do { try await self.checkBrowserConnection(connection) }
            catch {
                try checkActive()
                throw MailAppError.message("官方登录已完成，但收发连接未通过：" + error.localizedDescription)
            }
            try validateCurrentState()
            self.browserLoginStatus = "收发登录已通过，正在保存邮箱…"
            var next = self.library
            next.accounts.append(account)
            let commitLock = try self.storage.lockOAuthAdditions()
            defer { commitLock.release() }
            let prepared = try self.storage.prepareAccountAddition(next)
            try checkActive()
            let journal = try self.storage.beginOAuthAddition(accountID: account.id)
            do {
                try checkActive()
                try self.oauth.insertCredential(result.credential, accountID: account.id.uuidString, configuration: configuration, transactionID: journal.transactionID)
                try checkActive()
                try prepared.commit()
            } catch {
                let originalError = error
                do {
                    try self.oauth.rollbackNewCredential(accountID: account.id.uuidString, transactionID: journal.transactionID)
                    try self.storage.finishOAuthAddition(journal)
                } catch {
                    // Preserve the journal so retry/restart can finish this exact rollback.
                    throw MailAppError.message("邮箱未添加。新授权的清理尚未完成，已保留恢复记录；请解锁钥匙串后重试：" + error.localizedDescription)
                }
                throw originalError
            }
            self.library = next
            self.authorizationConfigurations[account.id] = self.connectionIdentity(account); self.authorizedHostAccounts.insert(account.id)
            self.connectionSucceeded(account)
            // Failure to remove a committed journal is harmless; recovery sees the saved
            // account and retains its credential. Do not report a successful add as failed.
            do { try self.storage.finishOAuthAddition(journal) }
            catch { self.problem = "邮箱已添加，请在邮件设置中核对未完成授权事务。" }
            self.notice = "邮箱已添加，收发登录已通过，正在准备同步"
            return account
        }
    }
    func pendingOAuthAdditionCount() throws -> Int {
        try storage.verifyAvailability(); return try storage.pendingOAuthAdditions().count
    }
    /// The native settings page presents a confirmation before calling this.
    /// Only a credential owned by the journal's exact transaction may be rolled
    /// back. Saved accounts retain their credentials; failures retain journals.
    func recoverPendingOAuthAdditionsAfterConfirmation() throws {
        try storage.verifyAvailability()
        guard try storage.hasPendingOAuthAdditions() else { return }
        let recoveryLock = try storage.lockOAuthAdditions()
        defer { recoveryLock.release() }
        let committedIDs = try storage.oauthRecoveryAccountIDs()
        for journal in try storage.pendingOAuthAdditions() {
            if !committedIDs.contains(journal.accountID) && account(journal.accountID) == nil {
                try oauth.rollbackNewCredential(accountID: journal.accountID.uuidString, transactionID: journal.transactionID)
            }
            try storage.finishOAuthAddition(journal)
        }
    }

    func connection(for a: MailAccount, overridePassword: String? = nil) async throws -> TransportConnection {
        try requireHostConnection(a)
        var password = ""; var token: String?
        if a.auth == "password" {
            password = try overridePassword ?? MailCredentialVault.read("account." + a.id.uuidString + ".password") ?? ""
            guard !password.isEmpty else { throw MailAppError.message("请编辑邮箱并填写客户端授权码或专用密码。") }
        } else { token = try await oauth.validAccessToken(accountID:a.id.uuidString,configuration:oauthConfiguration(for:a)) }
        return TransportConnection(imapHost:a.imapHost,imapPort:a.imapPort,imapSecurity:TransportSecurity(rawValue:a.imapTLS) ?? .tls,smtpHost:a.smtpHost,smtpPort:a.smtpPort,smtpSecurity:TransportSecurity(rawValue:a.smtpTLS) ?? .tls,username:a.username.isEmpty ? a.email : a.username,password:password,oauthToken:token)
    }
    func test(_ a: MailAccount, password: String?) async throws {
        // This method is invoked by the visible native “测试连接” button; it
        // tests the exact displayed settings, never sends a message.
        try storage.verifyAvailability()
        authorizationConfigurations[a.id] = connectionIdentity(a); authorizedHostAccounts.insert(a.id)
        let c = try await connection(for:a,overridePassword:password)
        try await MailTransport.testConnection(c)
        connectionSucceeded(a)
    }
    func syncAll() async {
        for a in library.accounts where a.enabled && isHostConnectionAuthorized(accountID: a.id) { await sync(a.id,folder:"INBOX") }
    }
    func sync(_ id: UUID, folder target: String = "INBOX") async {
        guard target != "__local_sent__", let a = account(id), a.enabled, !busy.contains(id), !detailBusy.contains(where:{$0.hasPrefix(id.uuidString + "|")}), storage.readFailure == nil else { return }
        busy.insert(id); defer { busy.remove(id) }
        do {
            let c = try await connection(for:a)
            let remoteFolders = try await MailTransport.listFolders(c); folders[id] = remoteFolders
            let fetched = try await MailTransport.fetchMessages(c,folder:target,limit:library.preferences.fetchLimit)
            let old = messages.filter{$0.accountID == id && $0.folder == target}
            let mapped = fetched.map { item -> CachedMessage in
                var m = cached(item,accountID:id,folder:target)
                if let previous = old.first(where:{$0.uid == item.uid && $0.uidValidity != nil && $0.uidValidity == item.uidValidity && $0.messageID == item.messageID}), previous.loaded && !m.loaded {
                    m.body = previous.body; m.html = previous.html; m.attachments = previous.attachments; m.loaded = true; m.preview = previous.preview
                }
                return m
            }
            var next = messages.filter{!($0.accountID == id && $0.folder == target)}; next += mapped
            try storage.saveMessages(next); messages = next
            var v = library; if let i = v.accounts.firstIndex(where:{$0.id == id}) { v.accounts[i].lastSync = Date(); v.accounts[i].syncError = nil }; try commit(v)
            let fresh = mapped.filter { m in !m.isRead && !old.contains(where:{$0.id == m.id}) }
            if a.lastSync != nil && target == "INBOX" && !fresh.isEmpty && library.preferences.notifyNewMail { notify(count:fresh.count,account:a) }
            connectionSucceeded(a)
            notice = "\(a.displayName) 已同步 \(mapped.count) 封邮件"
        } catch {
            var v = library; if let i = v.accounts.firstIndex(where:{$0.id == id}) { v.accounts[i].syncError = error.localizedDescription }
            do { try commit(v) } catch { publish(error) }
            notice = "\(a.displayName) 同步失败，请查看邮箱状态"
        }
    }
    func cached(_ m: TransportMessage, accountID: UUID, folder: String) -> CachedMessage {
        var result = CachedMessage(id:accountID.uuidString + "|" + folder + "|" + String(m.uidValidity ?? 0) + "|" + String(m.uid),accountID:accountID,folder:folder,uid:m.uid,subject:m.subject,from:m.from,to:m.to,cc:m.cc,date:m.date,preview:String(m.body.replacingOccurrences(of:"\n",with:" ").prefix(150)),body:m.body,html:m.html,isRead:m.isRead,isFlagged:m.isFlagged,messageID:m.messageID,references:m.references,attachments:m.attachments.map{CachedAttachment(filename:$0.filename,mimeType:$0.mimeType,data:$0.data)},loaded:m.bodyLoaded)
        result.uidValidity = m.uidValidity; result.replyTo = m.replyTo
        return result
    }
    func loadMessage(_ id: String) async {
        guard let existing = messages.first(where:{$0.id == id}), existing.folder != "__local_sent__", let a = account(existing.accountID), a.enabled, !detailBusy.contains(id), !busy.contains(a.id) else { return }
        detailBusy.insert(id); defer { detailBusy.remove(id) }
        do {
            guard let validity = existing.uidValidity else { throw MailAppError.message("请先重新同步此文件夹，再读取或修改邮件。") }
            let c = try await connection(for:a)
            if !existing.loaded {
                let fetched = try await MailTransport.fetchMessage(c,folder:existing.folder,uid:existing.uid,expectedUIDValidity:validity)
                if let i = messages.firstIndex(where:{$0.id == id}) { messages[i] = cached(fetched,accountID:a.id,folder:existing.folder) }
            }
            if !existing.isRead { try await MailTransport.setRead(c,folder:existing.folder,uids:[existing.uid],read:true,expectedUIDValidity:validity); if let i = messages.firstIndex(where:{$0.id == id}) { messages[i].isRead = true } }
            try storage.saveMessages(messages)
        } catch { publish(error) }
    }
    func changeFlag(_ m: CachedMessage, read: Bool? = nil, flag: Bool? = nil) async {
        guard let a = account(m.accountID), !busy.contains(a.id), !detailBusy.contains(m.id) else { return }
        detailBusy.insert(m.id); defer {detailBusy.remove(m.id)}
        do {
            if m.folder != "__local_sent__" {
                guard a.enabled, let validity = m.uidValidity else { throw MailAppError.message("请启用邮箱并重新同步后再修改邮件状态。") }
                let c = try await connection(for:a)
                if let read { try await MailTransport.setRead(c,folder:m.folder,uids:[m.uid],read:read,expectedUIDValidity:validity) }
                if let flag { try await MailTransport.setFlagged(c,folder:m.folder,uids:[m.uid],flagged:flag,expectedUIDValidity:validity) }
            }
            if let i = messages.firstIndex(where:{$0.id == m.id}) { if let read { messages[i].isRead = read }; if let flag { messages[i].isFlagged = flag } }
            try storage.saveMessages(messages)
        } catch { publish(error) }
    }
    func moveMessage(_ m: CachedMessage, destination: String) async {
        guard m.folder != "__local_sent__", let a = account(m.accountID), a.enabled, !busy.contains(a.id), !detailBusy.contains(m.id) else { return }
        detailBusy.insert(m.id); defer {detailBusy.remove(m.id)}
        do {
            guard let validity = m.uidValidity else { throw MailAppError.message("请重新同步后再移动邮件。") }
            let c = try await connection(for:a)
            try await MailTransport.move(c,folder:m.folder,uid:m.uid,destination:destination,expectedUIDValidity:validity)
            messages.removeAll{$0.id == m.id}; selectedMessageID = nil; try storage.saveMessages(messages); notice = "邮件已移至 \(destination)"
        } catch { publish(error) }
    }
    func submissionStates() throws -> [UUID: MailSubmissionState] {
        let ledger = try storage.loadSubmissions()
        var result: [UUID: MailSubmissionState] = [:]
        for record in ledger.records {
            if let accepted = volatileAcceptedSubmissions[record.draftID] {
                guard accepted.draftDigest == record.draftDigest, accepted.receiptDigest == record.receiptDigest,
                      record.phase != .completed else { throw MailAppError.message("发送恢复记录与本次接受结果不匹配，请保留草稿核对。") }
                result[record.draftID] = accepted.state
            } else { result[record.draftID] = record.state }
        }
        return result
    }
    func submissionStates(for draftIDs: [UUID]) throws -> [UUID: MailSubmissionState] {
        let ids = Set(draftIDs); return try submissionStates().filter { ids.contains($0.key) }
    }
    func submissionState(for draftID: UUID) throws -> MailSubmissionState? { try submissionStates(for: [draftID])[draftID] }
    /// This path has no credential lookup, connection, SMTP, or sent-folder APPEND.
    func retrySubmissionLocalSave(draftID: UUID) throws {
        guard !sending else { throw MailAppError.message("请等待当前发送结束后，只重试本地保存。") }
        guard let state = try submissionState(for: draftID), state.phase != .pending else {
            throw MailAppError.message("发送状态待确认，请在服务商的已发送中人工核对；不能重发或把未知结果标为已发送。")
        }
        defer { submissionRevision += 1 }
        do { try finishSubmissionLocalSave(draftID: draftID) }
        catch { throw MailAppError.message("服务商已接受发送，本地保存仍未完成；请勿重发。" + error.localizedDescription) }
    }
    private func readSubmissionAttachments(_ draft: MailDraft) throws -> [TransportAttachment] {
        var attachments: [TransportAttachment] = [], total = 0
        for file in draft.attachments {
            let url = URL(fileURLWithPath:file.path), info = try url.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey])
            guard info.isRegularFile == true, let size = info.fileSize, size < 24_000_000 - total else { throw MailAppError.message("附件必须为普通文件，附件总大小请控制在 24 MB 以内。") }
            let handle = try FileHandle(forReadingFrom:url)
            let data: Data
            do { data = try handle.read(upToCount:24_000_000 - total) ?? Data(); try handle.close() } catch { try? handle.close(); throw error }
            total += data.count
            guard total < 24_000_000 else { throw MailAppError.message("附件总大小超过 24 MB，请减少附件。") }
            attachments.append(TransportAttachment(filename:file.name,data:data))
        }
        return attachments
    }
    private func submissionReceipt(draft: MailDraft, attachments: [TransportAttachment], date: Date) throws -> CachedMessage {
        guard let accountID = draft.accountID else { throw MailAppError.message("发送事务缺少原邮箱标识。") }
        return CachedMessage(id:accountID.uuidString + "|local|" + draft.id.uuidString,accountID:accountID,folder:"__local_sent__",uid:0,subject:draft.subject,from:draft.from,to:MailValidation.recipients(draft.to).joined(separator:", "),cc:MailValidation.recipients(draft.cc).joined(separator:", "),date:date,preview:String(draft.body.prefix(150)),body:draft.body,html:nil,isRead:true,isFlagged:false,messageID:nil,references:draft.references,attachments:zip(draft.attachments, attachments).map{CachedAttachment(id:$0.0.id,filename:$0.1.filename,mimeType:$0.1.mimeType,data:$0.1.data)},loaded:true)
    }
    private func finishSubmissionLocalSave(draftID: UUID) throws {
        var ledger = try storage.loadSubmissions()
        guard let index = ledger.records.firstIndex(where: { $0.draftID == draftID }) else { throw MailAppError.message("找不到本机发送事务，不能重试发送。") }
        if let accepted = volatileAcceptedSubmissions[draftID] {
            guard ledger.records[index].draftDigest == accepted.draftDigest, ledger.records[index].receiptDigest == accepted.receiptDigest,
                  ledger.records[index].phase != .completed else { throw MailAppError.message("发送事务已变化，请保留恢复记录。") }
            ledger.records[index] = accepted
            try storage.saveSubmissions(ledger)
            volatileAcceptedSubmissions[draftID] = nil
        }
        let record = ledger.records[index]
        if record.phase == .completed { return }
        guard record.phase == .accepted else { throw MailAppError.message("发送状态待确认。请在服务商的已发送中人工核对；不能重复发送，也不能将未知结果标为已发送。") }
        let receipt: CachedMessage
        if let memory = volatileSubmissionReceipts[draftID], try record.matchesReceipt(memory) { receipt = memory }
        else if let cached = messages.first(where: { $0.id == record.receiptID }), try record.matchesReceipt(cached) { receipt = cached }
        else {
            guard let original = library.drafts.first(where: { $0.id == draftID }), try record.matchesDraft(original) else { throw MailAppError.message("原始草稿缺失或已变化，请保留发送事务并人工核对；不能重发。") }
            receipt = try submissionReceipt(draft: original, attachments: readSubmissionAttachments(original), date: record.attemptedAt)
            guard try record.matchesReceipt(receipt) else { throw MailAppError.message("原附件或草稿内容已变化，不能将其他内容存作原发送副本；请人工核对，不能重发。") }
        }
        // Commit cache before removing the original draft. Both writes are local
        // and idempotent by receipt/draft ID; errors never call SMTP again.
        var next = messages.filter { $0.id != record.receiptID }; next.append(receipt)
        try submissionPersistenceHook(.cache); try storage.saveMessages(next); messages = next
        var libraryNext = library; libraryNext.drafts.removeAll { $0.id == draftID }
        try submissionPersistenceHook(.library); try commit(libraryNext)
        ledger.records[index].phase = .completed
        do { try storage.saveSubmissions(ledger) }
        catch {
            // Cache and draft removal already committed. The durable accepted
            // metadata remains a resend barrier even if its final annotation fails.
            problem = "邮件及本地记录已保存，发送事务收尾未完成；请保留记录，切勿重发。"
        }
        volatileSubmissionReceipts[draftID] = nil
        notice = "邮件服务商已接受发送，本地记录已保存"
        if let warning = record.state.warning { problem = warning }
    }
    func send(_ draft: MailDraft) async throws {
        guard try submissionState(for: draft.id) == nil else { throw MailAppError.message("此草稿已有发送事务，不能再次发送。已接受的邮件只能重试本地保存；状态待确认时请人工核对服务商的已发送。") }
        guard !sending, let a = account(draft.accountID), a.enabled else { throw MailAppError.message("请选择已启用收发的邮箱。") }
        let to = MailValidation.recipients(draft.to), cc = MailValidation.recipients(draft.cc), bcc = MailValidation.recipients(draft.bcc)
        guard !(to+cc+bcc).isEmpty, (to+cc+bcc).allSatisfy(MailValidation.address) else { throw MailAppError.message("请检查收件人地址，多个地址使用逗号分隔。") }
        guard a.allowedAddresses.contains(where:{$0.lowercased() == draft.from.lowercased()}) else { throw MailAppError.message("发件地址必须属于此邮箱或已登记的别名。") }
        try requireHostConnection(a)
        try saveDraft(draft)
        sending = true; defer { sending = false; submissionRevision += 1 }
        let attachments = try readSubmissionAttachments(draft), attemptedAt = Date()
        let receipt = try submissionReceipt(draft: draft, attachments: attachments, date: attemptedAt)
        var ledger = try storage.loadSubmissions()
        guard !ledger.records.contains(where: { $0.draftID == draft.id }) else { throw MailAppError.message("此草稿已有发送事务，未重复发送。") }
        var record = MailSubmissionRecord(draftID: draft.id, accountID: a.id, draftDigest: try MailSubmissionRecord.digest(of: draft), receiptDigest: try MailSubmissionRecord.digest(of: receipt), attemptedAt: attemptedAt)
        ledger.records.append(record)
        try storage.saveSubmissions(ledger) // Durable metadata BEFORE any credential/network resolution.
        let result: TransportSendResult
        do {
            let c: TransportConnection
            if let resolveSubmissionConnection { try requireHostConnection(a); c = try await resolveSubmissionConnection(a) }
            else { c = try await connection(for:a) }
            let outgoing = TransportOutgoing(from:draft.from,fromName:a.name,to:to,cc:cc,bcc:bcc,subject:draft.subject,body:draft.body,attachments:attachments,inReplyTo:draft.inReplyTo,references:draft.references)
            let sentFolder = a.sentFolder?.trimmingCharacters(in:.whitespacesAndNewlines)
            result = try await sendMail(c, outgoing, sentFolder?.isEmpty == false ? sentFolder : nil)
            guard result.acceptedByServer else { throw MailAppError.message("服务商未返回接受确认。") }
        } catch {
            throw MailAppError.message("发送状态待确认，已保留原草稿和本机事务。请先人工核对服务商的已发送，切勿重复发送。" + error.localizedDescription)
        }
        record.phase = .accepted; record.acceptedAt = Date(); record.sentCopyFailed = result.sentCopyWarning != nil
        // If saving this phase fails, retain accepted metadata/receipt in memory;
        // after a crash the durable pending metadata still prevents another SMTP.
        volatileAcceptedSubmissions[draft.id] = record; volatileSubmissionReceipts[draft.id] = receipt
        connectionSucceeded(a)
        do { try finishSubmissionLocalSave(draftID: draft.id) }
        catch { throw MailAppError.message("邮件服务商已接受发送，但本地保存尚未完成。请勿重发；保留此草稿，仅使用“只重试本地保存”。" + error.localizedDescription) }
    }
    private func notify(count: Int, account: MailAccount) {
        let content = UNMutableNotificationContent(); content.title = "搞门户邮件 · " + identityName(for:account); content.body = "\(account.displayName) 收到 \(count) 封新邮件"; content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier:UUID().uuidString,content:content,trigger:nil))
    }
    func askNotifications() { UNUserNotificationCenter.current().requestAuthorization(options:[.alert,.sound,.badge]) { _,_ in } }
    func exportBackup() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "搞门户-邮件资料备份.json"; panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try MailStorage.encoder.encode(library).write(to:url,options:.atomic); notice = "资料备份已导出（不含密码与邮件缓存）" } catch { publish(error) }
    }
    func restoreBackup() {
        guard busy.isEmpty && detailBusy.isEmpty && !sending && compose == nil else { problem = "请关闭写信窗口，并等待当前收发和读取结束。"; return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            var incoming = try MailStorage.decoder.decode(MailLibrary.self,from:Data(contentsOf:url)); try MailValidation.validate(incoming)
            let alert = NSAlert(); alert.messageText = "恢复资料备份？"; alert.informativeText = "将替换当前的身份、邮箱资料、平台记录和草稿，并清空当前邮件视图。备份内有 \(incoming.accounts.count) 个邮箱、\(incoming.platforms.count) 条平台记录。当前资料和邮件缓存（含本机发送记录）会先保存恢复前副本，存放在数据文件夹中。恢复后邮箱设为仅登记，请重新检查收发授权。"; alert.addButton(withTitle:"恢复"); alert.addButton(withTitle:"取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            for i in incoming.accounts.indices { incoming.accounts[i].enabled = false; incoming.accounts[i].syncError = nil; incoming.accounts[i].lastSync = nil }
            try storage.restore(incoming); library = incoming; messages = []; try storage.saveMessages([]); identityFilter = nil; mailboxFilter = nil; notice = "资料已恢复，请重新检查邮箱授权"
        } catch { publish(error) }
    }
    func exportCSV() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "搞门户-邮件关联平台.csv"; panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try PlatformCSV.encode(library.platforms,accounts:library.accounts).write(to:url,atomically:true,encoding:.utf8); notice = "平台清单已导出" } catch { publish(error) }
    }
    func importCSV() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.commaSeparatedText,.plainText]; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let rows = try PlatformCSV.parse(String(contentsOf:url,encoding:.utf8))
            guard let header = rows.first, header == PlatformCSV.headers else { throw MailAppError.message("CSV 表头不匹配。请先导出一份平台清单作为模板。") }
            var additions: [PlatformRecord] = []; var skipped = 0
            for (index,row) in rows.dropFirst().enumerated() {
                guard row.count == 9 else { throw MailAppError.message("CSV 第 \(index+2) 行列数不正确，未导入任何记录。") }
                guard !row[0].trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw MailAppError.message("CSV 第 \(index+2) 行缺少平台名称。") }
                if !row[1].isEmpty && !MailValidation.address(row[1]) { throw MailAppError.message("CSV 第 \(index+2) 行邮箱格式不正确。") }
                if !row[3].isEmpty && MailValidation.webURL(row[3]) == nil { throw MailAppError.message("CSV 第 \(index+2) 行网址格式不正确。") }
                if (library.platforms + additions).contains(where:{$0.name == row[0] && $0.address == row[1] && $0.username == row[2]}) { skipped += 1; continue }
                let a = library.accounts.first {$0.allowedAddresses.contains(where:{$0.lowercased() == row[1].lowercased()})}
                additions.append(PlatformRecord(accountID:a?.id,name:row[0],url:row[3],username:row[2],address:row[1],kind:row[4],loginMethod:row[5],roles:row[6].components(separatedBy:" / "),status:row[7],notes:row[8],history:[PlatformHistory(text:"从 CSV 导入")]))
            }
            let alert = NSAlert(); alert.messageText = "导入 \(additions.count) 条平台关联？"; alert.informativeText = "跳过 \(skipped) 条重复记录。无法匹配到已添加邮箱的记录会保留地址，显示为未关联。"; alert.addButton(withTitle:"导入"); alert.addButton(withTitle:"取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            var v = library; v.platforms += additions; try commit(v); notice = "平台记录已导入"
        } catch { publish(error) }
    }
}
