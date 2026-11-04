import Foundation
import Darwin

/// Offline administrative utility. It exports only legacy UI preferences; it
/// never constructs MailStore, OAuth, a transport session, or a Keychain query.
@main struct MailUIOnlyBootstrapMain {
    private static let maximum = 32 * 1024 * 1024
    private static var stage = "arguments"
    private static func fail() -> MailAppError { .message("初始化凭据不完整。") }
    private static func local(_ path: String) throws -> Data {
        return try PortalMailUIOnlyBootstrap.readRecord(PortalMailUIOnlyBootstrap.absoluteRecordURL(path)).data
    }
    private static func operationalGuard() throws {
        // This checks actual current system state in addition to Root's bound
        // receipts. It never launches/quits/signals either app or a browser.
        _ = try PortalMailUIOnlyBootstrap.absence(URL(fileURLWithPath: "/Applications/搞邮件.app"))
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-ww", "-axo", "pid=,uid=,comm="]
        let output = Pipe(); process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        var data = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
        do {
            while true {
                let count = read(output.fileHandleForReading.fileDescriptor, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                guard count >= 0, data.count + max(0, count) <= 16 * 1024 * 1024 else { throw fail() }
                if count == 0 { break }; data.append(contentsOf: buffer.prefix(count))
            }
        } catch {
            if process.isRunning { process.terminate() }; process.waitUntilExit(); throw error
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0, data.count > 0,
              let text = String(data: data, encoding: .utf8) else { throw fail() }
        let blocked: Set<String> = ["GaoYouJian", "MenDao", "MenDaoBridge"]
        var rows = 0
        for line in text.split(separator: "\n") {
            let fields = line.split(maxSplits: 2, omittingEmptySubsequences: true, whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count == 3, Int(fields[0]) != nil, UInt32(fields[1]) != nil else { throw fail() }
            rows += 1
            guard !blocked.contains(URL(fileURLWithPath: String(fields[2])).lastPathComponent) else { throw fail() }
        }
        guard rows > 0 else { throw fail() }
    }
    private static func exportPreferences() throws -> Data {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["export", "com.gaoseries.GaoYouJian", "-"]
        let output = Pipe(); process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
        do {
            while true {
                let count = read(output.fileHandleForReading.fileDescriptor, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                guard count >= 0, bytes.count + max(0, count) <= maximum else { throw fail() }
                if count == 0 { break }; bytes.append(contentsOf: buffer.prefix(count))
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0, !bytes.isEmpty else { throw fail() }
            return bytes
        } catch {
            if process.isRunning { process.terminate() }
            process.waitUntilExit(); throw error
        }
    }
    private struct PlanOutput: Encodable {
        let plan: PortalMailUIOnlyBootstrapPlan
        let absencePlanSHA256: String
    }
    static func main() {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            let planOnly = args == ["--plan"]
            guard planOnly || (args.count == 10 && args[0] == "--apply" && args[1] == "--source-retired"
                && args[2] == "--authority" && args[4] == "--backup-receipt" && args[6] == "--user-authorization-proof"
                && args[8] == "--fence-receipt"), let defaults = UserDefaults(suiteName: "cn.mendao.launcher") else { throw fail() }
            let home = FileManager.default.homeDirectoryForCurrentUser
            if planOnly {
                stage = "plan"
                let plan = try PortalMailUIOnlyBootstrap.plan(homeURL: home, sourcePreferencesExport: exportPreferences(), targetDefaults: defaults)
                let result = PlanOutput(plan: plan, absencePlanSHA256: PortalMailUIOnlyBootstrap.digest(try PortalMailUIOnlyBootstrap.encoded(plan)))
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                FileHandle.standardOutput.write(try encoder.encode(result)); FileHandle.standardOutput.write(Data("\n".utf8)); return
            }
            stage = "proof-records"
            let authority = try local(args[3]), backup = try local(args[5]), human = try local(args[7]), fence = try local(args[9])
            stage = "apply"
            let receipt = try PortalMailUIOnlyBootstrap.prepare(homeURL: home, sourcePreferencesExport: exportPreferences,
                authorityBytes: authority, backupReceipt: backup, userAuthorizationProof: human, fenceReceipt: fence, targetDefaults: defaults,
                trustedHumanAuthorizationFactSHA256: MailUIOnlyBootstrapPinnedAuthorization.sha256,
                operationalGuard: operationalGuard, checkpoint: { stage = $0 })
            guard receipt.newLibrary, !receipt.dataMigrated else { throw fail() }
            print("已按本人明确授权创建新的邮件资料库并继承兼容界面偏好；newLibrary=true，dataMigrated=false。")
            print("原钥匙串未读取或更改，没有连接邮箱、同步或发信。")
        } catch {
            // Underlying errors may include paths or preference data. They are
            // never printed; interrupted evidence stays for Root inspection.
            let category: String
            if error is DecodingError { category = "decoding" }
            else if error is MailAppError { category = "condition-guard" }
            else {
                let detail = error as NSError
                category = detail.domain == NSPOSIXErrorDomain ? "posix-\(detail.code)" : "other-error"
            }
            fputs("邮件界面偏好初始化未完成（stage=\(stage), type=\(category)）；保留来源、目标、未完成证据与实际备份，不以空库迁移重试。\n", stderr)
            exit(1)
        }
    }
}
