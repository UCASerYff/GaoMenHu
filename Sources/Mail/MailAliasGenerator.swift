import Foundation

public struct AliasRuleOptions: Equatable {
    public var useDots: Bool = true
    public var usePlus: Bool = true
    public var useGooglemailDomain: Bool = false
    public var plusTag: String = ""
    public var randomPlusCount: Int = 4

    public init(
        useDots: Bool = true,
        usePlus: Bool = true,
        useGooglemailDomain: Bool = false,
        plusTag: String = "",
        randomPlusCount: Int = 4
    ) {
        self.useDots = useDots
        self.usePlus = usePlus
        self.useGooglemailDomain = useGooglemailDomain
        self.plusTag = plusTag
        self.randomPlusCount = randomPlusCount
    }
}

public enum AliasGenerator {
    /// Generates aliases for a given email address according to its provider type and options.
    public static func generate(
        email: String,
        count: Int = 20,
        options: AliasRuleOptions = AliasRuleOptions()
    ) -> [String] {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("@") else { return [] }
        let parts = trimmed.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return [] }

        let rawUser = String(parts[0])
        let rawDomain = String(parts[1]).lowercased()

        let isGmail = rawDomain == "gmail.com" || rawDomain == "googlemail.com"

        if isGmail {
            return generateGmailAliases(rawUser: rawUser, domain: rawDomain, count: count, options: options)
        } else {
            return generateGenericPlusAliases(rawUser: rawUser, domain: rawDomain, count: count, options: options)
        }
    }

    /// Generates a single dedicated alias for a specific platform/service name.
    public static func makeServiceAlias(email: String, service: String) -> String {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("@") else { return email }
        let parts = trimmed.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return email }

        let rawUser = String(parts[0])
        let baseUser = rawUser.split(separator: "+")[0] // Strip any previous +tag
        let rawDomain = String(parts[1])

        // Sanitize service name to be alphanumeric
        var cleanTag = service.lowercased()
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
        if let firstSegment = cleanTag.split(separator: "/").first {
            cleanTag = String(firstSegment)
        }
        // If domain format like github.com, extract base name (github)
        if cleanTag.contains(".") {
            let parts = cleanTag.split(separator: ".")
            if let first = parts.first, !first.isEmpty {
                cleanTag = String(first)
            }
        }
        let tagAllowed = cleanTag.replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
        let tag = tagAllowed.isEmpty ? "service" : tagAllowed

        return "\(baseUser)+\(tag)@\(rawDomain)"
    }

    private static func generateGmailAliases(
        rawUser: String,
        domain: String,
        count: Int,
        options: AliasRuleOptions
    ) -> [String] {
        // Strip existing dots and plus tag to get canonical local part
        let withoutPlus = String(rawUser.split(separator: "+")[0])
        let base = withoutPlus.replacingOccurrences(of: ".", with: "").lowercased()
        guard !base.isEmpty else { return [] }

        var results = Set<String>()
        results.insert("\(base)@gmail.com")
        if options.useGooglemailDomain {
            results.insert("\(base)@googlemail.com")
        }

        let chars = Array(base)
        let maxAttempts = max(count * 30, 2000)
        let pool = Array("abcdefghijklmnopqrstuvwxyz0123456789")

        for _ in 0..<maxAttempts {
            if results.count >= count { break }
            var local = base

            // 1. Dot Insertion
            if options.useDots && chars.count >= 2 {
                var modified = ""
                for (idx, char) in chars.enumerated() {
                    modified.append(char)
                    if idx < chars.count - 1 && Bool.random() {
                        modified.append(".")
                    }
                }
                local = modified
            }

            // 2. Plus Suffix
            if options.usePlus {
                let tag: String
                if !options.plusTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    tag = options.plusTag.trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    let len = max(2, options.randomPlusCount)
                    tag = String((0..<len).map { _ in pool.randomElement()! })
                }
                local = "\(local)+\(tag)"
            }

            let targetDomain = (options.useGooglemailDomain && Bool.random()) ? "googlemail.com" : "gmail.com"
            results.insert("\(local)@\(targetDomain)")
        }

        return Array(results.prefix(count))
    }

    private static func generateGenericPlusAliases(
        rawUser: String,
        domain: String,
        count: Int,
        options: AliasRuleOptions
    ) -> [String] {
        let withoutPlus = String(rawUser.split(separator: "+")[0])
        guard !withoutPlus.isEmpty else { return [] }

        var results = Set<String>()
        results.insert("\(withoutPlus)@\(domain)")

        let pool = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        let maxAttempts = max(count * 20, 1000)

        for _ in 0..<maxAttempts {
            if results.count >= count { break }
            let tag: String
            if !options.plusTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let suffix = String((0..<3).map { _ in pool.randomElement()! })
                tag = "\(options.plusTag)\(suffix)"
            } else {
                let len = max(3, options.randomPlusCount)
                tag = String((0..<len).map { _ in pool.randomElement()! })
            }
            results.insert("\(withoutPlus)+\(tag)@\(domain)")
        }

        return Array(results.prefix(count))
    }
}
