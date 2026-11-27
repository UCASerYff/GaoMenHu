import base64
import json
import threading
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

from gaomenhu.actions import make_request, payload_components, plan, validate_manifest
from gaomenhu.backup import export_zip, read_zip
from gaomenhu.downloads import DownloadManager, migrate_downloads, migration_status
from gaomenhu.errors import AppError, RecoveryError
from gaomenhu.mail import MailStore, extract_codes, generate_aliases, make_service_alias, primary_code, strip_html
from gaomenhu.models import bookmark_url_key, encode_library, initial_library, validate_library
from gaomenhu.operations import import_bookmarks, merge_library, preview_bookmarks, restore_library
from gaomenhu.search import floating_sites, search_key, search_text
from gaomenhu.server import PortalServer
from gaomenhu.service import PortalService
from gaomenhu.transport import authorization_url, code_challenge
from gaomenhu.vault import site_vault


def browsers():
    return ["chrome", "edge"]


def service(tmp_path, launcher=None):
    calls = []

    def launch(browser_id, url, profile_directory=None):
        calls.append((browser_id, url, profile_directory))

    app = PortalService(tmp_path / "MenDao", browser_probe=lambda: ["chrome", "edge"], launcher=launcher or launch)
    app.launch_log_calls = calls
    return app


def test_missing_directory_seeds_library(tmp_path):
    app = service(tmp_path)
    assert app.store.access == "ready"
    names = [site["name"] for site in app.store.library["sites"]]
    assert names[:2] == ["Claude", "ChatGPT"]
    claude = app.store.library["sites"][0]
    assert claude["allowedBrowsers"] == ["chrome"]
    assert "password" not in json.dumps(app.store.library)


def test_empty_existing_directory_does_not_seed(tmp_path):
    directory = tmp_path / "MenDao"
    directory.mkdir()
    app = PortalService(directory, browser_probe=lambda: ["chrome"])
    assert app.store.access == "uninitialized"
    assert not (directory / "library.json").exists()
    app.create_library()
    assert (directory / "library.json").is_file()
    assert app.store.access == "ready"


def test_nonempty_directory_without_library_is_blocked(tmp_path):
    directory = tmp_path / "MenDao"
    directory.mkdir()
    (directory / "notes.txt").write_text("keep", encoding="utf-8")
    app = PortalService(directory, browser_probe=lambda: ["chrome"])
    assert app.store.access == "blocked"
    assert (directory / "notes.txt").read_text(encoding="utf-8") == "keep"
    with pytest.raises(RecoveryError):
        app.create_library()


def test_pending_transaction_blocks_and_preserves_bytes(tmp_path):
    app = service(tmp_path)
    original = (app.data_dir / "library.json").read_bytes()
    (app.data_dir / ".gaomenhu-library-write-dead").mkdir()
    again = PortalService(app.data_dir, browser_probe=lambda: ["chrome"])
    assert again.store.access == "blocked"
    assert (app.data_dir / "library.json").read_bytes() == original


def test_schema_is_not_rewritten_when_unsupported(tmp_path):
    app = service(tmp_path)
    payload = json.loads((app.data_dir / "library.json").read_text(encoding="utf-8"))
    payload["schema"] = 2
    raw = json.dumps(payload).encode()
    (app.data_dir / "library.json").write_bytes(raw)
    again = PortalService(app.data_dir, browser_probe=lambda: ["chrome"])
    assert again.store.access == "blocked"
    assert (app.data_dir / "library.json").read_bytes() == raw


def test_validation_rejects_password_and_disallowed_browser():
    library = initial_library(["chrome"])
    library["sites"][0]["accounts"] = [{
        "id": "a", "label": "工作", "username": "person", "loginHosts": ["example.com"],
        "hasPassword": False, "password": "secret",
    }]
    with pytest.raises(AppError):
        validate_library(library)
    library = initial_library(["chrome"])
    library["sites"][0]["defaultBrowser"] = "firefox"
    with pytest.raises(AppError):
        validate_library(library)
    assert bookmark_url_key("https://Example.com:443/docs") == "https://example.com/docs"
    assert bookmark_url_key("https://user:pw@example.com") is None


