import Foundation
import ImageIO
import UniformTypeIdentifiers
import AppKit

struct WebsiteIcon {
    let dataURL: String
    /// The original bitmap's shortest side, before any downsampling.
    let sourcePixels: Int
}

struct IconCandidate {
    let url: URL
    let suggestedPixels: Int
}

enum IconDocument {
    static let maximumImageBytes = 4 * 1024 * 1024

    static func safeURL(_ value: String, relativeTo base: URL? = nil) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 4096,
              !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let url = URL(string: trimmed, relativeTo: base)?.absoluteURL,
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: true),
              parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil else { return nil }
        parts.fragment = nil
        return parts.url
    }

    /// Never request a saved bookmark's path, login parameters, or fragment.
    static func rootURL(_ value: String) -> URL? {
        guard var parts = URLComponents(string: value),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              parts.user == nil, parts.password == nil else { return nil }
        if parts.scheme?.lowercased() == "http", parts.port == 80 { parts.port = nil }
        parts.scheme = "https"
        parts.path = "/"; parts.query = nil; parts.fragment = nil
        if parts.port == 443 { parts.port = nil }
        return parts.url.flatMap { safeURL($0.absoluteString) }
    }

    static func entities(_ value: String) -> String {
        var result = value.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
        let regex = try! NSRegularExpression(pattern: "&#(x[0-9a-f]+|[0-9]+);", options: .caseInsensitive)
        for match in regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
            guard let bodyRange = Range(match.range(at: 1), in: result), let fullRange = Range(match.range, in: result) else { continue }
            let body = String(result[bodyRange])
            let number = body.lowercased().hasPrefix("x") ? UInt32(body.dropFirst(), radix: 16) : UInt32(body)
            if let number, let scalar = UnicodeScalar(number) { result.replaceSubrange(fullRange, with: String(scalar)) }
        }
        return result
    }

    static func attributes(_ tag: String) -> [String: String] {
        let pattern = #"([a-zA-Z][a-zA-Z0-9:_-]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#
        let regex = try! NSRegularExpression(pattern: pattern)
        var values: [String: String] = [:]
        for match in regex.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)) {
            guard let key = Range(match.range(at: 1), in: tag) else { continue }
            for i in 2...4 where match.range(at: i).location != NSNotFound {
                if let range = Range(match.range(at: i), in: tag) { values[String(tag[key]).lowercased()] = entities(String(tag[range])); break }
            }
        }
        return values
    }

    static func pixels(_ sizes: String?) -> Int {
        guard let sizes else { return 0 }
        return sizes.lowercased().split(whereSeparator: { $0.isWhitespace }).compactMap { size -> Int? in
            let sides = size.split(separator: "x").compactMap { Int($0) }
            return sides.count == 2 ? min(sides[0], sides[1]) : nil
        }.max() ?? 0
    }

    static func links(_ html: String, base: URL) -> (icons: [IconCandidate], manifests: [URL]) {
        // Comments and script bodies are data, not declarations of page icons.
        let strip = try! NSRegularExpression(pattern: #"<!--[\s\S]*?-->|<script\b[^>]*>[\s\S]*?</script\s*>"#, options: .caseInsensitive)
        let clean = strip.stringByReplacingMatches(in: html, range: NSRange(html.startIndex..., in: html), withTemplate: "")
        let regex = try! NSRegularExpression(pattern: #"<link\b(?:[^>"']|"[^"]*"|'[^']*')*>"#, options: .caseInsensitive)
        var icons: [IconCandidate] = [], manifests: [URL] = []
        for match in regex.matches(in: clean, range: NSRange(clean.startIndex..., in: clean)).prefix(128) {
            guard let range = Range(match.range, in: clean) else { continue }
            let attrs = attributes(String(clean[range]))
            guard let href = attrs["href"], let url = safeURL(href, relativeTo: base) else { continue }
            let relations = Set((attrs["rel"] ?? "").lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init))
            if relations.contains("manifest") { manifests.append(url) }
            if !relations.isDisjoint(with: ["icon", "apple-touch-icon", "apple-touch-icon-precomposed"]) {
                let hint = max(pixels(attrs["sizes"]), relations.contains("apple-touch-icon") ? 180 : 0)
                icons.append(IconCandidate(url: url, suggestedPixels: hint))
            }
        }
        return (unique(icons), Array(NSOrderedSet(array: manifests).array.compactMap { $0 as? URL }.prefix(2)))
    }

    static func manifest(_ data: Data, base: URL) -> [IconCandidate] {
        guard data.count <= 512 * 1024,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let icons = object["icons"] as? [[String: Any]] else { return [] }
        return unique(icons.prefix(32).compactMap { item in
            guard let src = item["src"] as? String, let url = safeURL(src, relativeTo: base) else { return nil }
            return IconCandidate(url: url, suggestedPixels: pixels(item["sizes"] as? String))
        })
    }

    static func unique(_ candidates: [IconCandidate]) -> [IconCandidate] {
        var seen = Set<String>()
        return candidates.sorted { $0.suggestedPixels > $1.suggestedPixels }.filter { seen.insert($0.url.absoluteString).inserted }
    }

    static func decode(_ data: Data) -> WebsiteIcon? {
        guard !data.isEmpty, data.count <= maximumImageBytes else { return nil }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return decodeSVG(data) }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return decodeSVG(data) }
        guard count <= 64 else { return nil }
        var layers: [(index: Int, pixels: Int)] = []
        for index in 0..<count {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width >= 64, height >= 64, width <= 8192, height <= 8192,
                  width * height <= 16_777_216, max(width, height) <= min(width, height) * 4 else { continue }
            layers.append((index, min(width, height)))
        }
        // ICO frames can be listed smallest first. Decode the largest actual bitmap.
        for layer in layers.sorted(by: { $0.pixels > $1.pixels }) {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 256,
                kCGImageSourceShouldCacheImmediately: true
            ]
            guard let bitmap = CGImageSourceCreateThumbnailAtIndex(source, layer.index, options as CFDictionary),
                  bitmap.width >= 64, bitmap.height >= 64 else { continue }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, bitmap, nil)
            if CGImageDestinationFinalize(destination) {
                return WebsiteIcon(dataURL: "data:image/png;base64," + (output as Data).base64EncodedString(), sourcePixels: layer.pixels)
            }
        }
        return nil
    }

    private static func decodeSVG(_ data: Data) -> WebsiteIcon? {
        guard data.count <= 512 * 1024, let xml = String(data: data, encoding: .utf8),
              xml.range(of: "<svg", options: .caseInsensitive) != nil,
              xml.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil,
              xml.range(of: "<!ENTITY", options: .caseInsensitive) == nil else { return nil }
        let validator = StaticSVGValidator()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = validator
        guard parser.parse(), validator.valid, validator.sawSVG,
              let image = NSImage(data: data), image.size.width.isFinite, image.size.height.isFinite,
              image.size.width > 0, image.size.height > 0, image.size.width <= 8192, image.size.height <= 8192 else { return nil }
        let ratio = image.size.width / image.size.height
        guard ratio >= 0.25, ratio <= 4 else { return nil }
        let width = ratio >= 1 ? 256 : max(64, Int(256 * ratio))
        let height = ratio <= 1 ? 256 : max(64, Int(256 / ratio))
        image.size = NSSize(width: width, height: height)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let bitmap = context.makeImage() else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, bitmap, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        // Vectors have no original pixels; record the produced bitmap resolution.
        return WebsiteIcon(dataURL: "data:image/png;base64," + (output as Data).base64EncodedString(), sourcePixels: min(width, height))
    }
}

