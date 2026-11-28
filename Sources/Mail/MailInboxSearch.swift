import Foundation

enum MailInboxFilter: String, CaseIterable, Hashable, Identifiable {
    case all, unread, starred, attachments

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "全部"
        case .unread: return "未读"
        case .starred: return "星标"
        case .attachments: return "有附件"
        }
    }

    fileprivate func includes(_ message: CachedMessage) -> Bool {
        switch self {
        case .all: return true
        case .unread: return !message.isRead
        case .starred: return message.isFlagged
        case .attachments: return !message.attachments.isEmpty
        }
    }
}

struct MailInboxSearchResult {
    let messages: [CachedMessage]
    let scopedCount: Int
    let headerOnlyCount: Int
    let hasQuery: Bool
    private let counts: [MailInboxFilter: Int]

    /// Counts are for matches to the query in the current account and folder scope.
    func count(for filter: MailInboxFilter) -> Int { counts[filter, default: 0] }

    static func search(_ cached: [CachedMessage], accountIDs: Set<UUID>, mailbox: UUID?, folder: String,
                       query: String, filter: MailInboxFilter) -> Self {
        let terms: [String] = query.split(whereSeparator: \.isWhitespace).map { String($0) }
        let inbox = folder.caseInsensitiveCompare("INBOX") == .orderedSame
        var scopedCount = 0
        var headerOnlyCount = 0
        var matches: [CachedMessage] = []
        var counts: [MailInboxFilter: Int] = [:]

        for message in cached {
            guard accountIDs.contains(message.accountID), mailbox == nil || message.accountID == mailbox else { continue }
            guard message.folder == folder || (inbox && message.folder.caseInsensitiveCompare("INBOX") == .orderedSame) else { continue }
            scopedCount += 1
            if !message.loaded { headerOnlyCount += 1 }
            guard terms.isEmpty || matchesQuery(terms, in: message) else { continue }
            for category in MailInboxFilter.allCases where category.includes(message) {
                counts[category, default: 0] += 1
            }
            if filter.includes(message) { matches.append(message) }
        }

        matches.sort { left, right in
            if left.date == right.date { return left.id < right.id }
            return left.date > right.date
        }
        return Self(messages: matches, scopedCount: scopedCount, headerOnlyCount: headerOnlyCount,
                    hasQuery: !terms.isEmpty, counts: counts)
    }

    private static func matchesQuery(_ terms: [String], in message: CachedMessage) -> Bool {
        let textFields = [message.subject, message.from, message.to, message.cc, message.replyTo ?? "", message.body, message.preview]
        let remaining = terms.filter { term in
            !textFields.contains { $0.localizedStandardContains(term) } &&
                !message.attachments.contains { $0.filename.localizedStandardContains(term) }
        }
        if remaining.isEmpty { return true }

        // Use the alternate HTML part when there is no plain body. This only
        // strips the cached markup and never creates a web view or resolves URLs.
        guard let html = message.html, message.body.allSatisfy(\.isWhitespace) else { return false }
        let text = CodeExtractor.stripHtml(html)
        return remaining.allSatisfy { text.localizedStandardContains($0) }
    }
}
