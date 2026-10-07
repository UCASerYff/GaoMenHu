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
            floating.setAutoHide(true); floating.setDock(.right)
            floatingChecks["visibleWhenEnabled"] = floating.isVisible && floating.panel.isVisible
            floatingChecks["nonactivatingNativePanel"] = floating.panel.styleMask.contains(.nonactivatingPanel) && !floating.panel.canBecomeMain
            floatingChecks["allSpacesAvailable"] = floating.panel.collectionBehavior.contains(.canJoinAllSpaces)
            floating.setExpanded(true)
            floatingChecks["expandedPanelSize"] = floating.expanded && floating.panel.frame.width >= 300 && floating.panel.frame.height >= 400
            floating.search("blbl")
            floatingChecks["nativeSearchAcceptsPinyin"] = floating.visibleSiteIDs == ["seed-4"]
            floating.search("gaomenhu-no-result-fixture")
            floatingChecks["nativeEmptySearchResult"] = floating.visibleSiteIDs.isEmpty
            floating.search("")
            floating.setExpanded(false)
            floatingChecks["collapsedPanelSize"] = !floating.expanded && floating.edgeHidden && floating.panel.frame.size == NSSize(width: 20, height: 104)
            floatingChecks["collapseClearsQuery"] = floating.query.isEmpty
            let handleFrame = floating.panel.frame
            let insideHandle = NSPoint(x: handleFrame.midX, y: handleFrame.midY)
            let outside = NSPoint(x: handleFrame.minX - 1000, y: handleFrame.minY - 1000)
            let clock = ProcessInfo.processInfo.systemUptime + 3
            floating.processPointer(at: insideHandle, now: clock)
            floating.processPointer(at: insideHandle, now: clock + 0.3)
            floatingChecks["hoverDelayPreventsAccidentalReveal"] = floating.edgeHidden
            floating.processPointer(at: insideHandle, now: clock + 0.5)
            floatingChecks["hoverRevealsAfterDelay"] = floating.expanded && !floating.edgeHidden
            floating.processPointer(at: outside, now: clock + 0.7)
            floating.processPointer(at: outside, now: clock + 1.3)
            floatingChecks["revealGraceProtectsPointerTravel"] = floating.expanded
            floating.processPointer(at: outside, now: clock + 1.6)
            floating.processPointer(at: outside, now: clock + 2.2)
            floatingChecks["pointerExitReturnsToHandle"] = floating.edgeHidden && !floating.expanded
            floatingChecks["modeChangesKeepAnchor"] = floating.panel.frame == handleFrame
            floating.setExpanded(true); floating.setPinned(true)
            floating.processPointer(at: outside, now: clock + 10)
            floating.processPointer(at: outside, now: clock + 11)
            floatingChecks["pinnedPanelDoesNotAutoHide"] = floating.expanded && floating.pinned
            floating.setExpanded(false)
            floatingChecks["explicitCollapseClearsPin"] = !floating.pinned && floating.edgeHidden
            floating.setExpanded(true)
            floating.processPointer(at: outside, now: clock + 20, mouseDown: true)
            floating.processPointer(at: outside, now: clock + 21, mouseDown: true)
            floatingChecks["pressedMouseProtectsPanel"] = floating.expanded
            let testMenu = NSMenu()
            floating.menuWillOpen(testMenu)
            floating.processPointer(at: outside, now: clock + 30)
            floating.processPointer(at: outside, now: clock + 31)
            floatingChecks["contextMenuProtectsPanel"] = floating.expanded
            floating.menuDidClose(testMenu)
            floating.processPointer(at: outside, now: clock + 32)
            floating.processPointer(at: outside, now: clock + 33)
            floatingChecks["menuCloseRestoresAutoHide"] = floating.edgeHidden
            floating.setExpanded(true)
            func findSearch(_ view: NSView) -> NSSearchField? {
                if let field = view as? NSSearchField { return field }
                return view.subviews.compactMap { findSearch($0) }.first
            }
            if let content = floating.panel.contentView, let field = findSearch(content) {
                floating.panel.makeKey(); floating.panel.makeFirstResponder(field)
                floating.processPointer(at: outside, now: clock + 40)
                floating.processPointer(at: outside, now: clock + 41)
                floatingChecks["searchEditingProtectsPanel"] = floating.expanded && floating.panel.firstResponder is NSTextView
                floating.panel.makeFirstResponder(nil)
            } else { floatingChecks["searchEditingProtectsPanel"] = false }
            floating.setExpanded(false); floating.setDock(.left)
            floatingChecks["leftDockHasNarrowHandle"] = floating.edgeHidden && NSScreen.screens.contains { $0.visibleFrame.minX == floating.panel.frame.minX && $0.visibleFrame.contains(floating.panel.frame) }
            floating.setDock(.none)
            floatingChecks["freePositionUsesCompactEntry"] = !floating.edgeHidden && floating.panel.frame.size == NSSize(width: 140, height: 48)
            floating.setExpanded(true)
            floating.processPointer(at: outside, now: clock + 50)
            floating.processPointer(at: outside, now: clock + 51)
            floatingChecks["freePositionDoesNotAutoHide"] = floating.expanded
            floating.setExpanded(false); floating.setDock(.right); floating.setAutoHide(false)
            floatingChecks["autoHideCanBeDisabled"] = !floating.edgeHidden && floating.panel.frame.size == NSSize(width: 140, height: 48)
            floating.setAutoHide(true)
            func findView(_ id: String, in view: NSView) -> NSView? {
                if view.identifier?.rawValue == id { return view }
                return view.subviews.compactMap { findView(id, in: $0) }.first
            }
            if let content = floating.panel.contentView,
               let closeButton = findView("GaoMenHu.Floating.CloseToEntry", in: content) as? NSButton {
                for (edge, autoHide) in [(FloatingLauncherEdge.right, true), (.left, true), (.none, true), (.right, false)] {
                    floating.setDock(edge); floating.setAutoHide(autoHide)
                    floating.setExpanded(true); floating.setPinned(true); floating.search("blbl")
                    closeButton.performClick(nil)
                    let narrow = edge != .none && autoHide
                    floatingChecks["closeKeepsEntry-\(edge.rawValue)-\(autoHide)"] = floating.isVisible && !floating.expanded &&
                        floating.edgeHidden == narrow && !floating.pinned && floating.query.isEmpty &&
                        floating.dockEdge == edge && floating.autoHideEnabled == autoHide
                }
                floating.setDock(.right); floating.setAutoHide(true)
                floating.setExpanded(true); closeButton.performClick(nil)
                let point = NSPoint(x: floating.panel.frame.midX, y: floating.panel.frame.midY)
                floating.processPointer(at: point, now: clock + 80)
                floating.processPointer(at: point, now: clock + 80.5)
                floatingChecks["closeAllowsHoverRevealWithoutReenable"] = floating.isVisible && floating.expanded
                closeButton.performClick(nil)
                let handle = findView("GaoMenHu.Floating.EdgeHandle", in: content)
                let clicked = handle?.accessibilityPerformPress() == true
                floatingChecks["closeAllowsClickRevealWithoutReenable"] = clicked && floating.isVisible && floating.expanded
                floating.setExpanded(false)
            } else { floatingChecks["closeButtonAvailable"] = false }
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
