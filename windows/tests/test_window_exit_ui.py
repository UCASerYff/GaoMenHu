"""Exercise the Windows quit preflight through the shipped loopback pages."""

from gaomenhu.errors import AppError
from test_launcher_ui import launcher_page, pytestmark


IDLE = {"busy": False, "editing": False, "draft": False}


def test_portal_can_finish_or_cancel_edits_after_suspension(launcher_page):
    page, service, _, origin = launcher_page
    page.until("Boolean(document.querySelector('#grid .tile'))")
    assert page.js("gaoCloseState()") == IDLE
    page.click("#addButton")
    page.fill("#siteName", "后台保留的测试网站")
    page.fill("#siteURL", "https://example.test/preserved")
    page.call("Page.setWebLifecycleState", state="frozen")
    page.call("Page.setWebLifecycleState", state="active")
    assert page.js("gaoCloseState()") == IDLE | {"editing": True}
    assert page.js("document.querySelector('#siteName').value") == "后台保留的测试网站"
    page.click("#saveSite")
    page.until("document.querySelector('#dialogOverlay').hidden")
    assert any(site["name"] == "后台保留的测试网站" for site in service.store.library["sites"])
    page.until("!gaoCloseState().busy")

    page.click("#addButton")
    page.fill("#siteName", "已取消的测试网站")
    page.js("window.pywebview = {api:{close_window:()=>{window.fixtureCloseCalls = (window.fixtureCloseCalls || 0) + 1;}}}")
    page.key("w", "KeyW", 87, modifiers=2)
    page.until("document.querySelector('#dialogOverlay').hidden")
    assert not any(site["name"] == "已取消的测试网站" for site in service.store.library["sites"])
    assert page.js("window.fixtureCloseCalls || 0") == 0
    page.key("w", "KeyW", 87, modifiers=2)
    page.until("window.fixtureCloseCalls === 1")

    page.call("Page.navigate", url=origin + "/settings")
    page.until("Boolean(document.querySelector('#settings-tab-appearance'))")
    assert page.js("gaoCloseState()") == IDLE
    page.click("#settings-tab-appearance")
    page.js("""(() => {
        const fetchNow = window.fetch.bind(window);
        window.fetch = (input, options) => input === '/api/appearance'
            ? new Promise(resolve => { window.resumePreference = () => resolve(fetchNow(input, options)); })
            : fetchNow(input, options);
    })()""")
    page.change("#settingsAppearance", "dark")
    page.until("Boolean(window.resumePreference)")
    assert page.js("gaoCloseState()") == IDLE | {"busy": True}
    page.js("window.resumePreference()")
    page.until("!gaoCloseState().busy && document.querySelector('#preferencesStatus').dataset.kind === 'saved'")
    assert service.store.library["appearance"] == "dark"

    page.call("Page.navigate", url=origin + "/downloads")
    page.until("Boolean(document.querySelector('.download-window .empty'))")
    page.click("button[title='新建下载']")
    page.fill(".download-links", "https://example.invalid/review.pdf")
    assert page.js("gaoCloseState().editing")
    assert page.js("document.querySelector('.download-links').value") == "https://example.invalid/review.pdf"
    page.key("Escape", "Escape", 27)
    page.until("!gaoCloseState().editing && !gaoCloseState().busy")
    assert service.download_manager().database["items"] == []
    assert not page.errors


def test_exit_mail_draft_is_saved_without_closing_or_sending(launcher_page, monkeypatch):
    page, service, _, origin = launcher_page
    store = service.mail_store()
    store.save_account({"email": "tray-test@example.invalid", "enabled": False})
    page.call("Page.navigate", url=origin + "/mail")
    page.until("Boolean(document.querySelector('.mail-message-rail'))")
    page.click("button[title='写信']")
    page.until("Boolean(document.querySelector('dialog[open].mail-compose-dialog'))")
    assert page.js("gaoCloseState()") == IDLE
    field = "dialog[open].mail-compose-dialog textarea"
    page.fill(field, "旧内容只存在于隔离草稿")
    assert page.js("gaoCloseState()") == IDLE | {"draft": True}

    def reject_draft(_draft):
        raise AppError("隔离草稿写入失败。")

    with monkeypatch.context() as override:
        override.setattr(store, "save_draft", reject_draft)
        assert page.js("gaoSaveDraftBeforeClose()") == {"ok": False, "error": "隔离草稿写入失败。"}
        assert page.js("gaoCloseState()") == IDLE | {"draft": True}
        assert store.library["drafts"] == []

    page.js("""(() => {
        const fetchNow = window.fetch.bind(window);
        window.fetch = (input, options) => {
            if (input !== '/api/mail/draft') return fetchNow(input, options);
            window.fetch = fetchNow;
            return new Promise(resolve => { window.resumeDraft = () => resolve(fetchNow(input, options)); });
        };
        window.waitForDraft = gaoSaveDraftBeforeClose();
    })()""")
    page.until("Boolean(window.resumeDraft)")
    assert page.js("gaoCloseState()") == IDLE | {"busy": True, "draft": True}
    page.fill(field, "退出前的最新测试草稿")
    page.js("window.resumeDraft()")
    assert not page.js("window.waitForDraft")["ok"]
    assert store.library["drafts"][0]["body"] == "旧内容只存在于隔离草稿"
    assert page.js("gaoCloseState()") == IDLE | {"draft": True}
    assert page.js("gaoSaveDraftBeforeClose()") == {"ok": True}
    assert len(store.library["drafts"]) == 1 and store.library["drafts"][0]["body"] == "退出前的最新测试草稿"
    assert store.submissions == []
    assert page.js("Boolean(document.querySelector('dialog[open].mail-compose-dialog'))")
    assert page.js("gaoCloseState()") == IDLE
    page.key("Escape", "Escape", 27)
    page.until("!document.querySelector('dialog[open]')")
    assert len(store.library["drafts"]) == 1
    assert not page.errors