/// Only static, self-contained shapes reach AppKit's SVG decoder. No browser is involved.
private final class StaticSVGValidator: NSObject, XMLParserDelegate {
    var valid = true
    var sawSVG = false
    private var depth = 0
    private var elements = 0
    private let allowedElements: Set<String> = ["svg", "g", "path", "rect", "circle", "ellipse", "line", "polyline", "polygon", "defs", "linearGradient", "radialGradient", "stop", "clipPath", "mask", "title", "desc"]
    private let allowedAttributes: Set<String> = ["xmlns", "xmlns:xlink", "id", "version", "viewBox", "width", "height", "preserveAspectRatio", "x", "y", "x1", "x2", "y1", "y2", "cx", "cy", "r", "rx", "ry", "d", "points", "transform", "fill", "fill-rule", "fill-opacity", "stroke", "stroke-width", "stroke-linecap", "stroke-linejoin", "stroke-miterlimit", "stroke-dasharray", "stroke-dashoffset", "stroke-opacity", "opacity", "clip-rule", "clip-path", "clipPathUnits", "mask", "maskUnits", "maskContentUnits", "gradientUnits", "gradientTransform", "spreadMethod", "fx", "fy", "fr", "offset", "stop-color", "stop-opacity", "role", "aria-label", "aria-hidden", "focusable"]

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        depth += 1; elements += 1
        if depth == 1 { sawSVG = elementName == "svg" }
        guard allowedElements.contains(elementName), depth <= 32, elements <= 4096 else { reject(parser); return }
        for (key, value) in attributes {
            guard allowedAttributes.contains(key), value.count <= 65_536 else { reject(parser); return }
            if key == "xmlns" || key == "xmlns:xlink" { continue }
            // CSS escape sequences, stylesheets, and all non-local paint references are rejected.
            guard !value.contains("\\"), !value.contains("@"), !value.contains("&") else { reject(parser); return }
            if value.lowercased().contains("url") {
                guard value.range(of: #"^url\(\s*#[a-zA-Z_][a-zA-Z0-9_.:-]*\s*\)$"#, options: .regularExpression) != nil else { reject(parser); return }
            }
        }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { depth -= 1 }
    func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) { reject(parser) }
    private func reject(_ parser: XMLParser) { valid = false; parser.abortParsing() }
}

