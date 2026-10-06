# 搞门户 V1.04

macOS 网站启动器。把常用网站像 App 一样放进启动台，拖动排序、组合文件夹，并为每个网站指定浏览器和登录账号。

<p align="center"><img src="Assets/AppIcon.png" width="180" alt="搞门户图标"></p>

## 下载与安装

从 [Releases](https://github.com/UCASerYff/GaoMenHu/releases/latest) 下载 `GaoMenHu-1.04.dmg` 和同名 `.sha256` 文件。仓库保存源码，安装包作为 Release 附件单独发布。

1. 支持 macOS 13 或更高版本、Apple Silicon；当前未提供 Intel 版本。
2. 打开 DMG，把 `搞门户.app` 拖入“应用程序”文件夹，然后启动。
3. 安装包采用本地 ad-hoc 签名，未经过 Apple 公证。macOS 可能提示无法验证开发者，请先确认下载来源和校验和。
4. 需要浏览器自动填充时，按下方说明在 Chrome 或 Edge 加载助手。

校验下载文件：

```sh
shasum -a 256 -c GaoMenHu-1.04.dmg.sha256
```

## 功能

- 网站以 Launchpad 风格排列，支持拖动排序、组合文件夹、移入移出与文件夹重命名。
- 每个网站至少指定一个允许的浏览器；默认浏览器必须属于允许列表，不会自动改用未允许的浏览器。
- 支持 Chrome、Edge、Safari、Firefox 启动；Chrome、Edge 助手支持账号自动填充。
- 名称、网址、中文拼音、拼音首字母和自定义简称搜索；方向键选中结果，回车打开。
- 双指横向翻页，以及页码、按钮和键盘翻页；拖到左右边缘可跨页整理。
- 紧凑／宽松布局、三档图标大小、高清站点图标和本地图片裁剪。
- 多选整理、批量移动与浏览器设置、布局撤销。
- 导入 Chrome / Edge 收藏栏；通过浏览器助手收藏当前网页。
- 工作场景可一次打开多个网站，各自使用指定浏览器和账号。
- 备份导出、合并导入、恢复预览及本地自动快照。

完整操作方法见 [使用说明](使用说明.txt)。

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
- 自动快照位于同一数据目录的 `Snapshots/`，用于恢复布局；升级清理应保留。
- 自动填充须先通过 Mac 身份验证，仅针对从本应用启动、精确授权的 HTTPS 页面；登录提交、验证码和二次验证由用户完成。
- 图标请求可能访问站点首页及其图标资源，不携带收藏网址中的查询参数、登录凭据或 Cookie。
- 日常模式不清除浏览器自身的密码或 Cookie。

应用原名“门道”。为兼容原有收藏和钥匙串，内部应用标识、通信标识及 `MenDao` 数据目录保持不变。

## 从源码构建

需要 Apple Silicon Mac、Xcode Command Line Tools、Python 3；运行测试另需 Node.js。正式应用没有第三方运行时依赖。

```sh
./Scripts/test.sh
./Scripts/build.sh
./Scripts/install.sh
```

构建在临时目录中进行并自动清理。`Release/` 保存当前 DMG、校验文件和本地验证记录，不提交到 Git。安装脚本检查应用标识后替换旧的“门道”或“搞门户”程序，保留用户数据。

- `Sources/`：Swift 原生程序、数据模型、钥匙串、本地通信。
- `Resources/`：随 App 打包的启动台界面。
- `BrowserExtension/`：Chrome / Edge Manifest V3 助手。
- `Assets/`：应用图标母版和设计说明；ICNS 由构建脚本生成。
- `Scripts/`：构建、安装、版本递增和检查脚本。
- `Tests/`：模型、导入恢复、图标、通信与界面测试，使用虚构测试数据。

`Scripts/test.sh` 执行核心回归检查。UI 自检可通过 `Scripts/build.sh --app-only /private/tmp/GaoMenHu-test.app` 构建，再以 `--ui-test --self-test` 运行；自检使用隔离数据，正式包不含自检资源。`Tests/Content.cjs` 的浏览器表单测试另需 Playwright 和 Chrome。

## 版本

版本以 `VERSION` 为准，首版 V1.00，后续功能更新增加 0.01。正式更新开始时运行一次 `python3 Scripts/bump_version.py`；重复构建同一版本不会增加版本号。本次公开发布沿用已完成的 V1.04。

V1.04：产品更名为“搞门户”，主程序、浏览器助手和安装包同步更名，图标采用搞系列的白底竖排书法“门户”。
