"""Run the Windows browser diagnosis panel with synthetic local evidence."""

from gaomenhu import browser_diagnostics, server
from gaomenhu.errors import AppError
from test_launcher_ui import launcher_page, pytestmark


def evidence(status, detail):
    return {"status": status, "detail": detail}


def diagnostics(*, connected):
    return {"ok": True, "browsers": [
        {"id": "chrome", "state": "connected" if connected else "indeterminate",
         "summary": "Chrome 助手已回应。" if connected else "尚未收到 Chrome 助手回应。",
         "browser": evidence("ok", "已找到浏览器程序。"), "package": evidence("ok", "随包助手已核对。"),
         "registration": evidence("ok", "当前用户登记已核对。"),
         "extension": evidence("ok" if connected else "unknown", "已收到心跳。" if connected else "请在目标资料中核对。"),
         "profiles": [{"label": "隔离测试资料 <个人>", "ageSeconds": 12}] if connected else []},
        {"id": "edge", "state": "attention", "summary": "Edge 的主机登记需要修复。",
         "browser": evidence("ok", "已找到浏览器程序。"), "package": evidence("ok", "随包助手已核对。"),
         "registration": evidence("issue", "Windows 助手登记缺失。"),
         "extension": evidence("unknown", "还无法核对扩展是否已启用。"), "profiles": []},
    ]}


def test_browser_diagnostics_from_settings_and_explicit_actions(launcher_page, monkeypatch, tmp_path):
    page, _, _, origin = launcher_page
    reads = []
    opens = []

    def read_diagnostics(service):
        reads.append(service)
        return diagnostics(connected=len(reads) == 1)

    def open_extensions(browser_id=None):
        opens.append(browser_id)
        return {"ok": True}

    monkeypatch.setattr(browser_diagnostics, "diagnose_browsers", read_diagnostics)
    monkeypatch.setattr(server, "open_extension_setup", open_extensions)
    page.call("Emulation.setDeviceMetricsOverride", width=1050, height=750, deviceScaleFactor=1, mobile=False)
    page.call("Page.navigate", url=origin + "/settings")
    page.until("document.activeElement.id === 'settings-tab-modules'")
    assert reads == [] and opens == []
    page.click("#browserDiagnosticsLink")
    page.until("document.querySelector('[data-browser=chrome] .diagnostic-state')?.textContent === '已连接'")
    assert page.js("document.querySelector('#settings-tab-browsers').getAttribute('aria-selected')") == "true"
    assert page.js("document.querySelector('[data-browser=chrome] .diagnostic-profiles li').textContent") == "隔离测试资料 <个人>12 秒前"
    assert page.js("document.querySelector('[data-browser=chrome] .diagnostic-profiles li span').children.length") == 0
    assert page.js("document.querySelector('[data-browser=edge] .diagnostic-state').textContent") == "需处理"
    assert "Windows 主机登记" in page.js("document.querySelector('[data-browser=edge] .diagnostic-issues').textContent")
    assert '注册 Chrome 和 Edge 的搞门户助手' in page.js("document.querySelector('[data-browser=edge]').textContent")
    assert len(reads) == 1 and opens == []

    page.click("[data-browser=edge] summary")
    assert page.js("document.querySelector('[data-browser=edge] details').open")
    assert "Windows 助手登记缺失" in page.js("document.querySelector('[data-browser=edge] [data-status=issue]').nextElementSibling.textContent")
    page.capture(tmp_path / "browser-diagnostics-light.png")
    page.click("[data-diagnostic-browser=chrome]")
    page.until("!document.querySelector('[data-diagnostic-browser=chrome]').disabled")
    assert opens == ["chrome"]
    page.click("#extensionFolder")
    page.until("!document.querySelector('#extensionFolder').disabled")
    assert opens == ["chrome", None]

    page.click("#diagnosticRetry")
    page.until("document.querySelector('[data-browser=chrome] .diagnostic-state')?.textContent === '未能确认'")
    assert page.js("document.activeElement.id") == "diagnosticRetry"
    assert page.js("document.querySelector('[data-browser=edge] details').open")
    assert len(reads) == 2 and opens == ["chrome", None]
    assert not page.errors


def test_browser_diagnostics_narrow_dark_failure_and_retry(launcher_page, monkeypatch, tmp_path):
    page, _, _, origin = launcher_page
    attempts = []

    def inspect_browser(service):
        attempts.append(service)
        if len(attempts) == 1:
            raise AppError("测试诊断暂时不可用。")
        result = diagnostics(connected=False)
        result["browsers"][1]["browser"] = evidence("issue", "测试未发现 Edge。")
        return result

    monkeypatch.setattr(browser_diagnostics, "diagnose_browsers", inspect_browser)
    page.call("Emulation.setDeviceMetricsOverride", width=424, height=480, deviceScaleFactor=1.5, mobile=False)
    page.call("Emulation.setEmulatedMedia", features=[dict(name="prefers-color-scheme", value="dark")])
    page.call("Page.navigate", url=origin + "/settings")
    page.until("document.activeElement.id === 'settings-tab-modules'")
    page.key("ArrowRight", "ArrowRight", 39)
    page.until("document.querySelector('#diagnosticStatus')?.dataset.kind === 'error'")
    assert page.js("document.activeElement.id") == "settings-tab-browsers"
    assert page.js("document.querySelector('#extensionFolder').disabled")
    assert page.js("document.body.classList.contains('dark') && devicePixelRatio === 1.5 && document.documentElement.scrollWidth === innerWidth")
    page.capture(tmp_path / "browser-diagnostics-dark-error.png")
    page.click("#diagnosticRetry")
    page.until("document.querySelector('[data-browser=chrome] .diagnostic-state')?.textContent === '未能确认'")
    assert not page.js("Boolean(document.querySelector('[data-diagnostic-browser=edge]'))")
    assert page.js("document.querySelector('[data-diagnostic-browser=chrome]').getBoundingClientRect().bottom < innerHeight")
    assert page.js("document.querySelector('#launcherSettingsPane').scrollWidth === document.querySelector('#launcherSettingsPane').clientWidth")
    assert page.js("document.querySelector('#diagnosticStatus').getAttribute('role')") == "status"
    page.capture(tmp_path / "browser-diagnostics-dark-narrow-150.png")
    assert len(attempts) == 2 and not page.errors
