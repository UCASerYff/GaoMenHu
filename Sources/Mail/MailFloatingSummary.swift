import Foundation

/// A snapshot of the locally cached inbox, independent of the main window's
/// identity, folder and search filters. Enabling mail does not imply that an
/// account has been authorized or that a sync has succeeded.
struct MailFloatingSummary {
    let accounts: [MailAccount]
    let selectedAccount: MailAccount?
    let scopeAccounts: [MailAccount]
    let unreadCount: Int
    let enabledCount: Int
    /// Accounts in the current scope configured for registration only.
    let registeredCount: Int
    let errorCount: Int
    let latestSync: Date?
    /// At most three newest locally cached unread inbox messages.
    let unreadMessages: [CachedMessage]
    private let unreadCounts: [UUID: Int]
    init(library: MailLibrary, messages: [CachedMessage], accountID: UUID? = nil) {
        accounts = library.accounts
        selectedAccount = accountID.flatMap { id in library.accounts.first { $0.id == id } }
        // A removed selection falls back to all remaining accounts.
        scopeAccounts = selectedAccount.map { [$0] } ?? library.accounts
        let knownIDs = Set(library.accounts.map(\.id))
        let scopeIDs = Set(scopeAccounts.map(\.id))
        let unread = messages.filter { Self.isUnreadCachedInbox($0, among: knownIDs) }
        unreadCounts = unread.reduce(into: [:]) { counts, message in
            counts[message.accountID, default: 0] += 1
        }
        let scopedUnread = unread.filter { scopeIDs.contains($0.accountID) }
        unreadCount = scopedUnread.count
        unreadMessages = Array(scopedUnread.sorted {
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.id < $1.id
        }.prefix(3))
        enabledCount = scopeAccounts.filter(\.enabled).count
        registeredCount = scopeAccounts.count - enabledCount
        errorCount = scopeAccounts.filter(Self.hasSyncError).count
        latestSync = scopeAccounts.compactMap(\.lastSync).max()
    }

    /// Per-account badges always describe that account, irrespective of the
    /// selected scope, and exclude messages belonging to removed accounts.
    func unreadCount(for accountID: UUID) -> Int { unreadCounts[accountID, default: 0] }

    static func isUnreadCachedInbox(_ message: CachedMessage, among accountIDs: Set<UUID>) -> Bool {
        accountIDs.contains(message.accountID) && message.folder.lowercased() == "inbox" && !message.isRead
    }

    static func hasSyncError(_ account: MailAccount) -> Bool {
        !(account.syncError ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func latestSyncLabel(for latestSync: Date?, now: Date) -> String {
        guard let latestSync else { return "尚未同步" }
        let elapsed = max(0, now.timeIntervalSince(latestSync))
        if elapsed < 60 { return "刚刚同步" }
        if elapsed < 3_600 { return "\(Int(elapsed / 60)) 分钟前同步" }
        if elapsed < 86_400 { return "\(Int(elapsed / 3_600)) 小时前同步" }
        if elapsed < 604_800 { return "\(Int(elapsed / 86_400)) 天前同步" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy/MM/dd HH:mm"
        return "同步于 " + formatter.string(from: latestSync)
    }
}

struct MailFloatingRailStatus: Equatable {
    let hasUnread: Bool
    let needsAttention: Bool

    init(accounts: [MailAccount] = [], messages: [CachedMessage] = [], hasProblem: Bool = false) {
        let accountIDs = Set(accounts.map(\.id))
        hasUnread = messages.contains { MailFloatingSummary.isUnreadCachedInbox($0, among: accountIDs) }
        needsAttention = hasProblem || accounts.contains(where: MailFloatingSummary.hasSyncError)
    }
}
