# 搞门户内置下载：资料和预算

下载权威根为 `~/Library/Application Support/MenDao/DownloadCenter/`；网站收藏和账号仍使用原 `MenDao/library.json` 和原钥匙串服务。下载资料不会存入网站账号字段或浏览器 Cookie。

`downloads.json` 是 schemaVersion 1 的下载快照，外层为 payload 的 Base64 与 SHA-256，内层保留 installationID、revision、migrationHistory、jobs、items、destinations 和 settings。`downloads.previous.json` 为上一完整快照，只供核对恢复，不自动回退。独立初始化记录 `.DownloadCenter.initialized-v1.json` 位于 MenDao 下，丢失或与资料冲突时停写；不能创建空队列替代已有资料。

每个 URL 对应一组稳定的 job/item UUID，原目标目录书签保存 device、inode 和 volumeUUID。迁入的书签全部要求在新宿主重新选择原目录；重授权核对目录身份，不能靠路径字符串重用旧权限。未完成片段仍留在原授权目录的历史 `.GaoXiaZai-Staging-<grantUUID>` 容器，保留原名称、inode、SHA 和 HTTP 校验器，不复制到默认下载目录，不覆盖正式文件。

运行状态、暂停意图与完成发布区分。持久断点只记录已同步的字节及摘要；恢复先核实际片段，再使用强 ETag 与 Range/If-Range 验证资源版本。资源不一致时明确从零开始，不拼接不同版本。发布使用同卷排他新名字；同名文件竞争只另取名字，不能覆盖用户原件。完成历史后来被移动或修改时，验证会阻止打开或回送另一份同名文件。

默认并发2、同主机1、单连接；可调整总限速。默认单文件20GiB、未发布临时数据40GiB，任务最多5000项、单批1–32条。HTTP自动重试有次数与时间预算，429/5xx遵守Retry-After；空间、包大小、记录达到预算时明确停止，不静默删除用户文件。日志不记录响应正文、Cookie、Authorization或网址查询参数。

`Exchange` 保留独立请求/结果账本、私有收件副本和结果包，其外部摘要证据在本应用偏好 `GaoMenHu.DownloadExchangeEvidence.<路径摘要>`。迁移收据和独立事务将旧installationID、任务/条目/目录UUID、全文件摘要及旧交换映射关联起来。旧宿主请求和结果保留为历史，不以新提供方身份复活；新请求的目标和结果来源均为 `cn.mendao.launcher`。
