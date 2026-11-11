import SwiftUI
import AppKit

enum DownloadSection: String, CaseIterable, Identifiable {
    case all, active, paused, completed, failed, exchange
    var id: String { rawValue }
    var title: String { switch self {
    case .all: return "全部任务"; case .active: return "正在下载"; case .paused: return "已暂停 / 等待"
    case .completed: return "已完成"; case .failed: return "失败 / 取消"; case .exchange: return "跨应用请求"
    } }
    var icon: String { switch self {
    case .all: return "tray.full"; case .active: return "arrow.down.circle"; case .paused: return "pause.circle"
    case .completed: return "checkmark.circle"; case .failed: return "exclamationmark.circle"; case .exchange: return "arrow.left.arrow.right"
    } }
    func matches(_ item: DownloadItem) -> Bool {
        switch self {
        case .all: return true
        case .active: return [.queued, .running, .verifying, .committing, .pausing].contains(item.state)
        case .paused: return [.paused, .waitingForNetwork, .waitingForDestination, .retryScheduled].contains(item.state)
        case .completed: return item.state == .completed
        case .failed: return [.failed, .cancelled, .partial].contains(item.state)
        case .exchange: return false
        }
    }
}

func downloadBytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }

extension DownloadState {
    var tint: Color {
        switch self {
        case .completed: return .green
        case .failed, .partial: return .orange
        case .running, .verifying, .committing: return .accentColor
        default: return .secondary
        }
    }
}

struct DownloadMainView: View {
    @ObservedObject var coordinator: PortalDownloadCoordinator
    @ObservedObject var manager: DownloadManager
    @ObservedObject var exchange: DownloadGaoExchange
    @State private var selectedID: UUID?
    @State private var query = ""
    @State private var visibleCount = 100
    @State private var deleteCandidate: UUID?
    @State private var cancelCandidate: UUID?

    private var filtered: [DownloadItem] {
        manager.items.reversed().filter { coordinator.selectedSection.matches($0) &&
            (query.isEmpty || $0.suggestedName.localizedCaseInsensitiveContains(query) || $0.displayURL.localizedCaseInsensitiveContains(query)) }
    }
    private var selected: DownloadItem? { manager.items.first { $0.id == selectedID } }
    private var recovery: String? { manager.recoveryIssue ?? exchange.recoveryIssue }

