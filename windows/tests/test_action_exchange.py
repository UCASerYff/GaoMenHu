import copy
import hashlib
import json
import os
import shutil
import subprocess
import sys
import threading
import time
import urllib.request
import uuid
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

from gaomenhu import APP_ID
from gaomenhu.action_exchange import action_route, write_empty_package
from gaomenhu.action_transport import ActionTransport, descriptor_path
from gaomenhu.actions import make_request, read_package
from gaomenhu.centers import download_route
from gaomenhu.errors import AppError
from gaomenhu.service import PortalService


def app(root, calls=None):
    return PortalService(root, browser_probe=lambda: ["chrome"], launcher=lambda *args: calls.append(args) if calls is not None else None)


def package(tmp_path, action="portal.openSite", parameters=None, **kwargs):
    parameters = parameters if parameters is not None else {"siteID": "seed-0"}
    manifest = make_request(action, parameters, **kwargs)
    return write_empty_package(tmp_path, manifest), manifest


def test_confirm_duplicate_expiry_and_recovery(tmp_path):
    calls = []
    data = tmp_path / "MenDao"
    service = app(data, calls)
    path, manifest = package(tmp_path)
    identifier = service.open_action(path)["review"]["id"]
    assert not calls
    assert service.open_action(path)["repeated"]
    service.action_exchange.decide(identifier, True)
    assert len(calls) == 1
    assert service.open_action(path)["record"]["status"] == "completed"
    assert app(data, calls).open_action(path)["record"]["status"] == "completed"
    changed = copy.deepcopy(manifest)
    changed["parameters"]["siteID"] = "seed-1"
    (path / "manifest.json").write_text(json.dumps(changed), encoding="utf-8")
    with pytest.raises(AppError) as collision:
        service.open_action(path)
    assert collision.value.code == "duplicate_id"
    changed["requestID"] = str(uuid.uuid4())
    duplicate_nonce = write_empty_package(tmp_path, changed)
    with pytest.raises(AppError) as collision:
        service.open_action(duplicate_nonce)
    assert collision.value.code == "duplicate_nonce"
    expiring, _ = package(tmp_path)
    identifier = service.open_action(expiring)["review"]["id"]
    with pytest.raises(AppError) as expired:
        service.action_exchange.decide(identifier, True, datetime.now(timezone.utc) + timedelta(seconds=121))
    assert expired.value.code == "expired"
    assert len(calls) == 1
    service.action_exchange.requests.file.unlink()
    reopened = app(data, calls)
    assert reopened.action_exchange.history()["unavailable"] == ["portal"]
    other, _ = package(tmp_path)
    with pytest.raises(AppError) as recovery:
        reopened.open_action(other)
    assert recovery.value.code == "exchange_recovery"


def test_review_rechecks_site_and_workspace_outcomes(tmp_path):
    calls = []
    service = app(tmp_path / "MenDao", calls)
    path, _ = package(tmp_path)
    identifier = service.open_action(path)["review"]["id"]
    site = copy.deepcopy(service._site("seed-0"))
    site["url"] = "https://example.test/changed"
    service.save_site({"site": site})
    with pytest.raises(AppError) as changed:
        service.action_exchange.decide(identifier, True)
    assert changed.value.code == "input_changed"
    assert not calls

    service.save_workspace({"id": "fixture", "name": "fixture", "siteIDs": ["seed-0", "seed-1"]})
    def launch(_, url):
        calls.append(url)
        if len(calls) > 1:
            raise AppError("fixture", "browser_launch_failed")
    service.launcher = launch
    path, _ = package(tmp_path, "portal.openWorkspace", {"workspaceID": "fixture"})
    identifier = service.open_action(path)["review"]["id"]
    service.action_exchange.decide(identifier, True)
    record = wait_for(lambda: next((row for row in service.action_exchange.history()["records"]
                                    if row["id"] == identifier and row["status"] != "pending"), None))
    assert record["status"] == "partial"
    assert [site["workflowState"] for site in record["sites"]] == ["opened", "failed"]


