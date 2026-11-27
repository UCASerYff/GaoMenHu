"""Exercise the Windows workspace shell with an isolated Chromium session."""

from test_launcher_ui import launcher_page, pytestmark


def test_workspace_keyboard_at_narrow_high_dpi(launcher_page, tmp_path):
    page, service, _, _ = launcher_page
    page.call("Emulation.setDeviceMetricsOverride", width=548, height=610, deviceScaleFactor=1.5, mobile=False)
    page.call("Emulation.setEmulatedMedia", features=[dict(name="prefers-color-scheme", value="dark")])
    page.until("document.querySelector('#grid .tile') && document.body.classList.contains('dark')")
    page.key("Tab", "Tab", 9)
    page.until("Boolean(document.querySelector('#launcherButton:focus-visible'))")
    page.key("s", "KeyS", 83, modifiers=3)
    page.until("Boolean(document.querySelector('#workspaceSidebarToggle[aria-expanded=false]:focus-visible'))")
    page.key("s", "KeyS", 83, modifiers=3)
    page.until("Boolean(document.querySelector('#workspaceSidebarToggle[aria-expanded=true]'))")
    assert page.js("document.documentElement.scrollWidth") == 548
    assert page.js("document.querySelector('#fullButton').getBoundingClientRect().width") > 0

    page.key("f", "KeyF", 70, modifiers=2)
    page.until("document.activeElement.id === 'search'")
    page.fill("#search", "隔离测试不存在的网址")
    page.until("document.querySelector('#empty strong')?.textContent === '没有匹配的网站'")
    page.capture(tmp_path / "launcher-search-empty-dark-narrow.png")
    page.click("#workspaceEmptyAction")
    page.until("document.activeElement.id === 'search' && !!document.querySelector('#grid .tile')")
    page.click("#manageButton")
    page.until("Boolean(document.querySelector('#manageButton[aria-pressed=true] svg'))")
    page.key("Escape", "Escape", 27)
    page.until("Boolean(document.querySelector('#manageButton[aria-pressed=false] svg'))")

    site = next(site for site in service.store.library["sites"] if site["id"] == "fixture-0")
    service.save_site({"site": {**site, "name": "跨部门资料校对与用户授权演示入口", "accounts": [
        dict(label="项目协作演示账号", username="reviewer@example.test")
    ]}})
    service.save_workspace(dict(name="项目交付资料与权限审查", siteIDs=[f"fixture-{i}" for i in range(4)]))
    page.call("Page.reload", ignoreCache=True)
    page.until("document.querySelector('#workspaceCount').textContent === '1'")
    page.click("#workspacesButton")
    page.until("document.querySelector('.workspace-scene-extra')?.textContent === '另有 1 个网站'")
    assert page.js("document.querySelector('.workspace-scene-sites small').textContent") == "Edge"
    page.capture(tmp_path / "scenes-dark-narrow.png")
    page.click("#vaultButton")
    page.until("document.querySelector('.vault-account strong')?.textContent === '项目协作演示账号'")
    assert page.js("document.querySelector('.workspace-password-state').textContent") == "未保存密码"
    assert page.js("document.querySelector('[data-delete-account]').getBoundingClientRect().right <= innerWidth")
    page.capture(tmp_path / "vault-dark-narrow.png")
    assert not page.errors


def test_workspace_startup_retries_after_state_request_failure(launcher_page, tmp_path):
    page, _, _, _ = launcher_page
    page.call("Page.enable")
    page.call("Page.addScriptToEvaluateOnNewDocument", source="""
        const realFetch = window.fetch.bind(window);
        window.fetch = (input, options) => {
            if (input !== '/api/launcher/state' || window.rejectFirstWorkspaceState) {
                return realFetch(input, options);
            }
            return new Promise((_, reject) => {
                window.rejectFirstWorkspaceState = () => reject(new Error('隔离测试网络错误'));
            });
        };
    """)
    page.call("Page.reload", ignoreCache=True)
    page.until("typeof window.rejectFirstWorkspaceState === 'function'")
    assert page.js("!!document.querySelector('#workspaceStartup:not([hidden]) .workspace-spinner')")
    page.js("window.rejectFirstWorkspaceState()")
    page.until("document.querySelector('#workspaceStartup strong')?.textContent === '无法加载网站资料'")
    page.capture(tmp_path / "launcher-startup-error.png")
    page.click("#workspaceRetry")
    page.until("document.querySelector('#workspaceStartup').hidden && !!document.querySelector('#grid .tile')")
    assert not page.errors
