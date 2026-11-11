# 搞门户 V1.18 沉静工作台 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在不改变网站、账号、下载、邮件和钥匙串数据的前提下，统一优化全部可见界面，彻底移除自动快照与升级备份，并交付 V1.18。

**Architecture:** 主窗口继续使用现有 HTML/CSS/JavaScript 与原生消息桥，原生模块继续使用 SwiftUI/AppKit。新增轻量共享 SwiftUI 视觉规范，数据模型和业务流程不改；手动资料 ZIP 仅保留 `library.json` 与 `manifest.json`，安装改为核验候选后直接替换，不创建任何备份。

**Tech Stack:** Swift 5、SwiftUI、AppKit、WebKit、HTML/CSS/JavaScript、Python 3、zsh、Node.js、GitHub CLI。

## Global Constraints

- 版本仅为 V1.18/build 118，重复构建不再次递增。
- Bundle ID 固定 `cn.mendao.launcher`，桥接标识固定 `cn.mendao.bridge`。
- 签名身份固定 `A15B2B2D22B018CBC842063C9A8A589946647524`，Team 固定 `5G96498KGJ`，不得降级 ad-hoc。
- 所有 `.app` 在生成前必须位于 `.noindex` 容器；正式入口仅为 `/Applications/搞门户.app`。
- 不创建自动快照、升级备份、旧程序回滚副本或验证备份；失败时停止并报告。
- 不删除 `library.json`、初始化证据、下载、邮件、附件、设置、网站图标或钥匙串；不上传任何用户数据。
- 不使用子代理；测试窗口随用随关；不发送真实邮件，不自动打开真实网站。

---

### Task 1: 移除自动快照并简化手动资料包

**Files:**
- Modify: `Sources/LibraryOperations.swift`
- Modify: `Sources/Models.swift`
- Modify: `Sources/Features.swift`
- Modify: `Sources/FullBackup.swift`
- Modify: `Sources/NativeSettings.swift`
- Delete: `Sources/BackupRestore.swift`
- Modify: `Resources/app.js`
- Modify: `Resources/features.js`
- Modify: `Tests/LibraryOperationsTests.swift`
- Modify: `Tests/NativeFeatureTests.swift`
- Modify: `Tests/FullBackupTests.swift`
- Modify: `Tests/BackupRestoreTests.swift`
- Modify: `Tests/UI.js`
- Modify: `Scripts/build.sh`
- Modify: `Scripts/test.sh`

**Interfaces:**
- Consumes: 现有 `LibraryOperations.restore(_:into:)`、`LibraryStore.save(_:)` 和 `FullBackup.read(_:currentVersion:)`。
- Produces: `FullBackup.Payload(manifest:library:)`、`FullBackup.export(library:version:destination:)`；不再产生 `checkpoint`、`snapshots`、`previewSnapshot` 或 `installBackup`。

- [ ] **Step 1: 先把测试改为无快照预期并确认失败**

在 `Tests/NativeFeatureTests.swift` 用以下检查替换快照计数：

```swift
check("batchKeepsInMemoryUndo", library.tiles.last?.children == ["seed-0", "seed-1"])
check("noSnapshotDirectoryCreated", !FileManager.default.fileExists(atPath: store.directory.appendingPathComponent("Snapshots").path))
```

在 `Tests/UI.js` 用以下检查替换 `native('snapshots')`：

```js
check('snapshotRouteRemoved',!$('settingsButton').textContent.includes('快照'));
await window.mendaoUndo();
check('undoStillAvailableWithoutSnapshots',!S.library.tiles.some(t=>t.name==='批量测试'));
```

在 `Tests/FullBackupTests.swift` 将导出调用改为：

```swift
let result = try FullBackup.export(library: library, version: "1.18", destination: destination)
let decoded = try FullBackup.read(destination, currentVersion: "1.18")
check("round trip contains only current library", decoded.library == library)
check("manifest contains library only", result.fileCount == 2 && decoded.manifest.files.keys.sorted() == ["library.json"])
```

运行 `./Scripts/test.sh`，预期因旧快照 API 仍存在或新导出签名不存在而失败。

- [ ] **Step 2: 删除快照写入、读取和前端入口**

从 `LibraryOperations.swift` 删除 `LibrarySnapshot`、`SnapshotEnvelope` 和整个快照扩展；从 `Models.swift` 删除 `transientSnapshots`。在 `Features.swift` 删除 `snapshots`/`previewSnapshot` 分支，并将所有：

