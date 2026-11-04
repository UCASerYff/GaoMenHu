import AppKit
import SwiftUI

private struct MailEditorHeader: View {
    let title: String
    let subtitle: String
    let symbol: String
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 25, weight: .medium)).foregroundStyle(.indigo)
                .frame(width: 48, height: 48).background(.indigo.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title2.bold())
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }.padding(22)
    }
}

private struct MailEditorFeedback: View {
    let error: String?
    var success: String? = nil
    var body: some View {
        if let error {
            Label(error, systemImage: "exclamationmark.circle.fill").font(.callout).foregroundStyle(.red)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22).padding(.vertical, 10)
        } else if let success {
            Label(success, systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.green)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22).padding(.vertical, 10)
        }
    }
}

@MainActor struct AccountEditor: View {
    @ObservedObject var store: MailStore
    @Environment(\.dismiss) private var dismiss
    @State private var value: MailAccount
    @State private var password = ""
    @State private var error: String?
    @State private var success: String?
    @State private var testing = false
    @State private var authorizing = false
    @State private var aliasSheet = false
    @State private var authorizationTask: Task<Void, Never>?
    @State private var authorizationID: UUID?
    private let wasExisting: Bool
    private let onBack: (() -> Void)?

    init(store: MailStore, account: MailAccount?, initialAccount: MailAccount? = nil, onBack: (() -> Void)? = nil) {
        self.store = store
        var initial = account ?? initialAccount ?? MailAccount()
        if account == nil && initialAccount == nil { initial.identityID = store.identityFilter }
        _value = State(initialValue: initial)
        wasExisting = account != nil
        self.onBack = onBack
    }
    private var working: Bool { testing || authorizing }
    var body: some View {
        VStack(spacing: 0) {
            MailEditorHeader(title: wasExisting ? "编辑邮箱" : (value.enabled ? "手动添加邮箱" : "登记邮箱资料"), subtitle: "为邮箱选择身份，再决定是否连接收发。", symbol: "envelope.badge")
            Divider()
            Form {
                Section("邮箱资料") {
                    TextField("邮箱地址", text: $value.email, prompt: Text("name@example.com"))
                        .disabled(wasExisting)
                        .onChange(of: value.email) { previous, current in
                            if value.username.isEmpty || value.username == previous { value.username = current }
                        }
                    if wasExisting {
                        Text("邮箱地址保存后不能更改。要使用另一个地址，请移除此邮箱后重新添加；别名可在下方维护。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    TextField("显示名称", text: $value.name, prompt: Text("例如：学校主邮箱"))
                    Picker("主要身份", selection: $value.identityID) {
                        Text("未分类").tag(UUID?.none)
                        ForEach(store.library.identities) { identity in
                            Label(identity.name, systemImage: identity.symbol).tag(Optional(identity.id))
                        }
                    }
                    TextField("附加标签", text: $value.tags, prompt: Text("科研、投稿、海外服务"))
                    HStack {
                        TextField("邮箱别名", text: $value.aliases, prompt: Text("多个地址使用逗号分隔"))
                        Button("别名助手") {
                            aliasSheet = true
                        }.font(.caption).buttonStyle(.link).disabled(value.email.isEmpty)
                    }
                    Text("别名应为服务商已经允许此账号使用的发件地址。").font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Toggle("开启邮件收发", isOn: $value.enabled)
                    Text(value.enabled ? "保存后可以测试连接、同步邮件和发送邮件。" : "仅登记资料：管理身份和关联平台，无需填写密码。")
                        .font(.callout).foregroundStyle(.secondary)
                    Picker("邮箱服务商", selection: $value.provider) {
                        ForEach(MailProvider.allCases) { provider in Text(provider.rawValue).tag(provider) }
                    }.onChange(of: value.provider) { _, _ in
                        value.applyProvider()
                        if !wasExisting { value.auth = "password" }
                        success = nil; error = nil
                    }
                    Text(value.provider.note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } header: { Text("连接方式") }
                if value.enabled {
                    authenticationSection
                    serverSection
                }
                Section("发件签名") {
                    TextEditor(text: $value.signature).font(.body).frame(minHeight: 75)
                        .accessibilityLabel("邮箱签名")
                    Text("使用此邮箱新建邮件时自动带入签名。").font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).disabled(working)
            MailEditorFeedback(error: error, success: success)
            Divider()
            HStack {
                if let onBack { Button("返回服务商", systemImage: "chevron.left", action: onBack).disabled(working) }
                if working { ProgressView().controlSize(.small); Text(authorizing ? "资料已保存，等待浏览器授权…" : "正在测试收发连接…").foregroundStyle(.secondary).font(.callout) }
                if authorizing { Button("取消授权") { cancelAuthorization() } }
                Spacer()
                Button(authorizing ? "取消授权并关闭" : "取消") {
                    if authorizing { cancelAuthorization() }
                    dismiss()
                }.keyboardShortcut(.cancelAction).disabled(testing)
                Button("保存邮箱") { saveAndClose() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(working)
            }.padding(18)
        }.frame(width: 760, height: 730).interactiveDismissDisabled(testing)
            .sheet(isPresented: $aliasSheet) { AliasHelperView(store: store, initialAccountID: value.id) }
            .onDisappear { if authorizing { cancelAuthorization() } }
    }
    private var authenticationSection: some View {
        Section("登录与授权") {
            TextField("登录用户名", text: $value.username, prompt: Text("通常与邮箱地址一致"))
            if wasExisting {
                Picker("认证方式", selection: $value.auth) {
                    Text("客户端授权码 / 专用密码").tag("password")
                    Text("Google OAuth").tag("google")
                    Text("Microsoft OAuth").tag("microsoft")
                }
            } else if value.provider == .gmail || value.provider == .outlook {
                if let onBack {
                    Button("使用网页登录添加", systemImage: "arrow.up.right.square", action: onBack)
                    Text("返回服务商选择页后，可在官方网页登录并自动添加邮箱。手动配置请使用账号允许的应用密码。")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if value.auth == "password" {
                SecureField("授权码 / 密码", text: $password, prompt: Text(wasExisting ? "留空则保留已保存的凭据" : "输入客户端授权码或专用密码"))
                Text("凭据保存到 macOS 钥匙串，不写入资料备份。").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("首次使用请先在设置中填写对应 OAuth 客户端信息，再保存并打开官方授权页面。").font(.callout).foregroundStyle(.secondary)
                Button("保存并通过 \(value.auth == "google" ? "Google" : "Microsoft") 授权", systemImage: "arrow.up.right.square") { authorize() }
            }
            Button("测试收件与发件连接", systemImage: "network") { test() }
            Text("连接测试仅验证服务器登录，不发送邮件。").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var serverSection: some View {
        Section("服务器配置") {
            TextField("IMAP 收件服务器", text: $value.imapHost, prompt: Text("imap.example.com"))
            HStack {
                TextField("收件端口", value: $value.imapPort, format: .number.grouping(.never)).frame(maxWidth: 230)
                Picker("加密", selection: $value.imapTLS) {
                    Text("SSL / TLS").tag("tls")
                    Text("STARTTLS").tag("startTLS")
                }
            }
            TextField("SMTP 发件服务器", text: $value.smtpHost, prompt: Text("smtp.example.com"))
            HStack {
                TextField("发件端口", value: $value.smtpPort, format: .number.grouping(.never)).frame(maxWidth: 230)
                Picker("加密", selection: $value.smtpTLS) {
                    Text("SSL / TLS").tag("tls")
                    Text("STARTTLS").tag("startTLS")
                }
            }
            TextField("发送后保存到 IMAP 文件夹", text: Binding(get: { value.sentFolder ?? "" }, set: { value.sentFolder = $0.isEmpty ? nil : $0 }), prompt: Text("可选，例如 Sent"))
            Text("空白表示由服务商保存。自建邮箱可填写 Sent 或已发送文件夹的完整路径；Gmail、Outlook 通常会自动保存，额外设置可能产生重复副本。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("恢复所选服务商的默认配置") {
                value.applyProvider()
                if !wasExisting { value.auth = "password" }
                success = nil
            }
                .font(.callout)
        }
    }
    private func checkedValue() throws -> MailAccount {
        var v = value
        v.email = v.email.trimmingCharacters(in: .whitespacesAndNewlines)
        v.username = v.username.trimmingCharacters(in: .whitespacesAndNewlines)
        v.imapHost = v.imapHost.trimmingCharacters(in: .whitespacesAndNewlines)
        v.smtpHost = v.smtpHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard MailValidation.address(v.email) else { throw MailAppError.message("请填写有效的完整邮箱地址。") }
        if v.username.isEmpty { v.username = v.email }
        guard (1...65535).contains(v.imapPort), (1...65535).contains(v.smtpPort) else { throw MailAppError.message("服务器端口应在 1 到 65535 之间。") }
        if v.enabled && (v.imapHost.isEmpty || v.smtpHost.isEmpty) { throw MailAppError.message("请填写 IMAP 和 SMTP 服务器，或关闭收发以仅登记资料。") }
        return v
    }
    private func saveAndClose() {
        do { try store.saveAccount(checkedValue(), password: password.isEmpty ? nil : password); dismiss() }
        catch { self.error = error.localizedDescription; success = nil }
    }
    private func test() {
        error = nil; success = nil
        do {
            let account = try checkedValue(); testing = true
            Task { @MainActor in
                defer { testing = false }
                do { try await store.test(account, password: password.isEmpty ? nil : password); success = "收件和发件服务器登录均成功。" }
                catch { self.error = error.localizedDescription }
            }
        } catch { self.error = error.localizedDescription }
    }
    private func authorize() {
        error = nil; success = nil
        do {
            let account = try checkedValue(); try store.saveAccount(account, password: nil); value = account; authorizing = true
            let attempt = UUID(); authorizationID = attempt
            authorizationTask = Task { @MainActor in
                defer { if authorizationID == attempt { authorizing = false; authorizationTask = nil; authorizationID = nil } }
                do {
                    try await store.authorize(account)
                    guard !Task.isCancelled, authorizationID == attempt else { return }
                    success = "官方授权已完成，可以测试连接。"
                } catch {
                    guard !Task.isCancelled, authorizationID == attempt else { return }
                    self.error = error.localizedDescription
                }
            }
        } catch { self.error = error.localizedDescription }
    }
    private func cancelAuthorization() {
        authorizationID = nil
        // OAuthManager cancels only the generation owned by this task.
        authorizationTask?.cancel(); authorizationTask = nil; authorizing = false
        success = nil; error = "已取消授权。邮箱资料已保存，可稍后重新授权。"
    }
}

@MainActor struct IdentityEditor: View {
    @ObservedObject var store: MailStore
    @Environment(\.dismiss) private var dismiss
    @State private var value: MailIdentity
    @State private var error: String?
    private let wasExisting: Bool
    private let symbols = ["graduationcap.fill", "briefcase.fill", "house.fill", "flask.fill", "desktopcomputer", "cart.fill", "person.fill", "heart.fill", "airplane", "lock.fill", "star.fill", "globe"]
    private let colors = ["6366F1", "14877D", "DA8C48", "BD527C", "5078C8", "64748B", "B46F38", "8866B0"]
    init(store: MailStore, identity: MailIdentity?) {
        self.store = store; _value = State(initialValue: identity ?? MailIdentity(name: "", symbol: "person.fill", color: "6366F1")); wasExisting = identity != nil
    }
    var body: some View {
        VStack(spacing: 0) {
            MailEditorHeader(title: wasExisting ? "编辑身份" : "新建身份", subtitle: "一个身份可以管理多个邮箱。", symbol: value.symbol)
            Divider()
            Form {
                Section("身份名称") { TextField("名称", text: $value.name, prompt: Text("例如：科研、开发、生活")) }
                Section("图标") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                        ForEach(symbols, id: \.self) { symbol in
                            Button { value.symbol = symbol } label: {
                                Image(systemName: symbol).font(.title2).frame(width: 50, height: 40)
                                    .foregroundStyle(value.symbol == symbol ? Color.white : .primary)
                                    .background(value.symbol == symbol ? Color.indigo : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                            }.buttonStyle(.plain).accessibilityLabel("选择图标 \(symbol)")
                        }
                    }.padding(.vertical, 4)
                }
                Section("颜色") {
                    HStack(spacing: 15) {
                        ForEach(colors, id: \.self) { hex in
                            Button { value.color = hex } label: {
                                Circle().fill(editorColor(hex)).frame(width: 30, height: 30)
                                    .overlay { if value.color == hex { Image(systemName: "checkmark").font(.body.bold()).foregroundStyle(.white) } }
                            }.buttonStyle(.plain).accessibilityLabel("选择颜色 \(hex)")
                        }
                    }.padding(.vertical, 5)
                }
            }.formStyle(.grouped)
            MailEditorFeedback(error: error)
            Divider()
            HStack { Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction); Button("保存身份") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent) }.padding(18)
        }.frame(width: 600, height: 480)
    }
    private func save() {
        do { value.name = value.name.trimmingCharacters(in: .whitespacesAndNewlines); try store.saveIdentity(value); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}

private func editorColor(_ value: String) -> Color {
    let hex = UInt32(value, radix: 16) ?? 0x6366F1
    return Color(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
}

@MainActor struct PlatformEditor: View {
    @ObservedObject var store: MailStore
    @Environment(\.dismiss) private var dismiss
    @State private var value: PlatformRecord
    @State private var error: String?
    @State private var hasCheckedDate: Bool
    private let wasExisting: Bool
    init(store: MailStore, record: PlatformRecord?) {
        self.store = store
        var initial = record ?? PlatformRecord()
        if record == nil { initial.accountID = store.mailboxFilter; initial.address = store.account(initial.accountID)?.email ?? "" }
        _value = State(initialValue: initial); _hasCheckedDate = State(initialValue: initial.checkedAt != nil); wasExisting = record != nil
    }
    var body: some View {
        VStack(spacing: 0) {
            MailEditorHeader(title: wasExisting ? "编辑关联平台" : "登记关联平台", subtitle: "记下账号用了哪个邮箱，以及如何登录。", symbol: "link")
            Divider()
            Form {
                Section("平台资料") {
                    TextField("平台名称", text: $value.name, prompt: Text("GitHub、教务系统、常用 App…"))
                    TextField("平台账号 / 昵称", text: $value.username, prompt: Text("同一平台可登记多个账号"))
                    TextField("网址 / 登录入口", text: $value.url, prompt: Text("https://example.com"))
                    editableChoice("类型", text: $value.kind, choices: ["网站", "App", "服务", "学校系统", "企业系统"])
                }
                Section("邮箱与登录") {
                    Picker("关联邮箱", selection: $value.accountID) {
                        Text("暂未关联邮箱").tag(UUID?.none)
                        ForEach(store.library.accounts) { account in Text("\(account.email) · \(store.identityName(for: account))").tag(Optional(account.id)) }
                    }.onChange(of: value.accountID) { previous, current in
                        if value.address.isEmpty || value.address == store.account(previous)?.email { value.address = store.account(current)?.email ?? "" }
                    }
                    HStack {
                        TextField("实际关联地址", text: $value.address, prompt: Text("可填写邮箱别名或保留原地址"))
                        if let acc = store.account(value.accountID) {
                            Button("生成平台专属别名") {
                                let alias = AliasGenerator.makeServiceAlias(email: acc.email, service: value.name.isEmpty ? (value.url.isEmpty ? "service" : value.url) : value.name)
                                value.address = alias
                            }.font(.caption).buttonStyle(.link).help("根据当前平台名称为所选邮箱生成加号子地址专属别名")
                        }
                    }
                    editableChoice("登录方式", text: $value.loginMethod, choices: ["邮箱登录", "Google 登录", "Apple 登录", "Microsoft 登录", "手机号登录", "其他"])
                    HStack {
                        Text("关联用途")
                        Spacer()
                        ForEach(["登录", "通知", "找回"], id: \.self) { role in Toggle(role, isOn: roleBinding(role)).toggleStyle(.checkbox) }
                    }
                }
                Section("状态与备注") {
                    editableChoice("状态", text: $value.status, choices: ["使用中", "待确认", "已换绑", "已注销"])
                    Toggle("已核对实际绑定", isOn: $hasCheckedDate)
                        .onChange(of: hasCheckedDate) { _, enabled in value.checkedAt = enabled ? (value.checkedAt ?? Date()) : nil }
                    if hasCheckedDate {
                        DatePicker("最近核对日期", selection: Binding(get: { value.checkedAt ?? Date() }, set: { value.checkedAt = $0 }), displayedComponents: .date)
                    }
                    TextEditor(text: $value.notes).font(.body).frame(minHeight: 80).accessibilityLabel("平台备注")
                    Text("这里是你的个人记录。保存或换绑记录不会修改平台上的真实账号设置。").font(.caption).foregroundStyle(.secondary)
                }
                if !value.history.isEmpty {
                    Section("变更记录") {
                        ForEach(value.history.reversed()) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.text).font(.callout)
                                Text(item.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 3)
                        }
                    }
                }
            }.formStyle(.grouped)
            MailEditorFeedback(error: error)
            Divider()
            HStack { Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction); Button("保存关联") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent) }.padding(18)
        }.frame(width: 730, height: 730)
    }
    private func editableChoice(_ title: String, text: Binding<String>, choices: [String]) -> some View {
        HStack {
            TextField(title, text: text)
            Menu { ForEach(choices, id: \.self) { option in Button(option) { text.wrappedValue = option } } } label: { Image(systemName: "chevron.down") }
                .menuStyle(.borderlessButton).frame(width: 25).help("选择常用值，也可直接输入")
        }
    }
    private func roleBinding(_ role: String) -> Binding<Bool> {
        Binding(get: { value.roles.contains(role) }, set: { selected in
            if selected { if !value.roles.contains(role) { value.roles.append(role) } } else { value.roles.removeAll { $0 == role } }
        })
    }
    private func save() {
        do { if !hasCheckedDate { value.checkedAt = nil }; try store.savePlatform(value); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}

@MainActor struct ComposerView: View {
    @ObservedObject var store: MailStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: MailDraft
    @State private var error: String?
    @State private var savedAt: Date?
    @State private var saveTask: Task<Void, Never>?
    @State private var finished = false
    @State private var subjectWarning = false
    @State private var discardWarning = false
    @State private var showCopies = false
    @State private var submission: MailSubmissionState?
    @State private var submissionReadError: String?
    @State private var submissionChecked = false
    init(store: MailStore, initial: MailDraft) {
        self.store = store; _draft = State(initialValue: initial); _showCopies = State(initialValue: !initial.cc.isEmpty || !initial.bcc.isEmpty)
    }
    private var account: MailAccount? { store.account(draft.accountID) }
    private var recipientCount: Int { MailValidation.recipients(draft.to + "," + draft.cc + "," + draft.bcc).count }
    private var submissionLocked: Bool { !submissionChecked || submissionReadError != nil || submission != nil }
    private var senderIsValid: Bool {
        guard let account, account.enabled else { return false }
        return account.allowedAddresses.contains { $0.caseInsensitiveCompare(draft.from) == .orderedSame }
    }
    var body: some View {
        VStack(spacing: 0) {
            composerHeader
            Divider()
            ScrollView { composerContent }.frame(minHeight: 160)
            if !submissionChecked || submission != nil || submissionReadError != nil {
                ScrollView { submissionFeedback }.frame(maxHeight: 160)
            }
            MailEditorFeedback(error: error)
            Divider()
            composerFooter
        }.frame(width: 820, height: 750)
            .onAppear(perform: refreshSubmission)
            .onChange(of: store.submissionRevision) { _, _ in refreshSubmission() }
            .onChange(of: draft) { _, updated in
                if !finished { store.compose = updated }
                scheduleSave()
            }
            .onChange(of: draft.accountID) { previous, current in switchAccount(from: previous, to: current) }
            .onDisappear { saveTask?.cancel(); if !finished { persistDraft() } }
            .interactiveDismissDisabled(store.sending)
            .alert("发送没有主题的邮件？", isPresented: $subjectWarning) {
                Button("返回填写", role: .cancel) { }
                Button("仍然发送") { send() }
            } message: { Text("发件人：\(draft.from)\n共 \(recipientCount) 个收件地址。") }
            .alert("丢弃这封草稿？", isPresented: $discardWarning) {
                Button("保留草稿", role: .cancel) { }
                Button("丢弃", role: .destructive) { discard() }
            } message: { Text("邮件正文和本封草稿中的附件引用将被移除，原始附件文件保留。") }
    }
    private var composerContent: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                HStack {
                    Text("发件邮箱").foregroundStyle(.secondary).frame(width: 74, alignment: .trailing)
                    Picker("发件邮箱", selection: $draft.accountID) {
                        Text("选择邮箱").tag(UUID?.none)
                        ForEach(store.library.accounts) { a in
                            Text("\(a.displayName) · \(store.identityName(for: a))\(a.enabled ? "" : " · 仅登记")").tag(Optional(a.id))
                        }
                    }.labelsHidden()
                    if let account {
                        Text(store.identityName(for: account)).font(.caption.weight(.medium)).padding(.horizontal, 9).padding(.vertical, 4)
                            .background(.indigo.opacity(0.09), in: Capsule()).foregroundStyle(.indigo)
                    }
                }
                addressRow
                if account?.enabled == true && !senderIsValid {
                    Label("请使用此邮箱地址或在邮箱资料中登记过的别名。", systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 82)
                }
                composeField("收件人", text: $draft.to, prompt: "多个地址使用逗号分隔")
                if showCopies {
                    composeField("抄送", text: $draft.cc, prompt: "可选")
                    composeField("密送", text: $draft.bcc, prompt: "收件人不会看到此列表")
                }
                composeField("主题", text: $draft.subject, prompt: "填写邮件主题")
            }.padding(.horizontal, 22).padding(.vertical, 16).disabled(store.sending || submissionLocked)
            Divider()
            TextEditor(text: $draft.body).font(.system(size: 14)).padding(14).frame(minHeight: 210)
                .accessibilityLabel("邮件正文").disabled(store.sending || submissionLocked)
            if !draft.attachments.isEmpty { attachmentStrip }
        }
    }
    private var composerHeader: some View {
        HStack(spacing: 14) {
            Image(systemName: "square.and.pencil").font(.title2).foregroundStyle(.indigo)
            VStack(alignment: .leading, spacing: 3) {
                Text("写邮件").font(.title2.bold())
                Text(account?.enabled == true ? "\(draft.from) · \(store.identityName(for: account))" : "选择已开启收发的邮箱发送，或先存为草稿。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button(showCopies ? "收起抄送 / 密送" : "抄送 / 密送") { showCopies.toggle() }.font(.callout)
        }.padding(22)
    }
    private var addressRow: some View {
        HStack {
            Text("发件地址").foregroundStyle(.secondary).frame(width: 74, alignment: .trailing)
            TextField("发件地址", text: $draft.from, prompt: Text("已登记邮箱或别名")).labelsHidden()
            if let account, account.allowedAddresses.count > 1 {
                Menu("选择别名") { ForEach(account.allowedAddresses, id: \.self) { address in Button(address) { draft.from = address } } }.frame(width: 100)
            }
        }
    }
    private func composeField(_ label: String, text: Binding<String>, prompt: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary).frame(width: 74, alignment: .trailing)
            TextField(label, text: text, prompt: Text(prompt)).labelsHidden()
        }
    }
    private var attachmentStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(draft.attachments) { file in
                    HStack(spacing: 7) {
                        Image(systemName: "doc")
                        Text(file.name).lineLimit(1)
                        Button { draft.attachments.removeAll { $0.id == file.id } } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).help("移除此附件")
                    }.font(.callout).padding(.horizontal, 10).padding(.vertical, 8)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8)).help(file.path)
                }
            }.padding(.horizontal, 22)
        }.frame(height: 48).disabled(store.sending || submissionLocked)
    }
    @ViewBuilder private var submissionFeedback: some View {
        if !submissionChecked {
            Text("正在核对本机发送记录…").font(.callout).foregroundStyle(.secondary).padding(12)
        } else if let submissionReadError {
            VStack(alignment: .leading, spacing: 8) {
                Label("发送记录不可读，已停止发送", systemImage: "exclamationmark.triangle.fill").font(.callout.weight(.semibold))
                Text(submissionReadError).font(.caption).textSelection(.enabled)
                Button("重新核对本机记录", action: refreshSubmission)
            }.foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22).padding(.vertical, 10)
        } else if let submission {
            VStack(alignment: .leading, spacing: 8) {
                switch submission.phase {
                case .pending:
                    Label(store.sending ? "正在提交，请等待发送结果" : "提交结果尚未确定", systemImage: "exclamationmark.triangle.fill").font(.callout.weight(.semibold))
                    Text("服务商可能已接收此邮件，同一份草稿不会再次提交。请在服务商核对已发送记录或与收件人确认；原草稿与提交记录会保留，不会自动重发。")
                        .font(.caption)
                case .accepted:
                    Label("服务商已接收，等待本地保存", systemImage: "checkmark.circle").font(.callout.weight(.semibold))
                    Text("请勿重复发送。下面的操作只重试保存本机已发送副本和清理原草稿，不会再次连接 SMTP 或发送邮件。")
                        .font(.caption)
                    Button("只重试本地保存", action: retrySubmissionLocalSave).disabled(store.sending)
                case .completed:
                    Label("服务商已接收，本地发送记录已保存", systemImage: "checkmark.circle").font(.callout.weight(.semibold))
                    Text("此草稿保留原发送标识，不会再次提交。关闭即可返回邮件列表。")
                        .font(.caption)
                }
                if let warning = submission.warning, !warning.isEmpty { Text(warning).font(.caption).textSelection(.enabled) }
            }.foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22).padding(.vertical, 10)
        }
    }
    private var composerFooter: some View {
        VStack(spacing: 12) {
            HStack {
                Button("添加附件", systemImage: "paperclip") { addAttachments() }.disabled(store.sending || submissionLocked)
                if let account, !account.signature.isEmpty { Button("插入签名") { draft.body += "\n\n" + account.signature }.disabled(store.sending || submissionLocked) }
                Spacer()
                if store.sending { ProgressView().controlSize(.small); Text("正在提交邮件…").font(.caption).foregroundStyle(.secondary) }
                else if let savedAt { Text("草稿已保存 · \(savedAt.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                else { Text("正文、收件人与附件引用自动保存").font(.caption).foregroundStyle(.secondary) }
            }
            HStack {
                Button("丢弃草稿", role: .destructive) { discardWarning = true }.disabled(store.sending || submissionLocked)
                Spacer()
                Button(submission?.phase == .completed ? "关闭" : "存为草稿并关闭") { saveAndClose() }.keyboardShortcut(.cancelAction).disabled(store.sending)
                Button("发送\(recipientCount > 0 ? " · \(recipientCount) 人" : "")", systemImage: "paperplane.fill") {
                    if draft.subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { subjectWarning = true } else { send() }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: [.command])
                    .disabled(store.sending || submissionLocked || !senderIsValid || recipientCount == 0)
            }
        }.padding(18)
    }
    private func scheduleSave() {
        guard !finished, !store.sending, !submissionLocked else { return }
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 700_000_000) } catch { return }
            guard !Task.isCancelled, !finished, !store.sending, !submissionLocked else { return }
            persistDraft()
        }
    }
    private func persistDraft() {
        guard !submissionLocked else { return }
        do { try store.saveDraft(draft); savedAt = Date() } catch { self.error = "草稿尚未保存：" + error.localizedDescription }
    }
    private func saveAndClose() {
        saveTask?.cancel()
        refreshSubmission()
        if let submissionReadError { error = submissionReadError; return }
        if submission?.phase == .completed { finished = true; dismiss(); return }
        do { try store.saveDraft(draft); finished = true; dismiss() }
        catch { self.error = "草稿尚未保存：" + error.localizedDescription }
    }
    private func discard() {
        refreshSubmission()
        guard !submissionLocked else { return }
        saveTask?.cancel(); store.deleteDraft(draft.id)
        if store.library.drafts.contains(where: { $0.id == draft.id }) { error = "草稿删除失败，请重试。"; return }
        finished = true; dismiss()
    }
    private func switchAccount(from previous: UUID?, to current: UUID?) {
        let old = store.account(previous), next = store.account(current)
        draft.from = next?.email ?? ""
        let previousSignature = old?.signature ?? ""
        if draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.body.trimmingCharacters(in: .whitespacesAndNewlines) == previousSignature.trimmingCharacters(in: .whitespacesAndNewlines) {
            draft.body = next?.signature.isEmpty == false ? "\n\n" + next!.signature : ""
        }
    }
    private func addAttachments() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        panel.prompt = "添加附件"; panel.message = "附件总大小请控制在 24 MB 以内。"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !draft.attachments.contains(where: { $0.path == url.path }) { draft.attachments.append(DraftAttachment(path: url.path)) }
    }
    private func send() {
        error = nil; saveTask?.cancel()
        refreshSubmission()
        guard !submissionLocked else { return }
        Task { @MainActor in
            do { try await store.send(draft); finished = true; dismiss() }
            catch { self.error = error.localizedDescription; refreshSubmission(); persistDraft() }
        }
    }
    private func refreshSubmission() {
        do {
            submission = try store.submissionState(for: draft.id)
            submissionReadError = nil
        } catch {
            submission = nil
            submissionReadError = error.localizedDescription
        }
        submissionChecked = true
    }
    private func retrySubmissionLocalSave() {
        error = nil; saveTask?.cancel()
        do {
            try store.retrySubmissionLocalSave(draftID: draft.id)
            refreshSubmission()
            guard submission?.phase == .completed else { return }
            finished = true; dismiss()
        } catch { self.error = error.localizedDescription; refreshSubmission() }
    }
}

