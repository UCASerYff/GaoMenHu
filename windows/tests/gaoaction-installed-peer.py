"""Exercise a registered installed portal and an isolated packaged GaoAction peer."""

import argparse
import base64
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import time
import traceback
import uuid
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.request import ProxyHandler, Request, build_opener

WINDOWS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(WINDOWS / "src"))

from gaomenhu import APP_ID
from gaomenhu.action_exchange import write_empty_package
from gaomenhu.action_transport import ActionTransport, REGISTRATION, installed_registrations
from gaomenhu.actions import read_package, validate_manifest

FIXTURE = b"GaoAction installed peer verification\n"
FIXTURE_NAME = "fixture.txt"
OPENER = build_opener(ProxyHandler({}))


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def wait_for(probe, description, *, directory=None):
    deadline = time.monotonic() + 25
    while time.monotonic() < deadline:
        if directory and (error := directory / "peer-error.txt").is_file():
            raise RuntimeError(error.read_text(encoding="utf-8"))
        if value := probe():
            return value
        time.sleep(.08)
    raise RuntimeError(f"Timed out waiting for {description}")


def spawn_portal(portal, data_dir, *args, wait=False):
    command = [str(portal), *map(str, args)]
    options = dict(cwd=portal.parent, env=os.environ | {"GAOMENHU_DATA_DIR": str(data_dir)},
                   creationflags=subprocess.CREATE_NO_WINDOW, stdin=subprocess.DEVNULL,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if wait:
        return subprocess.run(command, timeout=12, check=True, **options)
    return subprocess.Popen(command, **options)


def portal_api(data_dir, process):
    rendezvous = data_dir.with_name(data_dir.name + ".native.json")

    def connect():
        require(process.poll() is None, f"Installed portal exited before listening ({process.returncode})")
        try:
            port = json.loads(rendezvous.read_bytes())["port"]
            origin = f"http://127.0.0.1:{port}"
            with OPENER.open(origin, timeout=2) as page:
                token = re.search(r'name="gao-token" content="([^"]+)"', page.read().decode("utf-8"))
            return (origin, token[1]) if token else None
        except (OSError, ValueError, KeyError):
            return None

    origin, token = wait_for(connect, "installed portal")

    def post(path, **body):
        request = Request(origin + path, data=json.dumps(body).encode("utf-8"),
                          headers={"X-Gao-Token": token, "Content-Type": "application/json"})
        with OPENER.open(request, timeout=7) as response:
            result = json.load(response)
        require(result.get("ok") is True, f"Portal rejected {path}: {result.get('error', '')}")
        return result

    return post


def iso_timestamp(value):
    return value.isoformat(timespec="milliseconds").replace("+00:00", "Z")


def reply(source, original, task_id, status, payload=None):
    now = datetime.now(timezone.utc)
    items = [] if payload is None else [{
        "id": str(uuid.uuid4()), "relativePath": "payload/" + FIXTURE_NAME, "uti": "public.plain-text",
        "byteCount": len(payload), "sha256": hashlib.sha256(payload).hexdigest(),
    }]
    return validate_manifest({
        "schemaVersion": 1, "kind": "result", "requestID": str(uuid.uuid4()), "sourceBundleID": source,
        "targetBundleID": APP_ID, "action": "downloads.prepare", "createdAt": iso_timestamp(now),
        "expiresAt": iso_timestamp(now + timedelta(seconds=120)),
        "nonce": base64.b64encode(os.urandom(32)).decode("ascii"), "items": items, "references": [], "parameters": {},
        "inReplyTo": original["requestID"], "status": status, "errorCode": None,
        "provenance": {"workflowState": "accepted" if status == "pending" else "completed", "taskIDs": [task_id]},
    }, APP_ID, now)


def peer(directory):
    installation = Path(sys.executable).resolve().parent
    try:
        config = json.loads((installation / "fixture-config.json").read_bytes())
        original = read_package(directory, target_bundle_id=config["bundleID"])
        require(original["action"] == "downloads.prepare" and original["kind"] == "request"
                and original["sourceBundleID"] == APP_ID, "Unexpected request from installed portal")
        require(original["parameters"]["urls"] == [config["url"]], "Fixture URL or privacy stripping did not match")
        with OPENER.open(config["url"], timeout=5) as handle:
            payload = handle.read(len(FIXTURE) + 1)
        require(payload == FIXTURE, "Peer did not receive the expected loopback file")
        task = str(uuid.uuid4())
        portal, data_dir = Path(config["portal"]), Path(config["dataDir"])
        accepted = reply(config["bundleID"], original, task, "pending")
        require(ActionTransport().verify(accepted) == portal, "Return registration did not resolve to the installed portal")
        package = write_empty_package(installation, accepted)
        send_reply(portal, data_dir, package)
        wait_for(lambda: (installation / "allow-final").is_file() or (installation / "stop-peer").is_file(),
                 "acceptance of the pending receipt")
        if (installation / "stop-peer").is_file():
            return 1
        final = reply(config["bundleID"], original, task, "completed", payload)
        package = write_empty_package(installation, final)
        (package / "payload" / FIXTURE_NAME).write_bytes(payload)
        require(ActionTransport().verify(final) == portal, "Portal return registration was changed")
        (installation / "final-package.txt").write_text(str(package), encoding="utf-8")
        send_reply(portal, data_dir, package)
        (installation / "peer-complete").touch()
    except Exception:
        (installation / "peer-error.txt").write_text(traceback.format_exc(), encoding="utf-8")
        return 1
    finally:
        (installation / "peer-exit").touch()
    return 0


def send_reply(portal, data_dir, package):
    spawn_portal(portal, data_dir, "--serve", "--no-browser", "--port", 0, "--gaoaction", package, wait=True)


@contextmanager
def register_fixture(bundle, executable, descriptor):
    import winreg

    key_name = REGISTRATION + "\\" + bundle
    hive, view = winreg.HKEY_CURRENT_USER, winreg.KEY_WOW64_64KEY
    try:
        with winreg.OpenKey(hive, key_name, access=winreg.KEY_READ | view):
            raise RuntimeError("Unique fixture registration already exists")
    except FileNotFoundError:
        pass
    values = {"Executable": str(executable), "Capabilities": str(descriptor)}
    created = False
    try:
        with winreg.CreateKeyEx(hive, key_name, access=winreg.KEY_SET_VALUE | view) as key:
            created = True
            for name, value in values.items():
                winreg.SetValueEx(key, name, 0, winreg.REG_SZ, value)
        yield
    finally:
        if created:
            with winreg.OpenKey(hive, key_name, access=winreg.KEY_READ | view) as key:
                children, count, _ = winreg.QueryInfoKey(key)
                require(children == 0 and all(name in values and (value, kind) == (values[name], winreg.REG_SZ)
                    for name, value, kind in (winreg.EnumValue(key, index) for index in range(count))),
                    "Fixture registration changed during the test, leaving it for inspection")
            winreg.DeleteKeyEx(hive, key_name, view)


class LocalSource(BaseHTTPRequestHandler):
    def log_message(self, *_):
        return

    def do_GET(self):
        if self.path != f"/{FIXTURE_NAME}":
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Length", str(len(FIXTURE)))
        self.end_headers()
        self.wfile.write(FIXTURE)


def pack_peer(root, portal, url, data_dir, bundle):
    command = [sys.executable, "-m", "PyInstaller", "--noconfirm", "--onedir", "--windowed", "--log-level", "WARN",
               "--name", "GaoActionFixture", "--paths", str(WINDOWS / "src"), "--workpath", str(root / "build"),
               "--distpath", str(root / "installed"), "--specpath", str(root), str(Path(__file__).resolve())]
    environment = os.environ | {"PYINSTALLER_CONFIG_DIR": str(root / "build-cache")}
    subprocess.run(command, env=environment, creationflags=subprocess.CREATE_NO_WINDOW, check=True, timeout=90)
    installation = root / "installed" / "GaoActionFixture"
    descriptor = installation / "GaoCapabilities.json"
    real = json.loads(portal.with_name("GaoCapabilities.json").read_bytes())
    declared = next(entry for entry in real["actions"] if entry["action"] == "downloads.prepare")
    descriptor.write_text(json.dumps({"schemaVersion": 1, "bundleID": bundle, "appVersion": "1.0",
                                      "actions": [declared], "windowsTransport": {"argument": "--gaoaction", "resultActions": []}}), encoding="utf-8")
    (installation / "fixture-config.json").write_text(json.dumps({
        "bundleID": bundle, "url": url, "portal": str(portal), "dataDir": str(data_dir),
    }), encoding="utf-8")
    return installation / "GaoActionFixture.exe", descriptor


def exercise(root, portal, bundle, url, executable):
    data_dir = root / "MenDao"
    installation = executable.parent
    post = None
    process = spawn_portal(portal, data_dir, "--serve", "--no-browser", "--port", 0)
    try:
        post = portal_api(data_dir, process)
        providers = post("/api/actions/providers")["providers"]
        require({"bundleID": bundle, "version": "1.0"} in providers, "Installed portal did not find the fixture registry declaration")
        dispatch = post("/api/actions/send", target=bundle, urls=[url + "?test-private=discard"], privacy="strip")
        request_id = dispatch["record"]["id"]
        require(dispatch["record"]["sendState"] == "launched" and not dispatch["deliveryError"], "The portal did not launch the peer")

        def result_review(status):
            response = post("/api/actions/queue")
            review = response.get("review")
            if review and review.get("kind") == "result" and review.get("inReplyTo") == request_id and review.get("status") == status:
                return review
            if problem := (response.get("notice") or {}).get("error"):
                raise RuntimeError(problem)
            return None

        pending = wait_for(lambda: result_review("pending"), "real peer acceptance", directory=installation)
        accepted = post("/api/actions/decide", id=pending["id"], approve=True)["record"]
        require(accepted["workflowState"] == "accepted" and accepted["fileCount"] == 0, "Acceptance was not recorded")
        (installation / "allow-final").touch()
        final = wait_for(lambda: result_review("completed"), "real peer file result", directory=installation)
        completed = post("/api/actions/decide", id=final["id"], approve=True)["record"]
        require(completed["status"] == "completed" and completed["taskIDs"] == accepted["taskIDs"]
                and completed["fileCount"] == 1 and len(completed["deliveries"]) == 2, "Final result did not correlate with acceptance")
        received = data_dir / "Exchange" / "Incoming" / completed["deliveries"][-1]["folder"]
        require((received / "payload" / FIXTURE_NAME).read_bytes() == FIXTURE, "Installed portal did not preserve the verified private copy")
        wait_for((installation / "peer-complete").is_file, "peer exit", directory=installation)
        result_folder = Path((installation / "final-package.txt").read_text(encoding="utf-8"))
        send_reply(portal, data_dir, result_folder)

        def already_recorded():
            record = (post("/api/actions/queue").get("notice") or {}).get("record")
            return record and record.get("id") == request_id and len(record["deliveries"]) == 2

        wait_for(already_recorded, "duplicate result suppression")
        print("Installed GaoAction peer passed: separate registered executable, acceptance, verified file, duplicate suppression.")
    finally:
        (installation / "stop-peer").touch()
        if process.poll() is None and post is not None:
            try:
                post("/api/shutdown")
                process.wait(timeout=10)
            except (OSError, RuntimeError, subprocess.TimeoutExpired):
                pass
        if process.poll() is None:
            process.kill()
            process.wait(timeout=8)


def standalone(portal):
    require(os.name == "nt", "Installed GaoAction peer smoke requires Windows")
    portal = portal.resolve(strict=True)
    require(portal.is_file() and installed_registrations().get(APP_ID) == (portal, portal.with_name("GaoCapabilities.json")),
            "The provided executable must match the registered GaoMenHu installer (cn.mendao.launcher)")
    build = (WINDOWS / "build").resolve()
    require(build.parent == WINDOWS, "Unexpected fixture build root")
    build.mkdir(exist_ok=True)
    bundle = "local.gaomenhu.qa.p" + uuid.uuid4().hex
    with tempfile.TemporaryDirectory(prefix="gaoaction-peer-", dir=build) as temporary, ThreadingHTTPServer(("127.0.0.1", 0), LocalSource) as http:
        root = Path(temporary).resolve()
        require(root.parent == build and root.name.startswith("gaoaction-peer-"), "Unexpected fixture path")
        server = threading.Thread(target=http.serve_forever, daemon=True)
        server.start()
        try:
            url = f"http://127.0.0.1:{http.server_port}/{FIXTURE_NAME}"
            executable, descriptor = pack_peer(root, portal, url, root / "MenDao", bundle)
            with register_fixture(bundle, executable, descriptor):
                exercise(root, portal, bundle, url, executable)
        finally:
            http.shutdown()
            server.join(timeout=5)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--portal", type=Path, help="The normally registered, installed GaoMenHu.exe being tested")
    mode.add_argument("--gaoaction", type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    raise SystemExit(peer(args.gaoaction) if args.gaoaction else standalone(args.portal))
