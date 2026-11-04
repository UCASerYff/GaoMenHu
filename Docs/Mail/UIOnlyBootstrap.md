# 邮件界面偏好独立初始化

此入口只用于本人明确授权的特殊现状：旧邮件生产业务根及固定恢复/容器路径均不存在，但旧偏好仅含已知界面设置。它创建新的业务库，继承兼容 UI 设置；`newLibrary=true`、`dataMigrated=false`。它不表示旧库已迁移、历史上从未建库或所有可能的个人文件均不存在。

正常 `PortalMailMigration` 和 `mail-migrator` 不变：缺业务根且历史偏好非空仍严格拒绝。不得用空 `Library.json`、伪造 `sourceLibrarySHA256`、改写旧 journal 或假备份绕过。旧候选不改写；新源码需要协调安排的构建、签名及新收据。

## 所有权与前置条件

真实执行仅由 Root 取得统一前台维护租约后安排。Root 须建立并持续保持旧宿主/写者 fence，完整备份原 UI 偏好、接收方现用资料及所需附件/进度，并验证恢复。此 CLI 不读取钥匙串、旧业务内容或外部附件，不连接 IMAP/SMTP、不启动 GUI，也不复核外部备份内容；外部恢复事实由 Root 负责，CLI 仅核验声明、实际收据文件字节摘要与本次 plan 的绑定。

CLI 的 apply 还独立重复检查：`/Applications/搞邮件.app` 的正式路径确实缺席；系统进程枚举有效，未出现 `GaoYouJian`、`MenDao`、`MenDaoBridge` 执行名。它不退出或发送信号给任何进程。进程消失的瞬时检查不能代替 Root 的持续 fence；Root 前台租约由私有调用者实时复核，公开源不写个人线程 ID。

固定无源范围由当前用户 home 派生，逐级 nofollow 检查：

1. `Library/Application Support/GaoSeries/GaoYouJian`
2. `Library/Containers/com.gaoseries.GaoYouJian`
3. `Library/Application Support/com.gaoseries.GaoYouJian`
4. `Library/Saved Application State/com.gaoseries.GaoYouJian.savedState`
5. `Library/Application Support/GaoSeriesRestore/GaoYouJian`
6. `Library/Application Support/GaoSeries/GaoYouJian-Initialization.json`
7. `Library/Application Support/GaoSeries/.GaoYouJian.initialized-v1.json`

任何存在对象（包括链接）、链接祖先、非目录祖先、权限拒绝或 I/O 失败都拒绝。缺失证据记录最近存在父目录的 dev/inode/UID/GID/mode/flags 和后续缺失路径，不扫描用户文稿或任意附件。业务根不存在覆盖其内部库、草稿和附件的缺席检查，不声称检查了任意外部附件。

目标必须完全未初始化：`MenDao/MailCenter`、独立 marker 不存在，相关任何 `GaoMenHu.Mail*` 独立偏好证据及 `gaomenhu.mail.*` 设置均无，目标相邻迁移/初始化事务容器均无。已有空目录也拒绝，不能静默接管。MenDao 父目录须是当前用户的私有真实目录。

## 只读 plan

编译与测试先持有 Master 精确构建租约；脚本本身不创建应用、不开窗口：

```sh
bash Scripts/build-mail-ui-bootstrap.sh /绝对/已存在容器.noindex/唯一名称-mail-ui-bootstrap /绝对/原始本人授权事实.json
/绝对/已存在容器.noindex/唯一名称-mail-ui-bootstrap --plan
```

输出 JSON 为 `{ "plan": {...}, "absencePlanSHA256": "..." }`。其中摘要针对 `plan` 的 JSONEncoder sortedKeys 编码计算，不是整个漂亮输出文件的 SHA。plan 不是 sourceFrozen 证明。

plan 包含精确 sourceRoot/targetRoot/sourcePreferencesPath、7项 absence 见证、偏好键名/类型及映射键名，不输出值。`sourcePreferencesSHA256` 为本次 `/usr/bin/defaults export com.gaoseries.GaoYouJian -` 的完整原始字节；`sourcePreferencesFileSHA256` 是实际磁盘 plist 原始字节。两份各自严格验证 UI 白名单，并要求字典语义一致。磁盘还保存 `sourcePreferencesFileIdentity`：device/inode/uid/gid/mode/flags/links/size、mtime 秒/纳秒、ctime 秒/纳秒。读期间固定 FD，重复校验文件与父目录身份，无链接、硬链接、组/其他用户可写文件或超预算文件。