def test_merge_keeps_local_browser_and_clears_foreign_password():
    current = initial_library(["chrome", "edge"])
    imported = json.loads(json.dumps(current))
    imported["sites"][0]["allowedBrowsers"] = ["firefox"]
    imported["sites"][0]["defaultBrowser"] = "firefox"
    imported["sites"][0]["accounts"] = [{
        "id": "foreign", "label": "外来", "username": "a@b.c", "loginHosts": ["claude.ai"], "hasPassword": True,
    }]
    merged = merge_library(imported, current)
    site = next(item for item in merged["sites"] if item["id"] == "seed-0")
    assert site["allowedBrowsers"] == ["chrome"]
    assert site["accounts"][-1]["hasPassword"] is False
    assert site["accounts"][-1]["id"] != "foreign"
    restored = restore_library(imported, current)
    assert restored["sites"][0]["defaultBrowser"] == "firefox"
    assert all(account["hasPassword"] is False for account in restored["sites"][0]["accounts"])


def test_pinyin_search_and_floating_rank():
    library = initial_library(["chrome"])
    bili = next(site for site in library["sites"] if site["name"] == "哔哩哔哩")
    text = search_text(bili)
    assert "bilibili" in text or "bi" in text
    assert "blbl" in text
    assert "bili" in search_key(bili).replace(" ", "")
    usage = {
        "seed-1": {"openCount": 2, "lastOpenedAt": 10},
        "seed-2": {"openCount": 9, "lastOpenedAt": 5},
        "seed-3": {"openCount": 3, "lastOpenedAt": 8},
        "seed-4": {"openCount": 1, "lastOpenedAt": 7},
    }
    ranked = [site["id"] for site in floating_sites(library, "", usage, 8)]
    assert ranked[:3] == ["seed-1", "seed-3", "seed-4"]
    assert ranked[3] == "seed-2"
    found = floating_sites(library, "fs", {}, 8)
    assert [site["name"] for site in found] == ["飞书"]


def test_vault_roundtrip_and_library_stays_clean(tmp_path):
    app = service(tmp_path)
    site = json.loads(json.dumps(app.store.library["sites"][1]))
    account = {"id": "acc-1", "label": "主号", "username": "me", "loginHosts": ["chatgpt.com"], "hasPassword": False}
    site["accounts"] = [account]
    site["defaultAccount"] = "acc-1"
    app.save_site({"site": site, "passwords": [{"id": "acc-1", "password": "correct horse"}]})
    raw = (app.data_dir / "library.json").read_text(encoding="utf-8")
    assert "correct horse" not in raw
    assert '"hasPassword": true' in raw
    app.lock()
    with pytest.raises(AppError):
        app.vault.read("acc-1", app.clock())
    app.unlock()
    assert app.vault.read("acc-1", app.clock()) == "correct horse"
    other = site_vault(tmp_path / "elsewhere")
    other.unlock(0)
    other.save("acc-1", "other", 0)
    assert other.read("acc-1", 0) == "other"


def test_launch_does_not_fall_back(tmp_path):
    calls = []
    app = service(tmp_path, launcher=lambda browser_id, url, profile_directory=None: calls.append(browser_id))
    site = app.store.library["sites"][0]
    assert site["defaultBrowser"] == "chrome"
    app.browser_probe = lambda: ["edge"]
    with pytest.raises(AppError) as caught:
        app.launch_site(site["id"])
    assert caught.value.code == "browser_unavailable"
    assert calls == []
    app.browser_probe = lambda: ["chrome"]
    with pytest.raises(AppError) as denied:
        app.launch_site(site["id"], "edge")
    assert denied.value.code == "browser_not_allowed"
    assert calls == []


def test_undo_restores_browser_choice_only(tmp_path):
    app = service(tmp_path)
    site_id = app.store.library["sites"][1]["id"]
    app.batch({"siteIDs": [site_id], "operation": "browser", "browser": "edge"})
    assert app.store.library["sites"][1]["defaultBrowser"] == "edge"
    app.undo()
    assert app.store.library["sites"][1]["defaultBrowser"] == "chrome"


def test_zip_roundtrip_rejects_extra_and_future_version(tmp_path):
    library = initial_library(["chrome"])
    archive = export_zip(library, "1.19")
    loaded = read_zip(archive, "1.19")
    assert loaded["snapshotCount"] == 0
    assert loaded["library"]["sites"][0]["name"] == "Claude"
    import io
    import zipfile
    buffer = io.BytesIO(archive)
    with zipfile.ZipFile(buffer, "a") as handle:
        handle.writestr("extra.txt", "no")
    with pytest.raises(AppError):
        read_zip(buffer.getvalue(), "1.19")
    future = export_zip(library, "9.99")
    with pytest.raises(AppError):
        read_zip(future, "1.19")


