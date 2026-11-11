# 缺件取消历史：明确授权的隔离迁移

正常 `DownloadMigrationMain --plan/--apply` 仍要求全部历史交接包完整。这个独立工具仅供协调方按本人明确授权，将**精确四条已取消、无任务关联且声明包确实缺失的旧记录**保留为不可执行历史；缺件不记完整通过，不生成空包或补回执。来源项目、旧程序及 SourceArchive 不是接收方运行依赖。

## 构建与输入权威

Root 先持唯一构建租约，并独立核对其已记录的原始批准 snapshot 和本人明确授权事实的 SHA；不能现读一个任意新文件就把当前摘要当既有批准。构建器只编译工具，不运行迁移：

```sh
Scripts/build-download-history-isolator.sh \
  /absolute/existing.noindex/download-history-isolator \
  /absolute/private/original-approved-snapshot.json \
  /absolute/private/original-human-authorization-fact.json
```

构建器在临时 `.noindex` 生成仅含这两份原件 SHA 的 Swift 常量，编入**私有 CLI**；临时文件随构建目录清理。App 和公开源码不包含这两个私人 pin、记录 ID、nonce 或本人对话 questionCall。两个 pin 是必须输入，没有环境变量／命令行覆盖或自选 wrapper 回退。Root 私有构建调用者负责先将两原件与已知原始摘要核对；构建器不能自行判断一份此前不存在的事实是否来自本人。

原 snapshot schema 1 保留 `operation`、`authorizationReference`、原 journal SHA、5 条总数、精确四条 `exactApprovedRecords` 和 1 条完整记录数。每条 pin 包含 recordID、原 stage、requestManifestSHA256、nonceSHA256、原包名、精确缺包相对路径以及所有 delivery 包名／fingerprint／status。这里只存声明和实际缺件事实，不能称声明 hash 已与不存在原包比对通过。

原本人事实必须为 schema 1、kind `GaoSeriesHumanExplicitScopeAuthorization`、operation `downloads-quarantine-missing-history`、正确来源／目标 BID，明确 `sourceFullyVerified=false`、预期结果 `committed_with_quarantined_missing_history`。事实里的原 snapshot 路径和 SHA 必须匹配实际安全读取的原 snapshot。事实、snapshot、最终 human wrapper 三者的授权引用必须一致；不把私人引用常量写进 App。

## 只读 plan 与显式 apply

```sh
/absolute/existing.noindex/download-history-isolator --plan
```

plan 只读来源，持既有 store 共享锁与 journal 排他非阻塞锁，不创建来源锁，不联网、不读取钥匙串、原授权目录、下载文件或外部附件，不启动 App。它导出完整原偏好字节，使用同一生产校验验证源库、previous、初始化、独立交换证据和 ledger。输出 JSON 包含 `plan` 和 `planSHA256`；后者是 Swift sorted-key 编码 `plan` 的摘要，**不是 pretty console JSON 文件的摘要**。所有输出仅存私有报告，不能提交公开仓库。

仅当正好 5 条旧记录、4 条符合隔离条件、1 条完整 completed、1 job／item／grant 时才提供此 plan。完整记录和所有仍存在的交接包保持原结构／清单／payload 严格校验。隔离记录须 cancelled 且 taskIDs／itemIDs／outcomes 全空、无数据库反向关联，delivery 为无任务的取消结果。缺失须有安全父目录 FD 下的 ENOENT；存在但损坏、权限／链接／特殊文件／I/O／未知 schema 或状态／任意其他缺件，均拒绝。采样前后源树变化拒绝。最终 apply 的精确四条、journal SHA 和整个 plan 必须与**原获批 snapshot**一致，不能同数量换另一组。

```sh
/absolute/existing.noindex/download-history-isolator --apply --source-retired \
  --authority /absolute/private/final-authority.json \
  --approved-snapshot /absolute/private/original-approved-snapshot.json \
  --human-authorization /absolute/private/final-human-wrapper.json \
  --fence-receipt /absolute/private/final-fence-wrapper.json \
  --backup-receipt /absolute/private/actual-complete-restore-receipt.json
```

参数和次序必须精确。所有文件须本人拥有、单链接、无符号链接、0600 或更严格、物理绝对路径，预算 32 MiB；嵌套路径也拒绝相对／点路径。工具的失败诊断只记静态 phase／role、异常类型和可用 POSIX errno，不打印 payload、URL、账号或底层 localizedDescription。

Authority schema 2 的 operation 为 `download.migrate-with-cancelled-history-isolation.v1`，包括正确 BID、物理 sourceRoot／targetRoot、sourceFrozen、planSHA256、approvedSnapshotSHA256、humanAuthorizationSHA256、fenceReceiptSHA256、backupReceiptSHA256 和 exactApprovedRecords。schema 1 正常入口不接纳本 operation。

