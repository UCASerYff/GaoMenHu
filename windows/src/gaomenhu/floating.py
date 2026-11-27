"""Native, nonactivating Windows companion to the main website launcher."""

import base64
import binascii
import gc
import logging
import os
import queue
import threading
import time
from io import BytesIO
from math import hypot

from .errors import AppError
from .floating_geometry import (LAUNCHER_EMPTY_HEIGHT, LAUNCHER_FOOTER, LAUNCHER_LIST_TOP, LAUNCHER_ROW_HEIGHT,
                                LAUNCHER_ROW_STEP, PointerTiming, Rect, panel_frame, panel_size, restore_anchor,
                                save_anchor, screen_at, snap_frame, visible_rows)
from .models import BROWSERS, visible_site_ids
from .native_theme import PALETTE, font_family

HINT = "↑ ↓ 选择 · Enter 打开 · 右键选浏览器"
PLACEHOLDER = "搜索网站、拼音或网址"
TRANSPARENT = "#00ff01"
NAMES = {browser["id"]: browser["name"] for browser in BROWSERS}
LAUNCH_FIELDS = ("name", "url", "allowedBrowsers", "defaultBrowser", "profiles", "accounts", "defaultAccount")
LOG = logging.getLogger(__name__)


def enable_per_monitor_dpi():
    if os.name == "nt":
        from .floating_win32 import enable_per_monitor_dpi as enable
        enable()


def run_floating(service, open_main, stop_event, open_downloads=None, open_mail=None, *,
                 quit_app=None, icon_path=None, on_tray_state=None, on_session_lock=None,
                 mail_commands=None, open_center=None):
    if os.name != "nt":
        return
    import tkinter as tk

    from . import floating_win32 as desktop
    from .mail_floating import MailFloatingPanel

    desktop.enable_thread_dpi()
    root = tk.Tk(className="GaoMenHuFloating")
    panel = mail_panel = None
    try:
        panel = FloatingPanel(tk, root, desktop, service, stop_event, open_main, open_downloads, open_mail, quit_app,
                              icon_path, on_tray_state, on_session_lock)
        try:
            if mail_commands is not None and open_center is not None:
                def neighboring_rail():
                    return panel_frame(panel.screen, panel.anchor, panel.dock, False, 0) if panel.enabled else None

                try:
                    mail_panel = MailFloatingPanel(tk, root, desktop, service, mail_commands, open_center,
                                                   neighboring_rail, system_appearance)
                except (OSError, tk.TclError):
                    LOG.exception("Could not initialize the mail floating panel")
                else:
                    panel.mail_panel = mail_panel
            root.mainloop()
        finally:
            try:
                if mail_panel is not None:
                    mail_panel.close()
            finally:
                panel.native.close()
    finally:
        root.destroy()
        # Release Tk callback cycles on this thread before WinForms or process teardown.
        panel = mail_panel = root = None
        gc.collect()


def system_appearance():
    import winreg

    try:
        path = r"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, path) as key:
            return "light" if winreg.QueryValueEx(key, "AppsUseLightTheme")[0] else "dark"
    except OSError:
        return "light"


def launch_floating_site(service, site, browser, *, authorize=False):
    with service.library_lock:
        service._writable()
        if site["id"] not in visible_site_ids(service.store.library["tiles"]):
            raise AppError("这个网站已从启动台移除。")
        if authorize:
            current = service._site(site["id"])
            if any(current.get(field) != site.get(field) for field in LAUNCH_FIELDS):
                raise AppError("网站配置已变化，请重新确认后打开。")
            service.vault.unlock(service.clock())
        service.launch_site(site["id"], browser)


