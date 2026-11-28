import base64
import hashlib
import json
import secrets
import threading
import time
import urllib.request
import uuid
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlencode, urlsplit

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa

from gaomenhu import APP_ID
from gaomenhu import centers, mail_oauth
from gaomenhu.downloads import DownloadManager
from gaomenhu.errors import AppError
from gaomenhu.mail import sanitize_mail_html
from gaomenhu.server import PortalServer
from gaomenhu.service import PortalService
from gaomenhu.transport import code_challenge


def _wait_for(predicate):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.025)
    pytest.fail("Synthetic workflow did not reach its expected state")


@pytest.fixture
def service(tmp_path):
    return PortalService(tmp_path / "MenDao", browser_probe=lambda: [])


def test_download_async_pause_range_and_explicit_result(service, tmp_path):
    first_chunk = threading.Event()
    release = threading.Event()
    blob = hashlib.shake_256(b"Windows isolated downloads").digest(512 * 1024)
    received_requests = []

    class Source(BaseHTTPRequestHandler):
        def log_message(self, *_):
            return

        def do_GET(self):
            range_value = self.headers.get("Range")
            received_requests.append((range_value, self.headers.get("If-Range")))
            start = int(range_value.split("=")[1].split("-")[0]) if range_value else 0
            self.send_response(206 if start else 200)
            self.send_header("Content-Length", str(len(blob) - start))
            self.send_header("ETag", '"stable"')
            if start:
                self.send_header("Content-Range", f"bytes {start}-{len(blob)-1}/{len(blob)}")
            self.end_headers()
            try:
                if not start:
                    self.wfile.write(blob[:64 * 1024])
                    self.wfile.flush()
                    first_chunk.set()
                    release.wait(5)
                self.wfile.write(blob[start or 64 * 1024:])
            except ConnectionError:
                pass

    with ThreadingHTTPServer(("127.0.0.1", 0), Source) as source:
        thread = threading.Thread(target=source.serve_forever, daemon=True)
        thread.start()
        try:
            destination = tmp_path / "destination"
            destination.mkdir()
            url = f"http://localhost:{source.server_port}/NUL.txt?test=1"
            now = datetime.now(timezone.utc)
            iso = lambda date: date.isoformat(timespec="milliseconds").replace("+00:00", "Z")
            manifest = {
                "schemaVersion": 1, "kind": "request", "requestID": str(uuid.uuid4()),
                "sourceBundleID": "cn.synthetic.sender", "targetBundleID": APP_ID, "action": "downloads.prepare",
                "createdAt": iso(now - timedelta(seconds=1)), "expiresAt": iso(now + timedelta(seconds=119)),
                "nonce": base64.b64encode(secrets.token_bytes(32)).decode(), "items": [], "references": [],
                "parameters": {"urls": [url], "mediaType": "file"},
            }

            def route(name, **body):
                return centers.download_route(service, name, body)

            request_id = route("request", manifest=manifest)["requestID"]
            with pytest.raises(AppError, match="已经接收"):
                route("request", manifest=manifest)
            grant = route("destination", path=str(destination))["destination"]["id"]
            with pytest.raises(AppError, match="查询参数"):
                route("create", requestID=request_id, destinationID=grant)
            started = route("create", requestID=request_id, destinationID=grant, privacy="strip")
            item_id = started["items"][0]["id"]
            assert "sourceURL" not in started["items"][0]
            assert first_chunk.wait(5)
            _wait_for(lambda: route("state")["items"][0]["bytesReceived"] > 0)
            route("pause", id=item_id)
            release.set()
            _wait_for(lambda: not route("state")["busy"])
            assert route("state")["items"][0]["state"] == "paused"
            assert not (destination / "_NUL.txt").exists()
            route("resume", id=item_id)
            _wait_for(lambda: route("state")["items"][0]["state"] == "completed")
            assert received_requests[1] == ("bytes=65536-", '"stable"')
            assert (destination / "_NUL.txt").read_bytes() == blob
            with pytest.raises(AppError, match="接收回执"):
                route("request-result", id=request_id, phase="final", path=str(tmp_path))
            pending = route("request-result", id=request_id, phase="pending", path=str(tmp_path))["package"]
            done = route("request-result", id=request_id, phase="final", path=str(tmp_path))["package"]
            pending_manifest = json.loads((Path(pending) / "manifest.json").read_text(encoding="utf-8"))
            final_manifest = json.loads((Path(done) / "manifest.json").read_text(encoding="utf-8"))
            assert pending_manifest["status"] == "pending" and not pending_manifest["items"]
            assert final_manifest["status"] == "completed"
            assert pending_manifest["provenance"]["taskIDs"] == final_manifest["provenance"]["taskIDs"]
            artifact = final_manifest["items"][0]
            assert (Path(done) / artifact["relativePath"]).read_bytes() == blob
            assert artifact["sha256"] == hashlib.sha256(blob).hexdigest()
        finally:
            release.set()
            source.shutdown()
            thread.join(5)


