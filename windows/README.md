# 搞门户 Windows 1.19

支持 Windows 10/11 x64。安装后从开始菜单打开「搞门户」。启动台、工作场景、账号库和设置使用 macOS v1.19 的界面资源，在 Microsoft Edge WebView2 窗口中运行。托盘可打开主窗口、下载中心和邮件中心，贴边悬浮启动台支持左侧、右侧及自由浮动。窗口内可按 `Ctrl+Alt+P` 显示或隐藏悬浮启动台。

## 安装和资料

运行 `GaoMenHu-Windows-1.19-x64-Setup.exe`。安装只针对当前用户，程序默认位于 `%LOCALAPPDATA%\Programs\GaoMenHu`。若系统缺少 WebView2 Runtime，安装程序会运行随包提供的微软引导程序，下载运行时。可用 PowerShell 核对安装包的 SHA-256。

```powershell
Get-FileHash .\GaoMenHu-Windows-1.19-x64-Setup.exe -Algorithm SHA256
Get-Content .\GaoMenHu-Windows-1.19-x64-Setup.exe.sha256
```

网站库和下载、邮件数据继续使用 `%LOCALAPPDATA%\MenDao`。安装、升级和卸载均保留资料。安装前可在搞门户设置的「资料」中导出 ZIP。ZIP 和 JSON 导出只包含网站资料，密码由 Windows 当前用户的 DPAPI 保护。Mac 钥匙串中的密码需要在 Windows 上重新保存。

目录缺失时，首次运行创建六个示例网站。目录存在但完全为空时，页面提供「创建网站资料」。历史初始化证据、损坏的资料或中断的写入会进入恢复保护，并提示先检查资料。窗口选项和打开记录沿用旁边的 `MenDao.preferences.json`。

## 浏览器助手

安装程序向 Chrome 和 Edge 注册 `cn.mendao.bridge`，并把相同的 v1.19 扩展存放在安装目录下的 `BrowserExtension`。在要使用的 Chrome 或 Edge 个人资料中打开扩展管理页，启用开发者模式，点「加载已解压的扩展程序」并选择该目录。可在「设置 → 浏览器」打开管理页和助手所在目录。

在各浏览器资料中打开扩展弹窗查看连接状态，必要时点「重新连接」。多个资料连接后，可在网站编辑器中指定资料。浏览器必须在所选网站的允许列表中。保存了网站密码时，在搞门户确认解锁，再从搞门户启动网站。助手在匹配的 HTTPS 登录页填入账号，用户自行完成提交。Firefox 支持打开网站。Safari 在 Windows 上显示为不可用。

## 下载和邮件

- 下载中心支持 HTTP/HTTPS 直链复核、路径确认、暂停、继续、取消、重试、强 ETag 续传、SHA-256 校验和同名保护。Windows 以所选目录与卷标识识别路径，下次接入异常时可重新确认目录。下载中心单独保存队列。跨应用下载可在中心复核请求并导出回执。
- 邮件中心可查看缓存、管理账号、收发、同步文件夹、编辑草稿、处理附件、提取验证码和管理别名。账号启用、网络连接、网页 OAuth 授权和发信均由用户触发。Google/Microsoft 授权使用系统浏览器。服务商配置可在邮件设置中查看。密码与 OAuth 令牌由 Windows DPAPI 保护。
- Windows 使用通知区域代替 Mac 菜单栏，系统窗口边框、字体、模糊材质及缩放行为会有可见差异。账号解锁使用 Windows 当前用户的 DPAPI 和应用内确认。网站图标支持常见位图及 ICO。Mac 文档包可通过设置里的目录选择打开。Windows 通过文件交付跨应用回执，跨应用投递和 Mac 的结果汇总窗口仍有差距。

## 开发与回归

在 Windows x64 上使用 Python 3.12 和 Inno Setup 6.5。PowerShell 7 可按下面的命令运行测试、构建安装包并在项目目录内冒烟。

```powershell
cd windows
python -m pip install -r requirements-dev.txt
$env:GAOMENHU_UI_TEST = '1'
python -m pytest -q
node --test ..\Tests\Extension.cjs
.\build.ps1 -SkipDependencies -InnoSetup 'C:\Program Files (x86)\Inno Setup 6\ISCC.exe'
.\tests\install-smoke.ps1 -Setup .\dist\GaoMenHu-Windows-1.19-x64-Setup.exe
```

本地安装冒烟以隔离目录运行，并用安装程序的 `/PORTABLE=1` 跳过快捷方式和浏览器注册。GitHub Actions 的独立测试账号另外执行浏览器注册与卸载校验。安装冒烟可用 `-LegacyExe` 传入 Windows 初版可执行文件，验证已有网站库及其加密凭据可以继续读取。

单独运行开发窗口时，可给 `python launch.py` 传入 `--data-dir` 指向隔离资料。`--serve --no-browser` 只启动本地回环服务，适合测试。发行包版本是 1.19，Windows 内部构建号为 2。
