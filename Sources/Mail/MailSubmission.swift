import Foundation

/// Only irreversible-attempt metadata lives here. Body, recipients, attachment
/// bytes and credentials remain in their original Library/cache/Keychain stores.
enum MailSubmissionPhase: String, Codable, Hashable { case pending, accepted, completed }
struct MailSubmissionState: Equatable {
    let draftID: UUID
    let phase: MailSubmissionPhase
    let acceptedAt: Date?
    let warning: String?
}
enum MailSubmissionLocalStep: Equatable { case cache, library }
struct MailSubmissionRecord: Codable, Equatable {
    var draftID: UUID
    var accountID: UUID
    var draftDigest: String
    var receiptDigest: String
    var phase: MailSubmissionPhase = .pending
    var attemptedAt: Date
    var acceptedAt: Date?
    var sentCopyFailed = false
    var receiptID: String { accountID.uuidString + "|local|" + draftID.uuidString }
    var state: MailSubmissionState {
        MailSubmissionState(draftID: draftID, phase: phase, acceptedAt: acceptedAt,
            warning: sentCopyFailed ? "服务商已接受邮件，但其已发送文件夹副本保存失败；请核对服务商，切勿重发。" : nil)
    }
    static func digest(of draft: MailDraft) throws -> String {
        var canonical = draft; canonical.updatedAt = .distantPast
        return MailStorage.digest(try MailStorage.encoder.encode(canonical))
    }
    static func digest(of receipt: CachedMessage) throws -> String { MailStorage.digest(try MailStorage.encoder.encode(receipt)) }
    func matchesDraft(_ value: MailDraft) throws -> Bool {
        guard value.id == draftID, value.accountID == accountID else { return false }
        return try Self.digest(of: value) == draftDigest
    }
    func matchesReceipt(_ value: CachedMessage) throws -> Bool {
        guard value.id == receiptID, value.accountID == accountID else { return false }
        return try Self.digest(of: value) == receiptDigest
    }
}
struct MailSubmissionLedger: Codable {
    var schemaVersion = 1
    var records: [MailSubmissionRecord] = []
    static let maximumBytes = 16 * 1024 * 1024
    static func decode(_ bytes: Data) throws -> MailSubmissionLedger {
        guard bytes.count <= maximumBytes else { throw MailAppError.message("本机发送事务超过安全读取预算，未发送邮件。") }
        let ledger = try MailStorage.decoder.decode(Self.self, from: bytes)
        guard ledger.schemaVersion == 1, ledger.records.count <= 10_000,
              Set(ledger.records.map(\.draftID)).count == ledger.records.count else {
            throw MailAppError.message("本机发送事务版本、数量或标识无效，已阻止重复发送。")
        }
        func validDigest(_ value: String) -> Bool { value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
        for record in ledger.records {
            guard validDigest(record.draftDigest), validDigest(record.receiptDigest),
                  (record.phase == .pending) == (record.acceptedAt == nil) else {
                throw MailAppError.message("本机发送事务摘要或阶段无效，已阻止重复发送。")
            }
        }
        return ledger
    }
}
