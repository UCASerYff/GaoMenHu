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
        let usage: [String: WebsiteLaunchUsage] = [
            "extra-9": WebsiteLaunchUsage(openCount: 1000, lastOpenedAt: 900),
            "extra-8": WebsiteLaunchUsage(openCount: 1, lastOpenedAt: 800),
            "extra-7": WebsiteLaunchUsage(openCount: 2, lastOpenedAt: 700),
            "extra-6": WebsiteLaunchUsage(openCount: 100, lastOpenedAt: 100),
            "extra-5": WebsiteLaunchUsage(openCount: 50, lastOpenedAt: 90),
            "first": WebsiteLaunchUsage(openCount: 10, lastOpenedAt: 10),
            "second": WebsiteLaunchUsage(openCount: 10, lastOpenedAt: 20),
            "extra-4": WebsiteLaunchUsage(openCount: 10, lastOpenedAt: 20),
            "archived": WebsiteLaunchUsage(openCount: 5000, lastOpenedAt: 1000),
            "missing": WebsiteLaunchUsage(openCount: 5000, lastOpenedAt: 1000)
        ]
        let ranked = FloatingLauncherLogic.sites(in: library, query: "", usage: usage)
        check("recent three appear before frequent sites", Array(ranked.prefix(3)).map(\.id) == ["extra-9", "extra-8", "extra-7"])
        check("remaining sites sort by count then recency then original arrangement", ranked.map(\.id) == ["extra-9", "extra-8", "extra-7", "extra-6", "extra-5", "second", "extra-4", "first"])
        check("recent frequent overlap appears only once", Set(ranked.map(\.id)).count == ranked.count)
        check("archived and deleted history never appears", !ranked.contains(archived) && !ranked.contains { $0.id == "missing" })
        check("small limits reserve only available slots for recent", FloatingLauncherLogic.sites(in: library, query: "", usage: usage, limit: 2).map(\.id) == ["extra-9", "extra-8"])
        check("ranked negative limit remains empty", FloatingLauncherLogic.sites(in: library, query: "", usage: usage, limit: -1).isEmpty)
        check("ranked zero limit remains empty", FloatingLauncherLogic.sites(in: library, query: "", usage: usage, limit: 0).isEmpty)
        check("original arrangement fills unused recommendation slots", FloatingLauncherLogic.sites(in: library, query: "", usage: usage, limit: 10).map(\.id).suffix(2) == ["chinese", "accent"])
        check("ranked search preserves all matches and original arrangement", FloatingLauncherLogic.sites(in: library, query: "extra", usage: usage, limit: 2).map(\.id) == (0..<10).map { "extra-\($0)" })
        let oneUsage = ["extra-9": WebsiteLaunchUsage(openCount: 1, lastOpenedAt: 100)]
        check("one used site precedes unchanged arrangement fallback", FloatingLauncherLogic.sites(in: library, query: "", usage: oneUsage, limit: 3).map(\.id) == ["extra-9", "first", "second"])
        let tiedUsage = Dictionary(uniqueKeysWithValues: ["extra-9", "extra-8", "extra-7", "extra-6"].map { ($0, WebsiteLaunchUsage(openCount: 1, lastOpenedAt: 100)) })
        check("recency ties retain original arrangement deterministically", FloatingLauncherLogic.sites(in: library, query: "", usage: tiedUsage, limit: 4).map(\.id) == ["extra-6", "extra-7", "extra-8", "extra-9"])
        let invalidUsage = ["extra-9": WebsiteLaunchUsage(openCount: -1, lastOpenedAt: 900),
                            "extra-8": WebsiteLaunchUsage(openCount: 1, lastOpenedAt: .nan),
                            "extra-7": WebsiteLaunchUsage(openCount: 1, lastOpenedAt: -.infinity),
                            "extra-6": WebsiteLaunchUsage(openCount: 1, lastOpenedAt: -1),
                            "extra-5": WebsiteLaunchUsage(openCount: 0, lastOpenedAt: 900)]
        check("invalid and never opened statistics do not promote sites", FloatingLauncherLogic.sites(in: library, query: "", usage: invalidUsage).map(\.id) == Array(ordered.prefix(8)).map(\.id))
        check("ranking is read only and preserves library order", FloatingLauncherLogic.orderedSites(in: library).map(\.id) == ordered.map(\.id) && usage["extra-9"]?.openCount == 1000)

        let preferenceKey = "GaoMenHu.WebsiteLaunchHistory"
        let suite = "cn.mendao.launch-history-test." + UUID().uuidString
        guard let preferences = UserDefaults(suiteName: suite) else { fatalError("temporary preferences unavailable") }
        preferences.removePersistentDomain(forName: suite)
        defer { preferences.removePersistentDomain(forName: suite) }
        let history = WebsiteLaunchHistory(preferences: preferences)
        check("old preferences without history start empty", history.records.isEmpty)
        check("reading old preferences does not write statistics", preferences.data(forKey: preferenceKey) == nil)
        history.record(siteID: "first", at: Date(timeIntervalSince1970: 10))
        history.record(siteID: "first", at: Date(timeIntervalSince1970: 20))
        history.record(siteID: "second", at: Date(timeIntervalSince1970: 15))
        check("successful launches increment per site and update last open", history.records["first"] == WebsiteLaunchUsage(openCount: 2, lastOpenedAt: 20) && history.records["second"]?.openCount == 1)
        let savedHistory = preferences.data(forKey: preferenceKey)
        check("history survives creating a new store", WebsiteLaunchHistory(preferences: preferences).records == history.records)
        check("loading statistics does not rewrite persisted bytes", preferences.data(forKey: preferenceKey) == savedHistory)
        if let savedHistory, let json = try JSONSerialization.jsonObject(with: savedHistory) as? [String: [String: Any]] {
            check("persisted statistics contain only count and time", json.count == 2 && json.values.allSatisfy { Set($0.keys) == ["openCount", "lastOpenedAt"] })
        } else { check("persisted statistics are valid JSON", false) }
        history.record(siteID: "", at: Date(timeIntervalSince1970: 50))
        history.record(siteID: "first", at: Date(timeIntervalSince1970: -1))
        history.record(siteID: "first", at: Date(timeIntervalSince1970: .nan))
        history.record(siteID: "first", at: Date(timeIntervalSince1970: .infinity))
        check("invalid record attempts leave memory and persistence unchanged", history.records["first"]?.openCount == 2 && history.records.count == 2 && preferences.data(forKey: preferenceKey) == savedHistory)
        let isolated = WebsiteLaunchHistory(preferences: nil)
        isolated.record(siteID: "isolated", at: Date(timeIntervalSince1970: 100))
        check("nil preferences allow isolated in memory usage", isolated.records["isolated"]?.openCount == 1 && history.records["isolated"] == nil)
        check("test isolated history never changes persisted history", preferences.data(forKey: preferenceKey) == savedHistory)
        history.prune(siteIDs: ["first"])
        check("pruning deleted sites retains visible statistics", history.records.keys.sorted() == ["first"] && WebsiteLaunchHistory(preferences: preferences).records == history.records)
        let pruned = preferences.data(forKey: preferenceKey)
        history.prune(siteIDs: ["first"])
        check("unchanged prune does not rewrite bytes", preferences.data(forKey: preferenceKey) == pruned)
        let malformedData = Data("{broken".utf8)
        preferences.set(malformedData, forKey: preferenceKey)
        check("corrupt data safely loads empty without changing it", WebsiteLaunchHistory(preferences: preferences).records.isEmpty && preferences.data(forKey: preferenceKey) == malformedData)
        let invalidSaved: [String: WebsiteLaunchUsage] = ["valid": WebsiteLaunchUsage(openCount: 4, lastOpenedAt: 40),
            "negativeCount": WebsiteLaunchUsage(openCount: -1, lastOpenedAt: 40),
            "negativeDate": WebsiteLaunchUsage(openCount: 1, lastOpenedAt: -1),
            "nanDate": WebsiteLaunchUsage(openCount: 1, lastOpenedAt: .nan),
            "infiniteDate": WebsiteLaunchUsage(openCount: 1, lastOpenedAt: .infinity),
            "": WebsiteLaunchUsage(openCount: 1, lastOpenedAt: 50)]
        let invalidEncoder = JSONEncoder()
        invalidEncoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        let invalidSavedData = try invalidEncoder.encode(invalidSaved)
        preferences.set(invalidSavedData, forKey: preferenceKey)
        check("invalid saved records are skipped while valid records survive", WebsiteLaunchHistory(preferences: preferences).records == ["valid": WebsiteLaunchUsage(openCount: 4, lastOpenedAt: 40)])
        check("sanitizing while loading never rewrites saved history", preferences.data(forKey: preferenceKey) == invalidSavedData)
        preferences.set(try JSONEncoder().encode(["saturated": WebsiteLaunchUsage(openCount: Int.max, lastOpenedAt: 50)]), forKey: preferenceKey)
        let saturated = WebsiteLaunchHistory(preferences: preferences)
        saturated.record(siteID: "saturated", at: Date(timeIntervalSince1970: 60))
        check("maximum count saturates without overflow and time updates", saturated.records["saturated"] == WebsiteLaunchUsage(openCount: Int.max, lastOpenedAt: 60))
        let oversized = Dictionary(uniqueKeysWithValues: (0..<5001).map { ("record-\($0)", WebsiteLaunchUsage(openCount: 1, lastOpenedAt: Double($0))) })
        let oversizedData = try JSONEncoder().encode(oversized)
        preferences.set(oversizedData, forKey: preferenceKey)
        let bounded = WebsiteLaunchHistory(preferences: preferences)
        check("oversized history retains at most five thousand newest sites", bounded.records.count == 5000 && bounded.records["record-0"] == nil && bounded.records["record-5000"] != nil)
        check("bounded loading is read only", preferences.data(forKey: preferenceKey) == oversizedData)
        bounded.record(siteID: "new", at: Date(timeIntervalSince1970: 6000))
        check("recording a new site evicts oldest at the history limit", bounded.records.count == 5000 && bounded.records["new"]?.openCount == 1 && bounded.records["record-1"] == nil)
        check("bounded history persists after another launch", WebsiteLaunchHistory(preferences: preferences).records == bounded.records)
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

        let compactSizes: [(count: Int, height: CGFloat)] = [
            (0, 178), (1, 160), (6, 390), (8, 482), (9, 482),
            (-1, 178), (Int.min, 178), (Int.max, 482)
        ]
        for fixture in compactSizes {
            check("compact size for \(fixture.count) sites", FloatingLauncherGeometry.expandedSize(siteCount: fixture.count) == CGSize(width: 364, height: fixture.height))
        }
        let sixRows = FloatingLauncherGeometry.expandedSize(siteCount: 6)
        check("adding a seventh row increases only one row height", FloatingLauncherGeometry.expandedSize(siteCount: 7).height - sixRows.height == 46)
        check("eight row viewport is shorter than old fixed window", FloatingLauncherGeometry.expandedSize(siteCount: 8).height < expandedSize.height)

        let geometryFixtures: [(count: Int, height: CGFloat)] = [(0, 178), (1, 160), (6, 390), (8, 482), (Int.max, 482)]
        for edge in [FloatingLauncherEdge.left, .right, .none] {
            let anchorX = edge == .right ? leftScreen.maxX - collapsedSize.width : edge == .left ? leftScreen.minX : -900
            let compactAnchor = CGRect(x: anchorX, y: 750, width: collapsedSize.width, height: collapsedSize.height)
            for fixture in geometryFixtures {
                let dynamicSize = FloatingLauncherGeometry.expandedSize(siteCount: fixture.count)
                let dynamicFrame = FloatingLauncherGeometry.resizedFrame(compactAnchor, size: dynamicSize, in: leftScreen, edge: edge)
                check("compact \(edge.rawValue) frame for \(fixture.count) sites keeps exact size and top", dynamicFrame.size == CGSize(width: 364, height: fixture.height) && dynamicFrame.maxY == compactAnchor.maxY && leftScreen.contains(dynamicFrame))
                check("compact \(edge.rawValue) frame for \(fixture.count) sites keeps horizontal anchor", edge == .right ? dynamicFrame.maxX == compactAnchor.maxX : dynamicFrame.minX == compactAnchor.minX)

                let bottomCompactAnchor = CGRect(x: anchorX, y: leftScreen.minY, width: collapsedSize.width, height: collapsedSize.height)
                let bottomCompact = FloatingLauncherGeometry.resizedFrame(bottomCompactAnchor, size: dynamicSize, in: leftScreen, edge: edge)
                check("compact \(edge.rawValue) frame for \(fixture.count) sites stays above screen bottom", bottomCompact.minY == leftScreen.minY && bottomCompact.size == dynamicSize && leftScreen.contains(bottomCompact))

                let smallCompact = FloatingLauncherGeometry.resizedFrame(compactAnchor, size: dynamicSize, in: tiny, edge: edge)
                check("compact \(edge.rawValue) frame for \(fixture.count) sites fits a screen smaller than the content", smallCompact == tiny)
            }
        }
        print("Floating launcher logic: \(count) checks passed")
    }
}
