import AppKit
import SwiftUI

/// A new browser account is committed only after the provider identity and mail
/// connections have been verified. Manual entry remains an explicit choice.
@MainActor struct AddMailAccountView: View {
    @ObservedObject var store: MailStore
    @Environment(\.dismiss) private var dismiss
    var openSettings: () -> Void
    @State private var identityID: UUID?
    @State private var guide: MailAccountSetupGuide?
    @State private var manualAccount: MailAccount?
    @State private var organizationExpanded = false
    @State private var authorizationTask: Task<Void, Never>?
    @State private var authorizationID: UUID?
    @State private var activeProvider: OAuthProvider?
    @State private var error: String?

    init(store: MailStore, openSettings: @escaping () -> Void = { NotificationCenter.default.post(name: .mailOpenSettings, object: nil) }) {
        self.store = store
        self.openSettings = openSettings
        _identityID = State(initialValue: store.identityFilter)
    }

    private var working: Bool { authorizationID != nil }

    var body: some View {
        Group {
            if let manualAccount {
                AccountEditor(store: store, account: nil, initialAccount: manualAccount, onBack: {
                    self.manualAccount = nil
                    guide = nil
                }).id(manualAccount.id)
            } else {
                onboarding
            }
        }
        .onDisappear { cancelAuthorization() }
    }