class FloatingPanel:
    def __init__(self, tk, root, desktop, service, stop, open_main, open_downloads, open_mail, quit_app,
                 icon_path, on_tray_state=None, on_session_lock=None):
        self.tk, self.root, self.desktop, self.service = tk, root, desktop, service
        self.stop, self.open_main, self.quit_app = stop, open_main, quit_app
        self.open_downloads, self.open_mail = open_downloads, open_mail
        self.mail_panel = None
        self.on_tray_state = on_tray_state
        self.on_session_lock = on_session_lock
        self.enabled = self.expanded = self.launching = self.menu_open = False
        self.press_inside = self.scroll_drag = False
        self.status = HINT
        self.rows = []
        self.scroll = self.buttons = 0
        self.active_row = self.hover_row = None
        self.drag = None
        self.image_cache = {}
        self.timing = PointerTiming()
        self.completions = queue.SimpleQueue()
        self.last_settings = None
        self.sources = None
        self.theme = "light"
        self.font_family = font_family(root)
        self.sync_time = 0
        self.tray_download_sync_time = 0
        self.tray_download_summary = ""
        self.search_hit = self.clear_hit = self.scroll_hit = Rect(0, 0, 0, 0)
        self.last_layout = None
        self.placeholder = True

        root.withdraw()
        root.title("搞门户 · 悬浮窗")
        root.overrideredirect(True)
        self.canvas = tk.Canvas(root, bg=TRANSPARENT, borderwidth=0, highlightthickness=0)
        self.canvas.pack(fill="both", expand=True)
        # The colored strip has a separate, nearly invisible hit target. A Win32
        # color-keyed window passes clicks through its fully transparent pixels.
        self.hit = tk.Toplevel(root)
        self.hit.withdraw()
        self.hit.title("展开搞门户悬浮窗")
        self.hit.overrideredirect(True)
        self.hit.configure(bg="#333333")
        self.query = tk.StringVar(root, value=PLACEHOLDER)
        self.entry = tk.Entry(self.canvas, textvariable=self.query, borderwidth=0, highlightthickness=0)
        self.open_button = tk.Button(self.canvas, text="打开启动台", relief="flat", borderwidth=0,
                                     command=self.show_main, takefocus=True, padx=0, pady=0)
        self.entry_item = self.canvas.create_window(0, 0, anchor="w", window=self.entry, state="hidden")
        self.button_item = self.canvas.create_window(0, 0, window=self.open_button, state="hidden")
        self.query.trace_add("write", self.query_changed)
        self.entry.bind("<FocusIn>", self.search_focused)
        self.entry.bind("<FocusOut>", self.search_blurred)
        self.entry.bind("<Button-1>", self.focus_search, add=True)
        self.open_button.bind("<Return>", lambda event: self.show_main())
        self.open_button.bind("<FocusIn>", self.redraw)
        self.open_button.bind("<FocusOut>", self.redraw)
        self.root.bind("<Escape>", lambda event: self.set_expanded(False))
        self.root.bind("<Control-Alt-KeyPress-p>", lambda event: self.dispatch("toggle"))
        self.entry.bind("<Return>", self.open_selected)
        for key, delta in (("Up", -1), ("Down", 1), ("Prior", -8), ("Next", 8)):
            self.entry.bind(f"<{key}>", lambda event, step=delta: self.move_selection(step))
        self.root.bind("<MouseWheel>", self.wheel)
        for target in (self.hit, self.canvas):
            target.bind("<ButtonPress-1>", self.press)
            target.bind("<ButtonRelease-1>", self.release)
            target.bind("<B1-Motion>", self.motion)
        self.canvas.bind("<ButtonRelease-3>", self.context_menu)

        with desktop.without_activation():
            root.update_idletasks()
        self.native = desktop.DesktopWindow(root, self.dispatch, self.allows_activation, icon_path)
        self.hit_window = desktop.prepare_window(self.hit)
        desktop.configure_transparency(self.native.window, color_key=TRANSPARENT)
        desktop.configure_transparency(self.hit_window, opacity=0.012)
        self.screens = desktop.monitors()
        self.screen, self.anchor = restore_anchor(self.screens, None)
        self.frame = panel_frame(self.screen, self.anchor, "right", False, 0)
        self.dock = "right"
        self.sync()
        self.dispatch("tray-state")
        root.after(25, self.poll)

    def dispatch(self, event):
        if event == "open":
            self.show_main()
        elif event == "tray-state" and self.on_tray_state:
            self.on_tray_state(self.native.tray_available, self.native.window)
        elif event == "session-lock":
            if self.on_session_lock:
                self.on_session_lock()
            self.set_expanded(False)
        elif event == "toggle":
            self.service.set_floating({"enabled": not self.enabled})
            self.sync()
        elif event == "display" and self.drag is None:
            screens = self.desktop.monitors()
            if screens != self.screens:
                self.screens = screens
                self.last_settings = None
                self.sync()
        elif event == "tray":
            self.sync_tray_download()
            download_label = "下载中心…"
            if self.tray_download_summary:
                download_label += " · " + self.tray_download_summary
            items = [
                ("打开搞门户", self.show_main, False),
                (download_label, self.open_downloads, False),
                ("邮件中心…", self.open_mail, False),
            ]
            if self.mail_panel is not None:
                items.append(("显示或隐藏邮件悬浮窗", lambda: self.mail_panel.command("toggle"), self.mail_panel.enabled))
            items.extend([
                (None, None, False),
                ("显示或隐藏悬浮窗", lambda: self.dispatch("toggle"), self.enabled),
                ("重置悬浮窗位置", self.reset, False),
            ])
            if self.quit_app:
                items.extend([(None, None, False), ("退出搞门户", self.quit_app, False)])
            self.show_menu(items, self.desktop.pointer())

    def reset(self):
        self.service.set_floating({"reset": True})
        self.sync()

    def show_main(self):
        self.set_expanded(False)
        self.open_main()

    def show_menu(self, items, point):
        self.menu_open = True
        try:
            action = self.native.menu(items, point)
            if action:
                action()
        finally:
            self.menu_open = False
            self.timing.left = None

    def allows_activation(self, point):
        local = point[0] - self.frame.x, point[1] - self.frame.y
        return self.enabled and self.expanded and self.search_hit.contains(local)

    def focus_search(self, event=None):
        self.native.focus()
        self.entry.focus_set()

    def search_focused(self, event):
        if self.placeholder:
            self.placeholder = False
            self.query.set("")
        self.redraw()

    def search_blurred(self, event):
        if not self.query.get():
            self.placeholder = True
            self.query.set(PLACEHOLDER)
        self.redraw()

    def poll(self):
        if self.stop.is_set():
            self.root.quit()
            return
        now = time.monotonic()
        if now >= self.sync_time:
            self.sync()
            self.sync_time = now + 0.3
        if now >= self.tray_download_sync_time:
            self.sync_tray_download()
            self.tray_download_sync_time = now + 1
        self.finish_launch()
        delay = 100
        if self.enabled and not self.menu_open:
            point = self.desktop.pointer()
            buttons = self.desktop.mouse_buttons()
            if self.drag:
                if buttons & 1:
                    self.move_drag(point)
                else:
                    self.end_drag()
            if not buttons:
                self.press_inside = self.scroll_drag = False
            inside = self.frame.contains(point)
            if inside or self.expanded or self.drag:
                delay = 25
            pressed = bool(buttons & ~self.buttons)
            if pressed and inside:
                self.press_inside = True
            protected = bool(self.drag or self.launching or self.press_inside or self.native.composing())
            transition = self.timing.tick(now, expanded=self.expanded, inside=inside, buttons=buttons,
                                          outside_press=pressed and not inside, protected=protected)
            self.buttons = buttons
            if transition is not None:
                self.set_expanded(transition)
            if self.expanded and not self.drag and not buttons:
                hover = self.row_at(point[0] - self.frame.x, point[1] - self.frame.y) if inside else None
                if hover != self.hover_row:
                    self.hover_row = hover
                    self.redraw()
        self.root.after(delay, self.poll)

    def sync_tray_download(self):
        manager = self.service.downloads
        progress = manager.tray_progress() if manager is not None else (0, None)
        if progress is None:
            return
        count, percent = progress
        summary = f"{count} 项下载进行中" if count else ""
        if percent is not None:
            summary += f" · 已传输 {percent}%"
        if summary != self.tray_download_summary:
            self.tray_download_summary = summary
            self.native.set_tray_tip(f"搞门户 · {summary}" if summary else "搞门户")

    def sync(self):
        settings = self.service.floating_preferences()
        if self.drag and not settings["enabled"]:
            self.end_drag()
            settings = self.service.floating_preferences()
        if settings != self.last_settings and not self.drag:
            self.last_settings = settings
            self.dock = settings["dock"]
            self.screen, self.anchor = restore_anchor(self.screens, settings["anchor"])
            previously_enabled = self.enabled
            self.enabled = settings["enabled"]
            if self.enabled and not previously_enabled:
                self.timing = PointerTiming()
            self.update_frame()
            if not self.enabled and previously_enabled:
                self.set_expanded(False)
                self.root.withdraw()
                self.hit.withdraw()
        library = self.service.store.library
        theme = (library or {}).get("appearance", "system")
        if theme not in PALETTE:
            theme = system_appearance()
        if theme != self.theme:
            self.theme = theme
            self.redraw()
        if self.expanded and not self.drag:
            self.refresh_rows()

    def refresh_rows(self):
        library, usage = self.service.store.library, self.service.usage
        query = "" if self.placeholder else self.query.get()
        if self.sources and self.sources[0] is library and self.sources[1] is usage and self.sources[2] == query:
            return
        self.sources = library, usage, query
        matches = self.service.floating_sites(query)
        if matches != self.rows:
            self.rows = matches
            self.image_cache.clear()
            self.scroll = min(self.scroll, max(0, len(matches) - self.visible_rows()))
            self.active_row = self.hover_row = None
            self.update_frame()

    def set_expanded(self, expanded):
        if expanded == self.expanded:
            return
        self.expanded = expanded
        self.timing.transition(expanded, time.monotonic())
        self.scroll = 0
        self.active_row = self.hover_row = None
        if expanded:
            self.sources = None
            self.sync()
        else:
            self.canvas.focus_set()
            self.placeholder = True
            self.query.set(PLACEHOLDER)
            self.status = HINT
        self.update_frame()

    def update_frame(self):
        self.frame = panel_frame(self.screen, self.anchor, self.dock, self.expanded, len(self.rows))
        self.place()

    def place(self):
        frame = self.frame
        layout = (frame.width, frame.height, self.screen.dpi, self.dock)
        if layout != self.last_layout:
            self.root.geometry(f"{frame.width}x{frame.height}")
            if not self.expanded:
                self.hit.geometry(f"{frame.width}x{frame.height}")
            self.last_layout = layout
            self.image_cache.clear()
        self.redraw()
        if self.enabled:
            if not self.expanded:
                self.desktop.place_window(self.hit_window, frame)
                if self.hit.state() == "withdrawn":
                    self.desktop.show_nonactivating(self.hit)
                    self.desktop.place_window(self.hit_window, frame)
            elif self.hit.state() != "withdrawn":
                self.hit.withdraw()
            # Establish its real position before mapping to avoid flashing in the corner.
            self.native.place(frame)
            if self.root.state() == "withdrawn":
                self.desktop.show_nonactivating(self.root)
            self.native.place(frame)

    def query_changed(self, *args):
        if self.expanded and not self.drag:
            self.scroll = 0
            self.refresh_rows()
            self.redraw()

    def press(self, event):
        if self.launching:
            return
        self.press_inside = True
        point = self.desktop.pointer()
        row = self.row_at(event.x, event.y)
        if row is not None:
            self.active_row = row
            self.redraw()
        elif self.scroll_hit.contains((event.x, event.y)):
            self.scroll_drag = True
            self.scroll_to(event.y)
        elif self.clear_hit.contains((event.x, event.y)):
            self.focus_search()
            self.query.set("")
        elif self.expanded and self.search_hit.contains((event.x, event.y)):
            self.focus_search()
        else:
            self.drag = (point, self.frame, self.screen, False)

    def motion(self, event):
        if self.drag:
            self.move_drag(self.desktop.pointer())
        elif self.scroll_drag:
            self.scroll_to(event.y)

    def release(self, event):
        self.press_inside = False
        if self.drag:
            self.end_drag()
        elif self.scroll_drag:
            self.scroll_drag = False
        elif self.expanded and self.active_row is not None and self.row_at(event.x, event.y) == self.active_row:
            self.launch(self.rows[self.active_row])

    def move_drag(self, point):
        start, origin, initial_screen, moved = self.drag
        dx, dy = point[0] - start[0], point[1] - start[1]
        if not moved and hypot(dx, dy) <= initial_screen.px(3 if self.expanded else 4):
            return
        target = screen_at(self.screens, point)
        expected_w, expected_h = panel_size(target, self.expanded, len(self.rows))
        ratio = target.dpi / initial_screen.dpi
        x = point[0] - round((start[0] - origin.x) * ratio)
        y = point[1] - round((start[1] - origin.y) * ratio)
        frame, dock = snap_frame(target, Rect(x, y, expected_w, expected_h))
        self.drag = start, origin, initial_screen, True
        if (frame, dock, target) != (self.frame, self.dock, self.screen):
            self.frame, self.dock, self.screen = frame, dock, target
            self.place()

    def end_drag(self):
        _, _, _, moved = self.drag
        self.drag = None
        if not moved:
            if not self.expanded:
                self.set_expanded(True)
            return
        saved = save_anchor(self.screen, self.frame, self.dock)
        self.last_settings = self.service.set_floating({"dock": self.dock}, anchor=saved)
        self.screen, self.anchor = restore_anchor(self.screens, saved)
        self.timing.transition(False, time.monotonic())
        if self.expanded:
            self.refresh_rows()

    def visible_rows(self):
        return visible_rows(self.screen, self.frame.height)

    def row_at(self, x, y):
        if not self.expanded or self.launching or not self.rows or self.scroll_hit.contains((x, y)):
            return None
        left = self.screen.px(12)
        if not left <= x < self.frame.width - left or y < self.screen.px(LAUNCHER_LIST_TOP):
            return None
        for row in range(min(self.visible_rows(), len(self.rows) - self.scroll)):
            start = self.screen.px(LAUNCHER_LIST_TOP + row * LAUNCHER_ROW_STEP)
            if start <= y < start + self.screen.px(LAUNCHER_ROW_HEIGHT):
                return self.scroll + row
        return None

    def wheel(self, event):
        if self.expanded and len(self.rows) > self.visible_rows():
            step = max(1, abs(event.delta) // 120) * (-1 if event.delta > 0 else 1)
            self.scroll = min(max(self.scroll + step, 0), len(self.rows) - self.visible_rows())
            self.hover_row = None
            self.redraw()
        return "break"

    def scroll_to(self, y):
        fraction = (y - self.scroll_hit.y) / max(1, self.scroll_hit.height)
        self.scroll = round(max(0, min(1, fraction)) * max(0, len(self.rows) - self.visible_rows()))
        self.redraw()

    def move_selection(self, step):
        if self.rows:
            base = self.active_row if self.active_row is not None else (-1 if step > 0 else len(self.rows))
            self.active_row = min(len(self.rows) - 1, max(0, base + step))
            self.scroll = max(self.active_row - self.visible_rows() + 1, min(self.active_row, self.scroll))
            self.redraw()
        return "break"

    def open_selected(self, event):
        if self.rows and not self.native.composing():
            self.launch(self.rows[self.active_row or 0])
        return "break"

    def context_menu(self, event):
        row = self.row_at(event.x, event.y)
        if row is None:
            return
        site = self.rows[row]
        installed = set(self.service._installed())
        items = [("用指定浏览器打开", None, False)]
        for browser in dict.fromkeys(site["allowedBrowsers"]):
            default = browser == site["defaultBrowser"]
            label = NAMES.get(browser, browser) + (" · 默认" if default else "")
            choice = None
            if browser in installed:
                choice = lambda browser=browser: self.launch(site, browser)
            else:
                label += " · 未安装"
            items.append((label, choice, False))
        self.show_menu(items, self.desktop.pointer())

    def launch(self, site, browser=None):
        if self.launching:
            return
        self.launching = True
        self.status = "正在打开…"
        self.redraw()
        self.submit_launch(site, browser)

    def submit_launch(self, site, browser, *, authorize=False):
        def open_site():
            error = None
            try:
                launch_floating_site(self.service, site, browser, authorize=authorize)
            except AppError as exc:
                error = exc
            except Exception:
                LOG.exception("Floating website launch failed")
                error = AppError("没有打开网站，请检查浏览器是否可用。")
            self.completions.put((site, browser, authorize, error))

        threading.Thread(target=open_site, name="GaoMenHuWebsiteLaunch", daemon=True).start()

    def confirm_unlock(self, name):
        from tkinter import messagebox

        focused = self.root.focus_get() is self.entry
        allow = messagebox.askyesno("解锁搞门户账号库", f"解锁账号库并为「{name}」填入所选账号？",
                                    parent=self.root, default=messagebox.NO)
        if focused and self.expanded:
            self.entry.focus_set()
        return allow

    def finish_launch(self):
        try:
            site, browser, authorized, error = self.completions.get_nowait()
        except queue.Empty:
            return
        if error and error.code == "vault_locked" and not authorized:
            if self.confirm_unlock(site["name"]):
                self.submit_launch(site, browser, authorize=True)
                return
            error = AppError("已取消解锁。")
        self.launching = False
        self.status = str(error) if error else "正在用指定浏览器打开…"
        if error is None:
            self.set_expanded(False)
        else:
            self.redraw()

    def font(self, size, weight="normal"):
        return self.font_family, -max(1, self.screen.px(size)), weight

    def round_box(self, rect, radius, color, *, outline="", flush_left=False, flush_right=False):
        x, y, r, b = rect.x, rect.y, rect.right, rect.bottom
        radius = max(0, min(radius, rect.width // 2, rect.height // 2))
        left, right = (0 if flush_left else radius), (0 if flush_right else radius)
        self.canvas.create_polygon(x, y + left, x, y, x + left, y, r - right, y, r, y, r, y + right,
                                   r, b - right, r, b, r - right, b, x + left, b, x, b, x, b - left,
                                   smooth=True, fill=color, outline=outline, tags="paint")

    def text(self, x, y, value, size, color, width, *, center=False, bold=False):
        if width <= 0:
            return
        font = self.font(size, "bold" if bold else "normal")
        value = str(value or "")
        if not center and int(self.root.tk.call("font", "measure", font, value)) > width:
            lo, hi = 0, len(value)
            while lo < hi:
                middle = (lo + hi + 1) // 2
                if int(self.root.tk.call("font", "measure", font, value[:middle] + "…")) <= width:
                    lo = middle
                else:
                    hi = middle - 1
            value = value[:lo] + "…"
        self.canvas.create_text(x, y, text=value, font=font, fill=color,
                                anchor="center" if center else "w", width=width if center else 0, tags="paint")

    def redraw(self, event=None):
        px = self.screen.px
        w, h = self.frame.width, self.frame.height
        colors = PALETTE[self.theme]
        self.canvas.delete("paint")
        self.search_hit = self.clear_hit = self.scroll_hit = Rect(0, 0, 0, 0)
        if not self.expanded:
            self.canvas.itemconfigure(self.entry_item, state="hidden")
            self.canvas.itemconfigure(self.button_item, state="hidden")
            strip = min(w, px(7))
            x = 0 if self.dock == "left" else w - strip if self.dock == "right" else (w - strip) // 2
            self.round_box(Rect(x, max(0, (h - px(72)) // 2), strip, min(h, px(72))), px(3), colors["rail"],
                           flush_left=self.dock == "left", flush_right=self.dock == "right")
            for mark in (-3, 0, 3):
                y = h // 2 + px(mark)
                self.canvas.create_line(x + px(2), y, x + strip - px(2), y, fill=colors["primary_text"], tags="paint")
            return
        panel, ink, muted, border, field, accent = (colors[key] for key in ("surface", "text", "secondary", "border", "field", "accent"))
        self.round_box(Rect(0, 0, w - 1, h - 1), px(10), panel, outline=border,
                       flush_left=self.dock == "left", flush_right=self.dock == "right")
        self.text(px(14), px(23), "快速启动", 15, ink, w - px(132), bold=True)
        button_focused = self.root.focus_get() is self.open_button
        button_frame = Rect(w - px(108), px(11), px(94), px(25))
        self.round_box(button_frame, px(6), colors["tint"], outline=accent if button_focused else border)
        self.open_button.configure(font=self.font(11), bg=colors["tint"], fg=accent,
                                   activebackground=colors["card"], activeforeground=ink)
        self.canvas.coords(self.button_item, button_frame.x + button_frame.width // 2, px(23))
        self.canvas.itemconfigure(self.button_item, width=px(87), height=px(20), state="normal")

        self.search_hit = Rect(px(14), px(42), max(0, w - px(28)), px(29))
        self.round_box(self.search_hit, px(6), field, outline=accent if self.root.focus_get() is self.entry else border)
        self.canvas.create_oval(px(23), px(50), px(31), px(58), outline=muted, width=max(1, px(1)), tags="paint")
        self.canvas.create_line(px(30), px(57), px(34), px(61), fill=muted, width=max(1, px(1)), tags="paint")
        self.entry.configure(font=self.font(13), bg=field, fg=muted if self.placeholder else ink, insertbackground=ink)
        self.canvas.coords(self.entry_item, px(39), px(56.5))
        self.canvas.itemconfigure(self.entry_item, width=max(1, w - px(73)), height=px(22), state="normal")
        if not self.placeholder and self.query.get():
            x, y, r = w - px(25), px(56), px(5)
            self.clear_hit = Rect(x - px(8), y - px(8), px(16), px(16))
            self.canvas.create_oval(x - r, y - r, x + r, y + r, fill=muted, outline="", tags="paint")
            offset = px(2)
            self.canvas.create_line(x - offset, y - offset, x + offset, y + offset, fill=field, tags="paint")
            self.canvas.create_line(x - offset, y + offset, x + offset, y - offset, fill=field, tags="paint")

        if not self.rows:
            library = self.service.store.library or {}
            empty = ("没有匹配的网站\n试试其他关键词。" if library.get("sites")
                     else "还没有网站\n打开启动台添加网站。")
            self.text(w // 2, px(LAUNCHER_LIST_TOP + LAUNCHER_EMPTY_HEIGHT / 2), empty, 12, muted, w - px(28), center=True)
        for index in range(self.scroll, min(len(self.rows), self.scroll + self.visible_rows())):
            site = self.rows[index]
            y = px(LAUNCHER_LIST_TOP + LAUNCHER_ROW_STEP * (index - self.scroll))
            if index in (self.hover_row, self.active_row):
                self.round_box(Rect(px(12), y, max(0, w - px(24)), px(LAUNCHER_ROW_HEIGHT)), px(6),
                               colors["tint"], outline=accent if index == self.active_row else "")
            self.site_icon(site, px(20), y + px(5))
            self.text(px(57), y + px(19), site["name"], 13, ink, w - px(169), bold=True)
            browser = site["defaultBrowser"]
            self.text(w - px(102), y + px(19), NAMES.get(browser, browser), 11, muted, px(73))
            arrow = w - px(24)
            self.canvas.create_line(arrow - px(7), y + px(23), arrow, y + px(16), arrow - px(5), y + px(16),
                                    fill=accent if index == self.active_row else muted, tags="paint")
            self.canvas.create_line(arrow, y + px(16), arrow, y + px(21), fill=accent if index == self.active_row else muted, tags="paint")

        if len(self.rows) > self.visible_rows():
            self.scroll_hit = Rect(w - px(12), px(LAUNCHER_LIST_TOP), px(11), max(0, h - px(LAUNCHER_LIST_TOP + LAUNCHER_FOOTER)))
            track = self.scroll_hit
            span = max(px(18), round(track.height * self.visible_rows() / len(self.rows)))
            start = round(max(0, track.height - span) * self.scroll / (len(self.rows) - self.visible_rows()))
            self.round_box(Rect(track.x + px(4), track.y + start, px(5), span), px(2), muted)

        self.canvas.create_line(px(14), h - px(30), w - px(14), h - px(30), fill=colors["line"], tags="paint")
        status = "正在打开网站…" if self.launching else self.status
        status_color = accent if self.launching else muted if status == HINT else colors["warning"]
        self.text(px(14), h - px(16), status, 10, status_color, w - px(28))

    def site_icon(self, site, x, y):
        px = self.screen.px
        key = site["id"]
        if key not in self.image_cache:
            self.image_cache[key] = self.decode_icon(site.get("icon"), px(28))
        icon = self.image_cache[key]
        if icon is not None:
            self.canvas.create_image(x + px(14), y + px(14), image=icon, tags="paint")
        else:
            color = site.get("color") or "#635ce0"
            try:
                self.root.winfo_rgb(color)
            except self.tk.TclError:
                color = "#635ce0"
            self.round_box(Rect(x, y, px(28), px(28)), px(6), color)
            self.text(x + px(14), y + px(14), site["name"][:1], 15, "#ffffff", px(28), center=True, bold=True)

    def decode_icon(self, source, size):
        if not isinstance(source, str) or not source.startswith("data:image/") or len(source) > 4_000_100:
            return None
        try:
            data = base64.b64decode(source.split(",", 1)[1], validate=True)
        except (IndexError, ValueError, binascii.Error):
            return None
        try:
            from PIL import Image, ImageTk
        except ImportError:
            try:
                icon = self.tk.PhotoImage(master=self.root, data=data)
                ratio = max(1, (max(icon.width(), icon.height()) + size - 1) // size)
                return icon.subsample(ratio)
            except self.tk.TclError:
                return None
        try:
            with Image.open(BytesIO(data)) as image:
                if image.width * image.height > 16_000_000:
                    return None
                image.thumbnail((size, size), Image.Resampling.LANCZOS)
                return ImageTk.PhotoImage(image.convert("RGBA"), master=self.root)
        except (OSError, ValueError, Image.DecompressionBombError):
            return None
