import SwiftUI
import AppKit
import WebKit

extension Color {
    init(hex: String) { let value = UInt64(hex.replacingOccurrences(of:"#",with:""),radix:16) ?? 0x6366F1; self.init(red:Double((value>>16)&255)/255,green:Double((value>>8)&255)/255,blue:Double(value&255)/255) }
    static let mailCanvas = Color(nsColor:.windowBackgroundColor)
    static let mailInk = Color.primary
}
struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { content.padding(20).frame(maxWidth:.infinity,alignment:.leading).background(Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:14)).overlay(RoundedRectangle(cornerRadius:14).stroke(Color.primary.opacity(0.07),lineWidth:1)) }
}
struct IdentityBadge: View {
    var identity: MailIdentity?
    var body: some View { Label(identity?.name ?? "未分类",systemImage:identity?.symbol ?? "tray").font(.system(size:11,weight:.medium)).padding(.horizontal,9).padding(.vertical,5).foregroundStyle(Color(hex:identity?.color ?? "79818C")).background(Color(hex:identity?.color ?? "79818C").opacity(0.10),in:Capsule()) }
}
struct EmptyMailView: View {
    var icon: String
    var title: String
    var detail: String
    var button: String? = nil
    var action: (() -> Void)? = nil
    var body: some View {
        VStack(spacing:14) {
            Image(systemName:icon).font(.system(size:38,weight:.light)).foregroundStyle(PortalTheme.accent.opacity(0.65)).frame(width:84,height:84).background(PortalTheme.accent.opacity(0.065),in:RoundedRectangle(cornerRadius:25))
            Text(title).font(.system(size:21,weight:.semibold))
            Text(detail).font(.system(size:13)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth:380).lineSpacing(5)
            if let button, let action { Button(button,action:action).buttonStyle(.borderedProminent).tint(PortalTheme.accent).controlSize(.large).padding(.top,5) }
        }.frame(maxWidth:.infinity,maxHeight:.infinity).padding(30)
    }
}

