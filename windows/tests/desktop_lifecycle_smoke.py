"""Run the normal desktop entry on an unswitched Win32 desktop with a real Explorer icon."""

import argparse
import base64
import ctypes as C
import faulthandler
import json
import msvcrt
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import traceback
import urllib.error
import urllib.request
import uuid
from contextlib import contextmanager
from ctypes import wintypes as W
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from PIL import Image

from native_desktop_smoke import send_message, win
from native_tray_lifecycle_smoke import IconIdentifier, icon_rect
from native_visual_smoke import capture_window

from gaomenhu import cli, desktop, floating, icons


class StartupInfo(C.Structure):
    _fields_ = [("size", W.DWORD), ("reserved", W.LPWSTR), ("desktop", W.LPWSTR), ("title", W.LPWSTR)] + [
        (field, W.DWORD) for field in ("x", "y", "width", "height", "cols", "rows", "fill", "flags")
    ] + [("show", W.WORD), ("reserved_size", W.WORD), ("reserved_ptr", W.LPVOID),
         ("stdin", W.HANDLE), ("stdout", W.HANDLE), ("stderr", W.HANDLE)]


class ProcessInfo(C.Structure):
    _fields_ = [("process", W.HANDLE), ("thread", W.HANDLE), ("pid", W.DWORD), ("tid", W.DWORD)]


create_process = win.bind(win.kernel32, "CreateProcessW", W.BOOL, W.LPCWSTR, W.LPWSTR, W.LPVOID, W.LPVOID, W.BOOL,
                          W.DWORD, W.LPVOID, W.LPCWSTR, C.POINTER(StartupInfo), C.POINTER(ProcessInfo))
wait_handle = win.bind(win.kernel32, "WaitForSingleObject", W.DWORD, W.HANDLE, W.DWORD)
process_exit_code = win.bind(win.kernel32, "GetExitCodeProcess", W.BOOL, W.HANDLE, C.POINTER(W.DWORD))
close_handle = win.bind(win.kernel32, "CloseHandle", W.BOOL, W.HANDLE)
terminate_process = win.bind(win.kernel32, "TerminateProcess", W.BOOL, W.HANDLE, W.UINT)
create_desktop = win.bind(win.user32, "CreateDesktopW", W.HANDLE, W.LPCWSTR, W.LPCWSTR, W.LPVOID, W.DWORD, W.DWORD, W.LPVOID)
open_desktop = win.bind(win.user32, "OpenDesktopW", W.HANDLE, W.LPCWSTR, W.DWORD, W.BOOL, W.DWORD)
close_desktop = win.bind(win.user32, "CloseDesktop", W.BOOL, W.HANDLE)
set_thread_desktop = win.bind(win.user32, "SetThreadDesktop", W.BOOL, W.HANDLE)
window_visible = win.bind(win.user32, "IsWindowVisible", W.BOOL, W.HWND)
window_exists = win.bind(win.user32, "IsWindow", W.BOOL, W.HWND)
window_class = win.bind(win.user32, "GetClassNameW", W.INT, W.HWND, W.LPWSTR, W.INT)
window_title = win.bind(win.user32, "GetWindowTextW", W.INT, W.HWND, W.LPWSTR, W.INT)
menu_count = win.bind(win.user32, "GetMenuItemCount", W.INT, W.HMENU)
menu_text = win.bind(win.user32, "GetMenuStringW", W.INT, W.HMENU, W.UINT, W.LPWSTR, W.INT, W.UINT)
menu_id = win.bind(win.user32, "GetMenuItemID", W.UINT, W.HMENU, W.INT)
dialog_button = win.bind(win.user32, "GetDlgItem", W.HWND, W.HWND, W.INT)
window_pid = win.bind(win.user32, "GetWindowThreadProcessId", W.DWORD, W.HWND, C.POINTER(W.DWORD))
ENUMPROC = C.WINFUNCTYPE(W.BOOL, W.HWND, W.LPARAM)
enum_windows = win.bind(win.user32, "EnumWindows", W.BOOL, ENUMPROC, W.LPARAM)


def wait_for(condition, description, timeout=15):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        result = condition()
        if result:
            return result
        time.sleep(0.05)
    raise RuntimeError(f"Timed out waiting for {description}")


