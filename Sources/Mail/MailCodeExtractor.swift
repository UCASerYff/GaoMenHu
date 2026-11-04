import Foundation

public struct ExtractedCode: Equatable, Sendable, Identifiable {
    public enum CodeType: String, Equatable, Sendable {
        case numeric
        case alphanumeric
        case link
    }
    public var id: String { value }
    public var type: CodeType
    public var value: String
    public var confidence: Double
    public var context: String

    public var isLink: Bool { type == .link }
    public var displayTitle: String {
        switch type {
        case .numeric: return "数字验证码"
        case .alphanumeric: return "动态验证码"
        case .link: return "验证激活链接"
        }
    }
}

public enum CodeExtractor {
    private static let codeKeywords = "(?i)验证码|verification|verify|code|otp|pin|passcode|one.?time|确认码|安全码|动态码|captcha|校验码"
    private static let linkKeywords = "(?i)verify|confirm|activate|token|click|validate|magic|login|auth|reset"
    private static let unsubscribeKeywords = "(?i)unsubscribe|退订|opt-?out"
    private static let phoneKeywords = "(?i)phone|电话|手机|tel|fax"
    private static let moneyKeywords = "(?i)[\\$¥€£]|价格|金额|amount|price|total|fee|cost|¥|rmb"
    private static let zipKeywords = "(?i)zip|postal|邮编"

    public static func extract(subject: String, body: String, html: String? = nil) -> [ExtractedCode] {
        let plainText = body.isEmpty ? (html.map(stripHtml) ?? "") : body
        let fullText = "\(subject)\n\(plainText)"

        var results: [ExtractedCode] = []
        results.append(contentsOf: extractNumeric(from: fullText))
        results.append(contentsOf: extractAlphanumeric(from: fullText))
        if let htmlContent = html, !htmlContent.isEmpty {
            results.append(contentsOf: extractLinks(from: htmlContent))
        } else {
            results.append(contentsOf: extractPlainTextLinks(from: fullText))
        }

        results.sort { $0.confidence > $1.confidence }

        var seen = Set<String>()
        return results.filter { item in
            if seen.contains(item.value) { return false }
            seen.insert(item.value)
            return true
        }
    }

    public static func primaryCode(subject: String, body: String, html: String? = nil) -> ExtractedCode? {
        let all = extract(subject: subject, body: body, html: html)
        // Prefer explicit numeric or alphanumeric code over link
        if let firstCode = all.first(where: { $0.type != .link && $0.confidence >= 0.5 }) {
            return firstCode
        }
        return all.first
    }

