import SwiftUI
import AppKit

struct DownloadComposer: View {
    @ObservedObject var coordinator: PortalDownloadCoordinator
    @ObservedObject var manager: DownloadManager
    @ObservedObject var exchange: DownloadGaoExchange
    let requestID: UUID?
    @Environment(\.dismiss) private var dismiss
    @State private var linkText = ""
    @State private var destinationID: UUID?
    @State private var error: String?
    private var record: DownloadGaoExchangeRecord? { exchange.records.first { $0.id == requestID } }
    private var urls: [String] { linkText.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
    private var valid: Bool {
        !urls.isEmpty && urls.count <= 32 && urls.allSatisfy {
            guard $0.utf8.count <= 16_384, let value = URLComponents(string: $0),
                  ["http", "https"].contains(value.scheme?.lowercased() ?? ""),
                  value.host?.isEmpty == false, value.user == nil, value.password == nil, value.fragment == nil else { return false }
            return true
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "arrow.down.circle.fill").font(.system(size: 30)).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(requestID == nil && coordinator.internalReviewID == nil ? "新建下载" : "复核下载请求").font(.title2.weight(.semibold))
                    Text("确认链接与保存位置后开始").foregroundStyle(.secondary).font(.callout)
                }
                Spacer()
                if requestID == nil && coordinator.internalReviewID == nil { Button("粘贴链接") { linkText = NSPasteboard.general.string(forType: .string) ?? "" } }
            }
            if let record {
                Label("来源声明：\(record.sourceBundleID)", systemImage: "app.connected.to.app.below.fill").font(.callout)
                Text("来源标识仅用于关联，不能证明发送者身份。这里只接收文件直链，不使用浏览器会话或登录凭据。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if requestID == nil && coordinator.internalReviewID == nil {
                VStack(alignment: .leading, spacing: 7) {
                    Text("HTTP / HTTPS 文件链接 · 每行一条，最多 32 条").font(.callout.weight(.medium))
                    TextEditor(text: $linkText).font(.system(.body, design: .monospaced)).padding(7)
                        .frame(height: 135).background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
                        .accessibilityLabel("下载链接，每行一条")
                }
            }
            if !urls.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(urls.prefix(32).enumerated()), id: \.offset) { index, raw in
                            HStack(alignment: .top, spacing: 10) {
                                Text(String(format: "%02d", index + 1)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 22)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(previewName(raw)).font(.callout.weight(.medium)).lineLimit(1)
                                    Text(previewSource(raw)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Text("大小待响应确认").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.padding(12)
                }.frame(maxHeight: 180).background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            }
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "folder").font(.title3).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 5) {
                    Text("保存位置").font(.caption).foregroundStyle(.secondary)
                    if manager.destinations.isEmpty {
                        Text("请选择目标目录").font(.callout)
                    } else {
                        Picker("保存位置", selection: $destinationID) {
                            Text("请选择目录").tag(Optional<UUID>.none)
                            ForEach(manager.destinations.filter { $0.requiresReauthorization != true }) { destination in Text(destination.displayPath).tag(Optional(destination.id)) }
                        }.labelsHidden().frame(maxWidth: .infinity)
                    }
                }
                Spacer()
                Button("选择目录…") { if let grant = coordinator.selectDirectory() { destinationID = grant.id } }
            }.padding(12).background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            if manager.destinations.contains(where: { $0.requiresReauthorization == true }) {
                Text("迁入的旧目录需要在本应用重新选择。已完成文件与片段保留原位，重新授权后才能核验或恢复。")
                    .font(.caption).foregroundStyle(.orange)
            }
            VStack(alignment: .leading, spacing: 6) {
                Label("同名文件自动使用新名称，保留已有原件。", systemImage: "checkmark.shield")
                Label("先校验，再正式落盘；暂停后会核验资源版本。", systemImage: "externaldrive.badge.checkmark")
                Label("本版为文件下载，不解析网站、合集、DRM 或受限媒体。", systemImage: "info.circle")
            }.font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
            if !linkText.isEmpty && !valid { Text("请提供 1–32 条有效文件链接，不接受用户名或密码形式的 URL。") .font(.caption).foregroundStyle(.orange) }
            Divider()
            HStack {
                Text("\(urls.count) 个独立任务 · 并发上限 \(manager.settings.concurrency)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("返回") { coordinator.cancelComposer(); dismiss() }.keyboardShortcut(.cancelAction)
                Button("确认并开始下载") {
                    guard let destinationID else { return }
                    do { try coordinator.confirm(urls: urls, destinationID: destinationID, requestID: requestID); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!valid || destinationID == nil || manager.recoveryIssue != nil || exchange.recoveryIssue != nil || exchange.isPackaging || coordinator.shuttingDown)
            }
        }
        .padding(26).frame(width: 670)
        .onAppear {
            if let record { linkText = record.urls.joined(separator: "\n") }
            else if coordinator.internalReviewID != nil { linkText = coordinator.composerURLs.joined(separator: "\n") }
            destinationID = manager.destinations.last(where: { $0.requiresReauthorization != true })?.id
        }
        .onDisappear { coordinator.composerDidDismiss() }
    }
    private func previewName(_ raw: String) -> String {
        guard let url = URL(string: raw), !url.lastPathComponent.isEmpty else { return "由服务器确认文件名" }
        return String(url.lastPathComponent.prefix(200))
    }
    private func previewSource(_ raw: String) -> String {
        guard var value = URLComponents(string: raw), value.host != nil else { return "链接格式无效" }
        let query = value.query != nil
        value.query = nil; value.fragment = nil; value.user = nil; value.password = nil
        return (value.string ?? "链接格式无效") + (query ? "（查询参数已隐藏）" : "")
    }
}