    private var onboarding: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "envelope.badge")
                    .font(.system(size: 25, weight: .medium)).foregroundStyle(.indigo)
                    .frame(width: 48, height: 48)
                    .background(.indigo.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) {
                    Text(guide?.title ?? "添加邮箱").font(.title2.bold())
                    Text(guide == nil ? "选择邮箱服务商，使用适合你的登录方式。" : "在服务商官网准备好授权码，再回来连接邮箱。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(22)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let guide { guideContent(guide) }
                    else { providerChoices }
                }.padding(22)
            }.disabled(working)
            if let error {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22).padding(.bottom, 14)
            }
            Divider()
            footer
        }
        .frame(width: 760, height: 730)
    }

    private var providerChoices: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text("网页登录后自动添加").font(.headline)
                Text("在官方网页选择账号并允许访问；连接验证成功后自动进入收件箱。")
                    .font(.callout).foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 14) {
                    browserProviderCard(.google, title: "Gmail / Google Workspace", symbol: "envelope.fill", detail: "个人 Gmail，以及由 Google 托管的工作或学校邮箱。")
                    browserProviderCard(.microsoft, title: "Outlook / Microsoft 365", symbol: "square.grid.2x2.fill", detail: "Outlook、Hotmail，以及 Microsoft 365 工作或学校邮箱。")
                }
            }
            identityPicker
            VStack(alignment: .leading, spacing: 11) {
                Text("使用授权码或应用密码").font(.headline)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(MailAccountSetupGuide.allCases) { option in
                        Button {
                            error = nil
                            guide = option
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "key.fill").foregroundStyle(.indigo)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(option.title).font(.callout.weight(.semibold))
                                    Text(option.summary).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 4)
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                            }.padding(13).frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.primary.opacity(0.08)))
                        }.buttonStyle(.plain)
                    }
                }
            }
            DisclosureGroup(isExpanded: $organizationExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(".cn、.edu、.edu.cn 等后缀不能确定邮箱服务商。请按学校或企业实际使用的服务选择；不确定时可向管理员查询 IMAP / SMTP 设置。")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("Google Workspace") { startBrowserLogin(.google) }
                        Button("Microsoft 365") { startBrowserLogin(.microsoft) }
                        Button("其他 IMAP / SMTP") { openManual(.custom) }
                    }
                }.padding(.top, 10)
            } label: {
                Label("企业 / 学校邮箱", systemImage: "building.2").font(.headline)
            }
            Divider()
            HStack(spacing: 16) {
                Button("其他邮箱 / 手动配置", systemImage: "slider.horizontal.3") { openManual(.custom) }
                Spacer()
                Button("仅登记邮箱资料", systemImage: "person.crop.rectangle") { openManual(.custom, registerOnly: true) }
            }
        }
    }

    private var identityPicker: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("主要身份").font(.callout.weight(.medium))
                Text("可选，添加后仍可修改。").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("主要身份", selection: $identityID) {
                Text("未分类").tag(UUID?.none)
                ForEach(store.library.identities) { identity in
                    Label(identity.name, systemImage: identity.symbol).tag(Optional(identity.id))
                }
            }.labelsHidden().frame(width: 220)
        }.padding(14)
            .background(.indigo.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
    }

    private func browserProviderCard(_ provider: OAuthProvider, title: String, symbol: String, detail: String) -> some View {
        let unavailable = store.browserLoginAvailability(provider: provider)
        return VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 38, alignment: .top)
            Button { startBrowserLogin(provider) } label: {
                Label("网页登录添加", systemImage: "arrow.up.right.square").frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent).controlSize(.large).disabled(unavailable != nil)
            if let unavailable {
                VStack(alignment: .leading, spacing: 5) {
                    Text("网页登录服务尚未配置").font(.caption).foregroundStyle(.secondary).help(unavailable)
                    Button("打开网页登录配置…", action: showLoginSettings).font(.caption).buttonStyle(.link)
                }
            }
        }.padding(17).frame(maxWidth: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.indigo.opacity(0.18)))
    }

    private func guideContent(_ selected: MailAccountSetupGuide) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(selected.introduction).font(.body).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 18) {
                ForEach(Array(selected.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 12) {
                        Text("\(index + 1)").font(.callout.bold()).foregroundStyle(.indigo)
                            .frame(width: 26, height: 26).background(.indigo.opacity(0.09), in: Circle())
                        Text(step).font(.body).fixedSize(horizontal: false, vertical: true).padding(.top, 3)
                    }
                }
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            HStack(spacing: 14) {
                Button(selected.linkTitle, systemImage: "arrow.up.right.square") { openOfficialPage(selected.officialURL) }
                if selected == .mailcom {
                    Button("应用密码说明", systemImage: "arrow.up.right.square") {
                        openOfficialPage("https://support.mail.com/security/2fa/application-specific-passwords.html")
                    }
                }
            }
            Text("在网页中登录只用于管理邮箱设置；请回到搞门户 · 邮件填写授权码或应用密码以完成连接。")
                .font(.callout).foregroundStyle(.secondary)
            identityPicker
            HStack {
                Button("继续填写邮箱与授权码") { openManual(selected.provider) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                Button("仅登记资料") { openManual(selected.provider, registerOnly: true) }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if working {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.browserLoginStatus ?? "正在打开官方登录网页…").font(.callout)
                    Text("请在浏览器中完成 \(activeProvider == .google ? "Google" : "Microsoft") 登录并允许邮箱访问。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("取消本次添加") { cancelAuthorization(); error = "已取消本次添加。" }
            } else {
                if guide != nil {
                    Button("返回服务商", systemImage: "chevron.left") { guide = nil; error = nil }
                } else {
                    Text("凭据安全保存在此 Mac 的钥匙串中。").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            Button(working ? "取消并关闭" : "关闭") { cancelAuthorization(); dismiss() }
                .keyboardShortcut(.cancelAction)
        }.padding(18)
    }

    private func openManual(_ provider: MailProvider, registerOnly: Bool = false) {
        var account = MailAccount()
        account.provider = provider
        account.applyProvider()
        account.auth = "password"
        account.identityID = identityID
        account.enabled = !registerOnly
        error = nil
        manualAccount = account
    }

    private func startBrowserLogin(_ provider: OAuthProvider) {
        guard !working else { return }
        if let unavailable = store.browserLoginAvailability(provider: provider) {
            error = "网页登录服务尚未配置。\(unavailable)请点击“打开网页登录配置”，或选择手动配置。"
            return
        }
        error = nil
        activeProvider = provider
        let attempt = UUID()
        authorizationID = attempt
        authorizationTask = Task { @MainActor in
            defer {
                if authorizationID == attempt {
                    authorizationTask = nil
                    authorizationID = nil
                    activeProvider = nil
                }
            }
            do {
                let account = try await store.addAccountUsingBrowser(provider: provider, identityID: identityID)
                guard !Task.isCancelled, authorizationID == attempt else { return }
                store.openCachedInbox(accountID: account.id)
                authorizationID = nil
                authorizationTask = nil
                activeProvider = nil
                dismiss()
                Task { @MainActor in await store.sync(account.id, folder: "INBOX") }
            } catch {
                guard !Task.isCancelled, authorizationID == attempt else { return }
                self.error = error.localizedDescription
            }
        }
    }

    private func cancelAuthorization() {
        guard authorizationID != nil else { return }
        authorizationID = nil
        // The manager's cancellation handler checks its session generation before
        // calling cancel(), so closing this sheet cannot cancel another window.
        authorizationTask?.cancel()
        authorizationTask = nil
        activeProvider = nil
    }

    private func showLoginSettings() {
        // Release the add-account sheet before moving focus to the editable
        // Settings window. The user can reopen Add after saving configuration.
        dismiss()
        DispatchQueue.main.async {
            openSettings()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .mailSettingsTab, object: "module")
            }
        }
    }

    private func openOfficialPage(_ address: String) {
        guard let url = URL(string: address), url.scheme == "https",
              ["help.mail.qq.com", "mail.163.com", "vip.163.com", "support.mail.com"].contains(url.host ?? "") else { return }
        if !NSWorkspace.shared.open(url) { error = "无法打开官方网页，请检查默认浏览器设置。" }
    }
}

