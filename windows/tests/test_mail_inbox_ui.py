"""Exercise the normal mail window with isolated cached messages in Chromium."""

from test_launcher_ui import launcher_page, pytestmark


def test_cached_inbox_search_filters_and_reader(launcher_page, tmp_path, monkeypatch):
    page, service, _, origin = launcher_page
    store = service.mail_store()
    account = store.save_account({"email": "lab@example.invalid", "displayName": "研究邮箱"})
    other = store.save_account({"email": "personal@example.invalid", "displayName": "个人邮箱"})
    store.messages = [
        {"id": "plain", "accountID": account["id"], "subject": "五月报告", "from": "团队 <editor@example.invalid>",
         "date": 1760000002, "preview": "开头的摘要", "body": "正文 " * 130 + "玻璃温室 月光校准", "loaded": True,
         "isRead": False, "isFlagged": True, "attachments": [{"id": "result", "filename": "记录表.csv", "byteCount": 3}]},
        {"id": "html", "accountID": other["id"], "subject": "归档回执", "from": "系统 <archive@example.invalid>",
         "date": 1760000001, "isRead": True, "loaded": True,
         "html": '<script>fixture-hidden-secret</script><img src="https://example.invalid/open.png"><p>玻璃<b>温室</b></p>'},
        {"id": "headers", "accountID": account["id"], "subject": "邮件头", "date": 1760000000, "isRead": False},
        {"id": "archive", "accountID": account["id"], "folder": "Archive", "subject": "月光校准备查", "loaded": True},
    ]
    store._write_cache()

    def unexpected_network(*_):
        raise AssertionError("Reading local mail must not start IMAP")

    monkeypatch.setattr("gaomenhu.centers.fetch_mailbox", unexpected_network)
    monkeypatch.setattr("gaomenhu.centers.load_message", unexpected_network)
    page.call("Emulation.setDeviceMetricsOverride", width=1250, height=780, deviceScaleFactor=1, mobile=False)
    page.call("Emulation.setEmulatedMedia", features=[dict(name="prefers-color-scheme", value="light")])
    page.call("Page.navigate", url=origin + "/mail")
    row_ids = "Array.from(document.querySelectorAll('[data-mail-message]'), row=>row.dataset.mailMessage)"
    page.until("document.querySelectorAll('[data-mail-message]').length === 3")
    assert page.js("document.querySelector('.message-rail-header h1').textContent") == "统一收件箱"
    assert page.js(row_ids) == ["plain", "html", "headers"]
    assert page.js("document.querySelector('[data-mail-message=plain]').textContent.includes('研究邮箱')")
    page.click("[data-mail-filter=unread]")
    assert page.js(row_ids) == ["plain", "headers"]
    page.click("[data-mail-filter=starred]")
    assert page.js(row_ids) == ["plain"]
    page.click("[data-mail-filter=attachments]")
    assert page.js(row_ids) == ["plain"]
    assert page.js("document.activeElement.dataset.mailFilter") == "attachments"
    page.click("[data-mail-filter=all]")

    page.key("f", "KeyF", 70, modifiers=2)
    page.until("document.activeElement.matches('input[aria-label=搜索缓存邮件]')")
    search = ".mail-window input[type=search]"
    page.fill(search, "editor 月光校准")
    page.until("document.querySelector('[data-mail-message=plain] .mail-preview')?.textContent.includes('月光校准')")
    assert page.js(row_ids) == ["plain"]
    page.fill(search, "记录表.csv")
    page.until("document.querySelector('[data-mail-message=plain] .mail-preview')?.textContent === '开头的摘要'")
    assert page.js(row_ids) == ["plain"]
    page.fill(search, "fixture-hidden-secret")
    page.until("document.querySelector('.mail-message-list h2')?.textContent === '没有匹配的邮件'")
    page.fill(search, "玻璃温室")
    page.until("document.querySelectorAll('[data-mail-message]').length === 2")
    page.change(".inbox-filters [name=mailbox]", other["id"])
    page.until("document.querySelectorAll('[data-mail-message]').length === 1 && !!document.querySelector('[data-mail-message=html]')")
    assert page.js(f"document.querySelector({search!r}).value") == "玻璃温室"
    page.click("[data-mail-message=html]")
    page.until("document.querySelector('.mail-reader').dataset.openMessage === 'html'")
    assert page.js("Boolean(document.querySelector('[data-mail-message=html][aria-pressed=true]'))")
    page.click("[title=排版视图]")
    assert page.js("""(() => {
      const frame = document.querySelector('.message-html:not([hidden])');
      return frame?.getAttribute('sandbox') === '' && frame.srcdoc.includes("default-src 'none'") &&
        !frame.srcdoc.includes('open.png') && !frame.srcdoc.includes('fixture-hidden-secret');
    })()""")
    page.capture(tmp_path / "mail-cached-reader-light.png")

    page.call("Emulation.setDeviceMetricsOverride", width=560, height=480, deviceScaleFactor=1.5, mobile=False)
    page.call("Emulation.setEmulatedMedia", features=[dict(name="prefers-color-scheme", value="dark")])
    assert page.js("getComputedStyle(document.querySelector('.mail-message-rail')).display") == "none"
    assert page.js("document.documentElement.scrollWidth") == 560
    page.click("[title=返回列表]")
    assert page.js("document.activeElement.dataset.mailMessage") == "html"
    page.capture(tmp_path / "mail-cached-inbox-dark-narrow.png")
    assert store.authorized == set()
    assert not page.errors