```swift
_ = try store.checkpoint(library, reason: reason)
```

替换为直接调用现有 `try store.save(next)` 的写入流程。`applyLibraryChange` 成功回复改为：

```swift
reply(responseID, ["ok": true, "state": state(), "message": "已完成。"])
```

`undoOrganization` 的状态冲突文案改为：

```swift
throw AppError.message("网站数据已发生其他变化，请撤销最近的其他整理或手动调整排列。")
```

在 `Resources/app.js` 的路由中删除 `snapshots`；在 `Resources/features.js` 删除 `showSnapshots()`，并把预览说明改为“确认预览后再应用，不会创建自动快照。”

- [ ] **Step 3: 将 ZIP 限定为当前资料**

将 `FullBackup.Payload` 和导出接口改为：

```swift
struct Payload {
    let manifest: Manifest
    let library: Library
}

@discardableResult
static func export(library: Library, version: String, destination: URL) throws -> Summary {
    guard validVersion(version), destination.isFileURL else { throw failure("导出参数无效。") }
    _ = try library.validated()
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    var files = ["library.json": try encoder.encode(library)]
    try validateSizes(files)
    let manifest = Manifest(appID: appID, format: 2, version: version,
                            createdAt: Date().timeIntervalSince1970, files: files.mapValues(digest))
    files["manifest.json"] = try encoder.encode(manifest)
    let archive = try makeZIP(files)
    _ = try decode(archive, currentVersion: version)
    try writeAtomically(archive, to: destination)
    return Summary(fileCount: 2, totalBytes: Int64(files.values.reduce(0) { $0 + $1.count }),
                   zipBytes: Int64(archive.count), snapshotCount: 0)
}
```

`allowedPath` 只接受：

```swift
private static func allowedPath(_ path: String) -> Bool {
    path == "manifest.json" || path == "library.json"
}
```

`decode` 要求 `manifest.format == 2`、文件数恰好为 2，返回 `Payload(manifest: manifest, library: library)`。ZIP 条目总数上限改为 2。`NativeSettings.swift` 导出改为 `FullBackup.export(library:version:destination:)`；恢复先计算 `LibraryOperations.restore(payload.library, into: current)`，确认后执行 `try store.save(restored)` 并更新 `library`，不调用已删除的 `installBackup`。删除 `BackupRestore.swift` 及构建编译项。

- [ ] **Step 4: 更新资料测试并通过**

将 `BackupRestoreTests.swift` 精简为“当前资料恢复保留本机账号绑定、归档额外网站、原子保存、不创建 Snapshots”的测试；删除所有快照历史、快照符号链接和回滚副本断言。`FullBackupTests.swift` 保留 ZIP 安全测试，但把 `Snapshots/...` 路径全部列入拒绝项，不再构造快照。

运行：

```bash
./Scripts/test.sh
```

预期所有保留测试通过，且测试临时目录没有 `Snapshots`。

- [ ] **Step 5: 提交**

```bash
git add Sources Resources Tests Scripts/build.sh Scripts/test.sh
git commit -m "Remove automatic snapshots from portal data flows"
```

---

### Task 2: 用无备份安装器替换升级备份系统

**Files:**
- Create: `Scripts/install.py`
- Modify: `Scripts/install.sh`
- Modify: `Scripts/build.sh`
- Delete: `Scripts/backup_verify.py`
- Delete: `Scripts/app_macl_observation.py`
- Delete: `Tests/AppMaclObservationTests.py`
- Delete: `Tests/ApplicationRegistrationTests.py`
- Delete: `Tests/BackupAcceptedAccountsTests.py`
- Delete: `Tests/ProgramOriginalSafetyTests.py`
- Modify: `Tests/DownloadAcceptanceTests.py`
- Create: `Tests/InstallPolicyTests.py`
- Modify: `Scripts/test.sh`

**Interfaces:**
- Consumes: `Release/GaoMenHu-1.18.dmg` 与同名 SHA-256 文件。
- Produces: `validate_build_destination(path: Path) -> Path`、`install(no_open: bool = False) -> Path`；安装器不提供 snapshot、verify、rollback 或 finalize 命令。

- [ ] **Step 1: 编写无备份策略测试并确认失败**

