"""Run the shipped launcher UI headlessly with an isolated browser and library."""

import base64
import json
import os
import re
import shutil
import subprocess
import threading
import time
import urllib.request
from contextlib import closing
from pathlib import Path

import pytest
from PIL import Image

from gaomenhu import MARKETING_VERSION
from gaomenhu.backup import read_zip
from gaomenhu.server import PortalServer
from gaomenhu.service import PortalService


pytestmark = pytest.mark.skipif(
    os.environ.get("GAOMENHU_UI_TEST") != "1",
    reason="Set GAOMENHU_UI_TEST=1 to run the isolated Chromium UI regression.",
)

DEVTOOLS_PORT_RECORD = re.compile(
    r"([0-9]{1,5})\n/devtools/browser/[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\n?"
)


def wait_for_devtools_port(process, debug_port, output):
    deadline = time.monotonic() + 12
    # Edge may hand off startup to another process and exit successfully first.
    while process.poll() in (None, 0) and time.monotonic() < deadline:
        try:
            record = debug_port.read_text(encoding="ascii")
        except (FileNotFoundError, PermissionError, UnicodeDecodeError):
            # Chromium can hold the file open exclusively during startup on Windows.
            record = ""
        if match := DEVTOOLS_PORT_RECORD.fullmatch(record):
            port = int(match[1])
            if 0 < port <= 65535:
                return port
        time.sleep(min(.1, max(0, deadline - time.monotonic())))
    log = output.read_text(encoding="utf-8", errors="replace")
    raise AssertionError(f"Chromium did not publish a complete DevToolsActivePort record.\n{log}")


class ChromePage:
    def __init__(self, ws):
        self.ws = ws
        self.sequence = 0
        self.errors = []
        self.drag_data = None
        self.call("Runtime.enable")

    def call(self, method, **params):
        self.sequence += 1
        self.ws.send(json.dumps({"id": self.sequence, "method": method, "params": params}))
        while True:
            message = json.loads(self.ws.recv())
            if message.get("method") == "Runtime.exceptionThrown":
                details = message["params"]["exceptionDetails"]
                self.errors.append(details.get("exception", {}).get("description", details["text"]))
            if message.get("method") == "Input.dragIntercepted":
                self.drag_data = message["params"]["data"]
            if message.get("id") == self.sequence:
                assert "error" not in message, message
                return message.get("result", {})

    def js(self, expression):
        result = self.call("Runtime.evaluate", expression=expression, returnByValue=True, awaitPromise=True, userGesture=True)
        assert "exceptionDetails" not in result, result.get("exceptionDetails")
        return result["result"].get("value")

    def until(self, expression, wait=8):
        deadline = time.monotonic() + wait
        while time.monotonic() < deadline:
            if value := self.js(expression):
                return value
            time.sleep(.05)
        raise AssertionError(f"Browser condition not satisfied: {expression}")

    def click(self, selector):
        x, y = self.position(selector)
        self.mouse("mousePressed", x, y, button="left", buttons=1, clickCount=1)
        self.mouse("mouseReleased", x, y, button="left", buttons=0, clickCount=1)

    def position(self, selector, left=None):
        quoted = json.dumps(selector)
        x, y = self.until(f"""(() => {{
            const element = document.querySelector({quoted});
            if (!element) return null;
            element.scrollIntoView({{block: 'nearest'}});
            const rect = element.getBoundingClientRect();
            const x = rect.left + rect.width * {0.5 if left is None else left};
            const y = rect.top + rect.height / 2;
            return rect.width && rect.height && element.contains(document.elementFromPoint(x, y)) ? [x, y] : null;
        }})()""")
        return x, y

    def mouse(self, kind, x, y, **kwargs):
        self.call("Input.dispatchMouseEvent", type=kind, x=x, y=y, **kwargs)

    def key(self, key, code, number, modifiers=0):
        self.call("Input.dispatchKeyEvent", type="rawKeyDown", key=key, code=code, windowsVirtualKeyCode=number, modifiers=modifiers)
        self.call("Input.dispatchKeyEvent", type="keyUp", key=key, code=code, windowsVirtualKeyCode=number, modifiers=modifiers)

    def fill(self, selector, text):
        self.js(f"""(() => {{
            const field = document.querySelector({json.dumps(selector)});
            field.focus();
            field.value = {json.dumps(text)};
            field.dispatchEvent(new Event('input', {{bubbles: true}}));
        }})()""")

    def change(self, selector, value):
        self.js(f"""(() => {{
            const field = document.querySelector({json.dumps(selector)});
            field.value = {json.dumps(str(value))};
            field.dispatchEvent(new Event('change', {{bubbles: true}}));
        }})()""")

    def capture(self, destination):
        data = self.call("Page.captureScreenshot", format="png")["data"]
        destination.write_bytes(base64.b64decode(data))

    def choose_file(self, button, path):
        self.call("Page.enable")
        self.call("Page.setInterceptFileChooserDialog", enabled=True)
        self.click(button)
        self.until("Boolean(document.querySelector('input[type=file]'))")
        root = self.call("DOM.getDocument")["root"]["nodeId"]
        node = self.call("DOM.querySelector", nodeId=root, selector="input[type=file]")["nodeId"]
        self.call("DOM.setFileInputFiles", nodeId=node, files=[str(path.resolve())])
        self.call("Page.setInterceptFileChooserDialog", enabled=False)


