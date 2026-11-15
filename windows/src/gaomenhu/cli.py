"""命令行入口。窗口模式和浏览器助手模式共用这个文件。"""

import argparse
import json
import struct
import sys
import threading
import webbrowser
from pathlib import Path

from . import NATIVE_HOST_NAME, VERSION_LABEL
from .server import PortalServer
from .service import PortalService
from .store import default_data_dir


def main(argv=None):
    parser = argparse.ArgumentParser(prog="GaoMenHu")
    parser.add_argument("--data-dir", default="")
    parser.add_argument("--port", type=int, default=18765)
    parser.add_argument("--serve", action="store_true")
    parser.add_argument("--no-browser", action="store_true")
    parser.add_argument("--native-host", action="store_true")
    parser.add_argument("--browser", default="")
    parser.add_argument("--version", action="store_true")
    args = parser.parse_args(argv)
    if args.version:
        _write(VERSION_LABEL + "\n")
        return 0
    data_dir = Path(args.data_dir) if args.data_dir else default_data_dir()
    if args.native_host:
        return run_native_host(data_dir, args.browser)
    service = PortalService(data_dir)
    server = PortalServer(service, port=args.port)
    _publish_host(data_dir, server.port, service.host_token)
    if not args.no_browser:
        webbrowser.open(f"http://127.0.0.1:{server.port}/")
    if args.serve or True:
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            server.shutdown()
    return 0


def run_native_host(data_dir: Path, browser: str):
    info_path = data_dir.parent / (data_dir.name + ".native.json")
    if not info_path.is_file():
        return 1
    info = json.loads(info_path.read_text(encoding="utf-8"))
    import urllib.request
    while True:
        raw = _read_message()
        if raw is None:
            return 0
        request = urllib.request.Request(
            f"http://127.0.0.1:{info['port']}/api/native",
            data=json.dumps({"message": raw, "browser": browser}).encode("utf-8"),
            headers={"Content-Type": "application/json", "X-Gao-Host": info["token"], "Host": "127.0.0.1"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=8) as response:
                payload = json.loads(response.read().decode("utf-8"))
        except Exception:
            payload = {"ok": False, "error": "搞门户没有在运行。"}
        _write_message(payload)


def _publish_host(data_dir: Path, port, token):
    path = data_dir.parent / (data_dir.name + ".native.json")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"port": port, "token": token}), encoding="utf-8")


def _read_message():
    header = sys.stdin.buffer.read(4)
    if len(header) < 4:
        return None
    length = struct.unpack("<I", header)[0]
    if length > 1_048_576:
        return None
    body = sys.stdin.buffer.read(length)
    if len(body) < length:
        return None
    return json.loads(body.decode("utf-8"))


def _write_message(payload):
    body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    sys.stdout.buffer.write(struct.pack("<I", len(body)))
    sys.stdout.buffer.write(body)
    sys.stdout.buffer.flush()


def _write(text):
    if sys.stdout is not None:
        sys.stdout.write(text)


def native_manifest(executable: Path, browser_description="搞门户浏览器助手"):
    from . import EXTENSION_ID
    return {
        "name": NATIVE_HOST_NAME,
        "description": browser_description,
        "path": str(executable),
        "type": "stdio",
        "allowed_origins": [f"chrome-extension://{EXTENSION_ID}/"],
    }
