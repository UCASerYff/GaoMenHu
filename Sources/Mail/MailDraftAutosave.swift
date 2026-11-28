import Foundation

/// Tracks which exact composer contents have made it through local persistence.
struct MailDraftAutosave {
    enum Status: Equatable {
        case untouched
        case pending
        case saving
        case saved(Date)
        case failed(String)
    }

    private var checkpoint: MailDraft?
    private(set) var status: Status

    init(saved: MailDraft?) {
        checkpoint = saved
        status = saved.map { .saved($0.updatedAt) } ?? .untouched
    }

    @discardableResult
    mutating func markEdited(_ draft: MailDraft) -> Bool {
        if let saved = matchingCheckpoint(draft) {
            status = .saved(saved.updatedAt)
            return false
        }
        status = .pending
        return true
    }

    @discardableResult
    mutating func flush(_ draft: MailDraft, forceWrite: Bool = false, write: (MailDraft) throws -> Date) -> Bool {
        if !forceWrite, let saved = matchingCheckpoint(draft) {
            status = .saved(saved.updatedAt)
            return true
        }
        status = .saving
        do {
            let savedAt = try write(draft)
            var saved = draft
            saved.updatedAt = savedAt
            checkpoint = saved
            status = .saved(savedAt)
            return true
        } catch {
            status = .failed(error.localizedDescription)
            return false
        }
    }

    private func matchingCheckpoint(_ draft: MailDraft) -> MailDraft? {
        guard let checkpoint else { return nil }
        var candidate = draft
        candidate.updatedAt = checkpoint.updatedAt
        return candidate == checkpoint ? checkpoint : nil
    }
}