struct PortalMailRootView: View {
    @ObservedObject var store: MailStore
    var showFloating: () -> Void = {}
    var openSettings: () -> Void = { NotificationCenter.default.post(name: .mailOpenSettings, object: nil) }
    @AppStorage("gaomenhu.mail.sidebarHidden") private var sidebarHidden = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var searchFocused: Bool
    @State private var compactSidebarVisible = false
    @State private var mainWindowActive = true
    @State private var accountSheet = false
    @State private var platformSheet = false
    @State private var identitySheet = false
    @State private var aliasSheet = false
    @State private var selectedAliasAccountID: UUID?
    @State private var editingAccount: MailAccount?
    @State private var editingPlatform: PlatformRecord?
    @State private var editingIdentity: MailIdentity?
    @State private var pendingAccountDelete: MailAccount?
    @State private var pendingPlatformDelete: PlatformRecord?
    @State private var pendingIdentityDelete: MailIdentity?
    @State private var pendingConnectionAccount: MailAccount?
    @State private var draftSubmissions: [UUID: MailSubmissionState] = [:]
    @State private var draftSubmissionReadError: String?
    @State private var draftSubmissionsChecked = false
    private let menu: [(String,String,String)] = [("overview","square.grid.2x2","总览"),("inbox","tray","收件箱"),("accounts","envelope.badge.person.crop","邮箱管理"),("platforms","link","关联平台"),("drafts","doc.text","草稿")]
    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 980
            windowLayout(compact:compact)
                .onReceive(NotificationCenter.default.publisher(for:.mailToggleSidebar)) { _ in toggleSidebar(compact:compact) }
                .onChange(of:compact) { _, _ in compactSidebarVisible = false }
        }
        .tint(PortalTheme.accent)
        .animation(reduceMotion ? nil : .easeInOut(duration:0.18),value:sidebarHidden)
        .animation(reduceMotion ? nil : .easeInOut(duration:0.18),value:compactSidebarVisible)
        .onReceive(NotificationCenter.default.publisher(for:.mailFocusSearch)) {_ in
            if !["inbox","platforms"].contains(store.route) {store.route = "inbox"}
            compactSidebarVisible = false
            DispatchQueue.main.async {searchFocused = true}
        }
        .onReceive(NotificationCenter.default.publisher(for:.mailOpenAliasHelper)) {_ in
            selectedAliasAccountID = store.mailboxFilter
            aliasSheet = true
        }
        .onReceive(NotificationCenter.default.publisher(for:NSWindow.didBecomeKeyNotification)) {note in
            guard let window = note.object as? NSWindow else {return}
            mainWindowActive = window.identifier?.rawValue == "GaoMenHu.Mail.Main"
        }
        .task(id:store.notice) {
            guard let current = store.notice else {return}
            do {try await Task.sleep(nanoseconds:8_000_000_000)} catch {return}
            if store.notice == current {store.notice = nil}
        }
        .sheet(isPresented:$accountSheet) {
            if let editingAccount { AccountEditor(store:store,account:editingAccount) }
            else { AddMailAccountView(store:store, openSettings:openSettings) }
        }
        .sheet(isPresented:$platformSheet) { PlatformEditor(store:store,record:editingPlatform) }
        .sheet(isPresented:$identitySheet) { IdentityEditor(store:store,identity:editingIdentity) }
        .sheet(isPresented:$aliasSheet) { AliasHelperView(store:store,initialAccountID:selectedAliasAccountID,onRegisterPlatform:{ name, addr, accID in editingPlatform = PlatformRecord(accountID:accID,name:name,address:addr); platformSheet = true }) }
        .sheet(item:$store.compose) { draft in ComposerView(store:store,initial:draft) }.interactiveDismissDisabled(store.sending)
        .alert("操作提示",isPresented:Binding(get:{store.problem != nil && mainWindowActive},set:{if !$0 && mainWindowActive {store.problem = nil}})) { Button("知道了",role:.cancel) {store.problem = nil} } message: {Text(store.problem ?? "")}
        .confirmationDialog("移除这个邮箱？",isPresented:Binding(get:{pendingAccountDelete != nil},set:{if !$0 {pendingAccountDelete = nil}}),titleVisibility:.visible) {
            Button("移除邮箱并保留平台记录",role:.destructive) { if let a = pendingAccountDelete {store.deleteAccount(a.id)}; pendingAccountDelete = nil }
        } message: { Text("将清除本机此邮箱的连接凭据及邮件缓存，保留平台资料与草稿；不删除邮箱服务器上的邮件。") }
        .confirmationDialog("删除平台记录？",isPresented:Binding(get:{pendingPlatformDelete != nil},set:{if !$0 {pendingPlatformDelete = nil}}),titleVisibility:.visible) {
            Button("删除记录",role:.destructive) { if let p = pendingPlatformDelete {store.deletePlatform(p.id)}; pendingPlatformDelete = nil }
        } message: { Text("这只删除搞门户 · 邮件中的登记，不会注销网站或 App 账号。") }
        .confirmationDialog("删除这个身份？",isPresented:Binding(get:{pendingIdentityDelete != nil},set:{if !$0 {pendingIdentityDelete = nil}}),titleVisibility:.visible) {
            Button("删除身份",role:.destructive) { if let i = pendingIdentityDelete {store.deleteIdentity(i.id)}; pendingIdentityDelete = nil }
        } message: { Text("关联邮箱会改为未分类，邮件和平台资料保留。") }
        .confirmationDialog("允许搞门户连接这个邮箱？", isPresented:Binding(get:{pendingConnectionAccount != nil},set:{if !$0 {pendingConnectionAccount = nil}}), titleVisibility:.visible) {
            Button("允许本次运行连接并同步") {
                guard let account = pendingConnectionAccount else { return }
                pendingConnectionAccount = nil
                do {
                    try store.authorizeHostConnection(accountID:account.id)
                    Task { await store.sync(account.id, folder:"INBOX") }
                } catch { store.publish(error) }
            }
            Button("取消", role:.cancel) { pendingConnectionAccount = nil }
        } message: {
            Text("将按原邮箱配置读取系统钥匙串凭据并连接对应 IMAP / SMTP 服务，不发送测试邮件。仅本次运行获准连接；首次打开和查看缓存不会自动取得旧授权。")
        }
    }

    private func windowLayout(compact: Bool) -> some View {
        VStack(spacing:0) {
            mailContentToolbar(compact:compact)
            Divider()
            ZStack(alignment:.topLeading) {
                HStack(spacing:0) {
                    if !compact && !sidebarHidden {
                        sidebar
                        Divider()
                    }
                    VStack(spacing:0) {
                        if store.route == "platforms" { platformSearchField.padding(.horizontal,24).padding(.top,12) }
                        page.frame(maxWidth:.infinity,maxHeight:.infinity)
                        if store.notice != nil { footer }
                    }.background(Color.mailCanvas)
                }.accessibilityHidden(compact && compactSidebarVisible)
                if compact && compactSidebarVisible {
                    Color.black.opacity(0.24).onTapGesture { compactSidebarVisible = false }.accessibilityHidden(true)
                    sidebar.shadow(color:.black.opacity(0.18),radius:12,x:3,y:0)
                }
            }
        }
    }

    private func toggleSidebar(compact: Bool) {
        if compact { compactSidebarVisible.toggle() }
        else { sidebarHidden.toggle() }
    }

    /// NSHostingView is embedded in an AppKit window, so these actions are real
    /// content controls instead of depending on a SwiftUI Window scene toolbar.
    private func mailContentToolbar(compact: Bool) -> some View {
        let sidebarShown = compact ? compactSidebarVisible : !sidebarHidden
        let sidebarTitle = sidebarShown ? "隐藏侧边栏" : "显示侧边栏"
        return HStack(spacing:12) {
            Button { toggleSidebar(compact:compact) } label:{MailSidebarToggleIcon()}
                .buttonStyle(.plain).help(sidebarTitle).accessibilityLabel(sidebarTitle)
            if compact { Text("邮件中心").font(.callout.weight(.semibold)) }
            Spacer(minLength:8)
            toolbarActions
            Button(action:openSettings) { Label("邮件设置",systemImage:"gearshape") }
                .labelStyle(.iconOnly).help("邮件设置")
        }.padding(.horizontal,16).padding(.vertical,8)
            .background(Color(nsColor:.windowBackgroundColor))
    }
    private var sidebar: some View {
        VStack(spacing:0) {
            HStack(spacing:10) {
                if let path = Bundle.main.path(forResource:"Mark",ofType:"png"), let icon = NSImage(contentsOfFile:path) {
                    Image(nsImage:icon).resizable().interpolation(.high).frame(width:38,height:38)
                        .clipShape(RoundedRectangle(cornerRadius:9,style:.continuous)).accessibilityHidden(true)
                }
                Text("搞门户 · 邮件").font(.headline)
                Spacer(minLength:0)
            }.padding(.horizontal,14).padding(.top,14).padding(.bottom,10)
            ScrollView {
                VStack(alignment:.leading,spacing:20) {
                    VStack(alignment:.leading,spacing:4) {
                        sidebarHeading("邮件工作区")
                        ForEach(menu,id:\.0) {item in
                            MailSidebarRow(title:item.2,symbol:item.1,count:menuCount(item.0),selected:store.route == item.0) {
                                store.search = ""; store.mailboxFilter = nil; store.folder = "INBOX"; store.selectedMessageID = nil
                                if item.0 == "inbox" { store.inboxFilter = .all }
                                store.route = item.0
                                compactSidebarVisible = false
                            }
                        }
                    }
                    VStack(alignment:.leading,spacing:4) {
                        HStack {
                            sidebarHeading("我的身份")
                            Spacer()
                            Button {editingIdentity = nil; identitySheet = true} label:{Image(systemName:"plus").font(.caption).frame(width:22,height:22)}
                                .buttonStyle(.plain).help("添加身份").accessibilityLabel("添加身份")
                        }
                        identityButton(nil)
                        ForEach(store.library.identities) {i in
                            identityButton(i).contextMenu {
                                Button("编辑身份") {editingIdentity = i; identitySheet = true}
                                Button("删除身份",role:.destructive) {pendingIdentityDelete = i}
                            }
                        }
                    }
                }.padding(.horizontal,14).padding(.vertical,14)
            }
            VStack(alignment:.leading,spacing:7) {
                HStack(spacing:7) {
                    Circle().fill(store.busy.isEmpty ? Color(hex:"14877D") : .orange).frame(width:7,height:7)
                    Text(store.busy.isEmpty ? "\(store.library.accounts.count) 个邮箱 · \(store.library.accounts.filter{$0.enabled}.count) 个开启收发" : "正在同步 \(store.busy.count) 个邮箱").font(.caption)
                    Spacer(minLength:0)
                }
                Text("身份与平台资料保存在本机").font(.system(size:10)).foregroundStyle(.tertiary)
            }.padding(12).background(Color.primary.opacity(0.04),in:RoundedRectangle(cornerRadius:12,style:.continuous))
                .padding(.horizontal,14).padding(.vertical,12)
        }.frame(width:216).frame(maxHeight:.infinity).background(PortalTheme.canvas)
    }
    private func sidebarHeading(_ title:String) -> some View {
        Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.tertiary).padding(.horizontal,10).padding(.bottom,2)
    }
    private func menuCount(_ route:String) -> Int? {
        switch route {
        case "accounts": return store.library.accounts.count
        case "platforms": return store.library.platforms.count
        case "drafts": return store.library.drafts.count
        case "inbox": return store.messages.filter{!$0.isRead && $0.folder == "INBOX"}.count
        default: return nil
        }
    }
    private func identityButton(_ identity:MailIdentity?) -> some View {
        MailSidebarRow(title:identity?.name ?? "全部身份",symbol:identity?.symbol ?? "circle.grid.2x2.fill",
                       count:store.library.accounts.filter{identity == nil || $0.identityID == identity?.id}.count,
                       selected:store.identityFilter == identity?.id,accent:Color(hex:identity?.color ?? "79818C")) {
            store.identityFilter = identity?.id; store.mailboxFilter = nil; store.selectedMessageID = nil; store.folder = "INBOX"
            compactSidebarVisible = false
        }
    }
    private var platformSearchField: some View {
        HStack(spacing:7) {
            Image(systemName:"magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索平台、账号或邮箱",text:$store.search)
                .textFieldStyle(.plain).font(.callout).focused($searchFocused)
            if !store.search.isEmpty {
                Button {store.search = ""} label:{Image(systemName:"xmark.circle.fill").foregroundStyle(.secondary)}
                    .buttonStyle(.plain).help("清空搜索").accessibilityLabel("清空搜索")
            }
        }.padding(10).background(Color.primary.opacity(0.05),in:RoundedRectangle(cornerRadius:10))
    }
    private var toolbarActions: some View {
        HStack(spacing:12) {
            if !store.busy.isEmpty {ProgressView().controlSize(.small)}
            Button(action:showFloating) {Label("显示悬浮窗",systemImage:"rectangle.on.rectangle")}.help("显示邮件悬浮窗")
            Button {Task {await store.syncAll()}} label:{Label("同步所有邮箱",systemImage:"arrow.clockwise")}
                .help("同步本次运行已允许连接的邮箱").disabled(!store.busy.isEmpty || !store.library.accounts.contains(where:{$0.enabled && store.isHostConnectionAuthorized(accountID:$0.id)}))
            Button {store.newDraft()} label:{Label("写邮件",systemImage:"square.and.pencil")}.help("写邮件（⌘N）")
            Menu {
                Button("添加邮箱",systemImage:"envelope.badge") {editingAccount = nil; accountSheet = true}
                Button("登记平台",systemImage:"link") {editingPlatform = PlatformRecord(accountID:store.mailboxFilter); platformSheet = true}
                Button("添加身份",systemImage:"person.crop.circle.badge.plus") {editingIdentity = nil; identitySheet = true}
                Divider()
                Button("邮箱别名助手…",systemImage:"sparkles.rectangle.stack") {selectedAliasAccountID = store.mailboxFilter; aliasSheet = true}
            } label:{Label("添加",systemImage:"plus")}.help("添加邮箱、平台、身份或生成别名")
        }.labelStyle(.iconOnly)
    }
    private var footer: some View {
        HStack(alignment:.top,spacing:10) {
            Text(store.notice ?? "").font(.callout).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
            Spacer(minLength:10)
            Button {store.notice = nil} label:{Image(systemName:"xmark").font(.caption)}
                .buttonStyle(.plain).help("关闭提示").accessibilityLabel("关闭提示")
        }.foregroundStyle(.secondary).padding(.horizontal,24).padding(.vertical,10).background(Color.primary.opacity(0.035))
    }
    @ViewBuilder private var page: some View {
        switch store.route {
        case "accounts": accountsPage
        case "platforms": platformsPage
        case "inbox": InboxView(store:store,addAccount:{editingAccount = nil; accountSheet = true},searchFocused:$searchFocused)
        case "drafts": draftsPage
        default: overview
        }
    }
    private var overview: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:23) {
                HStack(alignment:.top) {
                    VStack(alignment:.leading,spacing:9) { Text("每个邮箱，都有自己的身份。").font(.system(size:25,weight:.semibold)); Text("学校、工作与生活，在这里各归其位。").font(.system(size:13)).foregroundStyle(.secondary) }
                    Spacer()
                    Button {editingAccount = nil; accountSheet = true} label:{Label("添加邮箱",systemImage:"plus")}.controlSize(.large)
                }.padding(.top,5)
                HStack(spacing:14) {
                    metric("我的邮箱",value:store.filteredAccounts.count,detail:"\(store.filteredAccounts.filter{$0.enabled}.count) 个开启收发",icon:"envelope",color:PortalTheme.accent)
                    metric("关联平台",value:store.filteredPlatforms.count,detail:"由你维护的账号关联",icon:"link",color:Color(hex:"14877D"))
                    metric("未读邮件",value:store.messages.filter{!$0.isRead && $0.folder == "INBOX" && Set(store.filteredAccounts.map(\.id)).contains($0.accountID)}.count,detail:"已同步到本机",icon:"tray",color:Color(hex:"DA8C48"))
                }
                HStack { Text("按身份整理").font(.system(size:16,weight:.semibold)); Spacer(); Button("管理身份") { editingIdentity = nil; identitySheet = true }.buttonStyle(.link) }
                LazyVGrid(columns:[GridItem(.adaptive(minimum:200),spacing:14)],spacing:14) {
                    ForEach(store.library.identities) { identity in
                        let count = store.library.accounts.filter{$0.identityID == identity.id}.count
                        Button {store.identityFilter = identity.id; store.route = "accounts"} label: {
                            VStack(alignment:.leading,spacing:20) {
                                HStack {Image(systemName:identity.symbol).font(.system(size:23)).foregroundStyle(Color(hex:identity.color)).frame(width:46,height:46).background(Color(hex:identity.color).opacity(0.1),in:RoundedRectangle(cornerRadius:14)); Spacer(); Image(systemName:"arrow.up.right").font(.system(size:12)).foregroundStyle(.tertiary)}
                                HStack(alignment:.lastTextBaseline) { Text(identity.name).font(.system(size:18,weight:.semibold)); Spacer(); Text("\(count) 个邮箱").font(.system(size:11)).foregroundStyle(.secondary) }
                            }.padding(20).background(Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:14)).overlay(RoundedRectangle(cornerRadius:14).stroke(Color(hex:identity.color).opacity(0.12)))
                        }.buttonStyle(.plain).contextMenu {Button("编辑身份") {editingIdentity = identity; identitySheet = true}; Button("删除身份",role:.destructive) {pendingIdentityDelete = identity}}
                    }
                }
                if store.library.accounts.isEmpty {
                    Card {
                        HStack(alignment:.center,spacing:24) {
                            Image(systemName:"envelope.open").font(.system(size:51,weight:.ultraLight)).foregroundStyle(PortalTheme.accent.opacity(0.65)).frame(width:90)
                            VStack(alignment:.leading,spacing:10) { Text("从你的第一个邮箱开始").font(.system(size:20,weight:.semibold)); Text("可以先登记邮箱和用途，再连接收发。把注册过的网站与 App 记下来，以后就不用猜用了哪个邮箱。").foregroundStyle(.secondary).font(.system(size:13)).lineSpacing(5); HStack(spacing:14) { Button("添加邮箱") {editingAccount = nil; accountSheet = true}.buttonStyle(.borderedProminent); Button("了解账号授权") {openSettings(); DispatchQueue.main.async {NotificationCenter.default.post(name:.mailSettingsTab,object:"module")}}.buttonStyle(.link) }.padding(.top,6) }
                        }.padding(.vertical,17)
                    }
                    HStack(spacing:18) { step("01","添加邮箱","常见邮箱预设，也支持手动配置"); step("02","分配身份","名称、颜色和用途，由你决定"); step("03","记录关联","网站、平台和 App 的账号台账") }
                } else {
                    HStack { Text("我的邮箱").font(.system(size:16,weight:.semibold)); Spacer(); Button("查看全部") {store.route = "accounts"}.buttonStyle(.link) }
                    ForEach(store.filteredAccounts.prefix(4)) { a in accountCard(a) }
                }
            }.padding(27)
        }
    }
    private func metric(_ title: String,value: Int,detail: String,icon: String,color: Color) -> some View {
        Card { VStack(alignment:.leading,spacing:12) { HStack {Text(title).font(.system(size:12)).foregroundStyle(.secondary); Spacer(); Image(systemName:icon).foregroundStyle(color)}; Text(String(value)).font(.system(size:31,weight:.semibold,design:.rounded)); Text(detail).font(.system(size:10)).foregroundStyle(.tertiary) } }
    }
    private func step(_ n: String,_ title: String,_ text: String) -> some View { HStack(alignment:.top,spacing:10) {Text(n).font(.system(size:12,weight:.semibold,design:.monospaced)).foregroundStyle(PortalTheme.accent.opacity(0.55)); VStack(alignment:.leading,spacing:5) {Text(title).font(.system(size:12,weight:.medium)); Text(text).font(.system(size:10)).foregroundStyle(.secondary)}; Spacer(minLength:0)} }
    private var accountsPage: some View {
        VStack(spacing:0) {
            HStack { VStack(alignment:.leading,spacing:5) {Text("你的邮箱，各有归属").font(.system(size:25,weight:.semibold)); Text("连接收发，或先登记身份和关联平台。").font(.system(size:12)).foregroundStyle(.secondary)}; Spacer(); Button {editingAccount = nil; accountSheet = true} label:{Label("添加邮箱",systemImage:"plus")}.controlSize(.large).buttonStyle(.borderedProminent) }.padding(27)
            if store.filteredAccounts.isEmpty { EmptyMailView(icon:"envelope.badge.person.crop",title:"这里还没有邮箱",detail:"添加一个邮箱，为它选择身份。你可以随时开启收发连接。",button:"添加邮箱") {editingAccount = nil; accountSheet = true} }
            else { ScrollView { LazyVStack(spacing:14) {ForEach(store.filteredAccounts) {a in accountCard(a)}}.padding(.horizontal,27).padding(.bottom,27) } }
        }
    }
    private func accountCard(_ a: MailAccount) -> some View {
        Card {
            VStack(alignment:.leading,spacing:14) {
                HStack(spacing:14) {
                    Image(systemName:store.identity(a.identityID)?.symbol ?? "envelope").font(.system(size:22)).foregroundStyle(Color(hex:store.identity(a.identityID)?.color ?? "6366F1")).frame(width:50,height:50).background(Color(hex:store.identity(a.identityID)?.color ?? "6366F1").opacity(0.08),in:RoundedRectangle(cornerRadius:15))
                    VStack(alignment:.leading,spacing:5) {Text(a.displayName).font(.system(size:16,weight:.semibold)); Text(a.email).font(.system(size:12)).foregroundStyle(.secondary).textSelection(.enabled)}
                    IdentityBadge(identity:store.identity(a.identityID)); Spacer()
                    Text(a.enabled ? (!store.isHostConnectionAuthorized(accountID:a.id) ? "本次尚未连接" : a.syncError == nil ? (a.lastSync == nil ? "待验证" : "已连接") : "需要处理") : "仅登记").font(.system(size:11,weight:.medium)).foregroundStyle(a.syncError == nil ? Color.secondary : .orange)
                    Button("编辑") {editingAccount = a; accountSheet = true}
                    Menu { Button("查看关联平台") {store.route = "platforms"; store.mailboxFilter = a.id; store.search = ""}; Button("别名助手") {selectedAliasAccountID = a.id; aliasSheet = true}; if a.auth != "password" {Button("重新授权") {Task {do {try await store.authorize(a); await store.sync(a.id)} catch {store.publish(error)}}}}; Divider(); Button("移除邮箱",role:.destructive) {pendingAccountDelete = a} } label:{Image(systemName:"ellipsis")}.menuStyle(.borderlessButton).frame(width:23)
                }
                if let error = a.syncError {Text(error).font(.system(size:11)).foregroundStyle(.orange).lineLimit(3)}
                HStack(spacing:16) {
                    Text(a.provider.rawValue).font(.system(size:10)).foregroundStyle(.secondary)
                    Text("\(store.library.platforms.filter{$0.accountID == a.id}.count) 个关联平台").font(.system(size:10)).foregroundStyle(.secondary)
                    if !a.tags.isEmpty {Text(a.tags).font(.system(size:10)).foregroundStyle(.secondary)}
                    Spacer()
                    if let d = a.lastSync { Text("同步于 " + d.formatted(date:.omitted,time:.shortened)).font(.system(size:10)).foregroundStyle(.tertiary) }
                    if a.enabled && !store.isHostConnectionAuthorized(accountID:a.id) {
                        Button("连接邮箱…") { pendingConnectionAccount = a }.buttonStyle(.borderedProminent)
                    }
                    Button {store.openCachedInbox(accountID:a.id)} label:{Label("查看缓存",systemImage:"arrow.right")}.buttonStyle(.link)
                }
            }
        }
    }
    private var platformsPage: some View {
        VStack(spacing:0) {
            HStack { VStack(alignment:.leading,spacing:5) {Text("这个账号，用的是哪个邮箱？").font(.system(size:25,weight:.semibold)); Text("手动记下关联，随时双向查找。").font(.system(size:12)).foregroundStyle(.secondary)}; Spacer(); Menu {Button("导入 CSV",action:store.importCSV); Button("导出 CSV",action:store.exportCSV)} label:{Image(systemName:"square.and.arrow.up")}.frame(width:45); Button {editingPlatform = PlatformRecord(accountID:store.mailboxFilter); platformSheet = true} label:{Label("登记平台",systemImage:"plus")}.controlSize(.large).buttonStyle(.borderedProminent) }.padding(27)
            HStack { Picker("邮箱",selection:$store.mailboxFilter) {Text("所有邮箱").tag(nil as UUID?); ForEach(store.filteredAccounts) {Text($0.displayName).tag(Optional($0.id))} }.frame(maxWidth:290); Spacer(); Text("\(store.filteredPlatforms.count) 条记录").font(.system(size:11)).foregroundStyle(.secondary) }.padding(.horizontal,27).padding(.bottom,16)
            if store.filteredPlatforms.isEmpty { EmptyMailView(icon:"link",title:store.search.isEmpty ? "记下你的第一个关联" : "没有匹配的平台",detail:"记录网站或 App、使用的邮箱和登录方式。即使没有历史邮件，也可以手动添加。",button:"登记平台") {editingPlatform = PlatformRecord(accountID:store.mailboxFilter); platformSheet = true} }
            else { ScrollView {LazyVStack(spacing:10) {ForEach(store.filteredPlatforms) {p in platformRow(p)}}.padding(.horizontal,27).padding(.bottom,25)} }
        }
    }
    private func platformRow(_ p: PlatformRecord) -> some View {
        Card {
            HStack(spacing:15) {
                Text(String(p.name.prefix(1)).uppercased()).font(.system(size:21,weight:.semibold,design:.rounded)).foregroundStyle(PortalTheme.accent).frame(width:45,height:45).background(PortalTheme.accent.opacity(0.07),in:RoundedRectangle(cornerRadius:13))
                VStack(alignment:.leading,spacing:5) { Text(p.name).font(.system(size:15,weight:.semibold)); Text(p.username.isEmpty ? (MailValidation.webURL(p.url)?.host ?? p.kind) : p.username).font(.system(size:11)).foregroundStyle(.secondary).lineLimit(1) }.frame(minWidth:100,maxWidth:.infinity,alignment:.leading)
                VStack(alignment:.leading,spacing:5) {Text(p.address.isEmpty ? store.account(p.accountID)?.email ?? "未关联邮箱" : p.address).font(.system(size:11)).lineLimit(1); IdentityBadge(identity:store.identity(store.account(p.accountID)?.identityID))}.frame(minWidth:155,maxWidth:.infinity,alignment:.leading)
                VStack(alignment:.leading,spacing:5) {Text(p.loginMethod).font(.system(size:11)); Text(p.roles.joined(separator:" · ")).font(.system(size:10)).foregroundStyle(.secondary)}.frame(width:105,alignment:.leading)
                Text(p.status).font(.system(size:10)).foregroundStyle(p.status == "使用中" ? Color(hex:"14877D") : .secondary).padding(.horizontal,9).padding(.vertical,5).background(Color.primary.opacity(0.04),in:Capsule())
                if let u = MailValidation.webURL(p.url) {Button {NSWorkspace.shared.open(u)} label:{Image(systemName:"arrow.up.right.square")}.buttonStyle(.plain).help("打开平台")}
                Button {editingPlatform = p; platformSheet = true} label:{Image(systemName:"pencil")}.buttonStyle(.plain).help("编辑平台")
                Menu {Button("复制关联邮箱") {NSPasteboard.general.clearContents(); NSPasteboard.general.setString(p.address,forType:.string)}; Button("删除记录",role:.destructive) {pendingPlatformDelete = p}} label:{Image(systemName:"ellipsis")}.menuStyle(.borderlessButton).frame(width:20)
            }
        }
    }
    private var draftsPage: some View {
        VStack(spacing:0) {
            HStack {Text("留给下一次继续写").font(.system(size:25,weight:.semibold)); Spacer(); Button("新建邮件") {store.newDraft()}.buttonStyle(.borderedProminent)}.padding(27)
            if let draftSubmissionReadError {
                VStack(alignment:.leading,spacing:8) {
                    Label("发送记录不可读，已停止提交与删除",systemImage:"exclamationmark.triangle.fill").font(.callout.weight(.semibold))
                    Text(draftSubmissionReadError).font(.caption).textSelection(.enabled)
                    Button("重新核对本机记录",action:refreshDraftSubmissions)
                }.foregroundStyle(.orange).frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,27).padding(.bottom,14)
            }
            if store.library.drafts.isEmpty {EmptyMailView(icon:"doc.text",title:"还没有草稿",detail:"写信时可以保存到本机，下次从这里继续。")}
            else {ScrollView {LazyVStack(spacing:12) {ForEach(store.library.drafts.sorted{$0.updatedAt > $1.updatedAt}) {d in
                draftRow(d)
            }}.padding(.horizontal,27)}}
        }
        .onAppear(perform:refreshDraftSubmissions)
        .onChange(of:store.submissionRevision) {_,_ in refreshDraftSubmissions()}
        .onChange(of:store.library.drafts.map(\.id)) {_,_ in refreshDraftSubmissions()}
    }
    private func draftRow(_ draft: MailDraft) -> some View {
        let submission = draftSubmissions[draft.id]
        return Card {
            HStack {
                VStack(alignment:.leading,spacing:7) {
                    Text(draft.subject.isEmpty ? "（无主题）" : draft.subject).font(.system(size:16,weight:.semibold))
                    Text(draft.to.isEmpty ? "尚未填写收件人" : "发给：" + draft.to).font(.system(size:12)).foregroundStyle(.secondary)
                    Text(draft.updatedAt.formatted(date:.abbreviated,time:.shortened)).font(.system(size:10)).foregroundStyle(.tertiary)
                    if let submission {
                        switch submission.phase {
                        case .pending: Label("提交结果待核对，不会再次发送",systemImage:"exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                        case .accepted: Label("服务商已接收，等待本地保存",systemImage:"checkmark.circle").font(.caption).foregroundStyle(.orange)
                        case .completed: Label("服务商已接收，本地记录已保存",systemImage:"checkmark.circle").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                Button(submission == nil ? "继续写" : "查看发送状态") {store.compose = draft}
                Button(role:.destructive) {deleteDraftAfterReview(draft)} label:{Image(systemName:"trash")}
                    .disabled(!draftSubmissionsChecked || draftSubmissionReadError != nil || submission != nil || store.sending)
            }
        }
    }
    private func refreshDraftSubmissions() {
        do {
            draftSubmissions = try store.submissionStates(for:store.library.drafts.map(\.id))
            draftSubmissionReadError = nil
        } catch {
            draftSubmissions = [:]
            draftSubmissionReadError = error.localizedDescription
        }
        draftSubmissionsChecked = true
    }
    private func deleteDraftAfterReview(_ draft: MailDraft) {
        do {
            guard try store.submissionState(for:draft.id) == nil else {refreshDraftSubmissions(); return}
            let alert = NSAlert()
            alert.messageText = "删除这份草稿？"
            alert.addButton(withTitle:"删除"); alert.addButton(withTitle:"取消")
            if alert.runModal() == .alertFirstButtonReturn {store.deleteDraft(draft.id)}
        } catch {store.publish(error); refreshDraftSubmissions()}
    }
}

struct InboxView: View {
    @ObservedObject var store: MailStore
    var addAccount: () -> Void
    @FocusState.Binding var searchFocused: Bool
    @State private var showHTML = false

    var body: some View {
        if store.library.accounts.isEmpty {
            EmptyMailView(icon:"tray",title:"添加邮箱",detail:"添加邮箱后可统一查看已缓存的邮件。首次同步需要你确认连接。",button:"添加邮箱",action:addAccount)
        } else {
            GeometryReader { geometry in
                let compact = geometry.size.width < 760
                let result = store.inboxSearchResult
                VStack(spacing:0) {
                    inboxHeader(result,compact:compact)
                    Divider()
                    inboxContent(result,compact:compact)
                }.frame(maxWidth:.infinity,maxHeight:.infinity)
            }
            .onChange(of:store.selectedMessageID) {_,_ in showHTML = false}
            .onChange(of:store.mailboxFilter) {_,_ in
                store.folder = "INBOX"
                store.retainVisibleMessageSelection()
            }
            .onChange(of:store.folder) {_,_ in
                store.retainVisibleMessageSelection()
            }
        }
    }

    private var filterSelection: Binding<MailInboxFilter> {
        Binding(get:{store.inboxFilter},set:{ filter in
            guard store.inboxFilter != filter else { return }
            store.inboxFilter = filter
            store.selectedMessageID = nil
        })
    }

    private var searchText: Binding<String> {
        Binding(get:{store.search},set:{ query in
            guard store.search != query else { return }
            store.search = query
            store.selectedMessageID = nil
        })
    }

    private func inboxHeader(_ result: MailInboxSearchResult, compact: Bool) -> some View {
        VStack(alignment:.leading,spacing:12) {
            HStack(spacing:16) {
                Text(folderTitle).font(.system(size:24,weight:.semibold)).lineLimit(1).accessibilityAddTraits(.isHeader)
                Spacer(minLength:12)
                searchField.frame(maxWidth:350)
            }
            HStack(spacing:10) {
                scopePickers
                Spacer(minLength:8)
                Text(result.messages.count,format:.number)
                    .font(.callout.weight(.semibold)).monospacedDigit()
                    .accessibilityLabel("\(result.messages.count) 封符合条件的邮件")
                Text("封").font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
            }
            Picker("筛选邮件",selection:filterSelection) {
                ForEach(MailInboxFilter.allCases) { filter in
                    Text("\(filter.title) \(result.count(for:filter))").tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth:compact ? .infinity : 460)
            .accessibilityIdentifier("mail.inbox.filters")
            Label(cacheScopeText(result),systemImage:"internaldrive")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal:false,vertical:true)
                .accessibilityIdentifier("mail.inbox.cacheScope")
        }
        .padding(.horizontal,compact ? 18 : 24)
        .padding(.vertical,14)
        .background(PortalTheme.panel)
    }

    private var searchField: some View {
        HStack(spacing:8) {
            Image(systemName:"magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField("搜索主题、正文或附件名",text:searchText)
                .textFieldStyle(.plain).font(.callout).focused($searchFocused)
                .accessibilityLabel("搜索本机缓存邮件").accessibilityIdentifier("mail.inbox.search")
            if !store.search.isEmpty {
                Button("清空搜索",systemImage:"xmark.circle.fill") { searchText.wrappedValue = "" }
                    .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("清空搜索")
            }
        }
        .padding(.vertical,8).padding(.horizontal,10)
        .background(Color(nsColor:.textBackgroundColor),in:RoundedRectangle(cornerRadius:9))
        .overlay(RoundedRectangle(cornerRadius:9).strokeBorder(searchFocused ? PortalTheme.accent : Color.primary.opacity(0.12),lineWidth:searchFocused ? 1.5 : 1))
    }

    private var scopePickers: some View {
        HStack(spacing:8) {
            Picker("邮箱范围",selection:$store.mailboxFilter) {
                Text("统一收件箱").tag(nil as UUID?)
                ForEach(store.filteredAccounts) { account in Text(account.displayName).tag(Optional(account.id)) }
            }.labelsHidden().frame(maxWidth:202)
            if let id = store.mailboxFilter {
                Picker("文件夹",selection:$store.folder) {
                    Text("收件箱").tag("INBOX")
                    Text("本机发送记录").tag("__local_sent__")
                    ForEach((store.folders[id] ?? []).filter { $0.selectable && $0.path.uppercased() != "INBOX" }) { folder in
                        Text(folder.displayName).tag(folder.path)
                    }
                }.labelsHidden().frame(maxWidth:195)
            }
        }
    }

    private var folderTitle: String {
        if store.folder == "__local_sent__" { return "本机发送记录" }
        if let id = store.mailboxFilter, store.folder.uppercased() != "INBOX" {
            return store.folders[id]?.first { $0.path == store.folder }?.displayName ?? store.folder
        }
        return "收件箱"
    }

    private func cacheScopeText(_ result: MailInboxSearchResult) -> String {
        let scope = "仅本机缓存 · 当前范围共 \(result.scopedCount) 封"
        if result.headerOnlyCount > 0 { return scope + " · \(result.headerOnlyCount) 封尚无完整正文和附件资料" }
        return scope
    }

    @ViewBuilder private func inboxContent(_ result: MailInboxSearchResult, compact: Bool) -> some View {
        let selected = store.messages.first { $0.id == store.selectedMessageID }
        if compact {
            if let selected { messageDetail(selected, compact:true) }
            else { messageList(result) }
        } else {
            HSplitView {
                messageList(result).frame(minWidth:270,idealWidth:325,maxWidth:415,maxHeight:.infinity)
                Group {
                    if let selected { messageDetail(selected,compact:false) }
                    else { EmptyMailView(icon:"envelope.open",title:"选择一封邮件",detail:"打开左侧列表中的邮件，查看已缓存的正文和附件。") }
                }.frame(minWidth:365,maxWidth:.infinity,maxHeight:.infinity)
            }
        }
    }

    @ViewBuilder private func messageList(_ result: MailInboxSearchResult) -> some View {
        if result.messages.isEmpty {
            if result.scopedCount == 0 {
                EmptyMailView(icon:"tray",title:"当前范围暂无缓存",detail:"同步已获准连接的邮箱，或选择其他邮箱和文件夹。")
            } else {
                EmptyMailView(icon:result.hasQuery ? "magnifyingglass" : "line.3.horizontal.decrease.circle",
                    title:"没有符合条件的邮件",detail:"试试其他关键词或筛选。搜索只使用本机缓存的内容。")
            }
        } else {
            List(selection:$store.selectedMessageID) {
                ForEach(result.messages) { message in
                    let account = store.account(message.accountID)
                    MailInboxRow(message:message,account:account,identity:store.identity(account?.identityID))
                        .listRowInsets(EdgeInsets(top:0,leading:12,bottom:0,trailing:12))
                        .tag(message.id)
                }
            }.listStyle(.plain).scrollContentBackground(.hidden).accessibilityIdentifier("mail.inbox.messages")
        }
    }

    private func messageDetail(_ m: CachedMessage, compact: Bool) -> some View {
        VStack(alignment:.leading,spacing:0) {
            detailToolbar(m,compact:compact)
            Divider()
            ScrollView {
                VStack(alignment:.leading,spacing:19) {
                    detailHeading(m)
                    Divider()
                    if let primary = CodeExtractor.extract(subject:m.subject,body:m.body,html:m.html).first { codeBanner(primary) }
                    detailBody(m)
                }.frame(maxWidth:820,alignment:.leading).padding(compact ? 20 : 26)
                    .frame(maxWidth:.infinity,alignment:.center)
            }
        }.background(PortalTheme.panel).accessibilityIdentifier("mail.inbox.reader")
    }

    private func detailToolbar(_ message: CachedMessage, compact: Bool) -> some View {
        HStack(spacing:9) {
            if compact {
                Button("邮件列表",systemImage:"chevron.left") { store.selectedMessageID = nil }
                    .keyboardShortcut(.cancelAction)
            }
            Spacer(minLength:4)
            Button("回复",systemImage:"arrowshape.turn.up.left") { store.reply(message) }.disabled(!message.loaded)
            Menu {
                Button("回复全部") { store.reply(message,all:true) }
                Button("转发正文") { store.reply(message,forward:true) }
            } label:{ Label("更多回复选项",systemImage:"ellipsis") }
                .labelStyle(.iconOnly).menuStyle(.borderlessButton).fixedSize().disabled(!message.loaded)
            Button(message.isFlagged ? "取消星标" : "加星",systemImage:message.isFlagged ? "star.fill" : "star") {
                Task { await store.changeFlag(message,flag:!message.isFlagged) }
            }.labelStyle(.iconOnly).help(message.isFlagged ? "取消星标" : "加星")
            Button(message.isRead ? "标为未读" : "标为已读",systemImage:message.isRead ? "envelope.badge" : "envelope.open") {
                Task { await store.changeFlag(message,read:!message.isRead) }
            }.labelStyle(.iconOnly).help(message.isRead ? "标为未读" : "标为已读")
            if message.folder != "__local_sent__" { folderMenu(message) }
        }.padding(.horizontal,16).padding(.vertical,9).background(Color.primary.opacity(0.025))
    }

    private func folderMenu(_ message: CachedMessage) -> some View {
        let targets = (store.folders[message.accountID] ?? []).filter { $0.selectable && $0.path != message.folder }
        return Menu {
            ForEach(targets) { folder in
                Button("移至 " + folder.displayName) { Task { await store.moveMessage(message,destination:folder.path) } }
            }
        } label:{ Label("移至文件夹",systemImage:"folder") }
            .labelStyle(.iconOnly).menuStyle(.borderlessButton).fixedSize().disabled(targets.isEmpty)
            .help("移至文件夹")
    }

    private func detailHeading(_ message: CachedMessage) -> some View {
        VStack(alignment:.leading,spacing:10) {
            Text(message.subject.isEmpty ? "（无主题）" : message.subject)
                .font(.system(size:24,weight:.semibold)).textSelection(.enabled).accessibilityAddTraits(.isHeader)
            VStack(alignment:.leading,spacing:5) {
                detailAddress("发件人",message.from)
                detailAddress("收件人",message.to)
                if !message.cc.isEmpty { detailAddress("抄送",message.cc) }
            }.textSelection(.enabled)
            HStack(spacing:10) {
                if let identity = store.identity(store.account(message.accountID)?.identityID) { IdentityBadge(identity:identity) }
                Text(message.date.formatted(date:.abbreviated,time:.shortened)).font(.caption).foregroundStyle(.secondary)
                if !message.isRead { Text("未读").font(.caption.weight(.medium)).foregroundStyle(PortalTheme.accent) }
            }
        }
    }

    private func detailAddress(_ label: String, _ value: String) -> some View {
        HStack(alignment:.firstTextBaseline,spacing:10) {
            Text(label).fontWeight(.medium).foregroundStyle(.secondary).frame(width:44,alignment:.leading)
            Text(value.isEmpty ? "—" : value).fixedSize(horizontal:false,vertical:true)
        }.font(.callout)
    }

    @ViewBuilder private func detailBody(_ message: CachedMessage) -> some View {
        if message.loaded {
            if message.html != nil {
                Toggle("显示原邮件排版 · 外部图片已阻止",isOn:$showHTML).font(.caption).toggleStyle(.checkbox)
            }
            if showHTML, let html = message.html {
                SafeMailHTML(html:html).frame(minHeight:420)
            } else {
                let fallback = message.html == nil ? "没有可显示的正文。" : "这封邮件只有排版正文。"
                Text(message.body.allSatisfy(\.isWhitespace) ? fallback : message.body)
                    .font(.system(size:14)).lineSpacing(6).textSelection(.enabled)
                    .frame(maxWidth:.infinity,alignment:.leading)
            }
            if !message.attachments.isEmpty { attachmentList(message.attachments) }
        } else if store.detailBusy.contains(message.id) {
            ProgressView("正在读取正文…").controlSize(.small)
        } else {
            let connected = store.account(message.accountID)?.enabled == true && store.isHostConnectionAuthorized(accountID:message.accountID)
            let synchronizing = store.busy.contains(message.accountID)
            let detail: String = if !connected { "完整正文和附件尚未缓存。请先在邮箱管理允许连接。" }
                else if synchronizing { "正在同步此邮箱，完成后可读取正文。" }
                else { "完整正文和附件尚未缓存。读取正文将访问邮箱。" }
            VStack(alignment:.leading,spacing:10) {
                if !message.preview.isEmpty {
                    Text(message.preview).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Text(detail)
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                Button("读取正文",systemImage:"arrow.down.circle") { Task { await store.loadMessage(message.id) } }
                    .buttonStyle(.bordered).disabled(!connected || synchronizing).accessibilityIdentifier("mail.inbox.fetchBody")
            }
        }
    }

    private func attachmentList(_ attachments: [CachedAttachment]) -> some View {
        VStack(alignment:.leading,spacing:7) {
            Divider()
            Label("附件 · \(attachments.count)",systemImage:"paperclip").font(.callout.weight(.semibold))
            ForEach(attachments) { attachment in
                Button { saveAttachment(attachment) } label:{
                    HStack(spacing:8) {
                        Text(attachment.filename).lineLimit(1)
                        Spacer(minLength:8)
                        Text(ByteCountFormatter.string(fromByteCount:Int64(attachment.data.count),countStyle:.file)).foregroundStyle(.secondary)
                        Image(systemName:"arrow.down.to.line").accessibilityHidden(true)
                    }.font(.callout)
                        .padding(.horizontal,11).padding(.vertical,9)
                        .background(Color.primary.opacity(0.055),in:RoundedRectangle(cornerRadius:8))
                }.buttonStyle(.plain).help("保存附件 \(attachment.filename)")
            }
        }
    }
    private func codeBanner(_ item: ExtractedCode) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: item.isLink ? "link.badge.plus" : "key.radiowaves.forward.fill")
                .font(.system(size: 20))
                .foregroundStyle(PortalTheme.accent)
                .frame(width: 42, height: 42)
                .background(PortalTheme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(item.displayTitle).font(.system(size: 12, weight: .semibold)).foregroundStyle(PortalTheme.accent)
                    Text("置信度 \(Int(item.confidence * 100))%").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                if item.isLink {
                    Text(item.value).font(.system(size: 11)).lineLimit(1).foregroundStyle(.secondary)
                } else {
                    Text(item.value).font(.system(size: 22, weight: .bold, design: .monospaced)).textSelection(.enabled)
                }
            }
            Spacer()
            if item.isLink {
                Button("打开验证链接") {
                    if let u = URL(string: item.value) { NSWorkspace.shared.open(u) }
                }.buttonStyle(.borderedProminent).controlSize(.small)
                Button("复制链接") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.value, forType: .string)
                    store.notice = "已复制验证链接"
                }.controlSize(.small)
            } else {
                Button("复制验证码") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.value, forType: .string)
                    store.notice = "已复制验证码：\(item.value)"
                }.buttonStyle(.borderedProminent).controlSize(.small)
            }
        }
        .padding(12)
        .background(PortalTheme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(PortalTheme.accent.opacity(0.18), lineWidth: 1))
    }
    private func saveAttachment(_ a: CachedAttachment) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = URL(fileURLWithPath:a.filename).lastPathComponent
        if panel.runModal() == .OK, let url = panel.url {do {try a.data.write(to:url,options:.atomic)} catch {store.publish(error)}}
    }
}

