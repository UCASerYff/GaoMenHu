import Foundation
import CryptoKit
import Darwin

/// The explicit coordinated entry point uses the same migration code as the
/// native mail host. It does not instantiate MailStore, OAuth or a mail session.
@main struct MailMigrationMain {
    private static let maximumRecordBytes = 32 * 1024 * 1024

    private static func fail(_ message: String = "迁移凭据不可安全读取。") -> MailAppError { .message(message) }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format:"%02x",$0) }.joined() }
    private static func metadata(_ fd: Int32) throws -> stat {
        var value = stat(); guard fstat(fd, &value) == 0 else { throw fail() }; return value
    }
    private static func physicalParent(_ path: String) throws -> (Int32, String) {
        let components = path.split(separator:"/", omittingEmptySubsequences:false)
        guard path.hasPrefix("/"), path.utf8.count <= 16_384, components.count > 1,
              components.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw fail("迁移凭据必须是无链接、无点路径的绝对文件路径。") }
        var directory = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw fail() }
        do {
            for component in components.dropFirst().dropLast() {
                let next = openat(directory, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw fail() }
                close(directory); directory = next
            }
            return (directory, String(components.last!))
        } catch { close(directory); throw error }
    }
    private static func localRecord(_ path: String) throws -> Data {
        let (parent, name) = try physicalParent(path); defer { close(parent) }
        let originalParent = try metadata(parent)
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw fail() }; defer { close(fd) }
        let before = try metadata(fd)
        guard before.st_mode & S_IFMT == S_IFREG, before.st_uid == getuid(), before.st_nlink == 1,
              before.st_mode & 0o022 == 0, before.st_size > 0, before.st_size <= Int64(maximumRecordBytes) else { throw fail() }
        var bytes = Data(), buffer = [UInt8](repeating:0, count:65536)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0, bytes.count + max(0,count) <= maximumRecordBytes else { throw fail() }
            if count == 0 { break }; bytes.append(contentsOf:buffer.prefix(count))
        }
        let after = try metadata(fd)
        var atPath = stat()
        guard before.st_dev == after.st_dev, before.st_ino == after.st_ino, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              after.st_mode & S_IFMT == S_IFREG, after.st_uid == getuid(), after.st_nlink == 1, after.st_mode & 0o022 == 0,
              Int64(bytes.count) == after.st_size,
              fstatat(parent, name, &atPath, AT_SYMLINK_NOFOLLOW) == 0, atPath.st_dev == after.st_dev, atPath.st_ino == after.st_ino else { throw fail("迁移凭据在读取期间改变。") }
        let (reopened, _) = try physicalParent(path); defer { close(reopened) }
        let currentParent = try metadata(reopened)
        guard currentParent.st_dev == originalParent.st_dev, currentParent.st_ino == originalParent.st_ino else { throw fail() }
        return bytes
    }
    private static func sourcePreferences() throws -> Data {
        let process = Process(); process.executableURL = URL(fileURLWithPath:"/usr/bin/defaults")
        process.arguments = ["export", "com.gaoseries.GaoYouJian", "-"]
        let output = Pipe(); process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        var bytes = Data(), buffer = [UInt8](repeating:0, count:65536)
        do {
            while true {
                let count = read(output.fileHandleForReading.fileDescriptor, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                guard count >= 0, bytes.count + max(0,count) <= maximumRecordBytes else { throw fail("原邮件偏好超过预算或不可完整读取。") }
                if count == 0 { break }; bytes.append(contentsOf:buffer.prefix(count))
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0, !bytes.isEmpty,
                  try PropertyListSerialization.propertyList(from:bytes, format:nil) is [String:Any] else {
                throw fail("原邮件偏好不可读；未将缺失或失败当作空白。")
            }
            return bytes
        } catch {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            throw error
        }
    }
    static func main() {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            let planOnly = args == ["--plan"]
            guard planOnly || (args.count == 6 && args[0] == "--apply" && args[1] == "--source-retired"
                && args[2] == "--authority" && args[4] == "--backup-receipt") else {
                throw fail("用法：--plan；或 --apply --source-retired --authority <绝对JSON路径> --backup-receipt <绝对JSON路径>。")
            }
            let home = FileManager.default.homeDirectoryForCurrentUser
            let source = home.appendingPathComponent("Library/Application Support/GaoSeries/GaoYouJian", isDirectory:true)
            let target = home.appendingPathComponent("Library/Application Support/MenDao/MailCenter", isDirectory:true)
            let preferences = try sourcePreferences()
            if planOnly {
                let snapshot = try PortalMailMigration.preflight(legacyRootURL:source, sourcePreferences:preferences)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
                FileHandle.standardOutput.write(try encoder.encode(snapshot))
                FileHandle.standardOutput.write(Data("\n".utf8)); return
            }
            let authority = try JSONDecoder().decode(PortalMailMigrationAuthority.self, from:localRecord(args[3]))
            let backupReceipt = try localRecord(args[5])
            guard try JSONSerialization.jsonObject(with:backupReceipt) is [String:Any],
                  authority.schemaVersion == 1, authority.sourceBundleID == "com.gaoseries.GaoYouJian",
                  authority.targetBundleID == "cn.mendao.launcher", authority.sourceFrozen,
                  authority.sourceRoot == source.path, authority.targetRoot == target.path,
                  authority.backupReceiptSHA256 == hash(backupReceipt),
                  let defaults = UserDefaults(suiteName:"cn.mendao.launcher") else {
                throw fail("来源停写凭据或完整备份恢复收据不匹配，未启用新邮件权威。")
            }
            let receipt = try PortalMailMigration.prepare(destinationRootURL:target, legacyRootURL:source,
                sourcePreferences:preferences, authority:authority, targetDefaults:defaults)
            print("邮件资料迁入完成；邮箱 \(receipt.accountIDs.count)，草稿 \(receipt.draftIDs.count)，缓存邮件 \(receipt.cachedMessageIDs.count)。")
            print("旧钥匙串服务与标识保留。首次仅显示缓存；连接、外部草稿附件和邮件预览仍需本人正常授权。")
        } catch {
            // Underlying file/JSON errors can carry account names or paths.
            fputs("邮件迁移未完成；保留来源、目标、未完成事务与完整备份，请核对实际恢复依据。\n", stderr)
            exit(1)
        }
    }
}