`Tests/InstallPolicyTests.py` 使用 `runpy.run_path` 加载 `Scripts/install.py`，在 `/private/tmp` 的 `.noindex` 临时目录检查：

```python
candidate = loaded["validate_build_destination"](outer / "Candidate.noindex" / "搞门户.app")
check(candidate.name == "搞门户.app", "valid noindex destination accepted")
rejects(lambda: loaded["validate_build_destination"](outer / "搞门户.app"), "indexable destination rejected")
source = (ROOT / "Scripts/install.py").read_text()
check("PreviousApplications" not in source and "snapshot(" not in source and "rollback" not in source,
      "installer has no backup or rollback path")
check('APP_ID = "cn.mendao.launcher"' in source and 'Path("/Applications/搞门户.app")' in source,
      "installer identity and formal path are exact")
```

首次运行预期 `Scripts/install.py` 不存在。

- [ ] **Step 2: 实现候选核验和直接安装**

`install.py` 仅使用标准库，核心实现为：

```python
APP_ID = "cn.mendao.launcher"
FORMAL_APP = Path("/Applications/搞门户.app")
LEGACY_APP = Path("/Applications/门道.app")
TEAM = "5G96498KGJ"

def validate_build_destination(path):
    path = Path(path).expanduser().resolve(strict=False)
    require(path.name.endswith(".app"), "测试构建目标必须是 .app。")
    require(any(parent.name.endswith(".noindex") for parent in path.parents),
            "测试构建目标必须位于 .noindex 容器。")
    return path

def app_info(path):
    with (path / "Contents/Info.plist").open("rb") as stream:
        return plistlib.load(stream)
```

`install()` 在 `/Applications/.GaoMenHu-install-<uuid>.noindex` 创建暂存目录，先校验 DMG 的 SHA-256，再用 `hdiutil attach -nobrowse -readonly -mountpoint <临时挂载点>` 挂载。对候选检查 `CFBundleIdentifier == APP_ID`、版本与 `VERSION` 一致、build 为 118、`codesign --verify --strict` 成功且 Team 正确。使用 `ditto` 复制到 `.noindex` 暂存并再次核验；只有候选全部通过后才退出本 App 进程、删除身份匹配的旧 `门道.app` 和正式旧 App、将暂存 App 移到正式路径。任一步失败均抛出错误，不创建备份、不自动回滚。`finally` 只卸载本轮镜像并删除不含 App 的本轮临时目录。

- [ ] **Step 3: 接线构建与测试，删除旧备份实现**

`install.sh` 改为：

```zsh
#!/bin/zsh
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 "$PROJECT_DIR/Scripts/install.py" "$@"
```

`build.sh --app-only` 改从 `Scripts/install.py` 导入 `validate_build_destination`，编译源列表加入后续 `Sources/PortalTheme.swift`，删除 `BackupRestore.swift`。`Scripts/test.sh` 用 `python3 Tests/InstallPolicyTests.py` 替换 `backup_verify.py self-test`。

`DownloadAcceptanceTests.py` 仅保留纯比较器测试；物理验证属于已移除的备份验收系统，随安装器测试一起删除，不影响生产下载代码。删除本任务列出的旧备份脚本与测试。

- [ ] **Step 4: 运行无备份策略与全量测试**

```bash
python3 Tests/InstallPolicyTests.py
./Scripts/test.sh
```

预期安装策略测试和其余测试通过；`Grep` 检查 `Scripts` 不再存在 `snapshot(`、`PreviousApplications`、`rollingBack`。

- [ ] **Step 5: 提交**

```bash
git add Scripts Tests
git commit -m "Replace upgrade backups with verified direct installation"
```

---

### Task 3: 重设计主启动台、场景、账号库和网页弹窗

**Files:**
- Modify: `Resources/index.html`
- Modify: `Resources/style.css`
- Modify: `Resources/app.js`
- Modify: `Resources/features.js`
- Modify: `Tests/UI.js`

**Interfaces:**
- Consumes: 现有 `S.library`、`selectSection(section)`、`render()` 和全部原生动作。
- Produces: `.sidebar` 宽 216 px、`.workspace-grid`、`.vault-grid`、`.launcher-surface`；所有既有 DOM id 和原生动作名保持不变。

- [ ] **Step 1: 更新界面结构断言并确认失败**

`Tests/UI.js` 将旧系列样式断言替换为：