private struct MailInboxRow: View {
    let message: CachedMessage
    let account: MailAccount?
    let identity: MailIdentity?

    var body: some View {
        HStack(alignment:.top,spacing:9) {
            if message.isRead {
                Color.clear.frame(width:7,height:7).accessibilityHidden(true)
            } else {
                Circle().fill(PortalTheme.accent).frame(width:7,height:7).accessibilityLabel("未读")
            }
            VStack(alignment:.leading,spacing:6) {
                HStack(alignment:.firstTextBaseline,spacing:8) {
                    Text(message.subject.isEmpty ? "（无主题）" : message.subject)
                        .font(.callout.weight(message.isRead ? .medium : .semibold)).lineLimit(1)
                    Spacer(minLength:4)
                    Text(message.date.formatted(date:.abbreviated,time:.omitted))
                        .font(.caption2).monospacedDigit().foregroundStyle(.secondary).fixedSize()
                }
                HStack(spacing:6) {
                    Text(message.from.isEmpty ? "未知发件人" : message.from).font(.caption).lineLimit(1)
                    Spacer(minLength:4)
                    if !message.attachments.isEmpty {
                        Image(systemName:"paperclip").font(.caption).accessibilityLabel("有缓存附件")
                    }
                    if message.isFlagged {
                        Image(systemName:"star.fill").font(.caption).foregroundStyle(.orange).accessibilityLabel("已加星")
                    }
                }.foregroundStyle(.secondary)
                if !message.preview.isEmpty {
                    Text(message.preview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                rowMetadata
            }
        }
        .padding(.vertical,10)
        .contentShape(Rectangle())
        .accessibilityElement(children:.combine)
    }

    private var rowMetadata: some View {
        HStack(spacing:6) {
            if let account {
                Label(account.displayName,systemImage:"envelope")
                    .font(.caption2).lineLimit(1).foregroundStyle(.secondary)
            }
            if let identity { IdentityBadge(identity:identity).lineLimit(1) }
            if let code = CodeExtractor.primaryCode(subject:message.subject,body:message.body,html:message.html), code.type != .link {
                Label(code.value,systemImage:"key.fill").font(.system(.caption2,design:.monospaced,weight:.semibold))
                    .padding(.horizontal,6).padding(.vertical,3)
                    .foregroundStyle(PortalTheme.accent)
                    .background(PortalTheme.accent.opacity(0.10),in:Capsule())
                    .help("验证码 \(code.value)")
            }
        }
    }
}

struct SafeMailHTML: NSViewRepresentable {
    var html: String
    func makeCoordinator() -> Coordinator {Coordinator()}
    func makeNSView(context:Context) -> WKWebView {
        let config = WKWebViewConfiguration(); config.defaultWebpagePreferences.allowsContentJavaScript = false; config.websiteDataStore = .nonPersistent()
        let v = WKWebView(frame:.zero,configuration:config); v.navigationDelegate = context.coordinator; return v
    }
    func updateNSView(_ view:WKWebView,context:Context) {
        guard context.coordinator.loaded != html else {return}; context.coordinator.loaded = html
        let csp = "default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src 'none'; connect-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none'; script-src 'none'"
        view.loadHTMLString("<!doctype html><html><head><meta http-equiv=\"Content-Security-Policy\" content=\"" + csp + "\"><meta name=\"viewport\" content=\"width=device-width\"><style>:root{color-scheme:light dark;}body{background:Canvas;color:CanvasText;font-family:-apple-system;font-size:14px;line-height:1.7;overflow-wrap:anywhere;}img{max-width:100%;height:auto;}table{max-width:100%;}pre{white-space:pre-wrap;}</style></head><body>" + html + "</body></html>",baseURL:nil)
    }
    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded = ""
        func webView(_ webView:WKWebView,decidePolicyFor action:WKNavigationAction,decisionHandler:@escaping(WKNavigationActionPolicy)->Void) {
            if action.navigationType == .linkActivated {if let u = action.request.url, ["https","http"].contains(u.scheme?.lowercased() ?? "") {NSWorkspace.shared.open(u)}; decisionHandler(.cancel)}
            else if action.request.url?.scheme == "about" {decisionHandler(.allow)} else {decisionHandler(.cancel)}
        }
    }
}