def test_legacy_download_directory_is_reauthorized_without_discarding_queue(tmp_path):
    center_path = tmp_path / "DownloadCenter"
    old_path = tmp_path / "destination"
    old_path.mkdir()
    manager = DownloadManager(center_path)
    grant = manager.add_destination(old_path)
    manager.create_jobs(["https://example.invalid/a.txt"], grant["id"])
    grant.pop("directoryIdentity")
    manager.store.save()
    reinstated = DownloadManager(center_path)
    item = reinstated.database["items"][0]
    assert item["state"] == "waitingForDestination"
    assert item["destinationID"] == grant["id"]
    assert item["id"] not in reinstated.session_authorized
    with pytest.raises(AppError):
        reinstated.resume(item["id"])
    refreshed = reinstated.reauthorize(grant["id"], old_path)
    assert refreshed["id"] == grant["id"]
    assert refreshed["directoryIdentity"]
    assert item["state"] == "waitingForDestination"
    old_path.rename(tmp_path / "original-folder")
    old_path.mkdir()
    with pytest.raises(AppError, match="目录身份"):
        reinstated.resume(item["id"])


def test_mail_search_uses_persisted_cache_without_authorization(service, monkeypatch):
    store = service.mail_store()
    identity = store.save_record("identities", {"name": "工作"})
    account = store.save_account({"email": "owner@example.invalid", "identityID": identity["id"]})
    other = store.save_account({"email": "other@example.invalid"})
    store.messages = [
        dict(id="one", accountID=account["id"], subject="归档", preview="首页", body="前文 " * 300 + "校准步骤",
             loaded=True, attachments=[dict(filename="结果.csv")]),
        dict(id="two", accountID=other["id"], subject="回执", html="<style>.校准步骤 {color: red}</style><p>签收</p>"),
        dict(id="three", accountID=account["id"], folder="Archive", subject="校准步骤"),
    ]
    store._write_cache()
    store.load()

    def fail(*_):
        raise AssertionError("Local mail search must not touch credentials or network")

    monkeypatch.setattr(centers, "_credential", fail)
    monkeypatch.setattr(centers, "load_message", fail)
    assert "校准步骤" in centers.mail_route(service, "search", {"query": "OWNER 校准步骤"})["matches"][0]["excerpt"]
    assert centers.mail_route(service, "search", {"query": "结果.csv", "identityID": identity["id"]})["matches"] == [
        {"id": "one", "excerpt": ""},
    ]
    assert centers.mail_route(service, "search", {"query": "校准步骤", "accountID": other["id"]})["matches"] == []
    assert centers.mail_route(service, "search", {"query": "校准步骤", "folder": "Archive"})["matches"] == [
        {"id": "three", "excerpt": ""},
    ]
    assert centers.mail_route(service, "state", {})["messages"][0]["hasAttachments"] is True
    assert not store.authorized


