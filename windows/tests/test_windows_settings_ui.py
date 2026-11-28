"""Headless coverage for the Windows settings rail and modal forms."""

from gaomenhu.errors import AppError
from test_launcher_ui import launcher_page, pytestmark


def test_settings_navigation_and_editor_focus_at_high_dpi(launcher_page, tmp_path):
    page, service, _, origin = launcher_page
    page.call("Emulation.setDeviceMetricsOverride", width=492, height=510, deviceScaleFactor=1.5, mobile=False)
    page.call("Emulation.setEmulatedMedia", features=[{"name": "prefers-reduced-motion", "value": "reduce"}])
    page.call("Page.navigate", url=origin + "/settings")
    page.until("document.activeElement?.id === 'settings-tab-modules'")
    assert page.js("document.querySelector('#launcherSettingsTabs').getAttribute('aria-orientation')") == "horizontal"
    assert page.js("devicePixelRatio === 1.5 && document.documentElement.scrollWidth === innerWidth")

    page.key("ArrowRight", "ArrowRight", 39)
    page.until("document.activeElement.id === 'settings-tab-browsers'")
    page.key("ArrowRight", "ArrowRight", 39)
    page.until("document.activeElement.id === 'settings-tab-appearance'")
    page.change("#settingsAppearance", "dark")
    page.until("document.body.classList.contains('dark') && document.querySelector('#preferencesStatus').dataset.kind === 'saved'")
    assert service.store.library["appearance"] == "dark"
    page.key("End", "End", 35)
    page.until("document.activeElement.id === 'settings-tab-data'")
    page.capture(tmp_path / "settings-narrow-dark-150.png")
    page.click("#openActionPackage")
    page.until("document.activeElement.id === 'actionPath'")
    page.key("Escape", "Escape", 27)
    page.until("document.activeElement.id === 'settings-tab-data'")

    page.call("Page.navigate", url=origin + "/?offline")
    page.until("document.body.classList.contains('dark') && Boolean(document.querySelector('#grid .tile'))")
    page.click("#addButton")
    page.until("document.activeElement.id === 'siteName'")
    assert page.js("document.querySelector('#dialog').getAttribute('aria-labelledby') === 'windows-dialog-title'")
    assert page.js("document.querySelector('#siteForm .windows-dialog-content').scrollHeight > document.querySelector('#siteForm .windows-dialog-content').clientHeight")
    page.fill("#siteName", "窄窗键盘工作台")
    page.fill("#siteURL", "https://example.test/narrow")
    page.click("#browserOptions .browser-choice.selected input")
    page.click("#saveSite")
    page.until("document.querySelector('#formError').textContent.includes('至少选择一个浏览器')")
    assert page.js("document.querySelector('#formError').getAttribute('role') === 'alert'")
    assert page.js("document.querySelector('#saveSite').getBoundingClientRect().bottom < innerHeight")
    page.capture(tmp_path / "site-editor-error-narrow-dark-150.png")

    page.js("document.querySelector('#dialog .close').focus()")
    page.key("Tab", "Tab", 9, modifiers=8)
    assert page.js("document.activeElement.id") == "saveSite"
    page.key("Tab", "Tab", 9)
    assert page.js("document.activeElement.matches('#dialog .close')")
    page.click("#browserOptions .browser-choice:first-child input")
    page.click("#addAccount")
    page.until("document.activeElement.dataset.field === 'label'")
    page.fill('[data-field="label"]', "键盘回归账号")
    page.fill('[data-field="username"]', "keyboard@example.test")
    page.click("#saveSite")
    page.until("document.querySelector('#dialogOverlay').hidden")
    saved = next(site for site in service.store.library["sites"] if site["name"] == "窄窗键盘工作台")
    assert saved["accounts"][0]["label"] == "键盘回归账号"
    assert not page.errors


def test_settings_recovers_from_startup_failure(launcher_page, monkeypatch):
    page, service, _, origin = launcher_page
    page.until("Boolean(document.querySelector('#grid .tile'))")
    original_state = service.state
    response_errors = iter([AppError("设置服务暂时不可用。")])

    def temporary_state_failure(*args, **kwargs):
        failure = next(response_errors, None)
        if failure:
            raise failure
        return original_state(*args, **kwargs)

    monkeypatch.setattr(service, "state", temporary_state_failure)
    page.call("Page.navigate", url=origin + "/settings")
    page.until("document.querySelector('#settingsStartupStatus')?.getAttribute('role') === 'alert'")
    assert "设置服务暂时不可用" in page.js("document.querySelector('#settingsStartupStatus').textContent")
    assert page.js("document.activeElement.id") == "settingsRetry"
    page.call("Input.dispatchKeyEvent", type="keyDown", key="Enter", code="Enter", windowsVirtualKeyCode=13, text="\r")
    page.call("Input.dispatchKeyEvent", type="keyUp", key="Enter", code="Enter", windowsVirtualKeyCode=13)
    page.until("document.activeElement.id === 'settings-tab-modules'")
    assert not page.errors
