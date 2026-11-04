import SwiftUI
import AppKit

struct DownloadSettingsView: View {
    @ObservedObject var coordinator: PortalDownloadCoordinator
    @ObservedObject var manager: DownloadManager
    @ObservedObject var exchange: DownloadGaoExchange
    @State private var settings = DownloadSettings()
    var body: some View {
        TabView {
            Form {
                Section("下载与资源") {
                    Picker("同时下载", selection: $settings.concurrency) { ForEach(1...2, id: \.self) { Text("\($0) 个任务").tag($0) } }
                    Text("同一主机最多 1 条连接；每个条目使用单连接。") .font(.caption).foregroundStyle(.secondary)
                    Picker("总下载限速", selection: $settings.speedLimitBytesPerSecond) {
                        Text("不限速").tag(Int64(0))
                        Text("256 KB/s").tag(Int64(256 * 1024))
                        Text("1 MB/s").tag(Int64(1024 * 1024))
                        Text("5 MB/s").tag(Int64(5 * 1024 * 1024))
                        Text("20 MB/s").tag(Int64(20 * 1024 * 1024))
                    }
                    Picker("单文件上限", selection: $settings.maxItemBytes) {
                        ForEach([1, 5, 20, 50, 100], id: \.self) { Text("\($0) GiB").tag(Int64($0) * 1024 * 1024 * 1024) }
                    }
                    Picker("临时空间总预算", selection: $settings.maxStagingBytes) {
                        ForEach([5, 20, 40, 100, 200], id: \.self) { Text("\($0) GiB").tag(Int64($0) * 1024 * 1024 * 1024) }
                    }
                }
                Section("运行方式") {
                    Text("应用运行时传输。退出会安全暂停；睡眠或断网会中断传输，恢复后核验资源版本。重新启动应用后由你恢复任务。")
                    Text("本版不提供预约、登录自启、常驻守护进程或媒体解析工具。") .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).tabItem { Label("下载", systemImage: "arrow.down.circle") }
            Form {
                Picker("外观", selection: $settings.appearance) {
                    Text("跟随系统").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark")
                }.pickerStyle(.radioGroup)
                Text("使用系统字体、键盘操作与原生控件。") .foregroundStyle(.secondary).font(.caption)
            }.formStyle(.grouped).tabItem { Label("外观", systemImage: "circle.lefthalf.filled") }
            Form {
                Section("本机资料") {
                    LabeledContent("资料格式", value: "schemaVersion 1")
                    Text("任务、目录书签、设置与跨应用账本保存在本应用的私有资料目录。下载文件保留在你选择的位置。") .font(.callout)
                    Button("在 Finder 中显示资料目录") {
                        NSWorkspace.shared.open(manager.dataRootURL)
                    }
                    Button("查看备份与恢复说明") { showBundledGuide("Recovery") }
                    Button("查看资料格式与预算") { showBundledGuide("DataFormat") }
                }
                Section("资料保护") {
                    Text("资料损坏、缺失或版本过新时停止写入，不创建空白库覆盖。恢复前保留现有资料，并按恢复说明核验备份。") .font(.callout)
                    Text("清理任务历史不会删除已发布文件。清理临时数据只处理任务清单记录的自有文件。") .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).tabItem { Label("数据", systemImage: "externaldrive") }
            VStack(spacing: 16) {
                if let icon = NSImage(named: NSImage.Name("AppIcon")) { Image(nsImage: icon).resizable().frame(width: 88, height: 88) }
                Text("搞门户 · 内置下载").font(.title2.weight(.semibold))
                Text("V\(portalDownloadVersion) · 构建 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1")").foregroundStyle(.secondary)
                Text("可控、可恢复、可解释的文件下载").font(.callout)
                Text("HTTP / HTTPS 直链 · SHA-256 · 原子落盘") .font(.caption).foregroundStyle(.secondary)
                Button("功能边界与验证说明") { showBundledGuide("Validation") }
                Text("开发签名 · 未经 Apple 公证") .font(.caption).foregroundStyle(.secondary)
                Link("源码与发行版本", destination: URL(string: "https://github.com/UCASerYff/GaoMenHu")!)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(30).tabItem { Label("关于", systemImage: "info.circle") }
        }
        .frame(width: 610, height: 510)
        .disabled(coordinator.shuttingDown)
        .preferredColorScheme(settings.appearance == "dark" ? .dark : settings.appearance == "light" ? .light : nil)
        .onAppear { settings = manager.settings }
        .onChange(of: settings) { value in manager.updateSettings(value) }
    }
}