def test_mail_center_password_gate_detail_and_uncertain_submission(service, monkeypatch):
    seen = []
    message_id = str(uuid.uuid4())

    def fake_fetch(account, credential, folder, limit):
        seen.append(("fetch", credential, folder))
        return ([{"id": message_id, "accountID": account["id"], "subject": "验证码 112233",
                  "folder": folder, "loaded": False, "from": "Fixture <fixture@example.invalid>"}],
                [{"path": "Archive", "displayName": "Archive", "selectable": True}])

    def fake_load(account, credential, message):
        seen.append(("load", credential))
        message.update(loaded=True, body="Fixture content", html='<img src="https://example.invalid/"><p>Fixture</p>',
                       attachments=[{"id": "0", "filename": "x.txt", "type": "text/plain", "byteCount": 1, "base64": "eA=="}])

    def fake_send(account, credential, draft, message):
        seen.append(("send", credential, message["Cc"].addresses[0].addr_spec, message["Bcc"].addresses[0].addr_spec))
        if draft["subject"] == "Unconfirmed":
            raise TimeoutError()

    monkeypatch.setattr(centers, "fetch_mailbox", fake_fetch)
    monkeypatch.setattr(centers, "load_message", fake_load)
    monkeypatch.setattr(centers, "send_mail", fake_send)
    monkeypatch.setattr(centers, "_start_autosync", lambda service: None)
    port = PortalServer(service)
    server = threading.Thread(target=port.serve_forever, daemon=True)
    server.start()
    origin = f"http://127.0.0.1:{port.port}"

    def api(action, **value):
        request = urllib.request.Request(origin + "/api/mail/" + action,
            data=json.dumps(value).encode(), headers={"Content-Type": "application/json", "X-Gao-Token": service.page_token})
        try:
            response = urllib.request.urlopen(request, timeout=5)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            return json.load(response)

    try:
        assert "centers.js" in urllib.request.urlopen(origin + "/mail", timeout=5).read().decode()
        assert api("state")["accounts"] == []
        account = api("account", password="isolated-app-password", account={
            "email": "tester@example.invalid", "smtpHost": "smtp.example.invalid", "imapHost": "imap.example.invalid",
        })["account"]
        account_id = account["id"]
        assert api("sync", id=account_id)["ok"] is False
        assert seen == []
        assert api("authorize", id=account_id, sync=True)["ok"]
        assert api("state")["messages"][0]["code"] == "112233"
        assert api("message", id=message_id)["message"]["loaded"] is False
        detail = api("message", id=message_id, load=True)["message"]
        assert detail["html"] == "<p>Fixture</p>"
        assert "base64" not in detail["attachments"][0]
        assert api("attachment", id=message_id, attachmentID="0")["attachment"]["base64"] == "eA=="
        assert sanitize_mail_html('<meta http-equiv="refresh" content="0; url=https://example.invalid"><svg><script>no</script></svg><b>x</b>') == "<b>x</b>"
        for title in ("Confirmed", "Unconfirmed"):
            draft = api("draft", draft={
                "accountID": account_id, "to": "Recipient <recipient@example.invalid>", "cc": "cc@example.invalid",
                "bcc": "bcc@example.invalid", "subject": title, "body": "Fixture",
            })["draft"]
            result = api("send", draftID=draft["id"])
            assert result["ok"] is (title == "Confirmed")
            assert api("send", draftID=draft["id"])["ok"] is False
        assert [entry[0] for entry in seen] == ["fetch", "load", "send", "send"]
        assert seen[-1][2:] == ("cc@example.invalid", "bcc@example.invalid")
        assert [record["phase"] for record in api("state")["submissions"]] == ["completed", "uncertain"]
        assert "isolated-app-password" not in json.dumps(api("backup"), ensure_ascii=False)
        assert "isolated-app-password" not in service.mail_store().library_path.read_text(encoding="utf-8")
        assert b"isolated-app-password" not in service.mail_vault.path.read_bytes()
        restarted = PortalService(service.data_dir, browser_probe=lambda: [])
        assert not restarted.mail_store().authorized
        assert restarted.mail_store().message(message_id)["loaded"]
    finally:
        port.shutdown()
        server.join(5)