def test_compose_autosaves_one_local_draft_without_submitting(launcher_page):
    page, service, _, origin = launcher_page
    store = service.mail_store()
    store.save_account({"email": "lab@example.invalid", "enabled": False})
    page.call("Page.navigate", url=origin + "/mail#compose")
    page.until("!!document.querySelector('dialog[open].mail-compose-dialog')")
    field = "dialog[open].mail-compose-dialog textarea"
    assert store.library["drafts"] == []
    page.fill(field, "第一版正文")
    page.until("document.querySelector('.mail-compose-status').dataset.state === 'saved'")
    draft_id = store.library["drafts"][0]["id"]
    page.fill(field, "修订版正文")
    page.until("document.querySelector('.mail-compose-status').dataset.state === 'saved'")
    assert [(draft["id"], draft["body"]) for draft in store.library["drafts"]] == [(draft_id, "修订版正文")]
    assert not store.submissions
    assert not page.js("gaoCloseState().draft")
    page.key("Escape", "Escape", 27)
    page.until("!document.querySelector('dialog[open]')")
    page.click("[data-mail-route=drafts]")
    page.click("[aria-label=继续写]")
    page.until("document.querySelector('dialog[open] textarea')?.value === '修订版正文'")
    assert not page.errors


def test_uncertain_submission_disables_sending_the_same_draft_again(launcher_page, monkeypatch):
    page, service, _, origin = launcher_page
    store = service.mail_store()
    account = store.save_account({"email": "lab@example.invalid"})
    store.authorize(account["id"])
    attempts = []

    def lose_confirmation(_account, _credential, draft, _message):
        attempts.append(draft["id"])
        raise OSError("synthetic provider confirmation lost")

    monkeypatch.setattr("gaomenhu.centers._credential", lambda *_: "fixture-credential")
    monkeypatch.setattr("gaomenhu.centers.send_mail", lose_confirmation)
    page.call("Page.navigate", url=origin + "/mail#compose")
    page.until("!!document.querySelector('dialog[open].mail-compose-dialog')")
    page.fill(".mail-compose-dialog .field:nth-child(2) input", "recipient@example.invalid")
    page.fill(".mail-compose-dialog textarea", "只用于隔离发送状态回归")
    page.click("[aria-label='发送…']")
    page.until("document.querySelector('dialog:last-child').textContent.includes('recipient@example.invalid')")
    assert not attempts
    page.click("[aria-label=确认发送]")
    page.until("document.querySelector('dialog:last-child .sheet-error').textContent.includes('请到邮箱服务商核对')")
    assert len(attempts) == 1
    assert store.submissions[0]["phase"] == "uncertain"
    page.click("[aria-label=确认发送]")
    assert len(attempts) == 1
    page.click("dialog:last-child [aria-label=返回]")
    page.until("!gaoCloseState().busy && document.querySelector('[aria-label=\"发送…\"]').disabled")
    assert not page.js("gaoCloseState().draft")
    page.key("Escape", "Escape", 27)
    page.until("!document.querySelector('dialog[open]')")
    assert not page.errors