```js
check('quietSidebarWidth',Math.round(document.querySelector('.sidebar').getBoundingClientRect().width)===216);
check('openLauncherSurface',document.querySelector('.launcher-surface')!==null&&getComputedStyle(document.querySelector('.launcher-surface')).backgroundColor==='rgba(0, 0, 0, 0)');
check('workspaceResponsiveGrid',getComputedStyle(document.querySelector('.workspace-grid')).display==='grid');
check('vaultResponsiveGrid',getComputedStyle(document.querySelector('.vault-grid')).display==='grid');
check('noSnapshotCopy',!document.body.textContent.includes('本地自动快照'));
```

运行界面测试，预期因旧 236 px 侧栏和缺少新容器而失败。

- [ ] **Step 2: 调整语义结构**

`index.html` 将品牌副标题改为“你的数字入口”，把 `launcher-card` 改为 `launcher-surface`，保留内部所有 id。启动台工具区使用：

```html
<div class="launcher-tools">
  <div class="search-wrap"><span id="searchSymbol"></span><input id="search" type="search" autocomplete="off" placeholder="搜索网站、拼音、简称或网址" aria-label="搜索网站"><kbd>⌘ F</kbd></div>
  <div class="toolbar-actions"><button class="tool-button" id="undoButton" title="撤销上次整理（⌘ Z）" disabled>↶ 撤销</button><button class="tool-button" id="manageButton">整理</button></div>
</div>
```

`app.js` 的 `renderSection()` 用 `<div class="workspace-grid">…</div>` 和 `<div class="vault-grid">…</div>` 包裹现有卡片；`selectSection` 的启动台副标题改为“把常用的地方，放在最顺手的位置。”不修改点击、拖动、分页或消息桥逻辑。

- [ ] **Step 3: 实现沉静工作台样式**

重写 `style.css` 的语义变量，浅色使用 `#f6f4ef` 画布、`#eae7e0` 侧栏、`#635bdf` 强调色、`#24232a` 文字；深色使用 `#17171c`、`#202027`、`#aaa4ff`、`#f2f0eb`。侧栏 216 px，主标题 28 pt，搜索框 44 px，启动台背景透明；图标保留三档尺寸并增加悬浮阴影。关键规则为：

```css
.sidebar{width:216px;flex-basis:216px;background:var(--sidebar);border-right:1px solid var(--line)}
.nav-item{min-height:40px;border-radius:12px;padding:0 12px}
.nav-item.selected{background:linear-gradient(135deg,var(--accent),var(--accent-deep));box-shadow:0 8px 20px var(--accent-shadow)}
.launcher-surface{flex:1;min-height:0;display:flex;flex-direction:column;background:transparent}
.workspace-grid,.vault-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:18px;align-items:start}
@media(max-width:900px){.workspace-grid,.vault-grid{grid-template-columns:1fr}}
```

其余规则完整覆盖表单、对话框、文件夹、分页、多选栏、提示条、深色、窄窗口、低高度窗口和减少动态效果；禁止出现未闭合规则或覆盖 `[hidden]`。

- [ ] **Step 4: 运行网页语法和界面测试**

```bash
node --check Resources/app.js
node --check Resources/features.js
./Scripts/test.sh
```

后续隔离 UI 自检应显示全部检查 `true`；重点验证长名称、双列转单列、拖动的原始 DOM 保留、分页、深色和弹窗焦点。

- [ ] **Step 5: 提交**

```bash
git add Resources Tests/UI.js
git commit -m "Redesign portal launcher as a calm workspace"
```

---

### Task 4: 统一下载、邮件、设置与悬浮窗视觉

**Files:**
- Create: `Sources/PortalTheme.swift`
- Modify: `Sources/Downloads/DownloadViews.swift`
- Modify: `Sources/Downloads/DownloadSettingsView.swift`
- Modify: `Sources/Mail/MailSeriesUI.swift`
- Modify: `Sources/Mail/MailViews.swift`
- Modify: `Sources/Mail/MailEditors.swift`
- Modify: `Sources/Mail/MailAddAccountView.swift`
- Modify: `Sources/Mail/MailSettingsView.swift`
- Modify: `Sources/Mail/MailFloatingView.swift`
- Modify: `Sources/NativeSettings.swift`
- Modify: `Sources/FloatingLauncher.swift`
- Modify: `Tests/UITesting.swift`
- Modify: `Scripts/build.sh`

