import Foundation

@main struct MailDraftAutosaveTests {
    enum FixtureError: LocalizedError {
        case blocked, assertion(String)

        var errorDescription: String? {
            switch self {
            case .blocked: return "synthetic local write failure"
            case .assertion(let label): return label
            }
        }
    }

    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let destination = root.appendingPathComponent("Draft.json")
        var checks = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
            guard try condition() else { throw FixtureError.assertion(label) }
            checks += 1
        }

        var draftsWritten: [MailDraft] = []
        var fail = false
        let now = Date(timeIntervalSince1970: 18_000)
        func write(_ draft: MailDraft) throws -> Date {
            draftsWritten.append(draft)
            if fail { throw FixtureError.blocked }
            var saved = draft
            saved.updatedAt = now
            try JSONEncoder().encode(saved).write(to: destination, options: .atomic)
            return saved.updatedAt
        }
        func read() throws -> MailDraft {
            try JSONDecoder().decode(MailDraft.self, from: Data(contentsOf: destination))
        }

        let initial = MailDraft(from: "sender@example.invalid", to: "recipient@example.invalid", updatedAt: .distantPast)
        var autosave = MailDraftAutosave(saved: nil)
        try check(autosave.status == .untouched && draftsWritten.isEmpty, "opening a new draft does not write")
        var latest = initial
        latest.subject = "First edit"
        try check(autosave.markEdited(latest) && autosave.status == .pending, "first edit marks pending")
        latest.subject = "Most recent subject"
        latest.body = "Local fixture body"
        latest.attachments = [DraftAttachment(path: "/isolation/fixture.txt")]
        try check(autosave.markEdited(latest) && draftsWritten.isEmpty, "rapid edits do not write interim snapshots")
        try check(autosave.flush(latest, write: write) && autosave.status == .saved(now), "successful write marks snapshot saved")
        let firstSaved = try read()
        try check(draftsWritten == [latest] && firstSaved.id == initial.id && firstSaved.subject == latest.subject && firstSaved.attachments == latest.attachments,
                  "only latest body and attachment references reach local storage")

        var reopened = MailDraftAutosave(saved: firstSaved)
        try check(reopened.status == .saved(now) && !reopened.markEdited(latest), "reopen recognises persisted snapshot regardless of timestamp")
        try check(reopened.flush(latest, write: write) && draftsWritten.count == 1, "unchanged autosave avoids duplicate writes")

        var edited = latest
        edited.bcc = "other@example.invalid"
        edited.body = "New body to retry"
        try check(reopened.markEdited(edited), "changing a saved draft clears the old saved status")
        fail = true
        try check(!reopened.flush(edited, write: write) && reopened.status == .failed("synthetic local write failure"), "failed local write remains actionable")
        try check(try read() == firstSaved, "failed update leaves the previous durable draft intact")
        fail = false
        try check(reopened.flush(edited, forceWrite: true, write: write) && reopened.status == .saved(now), "explicit retry writes current contents")
        let retried = try read()
        try check(retried.id == initial.id && retried.body == edited.body && retried.bcc == edited.bcc && retried.attachments == edited.attachments,
                  "retry retains ID and current draft contents")

        var discardedChanges = edited
        discardedChanges.attachments = []
        try check(reopened.markEdited(discardedChanges) && !reopened.markEdited(edited) && reopened.status == .saved(now), "reverting unsaved edits restores exact checkpoint")
        fail = true
        try check(!reopened.flush(edited, forceWrite: true, write: write) && reopened.status == .failed("synthetic local write failure"),
                  "explicit close still reports a failed local write when the checkpoint matches")
        fail = false
        try check(reopened.flush(edited, forceWrite: true, write: write) && reopened.status == .saved(now), "close can be retried even for an unchanged snapshot")
        print("Mail draft autosave: \(checks) isolated assertions passed")
    }
}
