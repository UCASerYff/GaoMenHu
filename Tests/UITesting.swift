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
            var report: [String: Any] = ["authorization": browserChecks, "nativeFeatures": featureChecks, "nativeSettings": settingsChecks]
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
