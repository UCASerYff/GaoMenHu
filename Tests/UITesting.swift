#if DEBUG_TESTING
import Foundation
import AppKit
import WebKit

extension AppDelegate {
    func runAutomatedTests() {
        let featureChecks = runNativeFeatureChecks()
        var settingsChecks: [String: Bool] = [:]
        let savedLibrary = library
        do {
            library.appearance = "dusk"
            settingsChecks["legacyThemeFollowsSystem"] = effectiveAppearance == "system"
            try updateSettings(appearance: "dark", density: "compact", iconSize: 92)
            settingsChecks["darkAppearanceApplied"] = NSApp.appearance?.name == .darkAqua && library.appearance == "dark"
            settingsChecks["layoutPreferencesSaved"] = library.layoutDensity == "compact" && library.iconSize == 92
            try updateSettings(appearance: "light")
            settingsChecks["lightAppearanceApplied"] = NSApp.appearance?.name == .aqua
            try updateSettings(appearance: "system")
            settingsChecks["systemAppearanceApplied"] = NSApp.appearance == nil
            let beforeInvalid = library
            do { try updateSettings(appearance: "unknown"); settingsChecks["invalidAppearanceRejected"] = false }
            catch { settingsChecks["invalidAppearanceRejected"] = library == beforeInvalid }
            settings()
            let firstWindow = settingsWindow
            settings()
            settingsChecks["nativeSettingsWindowReused"] = settingsWindow === firstWindow && settingsWindow?.title == "搞门户设置"
            settingsChecks["nativeSettingsSize"] = settingsWindow?.contentView?.frame.size == NSSize(width: 820, height: 740)
            settingsChecks["nativeToolbarHasSidebar"] = window.toolbar?.items.contains { $0.itemIdentifier.rawValue == "sidebar" } == true
            settingsChecks["nativeDataMenuAvailable"] = NSApp.mainMenu?.items.contains { $0.submenu?.title == "数据" } == true
            settingsWindow?.orderOut(nil)
        } catch { settingsChecks["setup"] = false }
        library = savedLibrary; applyAppearance(); window.makeKeyAndOrderFront(nil)
        var floatingChecks: [String: Bool] = [:]
        if let floating = floatingLauncher {
            floating.setVisible(true)
            floating.setDock(.right)
            floatingChecks["visibleWhenEnabled"] = floating.isVisible && floating.panel.isVisible
            floatingChecks["nonactivatingNativePanel"] = floating.panel.styleMask.contains(.nonactivatingPanel) && !floating.panel.canBecomeMain
            floatingChecks["allSpacesAvailable"] = floating.panel.collectionBehavior.contains(.canJoinAllSpaces)
            floatingChecks["startsAsNarrowVerticalEntry"] = floating.edgeHidden && floating.panel.frame.size == NSSize(width: 20, height: 104)
            func findView(_ id: String, in view: NSView) -> NSView? {
                if view.identifier?.rawValue == id { return view }
                return view.subviews.compactMap { findView(id, in: $0) }.first
            }
            floating.setExpanded(true)
            floatingChecks["expandedPanelSize"] = floating.expanded &&
                floating.panel.frame.size == FloatingLauncherGeometry.expandedSize(siteCount: floating.visibleSiteIDs.count)
            let originalHistory = launchHistory
            launchHistory = WebsiteLaunchHistory(preferences: nil)
            for _ in 0..<12 { launchHistory.record(siteID: "seed-5", at: Date(timeIntervalSince1970: 10)) }
            for (index, id) in ["seed-0", "seed-1", "seed-2"].enumerated() {
                launchHistory.record(siteID: id, at: Date(timeIntervalSince1970: Double(20 + index)))
            }
            floating.refresh()
            floatingChecks["recentAndFrequentAppearFirst"] = Array(floating.visibleSiteIDs.prefix(4)) == ["seed-2", "seed-1", "seed-0", "seed-5"]
            let beforeUsage = library
            recordWebsiteOpen(siteID: "seed-4")
            floatingChecks["successfulOpenRefreshesRecommendation"] = Array(floating.visibleSiteIDs.prefix(4)) == ["seed-4", "seed-2", "seed-1", "seed-5"]
            floatingChecks["usageDoesNotRewriteLibrary"] = library == beforeUsage
            if let content = floating.panel.contentView {
                func labels(in view: NSView) -> [String] {
                    (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap { labels(in: $0) }
                }
                floatingChecks["floatingHasNoProductTitleOrVersion"] = !labels(in: content).contains {
                    $0 == "搞门户" || $0.contains("V" + version) || $0.contains("最近使用优先")
                }
                func hasImageView(in view: NSView) -> Bool {
                    view is NSImageView || view.subviews.contains { hasImageView(in: $0) }
                }
                let header = findView("GaoMenHu.Floating.DragArea", in: content)
                floatingChecks["floatingHeaderHasNoAppIcon"] = header.map { !hasImageView(in: $0) } ?? false
                func hasButton(in view: NSView) -> Bool {
                    view is NSButton || view.subviews.contains { hasButton(in: $0) }
                }
                floatingChecks["floatingHeaderHasNoButtons"] = header.map { !hasButton(in: $0) } ?? false
                floatingChecks["floatingHeaderIsShortDragArea"] = header?.frame.height == 24
            } else { floatingChecks["floatingHasNoProductTitleOrVersion"] = false }
            launchHistory = originalHistory; floating.refresh()
            floating.search("blbl")
            floatingChecks["nativeSearchAcceptsPinyin"] = floating.visibleSiteIDs == ["seed-4"]
            floating.search("gaomenhu-no-result-fixture")
            floatingChecks["nativeEmptySearchResult"] = floating.visibleSiteIDs.isEmpty
            floatingChecks["emptySearchUsesCompactHeight"] = floating.panel.frame.size == NSSize(width: 364, height: 178)
            if let content = floating.panel.contentView {
                func findEmptyLabel(_ view: NSView) -> NSTextField? {
                    if let label = view as? NSTextField, label.stringValue.contains("没有匹配的网站") { return label }
                    return view.subviews.compactMap { findEmptyLabel($0) }.first
                }
                if let empty = findEmptyLabel(content), let parent = empty.superview {
                    floatingChecks["emptySearchMessageFitsList"] = parent.bounds.contains(empty.frame) &&
                        content.bounds.contains(empty.convert(empty.bounds, to: content))
                } else { floatingChecks["emptySearchMessageFitsList"] = false }
            } else { floatingChecks["emptySearchMessageFitsList"] = false }
            floating.search("")
            let heightLibrary = library
            var heightSites = heightLibrary.sites
            while heightSites.count < 11, var extra = heightLibrary.sites.first {
                extra.id = "floating-height-fixture-\(heightSites.count)"
                extra.name = "高度测试 \(heightSites.count)"
                heightSites.append(extra)
            }
            for count in [0, 1, 6, 8, 11] {
                let sites = Array(heightSites.prefix(count))
                library = Library(sites: sites, tiles: sites.map { Tile(id: $0.id, kind: "site", name: nil, children: nil) })
                floating.search("")
                let expected = FloatingLauncherGeometry.expandedSize(siteCount: min(count, 8))
                floatingChecks["heightFollowsResultCount-\(count)"] = floating.expanded &&
                    floating.visibleSiteIDs.count == min(count, 8) && floating.panel.frame.size == expected
            }
            floating.search("https")
            floatingChecks["manySearchResultsKeepCompactHeight"] = floating.visibleSiteIDs.count == 11 &&
                floating.panel.frame.size == NSSize(width: 364, height: 482)
            if let content = floating.panel.contentView {
                func findListScroll(_ view: NSView) -> NSScrollView? {
                    if let list = view as? NSScrollView { return list }
                    return view.subviews.compactMap { findListScroll($0) }.first
                }
                floatingChecks["manySearchResultsRemainScrollable"] = findListScroll(content).map {
                    ($0.documentView?.frame.height ?? 0) > $0.contentSize.height
                } ?? false
            } else { floatingChecks["manySearchResultsRemainScrollable"] = false }
            library = heightLibrary; floating.search("")
            floatingChecks["refreshRestoresHeightWithoutReopening"] = floating.expanded &&
                floating.panel.frame.size == NSSize(width: 364, height: 390)
            floating.setExpanded(false)
            floatingChecks["collapsedPanelSize"] = !floating.expanded && floating.edgeHidden && floating.panel.frame.size == NSSize(width: 20, height: 104)
            floatingChecks["collapseClearsQuery"] = floating.query.isEmpty
            let handleFrame = floating.panel.frame
            let insideHandle = NSPoint(x: handleFrame.midX, y: handleFrame.midY)
            let outside = NSPoint(x: handleFrame.minX - 1000, y: handleFrame.minY - 1000)
            let clock = ProcessInfo.processInfo.systemUptime + 3
            floating.processPointer(at: outside, now: clock - 0.1)
            floating.processPointer(at: insideHandle, now: clock)
            floating.processPointer(at: insideHandle, now: clock + 0.3)
            floatingChecks["hoverDelayPreventsAccidentalReveal"] = floating.edgeHidden
            floating.processPointer(at: insideHandle, now: clock + 0.5)
            floatingChecks["hoverRevealsAfterDelay"] = floating.expanded && !floating.edgeHidden
            floating.processPointer(at: outside, now: clock + 0.7)
            floating.processPointer(at: outside, now: clock + 0.84)
            floatingChecks["pointerExitDelayPreventsFlicker"] = floating.expanded
            floating.processPointer(at: outside, now: clock + 0.86)
            floatingChecks["pointerExitReturnsToHandle"] = floating.edgeHidden && !floating.expanded
            floatingChecks["pointerExitHasNoOpeningGrace"] = floating.edgeHidden && !floating.expanded
            floatingChecks["modeChangesKeepAnchor"] = floating.panel.frame == handleFrame
            floating.processPointer(at: insideHandle, now: clock + 1)
            floating.processPointer(at: insideHandle, now: clock + 2)
            floatingChecks["collapseDoesNotImmediatelyHoverReopen"] = floating.edgeHidden && !floating.expanded
            floating.processPointer(at: outside, now: clock + 2.1)
            floating.processPointer(at: insideHandle, now: clock + 2.2)
            floating.processPointer(at: insideHandle, now: clock + 2.7)
            floatingChecks["leavingEntryRearmsHoverReveal"] = floating.expanded && !floating.edgeHidden
            floating.setExpanded(true)
            let insidePanel = NSPoint(x: floating.panel.frame.midX, y: floating.panel.frame.midY)
            floating.processPointer(at: insidePanel, now: clock + 10)
            floating.processPointer(at: insidePanel, now: clock + 11)
            floatingChecks["pointerInsideKeepsPanelOpen"] = floating.expanded
            floating.processPointer(at: outside, now: clock + 20, mouseDown: true)
            floating.processPointer(at: outside, now: clock + 20.16, mouseDown: true)
            floatingChecks["externalPressedMouseDoesNotProtectPanel"] = floating.edgeHidden && !floating.expanded
            floating.setExpanded(true)
            floating.processMouseDown(at: insidePanel)
            floating.processPointer(at: outside, now: clock + 21, mouseDown: true)
            floating.processPointer(at: outside, now: clock + 22, mouseDown: true)
            floatingChecks["internalPressedMouseProtectsPanel"] = floating.expanded
            floating.processMouseUp(at: outside, now: clock + 22.1)
            floating.processPointer(at: outside, now: clock + 22.24)
            floatingChecks["internalMouseReleaseUsesShortExitDelay"] = floating.expanded
            floating.processPointer(at: outside, now: clock + 22.26)
            floatingChecks["internalMouseReleaseRestoresAutoHide"] = floating.edgeHidden && !floating.expanded
            for (index, side) in ["left", "right", "top", "bottom"].enumerated() {
                floating.setExpanded(true)
                let frame = floating.panel.frame
                let point: NSPoint
                switch side {
                case "left": point = NSPoint(x: frame.minX - 1, y: frame.midY)
                case "right": point = NSPoint(x: frame.maxX + 1, y: frame.midY)
                case "top": point = NSPoint(x: frame.midX, y: frame.maxY + 1)
                default: point = NSPoint(x: frame.midX, y: frame.minY - 1)
                }
                let start = clock + 23 + Double(index)
                floating.processPointer(at: point, now: start)
                floating.processPointer(at: point, now: start + 0.14)
                floatingChecks["onePointExitHasBriefDelay-\(side)"] = floating.expanded
                floating.processPointer(at: point, now: start + 0.16)
                floatingChecks["onePointExitCollapses-\(side)"] = floating.edgeHidden && !floating.expanded
            }
            floating.setExpanded(true)
            floating.processPointer(at: outside, now: clock + 27)
            floating.processPointer(at: insidePanel, now: clock + 27.1)
            floating.processPointer(at: insidePanel, now: clock + 28)
            floatingChecks["returnBeforeExitDelayCancelsCollapse"] = floating.expanded
            for kind in ["left", "right"] {
                floating.processMouseDown(at: outside)
                floatingChecks["externalMouseDownImmediatelyCollapses-\(kind)"] = floating.edgeHidden && !floating.expanded && floating.isVisible
                floating.processMouseUp(at: outside, now: clock + 29)
                floating.setExpanded(true)
            }
            let testMenu = NSMenu()
            floating.menuWillOpen(testMenu)
            floating.processMouseDown(at: outside)
            floating.processPointer(at: outside, now: clock + 30)
            floating.processPointer(at: outside, now: clock + 31)
            floatingChecks["contextMenuProtectsPanel"] = floating.expanded
            floating.menuDidClose(testMenu)
            floating.processPointer(at: outside, now: clock + 32)
            floating.processPointer(at: outside, now: clock + 32.16)
            floatingChecks["menuCloseRestoresAutoHide"] = floating.edgeHidden
            if let content = floating.panel.contentView,
               let dragArea = findView("GaoMenHu.Floating.DragArea", in: content),
               let down = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                              windowNumber: floating.panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
               let up = NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0,
                                            windowNumber: floating.panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0) {
                floating.setExpanded(true)
                dragArea.mouseDown(with: down)
                floating.processMouseDown(at: outside)
                floating.processPointer(at: outside, now: clock + 35)
                floating.processPointer(at: outside, now: clock + 36)
                floatingChecks["dragAreaPressProtectsPanel"] = floating.expanded
                dragArea.mouseUp(with: up)
                floating.processPointer(at: outside, now: clock + 37)
                floating.processPointer(at: outside, now: clock + 37.16)
                floatingChecks["dragAreaReleaseRestoresAutoHide"] = floating.edgeHidden
            } else { floatingChecks["dragAreaPressProtectsPanel"] = false }
            floating.setExpanded(true)
            func findSearch(_ view: NSView) -> NSSearchField? {
                if let field = view as? NSSearchField { return field }
                return view.subviews.compactMap { findSearch($0) }.first
            }
            if let content = floating.panel.contentView, let field = findSearch(content) {
                floating.panel.makeKey(); floating.panel.makeFirstResponder(field)
                floating.search("blbl")
                floating.processPointer(at: outside, now: clock + 40)
                floating.processPointer(at: outside, now: clock + 40.14)
                floatingChecks["searchExitUsesBriefDelay"] = floating.expanded
                floating.processPointer(at: outside, now: clock + 40.16)
                floatingChecks["searchFocusDoesNotDelayAutoHide"] = floating.edgeHidden && !floating.expanded && floating.isVisible
                floatingChecks["autoHideClearsSearchAndFocus"] = floating.query.isEmpty && !(floating.panel.firstResponder is NSTextView)
                floating.setExpanded(true); floating.panel.makeKey(); floating.panel.makeFirstResponder(field)
                floating.search("blbl")
                floating.processMouseDown(at: outside)
                floatingChecks["searchExternalClickImmediatelyCollapses"] = floating.edgeHidden && !floating.expanded &&
                    floating.query.isEmpty && !(floating.panel.firstResponder is NSTextView)
                floating.processMouseUp(at: outside, now: clock + 42)
                floating.setExpanded(true); floating.panel.makeKey(); floating.panel.makeFirstResponder(field)
                if let editor = floating.panel.firstResponder as? NSTextView {
                    editor.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
                    floating.processPointer(at: outside, now: clock + 43)
                    floating.processPointer(at: outside, now: clock + 44)
                    floating.processMouseDown(at: outside)
                    floatingChecks["markedChineseInputProtectsPanel"] = floating.expanded && editor.hasMarkedText()
                    editor.unmarkText()
                    floating.processMouseUp(at: outside, now: clock + 44.1)
                    floating.processPointer(at: outside, now: clock + 44.26)
                    floatingChecks["completedChineseInputRestoresAutoHide"] = floating.edgeHidden && !floating.expanded
                } else { floatingChecks["markedChineseInputProtectsPanel"] = false }
                floating.setExpanded(true); floating.panel.makeKey(); floating.panel.makeFirstResponder(field)
                if let editor = floating.panel.firstResponder as? NSTextView {
                    editor.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
                    window.makeKeyAndOrderFront(nil)
                    floating.processPointer(at: outside, now: clock + 46)
                    floating.processPointer(at: outside, now: clock + 46.16)
                    floatingChecks["markedInputLosingKeyFocusAllowsAutoHide"] = !floating.panel.isKeyWindow &&
                        floating.edgeHidden && !floating.expanded && floating.isVisible
                    editor.unmarkText()
                } else { floatingChecks["markedInputLosingKeyFocusAllowsAutoHide"] = false }
                floating.setExpanded(true); floating.panel.makeKey(); floating.panel.makeFirstResponder(field)
                floating.search("blbl")
                window.makeKeyAndOrderFront(nil)
                floating.processPointer(at: outside, now: clock + 50.1)
                floating.processPointer(at: outside, now: clock + 50.26)
                floatingChecks["searchLosesKeyFocusAllowsAutoHide"] = floating.edgeHidden && !floating.expanded
            } else { floatingChecks["searchFocusDoesNotDelayAutoHide"] = false }
            if let content = floating.panel.contentView,
               let handle = findView("GaoMenHu.Floating.EdgeHandle", in: content) {
                for (index, edge) in [FloatingLauncherEdge.left, .right, .none].enumerated() {
                    let start = clock + 60 + Double(index) * 10
                    floating.setExpanded(false); floating.setDock(edge)
                    let frame = floating.panel.frame
                    let point = NSPoint(x: frame.midX, y: frame.midY)
                    floatingChecks["uniformVerticalEntry-\(edge.rawValue)"] = floating.isVisible && floating.edgeHidden &&
                        !floating.expanded && frame.size == NSSize(width: 20, height: 104) && floating.dockEdge == edge
                    floatingChecks["entryWithinDisplay-\(edge.rawValue)"] = NSScreen.screens.contains { $0.visibleFrame.contains(frame) }
                    if edge != .none {
                        floatingChecks["entryTouchesRequestedEdge-\(edge.rawValue)"] = NSScreen.screens.contains {
                            $0.visibleFrame.contains(frame) && (edge == .left ? frame.minX == $0.visibleFrame.minX : frame.maxX == $0.visibleFrame.maxX)
                        }
                    }
                    floating.processPointer(at: outside, now: start - 0.1)
                    floating.processPointer(at: point, now: start)
                    floating.processPointer(at: point, now: start + 0.5)
                    floatingChecks["hoverRevealsWithoutReenable-\(edge.rawValue)"] = floating.expanded && floating.isVisible
                    floating.search("blbl")
                    floating.processPointer(at: outside, now: start + 2)
                    floating.processPointer(at: outside, now: start + 2.6)
                    floatingChecks["exitPreservesEntry-\(edge.rawValue)"] = floating.isVisible && !floating.expanded &&
                        floating.edgeHidden && floating.query.isEmpty && floating.panel.frame == frame && floating.dockEdge == edge
                    let clicked = handle.accessibilityPerformPress()
                    floatingChecks["clickRevealsWithoutReenable-\(edge.rawValue)"] = clicked && floating.isVisible && floating.expanded
                    floating.setExpanded(false)
                }
            } else { floatingChecks["entryHandleAvailable"] = false }
            let migrationSuite = "cn.mendao.tests.floating-migration." + UUID().uuidString
            if let preferences = UserDefaults(suiteName: migrationSuite), let screen = NSScreen.main ?? NSScreen.screens.first {
                defer { preferences.removePersistentDomain(forName: migrationSuite) }
                let visible = screen.visibleFrame
                let savedX = visible.minX + min(200, max(0, visible.width - 20))
                let savedTop = visible.maxY - min(160, max(0, visible.height - 104))
                preferences.set(false, forKey: "GaoMenHu.Floating.AutoHide")
                preferences.set("free", forKey: "GaoMenHu.Floating.Dock")
                preferences.set(true, forKey: "GaoMenHu.Floating.Enabled")
                preferences.set(Double(savedX), forKey: "GaoMenHu.Floating.X")
                preferences.set(Double(savedTop), forKey: "GaoMenHu.Floating.Top")
                let migrated = FloatingLauncherController(app: self, testPreferences: preferences)
                migrated.start()
                let migratedFrame = migrated.panel.frame
                floatingChecks["legacyAutoHideOverrideRemoved"] = preferences.object(forKey: "GaoMenHu.Floating.AutoHide") == nil
                floatingChecks["legacyFreeModeMigratesToVerticalEntry"] = migrated.isVisible && migrated.edgeHidden &&
                    !migrated.expanded && migrated.dockEdge == .none && migratedFrame.size == NSSize(width: 20, height: 104)
                floatingChecks["legacyFreePositionPreserved"] = migratedFrame.minX == savedX && migratedFrame.maxY == savedTop &&
                    preferences.double(forKey: "GaoMenHu.Floating.X") == Double(savedX) &&
                    preferences.double(forKey: "GaoMenHu.Floating.Top") == Double(savedTop)
                let point = NSPoint(x: migratedFrame.midX, y: migratedFrame.midY)
                migrated.processPointer(at: point, now: clock + 100)
                migrated.processPointer(at: point, now: clock + 100.5)
                floatingChecks["migratedEntryAllowsHoverReveal"] = migrated.isVisible && migrated.expanded
                migrated.processPointer(at: outside, now: clock + 102)
                migrated.processPointer(at: outside, now: clock + 102.6)
                floatingChecks["migratedFreeModeAutoHidesWithoutOverride"] = migrated.isVisible && migrated.edgeHidden &&
                    !migrated.expanded && migrated.panel.frame == migratedFrame
                let clicked = migrated.panel.contentView.flatMap { findView("GaoMenHu.Floating.EdgeHandle", in: $0) }?.accessibilityPerformPress() == true
                floatingChecks["migratedEntryAllowsClickReveal"] = clicked && migrated.expanded && migrated.isVisible
                migrated.stop()
                preferences.set(false, forKey: "GaoMenHu.Floating.Enabled")
                preferences.set(false, forKey: "GaoMenHu.Floating.AutoHide")
                let disabled = FloatingLauncherController(app: self, testPreferences: preferences)
                disabled.start()
                disabled.processPointer(at: point, now: clock + 110)
                disabled.processPointer(at: point, now: clock + 111)
                floatingChecks["legacyDisabledPreferenceRespected"] = !disabled.isVisible && !disabled.expanded &&
                    preferences.object(forKey: "GaoMenHu.Floating.Enabled") as? Bool == false
                floatingChecks["disabledMigrationRemovesOnlyAutoHideOverride"] =
                    preferences.object(forKey: "GaoMenHu.Floating.AutoHide") == nil && disabled.dockEdge == .none &&
                    preferences.double(forKey: "GaoMenHu.Floating.X") == Double(savedX) &&
                    preferences.double(forKey: "GaoMenHu.Floating.Top") == Double(savedTop)
                disabled.stop()
            } else { floatingChecks["migrationFixtureCreated"] = false }
            window.orderOut(nil)
            floatingChecks["independentOfMainWindow"] = floating.panel.isVisible && !window.isVisible
            floating.setVisible(false)
            floatingChecks["hiddenWhenDisabled"] = !floating.isVisible && !floating.panel.isVisible
            floating.setVisible(true); floating.resetPosition(); floating.setExpanded(true)
            floatingChecks["restoredWithinDisplay"] = NSScreen.screens.contains { $0.visibleFrame.contains(floating.panel.frame) }
            floating.showStatus("点击网站打开，右键选择浏览器")
            floating.capturePreview(to: URL(fileURLWithPath: "/private/tmp/mendao-floating-test.png"))
            floatingChecks["previewRendered"] = FileManager.default.fileExists(atPath: "/private/tmp/mendao-floating-test.png")
            floating.setExpanded(false)
            floating.capturePreview(to: URL(fileURLWithPath: "/private/tmp/mendao-hidden-test.png"))
            floatingChecks["hiddenPreviewRendered"] = FileManager.default.fileExists(atPath: "/private/tmp/mendao-hidden-test.png")
        } else { floatingChecks["controllerCreated"] = false }
        window.makeKeyAndOrderFront(nil)
        var browserChecks: [String: Bool] = [:]
        let profile = UUID().uuidString
        let account = Account(id: UUID().uuidString, label: "Test", username: "test@example.test", loginHosts: ["auth.example.test"], hasPassword: true)
        let site = Website(id: UUID().uuidString, name: "Test", url: "https://example.test", color: "#D97757", allowedBrowsers: ["chrome"], defaultBrowser: "chrome", accounts: [account], defaultAccount: account.id, profiles: [:])
        let initial = library
        do {
            try vault.save("dummy-test-only", id: account.id)
            library.sites.append(site)
            let grant = UUID().uuidString
            launches[grant] = LaunchRequest(id: grant, browser: "chrome", profileID: profile, siteID: site.id, accountID: account.id, url: site.url, allowed: allowedOrigins(site: site, account: account), expires: Date().addingTimeInterval(300), claimedProfile: profile, tabID: 7)
            let extensionID = try String(contentsOf: resources.appendingPathComponent("extension-id.txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            let base: [String: Any] = ["type": "credentials", "extension": extensionID, "browser": "chrome", "profileId": profile, "requestId": grant, "tabId": 7, "url": "https://example.test/login"]
            func accepted(_ changes: [String: Any]) -> Bool {
                var request = base; request.merge(changes) { _, new in new }
                return self.handleBrowser(request)["ok"] as? Bool == true
            }
            browserChecks["allowedOrigin"] = accepted([:])
            browserChecks["allowedLoginHost"] = accepted(["url": "https://auth.example.test/login"])
            browserChecks["rejectWrongOrigin"] = !accepted(["url": "https://example.test.evil.test/login"])
            browserChecks["rejectWrongTab"] = !accepted(["tabId": 8])
            browserChecks["rejectWrongBrowser"] = !accepted(["browser": "edge"])
            browserChecks["rejectWrongProfile"] = !accepted(["profileId": UUID().uuidString])
            browserChecks["rejectPlainHTTP"] = !accepted(["url": "http://example.test/login"])
            browserChecks["rejectWrongExtension"] = !accepted(["extension": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"])
            launches[grant]?.expires = Date().addingTimeInterval(-1)
            browserChecks["rejectExpiredGrant"] = !accepted([:])
            launches[grant]?.expires = Date().addingTimeInterval(300)
            launches[grant]?.filled = true
            browserChecks["rejectConsumedGrant"] = !accepted([:])
        } catch { browserChecks["setup"] = false }
        library = initial; launches.removeAll(); clients.removeAll()
        emit("update", ["state": state()])
        guard let script = try? String(contentsOf: resources.appendingPathComponent("UI.js"), encoding: .utf8) else {
            print("UI test script missing"); NSApp.terminate(nil); return
        }
        web.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { result in
            var report: [String: Any] = ["authorization": browserChecks, "nativeFeatures": featureChecks, "nativeSettings": settingsChecks, "nativeFloating": floatingChecks]
            switch result {
            case .success(let value): report["ui"] = value
            case .failure(let error): report["uiError"] = String(describing: (error as NSError).userInfo)
            }
            let reportURL = URL(fileURLWithPath: "/private/tmp/mendao-test-report.json")
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: reportURL) }
            self.web.takeSnapshot(with: nil) { image, _ in
                if let image, let data = image.tiffRepresentation, let rep = NSBitmapImageRep(data: data), let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: "/private/tmp/mendao-ui-test.png"))
                }
                print("UI_TEST_REPORT=/private/tmp/mendao-test-report.json")
                NSApp.terminate(nil)
            }
        }
    }
}
#endif
