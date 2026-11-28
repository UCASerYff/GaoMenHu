# 搞门户 V1.20

macOS 网站启动器，内置文件下载与原生邮件。把常用网站像 App 一样放进启动台，拖动排序、组合文件夹，并为每个网站指定浏览器和登录账号。

<p align="center"><img src="Assets/AppIcon.png" width="180" alt="搞门户图标"></p>

## 下载与安装

从 [Releases](https://github.com/UCASerYff/GaoMenHu/releases/latest) 下载 `GaoMenHu-1.20.dmg` 和同名 `.sha256` 文件。仓库保存源码，安装包作为 Release 附件单独发布。

1. 支持 macOS 14 或更高版本、Apple Silicon；当前未提供 Intel 版本。
2. 打开 DMG，把 `搞门户.app` 拖入“应用程序”文件夹，然后启动。
3. 安装包采用 Apple Development 稳定开发签名，未经过 Apple 公证。macOS 可能提示无法验证开发者，请先确认下载来源和校验和。
4. 需要浏览器自动填充时，按下方说明在 Chrome 或 Edge 加载助手。

校验下载文件：

```sh
shasum -a 256 -c GaoMenHu-1.20.dmg.sha256
```

## 功能

- 网站以 Launchpad 风格排列，支持拖动排序、组合文件夹、移入移出与文件夹重命名。
- 每个网站至少指定一个允许的浏览器；默认浏览器必须属于允许列表，不会自动改用未允许的浏览器。
- 支持 Chrome、Edge、Safari、Firefox 启动；Chrome、Edge 助手支持账号自动填充。
- 原生悬浮窗：左右贴边时收起为细条，悬停或点击展开，移出后自动收起；左侧、右侧和自由浮动均收起为竖线，顶部只保留拖动区。优先显示最近使用的 3 个网站，再按使用次数补充常用网站，最多 8 个且不重复；没有记录时沿用启动台顺序。界面不显示软件图标、名称、标题或版本，搜索整个启动台，右键指定允许的浏览器。
- 名称、网址、中文拼音、拼音首字母和自定义简称搜索；方向键选中结果，回车打开。
- 双指横向翻页，以及页码、按钮和键盘翻页；拖到左右边缘可跨页整理。
- 紧凑／宽松布局、三档图标大小、高清站点图标和本地图片裁剪。
- 多选整理、批量移动与浏览器设置、布局撤销。
- 导入 Chrome / Edge 收藏栏；通过浏览器助手收藏当前网页。
- 工作场景可一次打开多个网站，各自使用指定浏览器和账号。
- 沉静工作台视觉：悬浮侧栏、开放启动台与紫蓝渐变，工作场景和账号库响应式排列，支持系统／浅色／深色外观。
- 网站资料 ZIP 导出与校验恢复、JSON 模块导出、合并导入与恢复预览；不创建自动备份或升级回滚副本。
- 支持 GaoAction V1 跨 App 动作交接与目录包（.gaoaction），可由支持该契约的应用调用已有网站、工作场景、聚焦搜索与建议新站；支持交接包手动打开、结果查看与最小授权目录安全导出。
- 网站右键“在下载中心复核…”在本应用内复核网址和保存目录，再管理真实文件队列；不依赖独立搞下载。外部调用使用 `cn.mendao.launcher` 的 `downloads.prepare`。
- 原生邮件支持收件箱、身份、关联平台、草稿及附件、OAuth、验证码与别名助手；首次仅显示缓存，明确连接后才收发。

### 启动台与悬浮窗

- 将网站拖到另一个网站中央并等待片刻，可新建文件夹。拖进现有文件夹可归类，在文件夹内点名称重命名，将网站拖到“移回首页”区域可移出。
- 在“设置 → 模块设置 → 启动台”调整紧凑度与图标大小。使用多选整理后，可按 ⌘Z 撤销布局、入口移除和批量默认浏览器修改。
- 按 ⌃⌥Space 聚焦站点搜索，按 ⌃⌘P 切换悬浮窗，按 Esc 收起。拖动细线或展开面板的边缘可调整位置，靠近屏幕边缘时吸附。

## 浏览器助手

先启动安装好的 App，再打开 `chrome://extensions/` 或 `edge://extensions/`，开启开发者模式，选择“加载已解压的扩展程序”，加载：

```text
/Applications/搞门户.app/Contents/Resources/BrowserExtension
```

助手名称为“搞门户助手”。每个浏览器个人资料需要单独加载；连接多个资料时，在网站编辑页指定所需资料。升级或从旧名称迁移后，请在扩展管理页对助手点击“重新加载”，确保后台脚本已更新。

扩展使用 `nativeMessaging`、`tabs`、`storage`、`alarms` 与 HTTPS 网页权限，不申请 Cookie 或浏览器密码库权限。固定公钥用于保持扩展 ID；公钥不是私钥或登录凭据。

## 用户数据与隐私

源码和安装包不包含个人收藏、账户记录、密码、浏览器资料、Cookie、个人文件或用户备份。首次运行只生成不含账号的公共网站示例；下载本仓库不能恢复任何人的个人资料。

- 网站布局和账号元数据保存在 `~/Library/Application Support/MenDao/library.json`。
- 密码保存在 macOS 钥匙串，不放入源码、普通备份、日志、网址或剪贴板。
- 不生成网站自动快照、下载上一份库或邮件恢复前副本；手动导入导出由用户明确执行。
- 自动填充须先通过 Mac 身份验证，仅针对从本应用启动、精确授权的 HTTPS 页面；登录提交、验证码和二次验证由用户完成。
- 图标请求可能访问站点首页及其图标资源，不携带收藏网址中的查询参数、登录凭据或 Cookie。
- 悬浮窗位置、显示开关与网站使用次数、最近打开时间仅保存在本机偏好中，不包含在网站资料备份里；不会生成小组件。使用统计从 V1.09 开始，只记录从搞门户成功打开的网站，不读取浏览器历史。
- 日常模式不清除浏览器自身的密码或 Cookie。

应用原名“门道”。为兼容原有收藏和钥匙串，内部应用标识、通信标识及 `MenDao` 数据目录保持不变。

## 从源码构建

需要 Apple Silicon Mac、Xcode Command Line Tools、Python 3；运行测试另需 Node.js。正式应用没有第三方运行时依赖。

正式构建脚本固定发布者的开发签名身份；自行构建前请配置本人可用的签名身份和 Team。仓库不包含私钥或公证凭据。

```sh
./Scripts/test.sh
./Scripts/build.sh
./Scripts/install.sh
```

构建、镜像展开与安装暂存均在创建 App 前进入 `.noindex` 容器，临时构建结束后清理；DMG 自带不索引标记。`--app-only` 的目标也必须具有 `.noindex` 祖先。`Release/` 保存当前 DMG、校验文件和本地验证记录，不提交到 Git。

安装脚本核验发行包摘要、应用标识和签名后替换正式安装路径，保留现用用户数据，不生成升级备份或旧程序回滚副本。失败时停止并报告。正式交付仍须核对 Spotlight 与 LaunchServices 的有效结果都只指向 `/Applications/搞门户.app`；查询失败或空结果不代表通过。

- `Sources/`：Swift 原生程序、数据模型、钥匙串、本地通信。
- `Resources/`：随 App 打包的启动台界面。
- `BrowserExtension/`：Chrome / Edge Manifest V3 助手。
- `Assets/`：应用图标母版和设计说明；ICNS 由构建脚本生成。
- `Scripts/`：构建、安装、版本递增和检查脚本。
- `Tests/`：模型、导入恢复、图标、通信与界面测试，使用虚构测试数据。

`Scripts/test.sh` 执行命令行单元检查，包含主库/账本丢失与事务中断的新定向复现，不启动应用或浏览器。默认不自动运行冒烟测试；界面、浏览器及跨 App 冷启动验证只有用户明确要求后才运行，不能由隔离测试推断已通过。正式包不含 UI 自检资源。`Tests/Content.cjs` 的浏览器表单测试另需 Playwright 和 Chrome，也不属于默认检查。

在 Apple Silicon 验证机（例如 GitHub 托管的 `macos-15` arm64 runner）上，可运行以下命令。编译验证使用正式构建的架构、最低系统版本和优化参数，检查主程序、原生消息宿主、邮件 C 模块及 App 版本。产物留在临时容器，完成后自动清理。

```bash
set -euo pipefail
test "$(uname -m)" = arm64
./Scripts/build.sh --verify-compile
./Scripts/test.sh
bash Scripts/test-embedded-download-core.sh
bash Scripts/test-embedded-mail-core.sh
```

图标的可恢复源是已提交的 `Assets/AppIcon.png`、`Scripts/MakeIcon.swift` 和 `Scripts/make_icns.py`。构建从 PNG 母版生成临时 ICNS 后放入 App，不依赖未跟踪的 `Assets/AppIcon.icns`。`AGENTS.md`、用户资料、备份和本地验证记录均不公开提交。

参见[下载资料恢复](#下载资料恢复)和[下载资料与预算](#下载资料与预算)。缺失或中断状态不会通过新建空库、空账本或清除历史解除保护。

## 版本

发行版本以 `VERSION` 为准。macOS 构建号独立保存在 `BUILD`，用于 App 的 `CFBundleVersion` 和安装核验。递增发行版本时运行一次 `python3 Scripts/bump_version.py`，只更新 macOS 构建时递增 `BUILD` 即可。重复编译沿用同一构建号。当前源码版本为 V1.20，macOS 构建 121。

V1.20 的邮件中心默认打开缓存收件箱，提供全部、未读、星标和有附件筛选。搜索可以匹配已缓存的正文与附件名称。列表与阅读区会随窗口宽度调整，写信时显示本地草稿保存状态，并保留发送确认与防重复提交。参考了 MailX 的缓存优先和收件箱处理流程。 [MailX](https://github.com/GuqierMcl/MailX)

macOS 构建 120 增加 Chrome / Edge 资料连接诊断与修复入口，在菜单栏显示实际下载活动，并减少主窗隐藏和邮件贴边条收起时的刷新。

V1.19：补齐“窗口 → 关闭窗口”（Cmd+W），关闭当前下载、邮件或设置窗口；沿用已有下载后台队列和邮件草稿保存、发送保护。

V1.18：采用沉静工作台视觉，重排悬浮侧栏、开放启动台、工作场景、账号库、设置、下载、邮件与悬浮窗；完善浅色、深色和窄窗口布局。删除网站自动快照、下载上一份库、邮件恢复前副本及升级回滚备份，保留手动资料导入导出与现用数据、钥匙串绑定。

V1.17：内置下载队列和原生邮件，不再把下载流程交给独立程序；保留原网站、账号引用和钥匙串服务。加入同卷重新挂载后的显式原目录重授权、严格迁移与恢复保护，以及原生邮件的缓存优先、明确连接和发送退出保护。外部安装工具支持独立完整当前备份与精确业务变化验收，私有观察和授权事实不进入公开源码或安装包。

V1.16：接通网站右键的下载交接入口。通用动作账本恢复受限时，保留其阻断状态；独立下载账本按自身证据管理发送和回送，已知下载结果不再被通用账本误拦截。结果仍需匹配原请求并由用户确认，不把窗口打开或任务接受记为下载完成。构建、安装暂存及升级备份采用 `.noindex` 容器，验收后保留可核验的旧程序回滚副本。

V1.15：修复已有资料目录缺主库却被当作首次使用、账本遗失后重新接受旧 UUID 的问题。加入独立初始化证据、持久幂等水位、事务中断保护及明确恢复状态；有效旧主库和账本按原数据迁移，不生成默认空白替代品。补齐下载回送的请求关联、任务 ID 绑定、防重复、真实文件与摘要复核；只有用户确认后才接纳结果，不把打开窗口或任务接受当下载完成。无兼容下载提供方时保持明确不可用。图标直接从已提交母版重建，构建不依赖本地未跟踪资源。

V1.14：接入跨 App 动作交接契约 GaoAction V1，支持“搞操作”、“搞桌面”等兄弟应用通过 .gaoaction 目录包调用已有网站（portal.openSite）、工作场景（portal.openWorkspace）、聚焦搜索（portal.focusSearch）以及建议添加网站（portal.proposeSite）。严格限制外部动作参数，新增网站仅打开预填编辑界面由用户确认后写入，绝不静默改写数据库；密码与敏感凭据绝不导出或通过命令行传递。接入可选“搞下载”（com.gaoseries.GaoXiaZai）交接（portal.prepareDownload），支持用户选择网址隐私复核（可剔除查询参数与片段），未安装时优雅降级并允许复制干净网址。新增“数据”菜单下的交接包手动打开、结果查看与授权网站/场景最小目录安全导出。继承原有所有网站、布局快照与钥匙串密码。

V1.13：吸附改为拖动过程中实时判断，靠近左右边缘 32 pt 内贴边，移离边缘恢复自由移动，松手直接保存当前位置。取消隐藏竖线的左右内缩，停靠时只保留朝内的圆角；展开面板的顶部、两侧和底部空白处均可拖动，搜索、网站点击和滚动保持原操作。拖动期间暂停收起与列表重排，延续原资料、位置和使用记录。

V1.12：进一步压缩悬浮窗顶部留白，搜索框距顶部由 34 pt 减至 12 pt，保留顶部拖动区。整体高度减少 22 pt，列表和底部间距保持紧凑；保留 V1.11 的边界判断与快速收起逻辑。升级沿用原资料和使用统计。

V1.11：悬浮窗按实际窗口边界判定，移出约 0.15 秒收起，点击其他位置立即收起。移除展开保留时间和普通搜索宽限，拖动、右键菜单、中文组词与登录验证仍受到保护；收起后先移出入口再悬停，避免反复展开。高度随网站数量调整，最多显示 8 行，更多搜索结果滚动查看，压缩底部留白。沿用网站、账号、位置与使用记录。

V1.10：去掉悬浮窗顶部图钉、关闭及收起按钮，取消方块入口与自动隐藏开关。左侧、右侧、自由浮动统一收起为竖线，移出自动收起、悬停或点击展开；搜索输入使用短暂宽限，焦点残留不会永久阻止收起。保留网站排列、最近与高频统计及显示偏好。

V1.09：修复悬浮窗右上角 ❌ 直接关闭并禁用唤起入口的问题，现在会收回隐藏入口并保留显示开关。新增最近使用与高频常用排序；去掉悬浮窗内的软件图标、名称、标题和版本文字，自由浮动时收起为 48×48 pt 小入口。

V1.08：悬浮窗新增贴边隐藏形态，实际窗口缩为 20×104 pt，视觉为 6×88 pt 细条；悬停 0.45 秒展开，移出延迟收起，搜索、菜单与登录验证期间保护，支持图钉固定与左右／自由停靠。继续沿用原资料与位置偏好。

V1.07：新增可拖动、吸附及收起的原生悬浮窗，支持快捷启动、拼音搜索和允许浏览器菜单；菜单栏、显示菜单与原生设置提供开关及位置重置，升级保持原有网站资料和钥匙串绑定。

V1.06：应用图标改为黑底白字，主程序、应用内标志和浏览器助手同步更新；继承现有资料与钥匙串绑定。

V1.05：收细竖排图标字体，统一侧栏、主界面、原生设置与数据菜单；新增完整资料 ZIP 导出与恢复，保留安全快照和本机钥匙串绑定。

V1.04：产品更名为“搞门户”，主程序、浏览器助手和安装包同步更名，图标采用搞系列的白底竖排书法“门户”。

## V1.17 内置下载

下载中心接收普通 HTTP/HTTPS 文件直链，在搞门户内复核目录后管理队列、暂停、重试、取消和完整性。网站右键直接使用本应用服务，不依赖独立搞下载。`downloads.prepare` 的 canonical 目标为现有 `cn.mendao.launcher`，`mediaType` 仅 `file`。迁移与目录重授权参见 [下载恢复说明](#下载资料恢复)。原网站账号和钥匙串服务保持原路径与身份。

本版集成队列最低系统为 macOS 14。旧下载库只由显式协调迁移导入，已有历史和未完成片段保留，不自动重跑；不以首次初始化创建空队列覆盖原资料。媒体解析、浏览器会话借用和外接设备验收不在本版范围。

## V1.17 原生邮件

邮件模块保留 IMAP/SMTP、多账号和身份、关联平台、草稿、验证码提取、别名助手、正文及附件缓存与悬浮窗。邮件视图与设置使用独立原生窗口，邮箱资料不经过网站启动台的 JavaScript 接口。HTML 正文禁止脚本、远程图片、外部连接和表单提交。

首次打开和切换邮箱仅显示缓存。迁入账号须本人明确确认连接，之后才使用原钥匙串引用并联网；自动同步限于本次运行中已经连接成功的账号。Google / Microsoft 保留原有 PKCE、OIDC 校验与默认浏览器 loopback 回调，使用本人配置的客户端。邮件发送期间保留退出保护，编辑内容先存草稿。

邮件新数据根为 `~/Library/Application Support/MenDao/MailCenter/`。保留原服务 `com.gaoseries.GaoYouJian.credentials`，不导出密码或令牌，不把旧宿主权限视为已经自动转授。原资料仅通过显式迁移导入；邮件手动导出与网站资料导出分别处理，不创建自动备份。网页登录所需的客户端设置见[邮件授权配置](#邮件授权配置)。首次邮件悬浮窗与正文预览默认关闭。


## 下载资料恢复

搞门户的 HTTP/HTTPS 文件下载库由原搞下载迁入。迁移只由明确的协调流程执行，不在启动时自动取走旧数据。来源缺失但仍有初始化或历史依据时停写，不能导入空白；安装并不等于资料已迁入或已获原目录权限。

迁移持来源资料锁，逐项验证 schema、摘要和任务映射；目标提交有独立阶段证据。重复迁移不会覆盖目标后来新增的任务。迁入后任务不会自动开始，请在下载中心重新选择原保存目录，系统授权由本人操作。

目录身份相符后保留原 grant UUID，未完成片段和已发布文件仍须核验；手动恢复任务时再检查强 ETag 和片段摘要。没有可靠资源校验器或版本改变时会从零下载，旧正式文件不覆盖。完成历史不重新下载。

应用退出前停止调度、同步并记录断点；重新打开由你恢复。睡眠、断网与权限失效可能中断，不能承诺后台或关机继续。取消不会删除已发布原件。清理临时文件只允许任务清单、目录 FD 和身份核验一致的自有文件，不能清空用户下载目录。

恢复时保留现用资料，不拼接不同日期的库和独立证据。旧版 `downloads.previous.json` 只作为历史迁移可读格式，新版不生成，也不会自动回退到该文件。目录、资料、账本、附件、初始化或事务缺失、损坏、过新时维持保护；下载原件和钥匙串均不自动覆盖。

网站“完整资料”导出仅覆盖网站模块，不包含下载队列或邮件；当前版本不创建完整升级备份。凭据继续留在原钥匙串。

外接设备验收不做（用户取消），不能把未接入外接存储算通过。当前只使用本机目录和公开系统能力；不导入浏览器 Cookie，不绕过受限媒体或登录限制。

## 下载资料与预算

下载权威根为 `~/Library/Application Support/MenDao/DownloadCenter/`；网站收藏和账号仍使用原 `MenDao/library.json` 和原钥匙串服务。下载资料不会存入网站账号字段或浏览器 Cookie。

`downloads.json` 是 schemaVersion 1 的下载数据库，外层为 payload 的 Base64 与 SHA-256，内层保留 installationID、revision、migrationHistory、jobs、items、destinations 和 settings。旧版 `downloads.previous.json` 仅作为历史迁移可读格式，新版不生成，也不自动回退。独立初始化记录 `.DownloadCenter.initialized-v1.json` 位于 MenDao 下，丢失或与资料冲突时停写；不能创建空队列替代已有资料。

每个 URL 对应一组稳定的 job/item UUID，原目标目录书签保存 device、inode 和 volumeUUID。迁入的书签全部要求在新宿主重新选择原目录；重授权核对目录身份，不能靠路径字符串重用旧权限。未完成片段仍留在原授权目录的历史 `.GaoXiaZai-Staging-<grantUUID>` 容器，保留原名称、inode、SHA 和 HTTP 校验器，不复制到默认下载目录，不覆盖正式文件。

运行状态、暂停意图与完成发布区分。持久断点只记录已同步的字节及摘要；恢复先核实际片段，再使用强 ETag 与 Range/If-Range 验证资源版本。资源不一致时明确从零开始，不拼接不同版本。发布使用同卷排他新名字；同名文件竞争只另取名字，不能覆盖用户原件。完成历史后来被移动或修改时，验证会阻止打开或回送另一份同名文件。

默认并发2、同主机1、单连接；可调整总限速。默认单文件20GiB、未发布临时数据40GiB，任务最多5000项、单批1–32条。HTTP自动重试有次数与时间预算，429/5xx遵守Retry-After；空间、包大小、记录达到预算时明确停止，不静默删除用户文件。日志不记录响应正文、Cookie、Authorization或网址查询参数。

`Exchange` 保留独立请求/结果账本、私有收件副本和结果包，其外部摘要证据在本应用偏好 `GaoMenHu.DownloadExchangeEvidence.<路径摘要>`。迁移收据和独立事务将旧installationID、任务/条目/目录UUID、全文件摘要及旧交换映射关联起来。旧宿主请求和结果保留为历史，不以新提供方身份复活；新请求的目标和结果来源均为 `cn.mendao.launcher`。

## 下载功能边界

搞门户内置 URLSession 的 HTTP/HTTPS 普通文件直链下载、队列与完整性检查。没有媒体网页解析器、yt-dlp/FFmpeg、DRM绕过、Cookie/密码导入或后台守护进程；需要登录的受限资源由目标服务器决定，不借用浏览器会话。

下载完成必须实际同步、校验并排他发布文件；接收请求、建队列、pending回执或HTTP结束都不是完成。最终回送须本人显式发送，校验普通文件长度与SHA，失败重发结果不会重新下载。

迁移、幂等、故障保护与真实loopback引擎定向检查在隔离目录进行。编译或隔离测试不能代替实际安装、本人目录授权、原有资料迁移及主业务验收；这些在协调安排后分别记录。不默认启动应用、浏览器或通用冒烟测试。

## 邮件授权配置

本机入口已迁入“搞门户 → 邮件 → 邮件设置”。下面服务商配置说明沿用原邮件模块2026-10-11的文档；不表示本次整合已重新完成服务商授权验收。

### 适用范围与当前状态

Gmail / Google Workspace、Outlook / Microsoft 365 支持本应用的官方网页登录流程。添加页选择服务商后，在系统浏览器登录并允许访问；应用验证返回身份和收发登录，通过才自动填写邮箱资料、添加账号、同步并进入收件箱。连接检查只执行 IMAP / SMTP 登录，不发送测试邮件。取消、授权失败、连接失败或重复添加不会创建新账号。

本软件没有内置共享 Google / Microsoft 客户端 ID；原有本人配置随邮件资料迁移，未配置时需先完成以下注册及本机配置。本版尚未完成真实 Google / Microsoft 网页授权及真实邮箱收发验收，本地模拟测试不能替代服务商验收。

“客户端 ID”标识在服务商注册的应用，不是邮箱地址、邮箱密码或客户端授权码。维护者、组织管理员或个人测试者需有权管理相应注册应用；不要借用其他邮件软件的 ID 冒充其身份。普通用户无需配置即可网页登录，要求维护者先完成自己的正式注册及必要审核，并将合法应用配置接入发行版；本版尚未提供这项内置配置。

### 本机配置入口

从添加页点击“打开网页登录配置…”，或进入“搞门户 > 邮件 > 邮件设置…（邮件窗口中 ⌘,）> 模块设置”的 Google / Microsoft 授权区域。按下面步骤填写客户端信息后点击“保存设置”，再回到“添加邮箱”使用“网页登录添加”。QQ、网易、mail.com 的客户端授权码或应用密码填写在各自手动添加页，不填入客户端 ID 栏。

### Google：个人测试或组织内部使用

1. 打开 Google Cloud Console：https://console.cloud.google.com/
   选择自己有权限管理的项目，或为本应用新建项目。进入 Google Auth Platform；入口通常位于“API 和服务 > OAuth 同意屏幕”。
2. 在 Branding 配置应用名称、支持邮箱和开发者联系信息。在 Audience 选择适合的受众：个人 Gmail 测试使用 External / 外部，发布状态保持 Testing / 测试，并把要登录的 Google 账号加入 Test users / 测试用户；组织内部应用是否可用 Internal 由组织和项目资格决定。
   官方配置入口：https://console.cloud.google.com/auth/branding
   受众与测试用户：https://console.cloud.google.com/auth/audience
3. 在 Data Access 声明所需范围：https://mail.google.com/、openid、email。其中完整邮件范围用于 IMAP / SMTP。不要只配置普通“使用 Google 登录”的身份权限。
   权限入口：https://console.cloud.google.com/auth/scopes
4. 在 Clients 创建“Desktop app / 桌面应用”类型的 OAuth 客户端。本应用当前使用桌面 loopback 回调，不使用 Web、iOS 或 Android 客户端配置。
   回调地址为 http://127.0.0.1:<随机端口>/，监听端口由应用选择，无需另行注册固定端口。
   客户端入口：https://console.cloud.google.com/auth/clients
   将生成的 client_id 填入“Google 客户端 ID”；若下载的桌面配置包含 client_secret，将它填入“Google 客户端密钥”。本机保存的密钥位于系统钥匙串，留空会保留已有值；更换项目或 ID 时须同时核对旧密钥。
5. 保存设置后，回到添加页选择“Gmail / Google Workspace”，点击“网页登录添加”，在官方页面选择已加入测试名单的账号并同意邮件权限。Google Workspace 用户使用主账号登录，邮件别名不是独立 Google 账号。
6. 回到应用等待收发登录检查。检查通过后才会保存新邮箱并开始同步。测试状态的外部应用请求了 Gmail 权限，刷新令牌通常在 7 天后过期，届时需重新授权；撤销访问、更改密码和组织策略也可能令授权失效。

### Google：公开发行

面向公众时，由维护者维护正式 Cloud 项目及自己的客户端，完善应用主页、隐私政策、品牌信息和域名验证，按 Google Auth Platform 的验证流程提交邮件权限用途及操作演示。https://mail.google.com/ 属于受限范围；除个人使用、符合条件的内部使用等例外外，需要完成相应审核。切换到 In production 不等于审核已经通过。

年度安全评估与数据流有关：若应用有能力从第三方服务器或经过第三方服务器访问受限邮件数据，需按官方要求完成安全评估及后续复核。不能把这一条件无差别套用到所有纯本机客户端。应按实际架构和 Google 审核结论处理，不能通过复制他人客户端 ID 绕过审核。

### Microsoft：个人测试或组织部署

1. 打开 Microsoft Entra 管理中心：https://entra.microsoft.com/
   使用可管理应用注册的账号，在“Identity / 标识 > Applications / 应用程序 > App registrations / 应用注册”新建注册。若需同时兼容个人 Outlook 与不同组织的工作或学校账号，选择“任意组织目录中的账号和个人 Microsoft 账号”。内部应用可按管理员要求限制为单一目录。
2. 在 Authentication / 身份验证中添加“Mobile and desktop applications / 移动和桌面应用”平台，将 http://localhost 登记为重定向 URI。应用实际使用 http://localhost:<随机端口>/；Microsoft 的 localhost 匹配忽略端口。保持桌面公共客户端配置，不要改成依赖服务器密钥的 Web 应用流程。
3. 在 API permissions / API 权限中，为 Office 365 Exchange Online 添加 Delegated permissions / 委托权限：
   IMAP.AccessAsUser.All
   SMTP.Send
   本应用同时请求 offline_access、openid、profile、email。应用访问的是 Exchange 邮件协议；Microsoft Graph 的 Mail.Read / Mail.Send 不能替代这两个协议权限。按组织策略取得必要的管理员同意。
4. 从 Overview / 概览复制 Application (client) ID，填入“Microsoft 客户端 ID”。“Microsoft 租户”通常使用 common；组织专用应用填写管理员提供的租户 ID，且必须与应用注册支持的账号类型一致。本应用的 Microsoft 桌面公共客户端不需要 client_secret。
5. 保存设置后，在添加页选择“Outlook / Microsoft 365”并点击“网页登录添加”。在微软官方页面选择目标邮箱账号并允许访问，返回应用等待收发登录检查。
6. 网页授权成功不代表邮箱已开放 IMAP 或 SMTP AUTH。企业管理员可限制第三方应用、用户同意和协议访问；SMTP AUTH 也可能被组织安全默认值或邮箱设置禁用。遇到这类错误，应由管理员核对可用接入方式，不要为登录本应用自行关闭组织安全策略。

### Microsoft：公开发行

维护者需管理自己的应用注册、支持的账号类型、品牌和发布者域名、回调及权限。跨租户发行建议完成 Publisher verification / 发布者验证；未验证的新增多租户应用可能被风险同意策略拦截，需要管理员处理。发布者验证有组织、域名和 Partner Center 等资格要求，也不保证所有组织允许用户自行同意。本版不代替维护者完成注册或审核。

### 邮箱身份与实现边界

应用使用 S256 PKCE、一次性 state / nonce 和本机随机端口回调，并校验服务商签名、受众、有效期及返回账号，再执行实际 IMAP / SMTP 登录检查。浏览器提示已收到授权结果时，应用可能仍在检查，不能直接视为邮箱添加成功。

Google 账号可使用其他服务商的邮箱注册，仅能“登录 Google”不等于该邮箱由 Google 托管。Microsoft 的登录名、email 或 preferred_username 也不总是实际主邮箱地址。本版使用服务商返回的候选地址验证邮件访问；无法解析有效地址或连接被拒绝时，不自动添加。不同登录名、共享邮箱、委托邮箱和发件别名不会自动展开成多个账号。编辑已有账号重新授权时，需与当前保存的主登录地址匹配；这是本应用当前路径的范围，不表示服务商不支持其他委托方式。

企业 .cn、学校 .edu / .edu.cn 等后缀不代表服务商或协议。请根据真实托管方选择 Google Workspace、Microsoft 365 或其他 IMAP / SMTP；仅支持 Exchange ActiveSync 的账号不在当前邮件后端范围。Proton Mail 不在支持范围。

### QQ / 网易 / VIP 163 / mail.com

QQ：按官方说明登录网页，开启 POP / IMAP / SMTP 服务并生成客户端授权码，然后在手动添加页填写授权码。
网易 163 / vip.163：按对应官方说明开启客户端协议并生成授权码。网易官方确实说明 Outlook 等客户端存在 OAuth 2.0 登录，本应用尚未接入该方式；不能据此宣称网易不支持 OAuth。
mail.com：按官方说明确认 Premium 等具备第三方客户端权限的套餐，开启 POP / IMAP；启用二次验证时使用应用专用密码，并核对官方服务器配置。
这些入口用于官方指引和手动配置。此次未核实可供任意独立客户端直接采用的公开注册及邮件 OAuth 接入文档，不承诺打开网页即可自动绑定，也不会读取浏览器 Cookie 代替授权。

### 凭据与撤销

本机的授权令牌、刷新令牌、密码及 Google 客户端密钥保存在 macOS 钥匙串。资料备份、源码、发行包及日志不包含用户凭据。客户端 ID 是公开应用标识，与用户邮件令牌不同。移除本地授权只处理本机凭据；需要撤销服务商侧访问时，到 Google / Microsoft 官方账号安全页面移除本应用授权。更换客户端配置后，原账号可能需要重新授权。

### 官方资料（2026-10-11 核对）

Google 桌面 OAuth、PKCE 和回调：
https://developers.google.com/identity/protocols/oauth2/native-app
Google 邮件协议权限：
https://developers.google.com/workspace/gmail/imap/xoauth2-protocol
Google 测试状态与令牌有效期：
https://developers.google.com/identity/protocols/oauth2#expiration
Google 受限范围审核及安全评估：
https://developers.google.com/identity/protocols/oauth2/production-readiness/restricted-scope-verification
Google 邮箱身份边界：
https://developers.google.com/identity/gsi/web/guides/verify-google-id-token
Microsoft IMAP / SMTP OAuth：
https://learn.microsoft.com/en-us/exchange/client-developer/legacy-protocols/how-to-authenticate-an-imap-pop-smtp-application-by-using-oauth
Microsoft 回调配置：
https://learn.microsoft.com/en-us/entra/identity-platform/reply-url
Microsoft 发布者验证：
https://learn.microsoft.com/en-us/entra/identity-platform/publisher-verification-overview
Microsoft 身份字段与 SMTP AUTH：
https://learn.microsoft.com/en-us/entra/identity-platform/id-token-claims-reference
https://learn.microsoft.com/en-us/exchange/clients-and-mobile-in-exchange-online/authenticated-client-smtp-submission
QQ 授权码：
https://help.mail.qq.com/detail/106/985
网易 OAuth 说明：
https://help.mail.126.com/faqDetail.do?code=d7a5dc8471cd0c0e8b4b8f4f8e49998b374173cfe9171305fa1ce630d7f67ac2b0e7da41ebeef5ce
网易 VIP 客户端授权码：
https://help.vip.126.com/faqDetail.do?code=d7a5dc8471cd0c0e8b4b8f4f8e49998b374173cfe9171305fa1ce630d7f67ac2cade1591e6ff5019
mail.com 第三方客户端设置及应用密码：
https://support.mail.com/pop-imap/setting-up-pop-imap.html
https://www.mail.com/security/2fa/
