"""Exercise the real Shell registration without interacting with the shared foreground."""

import argparse
import ctypes as C
import json
import tempfile
import time
import tkinter as tk
from ctypes import wintypes as W
from pathlib import Path
from unittest.mock import patch

from PIL import Image

from native_desktop_smoke import send_message, win


class IconIdentifier(C.Structure):
    _fields_ = [("size", W.DWORD), ("window", W.HWND), ("id", W.UINT), ("guid", C.c_byte * 16)]


def icon_rect(identifier):
    get_rect = win.bind(win.shell32, "Shell_NotifyIconGetRect", W.LONG, C.POINTER(IconIdentifier), C.POINTER(W.RECT))
    rect = W.RECT()
    if get_rect(C.byref(identifier), C.byref(rect)) == 0 and rect.left < rect.right and rect.top < rect.bottom:
        return [rect.left, rect.top, rect.right, rect.bottom]
    return None


def wait_for(root, condition, message):
    until = time.monotonic() + 5
    while time.monotonic() < until:
        root.update()
        if condition():
            return
        time.sleep(0.02)
    raise RuntimeError(message)


def exercise(icon_path):
    foreground = win.get_foreground()
    events = []
    root = tk.Tk(className="GaoMenHuTrayLifecycleSmoke")
    root.withdraw()
    root.overrideredirect(True)
    window = None
    try:
        with win.without_activation():
            root.update_idletasks()
        # Simulate Explorer being unavailable for this icon's first request only.
        with patch.object(win, "notify_icon", return_value=False):
            window = win.DesktopWindow(root, events.append, lambda _: False, icon_path)
            assert window.custom_icon and not window.tray_available and window.tray_retry
        wait_for(root, lambda: window.tray_available, "The initial notification icon retry did not register with Explorer")
        assert events == ["tray-state"]
        identifier = IconIdentifier(size=C.sizeof(IconIdentifier), window=window.window, id=window.icon.id)
        initial_rect = icon_rect(identifier)
        assert win.notify_icon(win.NIM_MODIFY, C.byref(window.icon))

        # Exercise the real legacy Shell callback format with our own HWND only.
        send_message(window.window, win.TRAY_MESSAGE, identifier.id, 0x0202)  # WM_LBUTTONUP
        send_message(window.window, win.TRAY_MESSAGE, identifier.id, 0x0205)  # WM_RBUTTONUP
        wait_for(root, lambda: len(events) == 3, "Explorer notification messages did not reach the handlers")
        assert events[1:] == ["open", "tray"]

        # Recreate the observable part of Explorer restart: Explorer has lost
        # this icon and the window receives the registered TaskbarCreated event.
        assert window.taskbar_message
        assert win.notify_icon(win.NIM_DELETE, C.byref(window.icon))
        assert not win.notify_icon(win.NIM_MODIFY, C.byref(window.icon))
        with patch.object(win, "notify_icon", wraps=win.notify_icon) as shell_calls:
            send_message(window.window, window.taskbar_message, 0, 0)
            send_message(window.window, window.taskbar_message, 0, 0)
            wait_for(root, lambda: bool(shell_calls.call_count), "The new taskbar notification did not add the icon")
            assert [entry.args[0] for entry in shell_calls.call_args_list] == [win.NIM_ADD]
        assert window.tray_available and win.notify_icon(win.NIM_MODIFY, C.byref(window.icon))
        restored_rect = icon_rect(identifier)

        # A DPI-triggered TaskbarCreated event can also arrive while the Shell
        # still has this icon. Its ID and availability must remain usable.
        with patch.object(win, "notify_icon", wraps=win.notify_icon) as shell_calls:
            send_message(window.window, window.taskbar_message, 0, 0)
            wait_for(root, lambda: bool(shell_calls.call_count), "The DPI re-registration did not run")
        assert window.tray_available and win.notify_icon(win.NIM_MODIFY, C.byref(window.icon))

        # Late taskbar and input events must not bring the application back.
        send_message(window.window, window.taskbar_message, 0, 0)
        send_message(window.window, win.TRAY_MESSAGE, identifier.id, 0x0202)
        with patch.object(win, "notify_icon", wraps=win.notify_icon) as shell_calls:
            window.close()
            window.close()
            root.update()
            assert [entry.args[0] for entry in shell_calls.call_args_list] == [win.NIM_DELETE]
        assert not window.tray_available and not window.tray_retry
        assert not win.notify_icon(win.NIM_MODIFY, C.byref(window.icon))
        assert icon_rect(identifier) is None
        assert events == ["tray-state", "open", "tray"]
        assert win.get_foreground() != window.window
        return {"realShell": True, "startupRetry": True, "callbacks": events[1:],
                "taskbarCreatedRestored": True, "originalIconRect": initial_rect, "restoredIconRect": restored_rect,
                "iconRemoved": True, "foregroundUnchanged": win.get_foreground() == foreground}
    finally:
        if window is not None:
            window.close()
        root.destroy()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("work_dir", type=Path)
    options = parser.parse_args()
    mark = Path(__file__).resolve().parents[2] / "Assets" / "AppIcon.png"
    with tempfile.TemporaryDirectory(prefix="gaomenhu-tray-", dir=options.work_dir.resolve(strict=True)) as work:
        icon_path = Path(work) / "GaoMenHu.ico"
        with Image.open(mark) as source:
            source.save(icon_path, sizes=[(16, 16), (32, 32)])
        print(json.dumps(exercise(icon_path)))
