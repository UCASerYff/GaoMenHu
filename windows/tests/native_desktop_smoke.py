"""Opt-in native smoke. The IME window uses a private desktop without switching it."""

import argparse
import ctypes as C
import gc
import json
import sys
import tempfile
import threading
import time
import tkinter as tk
import traceback
import uuid
from ctypes import wintypes as W
from pathlib import Path
from queue import SimpleQueue
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from gaomenhu import floating_win32 as win
from gaomenhu.floating import FloatingPanel
from gaomenhu.mail_floating import MailFloatingPanel
from gaomenhu.service import PortalService

send_message = win.bind(win.user32, "SendMessageW", win.LRESULT, W.HWND, W.UINT, W.WPARAM, W.LPARAM)


def tray_smoke():
    foreground = win.get_foreground()
    root = tk.Tk()
    root.withdraw()
    root.overrideredirect(True)
    tk.Entry(root).pack()
    with win.without_activation():
        root.update_idletasks()
    events = []
    window = win.DesktopWindow(root, events.append, lambda _: False)
    try:
        assert window.tray_available, "Explorer did not register the hidden trial icon"
        send_message(window.window, win.TRAY_MESSAGE, 0, 0x0202)
        send_message(window.window, win.TRAY_MESSAGE, 0, 0x0205)
        with win.without_activation():
            root.update()
        assert events == ["open", "tray"], events
        current_foreground = win.get_foreground()
        assert current_foreground != window.window, "The trial icon window took foreground focus"
        return {"registered": True, "callbacks": events, "tookForeground": False,
                "foregroundUnchanged": current_foreground == foreground}
    finally:
        window.close()
        root.destroy()


def run_on_private_desktop(operation, work_dir):
    create_desktop = win.bind(win.user32, "CreateDesktopW", W.HANDLE, W.LPCWSTR, W.LPCWSTR, W.LPVOID, W.DWORD, W.DWORD, W.LPVOID)
    get_desktop = win.bind(win.user32, "GetThreadDesktop", W.HANDLE, W.DWORD)
    set_desktop = win.bind(win.user32, "SetThreadDesktop", W.BOOL, W.HANDLE)
    close_desktop = win.bind(win.user32, "CloseDesktop", W.BOOL, W.HANDLE)
    foreground = win.get_foreground()
    previous = get_desktop(win.current_thread_id())
    private = create_desktop("GaoMenHu-QA-" + uuid.uuid4().hex, None, None, 0, 0x0087, None)
    if not private or not set_desktop(previous):
        raise C.WinError(C.get_last_error())
    results = SimpleQueue()

    def worker():
        try:
            if not set_desktop(private):
                raise C.WinError(C.get_last_error())
            win.enable_thread_dpi()
            results.put((operation(work_dir), None))
        except Exception:
            results.put((None, traceback.format_exc()))
        finally:
            # Tcl retains a thread-owned hidden message window after Tk
            # closes. No Tk object or desktop assignment survives this worker.
            gc.collect()

    thread = threading.Thread(target=worker, name="GaoMenHuPrivateDesktopSmoke")
    thread.start()
    thread.join()
    result, error = results.get_nowait()
    for _ in range(20):
        if close_desktop(private):
            break
        if C.get_last_error() != 170:  # ERROR_BUSY while USER32 detaches the exiting worker
            raise C.WinError(C.get_last_error())
        time.sleep(0.025)
    else:
        raise RuntimeError("The test desktop is still attached after the worker exited")
    if error:
        raise RuntimeError(error)
    return result | {"foregroundUnchanged": win.get_foreground() == foreground}


def ime_smoke(work_dir):
    layout = win.bind(win.user32, "GetKeyboardLayout", W.HANDLE, W.DWORD)
    set_focus = win.bind(win.user32, "SetFocus", W.HWND, W.HWND)
    with tempfile.TemporaryDirectory(prefix="gaomenhu-ime-", dir=work_dir) as temporary:
        service = PortalService(Path(temporary) / "MenDao", browser_probe=lambda: ["edge"])
        service.save_site({"site": {"name": "飞书项目", "url": "https://fixture.example.test", "color": "#537CE6",
            "allowedBrowsers": ["edge"], "defaultBrowser": "edge", "accounts": [], "profiles": {}}})
        root = tk.Tk()
        panel = None
        try:
            panel = FloatingPanel(tk, root, win, service, threading.Event(), lambda: None, None, None, None, None)
            panel.set_expanded(True)
            root.update()
            panel.entry.focus_force()
            set_focus(panel.entry.winfo_id())
            root.update()
            for character in "飞书":
                send_message(panel.entry.winfo_id(), 0x0286, ord(character), 1)  # WM_IME_CHAR
            root.update()
            assert panel.entry.get() == "飞书", "The production search entry did not receive the committed IME text"
            assert any(site["name"] == "飞书项目" for site in panel.rows), "Committed text did not refresh the native search"
            return {"keyboardLayout": hex(layout(0) & 0xFFFF), "committedText": panel.entry.get(), "searchMatched": True,
                    "privateDesktop": True}
        finally:
            if panel is not None:
                panel.native.close()
            root.destroy()


