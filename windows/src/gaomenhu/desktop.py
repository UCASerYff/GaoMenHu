"""Native WinForms/WebView2 windows for the loopback portal pages."""

import base64
import ctypes
import json
import logging
import queue
import threading
import time
from pathlib import Path
from urllib.parse import urlsplit

from . import MARKETING_VERSION
from .errors import AppError
from .server import asset_root

WINDOWS = {
    "/": (f"搞门户 V{MARKETING_VERSION}", 1380, 860, (720, 520)),
    "/settings": ("搞门户设置", 820, 740, (620, 500)),
    "/downloads": ("搞门户 · 下载中心", 1180, 760, (760, 500)),
    "/mail": ("搞门户 · 邮件", 1360, 860, (790, 520)),
    "/mail#settings": ("邮件设置", 820, 740, (620, 500)),
    "/mail#floating": ("搞门户 · 邮件 · 悬浮窗", 450, 530, (350, 350)),
}


def local_window_key(path):
    if (not isinstance(path, str) or not path.startswith("/") or path.startswith("//")
            or len(path) > 2048 or any(ch in path for ch in ('\\', '\r', '\n', '\0'))):
        return None
    url = urlsplit(path)
    if url.scheme or url.netloc or url.path not in WINDOWS:
        return None
    anchor = f"{url.path}#{url.fragment}"
    if anchor == "/mail#floating-settings":
        return "/mail#settings"
    return anchor if anchor in WINDOWS else url.path


