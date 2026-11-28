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
    "/downloads": ("搞门户 · 下载中心", 1180, 760, (560, 460)),
    "/mail": ("搞门户 · 邮件中心", 1360, 860, (560, 480)),
    "/mail#settings": ("邮件设置", 820, 740, (620, 500)),
    "/mail#floating": ("搞门户 · 邮件 · 悬浮窗", 450, 530, (350, 350)),
}
LOG = logging.getLogger(__name__)


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
        self.dock_open_requests = queue.SimpleQueue()
        self.windows = {}
        self.create_lock = threading.RLock()
        self.dock_thread = None
        self.dock_open_thread = None
        self.tray_starting = not smoke_file
        self.tray_registered = False
        self.tray_window = None
        self.hidden_while_tray_starting = False
        self.main_hidden = False
        self.exit_lock = threading.Lock()
        self.exit_pending = False
        self.mail_close_pending = set()
        self.mail_close_approved = set()
        self.webview = None

    def run(self):
        import webview
        from .floating import enable_per_monitor_dpi

        enable_per_monitor_dpi()
        self.webview = webview
        webview.settings["ALLOW_DOWNLOADS"] = True
        webview.settings["ALLOW_FILE_URLS"] = False
        webview.settings["OPEN_EXTERNAL_LINKS_IN_BROWSER"] = True
        main = self._create("/", hidden=bool(self.smoke_file))
        main.events.closing += self._close_main
        try:
            webview.start(self._after_start, gui="edgechromium", private_mode=False,
                          storage_path=str(self.service.data_dir.with_name(self.service.data_dir.name + ".webview")))
        finally:
            self.stop.set()
            self.dock_open_requests.put(None)
            if self.dock_thread:
                self.dock_thread.join(timeout=3)
            if self.dock_open_thread:
                self.dock_open_thread.join(timeout=3)

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
        icon = asset_root() / "GaoMenHu.ico"
        if icon.is_file():
            def apply_icons():
                from .floating_win32 import bind_form_icons

                bind_form_icons(window.native, icon)

            window.events.before_show += apply_icons
        window.events.loaded += lambda: self._set_title_bar(key, window)
        if key == "/":
            window.events.loaded += self._publish_main_visibility
        else:
            window.events.closed += lambda: self.windows.pop(key, None)
            if key == "/mail":
                window.events.closing += lambda: self._close_mail(window)
        return window

    def _after_start(self):
        self.ready.set()
        if self.smoke_file:
            self._smoke()
            return
        from .floating import run_floating

        def open_from_dock():
            while (path := self.dock_open_requests.get()) is not None:
                try:
                    self.open_window(path)
                except Exception:
                    LOG.exception("Could not open a window from the notification area")

        def run_dock():
            try:
                run_floating(self.service, lambda: self._queue_dock_open("/"), self.stop,
                             open_downloads=lambda: self._queue_dock_open("/downloads"),
                             open_mail=lambda: self._queue_dock_open("/mail"), quit_app=self.request_quit,
                             icon_path=asset_root() / "GaoMenHu.ico", on_tray_state=self._tray_status,
                             on_session_lock=self.service.vault.lock, mail_commands=self.mail_panel_commands,
                             open_center=self._queue_dock_open)
            except Exception:
                LOG.exception("The notification area worker stopped unexpectedly")
            finally:
                if not self.stop.is_set():
                    self._tray_worker_stopped()

        self.dock_open_thread = threading.Thread(target=open_from_dock, daemon=True, name="Portal tray window requests")
        self.dock_open_thread.start()
        self.dock_thread = threading.Thread(target=run_dock, daemon=True, name="Portal tray and floating launcher")
        self.dock_thread.start()

    def _queue_dock_open(self, path):
        if not self.stop.is_set() and not self.exit_pending:
            self.dock_open_requests.put(path)

    def _smoke(self):
        window = self.windows["/"]
        try:
            if not window.events.loaded.wait(30):
                raise RuntimeError("WebView2 did not load the local portal")
            result = window.evaluate_js("""({title:document.title, launcher:!!document.querySelector('.workspace-shell #launcherButton'),
                bridge:!!window.pywebview?.api, token:!!document.querySelector('meta[name=gao-token]')})""")
            routes = {"/settings": "body.settings-window #launcherSettingsTabs", "/downloads": ".download-window .download-tabs",
                      "/mail": ".mail-window .mail-nav", "/mail#floating": ".floating"}
            for path, selector in routes.items():
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
                if not child.events.loaded.wait(12):
                    raise RuntimeError(f"WebView2 did not load {path}")
                deadline = time.monotonic() + 8
                while time.monotonic() < deadline:
                    if child.evaluate_js(f"!!document.querySelector({json.dumps(selector)})"):
                        break
                    time.sleep(0.1)
                else:
                    raise RuntimeError(f"WebView2 did not render the interface for {path}")
            result["windows"] = list(routes)
            settings = self.windows["/settings"]
            settings.evaluate_js("document.querySelector('#settings-tab-browsers').click()")
            deadline = time.monotonic() + 8
            while time.monotonic() < deadline:
                if settings.evaluate_js("Boolean(document.querySelector('[data-browser=chrome] .diagnostic-state') && "
                                        "document.querySelector('[data-browser=edge] .diagnostic-state'))"):
                    result["browserDiagnostics"] = True
                    break
                time.sleep(0.1)
            else:
                raise RuntimeError("WebView2 did not render the browser connection diagnosis")
            from .mail_floating import smoke_mail_floating
            result["mailFloating"] = smoke_mail_floating(self.service)
            Path(self.smoke_file).write_text(json.dumps(result, ensure_ascii=False), encoding="utf-8")
        except Exception as exc:
            Path(self.smoke_file).write_text(str(exc), encoding="utf-8")
        finally:
            self._destroy_windows()

    def show_main(self):
        return self.open_window("/")

    def _set_main_hidden(self, hidden):
        if hidden != self.main_hidden:
            self.main_hidden = hidden
            self._publish_main_visibility()

    def _publish_main_visibility(self):
        window = self.windows.get("/")
        form = window.native if window else None
        if form is None or self.stop.is_set():
            return

        def publish():
            try:
                control = form.webview.CoreWebView2
                if control is not None and not self.stop.is_set():
                    script = "window.gaoSetDesktopHidden?.(" + json.dumps(self.main_hidden) + ")"
                    control.ExecuteScriptAsync(script)
            except Exception:
                LOG.debug("Could not notify the launcher of window visibility", exc_info=True)

        try:
            from System import Action

            form.BeginInvoke(Action(publish))
        except Exception:
            LOG.debug("Could not dispatch launcher visibility", exc_info=True)

    def appearance_changed(self, route="/"):
        for key, window in tuple(self.windows.items()):
            if key == route or key.startswith(route + "#") or (route == "/" and key == "/settings"):
                self._set_title_bar(key, window)

    def mail_panel_changed(self):
        self.mail_panel_commands.put("refresh")
        self.appearance_changed("/mail")
        panel = self.windows.get("/mail#floating")
        if panel:
            panel.on_top = self._mail_keep_on_top()

    def _mail_keep_on_top(self):
        try:
            return bool(self.service.mail_store().library["preferences"].get("keepOnTop", True))
        except (AppError, OSError):
            return True

    def _set_title_bar(self, key, window):
        from .floating import system_appearance

        if window.native is None:
            return
        try:
            if key == "/downloads":
                preferences = self.service.download_manager().database["settings"]
            elif key.split("#", 1)[0] == "/mail":
                preferences = self.service.mail_store().library["preferences"]
            else:
                preferences = self.service.store.library or {}
            appearance = preferences.get("appearance", "system")
            if appearance == "system":
                appearance = system_appearance()
            handle = ctypes.c_void_p(int(window.native.Handle.ToInt64()))
            dark = ctypes.c_int(appearance == "dark")
            setter = ctypes.windll.dwmapi.DwmSetWindowAttribute
            if setter(handle, 20, ctypes.byref(dark), ctypes.sizeof(dark)) != 0:
                setter(handle, 19, ctypes.byref(dark), ctypes.sizeof(dark))
        except (AppError, AttributeError, OSError, TypeError):
            logging.debug("Cannot set native title bar appearance", exc_info=True)

    def open_window(self, path):
        key = local_window_key(path)
        if not key or self.stop.is_set() or not self.ready.wait(5):
            return False
        with self.create_lock:
            if self.stop.is_set() or self.exit_pending:
                return False
            if key == "/mail#floating" and not self.smoke_file:
                self.mail_panel_commands.put("show")
                return True
            window = self.windows.get(key)
            if window is None:
                window = self._create(path, hidden=bool(self.smoke_file))
            elif key != "/" and path != key:
                window.load_url(self.origin + path)
            if not self.smoke_file and window.events.shown.is_set():
                if key == "/":
                    self.hidden_while_tray_starting = False
                if window.native is not None and str(window.native.WindowState) == "Minimized":
                    window.restore()
                window.show()
                if key == "/":
                    self._set_main_hidden(False)
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
        if self.tray_registered or self.tray_starting:
            window = self.windows["/"]
            self.hidden_while_tray_starting = not self.tray_registered
            window.hide()
            # Explorer startup can complete while the UI callback is hiding
            # the window. Restore it if the app ended up without a tray.
            if not self.tray_registered and not self.tray_starting:
                self.hidden_while_tray_starting = False
                window.show()
                self._set_main_hidden(False)
            else:
                self._set_main_hidden(True)
        else:
            self.request_quit()
        return False

    def _close_mail(self, window):
        with self.exit_lock:
            if self.stop.is_set() or window in self.mail_close_approved or not window.events.loaded.is_set():
                return True
            if self.exit_pending or window in self.mail_close_pending:
                return False
            self.mail_close_pending.add(window)
        threading.Thread(target=self._finish_mail_close, args=(window,), daemon=True, name="Portal mail close").start()
        return False

    def _finish_mail_close(self, window):
        try:
            state = self._evaluate_for_exit(window, "window.gaoCloseState?.() || {}")
            if state.get("busy") or self.service.mail_blocks_exit():
                self._exit_prompt("邮件操作仍在进行。请等待操作完成后再关闭窗口。")
                return
            if state.get("editing"):
                self._exit_prompt("请先完成或关闭正在编辑的邮件表单。")
                return
            if state.get("draft"):
                result = self._evaluate_for_exit(window, "window.gaoSaveDraftBeforeClose()", promise=True)
                if result.get("ok") is not True:
                    self._exit_prompt("邮件草稿未能保存，窗口已保留。请保存后重试。")
                    return
            current = self._evaluate_for_exit(window, "window.gaoCloseState?.() || {}")
            if any(current.get(key) for key in ("busy", "editing", "draft")):
                self._exit_prompt("有新的编辑或尚未完成的操作，请核对后再关闭邮件窗口。")
                return
            with self.exit_lock:
                self.mail_close_approved.add(window)
            if not window.events.closed.is_set():
                window.destroy()
        except Exception:
            LOG.exception("Could not safely close the mail window")
            self._exit_prompt("无法确认邮件草稿状态。请保存后再关闭。")
        finally:
            with self.exit_lock:
                self.mail_close_pending.discard(window)
                self.mail_close_approved.discard(window)

    def _tray_status(self, is_registered, handle):
        # The shell can temporarily lose the icon during an Explorer restart.
        self.tray_window = handle
        self.tray_registered |= is_registered
        self.tray_starting = False
        self._recover_without_tray()

    def _tray_worker_stopped(self):
        restore = self.tray_registered or self.hidden_while_tray_starting
        self.tray_registered = self.tray_starting = False
        self.tray_window = None
        self.hidden_while_tray_starting = restore
        self._recover_without_tray()

    def _recover_without_tray(self):
        if not self.tray_registered and not self.tray_starting and self.hidden_while_tray_starting:
            self._queue_dock_open("/")

    def request_quit(self):
        with self.exit_lock:
            if self.exit_pending or self.stop.is_set():
                return True
            self.exit_pending = True
        # Native closing events and the Tk notification callback must return
        # before WinForms can evaluate the page or destroy its windows.
        threading.Thread(target=self._quit, daemon=True, name="Portal exit").start()
        return True

    def _quit(self):
        try:
            self._confirm_exit()
        except Exception:
            LOG.exception("Could not complete the desktop exit")
            self._exit_prompt("无法确认窗口中的更改。请在关闭表单或保存后重试。")
        finally:
            with self.exit_lock:
                self.exit_pending = False
            self._recover_without_tray()

    def _confirm_exit(self):
        if self.service.mail_blocks_exit():
            self._exit_prompt("正在发送邮件或保存邮箱授权，完成后即可退出。")
            return
        pages = self._exit_states()
        if any(state.get("busy") for state in pages.values()):
            self._exit_prompt("窗口中的操作仍在进行。请等待操作完成后再退出。")
            return
        if any(state.get("editing") or state.get("draft") for state in pages.values()):
            details = []
            if any(state.get("draft") for state in pages.values()):
                details.append("当前撰写的邮件会保存为草稿。")
            if any(state.get("editing") for state in pages.values()):
                details.append("其他未保存的更改将丢弃。")
            if not self._exit_prompt("\n".join(details + ["确定退出搞门户？"]), confirm=True):
                return
            current = self._exit_states()
            if self._new_exit_activity(pages, current):
                self._exit_prompt("有新的编辑或尚未完成的操作，请核对窗口后再退出。")
                return
            pages = current
        for window, state in pages.items():
            if not state.get("draft"):
                continue
            result = self._evaluate_for_exit(window, "window.gaoSaveDraftBeforeClose()", promise=True)
            if result.get("ok") is not True:
                self._exit_prompt("邮件草稿未能保存，窗口已保留。请保存后重试。")
                return
        current = self._exit_states()
        if self._new_exit_activity(pages, current) or any(state.get("draft") for state in current.values()):
            self._exit_prompt("有新的编辑或尚未完成的操作，请核对窗口后再退出。")
            return
        if not self.service.begin_shutdown():
            self._exit_prompt("正在发送邮件或保存邮箱授权，完成后即可退出。")
            return
        self._destroy_windows()

    def _exit_states(self):
        return {window: self._evaluate_for_exit(window, "window.gaoCloseState?.() || {}")
                for window in tuple(self.windows.values()) if window.events.loaded.is_set() and not window.events.closed.is_set()}

    @staticmethod
    def _new_exit_activity(previous, current):
        return any(state.get("busy") or any(state.get(key) and not previous.get(window, {}).get(key)
                                            for key in ("editing", "draft")) for window, state in current.items())

    @staticmethod
    def _evaluate_for_exit(window, script, *, promise=False):
        responses = queue.SimpleQueue()

        def evaluate():
            try:
                if promise:
                    window.evaluate_js(script, callback=lambda value: responses.put((value, None)))
                else:
                    responses.put((window.evaluate_js(script), None))
            except Exception as exc:
                responses.put((None, exc))

        # WebView2 6.1 can wait indefinitely while a renderer modal is open.
        threading.Thread(target=evaluate, daemon=True, name="Portal exit page check").start()
        response, error = responses.get(timeout=10)
        if error is not None:
            raise error
        if not isinstance(response, dict):
            raise AppError("无法确认窗口状态。")
        return response

    def _exit_prompt(self, message, *, confirm=False):
        window = self.windows.get("/")
        form = window.native if window else None
        owner = int(form.Handle.ToInt64()) if form is not None else None
        box = ctypes.windll.user32.MessageBoxW
        box.argtypes = ctypes.c_void_p, ctypes.c_wchar_p, ctypes.c_wchar_p, ctypes.c_uint
        response = box(owner, message, "搞门户", 0x134 if confirm else 0x40)
        return response == 6  # IDYES

    def _destroy_windows(self):
        with self.create_lock:
            if self.tray_window:
                from .floating_win32 import post_message

                post_message(self.tray_window, 0x001F, 0, 0)  # WM_CANCELMODE
            self.stop.set()
            windows = tuple(self.windows.values())
        for window in reversed(windows):
            if not window.events.closed.is_set():
                window.destroy()