struct ExchangeListView: View {
    @ObservedObject var coordinator: PortalDownloadCoordinator
    @ObservedObject var manager: DownloadManager
    @ObservedObject var exchange: DownloadGaoExchange
    @State private var selected: UUID?
    @State private var processing: UUID?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("跨应用请求").font(.title2.weight(.semibold))
                    Text("先复核，再建任务；接收回执与最终结果分别回送。") .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("接收请求…") { coordinator.importPackage() }
            }.padding(24)
            Divider()
            if exchange.records.isEmpty && coordinator.isolatedHistory.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "arrow.left.arrow.right.circle").font(.system(size: 46, weight: .light)).foregroundStyle(.secondary)
                    Text("尚未收到下载请求").font(.title3.weight(.medium))
                    Text("其他搞系列应用可交接文件直链，也可以打开 .gaoaction 请求包。") .font(.callout).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(exchange.records) { record in
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Label(record.sourceBundleID, systemImage: "app.connected.to.app.below.fill").font(.headline)
                                Spacer()
                                Text((record.isLegacyHistory ? "迁入历史 · " : "") + stageTitle(record.stage)).font(.caption).padding(.horizontal, 9).padding(.vertical, 4).background(Color.secondary.opacity(0.08), in: Capsule())
                            }
                            Text("\(record.urls.count) 个链接 · \(record.receivedAt.formatted(date: .abbreviated, time: .shortened))").font(.callout).foregroundStyle(.secondary)
                            Text("请求 \(record.id.uuidString)").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                            if record.isLegacyHistory {
                                Text("迁入的旧下载历史 · 原请求、任务与结果映射保留；不重新审批、创建任务或发送旧提供方结果。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if !record.taskIDs.isEmpty {
                                VStack(alignment: .leading, spacing: 7) {
                                    ForEach(record.taskIDs, id: \.self) { taskID in
                                        if let item = manager.items.first(where: { $0.jobID == taskID }) {
                                            HStack { Text(item.artifact?.fileName ?? item.suggestedName).lineLimit(1); Spacer(); Text(item.state.title).foregroundStyle(item.state.tint) }
                                                .font(.caption)
                                        } else { Text("任务资料缺失：\(taskID.uuidString)").font(.caption).foregroundStyle(.orange) }
                                    }
                                }
                            }
                            HStack {
                                if record.isLegacyHistory {
                                    Text("历史记录只读").font(.caption).foregroundStyle(.secondary)
                                } else if record.stage == "awaitingReview" {
                                    Button("复核并选择保存位置…") { coordinator.incomingReview = record.id; coordinator.showComposer = true }.buttonStyle(.borderedProminent).disabled(exchange.isPackaging)
                                    Button("拒绝请求") { exchange.decline(record.id) }
                                } else if !record.taskIDs.isEmpty && !record.hasFinalResult {
                                    if record.itemIDs.count != record.taskIDs.count || !record.deliveries.contains(where: { $0.manifest.status == "pending" }) {
                                        Button("补全接收回执") { coordinator.repairAcceptance(record) }.disabled(exchange.isPackaging)
                                    } else {
                                        Button("生成最终结果") { coordinator.generateFinal(record) }.disabled(!isFinal(record) || exchange.isPackaging || coordinator.preparingResults.contains(record.id))
                                    }
                                } else if record.stage == "cancelled" && !record.hasFinalResult {
                                    Button("生成取消回执") { coordinator.generateFinal(record) }.disabled(exchange.isPackaging || coordinator.preparingResults.contains(record.id))
                                }
                                Spacer()
                                if coordinator.preparingResults.contains(record.id) || exchange.isPackaging { ProgressView().controlSize(.small) }
                            }
                            ForEach(record.outgoingURLs, id: \.path) { url in
                                HStack {
                                    Image(systemName: "shippingbox").foregroundStyle(.secondary)
                                    Text(url == record.outgoingURLs.last && record.hasFinalResult ? "最终结果包" : "阶段回执包").font(.caption)
                                    Spacer()
                                    Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.controlSize(.small)
                                    Button("发送结果") { exchange.sendResult(url, for: record.id) }.controlSize(.small).disabled(exchange.isPackaging || record.isLegacyHistory)
                                }
                            }
                        }.padding(.vertical, 16)
                    }
                    if !coordinator.isolatedHistory.isEmpty {
                        Section("原包缺失的旧历史") {
                            Text("这些已取消的请求没有产生任务。原请求或结果包已经缺失，未完成原包验证；仅保留现存记录，不可执行或重试。")
                                .font(.callout).foregroundStyle(.secondary)
                            ForEach(coordinator.isolatedHistory) { entry in
                                VStack(alignment: .leading, spacing: 10) {
                                    Label("原包缺失 · 仅保留历史", systemImage: "archivebox")
                                        .font(.headline).foregroundStyle(.orange)
                                    Text("已取消 · 未产生任务 · \(entry.receivedAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.callout).foregroundStyle(.secondary)
                                    Text("请求 \(entry.id.uuidString)")
                                        .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                                    Text("缺失 \(entry.missingPackages.count) 个原包。取消记录与原摘要已保留，不能据此恢复下载或发送回执。")
                                        .font(.caption).foregroundStyle(.secondary)
                                    DisclosureGroup("原记录摘要") {
                                        Text(entry.requestManifestSHA256)
                                            .font(.caption.monospaced()).textSelection(.enabled)
                                    }.font(.caption)
                                }.padding(.vertical, 12)
                            }
                        }
                    }
                }.listStyle(.inset)
            }
            Divider()
            Text("发送仅表示递交，仍需对方匹配并确认。失败可重试，不会重复下载。超过包预算的文件需另行协商交接。")
                .font(.caption).foregroundStyle(.secondary).padding(16)
        }
    }
    private func isFinal(_ record: DownloadGaoExchangeRecord) -> Bool {
        !record.taskIDs.isEmpty && record.taskIDs.allSatisfy { taskID in
            let items = manager.items.filter { $0.jobID == taskID }
            return !items.isEmpty && items.allSatisfy { $0.state.isTerminal }
        }
    }
    private func stageTitle(_ stage: String) -> String {
        switch stage {
        case "awaitingReview": return "待复核"; case "accepted": return "已建任务 · 待完成"
        case "completed": return "已完成"; case "partial": return "部分完成"; case "failed": return "失败"
        case "cancelled": return "已拒绝 / 取消"; case "interrupted": return "交接中断 · 待核对"
        default: return stage
        }
    }
}