private final class BoundedIconDownload: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate {
    let limit: Int
    let semaphore = DispatchSemaphore(value: 0)
    var data = Data()
    var responseURL: URL?
    var failed = false
    var redirects = 0
    init(limit: Int) { self.limit = limit }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
              let url = response.url, IconDocument.safeURL(url.absoluteString) != nil,
              response.expectedContentLength <= Int64(limit) else { failed = true; completionHandler(.cancel); return }
        responseURL = url; completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard data.count + chunk.count <= limit else { failed = true; dataTask.cancel(); return }
        data.append(chunk)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        redirects += 1
        guard redirects <= 4, let url = request.url, IconDocument.safeURL(url.absoluteString) != nil else {
            failed = true; completionHandler(nil); return
        }
        var clean = request; clean.httpShouldHandleCookies = false
        clean.setValue(nil, forHTTPHeaderField: "Cookie"); clean.setValue(nil, forHTTPHeaderField: "Authorization")
        clean.setValue(nil, forHTTPHeaderField: "Referer")
        completionHandler(clean)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust { completionHandler(.performDefaultHandling, nil) }
        else { failed = true; completionHandler(.cancelAuthenticationChallenge, nil) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error != nil { failed = true }
        semaphore.signal()
    }

    static func fetch(_ url: URL, limit: Int, deadline: Date) -> (Data, URL)? {
        let remaining = min(8.0, deadline.timeIntervalSinceNow)
        guard remaining > 0, IconDocument.safeURL(url.absoluteString) != nil else { return nil }
        let delegate = BoundedIconDownload(limit: limit)
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCredentialStorage = nil; config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = remaining; config.timeoutIntervalForResource = remaining
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        var request = URLRequest(url: url); request.httpShouldHandleCookies = false
        request.setValue("MenDao/1 WebsiteIcon", forHTTPHeaderField: "User-Agent")
        let task = session.dataTask(with: request); task.resume()
        if delegate.semaphore.wait(timeout: .now() + remaining + 1) == .timedOut {
            task.cancel(); session.invalidateAndCancel(); return nil
        }
        session.finishTasksAndInvalidate()
        guard !delegate.failed, let responseURL = delegate.responseURL, !delegate.data.isEmpty else { return nil }
        return (delegate.data, responseURL)
    }
}

final class IconLoader {
    private let work = OperationQueue()
    private let state = DispatchQueue(label: "cn.mendao.icons.state")
    private var pending: [String: [(WebsiteIcon?) -> Void]] = [:]
    private var cache: [String: (Date, WebsiteIcon?)] = [:]

    init() { work.name = "cn.mendao.icons"; work.maxConcurrentOperationCount = 4; work.qualityOfService = .utility }

    func clearCache() { state.sync { cache.removeAll() } }

    /// Completion is always on the main queue. Duplicate origins share one request.
    func load(_ siteURL: String, completion: @escaping (WebsiteIcon?) -> Void) {
        guard let root = IconDocument.rootURL(siteURL) else { DispatchQueue.main.async { completion(nil) }; return }
        let key = root.absoluteString
        state.async {
            if let (date, result) = self.cache[key], Date().timeIntervalSince(date) < 60 {
                DispatchQueue.main.async { completion(result) }; return
            }
            if self.pending[key] != nil { self.pending[key]!.append(completion); return }
            self.pending[key] = [completion]
            self.work.addOperation {
                let result = self.resolve(root)
                self.state.async {
                    self.cache[key] = (Date(), result)
                    let callbacks = self.pending.removeValue(forKey: key) ?? []
                    DispatchQueue.main.async { callbacks.forEach { $0(result) } }
                }
            }
        }
    }

    private func resolve(_ root: URL) -> WebsiteIcon? {
        let deadline = Date().addingTimeInterval(28)
        var candidates: [IconCandidate] = []
        if let (data, finalURL) = BoundedIconDownload.fetch(root, limit: 1024 * 1024, deadline: deadline),
           let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
            let links = IconDocument.links(html, base: finalURL); candidates += links.icons
            for manifest in links.manifests {
                if let (data, url) = BoundedIconDownload.fetch(manifest, limit: 512 * 1024, deadline: deadline) {
                    candidates += IconDocument.manifest(data, base: url)
                }
            }
        }
        candidates += [IconCandidate(url: root.appendingPathComponent("apple-touch-icon.png"), suggestedPixels: 180),
                       IconCandidate(url: root.appendingPathComponent("favicon.ico"), suggestedPixels: 32)]
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 3; queue.qualityOfService = .utility
        let lock = NSLock()
        var best: WebsiteIcon?
        for candidate in IconDocument.unique(candidates).prefix(12) {
            queue.addOperation {
                guard let (data, _) = BoundedIconDownload.fetch(candidate.url, limit: IconDocument.maximumImageBytes, deadline: deadline),
                      let icon = IconDocument.decode(data) else { return }
                lock.lock(); defer { lock.unlock() }
                if icon.sourcePixels > (best?.sourcePixels ?? 0) { best = icon }
            }
        }
        queue.waitUntilAllOperationsAreFinished()
        return best
    }
}
