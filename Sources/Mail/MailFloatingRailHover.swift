import Foundation

/// A collapsed rail needs a timer only while the pointer is dwelling inside it.
enum MailFloatingRailHover: Equatable {
    case idle
    case needsExit
    case dwelling(until: TimeInterval)

    enum Action: Equatable {
        case cancel
        case wait(until: TimeInterval)
        case reveal
    }

    static let delay: TimeInterval = 0.28

    mutating func update(isInside: Bool, now: TimeInterval) -> Action {
        guard isInside else {
            self = .idle
            return .cancel
        }
        switch self {
        case .idle:
            let deadline = now + Self.delay
            self = .dwelling(until: deadline)
            return .wait(until: deadline)
        case .needsExit:
            return .cancel
        case .dwelling(let deadline):
            return now >= deadline ? .reveal : .wait(until: deadline)
        }
    }
}