private enum MailAccountSetupGuide: String, CaseIterable, Identifiable {
    case qq, netease, vip163, mailcom
    var id: String { rawValue }
    var provider: MailProvider {
        switch self {
        case .qq: return .qq
        case .netease: return .netease
        case .vip163: return .vip163
        case .mailcom: return .mailcom
        }
    }
    var title: String {
        switch self {
        case .qq: return "QQ 邮箱"
        case .netease: return "163 邮箱"
        case .vip163: return "VIP 163 邮箱"
        case .mailcom: return "mail.com"
        }
    }
    var summary: String { self == .mailcom ? "Premium · 应用密码" : "开启收发 · 获取授权码" }
    var introduction: String {
        switch self {
        case .qq: return "使用 QQ 邮箱生成的客户端授权码连接，收发服务器会自动填好。"
        case .netease, .vip163: return "搞门户 · 邮件目前通过客户端授权码连接此邮箱，收发服务器会自动填好。"
        case .mailcom: return "通过 IMAP 连接 mail.com 需要 Premium 权限；启用两步验证时，请为搞门户 · 邮件生成应用密码。"
        }
    }
    var steps: [String] {
        switch self {
        case .qq:
            return ["打开官方授权码说明，登录 QQ 邮箱。", "在“设置 → 账号与安全 → 安全设置”开启 IMAP / SMTP，并生成授权码。", "回到这里，填写完整邮箱地址和授权码。"]
        case .netease, .vip163:
            return ["打开对应的网易邮箱官网，登录你的邮箱。", "在邮箱设置中开启 IMAP / SMTP，并按页面提示获取客户端授权码。", "回到这里，填写完整邮箱地址和授权码。"]
        case .mailcom:
            return ["确认账号具有 Premium 的 IMAP 权限，并在邮箱设置中启用 POP3 / IMAP。", "启用两步验证的账号，在安全设置中生成应用密码。", "回到这里填写邮箱地址和应用密码，并测试收发连接。"]
        }
    }
    var linkTitle: String {
        switch self {
        case .qq: return "打开官方授权码说明"
        case .netease, .vip163: return "打开官方邮箱网页"
        case .mailcom: return "打开官方连接说明"
        }
    }
    var officialURL: String {
        switch self {
        case .qq: return "https://help.mail.qq.com/detail/106/985"
        case .netease: return "https://mail.163.com/"
        case .vip163: return "https://vip.163.com/"
        case .mailcom: return "https://support.mail.com/pop-imap/setting-up-pop-imap.html"
        }
    }
}
