"""Capture the app's own Tk windows on a private Win32 desktop."""

import argparse
import ctypes as C
import struct
import tempfile
import threading
import time
import tkinter as tk
from ctypes import wintypes as W
from pathlib import Path
from queue import SimpleQueue

from PIL import Image

from native_desktop_smoke import run_on_private_desktop, win
from gaomenhu.floating import FloatingPanel
from gaomenhu.mail_floating import MailFloatingPanel
from gaomenhu.service import PortalService


def capture_window(handle, frame, filename):
    gdi = C.WinDLL("gdi32")
    bind = win.bind
    get_dc = bind(win.user32, "GetDC", W.HDC, W.HWND)
    release_dc = bind(win.user32, "ReleaseDC", C.c_int, W.HWND, W.HDC)
    render = bind(win.user32, "PrintWindow", W.BOOL, W.HWND, W.HDC, W.UINT)
    create_dc = bind(gdi, "CreateCompatibleDC", W.HDC, W.HDC)
    create_bitmap = bind(gdi, "CreateCompatibleBitmap", W.HBITMAP, W.HDC, C.c_int, C.c_int)
    select = bind(gdi, "SelectObject", W.HANDLE, W.HDC, W.HANDLE)
    delete_bitmap = bind(gdi, "DeleteObject", W.BOOL, W.HANDLE)
    delete_dc = bind(gdi, "DeleteDC", W.BOOL, W.HDC)
    read = bind(gdi, "GetDIBits", C.c_int, W.HDC, W.HBITMAP, W.UINT, W.UINT, W.LPVOID, W.LPVOID, W.UINT)
    width, height = frame.width, frame.height
    origin_dc = get_dc(handle)
    dc = create_dc(origin_dc)
    bitmap = create_bitmap(origin_dc, width, height)
    original = select(dc, bitmap)
    try:
        assert render(handle, dc, 2), "PrintWindow failed"
        select(dc, original)
        header = C.create_string_buffer(struct.pack("<IiiHHIIiiII", 40, width, -height, 1, 32, 0, 0, 0, 0, 0, 0) + b"\0" * 4)
        channels = C.create_string_buffer(width * height * 4)
        assert read(dc, bitmap, 0, height, channels, header, 0) == height, "GetDIBits failed"
        image = Image.frombytes("RGB", (width, height), channels.raw, "raw", "BGRX")
        assert any(low < high for low, high in image.getextrema()), "Private window image was blank"
        image.save(filename)
    finally:
        select(dc, original)
        delete_bitmap(bitmap)
        delete_dc(dc)
        release_dc(handle, origin_dc)


def capture_panels(config):
    output, stage = config
    with tempfile.TemporaryDirectory(dir=output.parent, prefix="native-render-") as temporary:
        service = PortalService(Path(temporary) / "MenDao", browser_probe=lambda: ["chrome", "edge"])
        for name, domain, color, browser in (("产品协作台", "work", "#6553c2", "edge"),
            ("项目资料库", "docs", "#256a86", "chrome"), ("测试站点及较长中文名称", "qa", "#386641", "edge")):
            service.save_site({"site": {"name": name, "url": f"https://{domain}.example.test", "color": color,
                "allowedBrowsers": [browser], "defaultBrowser": browser, "accounts": [], "profiles": {}}})
        store = service.mail_store()
        store.save_account({"id": "fixture", "email": "mail@example.test", "displayName": "测试邮箱"})
        store.save_preferences({"showPreviews": True})
        now = time.time()
        for index, (sender, subject) in enumerate((("验证服务", "测试登录验证码 318492"), ("协作团队", "本周评审安排"),
                                                    ("资料归档", "项目文档已更新"))):
            store.messages.append({"id": f"fixture{index}", "accountID": "fixture", "folder": "INBOX", "from": sender,
                                   "subject": subject, "date": now - 120 * index, "isRead": False})
        root = tk.Tk()
        portal = mail = None
        try:
            portal = FloatingPanel(tk, root, win, service, threading.Event(), lambda: None, None, None, None, None)
            mail = MailFloatingPanel(tk, root, win, service, SimpleQueue(), lambda _: None, lambda: None, lambda: portal.theme)
            mail.command("show")
            for theme in ("light", "dark"):
                service.set_appearance(theme)
                store.save_preferences({"appearance": theme})
                portal.set_expanded(True)
                portal.sync()
                portal.active_row = 1
                portal.redraw()
                mail.set_expanded(True)
                mail.refresh()
                root.update()
                for name, panel in (("portal", portal), ("mail", mail)):
                    capture_window(panel.native.window, panel.frame, output / f"{stage}-{name}-{theme}.png")
                mail.set_expanded(False)
                portal.set_expanded(False)
        finally:
            if mail is not None:
                mail.close()
            if portal is not None:
                portal.native.close()
            root.destroy()
        return {"dpi": portal.screen.dpi, "screenshots": 4}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stage", choices=("before", "after"))
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    destination = args.output.resolve()
    destination.mkdir(parents=True, exist_ok=True)
    print(run_on_private_desktop(capture_panels, (destination, args.stage)))
