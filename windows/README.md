# 搞门户 Windows 版

营销版本与当前 Mac 版同为 **1.19**。Windows 构建号为 **1**，关于页和接口里的版本字符串是 `1.19+1`。

Windows 代码都在这个目录。业务用 **Python 3.12 标准库**，界面是只监听 `127.0.0.1` 的本地网页，GitHub Actions 在 `windows-latest` 上用 **PyInstaller** 打出 `GaoMenHu.exe` 和 `GaoMenHu-cli.exe`。没有改 Mac 版 Swift 源码。

## 运行

从源码：

```powershell
cd windows
py -3.12 -m pip install -r requirements-dev.txt
py -3.12 -m pytest -q
py -3.12 launch.py --data-dir $env:LOCALAPPDATA\MenDao
```

打包：

```powershell
powershell -ExecutionPolicy Bypass -File .\build.ps1
.\dist\GaoMenHu.exe
```

资料目录默认是 `%LOCALAPPDATA%\MenDao`，对应 Mac 的 `~/Library/Application Support/MenDao`。初始化证据、悬浮偏好和使用次数放在目录旁边的 `MenDao.preferences.json`，不写进 `library.json`。

- 目录还不存在时，第一次启动会写入 6 个示例网站。
- 目录已经存在但是空的，不会自动写入。页面上的「创建网站资料」或 `POST /api/library/create` 只在目录完全为空、没有初始化证据、没有历史偏好时创建。这是为了避免把残留目录当成首次使用。
- 主库缺失、schema 不是 1、或存在 `.gaomenhu-library-write-*` / `.gaomenhu-library-init-*` / `.gaomenhu-restore-*` 时进入恢复保护，不再自动保存。

密码不进入 `library.json`、JSON 导出或 ZIP。Windows 上用当前用户的 DPAPI 加密，服务名仍是 `cn.mendao.launcher.passwords`。邮件凭据分开保存，服务名仍是 `com.gaoseries.GaoYouJian.credentials`。

## 功能对照

| 功能 | 状态 | 说明 |
| --- | --- | --- |
| 启动台网站、文件夹、分页、搜索 | 已实现 | 名称、网址、简称、账号名；汉字用拼音全拼和首字母。拖动重排不会增减网站 |
| schema 1 `library.json` | 已实现 | 与 Mac 一样，未知字段在读入后丢弃。默认浏览器必须属于允许列表 |
| 紧凑 / 宽松、60 / 76 / 92 图标、系统 / 浅色 / 深色 | 已实现 | 外观写入资料库 |
| 多选移出、改默认浏览器、放入文件夹、撤销最近 30 次整理 | 已实现 | 撤销只恢复排列和浏览器选择 |
| 工作场景 | 已实现 | 1–20 个网站，各自用自己的默认浏览器。指定浏览器未安装时不改用别的 |
| 账号元数据与密码 | 已实现 | JSON 只留 `hasPassword`。解锁后 300 秒内可读取 |
| Chrome / Edge 收藏栏导入 | 已实现 | 读取 `%LOCALAPPDATA%` 下 Chrome、Edge 的 `Bookmarks`。重复网址保留现有账号和浏览器 |
| JSON 合并、恢复预览、ZIP 完整资料 | 已实现 | ZIP 只有 `manifest.json` 和 `library.json`，format 2，`snapshotCount` 为 0。不制作自动备份 |
| GaoAction V1 | 已实现 | `portal.openSite`、`portal.openWorkspace`、`portal.focusSearch`、`portal.proposeSite`、`portal.prepareDownload`。建议新站只打开编辑，不静默写入。参数里出现密码字段会拒绝。`../` 附件路径会拒绝 |
| 最小目录导出 | 已实现 | 只导出被点名的网站或场景的编号和显示名，不含网址和账号 |
| 悬浮启动 | 替代 | `/float` 是单独的本地页面。排序仍是最近 3 个，再用打开次数补到最多 8 个。没有置顶原生窗口 |
| 使用次数 | 已实现 | 只记录从搞门户成功发起的打开，存在偏好文件，不进网站资料备份 |
| 下载队列 | 已实现 | HTTP/HTTPS 直链，复核查询参数，暂停、继续、取消、重试，Range + 强 ETag，SHA-256，同名不覆盖。崩溃或重新打开后，正在下载和排队的任务改为暂停，不自动续传 |
| 下载迁移 | 已实现 | 目标已有 `downloads.json` 时拒绝覆盖。迁入后目录标记为需要重新确认，未完成任务进入 `waitingForDestination` |
| 邮件缓存、明确连接、草稿、验证码、别名 | 已实现 | 未连接不登录服务器。连接后用标准库 IMAP 收取信头、SMTP 发送。发送先写记录，未完成不自动重发 |
| OAuth 授权地址 | 部分 | 能生成 Google / Microsoft 的 PKCE S256 地址。没有把浏览器回调、令牌刷新和 JWKS 校验做成完整登录 |
| 浏览器助手 | 部分 | 原生消息帧、`poll` / `credentials` / `saveBookmark` 与扩展协议一致，填充前核对 HTTPS 来源。需要自行注册主机，见下文 |
| 高清站点图标 | 部分 | 可保存自定义图片数据。自动拉取只接受 HTTPS，失败时保留色块，没有 Mac 那套位图裁剪窗口 |

