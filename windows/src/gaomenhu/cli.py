"""Desktop, headless CLI and Chromium Native Messaging entry points."""

import argparse
import json
import os
import sys
import threading
import time
import webbrowser
from contextlib import contextmanager
from pathlib import Path

from . import VERSION_LABEL
from .action_transport import descriptor_path
from .native import (
    EXTENSION_ORIGIN, browser_from_ancestors, exchange, native_manifest, publish_host, rendezvous_path,
    read_message as _read_message, run_native_host, write_message as _write_message,
)
from .server import PortalServer
from .service import PortalService
from .store import default_data_dir


@contextmanager
def instance_lock(data_dir):
    import msvcrt

    path = data_dir.with_name(data_dir.name + ".instance.lock")
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a+b") as handle:
        handle.seek(0)
        try:
            msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
        except OSError:
            yield False
            return
        try:
            yield True
        finally:
            handle.seek(0)
            msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv and argv[0].startswith("chrome-extension://"):
        if argv[0] != EXTENSION_ORIGIN:
            return 1
        return run_native_host(default_data_dir(), browser_from_ancestors())

    parser = argparse.ArgumentParser(prog="GaoMenHu")
    parser.add_argument("--data-dir", default="")
    parser.add_argument("--port", type=int)
    parser.add_argument("--serve", action="store_true")
    parser.add_argument("--no-browser", action="store_true")
    parser.add_argument("--native-host", action="store_true")
    parser.add_argument("--browser", choices=("chrome", "edge"))
    parser.add_argument("--window-smoke", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--version", action="store_true")
    parser.add_argument("--gaoaction", type=Path, metavar="PATH")
    parser.add_argument("--capabilities", action="store_true")
    args = parser.parse_args(argv)
    if args.version:
        if sys.stdout is not None:
            print(VERSION_LABEL)
        return 0
    if args.capabilities:
        if sys.stdout is not None:
            sys.stdout.buffer.write(descriptor_path().read_bytes())
        return 0
    data_dir = (Path(args.data_dir) if args.data_dir else default_data_dir()).resolve()
    if args.native_host:
        if not args.data_dir or data_dir == default_data_dir().resolve() or not args.browser:
            parser.error("developer native-host mode requires an isolated --data-dir and --browser")
        return run_native_host(data_dir, args.browser)
    if args.window_smoke and (not args.data_dir or data_dir == default_data_dir().resolve()):
        parser.error("window smoke mode requires an isolated --data-dir")

    desktop = os.name == "nt" and not (args.serve or args.no_browser)
    port = args.port if args.port is not None else (0 if desktop else 18765)
    if os.name != "nt":
        return _serve(data_dir, port, False, open_browser=not (args.serve or args.no_browser), incoming=args.gaoaction)
    with instance_lock(data_dir) as owner:
        if owner:
            return _serve(data_dir, port, desktop, smoke_file=args.window_smoke, incoming=args.gaoaction)
        if not desktop and not args.gaoaction:
            _error("该资料目录的搞门户已经在运行。")
            return 1
        for _ in range(20):
            try:
                endpoint = "/api/actions/activate" if args.gaoaction else "/api/desktop/activate"
                payload = {"path": str(args.gaoaction.absolute())} if args.gaoaction else {}
                if exchange(data_dir, endpoint, payload).get("ok"):
                    return 0
            except (OSError, ValueError, KeyError):
                pass
            time.sleep(0.3)
        _error("搞门户已在启动中，请稍后重试。")
        return 1


def _error(message):
    if sys.stderr is not None:
        print(message, file=sys.stderr)
    elif os.name == "nt":
        import ctypes
        ctypes.windll.user32.MessageBoxW(None, message, "搞门户", 0x10)


def _serve(data_dir, port, desktop, open_browser=False, smoke_file=None, incoming=None):
    try:
        service = PortalService(data_dir)
        if incoming:
            service.enqueue_action(str(incoming.absolute()))
        server = PortalServer(service, port=port)
        publish_host(data_dir, server.port, service.host_token)
    except (OSError, ValueError) as exc:
        _error(f"搞门户启动失败。\n{exc}")
        return 1
    worker = threading.Thread(target=server.serve_forever, daemon=True, name="Portal loopback server")
    worker.start()
    try:
        if desktop:
            from .desktop import Desktop
            app = Desktop(server, smoke_file)
            server.activate_desktop = app.show_main
            server.appearance_changed = app.appearance_changed
            server.mail_panel_changed = app.mail_panel_changed
            app.run()
        else:
            if open_browser:
                webbrowser.open(f"http://127.0.0.1:{server.port}/")
            while worker.is_alive():
                worker.join(0.5)
    except KeyboardInterrupt:
        pass
    except Exception as exc:
        if smoke_file:
            smoke_file.write_text(str(exc), encoding="utf-8")
        else:
            _error(f"无法打开搞门户窗口，请检查 Microsoft Edge WebView2 Runtime。\n{exc}")
        return 1
    finally:
        server.shutdown()
        if service.downloads is not None:
            service.downloads.shutdown()
        try:
            if rendezvous_path(data_dir).is_file():
                path = rendezvous_path(data_dir)
                if json.loads(path.read_text(encoding="utf-8")).get("token") == service.host_token:
                    path.unlink(missing_ok=True)
        except (OSError, ValueError):
            pass
    return 0
