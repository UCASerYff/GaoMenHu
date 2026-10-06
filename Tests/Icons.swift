import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@main struct IconTests {
    static func png(_ width: Int, _ height: Int) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.92, green: 0.4, blue: 0.2, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
        return output as Data
    }

    static func ico(_ sizes: [Int]) -> Data {
        func u16(_ value: Int) -> Data { var v = UInt16(value).littleEndian; return withUnsafeBytes(of: &v) { Data($0) } }
        func u32(_ value: Int) -> Data { var v = UInt32(value).littleEndian; return withUnsafeBytes(of: &v) { Data($0) } }
        let images = sizes.map { png($0, $0) }
        var data = u16(0) + u16(1) + u16(sizes.count)
        var offset = 6 + sizes.count * 16
        for (size, image) in zip(sizes, images) {
            data += Data([UInt8(size == 256 ? 0 : size), UInt8(size == 256 ? 0 : size), 0, 0])
            data += u16(1) + u16(32) + u32(image.count) + u32(offset)
            offset += image.count
        }
        for image in images { data += image }
        return data
    }

    static func outputSize(_ icon: WebsiteIcon?) -> (Int, Int)? {
        guard let icon, let data = Data(base64Encoded: String(icon.dataURL.dropFirst("data:image/png;base64,".count))),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return (image.width, image.height)
    }

    static func main() {
        var count = 0
        func check(_ name: String, _ condition: @autoclosure () -> Bool) {
            guard condition() else { fatalError("Icon fixture failed: " + name) }
            count += 1
        }
        let base = URL(string: "https://example.test/account/welcome")!
        check("bookmark privacy: strip path and query", IconDocument.rootURL("https://example.test/private/login?token=do-not-send#secret")?.absoluteString == "https://example.test/")
        check("standard port normalization", IconDocument.rootURL("https://example.test:443/a")?.absoluteString == "https://example.test/")
        check("custom port preserved", IconDocument.rootURL("https://example.test:8443/a")?.port == 8443)
        check("legacy HTTP bookmark requests HTTPS icon root", IconDocument.rootURL("http://example.test:80/private?token=hidden")?.absoluteString == "https://example.test/")
        check("root credentials rejected", IconDocument.rootURL("https://name:secret@example.test/login") == nil)
        check("relative URL", IconDocument.safeURL("../assets/icon.png", relativeTo: base)?.absoluteString == "https://example.test/assets/icon.png")
        check("protocol relative CDN", IconDocument.safeURL("//cdn.example.test/icon.png", relativeTo: base)?.absoluteString == "https://cdn.example.test/icon.png")
        check("HTTPS only", IconDocument.safeURL("http://example.test/icon.png") == nil)
        check("no credentials in URL", IconDocument.safeURL("https://name:secret@example.test/icon.png") == nil)
        check("no script URL", IconDocument.safeURL("javascript:alert(1)", relativeTo: base) == nil)
        check("no local URL", IconDocument.safeURL("file:///tmp/icon.png") == nil)
        check("no inline URL", IconDocument.safeURL("data:image/png;base64,abc") == nil)
        check("no embedded controls", IconDocument.safeURL("https://exa\nmple.test/a") == nil)
        check("strip fragment", IconDocument.safeURL("https://example.test/i.png#fragment")?.fragment == nil)
        let html = """
        <!-- <link rel="icon" href="/not-a-real-icon.png"> -->
        <script>let fixture = '<link rel="icon" href="/not-from-script.png">';</script>
        <LINK sizes="32x32 128x128" href="../art/logo.png?v=1&amp;q=2" REL="shortcut icon">
        <link rel='apple-touch-icon' href='//cdn.example.test/apple.png'>
        <link rel=manifest href=/app.webmanifest>
        <link rel='icon' href='http://insecure.example.test/low.png'>
        <link rel='icon' href='https://user:password@example.test/bad.png'>
        <link rel='stylesheet' href='/style.css'>
        <link rel='icon' href='../art/logo.png?v=1&amp;q=2' sizes=64x64>
        """
        let links = IconDocument.links(html, base: base)
        check("only real secure icon declarations", links.icons.count == 2)
        check("touch icon prioritized", links.icons.first?.url.absoluteString == "https://cdn.example.test/apple.png")
        check("relative link and HTML entity", links.icons.last?.url.absoluteString == "https://example.test/art/logo.png?v=1&q=2")
        check("largest advertised size retained for duplicate", links.icons.last?.suggestedPixels == 128)
        check("manifest link extraction", links.manifests.map(\.absoluteString) == ["https://example.test/app.webmanifest"])
        check("numeric URL entities", IconDocument.entities("a&#x2f;b&#47;c") == "a/b/c")
        let manifest = Data(#"{"icons":[{"src":"img/pwa.png","sizes":"192x192 512x512"},{"src":"//cdn.example.test/other.png","sizes":"128x128"},{"src":"http://example.test/bad.png"},{"src":"data:image/png;base64,abc"}]}"#.utf8)
        let manifestURL = URL(string: "https://example.test/static/app.webmanifest")!
        let icons = IconDocument.manifest(manifest, base: manifestURL)
        check("manifest HTTPS filtering", icons.count == 2)
        check("manifest relative to manifest URL", icons.first?.url.absoluteString == "https://example.test/static/img/pwa.png")
        check("manifest dimensions", icons.first?.suggestedPixels == 512)
        check("invalid manifest", IconDocument.manifest(Data("no json".utf8), base: base).isEmpty)
        check("oversized manifest", IconDocument.manifest(Data(repeating: 32, count: 512 * 1024 + 1), base: base).isEmpty)
        check("16px rejected", IconDocument.decode(png(16, 16)) == nil)
        check("32px rejected", IconDocument.decode(png(32, 32)) == nil)
        let medium = IconDocument.decode(png(64, 64))
        check("64px retained", medium?.sourcePixels == 64)
        check("small source never enlarged", outputSize(medium)?.0 == 64)
        let high = IconDocument.decode(png(512, 512))
        check("actual source dimension", high?.sourcePixels == 512)
        check("512px downsampled to 256px", outputSize(high)?.0 == 256 && outputSize(high)?.1 == 256)
        check("shortest side recorded", IconDocument.decode(png(128, 256))?.sourcePixels == 128)
        check("huge dimensions rejected", IconDocument.decode(png(8193, 64)) == nil)
        check("oversized payload rejected", IconDocument.decode(Data(repeating: 0, count: IconDocument.maximumImageBytes + 1)) == nil)
        check("non-image rejected", IconDocument.decode(Data("<html>not a png</html>".utf8)) == nil)
        let layered = IconDocument.decode(ico([16, 64, 256]))
        check("ICO largest actual layer chosen", layered?.sourcePixels == 256)
        check("ICO output sharp", outputSize(layered)?.0 == 256)
        let reverse = IconDocument.decode(ico([256, 16, 64]))
        check("ICO layer order irrelevant", reverse?.sourcePixels == 256)
        check("ICO low resolution only rejected", IconDocument.decode(ico([16, 32])) == nil)
        let svg = ##"<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16"><rect width="16" height="16" fill="#cf6029"/></svg>"##
        let vector = IconDocument.decode(Data(svg.utf8))
        check("static SVG accepted", vector?.sourcePixels == 256)
        check("SVG rendered sharply", outputSize(vector)?.0 == 256)
        check("SVG script rejected", IconDocument.decode(Data(svg.replacingOccurrences(of: "</svg>", with: "<script>alert(1)</script></svg>").utf8)) == nil)
        check("SVG image external source rejected", IconDocument.decode(Data(svg.replacingOccurrences(of: "</svg>", with: "<image href='https://example.test/track'/></svg>").utf8)) == nil)
        check("SVG foreign object rejected", IconDocument.decode(Data(svg.replacingOccurrences(of: "</svg>", with: "<foreignObject><p>text</p></foreignObject></svg>").utf8)) == nil)
        check("SVG DOCTYPE rejected", IconDocument.decode(Data(("<!DOCTYPE svg SYSTEM 'https://example.test/external'>" + svg).utf8)) == nil)
        check("SVG stylesheet processing instruction rejected", IconDocument.decode(Data(("<?xml-stylesheet href='https://example.test/style'?>" + svg).utf8)) == nil)
        check("SVG event handler rejected", IconDocument.decode(Data(svg.replacingOccurrences(of: "<rect ", with: "<rect onload='alert(1)' ").utf8)) == nil)
        check("SVG external paint reference rejected", IconDocument.decode(Data(svg.replacingOccurrences(of: "#cf6029", with: "url(https://example.test/paint)").utf8)) == nil)
        check("SVG CSS escapes rejected", IconDocument.decode(Data(svg.replacingOccurrences(of: "#cf6029", with: "u\\72l(https://example.test/paint)").utf8)) == nil)
        print("Icon fixture tests passed: \(count)")
    }
}