@pytest.fixture
def launcher_page(tmp_path, monkeypatch):
    websocket = pytest.importorskip("websocket")
    candidates = [os.environ.get("GAOMENHU_TEST_CHROME"), shutil.which("chrome"),
                  r"C:\Program Files\Google\Chrome\Application\chrome.exe",
                  r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"]
    executable = next((path for path in candidates if path and Path(path).is_file()), None)
    if not executable:
        pytest.skip("Chromium or Edge is required for the UI regression.")
    monkeypatch.setattr("gaomenhu.icons.load_website_icon", lambda _url: None)
    launched = []
    service = PortalService(tmp_path / "MenDao", browser_probe=lambda: ["chrome", "edge"],
                            launcher=lambda browser, url: launched.append((browser, url)))
    fixture_sites = [
        dict(id=f"fixture-{index}", name=f"安静示例 {index:02}", url=f"https://example.test/{index}",
             color="#537CE6", allowedBrowsers=["chrome", "edge"], defaultBrowser="edge", profiles={}, accounts=[])
        for index in range(24)
    ]
    library = service.store.library
    service.store.save(dict(library, sites=library["sites"] + fixture_sites,
                            tiles=library["tiles"] + [dict(kind="site", id=site["id"]) for site in fixture_sites]))
    server = PortalServer(service, port=0)
    server_thread = threading.Thread(target=server.serve_forever, daemon=True)
    server_thread.start()
    store = tmp_path / "chromium"
    output = tmp_path / "chromium.log"
    with output.open("wb") as stream:
        process = subprocess.Popen([
            executable, "--headless=new", "--disable-gpu", "--disable-extensions",
            "--no-sandbox", "--disable-breakpad", "--disable-crash-reporter",
            "--disable-background-networking", "--no-first-run", "--no-default-browser-check",
            "--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1",
            "--remote-debugging-port=0", "--remote-allow-origins=*",
            f"--user-data-dir={store}", "--window-size=1300,900",
            f"http://127.0.0.1:{server.port}/?offline",
        ], stdout=stream, stderr=stream)
        try:
            port = wait_for_devtools_port(process, store / "DevToolsActivePort", output)
            for _ in range(80):
                with urllib.request.urlopen(f"http://127.0.0.1:{port}/json/list", timeout=3) as response:
                    targets = json.load(response)
                target = next((item for item in targets if item["type"] == "page"), None)
                if target:
                    break
                time.sleep(.05)
            with closing(websocket.create_connection(target["webSocketDebuggerUrl"], timeout=12)) as connection:
                page = ChromePage(connection)
                try:
                    yield page, service, launched, f"http://127.0.0.1:{server.port}"
                finally:
                    try:
                        page.call("Browser.close")
                    except websocket.WebSocketConnectionClosedException:
                        pass
        finally:
            try:
                process.wait(timeout=6)
            except subprocess.TimeoutExpired:
                process.terminate()
                process.wait(timeout=12)
            finally:
                server.shutdown()
                server_thread.join(timeout=3)


def test_launcher_normal_entry_workflows(launcher_page, tmp_path):
    page, service, launched, url = launcher_page
    page.until("document.querySelectorAll('#grid .tile').length > 0")
    assert page.js("document.querySelector('#version').textContent") == f"V{MARKETING_VERSION}"
    assert page.js("document.querySelector('#siteCount').textContent") == "30"
    assert page.js("document.querySelector('.brand img').naturalWidth") > 0
    page.call("Emulation.setDeviceMetricsOverride", width=1160, height=760, deviceScaleFactor=1, mobile=False)
    page.call("Emulation.setEmulatedMedia", features=[dict(name="prefers-reduced-motion", value="reduce")])
    page.until("window.mendaoTest.totalPages > 1")
    page.key("PageDown", "PageDown", 34)
    page.until("window.mendaoTest.page === 1")
    page.click("#previousPage")
    page.until("window.mendaoTest.page === 0")
    page.capture(tmp_path / "launcher-light.png")

    page.fill("#search", "ajsl")
    page.until("document.querySelectorAll('#grid .tile').length > 0 && document.querySelector('#caption').textContent === '搜索结果'")
    page.key("Enter", "Enter", 13)
    page.until("document.querySelector('#toast').textContent === '已交给所选浏览器打开。'")
    assert launched[-1] == ("edge", "https://example.test/0")
    page.key("Escape", "Escape", 27)
    page.fill("#search", "")

    first, second = service.store.library["tiles"][:2]
    source, target = f"[data-id='{first['id']}']", f"[data-id='{second['id']}']"
    start_x, start_y = page.position(source)
    end_x, end_y = page.position(target)
    page.call("Input.setInterceptDrags", enabled=True)
    page.mouse("mousePressed", start_x, start_y, button="left", buttons=1, clickCount=1)
    page.mouse("mouseMoved", start_x + 14, start_y, button="left", buttons=1)
    for _ in range(40):
        if page.drag_data is not None:
            break
        page.js("true")
        time.sleep(.05)
    assert page.drag_data is not None
    page.call("Input.dispatchDragEvent", type="dragEnter", x=end_x, y=end_y, data=page.drag_data)
    page.call("Input.dispatchDragEvent", type="dragOver", x=end_x, y=end_y, data=page.drag_data)
    page.until("document.querySelector('.merge-ready') !== null")
    page.call("Input.dispatchDragEvent", type="drop", x=end_x, y=end_y, data=page.drag_data)
    page.call("Input.setInterceptDrags", enabled=False)
    page.until("document.querySelector('#grid .folder') !== null")
    page.click("#grid .folder")
    page.click("#folderTitle")
    page.fill("#folderName", "工作资料")
    page.click("#renameSave")
    page.until("document.querySelector('#folderTitle').textContent === '工作资料'")
    page.click("#folderClose")
    page.click("#manageButton")
    page.click("#grid .folder")
    page.click("#folderGrid .tile")
    page.click("#batchMoveButton")
    page.click("#batchApply")
    page.until("document.querySelector('#dialogOverlay').hidden && !document.querySelector('#undoButton').disabled")
    page.click("#folderClose")
    page.click("#manageDone")
    page.click("#undoButton")
    page.until("document.querySelector('#toast').textContent === '已撤销上次整理。'")

    page.click("#workspacesButton")
    page.click("#newWorkspace")
    page.fill("#workspaceName", "工作场景回归")
    page.fill("#workspaceSearch", "ajsl")
    for id_ in ("fixture-0", "fixture-1"):
        page.click(f"#workspacePicker input[value='{id_}']")
    page.click("#workspaceSave")
    page.until("document.querySelector('.workspace-title strong')?.textContent === '工作场景回归'")
    page.click("[data-launch-workspace]")
    page.until("document.querySelector('#toast').textContent.includes('2')")
    assert launched[-2:] == [("edge", "https://example.test/0"), ("edge", "https://example.test/1")]
    page.capture(tmp_path / "workspaces-light.png")

    page.click("#launcherButton")
    page.click("#addButton")
    page.fill("#siteName", "同事入口")
    page.fill("#siteURL", "https://example.test/new")
    page.fill("#siteAliases", "tongshi")
    icon = tmp_path / "isolated-fixture.png"
    Image.new("RGB", (512, 280), "#5353ef").save(icon)
    page.choose_file("#chooseIcon", icon)
    page.until("!document.querySelector('#cropOverlay').hidden")
    page.change("#cropZoom", 1.4)
    page.click("#cropSave")
    page.until("document.querySelector('#cropOverlay').hidden && Boolean(document.querySelector('#editorIcon img'))")
    page.click("#addAccount")
    page.fill('input[data-field="label"]', "演示账号")
    page.fill('input[data-field="username"]', "test@example.test")
    page.capture(tmp_path / "site-editor-light.png")
    page.click("#saveSite")
    page.until("document.querySelector('#dialogOverlay').hidden")
    saved = next(site for site in service.store.library["sites"] if site["name"] == "同事入口")
    assert saved["iconSource"] == "custom" and saved["iconSourcePixels"] == 256
    page.click("#vaultButton")
    page.until("document.querySelector('.vault-account strong')?.textContent === '演示账号'")
    page.capture(tmp_path / "vault-light.png")

    page.call("Page.navigate", url=url + "/settings")
    page.until("Boolean(document.querySelector('#settingsDensity'))")
    page.change("#settingsDensity", "comfortable")
    page.until("!document.body.classList.contains('compact')")
    page.change("#settingsIconSize", 92)
    page.until("document.documentElement.style.getPropertyValue('--icon-size') === '92px'")
    page.change("#settingsDock", "left")
    page.until("S.floating.dock === 'left'")
    page.capture(tmp_path / "settings-modules-light.png")
    page.click("#settings-tab-appearance")
    page.change("#settingsAppearance", "dark")
    page.until("document.body.classList.contains('dark')")
    page.capture(tmp_path / "settings-dark.png")
    page.click("#settings-tab-data")
    page.until("Boolean(document.querySelector('#exportZip') && document.querySelector('#mergeJson'))")
    page.capture(tmp_path / "data-dark.png")
    page.js("window.pywebview = {api: {save_file: (kind, filename, payload) => {window.savedBackup = {kind, filename, payload}; return true;}}}")
    page.click("#exportZip")
    page.until("window.savedBackup?.kind === 'zip'")
    exported = base64.b64decode(page.js("window.savedBackup.payload"))
    assert read_zip(exported)["library"] == service.store.library
    backup = tmp_path / "isolated-export.zip"
    backup.write_bytes(exported)
    page.choose_file("#restoreZip", backup)
    page.until("Boolean(document.querySelector('#applyPreview'))")
    assert page.js("document.querySelector('.preview-stats strong').textContent") == "31"
    page.click("#applyPreview")
    page.until("Boolean(document.querySelector('#exportZip'))")
    page.click("#exportJson")
    page.until("window.savedBackup?.kind === 'json'")
    assert json.loads(base64.b64decode(page.js("window.savedBackup.payload"))) == service.store.library
    page.click("#exportWorkspacesCatalog")
    page.click("input[name='catalogID']")
    page.click("#catalogSave")
    page.until("window.savedBackup?.filename?.includes('场景')")
    catalog = json.loads(base64.b64decode(page.js("window.savedBackup.payload")))
    assert catalog["workspaces"] == [{
        "workspaceID": service.store.library["workspaces"][0]["id"], "displayName": "工作场景回归"
    }]

    page.call("Emulation.setDeviceMetricsOverride", width=720, height=580, deviceScaleFactor=1.5, mobile=False)
    page.call("Page.navigate", url=url + "/?offline")
    page.until("document.body.classList.contains('dark') && document.querySelectorAll('#grid .tile').length > 0")
    assert page.js("devicePixelRatio") == 1.5
    assert page.js("document.documentElement.scrollWidth") == 720
    assert page.js("document.querySelector('#addButton').getBoundingClientRect().right <= innerWidth")
    page.capture(tmp_path / "launcher-dark-narrow-hidpi.png")
    assert Image.open(tmp_path / "launcher-dark-narrow-hidpi.png").size == (1080, 870)
    assert not page.errors


def test_mail_and_download_centers_at_desktop_and_high_dpi(launcher_page, tmp_path):
    page, service, _, url = launcher_page
    page.call("Emulation.setDeviceMetricsOverride", width=1250, height=780, deviceScaleFactor=1, mobile=False)
    page.call("Emulation.setEmulatedMedia", features=[dict(name="prefers-color-scheme", value="light")])
    page.call("Page.navigate", url=url + "/mail#overview")
    page.until("Boolean(document.querySelector('.mail-overview-welcome'))")
    assert page.js("Array.from(document.querySelectorAll('.mail-overview-metrics .metric-caption'), e => e.textContent)") == [
        "邮箱", "关联平台", "缓存未读",
    ]
    assert page.js("document.querySelector('.center-brand').textContent") == "邮件中心"
    page.until("document.querySelector('.center-brand img').naturalWidth > 0")
    page.capture(tmp_path / "mail-empty-light.png")

    mail = service.mail_store()
    identity = mail.save_record("identities", {"name": "工作"})
    account = mail.save_account({"email": "member@example.invalid", "displayName": "项目邮箱", "identityID": identity["id"], "enabled": False})
    mail.save_account({"email": "other@example.invalid", "displayName": "个人邮箱", "enabled": False})
    mail.save_record("platforms", {"name": "示例平台", "accountID": account["id"]})
    now = time.time()
    mail.messages = [
        dict(id="center-ui-mail", accountID=account["id"], folder="INBOX", subject="门户项目 · 本周交付资料",
             **{"from": "协作资料组 <coordination@example.invalid>"}, to=account["email"], date=now,
             preview="本周交付资料已存档，请核对新模板。", isRead=False, loaded=True,
             body="各位好，\n\n本周交付资料已存档。请在下次例会前核对新模板。\n\n协作资料组",
             html="<p><b>隔离资料组</b></p>"),
        dict(id="center-ui-second", accountID=account["id"], folder="INBOX", subject="门户项目 · 会议时间确认",
             **{"from": "会议协作组 <calendar@example.invalid>"}, date=now - 43200, isRead=True, loaded=True,
             body="本周例会安排在周五上午。"),
    ]
    page.call("Page.navigate", url=url + "/mail?registered#overview")
    page.until("document.querySelectorAll('.mail-overview .mail-account-card').length === 2")
    assert page.js("document.querySelector('.mail-overview-welcome') === null")
    page.capture(tmp_path / "mail-populated-light.png")
    page.click(".mail-identity-card")
    page.until("document.querySelectorAll('.mail-account-card').length === 1")
    assert "member@example.invalid" in page.js("document.querySelector('.mail-account-card').textContent")
    page.click("[data-mail-route=inbox]")
    page.until("document.querySelectorAll('[data-mail-message]').length === 2")
    page.click("[data-mail-message=center-ui-mail]")
    page.until("document.querySelector('.mail-reader')?.dataset.openMessage === 'center-ui-mail'")
    assert "下次例会前核对新模板" in page.js("document.querySelector('.message-body').textContent")
    page.capture(tmp_path / "mail-reader-light.png")
    page.click(".message-article button[title='排版视图']")
    assert page.js("""(() => {
        const frame = document.querySelector('iframe[title="邮件排版视图"]');
        return frame && !frame.hidden && !frame.sandbox.length && frame.srcdoc.includes("default-src 'none'");
    })()""")
    page.js("document.querySelector('[data-mail-message=center-ui-mail]').focus()")
    page.key("ArrowDown", "ArrowDown", 40)
    assert page.js("document.activeElement.dataset.mailMessage") == "center-ui-second"
    page.call("Input.dispatchKeyEvent", type="keyDown", key="Enter", code="Enter", windowsVirtualKeyCode=13, text="\r")
    page.call("Input.dispatchKeyEvent", type="keyUp", key="Enter", code="Enter", windowsVirtualKeyCode=13)
    page.until("document.querySelector('.mail-reader')?.dataset.openMessage === 'center-ui-second'")
    page.click("button[title='写信']")
    page.until("Boolean(document.querySelector('dialog[open].mail-compose-dialog'))")
    page.fill("dialog[open] .field:has(> textarea) textarea", "仅保存到隔离草稿。")
    page.capture(tmp_path / "mail-compose-light.png")
    page.key("Escape", "Escape", 27)
    page.until("!document.querySelector('dialog[open]')")
    assert mail.library["drafts"][0]["body"] == "仅保存到隔离草稿。"

    folder = tmp_path / "download-output"
    folder.mkdir()
    manager = service.download_manager()
    grant = manager.add_destination(folder)
    manager.create_jobs(["https://example.invalid/file.pdf", "https://example.invalid/collaboration-archive.zip"], grant["id"])
    page.call("Page.navigate", url=url + "/downloads")
    page.until("document.querySelectorAll('[data-download-id]').length === 2")
    page.until("document.querySelector('.center-brand img').naturalWidth > 0")
    assert page.js("document.querySelector('.download-window > .toolbar').getBoundingClientRect().width") == 1250
    assert page.js("document.querySelector('.download-tabs [aria-current=page]').dataset.section") == "all"
    assert page.js("document.querySelector('[data-section=paused] .nav-count').textContent") == "2"
    assert not page.js("Boolean(document.querySelector('[data-section=active] .nav-count'))")
    assert page.js("Array.from(document.querySelectorAll('.download-columns > span'), cell => cell.textContent)") == [
        "文件与来源", "状态", "已传输",
    ]
    page.click("[data-download-id]")
    page.key("ArrowDown", "ArrowDown", 40)
    assert page.js("document.activeElement === document.querySelectorAll('[data-download-id]')[1]")
    page.call("Input.dispatchKeyEvent", type="keyDown", key="Enter", code="Enter", windowsVirtualKeyCode=13, text="\r")
    page.call("Input.dispatchKeyEvent", type="keyUp", key="Enter", code="Enter", windowsVirtualKeyCode=13)
    page.until("Boolean(document.querySelector('.download-window .detail'))")
    page.capture(tmp_path / "downloads-selected-light.png")

    page.call("Emulation.setDeviceMetricsOverride", width=720, height=580, deviceScaleFactor=1.5, mobile=False)
    page.call("Emulation.setEmulatedMedia", features=[dict(name="prefers-color-scheme", value="dark")])
    page.until("getComputedStyle(document.querySelector('.download-list')).display === 'none'")
    page.click(".download-detail-close")
    assert page.js("Boolean(document.activeElement.dataset.downloadId)")
    page.capture(tmp_path / "downloads-dark-hidpi.png")
    page.click(".download-window button[title='新建下载']")
    page.until("Boolean(document.querySelector('dialog[open] .download-links'))")
    page.fill(".download-links", "https://example.invalid/work-plan.pdf?fixture=LOCAL_ONLY")
    page.until("document.querySelector('dialog[open] .info-block select')?.offsetWidth > 0")
    page.click("dialog[open] button[title='确认并开始下载']")
    page.until("document.querySelector('.sheet-error').textContent.includes('链接隐私')")
    assert "LOCAL_ONLY" not in page.js("document.querySelector('dialog[open] .sheet-body').textContent")
    assert page.js("document.querySelector('dialog[open] footer').getBoundingClientRect().bottom <= innerHeight")
    assert page.js("document.querySelector('.sheet-error').getBoundingClientRect().bottom < innerHeight")
    page.capture(tmp_path / "download-composer-dark-hidpi.png")
    page.key("Escape", "Escape", 27)
    page.until("!document.querySelector('dialog[open]')")
    page.click("[data-section=completed]")
    page.until("Boolean(document.querySelector('.download-window .empty'))")
    page.click("button[title='下载设置']")
    page.until("Boolean(document.querySelector('dialog[open] .settings-layout'))")
    page.capture(tmp_path / "download-settings-dark-hidpi.png")
    page.key("ArrowDown", "ArrowDown", 40)
    assert page.js("document.activeElement.title") == "外观"
    page.call("Input.dispatchKeyEvent", type="keyDown", key="Enter", code="Enter", windowsVirtualKeyCode=13, text="\r")
    page.call("Input.dispatchKeyEvent", type="keyUp", key="Enter", code="Enter", windowsVirtualKeyCode=13)
    page.until("document.activeElement.title === '外观' && document.activeElement.getAttribute('aria-pressed') === 'true'")
    page.key("Escape", "Escape", 27)
    page.until("!document.querySelector('dialog[open]')")
    # Isolate all transfers. Only the new link below reaches the loopback portal.
    page.click("button[title='暂停全部']")
    page.until("document.querySelector('[data-section=paused] .nav-count')?.textContent === '2'")
    page.click("button[title='新建下载']")
    page.fill(".download-links", url.replace("127.0.0.1", "localhost") + "/portal-assets/Mark.png")
    page.click("dialog[open] button[title='确认并开始下载']")
    page.until("!document.querySelector('dialog[open]')")
    page.until("Boolean(document.querySelector('.download-list [data-state=completed]'))")
    with Image.open(folder / "Mark.png") as downloaded_mark:
        downloaded_mark.verify()

    page.call("Page.navigate", url=url + "/mail#inbox")
    page.until("document.querySelectorAll('[data-mail-message]').length === 2")
    assert page.js("document.documentElement.scrollWidth") == 720
    assert page.js("document.documentElement.scrollHeight") == 580
    page.click("[data-mail-message=center-ui-mail]")
    page.until("getComputedStyle(document.querySelector('.mail-message-rail')).display === 'none'")
    page.capture(tmp_path / "mail-reader-dark-hidpi.png")
    page.click(".mail-reader-close")
    assert page.js("document.activeElement.dataset.mailMessage") == "center-ui-mail"
    page.key("Control", "ControlLeft", 17, modifiers=2)
    page.key("f", "KeyF", 70, modifiers=2)
    page.until("document.activeElement.type === 'search'")
    page.fill(".center-search input", "会议")
    page.until("document.querySelectorAll('[data-mail-message]').length === 1")
    page.call("Page.navigate", url=url + "/mail#settings")
    page.until("Boolean(document.querySelector('body[data-mail-settings] dialog[open] .settings-layout'))")
    assert page.js("document.title") == "邮件设置"
    assert page.js("document.querySelector('dialog[open]').getBoundingClientRect().width") == 720
    assert page.js("document.querySelector('dialog[open] footer').getBoundingClientRect().bottom <= innerHeight")
    page.capture(tmp_path / "mail-settings-dark-hidpi.png")
    page.click("dialog[open] button[title='查看授权配置说明…']")
    page.until("document.querySelectorAll('dialog[open]').length === 2")
    page.key("Escape", "Escape", 27)
    page.until("document.querySelectorAll('dialog[open]').length === 1")
    page.click("dialog[open] button[title='关闭']")
    page.until("location.hash === '' && !document.body.hasAttribute('data-mail-settings')")
    for capture in tmp_path.glob("*-dark-hidpi.png"):
        with Image.open(capture) as picture:
            assert picture.size == (1080, 870)

    page.call("Emulation.setDeviceMetricsOverride", width=520, height=480, deviceScaleFactor=1.5, mobile=False)
    page.call("Page.navigate", url=url + "/mail#overview")
    page.until("Boolean(document.querySelector('.mail-overview-metrics'))")
    assert page.js("document.querySelector('.mail-window aside').getBoundingClientRect().width") == 520
    assert page.js("document.documentElement.scrollWidth === 520 && document.documentElement.scrollHeight === 480")
    page.click("[data-mail-route=platforms]")
    page.until("document.querySelector('.mail-window main').textContent.includes('示例平台')")
    page.click("[data-mail-route=drafts]")
    page.until("document.querySelector('.mail-window main').textContent.includes('无主题')")
    page.click("[data-mail-route=accounts]")
    page.until("document.querySelectorAll('.mail-account-card').length === 2")
    page.capture(tmp_path / "mail-accounts-small.png")
    page.click("button[title='写信']")
    page.until("Boolean(document.querySelector('dialog[open].mail-compose-dialog'))")
    assert page.js("document.querySelector('dialog[open] footer').getBoundingClientRect().bottom <= innerHeight")
    page.key("Escape", "Escape", 27)
    page.until("!document.querySelector('dialog[open]')")
    page.call("Page.navigate", url=url + "/downloads")
    page.until("Boolean(document.querySelector('.download-list [data-state=completed]'))")
    page.until("document.querySelector('.center-brand img').naturalWidth > 0")
    assert page.js("document.documentElement.scrollWidth === 520 && document.documentElement.scrollHeight === 480")
    page.capture(tmp_path / "downloads-small.png")
    assert not page.errors