class Desktop:
    def __init__(self, server, smoke_file=None):
        self.server = server
        self.service = server.service
        self.origin = f"http://127.0.0.1:{server.port}"
        self.smoke_file = smoke_file
        self.ready = threading.Event()
        self.stop = threading.Event()
        self.mail_panel_commands = queue.SimpleQueue()
        self.windows = {}
        self.create_lock = threading.RLock()
        self.dock_thread = None
        self.tray_registered = False
        self.webview = None

    def run(self):
        import webview
        from .floating import enable_per_monitor_dpi

        enable_per_monitor_dpi()
        self.webview = webview
        webview.settings["ALLOW_DOWNLOADS"] = True
        webview.settings["ALLOW_FILE_URLS"] = False
        webview.settings["OPEN_EXTERNAL_LINKS_IN_BROWSER"] = True
        icon = asset_root() / "GaoMenHu.ico"
        main = self._create("/", hidden=bool(self.smoke_file))
        main.events.closing += self._close_main
        try:
            webview.start(self._after_start, gui="edgechromium", private_mode=False,
                          storage_path=str(self.service.data_dir.with_name(self.service.data_dir.name + ".webview")),
                          icon=str(icon) if icon.is_file() else None)
        finally:
            self.stop.set()
            if self.dock_thread:
                self.dock_thread.join(timeout=3)

    def _create(self, path, hidden=False):
        key = local_window_key(path)
        title, width, height, minimum = WINDOWS[key]
        window = self.webview.create_window(title, self.origin + path, width=width, height=height,
                                            min_size=minimum,
                                            on_top=key == "/mail#floating" and self._mail_keep_on_top(), hidden=hidden)
        self.windows[key] = window

        def trusted_page():
            raw = window.get_current_url()
            current = str(raw) if raw is not None else ""
            return current.startswith(self.origin + "/") and local_window_key(current[len(self.origin):]) is not None

        def open_window(path):
            return trusted_page() and self.open_window(path)

        def toggle_fullscreen():
            if trusted_page():
                window.toggle_fullscreen()
                return True
            return False

        def close_window():
            if not trusted_page():
                return False
            window.destroy()
            return True

        def choose_folder():
            if not trusted_page():
                return None
            choice = window.create_file_dialog(self.webview.FileDialog.FOLDER, allow_multiple=False)
            return choice[0] if choice else None

        def save_file(kind, filename, contents):
            suffix = {"zip": ".zip", "json": ".json"}.get(kind)
            if not (trusted_page() and suffix and isinstance(filename, str) and filename.endswith(suffix)
                    and Path(filename).name == filename and len(filename) <= 160
                    and isinstance(contents, str) and len(contents) <= 42_000_000):
                return False
            blob = base64.b64decode(contents, validate=True)
            choice = window.create_file_dialog(self.webview.FileDialog.SAVE, save_filename=filename,
                                               file_types=(f"{kind.upper()} (*{suffix})",))
            if not choice:
                return False
            Path(choice[0]).write_bytes(blob)
            return True

        window.expose(open_window, toggle_fullscreen, close_window, choose_folder, save_file)
        window.events.loaded += lambda: self._set_title_bar(window)
        if key != "/":
            window.events.closed += lambda: self.windows.pop(key, None)
        return window

    def _after_start(self):
        self.ready.set()
        if self.smoke_file:
            self._smoke()
            return
        from .floating import run_floating

        self.dock_thread = threading.Thread(target=run_floating, args=(self.service, self.show_main, self.stop), kwargs={
            "open_downloads": lambda: self.open_window("/downloads"),
            "open_mail": lambda: self.open_window("/mail"),
            "quit_app": self.quit,
            "icon_path": asset_root() / "GaoMenHu.ico",
            "on_tray_state": self._tray_status,
            "on_session_lock": self.service.vault.lock,
            "mail_commands": self.mail_panel_commands,
            "open_center": self.open_window,
        }, daemon=True, name="Portal tray and floating launcher")
        self.dock_thread.start()

    def _smoke(self):
        window = self.windows["/"]
        try:
            if not window.events.loaded.wait(30):
                raise RuntimeError("WebView2 did not load the local portal")
            result = window.evaluate_js("""({title:document.title, launcher:!!document.querySelector('#launcherButton'),
                bridge:!!window.pywebview?.api, token:!!document.querySelector('meta[name=gao-token]')})""")
            routes = ("/settings", "/downloads", "/mail", "/mail#floating")
            for path in routes:
                window.evaluate_js(f"""void window.pywebview.api.open_window({json.dumps(path)}).then(value =>
                    window.gaoSmokeWindow = {{path:{json.dumps(path)}, ok:value}})""")
                deadline = time.monotonic() + 12
                while time.monotonic() < deadline:
                    if window.evaluate_js(f"window.gaoSmokeWindow?.path === {json.dumps(path)} && window.gaoSmokeWindow.ok === true"):
                        break
                    time.sleep(0.1)
                else:
                    raise RuntimeError(f"The WebView2 bridge did not open {path}")
                child = self.windows[path]
                if not child.events.loaded.wait(12) or not child.evaluate_js("!!document.querySelector('meta[name=gao-token]')"):
                    raise RuntimeError(f"WebView2 did not load {path}")
            result["windows"] = list(routes)
            from .mail_floating import smoke_mail_floating
            result["mailFloating"] = smoke_mail_floating(self.service)
            Path(self.smoke_file).write_text(json.dumps(result, ensure_ascii=False), encoding="utf-8")
        except Exception as exc:
            Path(self.smoke_file).write_text(str(exc), encoding="utf-8")
        finally:
            self.quit()

    def show_main(self):
        return self.open_window("/")

    def appearance_changed(self):
        for window in tuple(self.windows.values()):
            self._set_title_bar(window)

    def mail_panel_changed(self):
        self.mail_panel_commands.put("refresh")
        panel = self.windows.get("/mail#floating")
        if panel:
            panel.on_top = self._mail_keep_on_top()

    def _mail_keep_on_top(self):
        try:
            return bool(self.service.mail_store().library["preferences"].get("keepOnTop", True))
        except (AppError, OSError):
            return True

    def _set_title_bar(self, window):
        from .floating import system_appearance

        if window.native is None:
            return
        library = self.service.store.library or {}
        appearance = library.get("appearance", "system")
        if appearance == "system":
            appearance = system_appearance()
        try:
            handle = ctypes.c_void_p(int(window.native.Handle.ToInt64()))
            dark = ctypes.c_int(appearance == "dark")
            setter = ctypes.windll.dwmapi.DwmSetWindowAttribute
            if setter(handle, 20, ctypes.byref(dark), ctypes.sizeof(dark)) != 0:
                setter(handle, 19, ctypes.byref(dark), ctypes.sizeof(dark))
        except (AttributeError, OSError, TypeError):
            logging.debug("Cannot set native title bar appearance", exc_info=True)

    def open_window(self, path):
        key = local_window_key(path)
        if not key or self.stop.is_set() or not self.ready.wait(5):
            return False
        if key == "/mail#floating" and not self.smoke_file:
            self.mail_panel_commands.put("show")
            return True
        with self.create_lock:
            window = self.windows.get(key)
            if window is None:
                window = self._create(path, hidden=bool(self.smoke_file))
            elif key != "/" and path != key:
                window.load_url(self.origin + path)
            if not self.smoke_file and window.events.shown.is_set():
                if window.native is not None and str(window.native.WindowState) == "Minimized":
                    window.restore()
                window.show()
                self._foreground(window)
        return True

    def _foreground(self, window):
        form = window.native
        if form is None:
            return
        try:
            setter = ctypes.windll.user32.SetForegroundWindow
            setter.argtypes = (ctypes.c_void_p,)
            setter(int(form.Handle.ToInt64()))
        except (AttributeError, OSError, TypeError):
            logging.debug("Cannot focus native portal window", exc_info=True)

    def _close_main(self):
        if self.stop.is_set():
            return True
        if self.tray_registered:
            self.windows["/"].hide()
            return False
        if getattr(self.service, "mail_sending", None):
            return False
        self.stop.set()
        return True

    def _tray_status(self, is_registered):
        self.tray_registered = is_registered

    def quit(self):
        if getattr(self.service, "mail_sending", None):
            ctypes.windll.user32.MessageBoxW(None, "正在发送邮件，完成后即可退出。", "搞门户", 0x40)
            return False
        self.stop.set()
        for window in reversed(tuple(self.windows.values())):
            window.destroy()
        return True
