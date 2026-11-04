# 下载原目录重授权的定向验收比较

`Scripts/download_acceptance.py` 只比较调用方已读取的三个字节串：升级前的 `downloads.json`、现用 `downloads.json` 和现用 `downloads.previous.json`，以及一个明确指定的原 grant UUID。它不打开路径，不解析书签，不请求权限，不启动网络、进程或界面。

三个 envelope 都须具备合法的 base64 payload、正确 SHA-256 和受支持的下载模型。JSON 重复字段、非有限数值、身份或任务关联异常会被拒绝。比较保留全部未知字段，不经 DTO 投影而丢弃它们。

只允许指定原 grant 的 `requiresReauthorization` 从 `true` 变为 `false`、非空合法书签更新及设备号统一到一个正整数；原卷 UUID、目录 inode、路径、ID 不变。该目录关联产物和历史暂存身份的旧设备号必须原先与 grant 一致，并一起变成相同新设备号。原任务、条目、目录集合和顺序、链接、URL、指纹、inode、SHA、字节数、状态、迁移历史、设置及其他字段全部保持。其他 grant 不得变化。

**现用 previous 与升级前 CURRENT 模型比较**，不以升级前 previous 为基线。现用 current 和 previous 都必须是同一次明确重授权后的同一业务模型，仅 revision 可以分别增加，且满足原 revision < previous revision <= current revision。不能借 previous 的正常轮转接纳不同迁移历史、删除原任务或残留测试任务。

返回值仅包含资料文件/模型摘要、指定目录身份、书签摘要和原关联文件的校验证据，书签原值不返回。此纯比较通过不代表文件权限或物理产物已核验，也不替代本人正常选择。旧升级快照、旧 state 和失败日志不能被改写为通过。

外部安装器 `install --finalize` 的最小新增接口为 `--accepted-download-grant-id <原目录UUID>`，并且必须同时提供 `--accepted-data-backup <独立完整当前备份>`。下载单独验收不需提供新增账号的网站编号；只给备份、只给目录编号或把原安装备份冒充当前备份均拒绝。未带明确参数时继续逐文件执行原严格校验，不忽略整个 DownloadCenter。

当前窄物理核验只接纳本轮已完成、无 pending 发布的关联原产物。安装器通过无符号链接路径和持有的目录/文件 FD，只读核验目录当前设备号、原 inode、当前用户及权限；用公开 `diskutil info -plist /System/Volumes/Data` 确认同一内部 APFS 卷 UUID。成品须为独立单链接普通文件，当前设备、原 inode、长度与完整 SHA-256 匹配；历史暂存身份若保留，必须属于同一成品，暂存名字仍不存在。其他状态、未知片段或不明确 I/O 不当作空白接纳，不解析书签或再授予目录权限。

完成系统登记后、写入 finalized 之前，再核验完整当前备份和物理原件，并要求原升级收据的所有字段保持（仅本轮自行写入的登记收据例外，该收据也在登记后立即捕获并最终比较）。证据变化则保留 installed 阶段、原备份与现用资料，不重写原下载模型，不自动覆盖或回滚数据。
