# 安装原件、元数据与回滚保护

本说明适用于搞门户接收方自身的程序换装。真实维护由总协调取得前台/维护授权后安排；本轮候选1.17/117与迁移CLI不因安装脚本更新重编。来源搞下载/搞邮件验收后旧件、旧资料和专属备份按最新明确指令仅由Root精确删除；邮件原钥匙串条目、接收方现用资料不属可删除旧件。

## 原件身份

`Scripts/backup_verify.py`不以压缩归档、文件字节相同或同一Bundle ID代替原件。原安装App在正式路径首先绑定完整树：各节点dev/inode、UID/GID、完整mode、BSD flags、mtime纳秒、size/nlink，所有普通文件SHA-256、原生ACL外部表示与文本，以及Darwin fd xattr接口返回的全部可读名称/原值（含`XATTR_SHOWCOMPRESSION`显示的压缩属性）。API拒绝、采样变化、预算超限或未知文件类型会停止，不能当空值。ctime只用于同一次采样前后稳定性，读取可能改变的atime不作跨搬移不变量。

ACL缺失必须由同一fd的`fstatx_np/filesec_query_property(FILESEC_ACL)`正面证明，不能把`acl_get_fd_np`的NULL/ENOENT直接当无ACL。属性读取受macOS当前执行上下文可读权限约束；任何实际访问错误均停，不声称能读取系统未向该上下文公开的属性。

## 不可变搬移链

每次备份在`ApplicationSafety/`用0600排他新建的摘要命名记录形成链；既有事件不改写。`state.json.applicationSafety`保存锚点及头指针。记录含精确恢复路径、搬移前完整身份、两侧父目录身份、native排他rename完成后完整身份、前一事件摘要。维护根本App独占flock防并发写链，不过期、不抢占；Root统一前台互斥仍须另外遵守。

App仅同卷`renameatx_np(RENAME_EXCL)`；目标已占用或实现不支持就停止，没有覆盖式rename或复制删除回退。原旧App始终放在生成前已存在的`.noindex`恢复容器，失败的新程序也只移动到专属`.noindex`。数据快照不自动覆盖当前资料。

只有本进程实际成功发起该次native rename，紧接着核验前后原inode与全部其余元数据一致时，允许App根节点精确`com.apple.provenance`键由系统改变；前后原值及差异原样封存。其他节点同名属性、ACL、mode、flags、mtime、内容、身份均不例外。代码不写、删除或泛化忽略App系统属性。

## 中断与失败

- 意图落盘但尚未搬移：两侧父身份、原件全部匹配且目标空，才能取消意图或继续后续维护。
- rename已发生、after尚未封存：只有完整身份严格无差异时可恢复记录；若有未证的provenance差异也保留现场，交Root维护核验，不能猜测或归一化。
- after记录已封存但state头尚未更新：只接受同一锚点的完整有效链前缀，按封存记录恢复，不重放或新认领对象。
- 父路径替换、两侧均占用/均缺失、链记录缺损/篡改：不删除、不覆盖、不恢复旧资料快照。
- 登记失败时保留`rollingBack`或`installed`可重入阶段，不能提前写`rolledBack/finalized`。重试按同一身份链继续，精确登记成功后才终态。
- 暂存清理仅移除确认属于本轮且为空的容器。不明/非空/替换的stage保留，并写`程序暂存保留-*.json`指针；没有递归删除未知候选。挂载失败恢复同样保留精确路径，不动其他镜像。

## 精确登记与历史

登记前先成功读取完整 `lsregister -dump`，逐记录核对本App的 identifier、codeInfoID、可执行文件、应用类型、精确路径和已封存的历史/当前 inode，且必须能看到正式入口的有效正向记录。未知同名或同标识路径、字段缺失/冲突、查询失败或空结果均停止；不据此推断“没有登记”。

仅对链中属于本App且真实原件已核验的正式路径执行`lsregister -f`。旧暂存/失败路径只有在当前有效dump确有其精确已知登记时才执行`-u`；已移动、不存在且未登记的stage跳过，不盲目注销。真正的注销错误继续抛出，不能一概忽略系统错误。每个系统操作前后再核不可变指针、全部原件及路径元数据，并重新查询精确结果；登记不得获得搬移时才允许的provenance例外。Root须另外在真实用户会话完成Spotlight/LaunchServices有效正式路径与唯一性核验，命令成功本身不表示交付完成。

历史字节收据和旧备份不改名、不删除、不静默升级为新权威；缺少完整身份链的程序操作停止。历史对象/原始恢复工具与事实仍保留，若需历史恢复，由Root先验证真实原件及原恢复依据，不从当前新版或未知副本补造旧身份。

## 窄验证

`python3 Tests/ProgramOriginalSafetyTests.py`只创建`.noindex`下不可执行合成App；签名、登记和数据访问由严格fixture替身隔离。覆盖原inode、原子排他、替换/篡改、ACL/flags/xattr、父指针、四个中断时点、登记失败重入、未知stage保留与并发维护锁。`Tests/BackupAcceptedAccountsTests.py`只回归本次finalize受影响的指定账号追加边界。没有真实App、个人资料、钥匙串或GUI操作；不属于冒烟测试，也不重复Mail268或Downloads458。

`python3 Tests/ApplicationRegistrationTests.py`是本次登记修复的独立窄检查：完整合成原件链、缺失未登记stage、精确残留登记、未知路径/身份/inode、查询/注销失败、指针变化与登记后元数据变化。所有外部命令都由fixture拦截，不查询或更改真实系统登记；既有94项不因此外部安装器修复重跑。
