import Foundation
import CoreGraphics

@main struct FloatingLauncherLogicTests {
    static func main() throws {
        var count = 0
        func check(_ name: String, _ value: @autoclosure () -> Bool) {
            guard value() else { fatalError(name) }; count += 1
        }
        func site(_ id: String, name: String? = nil) -> Website {
            Website(id: id, name: name ?? id, url: "https://\(id).example.test/home", color: "#123456", icon: nil,
                    allowedBrowsers: ["edge"], defaultBrowser: "edge", accounts: [], defaultAccount: nil, profiles: [:])
        }
        func tile(_ id: String) -> Tile { Tile(id: id, kind: "site", name: nil, children: nil) }
        let oldJSON = #"{"schema":1,"sites":[],"tiles":[],"appearance":"dusk"}"#.data(using: .utf8)!
        let old = try JSONDecoder().decode(Library.self, from: oldJSON).validated()
        check("old library decodes without new floating fields", FloatingLauncherLogic.orderedSites(in: old).isEmpty)
        check("reading old library does not change it", old == (try? JSONDecoder().decode(Library.self, from: oldJSON)))
        var chinese = site("chinese", name: "哔哩哔哩"); chinese.aliases = "视频 弹幕"
        var french = site("accent", name: "Café Équipe"); french.aliases = "Team workspace"
        let ordered = [site("first"), site("second"), chinese, french] + (0..<10).map { site("extra-\($0)") }
        let archived = site("archived", name: "Archived video")
        let library = Library(sites: ordered.reversed() + [archived], tiles: [tile("first"),
            Tile(id: "folder", kind: "folder", name: "Folder", children: ["second", "chinese", "accent"])] + (0..<10).map { tile("extra-\($0)") })
        _ = try library.validated()
        check("follows launchpad and folder order", FloatingLauncherLogic.orderedSites(in: library).map(\.id) == ordered.map(\.id))
        check("archive excluded from default view", !FloatingLauncherLogic.sites(in: library, query: "").contains(archived))
        check("archive excluded from search", FloatingLauncherLogic.sites(in: library, query: "archived").isEmpty)
        check("default only first eight", FloatingLauncherLogic.sites(in: library, query: "").map(\.id) == Array(ordered.prefix(8)).map(\.id))
        check("whitespace query is default", FloatingLauncherLogic.sites(in: library, query: " \n\t").count == 8)
        check("default explicit limit", FloatingLauncherLogic.sites(in: library, query: "", limit: 2).map(\.id) == ["first", "second"])
        check("negative limit safely empty", FloatingLauncherLogic.sites(in: library, query: "", limit: -1).isEmpty)
        check("search includes all matches beyond default", FloatingLauncherLogic.sites(in: library, query: "extra").count == 10)
        check("case insensitive name search", FloatingLauncherLogic.sites(in: library, query: "FIRST").map(\.id) == ["first"])
        check("URL path search", FloatingLauncherLogic.sites(in: library, query: "first.example.test/home").map(\.id) == ["first"])
        check("Chinese name search", FloatingLauncherLogic.sites(in: library, query: "哔哩").map(\.id) == ["chinese"])
        check("Chinese alias search", FloatingLauncherLogic.sites(in: library, query: "弹幕").map(\.id) == ["chinese"])
        check("pinyin joined name search", FloatingLauncherLogic.sites(in: library, query: "bilibili").map(\.id) == ["chinese"])
        check("pinyin spaced name search", FloatingLauncherLogic.sites(in: library, query: "bi li").map(\.id) == ["chinese"])
        check("pinyin initials search", FloatingLauncherLogic.sites(in: library, query: "blbl").map(\.id) == ["chinese"])
        check("pinyin alias search", FloatingLauncherLogic.sites(in: library, query: "danmu").map(\.id) == ["chinese"])
        check("diacritics insensitive", FloatingLauncherLogic.sites(in: library, query: "cafe equipe").map(\.id) == ["accent"])
        check("full-width case folding", FloatingLauncherLogic.sites(in: library, query: "ＣＡＦＥ").map(\.id) == ["accent"])
        check("all query words must match", FloatingLauncherLogic.sites(in: library, query: "team absent").isEmpty)
        var malformed = library
        malformed.tiles += [tile("first"), Tile(id: "duplicate-folder", kind: "folder", name: "Duplicated", children: ["chinese", "missing"]),
                            Tile(id: "unknown", kind: "unknown", name: nil, children: ["archived"])]
        malformed.sites.append(ordered[0])
        check("defensive dedup ignores unknown tiles and missing sites", FloatingLauncherLogic.orderedSites(in: malformed).map(\.id) == ordered.map(\.id))
        var browserSite = site("browser"); browserSite.allowedBrowsers = ["chrome"]
        check("single allowed browser has no fallback", FloatingLauncherLogic.allowedBrowsers(for: browserSite).map(\.id) == ["chrome"])
        browserSite.allowedBrowsers = ["edge", "chrome", "edge", "unknown", "firefox"]
        check("browser menu follows allowed order and deduplicates", FloatingLauncherLogic.allowedBrowsers(for: browserSite).map(\.id) == ["edge", "chrome", "firefox"])
        browserSite.allowedBrowsers = []
        check("empty malformed browser list does not grant permission", FloatingLauncherLogic.allowedBrowsers(for: browserSite).isEmpty)

        let leftScreen = CGRect(x: -1440, y: 200, width: 1440, height: 900)
        let rightScreen = CGRect(x: 0, y: 24, width: 1920, height: 1056)
        let size = CGSize(width: 360, height: 500)
        let initial = FloatingLauncherGeometry.restoredFrame(saved: nil, size: size, screens: [leftScreen, rightScreen])
        check("initial panel uses given screen even with negative coordinates", leftScreen.contains(initial) && initial.maxX == -20)
        check("initial height respects menu and Dock exclusion", initial.maxY == leftScreen.maxY - 72)
        let saved = CGRect(x: 1520, y: 600, width: 360, height: 48)
        let restored = FloatingLauncherGeometry.restoredFrame(saved: saved, size: size, screens: [leftScreen, rightScreen])
        check("saved panel restores to its monitor", rightScreen.contains(restored) && restored.minX == saved.minX)
        check("expanded panel preserves header top", restored.maxY == saved.maxY)
        let clamped = FloatingLauncherGeometry.constrain(frame: CGRect(x: -1600, y: 50, width: 360, height: 500), to: leftScreen)
        check("clamp respects negative display origin", clamped.minX == -1440 && clamped.minY == 200)
        check("whole panel remains visible", leftScreen.contains(clamped))
        let movedOffscreen = CGRect(x: 2200, y: 650, width: 360, height: 48)
        let removed = FloatingLauncherGeometry.restoredFrame(saved: movedOffscreen, size: size, screens: [leftScreen, rightScreen])
        check("removed display restores to nearest remaining screen", rightScreen.contains(removed) && removed.maxX == rightScreen.maxX)
        let leftSaved = CGRect(x: -1700, y: 650, width: 360, height: 48)
        check("nearest removed display can be left of origin", FloatingLauncherGeometry.screen(for: leftSaved, among: [rightScreen, leftScreen]) == leftScreen)
        let straddled = CGRect(x: -80, y: 500, width: 360, height: 500)
        check("largest intersection selects correct display", FloatingLauncherGeometry.screen(for: straddled, among: [leftScreen, rightScreen]) == rightScreen)
        let tiny = CGRect(x: -400, y: -200, width: 240, height: 140)
        let small = FloatingLauncherGeometry.restoredFrame(saved: nil, size: size, screens: [tiny])
        check("small screen shrinks panel to fit", small == tiny)
        let expandedRight = FloatingLauncherGeometry.resizedFrame(CGRect(x: 1880, y: 700, width: 40, height: 48), size: size, in: rightScreen, edge: .right)
        check("right edge stays attached after expansion", expandedRight.maxX == rightScreen.maxX && expandedRight.maxY == 748)
        let collapsed = FloatingLauncherGeometry.resizedFrame(expandedRight, size: CGSize(width: 360, height: 48), in: rightScreen)
        check("collapse preserves header and screen", collapsed.maxY == expandedRight.maxY && rightScreen.contains(collapsed))
        let top = FloatingLauncherGeometry.resizedFrame(CGRect(x: 900, y: 1060, width: 360, height: 48), size: size, in: rightScreen)
        check("height change at screen top clamps safely", top.maxY == rightScreen.maxY)
        let leftSnap = FloatingLauncherGeometry.snap(frame: CGRect(x: -1425, y: 500, width: 360, height: 500), to: leftScreen)
        check("left edge snap respects nonzero origin", leftSnap.edge == .left && leftSnap.frame.minX == leftScreen.minX)
        let rightSnap = FloatingLauncherGeometry.snap(frame: CGRect(x: -375, y: 500, width: 360, height: 500), to: leftScreen)
        check("right edge snap respects negative screen", rightSnap.edge == .right && rightSnap.frame.maxX == leftScreen.maxX)
        let interior = FloatingLauncherGeometry.snap(frame: CGRect(x: 600, y: 500, width: 360, height: 500), to: rightScreen)
        check("interior position remains undocked", interior.edge == .none && interior.frame.minX == 600)
        let smallSnap = FloatingLauncherGeometry.snap(frame: small, to: tiny)
        check("full-width small screen ties deterministically to left", smallSnap.edge == .left && smallSnap.frame == tiny)
        let emptyScreens = FloatingLauncherGeometry.restoredFrame(saved: nil, size: size, screens: [])
        check("empty screen snapshot supplies finite fallback", emptyScreens.width == 360 && emptyScreens.height == 500)
        let invalid = CGRect(x: CGFloat.nan, y: CGFloat.infinity, width: 0, height: -1)
        let recovered = FloatingLauncherGeometry.restoredFrame(saved: invalid, size: size, screens: [leftScreen])
        check("invalid saved coordinates ignored", recovered == initial)
        let sanitized = FloatingLauncherGeometry.constrain(frame: invalid, to: rightScreen)
        check("invalid dimensions cannot hide panel", rightScreen.contains(sanitized) && sanitized.width == 360 && sanitized.height == 48)
        check("invalid screen candidates skipped", FloatingLauncherGeometry.screen(for: saved, among: [invalid, rightScreen]) == rightScreen)

        let handleSize = FloatingLauncherGeometry.hiddenSize
        let collapsedSize = CGSize(width: 140, height: 48)
        let expandedSize = CGSize(width: 364, height: 526)
        let leftAnchor = CGRect(x: leftScreen.minX, y: 750, width: collapsedSize.width, height: collapsedSize.height)
        let leftHandle = FloatingLauncherGeometry.hiddenFrame(anchor: leftAnchor, edge: .left, in: leftScreen)
        check("hidden left handle has compact independent size", leftHandle.size == handleSize)
        check("hidden left handle is wholly within negative-coordinate display", leftScreen.contains(leftHandle) && leftHandle.minX == leftScreen.minX)
        check("hidden left handle preserves anchor top", leftHandle.maxY == leftAnchor.maxY)
        let rightAnchor = CGRect(x: leftScreen.maxX - collapsedSize.width, y: 750, width: collapsedSize.width, height: collapsedSize.height)
        let rightHandle = FloatingLauncherGeometry.hiddenFrame(anchor: rightAnchor, edge: .right, in: leftScreen)
        check("hidden right handle sits inside display edge", rightHandle.maxX == leftScreen.maxX && leftScreen.contains(rightHandle))
        check("hidden right handle never extends into adjacent display", rightHandle.intersection(rightScreen).isNull || rightHandle.intersection(rightScreen).width == 0)
        check("hidden right handle preserves anchor top", rightHandle.maxY == rightAnchor.maxY)
        let interiorHandle = FloatingLauncherGeometry.hiddenFrame(anchor: saved, edge: .none, in: rightScreen)
        check("undocked hidden fallback retains original x", interiorHandle.minX == saved.minX && interiorHandle.maxY == saved.maxY)
        let highAnchor = CGRect(x: rightScreen.maxX - 140, y: rightScreen.maxY + 20, width: 140, height: 48)
        let highHandle = FloatingLauncherGeometry.hiddenFrame(anchor: highAnchor, edge: .right, in: rightScreen)
        check("hidden handle clamps below menu bar", highHandle.maxY == rightScreen.maxY && rightScreen.contains(highHandle))
        let bottomAnchor = CGRect(x: rightScreen.minX, y: rightScreen.minY, width: 140, height: 48)
        let bottomHandle = FloatingLauncherGeometry.hiddenFrame(anchor: bottomAnchor, edge: .left, in: rightScreen)
        check("taller hidden handle clamps above Dock", bottomHandle.minY == rightScreen.minY && rightScreen.contains(bottomHandle))
        let bottomExpanded = FloatingLauncherGeometry.resizedFrame(bottomAnchor, size: expandedSize, in: rightScreen, edge: .left)
        check("bottom hidden clamp does not alter saved anchor", bottomExpanded.minY == rightScreen.minY && bottomAnchor.height == 48)
        let microScreen = CGRect(x: -80, y: -32, width: 8, height: 40)
        let microHandle = FloatingLauncherGeometry.hiddenFrame(anchor: rightAnchor, edge: .right, in: microScreen)
        check("handle shrinks to fit extremely small display", microHandle == microScreen)
        let customHandle = FloatingLauncherGeometry.hiddenFrame(anchor: leftAnchor, edge: .left, in: leftScreen, size: CGSize(width: 10, height: 80))
        check("custom handle dimensions preserve edge and top", customHandle.size == CGSize(width: 10, height: 80) && customHandle.maxY == leftAnchor.maxY && customHandle.minX == leftScreen.minX)
        let invalidHandle = FloatingLauncherGeometry.hiddenFrame(anchor: invalid, edge: .right, in: rightScreen,
                                                                size: CGSize(width: CGFloat.infinity, height: -1))
        check("hidden invalid anchor and dimensions have safe visible fallback", rightScreen.contains(invalidHandle) && invalidHandle.size == handleSize && invalidHandle.maxY == rightScreen.maxY)
        let fallbackHandle = FloatingLauncherGeometry.hiddenFrame(anchor: invalid, edge: .left, in: invalid)
        check("hidden invalid display uses finite visible bounds", fallbackHandle == CGRect(x: 0, y: 396, width: 20, height: 104))
        for (edge, anchor) in [(FloatingLauncherEdge.left, leftAnchor), (.right, rightAnchor)] {
            let expanded = FloatingLauncherGeometry.resizedFrame(anchor, size: expandedSize, in: leftScreen, edge: edge)
            let collapsedAgain = FloatingLauncherGeometry.resizedFrame(expanded, size: collapsedSize, in: leftScreen, edge: edge)
            check("hidden-to-expanded keeps \(edge.rawValue) header at anchor", expanded.maxY == anchor.maxY)
            check("expanded-to-collapsed keeps \(edge.rawValue) normalized anchor", collapsedAgain == anchor)
            check("repeated hide preserves \(edge.rawValue) handle position", FloatingLauncherGeometry.hiddenFrame(anchor: collapsedAgain, edge: edge, in: leftScreen) == FloatingLauncherGeometry.hiddenFrame(anchor: anchor, edge: edge, in: leftScreen))
        }
        print("Floating launcher logic: \(count) checks passed")
    }
}