    var body: some View {
        NavigationSplitView {
            List(selection: $coordinator.selectedSection) {
                Section("下载") {
                    ForEach(DownloadSection.allCases.filter { $0 != .exchange }) { section in
                        Label {
                            HStack {
                                Text(section.title)
                                Spacer()
                                Text("\(manager.items.filter { section.matches($0) }.count)")
                                    .foregroundStyle(.secondary).font(.caption.monospacedDigit())
                            }
                        } icon: { Image(systemName: section.icon) }.tag(section)
                    }
                }
                Section("交接") {
                    Label {
                        HStack { Text("跨应用请求"); Spacer(); Text("\(exchange.records.filter { $0.stage == "awaitingReview" }.count)").foregroundStyle(.secondary).font(.caption) }
                    } icon: { Image(systemName: "arrow.left.arrow.right") }.tag(DownloadSection.exchange)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 216)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("仅在应用运行时下载", systemImage: "info.circle")
                    Text("退出会暂停，重新打开后由你恢复。")
                        .font(.caption2).foregroundStyle(.secondary)
                }.font(.caption).padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
        } detail: {
            VStack(spacing: 0) {
                if let recovery {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("资料需要恢复，已停止写入", systemImage: "exclamationmark.shield.fill").font(.headline)
                        Text(recovery).font(.callout).textSelection(.enabled)
                        Button("查看恢复说明") { showBundledGuide("Recovery") }
                    }
                    .padding().frame(maxWidth: .infinity, alignment: .leading).background(Color.orange.opacity(0.12))
                }
                if coordinator.shuttingDown {
                    HStack { ProgressView().controlSize(.small); Text("正在安全暂停并保存结果，完成后退出…").font(.callout) }
                        .padding(12).frame(maxWidth: .infinity).background(Color.secondary.opacity(0.06))
                }
                if coordinator.selectedSection == .exchange {
                    ExchangeListView(coordinator: coordinator, manager: manager, exchange: exchange)
                } else {
                    HStack(alignment: .firstTextBaseline) {
                        Text(coordinator.selectedSection.title).font(.title2.weight(.semibold))
                        Text("\(filtered.count) 个任务").font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        if manager.settings.speedLimitBytesPerSecond > 0 {
                            Label("限速 \(downloadBytes(manager.settings.speedLimitBytesPerSecond))/s", systemImage: "speedometer").font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.horizontal, 24).padding(.vertical, 20)
                    Divider()
                    if filtered.isEmpty {
                        VStack(spacing: 14) {
                            Image(systemName: query.isEmpty ? "arrow.down.doc" : "magnifyingglass").font(.system(size: 46, weight: .light)).foregroundStyle(.secondary)
                            Text(query.isEmpty ? "从一个链接开始" : "没有匹配的任务").font(.title3.weight(.medium))
                            Text(query.isEmpty ? "粘贴 HTTP 或 HTTPS 文件直链，确认保存位置后下载。" : "尝试文件名或来源主机名。")
                                .font(.callout).foregroundStyle(.secondary)
                            if query.isEmpty { Button("新建下载…") { coordinator.showComposer = true }.buttonStyle(.borderedProminent).disabled(recovery != nil) }
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        HSplitView {
                            List(selection: $selectedID) {
                                ForEach(Array(filtered.prefix(visibleCount))) { item in
                                    DownloadRow(item: item).tag(item.id)
                                        .contextMenu { itemActions(item) }
                                }
                                if filtered.count > visibleCount { Button("再显示 100 个") { visibleCount += 100 }.buttonStyle(.plain).foregroundStyle(Color.accentColor) }
                            }.listStyle(.inset).frame(minWidth: 380)
                            if let selected {
                                DownloadDetail(item: selected, manager: manager, coordinator: coordinator,
                                    onDelete: { deleteCandidate = selected.id }, onCancel: { cancelCandidate = selected.id })
                                    .frame(minWidth: 270, idealWidth: 300, maxWidth: 360)
                            }
                        }
                    }
                    Divider()
                    HStack {
                        Text("\(manager.items.filter { $0.state == .running }.count) 项传输中")
                        Spacer()
                        Text("校验和正式落盘完成后才记为完成")
                    }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 10)
                }
            }
            .searchable(text: $query, prompt: "搜索文件名或来源")
            .toolbar {
                ToolbarItemGroup {
                    Button { coordinator.showComposer = true } label: { Label("新建下载", systemImage: "plus") }.help("新建下载（⌘N）").disabled(recovery != nil)
                    Button { manager.pauseAll() } label: { Label("暂停全部", systemImage: "pause") }.disabled(recovery != nil)
                    Button { manager.resumeAll() } label: { Label("恢复全部", systemImage: "play") }.disabled(recovery != nil)
                    Button { coordinator.showSettings = true } label: { Label("下载设置", systemImage: "gearshape") }
                }
            }
        }
        .sheet(isPresented: $coordinator.showComposer) {
            DownloadComposer(coordinator: coordinator, manager: manager, exchange: exchange, requestID: coordinator.incomingReview)
        }
        .sheet(isPresented: $coordinator.showSettings) {
            DownloadSettingsView(coordinator: coordinator, manager: manager, exchange: exchange)
        }
        .tint(PortalTheme.accent)
        .preferredColorScheme(manager.settings.appearance == "dark" ? .dark : manager.settings.appearance == "light" ? .light : nil)
        .disabled(coordinator.shuttingDown)
        .onChange(of: coordinator.selectedSection) { _ in visibleCount = 100; selectedID = nil }
        .onReceive(manager.$lastError.compactMap { $0 }) { coordinator.alert = $0 }
        .onReceive(exchange.$lastError.compactMap { $0 }) { coordinator.alert = $0 }
        .alert("搞门户 · 下载", isPresented: Binding(get: { coordinator.alert != nil }, set: { if !$0 { coordinator.alert = nil } })) {
            Button("好") { coordinator.alert = nil }
        } message: { Text(coordinator.alert ?? "") }
        .confirmationDialog("取消这项下载？", isPresented: Binding(get: { cancelCandidate != nil }, set: { if !$0 { cancelCandidate = nil } })) {
            Button("取消并保留临时数据") { if let id = cancelCandidate { manager.cancel(id) }; cancelCandidate = nil }
            Button("取消并清理本任务临时数据", role: .destructive) { if let id = cancelCandidate { manager.cancel(id, removePartial: true) }; cancelCandidate = nil }
            Button("返回", role: .cancel) { cancelCandidate = nil }
        } message: { Text("不会删除已经发布的文件或目标目录内的原件。") }
        .confirmationDialog("删除这项历史记录？", isPresented: Binding(get: { deleteCandidate != nil }, set: { if !$0 { deleteCandidate = nil } })) {
            Button("删除历史", role: .destructive) { if let id = deleteCandidate { manager.deleteHistory(id) }; deleteCandidate = nil }
            Button("返回", role: .cancel) { deleteCandidate = nil }
        } message: { Text("不删除下载文件。跨应用关联任务需保留回执依据，可能无法移除。") }
    }

    @ViewBuilder private func itemActions(_ item: DownloadItem) -> some View {
        if manager.destinations.contains(where: { $0.id == item.destinationID }),
           !item.state.isActive, item.state != .queued, item.state != .retryScheduled {
            Button("重新授权原保存目录…") { coordinator.reauthorizeOriginalDirectory(for: item) }
        }
        if manager.destinations.first(where: { $0.id == item.destinationID })?.requiresReauthorization == true {
            // The explicit selection above is also available after later reboots.
        } else if item.state == .completed {
            Button("打开文件") { coordinator.openArtifact(item, reveal: false) }
            Button("在 Finder 中显示") { coordinator.openArtifact(item, reveal: true) }
        } else {
            if item.state.isActive || item.state == .queued { Button("暂停") { manager.pause(item.id) } }
            if item.state.canResume { Button("恢复 / 重试") { coordinator.resumeOrRetry(item) } }
            if !item.state.isTerminal { Button("取消…") { cancelCandidate = item.id } }
        }
        if !item.state.isActive && item.state != .completed {
            Button("清理本任务临时数据", role: .destructive) { manager.removePartialFiles(item.id) }
        }
        if item.state.isTerminal || item.state == .paused { Button("删除历史…", role: .destructive) { deleteCandidate = item.id } }
    }
}

