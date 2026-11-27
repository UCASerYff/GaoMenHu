# 搞门户 Windows 1.19

支持 Windows 10/11 x64。安装后从开始菜单打开「搞门户」。启动台、工作场景、账号库、下载中心、邮件中心和设置在 Microsoft Edge WebView2 窗口中运行。Windows 构建 4 重新排布了这些页面的导航、搜索、列表和表单，窄窗会收起部分导航，常用操作仍可通过键盘访问。托盘可打开主窗口、下载中心和邮件中心，贴边悬浮启动台支持左侧、右侧及自由浮动。窗口内可按 `Ctrl+Alt+P` 显示或隐藏悬浮启动台。

## 安装和资料

运行 `GaoMenHu-Windows-1.19-build4-x64-Setup.exe`。安装只针对当前用户，程序默认位于 `%LOCALAPPDATA%\Programs\GaoMenHu`，可直接覆盖升级同版本的较早 Windows 构建。若系统缺少 WebView2 Runtime，安装程序会运行随包提供的微软引导程序，下载运行时。可用 PowerShell 核对安装包的 SHA-256。

```powershell
Get-FileHash .\GaoMenHu-Windows-1.19-build4-x64-Setup.exe -Algorithm SHA256
Get-Content .\GaoMenHu-Windows-1.19-build4-x64-Setup.exe.sha256
```

网站库和下载、邮件数据继续使用 `%LOCALAPPDATA%\MenDao`。安装、升级和卸载均保留资料。安装前可在搞门户设置的「资料」中导出 ZIP。ZIP 和 JSON 导出只包含网站资料，密码由 Windows 当前用户的 DPAPI 保护。Mac 钥匙串中的密码需要在 Windows 上重新保存。

目录缺失时，首次运行创建六个示例网站。目录存在但完全为空时，页面提供「创建网站资料」。历史初始化证据、损坏的资料或中断的写入会进入恢复保护，并提示先检查资料。窗口选项和打开记录沿用旁边的 `MenDao.preferences.json`。

## 浏览器助手

安装程序默认向 Chrome 和 Edge 注册 `cn.mendao.bridge`，并把 v1.19 扩展存放在安装目录下的 `BrowserExtension`。在要使用的 Chrome 或 Edge 个人资料中打开扩展管理页，启用开发者模式，点「加载已解压的扩展程序」并选择该目录。可在「设置 → 浏览器」打开管理页和助手所在目录。

在各浏览器资料中打开扩展弹窗查看连接状态，必要时点「重新连接」。多个资料连接后，可在网站编辑器中指定资料。浏览器必须在所选网站的允许列表中。保存了网站密码时，在搞门户确认解锁，再从搞门户启动网站。助手在匹配的 HTTPS 登录页填入账号，用户自行完成提交。对于从 Mac 导入、原先用 Safari 的网站，请在网站编辑器中选择本机已安装的 Chrome、Edge 或 Firefox，再保存默认浏览器。浏览器切换由用户确认。

## 下载和邮件

- 下载中心支持 HTTP/HTTPS 直链复核、路径确认、暂停、继续、取消、重试、强 ETag 续传、SHA-256 校验和同名保护。Windows 通过目录和卷身份校验授权。已有下载队列会保留。旧版保存目录或从 Mac 迁入的目录可在下载中心重新确认。
- 邮件中心可查看缓存、管理账号、收发、同步文件夹、编辑草稿、处理附件、提取验证码和管理别名。账号启用、网络连接、网页 OAuth 授权和发信均由用户触发。Google/Microsoft 授权使用系统浏览器。服务商配置可在邮件设置中查看。密码与 OAuth 令牌由 Windows DPAPI 保护。
- 邮件工具栏或系统托盘可显示邮件悬浮窗。平时保留窄条，鼠标悬停后展开，移开、点击窗外或按 `Esc` 收起。可以拖动到左右侧贴边或自由停放。默认显示本机缓存未读数，可在邮件设置中开启近期邮件预览。滚动预览时，收件箱、同步和写信仍固定在窗口下方。
- Windows 使用通知区域和系统窗口样式。字体、窗口边框和悬浮窗材质与 Mac 有可见差异。账号解锁使用 Windows 当前用户的 DPAPI 和应用内确认。网站图标支持常见位图及 ICO。

## GaoAction 交接

安装后，其他搞系列 Windows 应用可通过当前用户的 GaoAction 注册发现搞门户及其 `GaoCapabilities.json`。支持 `--gaoaction <交接包目录>` 的已安装接收方可通过注册接收投递。在「设置 → 资料」打开交接包、发起下载链接交接或查看结果汇总。发送前可选接收方并复核链接。接收方确认后可发送接收回执和最终结果。搞门户会校验期限、编号、关联请求及附件的 SHA-256。缺少相应能力声明的应用可用文件包手动交付。

## 开发与回归

在 Windows x64 上使用 Python 3.12 和 Inno Setup 6.5。PowerShell 7 可按下面的命令运行测试、构建安装包并在项目目录内冒烟。

```powershell
cd windows
python -m pip install -r requirements-dev.txt
$env:GAOMENHU_UI_TEST = '1'
python -m pytest -q
node --test ..\Tests\Extension.cjs
.\build.ps1 -SkipDependencies -InnoSetup 'C:\Program Files (x86)\Inno Setup 6\ISCC.exe'
.\tests\install-smoke.ps1 -Setup .\dist\GaoMenHu-Windows-1.19-build4-x64-Setup.exe
```

本地安装冒烟以隔离目录运行。可用 `-PreviousSetup` 验证覆盖升级及原有站点、下载和邮件数据，也可用 `-LegacyExe` 传入 Windows 初版，验证原有站点和加密凭据。默认使用独立安装标识验证卸载及资料保留。如果本机的搞门户注册项为空，可加 `-Register` 验证正式注册。安装 Playwright Core 后加 `-PlaywrightPackage` 指向该软件包目录，可在干净的 Chrome、Edge 资料中测试随包原生助手。默认测试用临时主机名连接同一个随包程序，避免改动已有的正式助手注册。托盘和中文输入可用 `tests/native_desktop_smoke.py` 进行隔离验证。`python tests/native_visual_smoke.py after <截图目录>` 可在独立桌面采集两个悬浮窗的浅、深色 150% 截图。

单独运行开发窗口时，可给 `python launch.py` 传入 `--data-dir` 指向隔离资料。给独立浏览器进程设置 `GAOMENHU_DATA_DIR` 为同一绝对路径，可让其原生助手连接该资料。`--serve --no-browser` 只启动本地回环服务，适合测试。发行包版本是 1.19，Windows 内部构建号为 4。