@MainActor struct AliasHelperView: View {
    @ObservedObject var store: MailStore
    var initialAccountID: UUID? = nil
    var onRegisterPlatform: ((String, String, UUID?) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var selectedAccountID: UUID?
    @State private var serviceName: String = ""
    @State private var customTag: String = ""
    @State private var options = AliasRuleOptions(useDots: true, usePlus: true, useGooglemailDomain: false)
    @State private var batchCount: Int = 20
    @State private var generatedAliases: [String] = []
    @State private var notice: String?
    @State private var copiedItem: String?

    init(store: MailStore, initialAccountID: UUID? = nil, onRegisterPlatform: ((String, String, UUID?) -> Void)? = nil) {
        self.store = store
        self.initialAccountID = initialAccountID
        self.onRegisterPlatform = onRegisterPlatform
        let initID = initialAccountID ?? store.mailboxFilter ?? store.library.accounts.first?.id
        _selectedAccountID = State(initialValue: initID)
    }

    private var currentAccount: MailAccount? {
        store.account(selectedAccountID) ?? store.library.accounts.first
    }

    private var isGmail: Bool {
        guard let acc = currentAccount else { return false }
        let d = acc.email.lowercased()
        return d.hasSuffix("@gmail.com") || d.hasSuffix("@googlemail.com") || acc.provider == .gmail
    }

    private var serviceAlias: String {
        guard let acc = currentAccount else { return "" }
        let tag = serviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        return AliasGenerator.makeServiceAlias(email: acc.email, service: tag.isEmpty ? "service" : tag)
    }

    var body: some View {
        VStack(spacing: 0) {
            MailEditorHeader(
                title: "邮箱别名助手",
                subtitle: "基于服务商规则与子地址（Plus-addressing）生成专属别名，全部进同一收件箱。",
                symbol: "sparkles.rectangle.stack"
            )
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // Account Picker
                    HStack(spacing: 12) {
                        Text("当前邮箱:").font(.system(size: 13, weight: .medium))
                        Picker("", selection: $selectedAccountID) {
                            ForEach(store.library.accounts) { acc in
                                Text("\(acc.displayName) (\(acc.email))").tag(Optional(acc.id))
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 320)
                        Spacer()
                    }

                    if let acc = currentAccount {
                        // Section 1: Service dedicated alias
                        VStack(alignment: .leading, spacing: 10) {
                            Text("1. 目标平台 / 服务专用别名").font(.system(size: 14, weight: .semibold))
                            Text("为某个网站（如 GitHub、Twitter、Steam）生成专属邮箱，平台发来的验证码与邮件仍会进原邮箱收件箱。")
                                .font(.caption).foregroundStyle(.secondary)

                            HStack(spacing: 10) {
                                TextField("输入平台名称或网址，如 github.com 或 steam", text: $serviceName)
                                    .textFieldStyle(.roundedBorder)
                            }

                            HStack(spacing: 12) {
                                Text(serviceAlias)
                                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                                    .textSelection(.enabled)
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))

                                Button(copiedItem == serviceAlias ? "已复制" : "复制别名") {
                                    copyText(serviceAlias)
                                }
                                .controlSize(.small)

                                Button("追加为此邮箱别名") {
                                    appendAliasToAccount(serviceAlias, account: acc)
                                }
                                .controlSize(.small)

                                if onRegisterPlatform != nil {
                                    Button("一键登记为关联平台") {
                                        dismiss()
                                        onRegisterPlatform?(serviceName.isEmpty ? "新平台" : serviceName, serviceAlias, acc.id)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                }
                            }
                        }
                        .padding(14)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08), lineWidth: 1))

                        // Section 2: Batch Generation Rules
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("2. 批量别名生成器").font(.system(size: 14, weight: .semibold))
                                Spacer()
                                if isGmail {
                                    Text("检测到 Gmail 格式，支持点号与镜像域").font(.caption).foregroundStyle(.indigo)
                                } else {
                                    Text("通用邮箱采用标准 + 标签子地址规则").font(.caption).foregroundStyle(.secondary)
                                }
                            }

