"""Test Windows icon frame selection without showing a window or using the real tray."""

import ctypes as C
import io
import struct
import sys
from collections import deque
from ctypes import wintypes as W
from types import SimpleNamespace

import pytest
from PIL import Image

if sys.platform != "win32":
    pytest.skip("Win32 icon APIs", allow_module_level=True)

from gaomenhu import floating_win32 as win


DPI_SIZES = ((96, 16, 32), (120, 20, 40), (144, 24, 48), (168, 28, 56), (192, 32, 64))
WM_GETICON = 0x007F


class IconInfo(C.Structure):
    _fields_ = [("icon", W.BOOL), ("x", W.DWORD), ("y", W.DWORD), ("mask", W.HBITMAP), ("color", W.HBITMAP)]


class Bitmap(C.Structure):
    _fields_ = [("type", W.LONG), ("width", W.LONG), ("height", W.LONG), ("width_bytes", W.LONG),
                ("planes", W.WORD), ("bits_pixel", W.WORD), ("bits", W.LPVOID)]


gdi = C.WinDLL("gdi32", use_last_error=True)
get_icon_info = win.bind(win.user32, "GetIconInfo", W.BOOL, W.HICON, C.POINTER(IconInfo))
get_object = win.bind(gdi, "GetObjectW", C.c_int, W.HANDLE, C.c_int, W.LPVOID)
delete_object = win.bind(gdi, "DeleteObject", W.BOOL, W.HANDLE)
create_dc = win.bind(gdi, "CreateCompatibleDC", W.HDC, W.HDC)
select_object = win.bind(gdi, "SelectObject", W.HANDLE, W.HDC, W.HANDLE)
get_pixel = win.bind(gdi, "GetPixel", W.DWORD, W.HDC, C.c_int, C.c_int)
delete_dc = win.bind(gdi, "DeleteDC", W.BOOL, W.HDC)
create_window = win.bind(win.user32, "CreateWindowExW", W.HWND, W.DWORD, W.LPCWSTR, W.LPCWSTR, W.DWORD,
                         C.c_int, C.c_int, C.c_int, C.c_int, W.HWND, W.HMENU, W.HINSTANCE, W.LPVOID)
destroy_window = win.bind(win.user32, "DestroyWindow", W.BOOL, W.HWND)


@pytest.fixture
def icon_path(tmp_path):
    frames = sorted({size for _, small, large in DPI_SIZES for size in (small, large)})
    header = struct.pack("<HHH", 0, 1, len(frames))
    offset = len(header) + 16 * len(frames)
    entries = []
    payloads = []
    for size in frames:
        png = io.BytesIO()
        Image.new("RGBA", (size, size), (size, 113, 207, 255)).save(png, format="PNG")
        data = png.getvalue()
        payloads.append(data)
        entries.append(struct.pack("<BBBBHHII", size, size, 0, 0, 1, 32, len(data), offset))
        offset += len(data)
    path = tmp_path / "多尺寸.ico"
    path.write_bytes(header + b"".join(entries) + b"".join(payloads))
    return path


def assert_frame(icon, size):
    assert icon
    info = IconInfo()
    assert get_icon_info(icon, C.byref(info))
    try:
        bitmap = Bitmap()
        assert get_object(info.color, C.sizeof(bitmap), C.byref(bitmap)) == C.sizeof(bitmap)
        assert (bitmap.width, bitmap.height) == (size, size)
        dc = create_dc(None)
        assert dc
        try:
            previous = select_object(dc, info.color)
            try:
                # Each source frame is a different solid color. This verifies
                # selection of the matching ICO frame even if a rescaled frame
                # would have had the same output dimensions.
                assert get_pixel(dc, 0, 0) == size | (113 << 8) | (207 << 16)
            finally:
                select_object(dc, previous)
        finally:
            delete_dc(dc)
    finally:
        delete_object(info.color)
        delete_object(info.mask)


@pytest.mark.parametrize("dpi,small,large", DPI_SIZES)
def test_win32_loads_exact_window_and_notification_frames(icon_path, dpi, small, large):
    for compact, expected in ((True, small), (False, large)):
        size = win.icon_size(dpi, small=compact)
        assert size == (expected, expected)
        icon = win.load_icon_file(icon_path, size)
        try:
            assert_frame(icon, expected)
        finally:
            if icon:
                win.destroy_icon(icon)


def test_hidden_hwnd_replaces_both_icons_on_dpi_change_and_releases_on_destroy(icon_path):
    hwnd = create_window(0, "STATIC", None, 0x80000000, 0, 0, 100, 100, None, None, None, None)
    assert hwnd
    icons = win.WindowIcons(icon_path)
    try:
        icons.attach(hwnd)
        assert icons.window == hwnd
        bounds = W.RECT(10, 10, 110, 110)
        for dpi, small, large in DPI_SIZES:
            win.send_message(hwnd, win.WM_DPICHANGED, dpi | (dpi << 16), C.addressof(bounds))
            assert_frame(win.send_message(hwnd, WM_GETICON, win.ICON_SMALL, dpi), small)
            assert_frame(win.send_message(hwnd, WM_GETICON, win.ICON_BIG, dpi), large)
    finally:
        assert destroy_window(hwnd)
    assert icons.window is None and not icons.handles


def test_explorer_refresh_reloads_small_icon_and_keeps_existing_id(icon_path, monkeypatch):
    tray = win.DesktopWindow.__new__(win.DesktopWindow)
    tray.window, tray.taskbar_message, tray.closed = 1, 0xC007, False
    tray.icon = win.NotifyIcon(size=C.sizeof(win.NotifyIcon), window=tray.window, id=1, flags=7, tip="搞门户")
    tray.icon_path, tray.custom_icon, tray.tray_size = icon_path, None, None
    tray.tray_available = tray.tray_refresh_requested = False
    calls, delays = [], []
    tray.event = lambda _event: None
    tray.events = deque()
    tray.root = SimpleNamespace(after=lambda *_: None)
    tray._schedule_tray_refresh = delays.append
    size, accepted = 16, True

    def notify(action, value):
        info = C.cast(value, C.POINTER(win.NotifyIcon)).contents
        calls.append((action, info.window, info.id, info.icon))
        return accepted and action == win.NIM_MODIFY

    monkeypatch.setattr(win, "tray_icon_size", lambda: (size, size))
    monkeypatch.setattr(win, "notify_icon", notify)
    try:
        tray._refresh_tray()
        previous = tray.custom_icon
        assert_frame(previous, 16)
        assert tray.tray_available

        size, accepted = 28, False
        assert tray.dispatch(tray.window, tray.taskbar_message, 0, 0) == 0
        tray._deliver_events()
        assert delays == [0]
        tray._refresh_tray()
        assert delays == [0, win.TRAY_RETRY_MILLISECONDS]
        assert not tray.tray_available and tray.icon.icon == previous
        assert_frame(previous, 16)

        accepted = True
        tray._refresh_tray()
        assert_frame(tray.custom_icon, 28)
        assert tray.tray_available and tray.custom_icon != previous
        assert all(window == tray.window and icon_id == 1 for _, window, icon_id, _ in calls)
        assert [action for action, *_ in calls] == [win.NIM_ADD, win.NIM_MODIFY] * 3
    finally:
        if tray.custom_icon:
            win.destroy_icon(tray.custom_icon)