def mail_smoke(work_dir):
    class PointerProbe:
        point = (0, 0)
        buttons = 0

        def __getattr__(self, name):
            return getattr(win, name)

        def pointer(self):
            return self.point

        def mouse_buttons(self):
            return self.buttons

    visible = win.bind(win.user32, "IsWindowVisible", W.BOOL, W.HWND)
    get_layered = win.bind(win.user32, "GetLayeredWindowAttributes", W.BOOL, W.HWND,
                           C.POINTER(W.DWORD), C.POINTER(W.BYTE), C.POINTER(W.DWORD))
    with tempfile.TemporaryDirectory(prefix="gaomenhu-mail-rail-", dir=work_dir) as temporary:
        service = PortalService(Path(temporary) / "MenDao", browser_probe=lambda: ["edge"])
        root = tk.Tk()
        root.withdraw()
        panel = None
        try:
            desktop = PointerProbe()
            opens, focus_observations = [], []
            panel = MailFloatingPanel(tk, root, desktop, service, SimpleQueue(), opens.append,
                                      lambda: None, lambda: "dark")
            panel.command("show")
            panel.refresh()
            root.update()
            rail = panel.frame
            focus_observations.append(win.get_foreground())
            assert visible(panel.native.window) and visible(panel.hit_window), "Expected both mapped rail surfaces"
            assert win.window_rect(panel.native.window) == win.window_rect(panel.hit_window) == rail
            desktop.point = (rail.right - 2, rail.y + rail.height // 2)
            assert win.contains_pointer(desktop.point, (panel.native.window, panel.hit_window)), "Rail did not own its hit target"
            now = time.monotonic()
            panel.evaluate_pointer(now, desktop.point, 0)
            panel.evaluate_pointer(now + 0.30, desktop.point, 0)
            root.update()
            card = panel.frame
            focus_observations.append(win.get_foreground())
            assert panel.expanded and visible(panel.native.window) and not visible(panel.hit_window)
            assert win.window_rect(panel.native.window) == card and panel.body.find_all()
            assert not win.contains_pointer((card.x, card.y), (panel.native.window,)), "Transparent card corner blocked input"
            desktop.point = (card.x - 8, card.y - 8)
            panel.evaluate_pointer(now + 0.4, desktop.point, 0)
            panel.evaluate_pointer(now + 0.47, desktop.point, 0)
            assert panel.expanded, "Mail panel collapsed before its leave grace elapsed"
            panel.evaluate_pointer(now + 0.49, desktop.point, 0)
            root.update()
            assert not panel.expanded and visible(panel.hit_window) and panel.frame == rail
            focus_observations.append(win.get_foreground())
            desktop.point = (rail.right - 2, rail.y + rail.height // 2)
            panel.press(SimpleNamespace(y=10))
            desktop.point = (panel.screen.bounds.x + rail.width, rail.y + 130)
            panel.motion(None)
            panel.release(None)
            root.update()
            assert panel.position.dock == "left" and panel.frame.x == panel.screen.bounds.x
            assert service.mail_store().library["preferences"]["floatingPlacement"]["side"] == "left"
            focus_observations.append(win.get_foreground())

            store = service.mail_store()
            store.save_account({"id": "fixture", "email": "mail@example.test"})
            store.save_preferences({"showPreviews": True, "floatingOpacity": 0.8})
            for index in range(4):
                store.messages.append({"id": f"fixture{index}", "accountID": "fixture", "folder": "INBOX",
                                       "from": "Fixture", "subject": "测试验证码 123456", "date": 300 + index, "isRead": False})
            panel.set_expanded(True)
            root.update()
            color, opacity, layers = W.DWORD(), W.BYTE(), W.DWORD()
            assert get_layered(panel.native.window, C.byref(color), C.byref(opacity), C.byref(layers))
            assert opacity.value == 204 and layers.value & 3 == 3
            assert panel.snapshot["unread"] == 4 and len(panel.snapshot["previews"]) == 3
            assert "code0" in panel.actions and not panel.actions.get("sync")
            panel.actions["message0"]()
            assert not panel.expanded and opens == ["/mail#message=fixture3"]
            assert not panel.body.find_all() and not any(message["isRead"] for message in store.messages)
            panel.command("hide")
            panel.refresh()
            root.update()
            assert not visible(panel.native.window) and not visible(panel.hit_window)
            focus_observations.append(win.get_foreground())
            assert all(hwnd not in (panel.native.window, panel.hit_window) for hwnd in focus_observations)
            dpi = panel.screen.dpi
        finally:
            if panel is not None:
                panel.close()
            root.destroy()
    return {"privateDesktop": True, "dpi": dpi,
            "rail": [rail.width, rail.height], "card": [card.width, card.height], "realHitTarget": True,
            "hoverExpanded": True, "leaveCollapsed": True, "leftDockPersisted": True, "tookForeground": False,
            "transparentCorner": True, "opacity": 0.8, "previewOpenedWithoutMarkingRead": True}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("tray", "ime", "mail"))
    parser.add_argument("work_dir", type=Path)
    command = parser.parse_args()
    probes = {"ime": ime_smoke, "mail": mail_smoke}
    result = tray_smoke() if command.mode == "tray" else run_on_private_desktop(
        probes[command.mode], command.work_dir.resolve(strict=True))
    print(json.dumps(result, ensure_ascii=False))
