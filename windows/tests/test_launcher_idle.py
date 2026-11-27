"""Verify Windows launcher polling follows the native hide/show signal."""

from test_launcher_ui import launcher_page, pytestmark


def test_native_hide_stops_polling_and_first_restore_refreshes_immediately(launcher_page):
    page, service, _, _ = launcher_page
    page.until("Boolean(document.querySelector('#grid .tile'))")
    page.js("""(() => {
      window.pollingCalls = [];
      const original = window.fetch;
      window.fetch = (input, options) => {
        if (['/api/launcher/runtime', '/api/actions/queue'].includes(input)) window.pollingCalls.push(input);
        return original(input, options);
      };
      window.gaoSetDesktopHidden(true);
    })()""")
    assert page.js("document.visibilityState") == "visible"
    assert page.js("new Promise(resolve => setTimeout(() => resolve(window.pollingCalls), 2800))") == []
    page.js("window.gaoSetDesktopHidden(false)")
    assert sorted(page.js("window.pollingCalls")) == ["/api/actions/queue", "/api/launcher/runtime"]

    page.click("#addButton")
    page.fill("#siteName", "隔离窗口后台保存")
    page.fill("#siteURL", "https://example.test/background-save")
    page.js("window.gaoSetDesktopHidden(true)")
    assert page.js("document.querySelector('#siteName').value") == "隔离窗口后台保存"
    page.click("#saveSite")
    page.until("document.querySelector('#dialogOverlay').hidden")
    assert any(site["name"] == "隔离窗口后台保存" for site in service.store.library["sites"])
    page.js("window.gaoSetDesktopHidden(false)")
    assert not page.errors