@pytest.mark.parametrize("provider", ["google", "microsoft"])
def test_real_loopback_oauth_pkce_nonce_signature_and_credential_storage(service, monkeypatch, provider):
    address = "synthetic@example.invalid"
    client = "fixture-client"
    tenant = str(uuid.uuid4())
    centers.mail_route(service, "settings", {"preferences": {
        provider + "ClientID": client, "microsoftTenant": "common",
    }})
    private = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    jwk = json.loads(jwt.algorithms.RSAAlgorithm.to_jwk(private.public_key()))
    jwk["kid"] = "fixture-key"
    if provider == "microsoft":
        jwk["issuer"] = "https://login.microsoftonline.com/{tenantid}/v2.0"
    launched = []
    wire = []
    checked = []

    def open_browser(url):
        query = parse_qs(urlsplit(url).query)
        launched.append({key: values[0] for key, values in query.items()})
        return True

    def provider_fixture(url, form=None):
        wire.append((url, form))
        if form is None:
            return {"keys": [jwk]}
        params = launched[-1]
        assert form["client_id"] == client and form["redirect_uri"] == params["redirect_uri"]
        assert code_challenge(form["code_verifier"]) == params["code_challenge"]
        now = int(time.time())
        identity = {"sub": "fixture-subject", "iat": now, "exp": now + 3600, "nonce": params["nonce"],
                    "aud": client, "email": address, "email_verified": True}
        identity["iss"] = "https://accounts.google.com" if provider == "google" else f"https://login.microsoftonline.com/{tenant}/v2.0"
        if provider == "microsoft":
            identity["tid"] = tenant
        if form["code"] == "mismatched":
            identity["nonce"] = "unrelated"
        return {"id_token": jwt.encode(identity, private, algorithm="RS256", headers={"kid": jwk["kid"]}),
                "access_token": "fixture-access", "refresh_token": "fixture-refresh", "expires_in": 3600}

    monkeypatch.setattr(mail_oauth.webbrowser, "open", open_browser)
    monkeypatch.setattr(mail_oauth, "_request", provider_fixture)
    monkeypatch.setattr(mail_oauth, "check_connection", lambda account, credential: checked.append((account, credential)))
    monkeypatch.setattr(centers, "_start_autosync", lambda service: None)

    def callback(code, state=None):
        request = launched[-1]
        return urllib.request.urlopen(request["redirect_uri"] + "?" + urlencode({
            "code": code, "state": state or request["state"],
        }), timeout=5)

    attempt = centers.mail_route(service, "oauth-start", {"provider": provider})["id"]
    with pytest.raises(urllib.error.HTTPError) as denied:
        callback("mismatched", "unrelated")
    assert denied.value.code == 400
    assert not wire
    with callback("mismatched") as response:
        assert response.status == 200
    _wait_for(lambda: centers.mail_route(service, "oauth-status", {"id": attempt})["status"] == "failed")
    assert not service.mail_store().library["accounts"]
    assert not checked

    attempt = centers.mail_route(service, "oauth-start", {"provider": provider})["id"]
    with callback("verified") as response:
        assert response.status == 200
    _wait_for(lambda: centers.mail_route(service, "oauth-status", {"id": attempt})["status"] == "complete")
    account = service.mail_store().library["accounts"][0]
    assert account["email"] == address and account["id"] in service.mail_store().authorized
    assert checked[0][1] == "fixture-access"
    assert centers._credential(service, account) == "fixture-access"
    assert b"fixture-refresh" not in service.mail_vault.path.read_bytes()
    assert "fixture-access" not in service.mail_store().library_path.read_text(encoding="utf-8")
