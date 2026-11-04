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
            Image(systemName:icon).font(.system(size:38,weight:.light)).foregroundStyle(.indigo.opacity(0.65)).frame(width:84,height:84).background(.indigo.opacity(0.065),in:RoundedRectangle(cornerRadius:25))
            Text(title).font(.system(size:21,weight:.semibold))
            Text(detail).font(.system(size:13)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth:380).lineSpacing(5)
            if let button, let action { Button(button,action:action).buttonStyle(.borderedProminent).tint(.indigo).controlSize(.large).padding(.top,5) }
        }.frame(maxWidth:.infinity,maxHeight:.infinity).padding(30)
    }
}

struct PortalMailRootView: View {
    @ObservedObject var store: MailStore
    var showFloating: () -> Void = {}
    var openSettings: () -> Void = { NotificationCenter.default.post(name: .mailOpenSettings, object: nil) }
    @AppStorage("gaomenhu.mail.sidebarHidden") private var sidebarHidden = false
    @FocusState private var searchFocused: Bool
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
    private let menu: [(String,String,String)] = [("overview","square.grid.2x2","总览"),("inbox","tray","邮件"),("accounts","envelope.badge.person.crop","邮箱管理"),("platforms","link","关联平台"),("drafts","doc.text","草稿")]
    var body: some View {
        VStack(spacing:0) {
            mailContentToolbar
            Divider()
            HStack(spacing:0) {
                if !sidebarHidden {
                    sidebar
                    Rectangle().fill(Color.primary.opacity(0.12)).frame(width:1).frame(maxHeight:.infinity)
                }
                VStack(spacing:0) {
                    if sidebarHidden && ["inbox","platforms"].contains(store.route) {
                        searchField.padding(.horizontal,27).padding(.top,14)
                    }
                    page.frame(maxWidth:.infinity,maxHeight:.infinity)
                    if store.notice != nil {footer}
                }.background(Color.mailCanvas)
            }
        }.tint(.indigo)
        .animation(.easeInOut(duration:0.22),value:sidebarHidden)
        .onReceive(NotificationCenter.default.publisher(for:.mailToggleSidebar)) {_ in sidebarHidden.toggle()}
        .onReceive(NotificationCenter.default.publisher(for:.mailFocusSearch)) {_ in
            if !["inbox","platforms"].contains(store.route) {store.route = "inbox"}
            sidebarHidden = false
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
    /// NSHostingView is embedded in an AppKit window, so these actions are real
    /// content controls instead of depending on a SwiftUI Window scene toolbar.
    private var mailContentToolbar: some View {
        HStack(spacing:12) {
            Button {sidebarHidden.toggle()} label:{MailSidebarToggleIcon()}
                .buttonStyle(.plain).help(sidebarHidden ? "显示侧边栏" : "隐藏侧边栏")
                .accessibilityLabel(sidebarHidden ? "显示侧边栏" : "隐藏侧边栏")
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
                if let path = Bundle.main.path(forResource:"AppIcon",ofType:"png"), let icon = NSImage(contentsOfFile:path) {
                    Image(nsImage:icon).resizable().interpolation(.high).frame(width:38,height:38)
                        .clipShape(RoundedRectangle(cornerRadius:9,style:.continuous)).accessibilityHidden(true)
                }
                VStack(alignment:.leading,spacing:2) {
                    Text("搞门户 · 邮件").font(.headline)
                    Text("邮箱 · 身份 · 平台").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength:0)
            }.padding(.horizontal,14).padding(.top,14).padding(.bottom,10)
            if ["inbox","platforms"].contains(store.route) {searchField.padding(.horizontal,14).padding(.bottom,4)}
            ScrollView {
                VStack(alignment:.leading,spacing:20) {
                    VStack(alignment:.leading,spacing:4) {
                        sidebarHeading("邮箱管理")
                        ForEach(menu,id:\.0) {item in
                            MailSidebarRow(title:item.2,symbol:item.1,count:menuCount(item.0),selected:store.route == item.0) {
                                store.route = item.0; store.search = ""; store.mailboxFilter = nil; store.folder = "INBOX"; store.selectedMessageID = nil
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
        }.frame(width:236).frame(maxHeight:.infinity).background(.regularMaterial)
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
        }
    }
    private var searchField: some View {
        HStack(spacing:7) {
            Image(systemName:"magnifyingglass").foregroundStyle(.secondary)
            TextField(store.route == "platforms" ? "搜索平台、账号或邮箱" : "搜索已缓存的邮件",text:$store.search)
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
        }.labelStyle(.iconOnly).frame(width:360,alignment:.trailing)
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
        case "inbox": InboxView(store:store,addAccount:{editingAccount = nil; accountSheet = true})
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
                    metric("我的邮箱",value:store.filteredAccounts.count,detail:"\(store.filteredAccounts.filter{$0.enabled}.count) 个开启收发",icon:"envelope",color:.indigo)
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
                            Image(systemName:"envelope.open").font(.system(size:51,weight:.ultraLight)).foregroundStyle(.indigo.opacity(0.65)).frame(width:90)
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
    private func step(_ n: String,_ title: String,_ text: String) -> some View { HStack(alignment:.top,spacing:10) {Text(n).font(.system(size:12,weight:.semibold,design:.monospaced)).foregroundStyle(.indigo.opacity(0.55)); VStack(alignment:.leading,spacing:5) {Text(title).font(.system(size:12,weight:.medium)); Text(text).font(.system(size:10)).foregroundStyle(.secondary)}; Spacer(minLength:0)} }
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
                Text(String(p.name.prefix(1)).uppercased()).font(.system(size:21,weight:.semibold,design:.rounded)).foregroundStyle(.indigo).frame(width:45,height:45).background(.indigo.opacity(0.07),in:RoundedRectangle(cornerRadius:13))
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
    @State private var showHTML = false
    var body: some View {
        if store.library.accounts.isEmpty {EmptyMailView(icon:"tray",title:"把邮箱带到这里",detail:"支持常见邮箱及自定义 IMAP / SMTP。连接成功后，邮件会出现在这里。",button:"添加邮箱",action:addAccount)}
        else {
            VStack(spacing:0) {
                HStack(spacing:12) {
                    Picker("邮箱",selection:$store.mailboxFilter) {Text("统一收件箱").tag(nil as UUID?); ForEach(store.filteredAccounts) {Text($0.displayName).tag(Optional($0.id))} }.frame(maxWidth:265)
                    if let id = store.mailboxFilter {Picker("文件夹",selection:$store.folder) {Text("收件箱").tag("INBOX"); Text("本机发送记录").tag("__local_sent__"); ForEach((store.folders[id] ?? []).filter {$0.selectable && $0.path.uppercased() != "INBOX"}) {Text($0.displayName).tag($0.path)}}.frame(maxWidth:235)}
                    Spacer(); Text("最近 \(store.filteredMessages.count) 封").font(.system(size:11)).foregroundStyle(.secondary)
                }.padding(.horizontal,22).padding(.vertical,13)
                Divider()
                HSplitView {
                    VStack(spacing:0) {
                        if store.filteredMessages.isEmpty {EmptyMailView(icon:"tray",title:store.search.isEmpty ? "暂无缓存邮件" : "未找到邮件",detail:store.search.isEmpty ? "请先连接邮箱并同步。仅登记的邮箱不会收发邮件。" : "搜索范围为已同步到本机的邮件；正文在打开后缓存。")}
                        else { List(selection:$store.selectedMessageID) { ForEach(store.filteredMessages) {m in
                            VStack(alignment:.leading,spacing:8) {
                                HStack(spacing:6) {Circle().fill(m.isRead ? Color.clear : .indigo).frame(width:6,height:6); Text(m.from.isEmpty ? "未知发件人" : m.from).font(.system(size:12,weight:m.isRead ? .regular : .semibold)).lineLimit(1); Spacer(); if m.isFlagged {Image(systemName:"star.fill").font(.system(size:10)).foregroundStyle(.orange)}; Text(m.date.formatted(date:.numeric,time:.omitted)).font(.system(size:9)).foregroundStyle(.secondary)}
                                Text(m.subject.isEmpty ? "（无主题）" : m.subject).font(.system(size:13,weight:.medium)).lineLimit(2)
                                Text(m.preview.isEmpty ? store.account(m.accountID)?.email ?? "" : m.preview).font(.system(size:11)).foregroundStyle(.secondary).lineLimit(2)
                                HStack {
                                    IdentityBadge(identity:store.identity(store.account(m.accountID)?.identityID))
                                    if let code = CodeExtractor.primaryCode(subject: m.subject, body: m.body, html: m.html), code.type != .link {
                                        HStack(spacing: 3) {
                                            Image(systemName: "key.fill").font(.system(size: 8))
                                            Text(code.value).font(.system(size: 10, weight: .bold, design: .monospaced))
                                        }
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .foregroundStyle(Color.indigo)
                                        .background(Color.indigo.opacity(0.10), in: Capsule())
                                        .help("提取到验证码 \(code.value)")
                                    }
                                }
                            }.padding(.vertical,10).tag(m.id)
                        }}.listStyle(.inset).scrollContentBackground(.hidden) }
                    }.frame(minWidth:260,idealWidth:310,maxWidth:380)
                    if let m = store.messages.first(where:{$0.id == store.selectedMessageID}) {messageDetail(m).frame(minWidth:370,maxWidth:.infinity,maxHeight:.infinity)}
                    else {EmptyMailView(icon:"envelope.open",title:"选一封邮件，慢慢读",detail:"邮件正文、附件和回复会显示在这里。") .frame(minWidth:350)}
                }
            }
            .onChange(of:store.selectedMessageID) {_,id in showHTML = false; if let id {Task {await store.loadMessage(id)}}}
            .onChange(of:store.mailboxFilter) {_,id in
                store.folder = "INBOX"; store.retainVisibleMessageSelection()
            }
            .onChange(of:store.folder) {_,folder in
                store.retainVisibleMessageSelection()
            }
        }
    }
    private func messageDetail(_ m: CachedMessage) -> some View {
        VStack(alignment:.leading,spacing:0) {
            HStack(spacing:12) {
                Button {store.reply(m)} label:{Label("回复",systemImage:"arrowshape.turn.up.left")}.disabled(!m.loaded)
                Menu {Button("回复全部") {store.reply(m,all:true)}; Button("转发正文") {store.reply(m,forward:true)}} label:{Image(systemName:"chevron.down")}.menuStyle(.borderlessButton).frame(width:20).disabled(!m.loaded)
                Spacer()
                Button {Task {await store.changeFlag(m,flag:!m.isFlagged)}} label:{Image(systemName:m.isFlagged ? "star.fill" : "star")}.help("切换星标")
                Button {Task {await store.changeFlag(m,read:!m.isRead)}} label:{Image(systemName:m.isRead ? "envelope.badge" : "envelope.open")}.help(m.isRead ? "标为未读" : "标为已读")
                if m.folder != "__local_sent__" {Menu {ForEach((store.folders[m.accountID] ?? []).filter {$0.selectable && $0.path != m.folder}) {f in Button("移至 " + f.displayName) {Task {await store.moveMessage(m,destination:f.path)}}}} label:{Image(systemName:"folder")}.menuStyle(.borderlessButton).frame(width:22).help("移至文件夹或垃圾箱")}
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment:.leading,spacing:15) {
                    Text(m.subject.isEmpty ? "（无主题）" : m.subject).font(.system(size:23,weight:.semibold)).textSelection(.enabled).padding(.top,4)
                    HStack(alignment:.top) {VStack(alignment:.leading,spacing:5) {Text("发件人：" + m.from); Text("收件人：" + m.to); if !m.cc.isEmpty {Text("抄送：" + m.cc)}}.font(.system(size:11)).foregroundStyle(.secondary).textSelection(.enabled); Spacer(); IdentityBadge(identity:store.identity(store.account(m.accountID)?.identityID))}
                    Text(m.date.formatted(date:.long,time:.shortened)).font(.system(size:10)).foregroundStyle(.tertiary)
                    Divider()
                    let extracted = CodeExtractor.extract(subject: m.subject, body: m.body, html: m.html)
                    if let primary = extracted.first {
                        codeBanner(primary)
                    }
                    if store.detailBusy.contains(m.id) {ProgressView("正在读取邮件…").font(.system(size:12)).padding(.vertical,20)}
                    if m.loaded {
                        if m.html != nil {Toggle("查看邮件排版（外部图片已阻止）",isOn:$showHTML).font(.system(size:10)).toggleStyle(.checkbox)}
                        if showHTML, let html = m.html {SafeMailHTML(html:html).frame(minHeight:420)}
                        else {Text(m.body.isEmpty ? "这封邮件没有纯文本正文，可以切换到排版视图查看。" : m.body).font(.system(size:14)).lineSpacing(6).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)}
                        if !m.attachments.isEmpty {Divider(); Text("附件 · \(m.attachments.count)").font(.system(size:12,weight:.semibold)); ForEach(m.attachments) {a in Button {saveAttachment(a)} label:{HStack {Image(systemName:"paperclip"); Text(a.filename).lineLimit(1); Spacer(); Text(ByteCountFormatter.string(fromByteCount:Int64(a.data.count),countStyle:.file)).foregroundStyle(.secondary); Image(systemName:"arrow.down.to.line")}.font(.system(size:12)).padding(12).background(Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:8))}.buttonStyle(.plain)}}
                    } else if !store.detailBusy.contains(m.id) {Button("读取正文") {Task {await store.loadMessage(m.id)}}}
                }.padding(24)
            }
        }.background(Color(nsColor:.textBackgroundColor))
    }
    private func codeBanner(_ item: ExtractedCode) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: item.isLink ? "link.badge.plus" : "key.radiowaves.forward.fill")
                .font(.system(size: 20))
                .foregroundStyle(Color.indigo)
                .frame(width: 42, height: 42)
                .background(Color.indigo.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(item.displayTitle).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.indigo)
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
        .background(Color.indigo.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.indigo.opacity(0.18), lineWidth: 1))
    }
    private func saveAttachment(_ a: CachedAttachment) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = URL(fileURLWithPath:a.filename).lastPathComponent
        if panel.runModal() == .OK, let url = panel.url {do {try a.data.write(to:url,options:.atomic)} catch {store.publish(error)}}
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
        view.loadHTMLString("<!doctype html><html><head><meta http-equiv=\"Content-Security-Policy\" content=\"" + csp + "\"><meta name=\"viewport\" content=\"width=device-width\"><style>body{font-family:-apple-system;font-size:14px;line-height:1.7;overflow-wrap:anywhere;}img{max-width:100%;height:auto;}table{max-width:100%;}pre{white-space:pre-wrap;}</style></head><body>" + html + "</body></html>",baseURL:nil)
    }
    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded = ""
        func webView(_ webView:WKWebView,decidePolicyFor action:WKNavigationAction,decisionHandler:@escaping(WKNavigationActionPolicy)->Void) {
            if action.navigationType == .linkActivated {if let u = action.request.url, ["https","http"].contains(u.scheme?.lowercased() ?? "") {NSWorkspace.shared.open(u)}; decisionHandler(.cancel)}
            else if action.request.url?.scheme == "about" {decisionHandler(.allow)} else {decisionHandler(.cancel)}
        }
    }
}