## 没有对齐的部分

这些依赖 macOS，Windows 版没有假装实现：

- **Safari、菜单栏、Dock、触控板横向滑动、⌘Z 以外的系统快捷键。** 撤销在页面里。Safari 仍出现在浏览器目录中，但这台电脑没有 Safari，指定它会失败，不会改用 Chrome 或 Edge。
- **原生悬浮窗。** 没有贴边 32 pt、悬停 0.45 秒、移出约 0.15 秒的系统窗口，也没有菜单栏开关。替代品是本地页面里的悬浮条。
- **macOS 钥匙串和 Touch ID。** 已有 Mac 密码不能被 Windows 读出。DPAPI 只保护这台电脑上的当前用户。
- **WKWebView 邮件正文。** 页面会去掉脚本、事件属性和远程图片，不是带 CSP 的系统 WebView。
- **security-scoped bookmark、APFS 的 inode / volume UUID、同卷重新挂载证明。** 下载目录用路径授权。换盘或路径失效后要重新选择目录。
- **`.noindex`、Spotlight、LaunchServices、DistributedNotificationCenter。**
- **与正在运行的 macOS 搞门户同时写同一份资料。** 可以把目录放在一起看，但不要两边同时写。
- **`gaomenhu://` 一类 URL 协议。** 没有注册。
- **Chrome / Edge 助手不会在安装时自动获得 Mac 那种“打开浏览器并重连”的系统集成。** 扩展 ID 仍是 `ipggjapdbehjdikobhedllpdbchkoigf`。在 Chrome 或 Edge 加载仓库里的 `BrowserExtension`，再把主机清单注册到当前用户：

```text
HKCU\Software\Google\Chrome\NativeMessagingHosts\cn.mendao.bridge
HKCU\Software\Microsoft\Edge\NativeMessagingHosts\cn.mendao.bridge
```

清单里的 `path` 指向 `GaoMenHu.exe`，`allowed_origins` 为 `chrome-extension://ipggjapdbehjdikobhedllpdbchkoigf/`。主机名是 `cn.mendao.bridge`。Windows 的原生消息协议不告诉主机这是 Chrome 还是 Edge，因此一个已连接的资料会同时记在这两个浏览器下。只开一个浏览器、并在网站上绑定该资料时，填充规则与 Mac 相同。

OAuth 收信没有做成完整回路：需要本人的客户端标识、本机回调和提供方公钥校验。现在可以用 IMAP/SMTP 密码或应用专用密码，在页面里先保存账号，再点连接。

## 测试

`windows/` 下的单元测试覆盖资料保护、合并与恢复、拼音和悬浮排序、密码不落盘、浏览器不回退、交接包、收藏导入、下载与迁移、验证码和别名、本地 HTTP 接口。

`.github/workflows/windows.yml` 在 `windows-latest` 上跑这些测试，打包两个 exe，再用临时空目录启动 `GaoMenHu.exe`：页面必须返回 200 和会话令牌，创建资料库，写入一个网站，再从 `library.json` 和接口读回。产物名称是 `GaoMenHu-Windows-1.19`。工作流不发布 GitHub Release。