Human wrapper schema 2 包含同 operation、authorizationReference、**真 JSON boolean** approved=true、approvedSnapshotSHA256、planSHA256、exactApprovedRecords，另有 actualHumanAuthorizationFactPath／actualHumanAuthorizationFactSHA256。内核实际安全读取原本人事实并对照私有构建 pin，再读取事实引用的原 snapshot；不是让几份可自由替换的 wrapper 相互证明授权。

Fence wrapper schema 2 包含 operation、receiptKind=`actual-writer-fence`、sourceRoot／targetRoot、真 boolean frozen／actualWriterFence、evidenceSHA256、actualFenceReceiptPath／actualFenceReceiptSHA256；两个 evidence SHA 必须相同且与实际原件字节匹配。内核核实际 Root `fenced-observed` 文件的 transactionID、previousSHA256、来源 BID、download 源／目标根及 sourceFrozenAtThisObservation、sourceFormalApplicationAbsentOrIsolated、noSourceWriterObserved、leaseMustRemainOwned 真 boolean。此原件可诚实保留 backupVerified=false；完整真实备份／恢复由独立 backupReceipt 证明，不篡改 fence 冒充完成备份。

Root 必须保持真实 lease 和写者 fence。生产 CLI 在写入前、发布前及最终提交前再次只读核：正式 `/Applications/搞下载.app` 已隔离／不存在，下载／门户／桥接相关宿主与可识别旧 Widget／Intent 写者没有运行。只观察，不 kill，不移动程序，不改登记。单次进程清单或 true 字段不能代替 Root 持续的 fence。原钥匙串服务及引用保持，秘密不读取、不复制、不导出。backupReceipt 的字节 SHA 被精确绑定，但其实际完整性／恢复演练真实性仍由 Root 维护流程负责；占位 JSON 不构成真实通过。

## 目标现用资料与恢复边界

迁移将来源现用业务文件原字节复制到 `DownloadCenter/ReadOnlyHistory/<migrationUUID>/OriginalFiles/`，但明确排除 `downloads.previous.json` 自动备份。此处保存来源相邻初始化原件、完整原偏好、原交换独立证据、源文件清单、四条只读 entries 和只拒绝的身份索引。完整原 ledger 在该目录内保持原字节，包含原 ID、nonce 和摘要。它们是接收方现用业务历史，不需要读取旧来源路径，也不生成后续完整备份。原源码／App／专属旧恢复备份不在此保留范围。

正常库保留原 installation／job／item／grant UUID 和关系；grant 需本人重新授权，不自动开始传输。当前 Exchange 只迁入那条完整旧 completed 历史及其完整包，保留旧 target BID、不可重新批准或发送。四条缺件记录不进入当前 Exchange.records、Incoming／Outgoing 授权或重试流。原目录外的真实下载文件不由迁移工具打开，仍需本人授权后的正常完整性核验。

只读 index 保留全部原 request／result UUID 和 nonce 摘要，只有拒绝能力，没有身份或授权能力。receive、journal append、新请求以及已有 current record replace 均阻止借用原历史 UUID／nonce；replace 在此隔离存在时还冻结原请求清单／摘要／来源／URL／包名／收到时间。UI 仅显示缺件事实，不提供执行、重试、授权或发送按钮。正常碰撞为 `history_identity_reserved`，不可变依据损坏为 `exchange_recovery_required`。

独立事务偏好键 `GaoMenHu.DownloadHistoryIsolation.<SHA(targetRoot.path UTF8)>`，相邻标记 `.DownloadCenter.history-isolation-v2.json`，结果 `MigrationEvidence/receipt.json`，schema 2 状态为 `committed_with_quarantined_missing_history`、sourceFullyVerified=false、quarantinedPackageIntegrityVerified=false。收据的“committed”描述须和独立事务及完成 seal 一起核验，不能把暂存／部分发布文件本身当成功。

最后 committed defaults 同步和 readback **成功后**才独占写入／fsync 相邻 `.DownloadCenter.history-isolation-complete-v2.json`，绑定完整最终 State 摘要。readiness／readHistory 都要求完成 seal；末次同步失败即使内存已显示 committed 仍保护。validated 的同依据事务可继续，preparing 中断保留现场待恢复，不清空重建；重复成功调用不覆盖目标后来新增业务。缺独立 anchor／marker／receipt 而仍有 ReadOnlyHistory 也保护，不能落回普通空初始化。

`readHistory` 只核目标不可变依据，不打开已被 DownloadManager 持锁的库，也不访问来源。Host 创建 manager 前的 readiness 可只读核库；`verifyPreservedFiles` 核验全部现用保留字节，并明确忽略旧清单中的 `downloads.previous.json`，因此既有自动备份可精确删除而不影响其他历史校验。来源清理由 Root 在例外范围、实际资料核对、业务／组件、安装发布、调用改指和唯一入口都完成后执行；缺件事实始终不能被总台账记成全部历史完整通过。

定向合成检查脚本为 `Scripts/test-download-history-isolation.sh`，仅在 Root 构建 GO／租约后运行。它不启动 App、浏览器或测试窗口，不读取真实账户／资料／钥匙串，也不重跑原不变的下载全套。
