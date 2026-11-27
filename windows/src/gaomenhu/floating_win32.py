"""Windows desktop and shell APIs used by the floating window."""

import ctypes as C
import logging
from collections import deque
from contextlib import contextmanager
from ctypes import wintypes as W

from .floating_geometry import Rect, Screen

user32 = C.WinDLL("user32", use_last_error=True)
shell32 = C.WinDLL("shell32", use_last_error=True)
shcore = C.WinDLL("shcore", use_last_error=True)
imm32 = C.WinDLL("imm32", use_last_error=True)
wtsapi32 = C.WinDLL("wtsapi32", use_last_error=True)
kernel32 = C.WinDLL("kernel32", use_last_error=True)

LRESULT = C.c_ssize_t
WNDPROC = C.WINFUNCTYPE(LRESULT, W.HWND, W.UINT, W.WPARAM, W.LPARAM)
MONITORPROC = C.WINFUNCTYPE(W.BOOL, W.HANDLE, W.HDC, C.POINTER(W.RECT), W.LPARAM)
HOOKPROC = C.WINFUNCTYPE(LRESULT, C.c_int, W.WPARAM, W.LPARAM)


class MonitorInfo(C.Structure):
    _fields_ = [("size", W.DWORD), ("monitor", W.RECT), ("work", W.RECT),
                ("flags", W.DWORD), ("device", W.WCHAR * 32)]


class NotifyIcon(C.Structure):
    _fields_ = [("size", W.DWORD), ("window", W.HWND), ("id", W.UINT), ("flags", W.UINT),
                ("message", W.UINT), ("icon", W.HICON), ("tip", W.WCHAR * 128),
                ("state", W.DWORD), ("mask", W.DWORD), ("info", W.WCHAR * 256),
                ("version", W.UINT), ("title", W.WCHAR * 64), ("info_flags", W.DWORD),
                ("guid", C.c_byte * 16), ("balloon_icon", W.HICON)]


def bind(dll, name, result, *args):
    function = getattr(dll, name)
    function.restype = result
    function.argtypes = args
    return function


