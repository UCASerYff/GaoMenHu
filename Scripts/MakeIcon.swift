import AppKit
import Foundation

// The approved PNG is the artwork master; builds only package size representations.
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let temporary = URL(fileURLWithPath: CommandLine.arguments[2])
let source = root.appendingPathComponent("Assets/AppIcon.png")
guard let artwork = NSImage(contentsOf: source), artwork.size.width > 0 else {
    fatalError("无法读取搞门户图标母版。")
}
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
func render(_ pixels: Int, to url: URL) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    artwork.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
        from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}
let iconset = temporary.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try render(size, to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2, to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
for size in [16, 48, 128] {
    try render(size, to: root.appendingPathComponent("BrowserExtension/icon\(size).png"))
}
