import Foundation
import CoreGraphics

enum FloatingLauncherLogic {
    /// Uses the launchpad arrangement as the source of truth. Unarranged sites are archived.
    static func orderedSites(in library: Library) -> [Website] {
        let sitesByID = Dictionary(library.sites.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen: Set<String> = []
        var result: [Website] = []
        for tile in library.tiles {
            let ids: [String]
            switch tile.kind {
            case "site": ids = [tile.id]
            case "folder": ids = tile.children ?? []
            default: continue
            }
            for id in ids {
                if let site = sitesByID[id], seen.insert(id).inserted { result.append(site) }
            }
        }
        return result
    }

    static func sites(in library: Library, query: String, limit: Int = 8) -> [Website] {
        let ordered = orderedSites(in: library)
        let terms = normalized(query).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !terms.isEmpty else { return Array(ordered.prefix(max(0, limit))) }
        return ordered.filter { site in
            let text = searchText(for: site)
            return terms.allSatisfy { text.contains($0) }
        }
    }

    static func searchText(for site: Website) -> String {
        let nameAndAliases = site.name + " " + (site.aliases ?? "")
        let romanized = normalized(nameAndAliases.applyingTransform(.toLatin, reverse: false) ?? nameAndAliases)
        let words = romanized.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let initials = String(words.compactMap(\.first))
        return normalized(nameAndAliases + " " + site.url) + " " + romanized + " " + words.joined() + " " + initials
    }

    /// Never adds a fallback browser: the launch action independently validates this constraint.
    static func allowedBrowsers(for site: Website) -> [Browser] {
        var seen: Set<String> = []
        return site.allowedBrowsers.compactMap { id in
            guard seen.insert(id).inserted else { return nil }
            return Browser.catalog.first(where: { $0.id == id })
        }
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "zh_CN"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum FloatingLauncherEdge: String {
    case none, left, right
}

enum FloatingLauncherGeometry {
    static let width: CGFloat = 360
    static let headerHeight: CGFloat = 48
    static let hiddenSize = CGSize(width: 20, height: 104)

    static func constrain(frame: CGRect, to screen: CGRect) -> CGRect {
        let bounds = validScreen(screen)
        let width = min(positive(frame.size.width, fallback: Self.width), bounds.width)
        let height = min(positive(frame.size.height, fallback: headerHeight), bounds.height)
        let x = frame.minX.isFinite ? frame.minX : bounds.maxX - width
        let y = frame.minY.isFinite ? frame.minY : bounds.maxY - height
        return CGRect(x: min(max(x, bounds.minX), bounds.maxX - width),
                      y: min(max(y, bounds.minY), bounds.maxY - height), width: width, height: height)
    }

    /// Screen rectangles are visible frames, so menu bars and the Dock remain unobstructed.
    static func restoredFrame(saved: CGRect?, size: CGSize, screens: [CGRect]) -> CGRect {
        let valid = screens.filter(isValidScreen)
        guard !valid.isEmpty else {
            return CGRect(x: 0, y: 0, width: positive(size.width, fallback: width),
                          height: positive(size.height, fallback: headerHeight))
        }
        if let saved, saved.minX.isFinite, saved.minY.isFinite,
           saved.size.width.isFinite, saved.size.height.isFinite, saved.size.width > 0, saved.size.height > 0 {
            let screen = screen(for: saved, among: valid)!
            return resizedFrame(saved, size: size, in: screen)
        }
        let screen = valid[0]
        let target = CGSize(width: positive(size.width, fallback: width), height: positive(size.height, fallback: headerHeight))
        return constrain(frame: CGRect(x: screen.maxX - target.width - 20,
                                       y: screen.maxY - target.height - 72,
                                       width: target.width, height: target.height), to: screen)
    }

    /// Largest intersection wins; after a monitor is removed, use the nearest remaining display.
    static func screen(for frame: CGRect, among screens: [CGRect]) -> CGRect? {
        let valid = screens.filter(isValidScreen)
        guard let first = valid.first else { return nil }
        guard frame.minX.isFinite, frame.minY.isFinite, frame.width.isFinite, frame.height.isFinite else { return first }
        let areas = valid.map { screen -> CGFloat in
            let overlap = screen.intersection(frame)
            return overlap.isNull ? 0 : overlap.width * overlap.height
        }
        if let largest = areas.max(), largest > 0, let index = areas.firstIndex(of: largest) { return valid[index] }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return valid.min { squaredDistance(center, to: $0) < squaredDistance(center, to: $1) }
    }

    /// macOS coordinates grow upwards. Keeping maxY stable prevents expansion from moving the header.
    static func resizedFrame(_ frame: CGRect, size: CGSize, in screen: CGRect,
                             edge: FloatingLauncherEdge = .none) -> CGRect {
        let width = positive(size.width, fallback: Self.width)
        let height = positive(size.height, fallback: headerHeight)
        let x = edge == .right ? frame.maxX - width : frame.minX
        return constrain(frame: CGRect(x: x, y: frame.maxY - height, width: width, height: height), to: screen)
    }

    /// A separate narrow window keeps the hidden launcher within its own display.
    /// Retain the collapsed anchor for saving and expansion; a bottom-edge clamp may move this handle's top.
    static func hiddenFrame(anchor: CGRect, edge: FloatingLauncherEdge, in screen: CGRect,
                            size: CGSize = hiddenSize) -> CGRect {
        let bounds = validScreen(screen)
        let width = min(positive(size.width, fallback: hiddenSize.width), bounds.width)
        let height = min(positive(size.height, fallback: hiddenSize.height), bounds.height)
        let x: CGFloat
        switch edge {
        case .left: x = bounds.minX
        case .right: x = bounds.maxX - width
        case .none: x = anchor.minX
        }
        let top = anchor.maxY.isFinite && anchor.height.isFinite && anchor.height > 0 ? anchor.maxY : bounds.maxY
        return constrain(frame: CGRect(x: x, y: top - height, width: width, height: height), to: bounds)
    }

    static func snap(frame: CGRect, to screen: CGRect, threshold: CGFloat = 24) -> (frame: CGRect, edge: FloatingLauncherEdge) {
        let bounds = validScreen(screen)
        var result = constrain(frame: frame, to: bounds)
        let distance = threshold.isFinite ? max(0, threshold) : 24
        let left = abs(result.minX - bounds.minX), right = abs(bounds.maxX - result.maxX)
        if left <= distance && left <= right { result.origin.x = bounds.minX; return (result, .left) }
        if right <= distance { result.origin.x = bounds.maxX - result.width; return (result, .right) }
        return (result, .none)
    }

    private static func positive(_ value: CGFloat, fallback: CGFloat) -> CGFloat { value.isFinite && value > 0 ? value : fallback }
    private static func isValidScreen(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite && frame.size.width.isFinite && frame.size.height.isFinite && frame.size.width > 0 && frame.size.height > 0
    }
    private static func validScreen(_ frame: CGRect) -> CGRect {
        isValidScreen(frame) ? frame : CGRect(x: 0, y: 0, width: width, height: 500)
    }
    private static func squaredDistance(_ point: CGPoint, to frame: CGRect) -> CGFloat {
        let dx = max(frame.minX - point.x, 0, point.x - frame.maxX)
        let dy = max(frame.minY - point.y, 0, point.y - frame.maxY)
        return dx * dx + dy * dy
    }
}