def process_on_desktop(name, arguments, *, timeout, console=None):
    startup = StartupInfo(size=C.sizeof(StartupInfo), desktop="WinSta0\\" + name)
    process = ProcessInfo()
    command = C.create_unicode_buffer(subprocess.list2cmdline(arguments))
    if console:
        with console.open("ab") as output, open(os.devnull, "rb") as input_stream:
            startup.flags = 0x100  # STARTF_USESTDHANDLES
            startup.stdout = startup.stderr = msvcrt.get_osfhandle(output.fileno())
            startup.stdin = msvcrt.get_osfhandle(input_stream.fileno())
            for handle in (startup.stdout, startup.stdin):
                os.set_handle_inheritable(handle, True)
            created = create_process(None, command, None, None, True, 0x08000000, None, None, C.byref(startup), C.byref(process))
    else:
        created = create_process(None, command, None, None, False, 0x08000000, None, None, C.byref(startup), C.byref(process))
    if not created:
        raise C.WinError(C.get_last_error())
    close_handle(process.thread)
    try:
        if wait_handle(process.process, int(timeout * 1000)) != 0:
            terminate_process(process.process, 1)
            wait_handle(process.process, 3000)
            raise RuntimeError("The isolated desktop process did not stop")
        status = W.DWORD()
        if not process_exit_code(process.process, C.byref(status)):
            raise C.WinError(C.get_last_error())
        return status.value
    finally:
        close_handle(process.process)


def windows_for_process(class_name=None, title=None):
    handles = []

    @ENUMPROC
    def visit(handle, _):
        pid = W.DWORD()
        window_pid(handle, C.byref(pid))
        if pid.value == os.getpid():
            text = C.create_unicode_buffer(200)
            window_class(handle, text, len(text))
            if class_name is not None and text.value != class_name:
                return True
            window_title(handle, text, len(text))
            if title is None or text.value == title:
                handles.append(handle)
        return True

    enum_windows(visit, 0)
    return handles


def post(window, message, wparam=0, lparam=0):
    if not win.post_message(window, message, wparam, lparam):
        raise C.WinError(C.get_last_error())


def native_window(window):
    return int(window.native.Handle.ToInt64()) if window.native is not None else None


def capture_webview(window, destination):
    from System import Action

    control = window.native.webview
    tasks = []
    control.Invoke(Action(lambda: tasks.append(control.CoreWebView2.CallDevToolsProtocolMethodAsync(
        "Page.captureScreenshot", '{"format":"png"}'))))
    if not tasks[0].Wait(10000):
        raise RuntimeError("WebView2 did not capture the restored launcher")
    destination.write_bytes(base64.b64decode(json.loads(str(tasks[0].Result))["data"], validate=True))


class ShellProbe:
    def __init__(self):
        self.registrations = set()
        self.removals = set()
        self.chosen = []
        self.choice = ""
        self.hwnd = None
        self.icon = None
        self.tip = ""
        self.tip_updates = []
        self.notify = win.notify_icon

    def notify_icon(self, operation, data):
        result = self.notify(operation, data)
        icon = C.cast(data, C.POINTER(win.NotifyIcon)).contents
        if operation == win.NIM_ADD and result:
            self.hwnd = icon.window
            self.icon = IconIdentifier(size=C.sizeof(IconIdentifier), window=icon.window, id=icon.id)
            self.registrations.add((icon.window, icon.id))
        if operation in (win.NIM_ADD, win.NIM_MODIFY) and result and icon.flags & win.NIF_TIP:
            self.tip = icon.tip
            if operation == win.NIM_MODIFY and icon.flags == win.NIF_TIP:
                self.tip_updates.append(icon.tip)
        if operation == win.NIM_DELETE and result:
            self.removals.add((icon.window, icon.id))
        return result

    def select_menu(self, menu, *_):
        for index in range(menu_count(menu)):
            label = C.create_unicode_buffer(96)
            menu_text(menu, index, label, len(label), 0x0400)  # MF_BYPOSITION
            if label.value == self.choice:
                self.chosen.append(label.value)
                return menu_id(menu, index)
        return 0

    def choose(self, label):
        self.choice = label
        total = len(self.chosen)
        send_message(self.hwnd, win.TRAY_MESSAGE, self.icon.id, 0x0205)  # WM_RBUTTONUP
        wait_for(lambda: len(self.chosen) > total, f"tray menu selection {label!r}")