set_process_dpi = bind(user32, "SetProcessDpiAwarenessContext", W.BOOL, W.HANDLE)
set_thread_dpi = bind(user32, "SetThreadDpiAwarenessContext", W.HANDLE, W.HANDLE)
enum_monitors = bind(user32, "EnumDisplayMonitors", W.BOOL, W.HDC, C.POINTER(W.RECT), MONITORPROC, W.LPARAM)
monitor_info = bind(user32, "GetMonitorInfoW", W.BOOL, W.HANDLE, C.POINTER(MonitorInfo))
monitor_scale = bind(shcore, "GetScaleFactorForMonitor", W.LONG, W.HANDLE, C.POINTER(C.c_int))
get_cursor_pos = bind(user32, "GetCursorPos", W.BOOL, C.POINTER(W.POINT))
get_async_key_state = bind(user32, "GetAsyncKeyState", W.SHORT, C.c_int)
get_system_metrics = bind(user32, "GetSystemMetrics", C.c_int, C.c_int)
get_ancestor = bind(user32, "GetAncestor", W.HWND, W.HWND, W.UINT)
get_window_long = bind(user32, "GetWindowLongPtrW", LRESULT, W.HWND, C.c_int)
get_window_rect = bind(user32, "GetWindowRect", W.BOOL, W.HWND, C.POINTER(W.RECT))
set_window_long = bind(user32, "SetWindowLongPtrW", LRESULT, W.HWND, C.c_int, LRESULT)
call_window = bind(user32, "CallWindowProcW", LRESULT, LRESULT, W.HWND, W.UINT, W.WPARAM, W.LPARAM)
set_window_pos = bind(user32, "SetWindowPos", W.BOOL, W.HWND, W.HWND, C.c_int, C.c_int, C.c_int, C.c_int, W.UINT)
set_layered_attributes = bind(user32, "SetLayeredWindowAttributes", W.BOOL, W.HWND, W.DWORD, W.BYTE, W.DWORD)
set_foreground = bind(user32, "SetForegroundWindow", W.BOOL, W.HWND)
get_foreground = bind(user32, "GetForegroundWindow", W.HWND)
get_focus = bind(user32, "GetFocus", W.HWND)
window_from_point = bind(user32, "WindowFromPoint", W.HWND, W.POINT)
post_message = bind(user32, "PostMessageW", W.BOOL, W.HWND, W.UINT, W.WPARAM, W.LPARAM)
register_message = bind(user32, "RegisterWindowMessageW", W.UINT, W.LPCWSTR)
create_menu = bind(user32, "CreatePopupMenu", W.HMENU)
append_menu = bind(user32, "AppendMenuW", W.BOOL, W.HMENU, W.UINT, C.c_size_t, W.LPCWSTR)
track_menu = bind(user32, "TrackPopupMenu", W.UINT, W.HMENU, W.UINT, C.c_int, C.c_int, C.c_int, W.HWND, W.LPVOID)
destroy_menu = bind(user32, "DestroyMenu", W.BOOL, W.HMENU)
load_image = bind(user32, "LoadImageW", W.HANDLE, W.HINSTANCE, W.LPCWSTR, W.UINT, C.c_int, C.c_int, W.UINT)
load_icon = bind(user32, "LoadIconW", W.HICON, W.HINSTANCE, C.c_void_p)
destroy_icon = bind(user32, "DestroyIcon", W.BOOL, W.HICON)
notify_icon = bind(shell32, "Shell_NotifyIconW", W.BOOL, W.DWORD, C.POINTER(NotifyIcon))
ime_context = bind(imm32, "ImmGetContext", W.HANDLE, W.HWND)
ime_release = bind(imm32, "ImmReleaseContext", W.BOOL, W.HWND, W.HANDLE)
ime_string = bind(imm32, "ImmGetCompositionStringW", W.LONG, W.HANDLE, W.DWORD, W.LPVOID, W.DWORD)
register_session = bind(wtsapi32, "WTSRegisterSessionNotification", W.BOOL, W.HWND, W.DWORD)
unregister_session = bind(wtsapi32, "WTSUnRegisterSessionNotification", W.BOOL, W.HWND)
current_thread_id = bind(kernel32, "GetCurrentThreadId", W.DWORD)
set_thread_hook = bind(user32, "SetWindowsHookExW", W.HANDLE, C.c_int, HOOKPROC, W.HMODULE, W.DWORD)
remove_thread_hook = bind(user32, "UnhookWindowsHookEx", W.BOOL, W.HANDLE)
call_thread_hook = bind(user32, "CallNextHookEx", LRESULT, W.HANDLE, C.c_int, W.WPARAM, W.LPARAM)

LOG = logging.getLogger(__name__)
NO_ACTIVATE = 0x08000000
LAYERED = 0x00080000
TOOL_WINDOW = 0x00000080
APP_WINDOW = 0x00040000
TRAY_MESSAGE = 0x8050
NIM_ADD = 0
NIM_MODIFY = 1
NIM_DELETE = 2
TRAY_RETRY_MILLISECONDS = 1000


def enable_per_monitor_dpi():
    for context in (-4, -3):
        if set_process_dpi(context):
            return


def enable_thread_dpi():
    return set_thread_dpi(-4) or set_thread_dpi(-3)


@contextmanager
def without_activation():
    # Older Tk versions explicitly activate the first wrapper even when it
    # was withdrawn. This short-lived hook applies only to the Tk worker.
    previous = get_foreground()

    @HOOKPROC
    def skip_activation(code, wparam, lparam):
        if code in (5, 9):  # HCBT_ACTIVATE / HCBT_SETFOCUS
            return 1
        return call_thread_hook(None, code, wparam, lparam)

    hook = set_thread_hook(5, skip_activation, None, current_thread_id())  # WH_CBT
    try:
        yield
    finally:
        if hook:
            remove_thread_hook(hook)
        if previous and not get_foreground():
            set_foreground(previous)