允许旧键为 `gaoyoujian.appearance`、`sidebarHidden`、`floating.opacity/display/horizontalRatio/verticalRatio/edge/dockMode/visible/showPreviews`，并验证枚举、有限数值范围及真实 CFBoolean。整数1不能冒充 Bool。明确允许的窗口 frame 键只有 `NSWindow Frame GaoYouJian.MainWindow`、`NSWindow Frame com_apple_SwiftUI_Settings_window`、`NSWindow Frame main`；值须为8个有限十进制数、坐标/尺寸有预算。窗口名不同，不向门户映射 frame。未知键、账号/凭据键及坏类型全部拒绝。

兼容字段映射到 `gaomenhu.mail.*`。`floating.visible`、`floating.showPreviews` 无论原值都设 false，首次不展示旧邮件预览、不自动唤起悬浮窗。原 UI 偏好不删除、不修改。

## Root 输入契约

所有文件须为当前用户所有的安全普通文件、单链接、0600（无组/其他权限），绝对路径、无空段/点段/链接。每份 JSON 使用下列实际字段，不以示例中的真值替代真实操作：

共同身份字段（authority 与3份 proof 都有）：

- `schemaVersion: 1`
- `operation: "mail-ui-only-bootstrap"`
- `bootstrapID`: 本次 UUID
- `sourceBundleID: "com.gaoseries.GaoYouJian"`
- `targetBundleID: "cn.mendao.launcher"`
- `sourceRoot`、`targetRoot`: 来自当次 plan

authority 再包含：

- `sourceFrozen: true`: 仅在 Root 真实持续 fence 建立后填写
- `sourcePreferencesPath`、`sourcePreferencesSHA256`、`sourcePreferencesFileSHA256`、`sourcePreferencesFileIdentity`: 当次 plan 原字段
- `absencePlanSHA256`: plan 输出的规范摘要
- `backupReceiptSHA256`、`userAuthorizationProofSHA256`、`fenceReceiptSHA256`: 以下3个输入文件的原始字节 SHA

`--backup-receipt` 为本次 Root 专用声明 wrapper，另含：

- `fullCurrentBackupRestoreVerified: true`: Root 实际完成恢复验证的声明
- `sourceUIPreferencesSHA256`、`sourceUIPreferencesFileSHA256`: 对应 plan 两份原始偏好摘要
- `absentSourcePaths`: 与 plan.absences.map(path) 同顺序、完整精确匹配
- `actualBackupReceiptPath`、`actualBackupReceiptSHA256`: 真实备份恢复收据的绝对路径/原始字节摘要。CLI 安全读取并核对其是 JSON 对象；不把 wrapper 的 true 声称为 CLI 自行完成了恢复测试

`--user-authorization-proof` 再含：

- `explicitHumanAuthorization: true`
- `newLibrary: true`、`dataMigrated: false`
- `decision: "authorize-new-empty-mail-library-and-ui-preferences-only"`
- `humanMessageReference`: 实际本人授权消息的引用，非代理自批
- `actualHumanAuthorizationFactPath`、`actualHumanAuthorizationFactSHA256`: 原始本人授权事实的安全绝对文件路径及原始字节摘要。不能以 wrapper 自己选择的 SHA 作为信任锚

原始事实须为 `schemaVersion=1`、`kind=GaoSeriesHumanExplicitScopeAuthorization`、同 operation/sourceBundleID/targetBundleID，真实 Bool `newLibrary=true/dataMigrated=false`，`notProofOfNeverHavingAnAccount=true`、`doesNotCertifyWritersFrozenOrBackupsOrCurrentAbsence=true`；`questionCall/humanAnswer/scope` 非空且有界。CLI 不打印或归档答复正文，目标最小收据只保留其 SHA。

Root 私有构建调用者须先把原事实核对到独立记录的本人授权原 SHA，再把原文件路径传给构建脚本。构建脚本使用 nofollow FD/身份稳定检查读取该文件，只将 SHA 写入本次临时 `.noindex` 下的 Swift 常量并编入私有 CLI，不向公开源或 App 写入私人 pin/原文/路径。核心 `prepare` 必填、无默认的 `trustedHumanAuthorizationFactSHA256` 来自此编译期常量；测试提供独立 synthetic pin。wrapper 声称的 SHA、实际原文件 SHA 和该外部可信 pin 必须三者一致，原事实还在写入前和 commit 前重查。重写 wrapper、authority 并替换为另一份语义相似 JSON 也不能改变已编入的信任锚。Root 私有 runner 必须同步新的构建参数；旧 CLI 不支持此增强，不能冒用旧构建收据。