def portal_api(app, route, payload=None):
    request = urllib.request.Request(app.origin + route, data=json.dumps(payload or {}).encode(),
                                     headers={"X-Gao-Token": app.service.page_token, "Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=3) as response:
        result = json.load(response)
    if not result.get("ok"):
        raise RuntimeError(result.get("error"))
    return result


def choose_exit_prompt(button, *, screenshot=None):
    def find_prompt():
        matches = [item for item in windows_for_process("#32770", "搞门户") if window_visible(item)]
        return matches[0] if matches else None

    prompt = wait_for(find_prompt, "the real native exit confirmation")
    control = dialog_button(prompt, button)
    assert control, f"The exit confirmation lacks button {button}"
    if screenshot:
        def body_painted():
            capture_window(prompt, win.window_rect(prompt), screenshot)
            with Image.open(screenshot) as image:
                return image.crop((0, image.height // 3, image.width, image.height)).getbbox() is not None

        wait_for(body_painted, "the exit confirmation painting on the private desktop")
    post(prompt, 0x0111, button, control)  # WM_COMMAND with a real Yes/No button
    wait_for(lambda: not window_exists(prompt), "dismissal of the native exit confirmation")


@contextmanager
def verify_download_tray(app, shell, work, evidence):
    chunk = b"D" * 65536
    release = {path: threading.Event() for path in ("/known-total.bin", "/unknown-total.bin", "/exit-transfer.bin")}

    class FixtureDownload(BaseHTTPRequestHandler):
        def log_message(self, *_):
            return

        def do_GET(self):
            self.send_response(200)
            if self.path != "/unknown-total.bin":
                self.send_header("Content-Length", str(2 * len(chunk)))
            self.send_header("ETag", '"tray-fixture"')
            self.end_headers()
            try:
                self.wfile.write(chunk)
                self.wfile.flush()
                release[self.path].wait(35)
                self.wfile.write(chunk)
            except ConnectionError:
                pass

    with ThreadingHTTPServer(("127.0.0.1", 0), FixtureDownload) as source:
        worker = threading.Thread(target=source.serve_forever, daemon=True)
        worker.start()
        try:
            directory = work / "isolated-downloads"
            directory.mkdir()
            grant = portal_api(app, "/api/downloads/destination", {"path": str(directory)})["destination"]

            def start(path):
                result = portal_api(app, "/api/downloads/create", {
                    "urls": [f"http://localhost:{source.server_port}{path}"], "destinationID": grant["id"],
                })
                return next(item["id"] for item in result["items"] if item["suggestedName"] == path[1:])

            known_tip = "搞门户 · 1 项下载进行中 · 已传输 50%"
            start("/known-total.bin")
            wait_for(lambda: shell.tip == known_tip, "Explorer accepting the measured 50% progress")
            shell.choose("下载中心… · 1 项下载进行中 · 已传输 50%")
            download = wait_for(lambda: app.windows.get("/downloads"), "the download window from the tray")
            assert download.events.loaded.wait(12)
            wait_for(lambda: download.evaluate_js("Boolean(document.querySelector('.download-list [data-state=running]'))"),
                     "the live transfer in the download window")
            if evidence:
                capture_webview(download, evidence / "download-center-from-tray.png")
            release["/known-total.bin"].set()
            wait_for(lambda: shell.tip == "搞门户", "idle tray after the download completed")

            unknown_tip = "搞门户 · 1 项下载进行中"
            unknown = start("/unknown-total.bin")
            wait_for(lambda: shell.tip == unknown_tip, "Explorer accepting the download count without an unknown percentage")
            shell.choose("下载中心… · 1 项下载进行中")
            portal_api(app, "/api/downloads/pause", {"id": unknown})
            release["/unknown-total.bin"].set()
            wait_for(lambda: shell.tip == "搞门户", "idle tray after pausing a download")
            shell.choose("下载中心…")
            assert len(shell.registrations) == 1
            checked = {"knownTotal": known_tip, "unknownTotal": unknown_tip, "idle": shell.tip,
                       "acceptedTooltipUpdates": shell.tip_updates.copy()}
            exit_task = start("/exit-transfer.bin")
            wait_for(lambda: shell.tip == known_tip, "the transfer checkpoint before the tray exit")
            yield checked, exit_task
        finally:
            for event in release.values():
                event.set()
            source.shutdown()
            worker.join(5)


def verify_lifecycle(app, shell, desktop_name, data, evidence):
    main = app.windows["/"]
    if not main.events.loaded.wait(25):
        raise RuntimeError("The normal WebView2 launcher did not initialize")
    handle = native_window(main)
    assert handle and window_visible(handle)
    wait_for(lambda: shell.hwnd and app.tray_registered, "the original Explorer notification icon")
    assert shell.registrations == {(shell.hwnd, 1)}
    assert main.evaluate_js("!!document.querySelector('.workspace-shell #launcherButton')")
    print("The main window and real tray icon initialized.")

    post(handle, 0x0010)  # WM_CLOSE
    wait_for(lambda: not window_visible(handle), "the main window hiding to the tray")
    assert window_exists(handle) and app.tray_registered and portal_api(app, "/api/state")["ok"]
    print("WM_CLOSE kept the original process, window and loopback server available.")
    send_message(shell.hwnd, win.TRAY_MESSAGE, shell.icon.id, 0x0202)  # WM_LBUTTONUP
    wait_for(lambda: window_visible(handle), "the tray click restoring the original WinForms window")
    print("The tray click restored the original window.")
    if evidence:
        capture_webview(main, evidence / "webview2-restored-from-tray.png")

    post(handle, 0x0010)
    wait_for(lambda: not window_visible(handle), "the second close hiding the main window")
    shell.choose("打开搞门户")
    wait_for(lambda: window_visible(handle), "the Open menu restoring the original WinForms window")
    print("The tray Open command restored the original window.")

    post(handle, 0x0010)
    wait_for(lambda: not window_visible(handle), "the third close hiding the main window")
    launcher = Path(__file__).resolve().parents[1] / "launch.py"
    assert process_on_desktop(desktop_name, [sys.executable, str(launcher), "--data-dir", str(data)], timeout=14) == 0
    wait_for(lambda: window_visible(handle), "ordinary second launch forwarding to the original instance")
    assert native_window(app.windows["/"]) == handle and len(shell.registrations) == 1
    print("The second application process forwarded to the original instance.")

    with verify_download_tray(app, shell, data.parent, evidence) as (tray_download, exit_task):
        print("The original tray icon reported a real download and omitted the unknown percentage.")
        verify_mail_tray_exit(app, shell, handle, evidence, exit_task)
        wait_for(lambda: transfer_state(app, exit_task) == ("paused", 65536), "the exit keeping the active download checkpoint")
        tray_download["exitPausedAt64KiB"] = True
    return {"mainHwnd": handle, "trayHwnd": shell.hwnd, "trayIconId": shell.icon.id,
            "regularReopen": True, "menuLabels": shell.chosen, "cancelledWithDraftInEditor": True,
            "hostPort": app.server.port, "distinctIconIdentities": len(shell.registrations), "trayDownload": tray_download}


def transfer_state(app, task):
    manager = app.service.downloads
    with manager.lock:
        item = manager._item(task)
        return item["state"], item["bytesReceived"]


def verify_mail_tray_exit(app, shell, handle, evidence, exit_task):
    portal_api(app, "/api/mail/account", {"account": {"id": "exit-fixture", "email": "isolated@example.test"}})
    shell.choose("邮件中心…")
    mail = wait_for(lambda: app.windows.get("/mail"), "the native mail window from the tray")
    if not mail.events.loaded.wait(15):
        raise RuntimeError("The normal WebView2 mail pane did not load")
    wait_for(lambda: mail.evaluate_js("!!document.querySelector('button[title=\"写信\"]')"), "the mail toolbar")
    mail.evaluate_js("document.querySelector('button[title=\"写信\"]').click()")
    wait_for(lambda: mail.evaluate_js("!!document.querySelector('dialog[open] textarea')"), "the mail draft composer")
    mail.evaluate_js("""(() => {
        const field = document.querySelector('dialog[open] textarea');
        field.value = '只用于测试退出草稿';
        field.dispatchEvent(new Event('input', {bubbles:true}));
    })()""")
    assert mail.evaluate_js("window.gaoCloseState().draft")
    print("The native mail window holds a dirty draft.")

    shell.choose("退出搞门户")
    choose_exit_prompt(7, screenshot=evidence / "exit-draft-confirmation.png" if evidence else None)  # IDNO
    wait_for(lambda: not app.exit_pending, "the cancelled exit finishing")
    assert not app.stop.is_set() and window_exists(handle) and app.tray_registered
    assert mail.evaluate_js("document.querySelector('dialog[open] textarea').value") == "只用于测试退出草稿"
    assert portal_api(app, "/api/mail/state")["drafts"] == []
    assert transfer_state(app, exit_task) == ("running", 65536)
    print("Cancelling native exit left the draft in the editor.")

    shell.choose("退出搞门户")
    choose_exit_prompt(6)  # IDYES
    wait_for(app.stop.is_set, "the confirmed application exit")
    print("Confirming native exit saved the draft and initiated shutdown.")


def run_child(work, desktop_name, evidence):
    data = work / "MenDao"
    os.environ["GAOMENHU_DATA_DIR"] = str(data)
    shell = ShellProbe()
    original_run_floating = floating.run_floating
    original_after_start = desktop.Desktop._after_start
    completed = threading.Event()
    result = {}

    def dock_on_explorer(*args, **kwargs):
        explorer_desktop = open_desktop("Default", 0, False, 0x00C7)
        if not explorer_desktop or not set_thread_desktop(explorer_desktop):
            raise C.WinError(C.get_last_error())
        original_run_floating(*args, **kwargs)

    def start_probe(app):
        original_after_start(app)

        def run():
            try:
                result.update(verify_lifecycle(app, shell, desktop_name, data, evidence))
            except Exception:
                result["error"] = traceback.format_exc()
                app._destroy_windows()
            finally:
                completed.set()

        threading.Thread(target=run, name="GaoMenHuDesktopLifecycleProbe", daemon=True).start()

    floating.run_floating = dock_on_explorer
    desktop.Desktop._after_start = start_probe
    win.notify_icon = shell.notify_icon
    win.track_menu = shell.select_menu
    # This hook only changes activation requests from the Tk notification
    # wrapper. The app's real WinForms windows are on the private desktop.
    win.set_foreground = lambda _: False
    icons.load_website_icon = lambda _: None
    exit_code = cli.main(["--data-dir", str(data)])
    completed.wait(8)
    result["exitCode"] = exit_code
    result["shellRemovedOwnIcon"] = bool(shell.registrations and shell.registrations == shell.removals)
    (work / "desktop-lifecycle.json").write_text(json.dumps(result, ensure_ascii=False), encoding="utf-8")
    return 0 if completed.is_set() and not result.get("error") and exit_code == 0 else 1


def run_parent(work, evidence):
    foreground = win.get_foreground()
    name = "GaoMenHu-QA-" + uuid.uuid4().hex
    private = create_desktop(name, None, None, 0, 0x00C7, None)
    if not private:
        raise C.WinError(C.get_last_error())
    try:
        arguments = [sys.executable, str(Path(__file__).resolve()), str(work), "--child-desktop", name]
        if evidence:
            arguments.extend(("--evidence", str(evidence)))
        console = work / "desktop-console.log"
        status = process_on_desktop(name, arguments, timeout=80, console=console)
        report = work / "desktop-lifecycle.json"
        if not report.exists():
            log = work / "desktop-lifecycle.log"
            diagnostic = [entry.read_text(encoding="utf-8", errors="replace") for entry in (log, console) if entry.exists()]
            raise RuntimeError(f"The isolated desktop process exited with {status:#x}\n" + "\n".join(diagnostic))
        result = json.loads(report.read_text(encoding="utf-8"))
        if status or result.get("error"):
            raise RuntimeError(result.get("error") or f"The desktop test exited with status {status}")
        assert result["exitCode"] == 0 and result["shellRemovedOwnIcon"]
        assert not window_exists(result["trayHwnd"]) and not window_exists(result["mainHwnd"])
        identifier = IconIdentifier(size=C.sizeof(IconIdentifier), window=result["trayHwnd"], id=result["trayIconId"])
        assert icon_rect(identifier) is None
        assert not (work / "MenDao.native.json").exists()
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{result['hostPort']}/", timeout=2):
                raise AssertionError("The isolated loopback port is still responding after exit")
        except urllib.error.URLError:
            pass
        library = json.loads((work / "MenDao" / "MailCenter" / "Library.json").read_text(encoding="utf-8"))
        assert len(library["drafts"]) == 1 and library["drafts"][0]["body"] == "只用于测试退出草稿"
        result.update({"draftSavedOnExit": True, "portClosed": True, "trayRemoved": True,
                       "realExplorer": True, "foregroundUnchanged": win.get_foreground() == foreground})
        return result
    finally:
        if not close_desktop(private):
            raise C.WinError(C.get_last_error())


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("work_dir", type=Path)
    parser.add_argument("--child-desktop")
    parser.add_argument("--evidence", type=Path)
    options = parser.parse_args()
    base = options.work_dir.resolve(strict=True)
    evidence = options.evidence.resolve() if options.evidence else None
    if evidence:
        evidence.mkdir(parents=True, exist_ok=True)
    if options.child_desktop:
        with (base / "desktop-lifecycle.log").open("w", encoding="utf-8", buffering=1) as stream:
            sys.stdout = sys.stderr = stream
            faulthandler.enable(stream)
            raise SystemExit(run_child(base, options.child_desktop, evidence))
    work = Path(tempfile.mkdtemp(prefix="gaomenhu-desktop-", dir=base))
    try:
        print(json.dumps(run_parent(work, evidence), ensure_ascii=False))
    finally:
        # The WebView2 browser can release its test profile just after the host exits.
        for attempt in range(20):
            try:
                shutil.rmtree(work)
                break
            except PermissionError:
                if attempt == 19:
                    raise
                time.sleep(0.2)