struct DownloadRow: View {
    let item: DownloadItem
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: item.state == .completed ? "doc.badge.checkmark" : "arrow.down.doc")
                .font(.system(size: 24, weight: .light)).foregroundStyle(item.state.tint).frame(width: 32, height: 40)
            VStack(alignment: .leading, spacing: 7) {
                HStack { Text(item.artifact?.fileName ?? item.suggestedName).font(.body.weight(.medium)).lineLimit(1); Spacer(); Text(item.state.title).font(.caption).foregroundStyle(item.state.tint) }
                Text(item.displayURL).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if item.state == .completed {
                    Text("\(downloadBytes(item.artifact?.byteCount ?? item.bytesReceived)) · SHA-256 已记录").font(.caption).foregroundStyle(.secondary)
                } else {
                    if let total = item.expectedBytes, total > 0 {
                        ProgressView(value: min(Double(item.bytesReceived) / Double(total), 0.995)).tint(item.state.tint)
                    } else if item.state.isActive { ProgressView().progressViewStyle(.linear) }
                    HStack {
                        Text(downloadBytes(item.bytesReceived) + (item.expectedBytes.map { " / " + downloadBytes($0) } ?? " · 总大小未知"))
                        Spacer()
                        if item.state == .running && item.bytesPerSecond > 0 { Text("\(downloadBytes(Int64(item.bytesPerSecond)))/s") }
                    }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                if let error = item.errorMessage { Text(error).font(.caption).foregroundStyle(.orange).lineLimit(2) }
            }
        }.padding(.vertical, 10).accessibilityElement(children: .combine)
    }
}

struct DownloadDetail: View {
    let item: DownloadItem
    @ObservedObject var manager: DownloadManager
    @ObservedObject var coordinator: PortalDownloadCoordinator
    let onDelete: () -> Void
    let onCancel: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Label(item.state.title, systemImage: item.state == .completed ? "checkmark.circle.fill" : "arrow.down.circle").foregroundStyle(item.state.tint).font(.headline)
                Text(item.artifact?.fileName ?? item.suggestedName).font(.title3.weight(.semibold)).textSelection(.enabled)
                if manager.destinations.first(where: { $0.id == item.destinationID })?.requiresReauthorization == true {
                    Text("需要重新选择原保存目录以授权搞门户。原任务、文件与未完成片段保持原位，不自动开始下载。")
                        .font(.callout).foregroundStyle(.orange)
                    Button("重新授权原保存目录…") { coordinator.reauthorizeOriginalDirectory(for: item) }.buttonStyle(.borderedProminent)
                } else if item.state == .completed {
                    HStack {
                        Button("打开文件") { coordinator.openArtifact(item, reveal: false) }.buttonStyle(.borderedProminent)
                        Button { coordinator.openArtifact(item, reveal: true) } label: { Image(systemName: "folder") }.help("在 Finder 中显示")
                    }
                } else {
                    HStack {
                        if item.state.isActive || item.state == .queued { Button("暂停") { manager.pause(item.id) } }
                        if item.state.canResume { Button("恢复 / 重试") { coordinator.resumeOrRetry(item) }.buttonStyle(.borderedProminent) }
                        if !item.state.isTerminal { Button("取消…", action: onCancel) }
                    }
                }
                Divider()
                detail("来源", item.displayURL)
                detail("保存位置", manager.destinations.first { $0.id == item.destinationID }?.displayPath ?? "目录授权缺失")
                detail("任务 ID", item.jobID.uuidString)
                detail("条目 ID", item.id.uuidString)
                detail("创建时间", item.createdAt.formatted(date: .abbreviated, time: .shortened))
                if let retry = item.retryAt { detail("下一次重试", retry.formatted(date: .omitted, time: .standard)) }
                if let explanation = item.resumeExplanation { detail("续传策略", explanation) }
                if let error = item.errorMessage { detail("详情", error) }
                if let digest = item.sha256 {
                    detail("SHA-256", digest)
                    Text("摘要用于本地完整性证据；未提供来源可信摘要时，不代表来源真实性验证。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !item.state.isActive && item.state != .completed {
                    Button("清理本任务临时数据", role: .destructive) { manager.removePartialFiles(item.id) }
                }
                if item.state.isTerminal || item.state == .paused { Button("删除历史记录…", action: onDelete) }
            }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func detail(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
    }
}

func showBundledGuide(_ name: String) {
    if let url = Bundle.main.url(forResource: name, withExtension: "md", subdirectory: "Docs/Downloads") { NSWorkspace.shared.open(url) }
}
