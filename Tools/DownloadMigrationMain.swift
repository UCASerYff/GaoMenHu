import Foundation
import Darwin

/// Explicit coordinated migration utility. It never launches either application.
@main struct DownloadMigrationMain {
    private static func localRecord(_ path: String) throws -> Data {
        let url = URL(fileURLWithPath: path)
        guard path.hasPrefix("/"), url.isFileURL, !url.pathComponents.contains(".."), !url.pathComponents.contains(".") else { throw DownloadError.message("迁移凭据路径无效。") }
        let parent = try openDirectoryNoLinks(url.deletingLastPathComponent()); defer { close(parent) }
        let fd = openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw DownloadError.message("迁移凭据不可读。") }; defer { close(fd) }
        let before = try statIdentity(fd)
        guard regularOwned(before), before.st_mode & 0o022 == 0, before.st_size > 0, before.st_size <= 32 * 1024 * 1024 else {
            throw DownloadError.message("迁移凭据不是安全普通文件。")
        }
        var value = Data(), buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0, value.count + max(0, count) <= 32 * 1024 * 1024 else { throw DownloadError.message("迁移凭据读取失败。") }
            if count == 0 { break }; value.append(contentsOf: buffer.prefix(count))
        }
        let after = try statIdentity(fd)
        guard before.st_dev == after.st_dev, before.st_ino == after.st_ino, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              Int64(value.count) == after.st_size else { throw DownloadError.message("迁移凭据在读取期间改变。") }
        return value
    }

    static func main() {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            let planOnly = args == ["--plan"]
            guard planOnly || (args.count == 6 && args[0] == "--apply" && args[1] == "--source-retired"
                && args[2] == "--authority" && args[4] == "--backup-receipt") else {
                throw DownloadError.message("用法：--plan，或在来源已冻结且完整备份恢复核验后 --apply --source-retired --authority <凭据.json> --backup-receipt <恢复收据.json>。")
            }
            let home = FileManager.default.homeDirectoryForCurrentUser
            let legacy = home.appendingPathComponent("Library/Application Support/GaoSeries/GaoXiaZai", isDirectory: true)
            let target = home.appendingPathComponent("Library/Application Support/MenDao/DownloadCenter", isDirectory: true)
            // Export the exact source domain. Unreadable/missing preferences
            // cannot silently become an empty evidence dictionary.
            let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
            task.arguments = ["export", "com.gaoseries.GaoXiaZai", "-"]
            let output = Pipe(); task.standardOutput = output; task.standardError = Pipe()
            try task.run(); let bytes = output.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
            guard task.terminationStatus == 0, bytes.count <= 32 * 1024 * 1024,
                  let values = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any] else {
                throw DownloadError.message("旧宿主偏好无法完整读取，未迁移或创建空队列。")
            }
            let matching = values.filter { $0.key.hasPrefix(PortalDownloadMigration.legacyExchangeEvidencePrefix) }
            let evidence = matching.compactMapValues { $0 as? Data }
            guard matching.count == evidence.count else { throw DownloadError.message("下载独立证据损坏。") }
            if planOnly {
                let snapshot = try PortalDownloadMigration.preflight(legacyRootURL: legacy, sourcePreferences: evidence)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(snapshot)
                FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data("\n".utf8)); return
            }
            let authorityBytes = try localRecord(args[3])
            let authority = try JSONDecoder().decode(PortalDownloadMigrationAuthority.self, from: authorityBytes)
            let backupReceipt = try localRecord(args[5])
            guard authority.backupReceiptSHA256 == downloadDigest(backupReceipt), authority.sourceFrozen,
                  let targetDefaults = UserDefaults(suiteName: "cn.mendao.launcher") else {
                throw DownloadError.message("最终停写凭据或完整备份恢复收据不匹配。预备基线不能启用生产权威。")
            }
            let receipt = try PortalDownloadMigration.prepare(destinationRootURL: target, legacyRootURL: legacy,
                sourcePreferences: evidence, targetDefaults: targetDefaults, sourceRetired: true, authority: authority)
            print("下载资料迁入完成；任务 \(receipt.taskIDs.count)，条目 \(receipt.itemIDs.count)，目录授权 \(receipt.destinationIDs.count)。")
            print("旧目录授权须本人在搞门户重新选择原目录；未自动恢复任何传输。")
        } catch {
            fputs("下载迁移未完成；保留来源、目标、事务与备份，请核对恢复依据。\n", stderr)
            exit(1)
        }
    }
}
