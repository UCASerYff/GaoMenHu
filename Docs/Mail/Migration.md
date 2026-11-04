# 搞邮件迁入搞门户

邮件模块沿用原生收发、缓存、附件、草稿、身份及平台资料。新权威目录为 `~/Library/Application Support/MenDao/MailCenter/`，来源目录为 `~/Library/Application Support/GaoSeries/GaoYouJian/`。来源项目不是编译或运行依赖。

## 先保留资料，再切换权威

总协调先完整备份来源项目、未提交改动、Git 历史、真实资料、偏好、缓存、全部自有附件及恢复依据，逐摘要核验并做恢复演练。来源 V1.10 没有覆盖全库的写者锁；总协调必须在最后快照到切换完成期间实际阻止旧宿主继续写入。单次查询进程不存在、工具的 `--source-retired` 参数或写在 JSON 里的 `sourceFrozen=true`，都不能代替这个动作。

迁移前不自动启动任一应用，不登录、不联网，也不读取或导出钥匙串秘密。原凭据继续使用 `com.gaoseries.GaoYouJian.credentials` 和原账号／OAuth 标识；这些标识保留不代表新宿主已经取得访问权限。首次打开只显示缓存，须本人在原生邮件界面明确连接，系统钥匙串提示也由本人处理。未配置 Google／Microsoft 客户端 ID 时仍显示未配置。

## 同一生产逻辑的工具入口

编译前先取得工作区 `合并迁移-2026-11-02/build_lease.py` 的唯一构建租约。输出位置必须是预先存在的真实 `.noindex` 容器，工具不会生成 `.app`：

```sh
Scripts/build-mail-migrator.sh /absolute/reports.noindex/mail-migrator
```

构建器使用本项目的 `MailNative.c`、头文件和系统框架／libcurl；不引用来源项目。仅编译不会执行迁移。

只读预检：

```sh
/absolute/reports.noindex/mail-migrator --plan
```

预检通过相同的 `PortalMailMigration.preflight` 读取真实来源，输出全树、Library 和完整来源偏好三个摘要，以及账号、草稿、缓存和附件数量。完整偏好来自 `/usr/bin/defaults export com.gaoseries.GaoYouJian -` 的原始 plist 字节，不只挑选若干键，也不将导出失败当作空偏好。输出包含本机元数据，应保存在私有报告中。

只有完整备份恢复演练完成、来源实际停写且最后快照核验无变化后，总协调才能生成 schema 1 的 `PortalMailMigrationAuthority`，再执行：

```sh
/absolute/reports.noindex/mail-migrator --apply --source-retired \
  --authority /absolute/private/authority.json \
  --backup-receipt /absolute/private/backup-restore-receipt.json
```

凭据包含精确的来源／目标 Bundle ID 和物理路径、来源全树摘要、主库摘要、完整原偏好字节摘要、`sourceFrozen` 及真实备份恢复收据的 SHA-256。工具安全打开两个绝对 JSON 文件，拒绝链接、硬链接、非本人文件、读取期间变化和超预算数据，并核对备份收据的实际字节摘要；随后调用相同的生产 `PortalMailMigration.prepare`。目标偏好域固定为 `cn.mendao.launcher`。

原始偏好导出字节若发生变化，即使只是序列化顺序差异，也须先核对并依据最新完整导出重新建立最后授权；工具不会自行标准化、忽略摘要或改写旧授权来通过。不要将预备清单或占位收据当作完成备份、停写或恢复验证的凭证。

## 保留与拒绝边界

- 保留原账号 UUID、启用标记、UID／UIDVALIDITY、平台、草稿、缓存附件和未完成 OAuth 记录，不补造账号或成功状态。
- 私有目录内草稿附件按完整实物映射；外部草稿附件保留原路径，迁移不擅自读取、搬动或声称权限已转授，使用时由本人正常授权。
- 旧初始化依据、恢复文件和未知文件原样保留并在收据标明，不把未知内容冒充已验证的新格式。缺失、不可读、未来格式、摘要冲突或未完成事务都停写，不以空库覆盖。
- 新目标具有独立初始化证据和迁移事务；重复执行核验既有收据，不重复导入。失败保留来源、目标、暂存和恢复依据，不能用旧快照覆盖新增资料。
- 原浮窗偏好完整归档；新宿主的可见和发件人／主题预览默认关闭。邮件主题仅应用于邮件窗口，不改门户网站模块的外观。

源码、安装包和公开仓库不包含邮件资料、附件、偏好、备份或凭据。真实迁移、安装、业务验收与来源退役由总协调安排；隔离检查、编译成功或工具返回成功不等于这些步骤已经完成。