def show_nonactivating(widget):
    if widget.state() == "withdrawn":
        with without_activation():
            widget.deiconify()


def monitors():
    screens = []

    def rectangle(rect):
        return Rect(rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top)

    @MONITORPROC
    def visit(monitor, device_context, rect, context):
        info = MonitorInfo(size=C.sizeof(MonitorInfo))
        if monitor_info(monitor, C.byref(info)):
            percent = C.c_int(100)
            monitor_scale(monitor, C.byref(percent))
            screen = Screen(info.device, rectangle(info.monitor), rectangle(info.work), round(96 * percent.value / 100))
            if info.flags & 1:
                screens.insert(0, screen)
            else:
                screens.append(screen)
        return True

    enum_monitors(None, None, visit, 0)
    return screens or [Screen("primary", Rect(0, 0, 1024, 768), Rect(0, 0, 1024, 768))]


def pointer():
    point = W.POINT()
    get_cursor_pos(C.byref(point))
    return point.x, point.y


def mouse_buttons():
    swapped = bool(get_system_metrics(23))
    keys = [0x02, 0x01, 0x04, 0x05, 0x06] if swapped else [0x01, 0x02, 0x04, 0x05, 0x06]
    return sum(1 << index for index, key in enumerate(keys) if get_async_key_state(key) & 0x8000)


def contains_pointer(point, windows):
    hovered = window_from_point(W.POINT(*point))
    return bool(hovered and get_ancestor(hovered, 2) in windows)


def window_rect(window):
    rect = W.RECT()
    if not get_window_rect(window, C.byref(rect)):
        raise C.WinError(C.get_last_error())
    return Rect(rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top)


def is_composing(window):
    focused = get_focus()
    if not focused or get_ancestor(focused, 2) != window or get_foreground() != window:
        return False
    context = ime_context(focused)
    if not context:
        return False
    try:
        return ime_string(context, 0x0008, None, 0) > 0
    finally:
        ime_release(focused, context)