def test_arrival_notice_survives_peek_until_matching_acknowledgement(tmp_path):
    service = app(tmp_path / "MenDao")
    path, manifest = package(tmp_path, "downloads.prepare", {"urls": ["https://example.test/f.txt"]})
    assert service.enqueue_action(str(path))
    notice = wait_for(lambda: action_route(service, "queue", {})["notice"])
    assert notice["path"].endswith(manifest["requestID"])
    assert action_route(service, "queue", {})["notice"] == notice
    action_route(service, "ack-notice", {"id": str(uuid.uuid4())})
    assert action_route(service, "queue", {})["notice"] == notice
    action_route(service, "ack-notice", {"id": notice["noticeID"]})
    assert not action_route(service, "queue", {})["notice"]


def wait_for(predicate):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        answer = predicate()
        if answer:
            return answer
        time.sleep(0.04)
    raise AssertionError("Timed out waiting for isolated handoff")


def test_registered_provider_delivers_request_pending_and_verified_file(tmp_path):
    sender, receiver = (app(tmp_path / name) for name in ("Sender", "Receiver"))
    install = tmp_path / "Installed"
    install.mkdir()
    executable = install / "GaoMenHu.exe"
    shutil.copyfile(sys.executable, executable)
    descriptor = install / "GaoCapabilities.json"
    descriptor.write_bytes(descriptor_path().read_bytes())
    registration = lambda: {APP_ID: (executable, descriptor)}
    paths = {}

    def transport_to(peer, key):
        def spawn(args, **kwargs):
            assert args[:2] == [str(executable), "--gaoaction"]
            paths[key] = Path(args[2])
            response = peer.open_action(paths[key])
            assert response["ok"]
            paths[key + "-response"] = response
        return ActionTransport(registration, spawn)

    sender.action_exchange.transport = transport_to(receiver, "request")
    receiver.action_exchange.transport = transport_to(sender, "result")
    assert sender.action_exchange.transport.targets("downloads.prepare") == [{"bundleID": APP_ID, "version": "1.19"}]
    blob = b"verified handoff fixture\n"
    class LocalFile(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass
        def do_GET(self):
            self.send_response(200)
            self.send_header("Content-Length", str(len(blob)))
            self.end_headers()
            self.wfile.write(blob)

    with ThreadingHTTPServer(("127.0.0.1", 0), LocalFile) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        manager = receiver.download_manager()
        try:
            url = f"http://localhost:{server.server_port}/verified.txt?temporary=private"
            def download(action, **body):
                return download_route(receiver, action, body)
            with pytest.raises(AppError):
                sender.action_exchange.send_request(APP_ID, [url], None)
            sent = sender.action_exchange.send_request(APP_ID, [url], "strip")
            related = sent["record"]["id"]
            assert sent["record"]["sendState"] == "launched"
            actual_clock = sender.action_exchange.clock
            sender.action_exchange.clock = lambda: actual_clock() + timedelta(seconds=121)
            try:
                aged = sender.action_exchange.history()["records"][0]
                assert aged["sendState"] == "expired" and aged["status"] == "pending"
                with pytest.raises(AppError) as expired:
                    sender.action_exchange.resend_request(related)
                assert expired.value.code == "expired"
            finally:
                sender.action_exchange.clock = actual_clock
            assert "temporary" not in (paths["request"] / "manifest.json").read_text(encoding="utf-8")
            assert receiver.open_action(paths["request"])["repeated"]
            destination = tmp_path / "Downloads"
            destination.mkdir()
            grant = download("destination", path=str(destination))["destination"]["id"]
            download("create", requestID=related, destinationID=grant, run=True)
            wait_for(lambda: download("state")["items"][0]["state"] == "completed")
            pending = download("request-result", id=related, phase="pending", send=True)
            assert pending["delivered"]
            pending_review = paths["result-response"]["review"]["id"]
            accepted = sender.action_exchange.decide(pending_review, True)["record"]
            assert accepted["workflowState"] == "accepted"
            assert not accepted["fileCount"]
            assert sender.open_action(paths["result"])["repeated"]
            final = download("request-result", id=related, phase="final", send=True)
            assert final["delivered"]
            final_review = paths["result-response"]["review"]["id"]
            result_package = paths["result"]
            result_manifest = read_package(result_package)
            recovered = sender.action_exchange.decide(final_review, True)["record"]
            assert recovered["status"] == "completed" and recovered["fileCount"] == 1
            assert recovered["taskIDs"] == accepted["taskIDs"]
            file_name = result_manifest["items"][0]["relativePath"]
            stored = sender.data_dir / "Exchange" / "Incoming" / recovered["deliveries"][-1]["folder"] / file_name
            assert stored.read_bytes() == blob
            (result_package / file_name).write_bytes(b"x" * len(blob))
            assert hashlib.sha256(stored.read_bytes()).hexdigest() == result_manifest["items"][0]["sha256"]
            with pytest.raises(AppError):
                sender.open_action(result_package)
            assert len(app(sender.data_dir).action_exchange.history()["records"][0]["deliveries"]) == 2
        finally:
            manager.shutdown()
            server.shutdown()
            thread.join(5)


@pytest.mark.skipif(os.name != "nt", reason="Windows UNC path")
def test_registered_provider_must_be_on_local_drive(monkeypatch):
    executable = Path(r"\\example.invalid\share\GaoMenHu.exe")
    descriptor = executable.with_name("GaoCapabilities.json")
    monkeypatch.setattr("gaomenhu.action_transport.filesystem_entry", lambda *args, **kwargs: pytest.fail("touched network path"))
    transport = ActionTransport(lambda: {APP_ID: (executable, descriptor)})
    assert transport.targets("downloads.prepare") == []


@pytest.mark.skipif(os.name != "nt", reason="Windows running-instance forwarding")
def test_normal_command_line_cold_and_running_handoff(tmp_path):
    data = tmp_path / "MenDao"
    executable = [sys.executable, str(Path(__file__).resolve().parents[1] / "launch.py"),
                  "--data-dir", str(data), "--serve", "--no-browser", "--port", "0"]
    first, _ = package(tmp_path, "portal.focusSearch", {"query": "冷启动"})
    process = subprocess.Popen(executable + ["--gaoaction", str(first)], creationflags=subprocess.CREATE_NO_WINDOW,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    rendezvous = data.with_name(data.name + ".native.json")
    origin, token = None, None
    try:
        wait_for(rendezvous.is_file)
        origin = "http://127.0.0.1:" + str(json.loads(rendezvous.read_bytes())["port"])
        with urllib.request.urlopen(origin) as response:
            token = response.read().decode().split('name="gao-token" content="', 1)[1].split('"', 1)[0]

        def post(path, body={}):
            request = urllib.request.Request(origin + path, data=json.dumps(body).encode(),
                headers={"X-Gao-Token": token, "Content-Type": "application/json"})
            with urllib.request.urlopen(request, timeout=8) as response:
                return json.load(response)

        review = wait_for(lambda: post("/api/actions/queue")["review"])
        assert review["summary"] == ["冷启动"]
        post("/api/actions/decide", {"id": review["id"], "approve": False})
        second, _ = package(tmp_path, "portal.focusSearch", {"query": "已运行"})
        completed = subprocess.run(executable + ["--gaoaction", str(second)], creationflags=subprocess.CREATE_NO_WINDOW,
                                   timeout=10, capture_output=True, check=False)
        assert completed.returncode == 0
        review = wait_for(lambda: post("/api/actions/queue")["review"])
        assert review["summary"] == ["已运行"]
        post("/api/actions/decide", {"id": review["id"], "approve": True})
        runtime = post("/api/launcher/runtime")
        assert runtime["focusQuery"] == "已运行"
        post("/api/launcher/acknowledge", {"requestID": runtime["focusRequestID"]})
        assert post("/api/actions/history")["records"][0]["status"] == "completed"
    finally:
        if process.poll() is None:
            if origin and token:
                try:
                    post("/api/shutdown")
                except OSError:
                    pass
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=3)
