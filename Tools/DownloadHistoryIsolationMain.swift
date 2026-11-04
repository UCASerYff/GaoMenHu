import Foundation
import AppKit
import Darwin

/// Private coordinated tool; the two immutable approval digests are injected at
/// build time from Root's independently verified private facts, never from argv.
@main struct DownloadHistoryIsolationMain {
    private static var phase = "arguments"
    private static var role = "download-history-isolation"
    private static func fail() -> DownloadError { .message("隔离迁移前提未满足。") }
    private static func capture(_ executable: String, _ arguments: [String]) throws -> Data {
        let task = Process(); task.executableURL = URL(fileURLWithPath: executable); task.arguments = arguments
        let pipe = Pipe(); task.standardOutput = pipe; task.standardError = FileHandle.nullDevice
        try task.run()
        var output = Data(), buffer = [UInt8](repeating: 0, count: 65536)
        do {
            while true {
                let count = Darwin.read(pipe.fileHandleForReading.fileDescriptor, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                guard count >= 0, output.count + max(0, count) <= 32 * 1024 * 1024 else { throw fail() }
                if count == 0 { break }; output.append(contentsOf: buffer.prefix(count))
            }
            task.waitUntilExit(); guard task.terminationStatus == 0 else { throw fail() }
            return output
        } catch {
            if task.isRunning { task.terminate() }; task.waitUntilExit(); throw error
        }
    }
    private static func maintenance() throws {
        phase = "actual-maintenance-observation"
        var metadata = stat()
        let exists = lstat("/Applications/搞下载.app", &metadata) == 0
        guard !exists, errno == ENOENT else { throw fail() }
        let forbidden = ["com.gaoseries.GaoXiaZai", "cn.mendao.launcher", "cn.mendao.bridge"]
        guard !NSWorkspace.shared.runningApplications.contains(where: {
            guard let bid = $0.bundleIdentifier else { return false }
            return forbidden.contains(where: { bid == $0 || bid.hasPrefix($0 + ".") })
        }) else { throw fail() }
        let raw = try capture("/bin/ps", ["-ww", "-axo", "pid=,comm="])
        guard let text = String(data: raw, encoding: .utf8), !text.isEmpty else { throw fail() }
        for line in text.split(separator: "\n") {
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 2, let pid = Int32(parts[0]) else { throw fail() }
            if pid == getpid() { continue }
            let path = String(parts[1]).trimmingCharacters(in: .whitespaces)
            let name = URL(fileURLWithPath: path).lastPathComponent
            let appPath = ["/搞下载.app/", "/GaoXiaZai.app/", "/搞门户.app/", "/门道.app/"].contains { path.contains($0) }
            let host = ["GaoXiaZai", "搞下载", "MenDao", "MenDaoBridge", "GaoMenHu", "搞门户"].contains(name)
            let widget = name.hasPrefix("GaoXiaZai") && (name.contains("Widget") || name.contains("Intent"))
            guard !appPath, !host, !widget else { throw fail() }
        }
    }
    static func main() {
        do {
            let args = Array(CommandLine.arguments.dropFirst()), planning = args == ["--plan"]
            guard planning || (args.count == 12 && args[0] == "--apply" && args[1] == "--source-retired"
                && args[2] == "--authority" && args[4] == "--approved-snapshot" && args[6] == "--human-authorization"
                && args[8] == "--fence-receipt" && args[10] == "--backup-receipt") else { throw fail() }
            guard getuid() != 0, geteuid() == getuid() else { throw fail() }
            let home = FileManager.default.homeDirectoryForCurrentUser
            let source = home.appendingPathComponent("Library/Application Support/GaoSeries/GaoXiaZai", isDirectory: true)
            let target = home.appendingPathComponent("Library/Application Support/MenDao/DownloadCenter", isDirectory: true)
            phase = "source-preferences-export"
            let preferences = try capture("/usr/bin/defaults", ["export", "com.gaoseries.GaoXiaZai", "-"])
            if planning {
                phase = "read-only-source-plan"
                let plan = try PortalDownloadHistoryIsolation.preflight(legacyRootURL: source, sourcePreferences: preferences)
                // The authority binds this canonical byte encoding, not the pretty-printed console representation.
                let raw = try PortalDownloadHistoryIsolation.encoded(plan)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let envelope = PlanOutput(planSHA256: downloadDigest(raw), plan: plan)
                FileHandle.standardOutput.write(try encoder.encode(envelope)); FileHandle.standardOutput.write(Data("\n".utf8)); return
            }
            phase = "authority-records-read"
            func record(_ index: Int) throws -> Data {
                return try PortalDownloadHistoryIsolation.readRecord(PortalDownloadHistoryIsolation.recordURL(args[index]))
            }
            let authority = try JSONDecoder().decode(PortalDownloadHistoryIsolation.Authority.self, from: record(3))
            let snapshot = try record(5), human = try record(7), fence = try record(9), backup = try record(11)
            guard let defaults = UserDefaults(suiteName: "cn.mendao.launcher") else { throw fail() }
            phase = "qualified-history-apply"
            let receipt = try PortalDownloadHistoryIsolation.prepare(destinationRootURL: target, legacyRootURL: source,
                sourcePreferences: preferences, authority: authority, approvedSnapshot: snapshot, humanAuthorization: human,
                fenceReceipt: fence, backupReceipt: backup,
                trustedApprovedSnapshotSHA256: PortalHistoryIsolationBuildPin.approvedSnapshotSHA256,
                trustedHumanAuthorizationFactSHA256: PortalHistoryIsolationBuildPin.humanFactSHA256,
                targetDefaults: defaults, maintenanceGuard: { try maintenance(); phase = "qualified-history-apply" })
            print("资料已迁入；\(receipt.plan.verifiedCompleteRecordIDs.count) 条完整历史，\(receipt.plan.exactApprovedRecords.count) 条缺件历史仅隔离保留。")
            print("sourceFullyVerified=false；缺失原包未恢复，不可执行、重试、授权或重发。原目录需本人重新授权。")
        } catch {
            let ns = error as NSError
            let record: [String: Any] = ["status": "BLOCKED_NOT_A_FULL_PASS", "phase": phase, "role": role,
                "errorType": String(reflecting: type(of: error)), "posixErrno": ns.domain == NSPOSIXErrorDomain ? ns.code as Any : NSNull()]
            if let raw = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) {
                FileHandle.standardError.write(raw); FileHandle.standardError.write(Data("\n".utf8))
            }
            exit(1)
        }
    }
    private struct PlanOutput: Codable {
        let planSHA256: String
        let plan: PortalDownloadHistoryIsolation.Plan
    }
}