**Interfaces:**
- Consumes: 现有 SwiftUI/AppKit 视图与状态对象。
- Produces: `PortalTheme.accent`、`PortalTheme.canvas`、`PortalTheme.panel`、`PortalTheme.quietCard` 和 `PortalStatusBadge`；不改变任何 Store 或 Coordinator 接口。

- [ ] **Step 1: 增加原生主题结构检查并确认失败**

在 `Tests/UITesting.swift` 增加：

```swift
settingsChecks["sharedPortalThemeCompiled"] = PortalTheme.accent != .clear
settingsChecks["settingsUsesCalmWidth"] = settingsWindow?.contentView?.frame.width == 820
```

首次编译预期 `PortalTheme` 不存在。

- [ ] **Step 2: 创建共享视觉规范**

`PortalTheme.swift` 定义：

```swift
import SwiftUI
import AppKit

enum PortalTheme {
    static let accent = Color(red: 0.39, green: 0.36, blue: 0.87)
    static let canvas = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.09, green: 0.09, blue: 0.11, alpha: 1)
            : NSColor(calibratedRed: 0.965, green: 0.957, blue: 0.937, alpha: 1)
    })
    static let panel = Color(nsColor: .controlBackgroundColor)
}

struct PortalStatusBadge: View {
    let title: String
    var tint: Color = PortalTheme.accent
    var body: some View {
        Text(title).font(.caption.weight(.medium)).padding(.horizontal, 9).padding(.vertical, 4)
            .foregroundStyle(tint).background(tint.opacity(0.11), in: Capsule())
    }
}
```

增加 `View.portalCard()` 修饰器：20 pt 内边距、16 pt 连续圆角、`panel` 背景和 7% 主色边框。构建脚本将其加入主程序编译。

- [ ] **Step 3: 应用主题但不改业务操作**

下载侧栏 ideal width 改为 216，标题区增加状态胶囊，任务行使用 12 pt 圆角选中背景和统一进度色。邮件 `MailSidebarRow.accent` 默认改为 `PortalTheme.accent`，侧栏宽 216，搜索框与卡片调用 `portalCard()`，全局 `.tint(.indigo)` 改为 `.tint(PortalTheme.accent)`。设置窗口继续使用 820×740 和现有 TabView，但 `.tint` 改用共享色，数据页只显示“导出当前资料”“从资料恢复”“导出 JSON”“导入 JSON”和数据目录，不显示快照。

`FloatingLauncher.swift` 保持 20×104 收起尺寸与全部几何测试，仅将圆角改为 18、强调色改为 `NSColor(calibratedRed:0.39,green:0.36,blue:0.87,alpha:1)`，搜索与列表间距统一为 12/10 pt。不得修改自动隐藏计时和拖动逻辑。

- [ ] **Step 4: 编译并运行原生自检**

```bash
./Scripts/test.sh
./Scripts/build.sh --app-only /private/tmp/GaoMenHu-UI.noindex/搞门户.app
```

预期编译成功；隔离自检中设置、悬浮窗几何、下载和邮件既有检查全部通过。用测试实例截图检查主窗口、下载、邮件和设置的浅色/深色，不用真实账号或网站。

- [ ] **Step 5: 提交**

```bash
git add Sources Tests/UITesting.swift Scripts/build.sh
git commit -m "Unify native portal views with shared visual theme"
```

---

### Task 5: V1.18 文档、构建和回归验证

**Files:**
- Modify: `VERSION`
- Modify: `BrowserExtension/manifest.json`
- Modify: `Resources/GaoCapabilities.json`
- Modify: `README.md`
- Modify: `使用说明.txt`
- Modify: `Docs/InstallRecovery.md`
- Modify: `Docs/恢复保护与下载回送.md`
- Delete: `Docs/AppMetadataObservation.md`
- Delete: `Docs/DownloadAcceptance.md`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: 已完成的 V1.18 源码。
- Produces: `Release/GaoMenHu-1.18.dmg` 与 `Release/GaoMenHu-1.18.dmg.sha256`。

- [ ] **Step 1: 只递增一次版本**

```bash
python3 Scripts/bump_version.py
```

预期输出 `搞门户 V1.17 → V1.18`，`VERSION` 为 `1.18`，扩展版本为 `1.18.0`，能力清单 `appVersion` 为 `1.18`。