`--fence-receipt` 为本次 Root 专用声明 wrapper，另含：

- `sourceFrozen: true`、`hostStopped: true`、`noSourceWriterObserved: true`
- `sourceFormalApplicationAbsentOrIsolated: true`
- `actualFenceReceiptPath`、`actualFenceReceiptSHA256`: 实际可逆隔离/停写收据。CLI 安全读取并核摘要；真实运行状态还按上述 operational guard 重查

精确参数顺序：

```sh
/绝对/已存在容器.noindex/唯一名称-mail-ui-bootstrap \
  --apply --source-retired \
  --authority /绝对/本次-authority.json \
  --backup-receipt /绝对/本次-backup-wrapper.json \
  --user-authorization-proof /绝对/本人授权-proof.json \
  --fence-receipt /绝对/本次-fence-wrapper.json
```

`--source-retired` 表示本次独立写者已停用，不触发删除来源，也不是不可逆退役完成声明。所有来源删除仍只由 Root 在真实业务、唯一入口和发布闸门通过后执行。

## 初始化、失败与宿主接入

核心 `prepare` 的 `operationalGuard` 必填，可被纯合成测试注入；真实 CLI 不能省略。它在首次、intent前、生产库创建前、commit前共调用4次。source export、磁盘原字节/完整身份及7处缺失见证在 intent前、库创建前、commit前重新 CAS。任何后来出现的源库/恢复目录/源内部附件或偏好变化都会停止。

对既有 MenDao 父目录 FD 加独占非阻塞 flock，不创建锁文件。先把独立 `GaoMenHu.MailUIOnlyBootstrap.<target-path-SHA>` 状态同步为 preparing，再进行目标任何文件写入。使用生产 `MailStorage.load` 初始化独立 marker/evidence/library/cache，再 `save(emptyLibrary())`，真实核验 identities/accounts/platforms/drafts/messages 都为0。不实例化 MailStore、OAuth 或 transport，不接触原钥匙串服务 `com.gaoseries.GaoYouJian.credentials` 的任何条目/UUID引用/保护。

最小目标收据位于 `MailCenter/UIOnlyBootstrapEvidence/receipt.json`，独立状态 committed 绑定其 SHA 和 MailStorage marker SHA。最终 defaults 同步成功后才排他创建并 fsync `committed.json` seal，绑定该 committed 状态与 receipt 的 SHA；readiness 要求两者同时存在。最终同步失败即使内存值已设置 committed，也因缺 seal 保持阻断。收据明确 `newLibrary=true/dataMigrated=false`、真实初始计数、实际 absence、本人授权摘要、Root 外部恢复声明摘要，区分 `sourceBusinessDataReadOrRestored=false`、`sourceUIPreferencesRead=true`、`compatibleUISettingsCopied=true`、`keychainAccessed=false`。不含账号、邮件、附件、原 UI 值或原偏好可恢复字节。

任意中断保留 preparing/原目标/证据，不自动删除、重建、补 marker、回滚资料或刷新 authority。当前入口不提供自动恢复；Root 必须保留现场后制定明确维护步骤，不能直接重跑来采用已有目标。

宿主先调用 `PortalMailUIOnlyBootstrap.readiness(destinationRootURL:legacyRootURL:targetDefaults:)`：`.ready` 放行；`.recoveryRequired` 阻断；只有 `.absent` 才进入原 MailMigration 严格判定。readiness 只读独立状态/收据/marker/evidence和当前 Library/Cache 的生产格式/关联，不创建锁，也不以最初空库 hash 限制后续正常新增/删除账号。已 committed 的使用不依赖旧偏好、源根、备份或原始 proof，因此 Root 验收后的来源专属可恢复材料清理不破坏现用模块。

CLI 出错只输出固定 stage、错误类别（POSIX仅数值码），不输出偏好值、payload或 localizedDescription。新定向合成套件入口 `Scripts/test-mail-ui-bootstrap.sh`；构建及运行均等待 Root 构建租约，不重复旧94/268/458，也不运行冒烟。
