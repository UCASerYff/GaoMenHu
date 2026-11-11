import AppKit
import SwiftUI

struct MailFloatingView: View {
    @ObservedObject var store: MailStore
    @ObservedObject var controller: MailFloatingController
    @State private var copiedCode: String?

    private var summary: MailFloatingSummary {
        MailFloatingSummary(library: store.library, messages: store.messages)
    }
    private var syncing: Bool { !store.busy.isDisjoint(with: Set(summary.scopeAccounts.map(\.id))) }
    private var canSync: Bool { summary.scopeAccounts.contains(where: { $0.enabled && store.isHostConnectionAuthorized(accountID:$0.id) }) && !syncing }

    var body: some View {
        Group {
            if controller.isExpanded { card }
            else {
                let all = MailFloatingSummary(library:store.library,messages:store.messages)
                MailFloatingRailView(controller:controller,unreadCount:all.unreadCount,errorCount:all.errorCount + (store.problem == nil ? 0 : 1))
            }
        }
    }

    private var card: some View {
        VStack(spacing: 0) {
            unreadHeader
            ScrollView(.vertical) {
                expandedContent
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                    .frame(maxWidth: .infinity, alignment: .top)
                    .fixedSize(horizontal: false, vertical: true)
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(key: MailFloatingHeightPreferenceKey.self, value: geometry.size.height + MailFloatingController.dragHeaderHeight)
                        }
                    }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: max(controller.expandedHeight - MailFloatingController.dragHeaderHeight, 0))
        }
        .frame(maxWidth: .infinity)
        .frame(height: controller.expandedHeight)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .circular))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .circular).stroke(Color.primary.opacity(0.09), lineWidth: 1))
        .tint(PortalTheme.accent)
        .onPreferenceChange(MailFloatingHeightPreferenceKey.self) { height in
            guard height.isFinite, height > 0 else { return }
            let ideal = ceil(height)
            controller.updateExpandedHeight(ideal)
        }
    }

    private var unreadHeader: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 1) {
                Text(String(summary.unreadCount)).font(.system(size: 40, weight: .semibold, design: .rounded)).monospacedDigit()
                Text("缓存未读 · 收件箱").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 7) {
                statusBadge
                Text("\(summary.enabledCount) 个启用 · \(summary.registeredCount) 个仅登记")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .frame(height: MailFloatingController.dragHeaderHeight - 16)
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
        .help("拖动未读统计区域自由移动悬浮窗，靠近左右边缘时吸附")
    }

    private var expandedContent: some View {
        VStack(spacing: 6) {
            Divider().opacity(0.5)
            VStack(alignment: .leading, spacing: 6) {
                if summary.accounts.isEmpty { emptyAccounts }
                else if controller.showPreviews { previews }
                else { privateSummary }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider().opacity(0.5)
            HStack(spacing: 8) {
                Button { controller.openInbox() } label: {
                    Label(summary.accounts.isEmpty ? "添加邮箱" : "收件箱", systemImage: summary.accounts.isEmpty ? "plus" : "tray")
                }.buttonStyle(.borderedProminent)
                Spacer(minLength: 0)
                Button { sync() } label: { Label("同步", systemImage: "arrow.clockwise") }
                    .disabled(!canSync).help("同步所有已启用邮箱")
                Button { controller.compose() } label: { Label("写信", systemImage: "square.and.pencil") }
            }
            .font(.system(size: 11)).controlSize(.small)
            footer
        }
    }

    private var statusBadge: some View {
        HStack(spacing: 4) {
            if syncing { ProgressView().controlSize(.mini) }
            else { Image(systemName: summary.errorCount > 0 || store.problem != nil ? "exclamationmark.circle" : "tray") }
            Text(syncing ? "正在同步" : summary.errorCount > 0 ? "\(summary.errorCount) 个邮箱待检查" : store.problem != nil ? "操作待处理" : "本机缓存")
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle((summary.errorCount > 0 || store.problem != nil) && !syncing ? Color.orange : PortalTheme.accent)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(((summary.errorCount > 0 || store.problem != nil) && !syncing ? Color.orange : PortalTheme.accent).opacity(0.08), in: Capsule())
    }

    private var footer: some View {
        HStack {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Text(MailFloatingSummary(library: store.library, messages: store.messages, now: context.date).latestSyncLabel)
            }
            Spacer(minLength: 8)
            Text("最近同步范围").help("只统计已缓存的收件箱邮件，并非服务商的完整未读总数")
        }.font(.system(size: 9)).foregroundStyle(.secondary)
    }

    private var emptyAccounts: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("把邮箱带到桌面").font(.system(size: 13, weight: .semibold))
            Text("添加邮箱后，在这里查看缓存未读数量和同步状态。")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(PortalTheme.accent.opacity(0.045), in: RoundedRectangle(cornerRadius: 11))
    }

    private var privateSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("邮件预览已隐藏", systemImage: "eye.slash")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Text(summary.unreadCount > 0 ? "有 \(summary.unreadCount) 封缓存未读邮件，打开收件箱查看。" : "当前缓存中没有未读邮件。")
                .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Text("在设置的外观页开启邮件预览，可显示最近三封邮件的发件人和主题。")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if summary.errorCount > 0 || store.problem != nil { checkAccounts }
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 11))
    }

    @ViewBuilder private var previews: some View {
        if summary.unreadMessages.isEmpty {
            Label("暂无缓存未读邮件", systemImage: "envelope.open").font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 8)
        } else {
            ForEach(summary.unreadMessages) { message in
                Button { controller.openInbox(accountID: message.accountID, messageID: message.id) } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Circle().fill(PortalTheme.accent).frame(width: 5, height: 5).padding(.top, 5)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(message.from.isEmpty ? "未知发件人" : message.from).font(.system(size: 10, weight: .medium)).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(message.date.formatted(date: .omitted, time: .shortened)).font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                            Text(message.subject.isEmpty ? "（无主题）" : message.subject).font(.system(size: 12, weight: .medium)).lineLimit(2)
                            if let code = CodeExtractor.primaryCode(subject: message.subject, body: message.body, html: message.html), code.type != .link {
                                HStack(spacing: 5) {
                                    Image(systemName: "key.fill").font(.system(size: 9)).foregroundStyle(PortalTheme.accent)
                                    Text(code.value).font(.system(size: 11, weight: .bold, design: .monospaced))
                                    Spacer()
                                    Button {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(code.value, forType: .string)
                                        copiedCode = code.value
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                            if copiedCode == code.value { copiedCode = nil }
                                        }
                                    } label: {
                                        HStack(spacing: 3) {
                                            Image(systemName: copiedCode == code.value ? "checkmark" : "doc.on.doc").font(.system(size: 8))
                                            Text(copiedCode == code.value ? "已复制" : "复制").font(.system(size: 9))
                                        }
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(PortalTheme.accent.opacity(0.12), in: Capsule())
                                    }.buttonStyle(.plain)
                                }
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(PortalTheme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                            }
                            Text(store.account(message.accountID)?.displayName ?? "").font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }.padding(9).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
                }.buttonStyle(.plain).accessibilityLabel("打开邮件：" + message.subject)
            }
        }
        if summary.errorCount > 0 || store.problem != nil { checkAccounts }
    }

    private var checkAccounts: some View {
        Button(store.problem != nil ? "查看操作提示" : "查看邮箱状态") {
            controller.openInbox()
            if store.problem == nil { store.route = "accounts" }
        }.font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(.orange)
    }

    private func sync() {
        guard canSync else { return }
        Task { await store.syncAll() }
    }
}

/// Read the intrinsic expanded content only; the 104-point edge rail never publishes a card height.
private struct MailFloatingHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