class DesktopWindow:
    def __init__(self, root, event, allows_activation, icon_path=None, *, tray=True):
        self.root = root
        self.window = prepare_window(root)
        self.event = event
        self.allows_activation = allows_activation
        self.taskbar_message = register_message("TaskbarCreated") if tray else 0
        self.tray_available = False
        self.tray_retry = None
        self.tray_refresh_requested = False
        self.closed = False
        self.events = deque()
        self.procedure = WNDPROC(self.dispatch)
        self.original = set_window_long(self.window, -4, C.cast(self.procedure, C.c_void_p).value)
        if not self.original:
            raise OSError(C.get_last_error(), "Unable to subclass the floating window")
        self.custom_icon = load_image(None, str(icon_path), 1, 0, 0, 0x0010 | 0x0040) if tray and icon_path else None
        self.icon = NotifyIcon(size=C.sizeof(NotifyIcon), window=self.window, id=1, flags=7,
                               message=TRAY_MESSAGE, icon=self.custom_icon or load_icon(None, 32512), tip="搞门户") if tray else None
        self.session_registered = bool(register_session(self.window, 0))
        if self.icon is not None:
            self._refresh_tray(announce=False)
        self.event_poll = self.root.after_idle(self._deliver_events)

    def _schedule_tray_refresh(self, delay):
        if self.tray_retry is not None:
            self.root.after_cancel(self.tray_retry)
        self.tray_retry = self.root.after(delay, self._refresh_tray)

    def _refresh_tray(self, *, announce=True):
        self.tray_retry = None
        if self.closed:
            return
        data = C.byref(self.icon)
        # Windows also sends TaskbarCreated after a DPI change. Update this
        # HWND and icon ID if Explorer has already kept the original icon.
        available = bool(notify_icon(NIM_ADD, data) or notify_icon(NIM_MODIFY, data))
        changed = available != self.tray_available
        self.tray_available = available
        if not available:
            self._schedule_tray_refresh(TRAY_RETRY_MILLISECONDS)
        if announce and changed:
            self.event("tray-state")

    def _deliver_events(self):
        self.event_poll = None
        try:
            if self.tray_refresh_requested:
                self.tray_refresh_requested = False
                self._schedule_tray_refresh(0)
            while self.events and not self.closed:
                event = self.events.popleft()
                if event not in ("open", "tray") or self.tray_available:
                    self.event(event)
        finally:
            if not self.closed:
                self.event_poll = self.root.after(25, self._deliver_events)

    def dispatch(self, window, message, wparam, lparam):
        # The HWND callback can reenter Tk's native message loop. Queue work
        # here and call Tcl only from a callback scheduled by Tk itself.
        try:
            if message == 0x0021:  # WM_MOUSEACTIVATE
                return 1 if self.allows_activation(pointer()) else 3
            if message == TRAY_MESSAGE and not self.closed and self.tray_available:
                if lparam == 0x0202:  # WM_LBUTTONUP
                    self.events.append("open")
                if lparam == 0x0205:  # WM_RBUTTONUP
                    self.events.append("tray")
                return 0
            if self.taskbar_message and message == self.taskbar_message and not self.closed:
                # Let Explorer finish the broadcast before calling the Shell back.
                self.tray_refresh_requested = True
                return 0
            if message == 0x02B1 and wparam == 7:  # WM_WTSSESSION_CHANGE / WTS_SESSION_LOCK
                self.events.append("session-lock")
            if message in (0x007E, 0x001A, 0x02E0):  # display, settings or DPI change
                self.events.append("display")
        except Exception:
            LOG.exception("Floating window message failed")
        return call_window(self.original, window, message, wparam, lparam)

    def place(self, frame, *, topmost=True):
        place_window(self.window, frame, topmost=topmost)

    def focus(self):
        set_foreground(self.window)

    def composing(self):
        return is_composing(self.window)

    def menu(self, items, point):
        menu = create_menu()
        if not menu:
            return None
        try:
            for index, (label, action, checked) in enumerate(items, start=1):
                flags = 0x0800 if label is None else (0x0008 if checked else 0) | (0x0001 if action is None else 0)
                append_menu(menu, flags, index, label)
            # 0x0182: TPM_RETURNCMD, TPM_NONOTIFY and TPM_RIGHTBUTTON.
            self.focus()
            selected = track_menu(menu, 0x0182, *point, 0, self.window, None)
            post_message(self.window, 0, 0, 0)
            return items[selected - 1][1] if 0 < selected <= len(items) else None
        finally:
            destroy_menu(menu)

    def close(self):
        if self.closed:
            return
        self.closed = True
        if self.event_poll is not None:
            self.root.after_cancel(self.event_poll)
            self.event_poll = None
        self.events.clear()
        if self.tray_retry is not None:
            self.root.after_cancel(self.tray_retry)
            self.tray_retry = None
        if self.session_registered:
            unregister_session(self.window)
        if self.icon is not None:
            notify_icon(NIM_DELETE, C.byref(self.icon))
        self.tray_available = False
        if self.custom_icon:
            destroy_icon(self.custom_icon)
        set_window_long(self.window, -4, self.original)


def prepare_window(widget):
    handle = get_ancestor(widget.winfo_id(), 2)
    styles = get_window_long(handle, -20)
    set_window_long(handle, -20, (styles | NO_ACTIVATE | TOOL_WINDOW) & ~APP_WINDOW)
    return handle


def configure_transparency(handle, *, opacity=1, color_key=None):
    styles = get_window_long(handle, -20)
    set_window_long(handle, -20, styles | LAYERED)
    color = int.from_bytes(bytes.fromhex(color_key[1:]), "little") if color_key else 0
    flags = 0x0002 | (0x0001 if color_key else 0)
    if not set_layered_attributes(handle, color, round(255 * opacity), flags):
        raise C.WinError(C.get_last_error())


def place_window(handle, frame, *, topmost=True):
    # HWND_TOPMOST or HWND_NOTOPMOST, SWP_NOACTIVATE
    set_window_pos(handle, -1 if topmost else -2, frame.x, frame.y, frame.width, frame.height, 0x0010)