    private static func extractNumeric(from text: String) -> [ExtractedCode] {
        var list: [ExtractedCode] = []
        let pattern = "\\b(\\d{4,8})\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return list }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        for match in matches {
            guard match.numberOfRanges > 1 else { continue }
            let valRange = match.range(at: 1)
            let value = nsText.substring(with: valRange)
            let ctx = extractContext(from: text, matchRange: match.range)

            // Skip year representations 2020..2039
            if let year = Int(value), year >= 2020 && year <= 2039 { continue }
            if containsRegex(phoneKeywords, in: ctx) { continue }
            if containsRegex(moneyKeywords, in: ctx) { continue }
            if value.count == 5 && containsRegex(zipKeywords, in: ctx) { continue }

            var confidence = 0.3
            if containsRegex(codeKeywords, in: ctx) { confidence = 0.90 }
            if value.count == 6 { confidence += 0.05 }
            if containsRegex("[:：]\\s*\\d", in: ctx) { confidence += 0.05 }

            list.append(ExtractedCode(
                type: .numeric,
                value: value,
                confidence: min(confidence, 1.0),
                context: ctx
            ))
        }
        return list
    }

    private static func extractAlphanumeric(from text: String) -> [ExtractedCode] {
        var list: [ExtractedCode] = []
        let pattern = "\\b([A-Za-z0-9]{4,10})\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return list }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        for match in matches {
            guard match.numberOfRanges > 1 else { continue }
            let valRange = match.range(at: 1)
            let value = nsText.substring(with: valRange)

            // Must contain both letters and digits to be alphanumeric
            let hasLetter = value.rangeOfCharacter(from: .letters) != nil
            let hasNumber = value.rangeOfCharacter(from: .decimalDigits) != nil
            guard hasLetter && hasNumber else { continue }

            let ctx = extractContext(from: text, matchRange: match.range)
            guard containsRegex(codeKeywords, in: ctx) else { continue }

            list.append(ExtractedCode(
                type: .alphanumeric,
                value: value,
                confidence: 0.75,
                context: ctx
            ))
        }
        return list
    }

    private static func extractLinks(from html: String) -> [ExtractedCode] {
        var list: [ExtractedCode] = []
        let pattern = "(?i)href=[\"']([^\"']+)[\"']"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return list }
        let nsHtml = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: nsHtml.length))

        for match in matches {
            guard match.numberOfRanges > 1 else { continue }
            let urlRaw = nsHtml.substring(with: match.range(at: 1))
            let url = decodeHtmlEntities(urlRaw)
            guard url.lowercased().hasPrefix("http") else { continue }
            guard containsRegex(linkKeywords, in: url) else { continue }
            guard !containsRegex(unsubscribeKeywords, in: url) else { continue }

            var confidence = 0.65
            if containsRegex("(?i)verify|confirm|activate", in: url) { confidence = 0.88 }
            if containsRegex("(?i)magic|login.*token|auth.*token", in: url) { confidence = 0.85 }
            if containsRegex("(?i)token=|code=|key=", in: url) { confidence += 0.08 }

            let shortContext = String(url.prefix(80))
            list.append(ExtractedCode(
                type: .link,
                value: url,
                confidence: min(confidence, 1.0),
                context: shortContext
            ))
        }
        return list
    }

    private static func extractPlainTextLinks(from text: String) -> [ExtractedCode] {
        var list: [ExtractedCode] = []
        let pattern = "(?i)https?://[^\\s<>\"'\\]\\)]+"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return list }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        for match in matches {
            let url = nsText.substring(with: match.range)
            guard containsRegex(linkKeywords, in: url) else { continue }
            guard !containsRegex(unsubscribeKeywords, in: url) else { continue }

            var confidence = 0.60
            if containsRegex("(?i)verify|confirm|activate", in: url) { confidence = 0.85 }
            list.append(ExtractedCode(
                type: .link,
                value: url,
                confidence: min(confidence, 1.0),
                context: String(url.prefix(80))
            ))
        }
        return list
    }

    private static func extractContext(from text: String, matchRange: NSRange, radius: Int = 40) -> String {
        let nsText = text as NSString
        let start = max(0, matchRange.location - radius)
        let end = min(nsText.length, matchRange.location + matchRange.length + radius)
        let length = max(0, end - start)
        return nsText.substring(with: NSRange(location: start, length: length)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func containsRegex(_ pattern: String, in text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.firstMatch(in: text, range: range) != nil
    }

    public static func stripHtml(_ html: String) -> String {
        var text = html
        text = text.replacingOccurrences(of: "(?is)<style[^>]*>.*?</style>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?is)<script[^>]*>.*?</script>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        text = decodeHtmlEntities(text)
        return text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func decodeHtmlEntities(_ value: String) -> String {
        var str = value
        str = str.replacingOccurrences(of: "&nbsp;", with: " ")
        str = str.replacingOccurrences(of: "&amp;", with: "&")
        str = str.replacingOccurrences(of: "&quot;", with: "\"")
        str = str.replacingOccurrences(of: "&#39;", with: "'")
        str = str.replacingOccurrences(of: "&lt;", with: "<")
        str = str.replacingOccurrences(of: "&gt;", with: ">")
        return str
    }
}