- [ ] **Step 2: 更新公开说明**

README 和使用说明删除自动快照、升级备份、回滚副本的描述，改为“应用不创建自动快照或升级备份；手动导出仅包含当前网站资料”。新增 V1.18 条目，说明沉静工作台界面和备份移除。安装文档说明候选核验后才替换，失败停止且不生成备份。不得写入真实路径中的用户文件内容或账号信息。

- [ ] **Step 3: 全量测试和正式构建**

```bash
./Scripts/test.sh
./Scripts/build.sh
```

预期 `Release/GaoMenHu-1.18.dmg` 生成，两个 Mach-O 均为 Team `5G96498KGJ`，DR 不含 cdhash，版本 1.18/build 118。若签名身份不可用，停止，不降级。

- [ ] **Step 4: 检查发行内容与仓库**

```bash
shasum -a 256 -c Release/GaoMenHu-1.18.dmg.sha256
git diff --check
git status --short
```

预期校验通过、无空白错误；暂存前逐文件审查，不包含 `用户数据备份`、验证结果、真实资料或凭据。

- [ ] **Step 5: 提交**

```bash
git add VERSION BrowserExtension/manifest.json Resources/GaoCapabilities.json README.md 使用说明.txt Docs .gitignore
git commit -m "Release GaoMenHu V1.18"
```

---

### Task 6: 隔离验收、真实资料核验、安装清理与发布

**Files:**
- Create temporarily and delete before delivery: `/private/tmp/GaoMenHu-UI.noindex/`
- Modify locally only, never commit: `/Applications/搞门户.app`
- Retain: `Release/GaoMenHu-1.18.dmg` and `.sha256`
- Delete: older Release files, `TestResults/`, `用户数据备份/`, build staging and verified automatic `Snapshots`

**Interfaces:**
- Consumes: 已签名 V1.18 DMG 和无备份安装器。
- Produces: 唯一正式安装入口、GitHub `main`、tag `v1.18` 和对应 Release。

- [ ] **Step 1: 使用虚构资料验收全部界面**

构建隔离测试 App，运行现有 `--self-test`，导出主界面和悬浮窗截图。打开隔离下载、邮件和设置窗口，检查浅色/深色、窄窗口、空状态、长文本、按钮与状态标签。每完成一个窗口立即关闭，不访问真实网站、邮箱或下载目录。

- [ ] **Step 2: 核验真实资料但不建立备份**

只读取文件类型、大小和 SHA-256 清单，不输出内容。记录 `~/Library/Application Support/MenDao` 下现用文件，单独识别 `Snapshots`；确认 `library.json`、初始化证据、DownloadCenter、MailCenter 和附件可读取且非空时不视为空数据。删除仅限 `Snapshots` 自动快照及项目内明确备份目录，不触碰其他文件。若真实目录身份不明或无法读取，停止安装。

- [ ] **Step 3: 卸载旧版并安装新版**

```bash
./Scripts/install.sh --no-open
open -a "/Applications/搞门户.app"
```

安装器先核验候选再替换；不生成升级备份。启动后核验 V1.18/build 118、网站数量、工作场景、账号元数据、下载和邮件数据库文件与安装前一致，钥匙串服务名不变。测试窗口用完立即关闭。

- [ ] **Step 4: 唯一入口和清理**

在真实用户会话运行 Spotlight 与 LaunchServices 查询，记录所有 `cn.mendao.launcher` 结果。只注销并删除已查明属于本 App 的旧构建、旧 `门道.app`、暂存和镜像副本，不全局重置。最终有效结果必须只包含 `/Applications/搞门户.app`。卸载 DMG，删除旧 Release、TestResults、临时 App、模块缓存和中间构建，保留 V1.18 DMG 与校验文件。

- [ ] **Step 5: 推送源码和 Release**

```bash
git push origin main
git tag -a v1.18 -m "GaoMenHu V1.18"
git push origin v1.18
gh release create v1.18 Release/GaoMenHu-1.18.dmg Release/GaoMenHu-1.18.dmg.sha256 \
  --title "搞门户 V1.18" --notes "沉静工作台全界面优化；移除自动快照与升级备份。"
gh release list
```

随后仅删除本仓库旧 Release 和旧标签，确认最新 Release 附件可下载且 SHA-256 匹配。最终 `git status --short` 干净，GitHub 不含用户数据。