                            HStack(spacing: 16) {
                                if isGmail {
                                    Toggle("点号打点 (Dot Trick)", isOn: $options.useDots)
                                    Toggle("加号后缀 (+ Suffix)", isOn: $options.usePlus)
                                    Toggle("googlemail.com 镜像域", isOn: $options.useGooglemailDomain)
                                } else {
                                    Toggle("启用加号子地址 (+ Tag)", isOn: $options.usePlus)
                                }
                            }.font(.callout)

                            HStack(spacing: 12) {
                                Button("立即批量生成") {
                                    generateBatch(for: acc)
                                }.buttonStyle(.borderedProminent).controlSize(.small)

                                if !generatedAliases.isEmpty {
                                    Button("一键复制全部 (\(generatedAliases.count))") {
                                        copyText(generatedAliases.joined(separator: "\n"))
                                        notice = "已复制全部 \(generatedAliases.count) 个别名"
                                    }.controlSize(.small)
                                }
                            }

                            if !generatedAliases.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(generatedAliases, id: \.self) { item in
                                        HStack {
                                            Text(item).font(.system(size: 12, design: .monospaced))
                                            Spacer()
                                            Button(copiedItem == item ? "已复制" : "复制") {
                                                copyText(item)
                                            }.font(.caption).buttonStyle(.borderless)
                                        }
                                        .padding(.horizontal, 10).padding(.vertical, 5)
                                        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
                                    }
                                }
                                .frame(maxHeight: 220)
                            }
                        }
                        .padding(14)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08), lineWidth: 1))
                    } else {
                        Text("请先在邮箱管理中添加至少一个邮箱账户。").foregroundStyle(.secondary)
                    }

                    if let msg = notice {
                        Label(msg, systemImage: "checkmark.circle.fill")
                            .font(.callout).foregroundStyle(.green)
                    }
                }.padding(22)
            }

            Divider()
            HStack {
                Spacer()
                Button("关闭") { dismiss() }.buttonStyle(.borderedProminent).controlSize(.regular)
            }.padding(16)
        }
        .frame(width: 680, height: 620)
        .onAppear {
            if let acc = currentAccount {
                generateBatch(for: acc)
            }
        }
    }

    private func generateBatch(for acc: MailAccount) {
        generatedAliases = AliasGenerator.generate(email: acc.email, count: batchCount, options: options)
    }

    private func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedItem = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if copiedItem == text { copiedItem = nil }
        }
    }

    private func appendAliasToAccount(_ alias: String, account: MailAccount) {
        var updated = account
        var currentAliases = updated.aliases.components(separatedBy: CharacterSet(charactersIn: ",;\n，；"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if !currentAliases.contains(alias) {
            currentAliases.append(alias)
            updated.aliases = currentAliases.joined(separator: ", ")
            do {
                try store.saveAccount(updated, password: nil)
                notice = "已将 \(alias) 保存到邮箱 \(account.displayName) 的别名列表中！"
            } catch {
                notice = "保存失败：\(error.localizedDescription)"
            }
        } else {
            notice = "此别名已经在该邮箱列表中。"
        }
    }
}