def test_action_package_rules(tmp_path):
    now = datetime(2026, 1, 1, tzinfo=timezone.utc)
    manifest = make_request("portal.openSite", {"siteID": "seed-0"}, now=now)
    validate_manifest(manifest, now=now + timedelta(seconds=10))
    with pytest.raises(AppError):
        validate_manifest(manifest, now=now + timedelta(seconds=121))
    expired = dict(manifest)
    expired["parameters"] = {"siteID": "seed-0", "password": "no"}
    with pytest.raises(AppError):
        validate_manifest(expired, now=now + timedelta(seconds=1))
    with pytest.raises(AppError):
        payload_components("../input.txt")
    with pytest.raises(AppError):
        payload_components("payload/../../secret")
    library = initial_library(["chrome"])
    planned = plan("portal.prepareDownload", {"urls": ["https://example.com/a?token=1#x"]}, library, ["chrome"], {})
    assert planned["urls"][0]["requiresPrivacyReview"] is True
    assert "token" not in planned["urls"][0]["withoutQueryAndFragment"]
    package = tmp_path / "sample.gaoaction"
    (package / "payload").mkdir(parents=True)
    (package / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
    app = service(tmp_path)
    opened = app.open_action(package, now=now + timedelta(seconds=5))
    assert opened["review"]["action"] == "portal.openSite"
    assert not app.launch_log
    assert app.action_exchange.decide(opened["review"]["id"], True, now + timedelta(seconds=5))["plan"]["type"] == "openSite"
    proposal = make_request("portal.proposeSite", {"url": "https://example.com/new", "title": "新站"}, now=now)
    folder = tmp_path / "propose.gaoaction"
    folder.mkdir()
    (folder / "manifest.json").write_text(json.dumps(proposal), encoding="utf-8")
    result = app.open_action(folder, now=now + timedelta(seconds=5))
    assert result["review"]["action"] == "portal.proposeSite"
    assert app.proposal is None
    assert app.action_exchange.decide(result["review"]["id"], True, now + timedelta(seconds=5))["plan"]["type"] == "proposeSite"
    assert app.proposal["url"] == "https://example.com/new"
    assert app.store.library["sites"][0]["name"] == "Claude"


def test_bookmark_import_deduplicates(tmp_path):
    home = tmp_path / "home"
    bookmarks = home / "AppData" / "Local" / "Google" / "Chrome" / "User Data" / "Default"
    bookmarks.mkdir(parents=True)
    (home / "AppData" / "Local" / "Google" / "Chrome" / "User Data" / "Local State").write_text(
        json.dumps({"profile": {"info_cache": {"Default": {"name": "个人"}}}}), encoding="utf-8")
    document = {"roots": {"bookmark_bar": {"type": "folder", "name": "栏", "children": [
        {"type": "url", "name": "例", "url": "https://example.com/a"},
        {"type": "url", "name": "重复", "url": "https://example.com/a"},
        {"type": "folder", "name": "内层", "children": [
            {"type": "url", "name": "内", "url": "https://example.com/b"},
        ]},
    ]}}}
    (bookmarks / "Bookmarks").write_text(json.dumps(document), encoding="utf-8")
    library = initial_library(["chrome"])
    preview = preview_bookmarks(home, "chrome:Default", library)
    assert preview["roots"][0]["id"] == "bookmark_bar"
    imported = import_bookmarks(home, "chrome:Default", ["bookmark_bar"], library)
    urls = [site["url"] for site in imported["sites"]]
    assert urls.count("https://example.com/a") == 1
    assert "https://example.com/b" in urls


def test_mail_codes_aliases_and_cache_gate(tmp_path):
    found = extract_codes("登录", "你的验证码是 123456，会议在 2024 年。")
    assert primary_code("登录", "你的验证码是 123456，会议在 2024 年。")["value"] == "123456"
    assert all(item["value"] != "2024" for item in found)
    assert "script" not in strip_html("<script>alert(1)</script><p>正文</p>")
    assert make_service_alias("User+old@gmail.com", "https://github.com/x") == "User+github@gmail.com"
    aliases = generate_aliases("name@gmail.com", count=3)
    assert aliases[0] == "name@gmail.com"
    store = MailStore(tmp_path / "MailCenter")
    account = store.save_account({"email": "me@example.com", "imapHost": "imap.example.com", "smtpHost": "smtp.example.com"})
    with pytest.raises(AppError):
        store.sync(account["id"], lambda account_id: [])
    store.authorize(account["id"])
    messages = store.sync(account["id"], lambda account_id: [{
        "id": account_id + "|INBOX|1|1", "accountID": account_id, "subject": "hi", "loaded": False,
    }])
    assert messages[0]["subject"] == "hi"
    draft = store.save_draft({"accountID": account["id"], "subject": "草稿", "body": "先存下来"})
    record = store.stage_submission(draft["id"])
    assert record["phase"] == "accepted"
    store.complete_submission(record["id"])
    with pytest.raises(AppError):
        store.stage_submission(draft["id"])


def test_download_queue_integrity_and_migration(tmp_path):
    body = b"hello portal"
    digest_holder = {}

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            data = body
            start = 0
            if self.headers.get("Range"):
                start = int(self.headers["Range"].split("=")[1].split("-")[0])
                self.send_response(206)
                self.send_header("Content-Range", f"bytes {start}-{len(data) - 1}/{len(data)}")
            else:
                self.send_response(200)
            self.send_header("Content-Length", str(len(data) - start))
            self.send_header("ETag", '"abc"')
            self.end_headers()
            self.wfile.write(data[start:])

        def log_message(self, fmt, *args):
            return

    httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    try:
        port = httpd.server_address[1]
        url = f"http://127.0.0.1:{port}/report.txt"
        root = tmp_path / "DownloadCenter"
        manager = DownloadManager(root)
        grant = manager.add_destination(tmp_path / "out")
        manager.create_jobs([url], grant["id"])
        manager.run_authorized()
        published = list((tmp_path / "out").iterdir())
        assert published[0].read_bytes() == body
        manager.create_jobs([url], grant["id"])
        manager.run_authorized()
        names = sorted(path.name for path in (tmp_path / "out").iterdir())
        assert names == ["report (1).txt", "report.txt"]
        restarted = DownloadManager(root)
        assert all(item["state"] != "running" for item in restarted.database["items"])
        assert restarted.session_authorized == set()
        source = tmp_path / "legacy"
        source.mkdir()
        (source / "downloads.json").write_bytes((root / "downloads.json").read_bytes())
        destination = tmp_path / "moved"
        assert migration_status(source, destination) == "requiresMigration"
        migrate_downloads(source, destination)
        assert migration_status(source, destination) == "alreadyPresent"
        with pytest.raises(AppError):
            migrate_downloads(source, destination)
        reserved = restarted.database["items"][0]["id"]
        with pytest.raises(AppError):
            restarted.create_jobs([url], grant["id"], request_id=reserved, reserved_ids={reserved})
    finally:
        httpd.shutdown()


def test_http_api_creates_and_reads_library(tmp_path):
    (tmp_path / "MenDao").mkdir()
    app = PortalService(tmp_path / "MenDao", browser_probe=lambda: ["chrome"])
    assert app.store.access == "uninitialized"
    server = PortalServer(app, port=0)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        import urllib.request
        page = urllib.request.urlopen(f"http://127.0.0.1:{server.port}/").read().decode()
        assert 'name="gao-token"' in page
        token = page.split('name="gao-token" content="', 1)[1].split('"', 1)[0]

        def post(path, payload):
            request = urllib.request.Request(
                f"http://127.0.0.1:{server.port}{path}",
                data=json.dumps(payload).encode(),
                headers={"Content-Type": "application/json", "X-Gao-Token": token},
                method="POST",
            )
            with urllib.request.urlopen(request) as response:
                return json.loads(response.read().decode())

        created = post("/api/library/create", {})
        assert created["access"] == "ready"
        saved = post("/api/sites/save", {"site": {
            "name": "CI smoke site",
            "url": "https://example.com",
            "color": "#537CE6",
            "allowedBrowsers": ["chrome"],
            "defaultBrowser": "chrome",
            "accounts": [],
            "profiles": {},
        }})
        assert any(site["name"] == "CI smoke site" for site in saved["state"]["library"]["sites"])
        raw = (tmp_path / "MenDao" / "library.json").read_text(encoding="utf-8")
        assert "CI smoke site" in raw
        listed = post("/api/state", {})
        assert any(site["name"] == "CI smoke site" for site in listed["library"]["sites"])
        denied = urllib.request.Request(
            f"http://127.0.0.1:{server.port}/api/state",
            data=b"{}",
            headers={"Content-Type": "application/json", "X-Gao-Token": "nope"},
            method="POST",
        )
        with pytest.raises(urllib.error.HTTPError):
            urllib.request.urlopen(denied)
    finally:
        server.shutdown()


def test_credentials_require_matching_https_origin(tmp_path):
    app = service(tmp_path)
    site = json.loads(json.dumps(app.store.library["sites"][1]))
    site["accounts"] = [{"id": "acc", "label": "a", "username": "me", "loginHosts": ["chatgpt.com"], "hasPassword": True}]
    site["defaultAccount"] = "acc"
    profile = "87038a19-5047-4b93-9183-5b14582ec7d2"
    site["profiles"] = {"chrome": profile}
    app.save_site({"site": site, "passwords": [{"id": "acc", "password": "secret-value"}]})
    poll = {"type": "poll", "profileId": profile, "label": "默认"}
    app.native_message(poll, "chrome")
    app.lock()
    with pytest.raises(AppError) as locked:
        app.launch_site(site["id"], "chrome")
    assert locked.value.code == "vault_locked"
    app.unlock()
    launch_id = app.launch_site(site["id"], "chrome")["requestID"]
    assert not app.usage.get(site["id"])
    assert "launch" not in app.native_message(poll, "edge")
    assert app.native_message(poll, "chrome")["launch"]["id"] == launch_id
    grant = {"profileId": profile, "requestId": launch_id, "tabId": 42}
    credentials = {**grant, "type": "credentials", "url": "https://chatgpt.com/login"}
    assert app.native_message(credentials, "chrome")["ok"] is False
    assert app.native_message({**grant, "type": "bind"}, "edge")["ok"] is False
    assert app.native_message({**grant, "type": "bind"}, "chrome")["ok"] is True
    assert app.native_message({**credentials, "tabId": 43}, "chrome")["ok"] is False
    assert app.native_message({**grant, "type": "launchStatus", "status": "opened"}, "chrome")["ok"] is True
    assert app.usage[site["id"]]["openCount"] == 1
    denied = app.native_message({
        **credentials, "url": "https://other.example/login",
    }, "chrome")
    assert denied["ok"] is False
    allowed = app.native_message(credentials, "chrome")
    assert allowed["username"] == "me"
    assert allowed["password"] == "secret-value"
    assert app.native_message({**grant, "type": "filled", "passwordFilled": False}, "chrome")["ok"] is True
    assert app.native_message(credentials, "chrome")["ok"] is True
    assert app.native_message({**grant, "type": "filled", "passwordFilled": True}, "chrome")["ok"] is True
    assert app.native_message(credentials, "chrome")["ok"] is False
    assert "secret-value" not in (app.data_dir / "library.json").read_text(encoding="utf-8")


def test_oauth_authorization_url_uses_s256():
    verifier = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"
    url = authorization_url("google", "client", "http://127.0.0.1:8765/callback", "state", verifier, "nonce")
    assert url.startswith("https://accounts.google.com/o/oauth2/v2/auth?")
    assert "code_challenge_method=S256" in url
    assert code_challenge(verifier) in url
    assert "client_secret" not in url


def test_native_message_framing(tmp_path):
    import struct
    import subprocess
    import sys
    from gaomenhu.native import publish_host

    app = service(tmp_path)
    server = PortalServer(app, port=0)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    publish_host(app.data_dir, server.port, app.host_token)
    try:
        profile = "87038a19-5047-4b93-9183-5b14582ec7d2"
        payload = json.dumps({"rid": "42", "type": "poll", "profileId": profile, "label": "测试"}).encode("utf-8")
        launch_path = Path(__file__).resolve().parents[1] / "launch.py"
        child = subprocess.run([
            sys.executable, str(launch_path), "--native-host", "--browser", "edge", "--data-dir", str(app.data_dir),
        ], input=struct.pack("<I", len(payload)) + payload, capture_output=True, timeout=10, check=True)
        assert len(child.stdout) > 4
        assert struct.unpack("<I", child.stdout[:4])[0] == len(child.stdout) - 4
        response = json.loads(child.stdout[4:])
        assert response["ok"] and response["rid"] == "42"
        assert [item["browser"] for item in app.state()["profiles"]] == ["edge"]
    finally:
        server.shutdown()
