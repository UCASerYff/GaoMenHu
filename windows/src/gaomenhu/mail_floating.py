"""The native Windows edge rail and cached mail card."""

import gc
import logging
import queue
import threading
import time
from datetime import datetime
from heapq import nsmallest
from math import hypot, isfinite
from urllib.parse import quote

from .centers import _message_code, sync_mail_floating
from .errors import AppError
from .floating_geometry import PointerTiming, Rect, screen_at
from .mail_floating_layout import (
    CARD_RADIUS, HEADER, MailPlacement, carried_mail_frame, mail_frame, mail_opacity, mail_size,
    rounded_card_contains, separated_mail_position,
)

LOG = logging.getLogger(__name__)
TRANSPARENT = "#00ff01"
PALETTE = {
    "light": {"bg": "#fbfaf8", "text": "#242327", "secondary": "#626168", "border": "#e0dce3",
              "line": "#eeebee", "card": "#f3f1f4", "tint": "#efebfc", "accent": "#655cde",
              "warning": "#9f4b16", "warning_bg": "#f9eee4", "rail": "#8c83e7", "primary_text": "#ffffff"},
    "dark": {"bg": "#28282e", "text": "#f6f3f7", "secondary": "#b3b1bc", "border": "#494653",
             "line": "#403d47", "card": "#33313b", "tint": "#3b3454", "accent": "#a49afa",
             "warning": "#ffb878", "warning_bg": "#4b3932", "rail": "#8477cc", "primary_text": "#252132"},
}


def _timestamp(value):
    return value if type(value) in (int, float) and isfinite(value) and 0 < value < 253402214400 else 0


def _clock_label(last, now):
    if not last:
        return "尚未同步"
    age = max(0, now - last)
    if age < 60:
        return "刚刚同步"
    if age < 3600:
        return f"{int(age // 60)} 分钟前同步"
    if age < 86400:
        return f"{int(age // 3600)} 小时前同步"
    if age < 604800:
        return f"{int(age // 86400)} 天前同步"
    return "同步于 " + datetime.fromtimestamp(last).strftime("%Y/%m/%d %H:%M")


def mail_floating_summary(store, show_previews, now):
    accounts = {account["id"]: account for account in store.library["accounts"]}
    enabled = sum(bool(account.get("enabled")) for account in accounts.values())
    unread = [entry for entry in store.messages if entry.get("accountID") in accounts
              and str(entry.get("folder", "")).casefold() == "inbox" and not entry.get("isRead")]
    previews = []
    if show_previews:
        latest = nsmallest(3, unread, key=lambda entry: (-_timestamp(entry.get("date")), str(entry["id"])))
        for entry in latest:
            date = _timestamp(entry.get("date"))
            account = accounts[entry["accountID"]]
            previews.append({
                "id": entry["id"],
                "sender": entry.get("from") or "未知发件人",
                "subject": entry.get("subject") or "（无主题）",
                "account": account.get("displayName") or account.get("email") or "",
                "time": datetime.fromtimestamp(date).strftime("%H:%M") if date else "",
                "code": _message_code(entry),
            })
    return {
        "accounts": len(accounts), "enabled": enabled, "unread": len(unread), "previews": previews,
        "errors": sum(bool(str(account.get("syncError") or "").strip()) for account in accounts.values()),
        "last_sync": _clock_label(max((_timestamp(account.get("lastSync")) for account in accounts.values()), default=0), now),
        "can_sync": any(account.get("enabled") and account["id"] in store.authorized for account in accounts.values()),
        "problem": False,
    }


class MailFloatingPanel:
    def __init__(self, tk, root, desktop, service, commands, open_window, neighboring_rail, system_appearance,
                 *, present=True):
        self.tk, self.root, self.desktop, self.service = tk, root, desktop, service
        self.commands, self.open_window, self.neighboring_rail = commands, open_window, neighboring_rail
        self.system_appearance, self.present = system_appearance, present
        self.events = queue.SimpleQueue()
        self.enabled = self.expanded = self.menu_open = self.syncing = False
        self.preferences, self.pending = {}, {}
        self.snapshot = None
        self.theme, self.topmost, self.opacity = "light", True, 1.0
        self.prefix = ""
        self.copied = None
        self.actions = {}
        self.bindings = {}
        self.focused_action = None
        self.previous_foreground = None
        self.drag = None
        self.pressed_inside = False
        self.buttons = 0
        self.timing = PointerTiming(reveal_delay=0.28, leave_delay=0.08, cooldown=0)
        self.screens = desktop.monitors()
        self.screen = self.screens[0]
        self.frame = mail_frame(self.screen, MailPlacement(), False)
        self.position = MailPlacement()
        self.window = tk.Toplevel(root)
        self.window.withdraw()
        self.window.title("搞门户 · 邮件 · 悬浮窗")
        self.window.overrideredirect(True)
        self.window.protocol("WM_DELETE_WINDOW", lambda: self.command("hide"))
        self.canvas = tk.Canvas(self.window, bg=TRANSPARENT, borderwidth=0, highlightthickness=0)
        self.canvas.pack(fill="both", expand=True)
        self.body = tk.Canvas(self.canvas, borderwidth=0, highlightthickness=0)
        self.body_item = self.canvas.create_window(0, 0, anchor="nw", window=self.body, state="hidden")
        self.hit = tk.Toplevel(root)
        self.hit.withdraw()
        self.hit.title("展开搞门户邮件悬浮窗")
        self.hit.overrideredirect(True)
        self.hit.configure(bg="#333333")
        for target in (self.hit, self.canvas):
            target.bind("<ButtonPress-1>", self.press)
            target.bind("<ButtonRelease-1>", self.release)
            target.bind("<B1-Motion>", self.motion)
            target.bind("<ButtonRelease-3>", self.context_menu)
        self.window.bind("<Escape>", lambda _: self.set_expanded(False))
        self.window.bind("<Control-w>", lambda _: self.command("hide"))
        self.body.bind("<MouseWheel>", self.wheel)
        self.body.bind("<Button-1>", self.focus_body)
        self.body.bind("<Tab>", lambda _: self.focus_action(1))
        self.body.bind("<Shift-Tab>", lambda _: self.focus_action(-1))
        self.body.bind("<Return>", self.invoke_focused)
        self.body.bind("<Up>", lambda _: self.body.yview_scroll(-1, "units"))
        self.body.bind("<Down>", lambda _: self.body.yview_scroll(1, "units"))
        with desktop.without_activation():
            self.window.update_idletasks()
        self.native = desktop.DesktopWindow(self.window, self.command, self.allows_activation, tray=False)
        self.hit_window = desktop.prepare_window(self.hit)
        # Tk's layered window attributes can rewrap and briefly activate a
        # withdrawn toplevel. Set the attributes on the final HWND instead.
        desktop.configure_transparency(self.native.window, color_key=TRANSPARENT)
        desktop.configure_transparency(self.hit_window, opacity=0.012)
        self.ready_at = 0
        self.refresh()
        self.schedule = root.after(40, self.poll)

    def command(self, action):
        if action == "display":
            screens = self.desktop.monitors()
            if screens != self.screens:
                self.screens = screens
                if not self.drag:
                    self.place(self.restored_frame())
        elif action == "session-lock":
            self.drag = None
            self.set_expanded(False)
        elif action in ("show", "hide", "toggle"):
            enabled = not self.enabled if action == "toggle" else action == "show"
            if enabled != self.enabled:
                self.pending["floatingVisible"] = enabled
                self.set_enabled(enabled)
        elif action == "reset":
            self.pending["floatingPlacement"] = None
            self.drag = None
            self.place(self.restored_frame())
        self.ready_at = 0

    def close(self):
        self.root.after_cancel(self.schedule)
        if self.pending and self.service.mail_lock.acquire(timeout=0.5):
            try:
                self.commit_preferences(self.service.mail_store())
            except (AppError, OSError):
                LOG.warning("Could not save the mail floating position during shutdown", exc_info=True)
            finally:
                self.service.mail_lock.release()
        self.native.close()
        self.hit.destroy()
        self.window.destroy()

    def commit_preferences(self, store):
        if self.pending:
            store.save_preferences(self.pending)
            self.pending.clear()

    def refresh(self, *, restore_visibility=True):
        if not self.service.mail_lock.acquire(blocking=False):
            return
        try:
            source = self.service.data_dir / "MailCenter" / "Library.json"
            if not self.pending and self.service.mail is None and not source.exists():
                return
            store = self.service.mail_store()
            self.commit_preferences(store)
            preferences = store.library["preferences"].copy()
            show = bool(preferences.get("showPreviews"))
            summary = mail_floating_summary(store, show and self.expanded, self.service.clock())
        except (AppError, OSError, ValueError, TypeError, KeyError):
            LOG.debug("Could not refresh the mail floating state", exc_info=True)
            summary = {"accounts": 0, "enabled": 0, "unread": 0, "previews": [], "errors": 0,
                       "last_sync": "尚未同步", "can_sync": False, "problem": True}
            preferences = self.preferences
        finally:
            self.service.mail_lock.release()
        preferences = preferences | self.pending
        theme = preferences.get("appearance", "system")
        if theme not in PALETTE:
            theme = self.system_appearance()
        changed = (summary, preferences, theme) != (self.snapshot, self.preferences, self.theme)
        self.snapshot, self.preferences, self.theme = summary, preferences, theme
        self.topmost = preferences.get("keepOnTop") is not False
        alpha = mail_opacity(preferences.get("floatingOpacity"))
        if alpha != self.opacity:
            self.opacity = alpha
            self.desktop.configure_transparency(self.native.window, opacity=alpha, color_key=TRANSPARENT)
        if restore_visibility:
            self.set_enabled(preferences.get("floatingVisible") is True)
        if self.enabled and not self.drag:
            frame = self.restored_frame()
            if changed or frame != self.frame:
                self.place(frame)

    def set_enabled(self, enabled):
        if enabled == self.enabled:
            return
        self.enabled = enabled
        self.expanded = False
        self.drag = None
        self.timing = PointerTiming(reveal_delay=0.28, leave_delay=0.08, cooldown=0)
        if enabled:
            self.place(self.restored_frame())
        else:
            self.resign_focus()
            self.window.withdraw()
            self.hit.withdraw()

    def set_expanded(self, expanded):
        if not self.enabled or self.expanded == expanded or self.drag:
            return
        self.expanded = expanded
        self.focused_action = None
        self.timing.transition(expanded, time.monotonic())
        self.body.yview_moveto(0)
        if expanded:
            self.refresh(restore_visibility=False)
        else:
            self.resign_focus()
        self.place(self.restored_frame())
        if not expanded and not self.frame.contains(self.desktop.pointer()):
            self.timing.armed = True

    def restored_frame(self):
        saved = self.pending.get("floatingPlacement", self.preferences.get("floatingPlacement"))
        position = MailPlacement.restore(saved)
        screen = next((value for value in self.screens if value.name == position.screen), self.screens[0])
        if not MailPlacement.valid(saved):
            position = separated_mail_position(screen, position, self.neighboring_rail())
        self.position, self.screen = position, screen
        return mail_frame(screen, position, self.expanded, self.ideal_height())

    def place(self, frame):
        self.frame = frame
        self.window.geometry(f"{frame.width}x{frame.height}")
        self.redraw()
        if not self.enabled or not self.present:
            return
        # Positions are established without activation before and after mapping.
        if self.expanded:
            self.hit.withdraw()
        else:
            self.hit.geometry(f"{frame.width}x{frame.height}")
            self.desktop.place_window(self.hit_window, frame, topmost=self.topmost)
            if self.hit.state() == "withdrawn":
                self.desktop.show_nonactivating(self.hit)
                self.desktop.place_window(self.hit_window, frame, topmost=self.topmost)
        self.native.place(frame, topmost=self.topmost)
        if self.window.state() == "withdrawn":
            self.desktop.show_nonactivating(self.window)
        self.native.place(frame, topmost=self.topmost)

    def allows_activation(self, point):
        allows = self.expanded and point[1] - self.frame.y >= self.px(HEADER) and self.contains(point)
        if allows:
            previous = self.desktop.get_foreground()
            if previous != self.native.window:
                self.previous_foreground = previous
        return allows

    def focus_body(self, _event):
        if self.allows_activation(self.desktop.pointer()):
            self.native.focus()
            self.body.focus_set()

    def resign_focus(self):
        previous, self.previous_foreground = self.previous_foreground, None
        if previous and self.desktop.get_foreground() == self.native.window:
            self.desktop.set_foreground(previous)

    def contains(self, point):
        if self.expanded:
            return rounded_card_contains(point, self.frame, self.px(CARD_RADIUS))
        return self.frame.contains(point)

    def poll(self):
        try:
            while True:
                self.command(self.commands.get_nowait())
        except queue.Empty:
            pass
        try:
            status = self.events.get_nowait()
        except queue.Empty:
            pass
        else:
            self.syncing = False
            self.prefix = status
            self.ready_at = 0
            self.root.after(3000, self.clear_status, status)
            self.redraw()
        now = time.monotonic()
        if now >= self.ready_at:
            self.refresh()
            self.ready_at = now + (0.25 if self.pending or self.expanded else 1)
        if self.enabled and not self.menu_open and self.present:
            self.evaluate_pointer(now, self.desktop.pointer(), self.desktop.mouse_buttons())
        self.schedule = self.root.after(40, self.poll)

    def evaluate_pointer(self, now, point, buttons):
        if self.drag:
            if buttons & 1:
                self.move_drag(point)
            else:
                self.end_drag(point)
        inside = self.contains(point)
        if inside and self.present:
            inside = self.desktop.contains_pointer(point, (self.native.window, self.hit_window))
        pressed = bool(buttons & ~self.buttons)
        if pressed and inside:
            self.pressed_inside = True
        if not buttons:
            self.pressed_inside = False
        transition = self.timing.tick(now, expanded=self.expanded, inside=inside, buttons=buttons,
                                      outside_press=pressed and not inside,
                                      protected=bool(self.drag or self.pressed_inside))
        if transition is not None:
            self.set_expanded(transition)
        self.buttons = buttons

    def press(self, event):
        if not self.expanded or event.y < self.px(HEADER):
            self.drag = self.desktop.pointer(), self.frame, self.screen, False

    def motion(self, _event):
        if self.drag:
            self.move_drag(self.desktop.pointer())

    def release(self, _event):
        if self.drag:
            self.end_drag(self.desktop.pointer())

    def move_drag(self, point):
        start, original, screen, moved = self.drag
        dx, dy = point[0] - start[0], point[1] - start[1]
        if not moved and hypot(dx, dy) <= screen.px(4):
            return
        target = screen_at(self.screens, point)
        scale = target.dpi / screen.dpi
        width, height = mail_size(target, self.expanded, self.ideal_height())
        wanted = Rect(point[0] - round((start[0] - original.x) * scale),
                      point[1] - round((start[1] - original.y) * scale), width, height)
        frame, position = carried_mail_frame(target, wanted, self.position.side, self.expanded)
        self.drag = start, original, screen, True
        if (frame, position) != (self.frame, self.position):
            self.position, self.screen = position, target
            self.place(frame)

    def end_drag(self, point):
        _, _, _, moved = self.drag
        self.drag = None
        if moved:
            self.pending["floatingPlacement"] = self.position.serialized()
            if not self.expanded:
                self.timing.transition(False, time.monotonic())
            self.refresh()
        elif not self.expanded and self.contains(point):
            self.set_expanded(True)

    def context_menu(self, _event):
        self.menu_open = True
        try:
            action = self.native.menu([
                ("打开收件箱", lambda: self.open_target("/mail#inbox"), False),
                ("写邮件", lambda: self.open_target("/mail#compose"), False),
                ("悬浮窗设置…", lambda: self.open_target("/mail#floating-settings"), False),
                (None, None, False), ("隐藏邮件悬浮窗", lambda: self.command("hide"), False),
            ], self.desktop.pointer())
            if action:
                action()
        finally:
            self.menu_open = False
            self.timing.left = None

    def open_target(self, path):
        self.set_expanded(False)
        self.open_window(path)

    def clear_status(self, status):
        if self.prefix == status:
            self.prefix = ""
            self.redraw()

    def sync_mail(self):
        if self.syncing or not self.snapshot or not self.snapshot["can_sync"]:
            return
        self.syncing = True
        self.redraw()

        def run():
            try:
                sync_mail_floating(self.service)
            except AppError as exc:
                self.events.put(str(exc))
            except OSError:
                self.events.put("同步失败，请查看邮箱状态。")
            else:
                self.events.put("同步完成")

        threading.Thread(target=run, name="GaoMenHuFloatingMailSync", daemon=True).start()

    def copy_code(self, code):
        self.window.clipboard_clear()
        self.window.clipboard_append(code)
        self.copied = code
        self.redraw()

        def clear():
            if self.copied == code:
                self.copied = None
                self.redraw()

        self.root.after(2000, clear)

    def px(self, value):
        return self.screen.px(value)

    def ideal_height(self):
        snapshot = self.snapshot
        if not snapshot or snapshot["problem"]:
            content = 70
        elif not snapshot["accounts"]:
            content = 64
        elif not self.preferences.get("showPreviews"):
            content = 88
        elif snapshot["previews"]:
            content = sum(94 if preview["code"] else 69 for preview in snapshot["previews"])
        else:
            content = 32
        if snapshot and (snapshot["errors"] or snapshot["problem"]):
            content += 25
        return HEADER + content + 63

    def round_box(self, canvas, x, y, w, h, radius, fill, *, outline="", tags=""):
        r, b = x + w - 1, y + h - 1
        radius = max(0, min(radius, w // 2, h // 2))
        coords = (x, y + radius, x, y, x + radius, y, r - radius, y, r, y, r, y + radius,
                  r, b - radius, r, b, r - radius, b, x + radius, b, x, b, x, b - radius)
        return canvas.create_polygon(*coords, smooth=True, fill=fill, outline=outline, tags=("paint", tags))

    def text(self, canvas, x, y, value, size, color, width, *, bold=False, anchor="nw", tags=""):
        if width < 1:
            return
        font = ("Segoe UI", -max(1, self.px(size)), "bold" if bold else "normal")
        value = " ".join(str(value).split())
        measure = self.root.tk.call
        if measure("font", "measure", font, value) > width:
            lo, hi = 0, len(value)
            while lo < hi:
                middle = (lo + hi + 1) // 2
                if measure("font", "measure", font, value[:middle] + "…") <= width:
                    lo = middle
                else:
                    hi = middle - 1
            value = value[:lo] + "…"
        return canvas.create_text(x, y, text=value, fill=color, font=font, anchor=anchor, tags=("paint", tags))

    def action(self, key, callback):
        def invoke(_event):
            if self.expanded:
                callback()
        self.actions[key] = callback
        self.bindings[key] = self.body.tag_bind(key, "<ButtonRelease-1>", invoke)

    def focus_action(self, step):
        keys = list(self.actions)
        if keys:
            current = keys.index(self.focused_action) if self.focused_action in keys else (-1 if step > 0 else 0)
            self.focused_action = keys[(current + step) % len(keys)]
            self.draw_focus()
            if bounds := self.body.bbox(self.focused_action):
                _, y1, _, y2 = bounds
                height = self.body.winfo_height()
                top = self.body.canvasy(0)
                maximum = max(1, int(self.body.cget("scrollregion").split()[-1]))
                if y1 < top or y2 > top + height:
                    self.body.yview_moveto(max(0, y2 - height + self.px(4)) / maximum)
        return "break"

    def invoke_focused(self, _event):
        callback = self.actions.get(self.focused_action)
        if self.expanded and callback:
            callback()
        return "break"

    def draw_focus(self):
        self.body.delete("keyboard-focus")
        if self.focused_action in self.actions and (bounds := self.body.bbox(self.focused_action)):
            x1, y1, x2, y2 = bounds
            self.body.create_rectangle(max(0, x1), max(0, y1), x2 - 1, y2 - 1, outline=PALETTE[self.theme]["accent"],
                                       dash=(2, 2), tags=("paint", "keyboard-focus"))

    def wheel(self, event):
        self.body.yview_scroll((-1 if event.delta > 0 else 1) * max(1, abs(event.delta) // 120), "units")
        return "break"

    def redraw(self):
        px, colors = self.px, PALETTE[self.theme]
        self.canvas.delete("paint")
        width, height = self.frame.width, self.frame.height
        snapshot = self.snapshot
        self.body.delete("paint")
        for key, binding in self.bindings.items():
            self.body.tag_unbind(key, "<ButtonRelease-1>", binding)
        self.bindings.clear()
        self.actions.clear()
        if not self.expanded:
            self.canvas.itemconfigure(self.body_item, state="hidden")
            x = 0 if self.position.side == "left" else max(0, width - px(6))
            y = max(0, (height - px(88)) // 2)
            self.round_box(self.canvas, x, y, px(6), px(88), px(4),
                           colors["accent"] if snapshot and snapshot["unread"] else colors["rail"])
            if snapshot and (snapshot["errors"] or snapshot["problem"]):
                self.canvas.create_oval(x + px(1.5), y + px(5), x + px(4.5), y + px(8),
                                        fill="#f4a04d", outline="", tags="paint")
            return
        if not snapshot:
            snapshot = {"accounts": 0, "unread": 0, "enabled": 0, "errors": 0, "previews": [], "problem": False,
                        "can_sync": False, "last_sync": "尚未同步"}
        self.round_box(self.canvas, 0, 0, width, height, px(CARD_RADIUS), colors["bg"], outline=colors["border"])
        self.text(self.canvas, px(14), px(5), snapshot["unread"], 40, colors["text"], width - px(154), bold=True)
        self.text(self.canvas, px(14), px(54), "缓存未读 · 收件箱", 11, colors["secondary"], width - px(150))
        error = snapshot["errors"] or snapshot["problem"]
        status = ("正在同步" if self.syncing else f"{snapshot['errors']} 个邮箱待检查" if snapshot["errors"]
                  else "操作待处理" if snapshot["problem"] else "本机缓存")
        self.round_box(self.canvas, width - px(125), px(20), px(111), px(23), px(12),
                       colors["warning_bg" if error and not self.syncing else "tint"])
        self.text(self.canvas, width - px(69), px(31), status, 10,
                  colors["warning" if error and not self.syncing else "accent"], px(107), anchor="center")
        counts = f"{snapshot['enabled']} 个启用 · {snapshot['accounts'] - snapshot['enabled']} 个仅登记"
        self.text(self.canvas, width - px(14), px(50), counts, 10, colors["secondary"], px(132), anchor="ne")

        body_w = max(1, width - px(20))
        self.body.configure(bg=colors["bg"], yscrollincrement=max(1, px(16)))
        self.canvas.coords(self.body_item, px(10), px(HEADER))
        self.canvas.itemconfigure(self.body_item, state="normal", width=body_w, height=max(1, height - px(HEADER + 10)))
        self.body.create_line(0, 0, body_w, 0, fill=colors["line"], tags="paint")
        y = self.draw_content(snapshot, colors, body_w)
        self.body.create_line(0, y, body_w, y, fill=colors["line"], tags="paint")
        y += px(8)
        actions = (
            ("inbox", "添加邮箱" if not snapshot["accounts"] else "收件箱", 99, True,
             lambda: self.open_target("/mail#add-account" if not snapshot["accounts"] else "/mail#inbox")),
            ("sync", "同步", 60, False, self.sync_mail if snapshot["can_sync"] and not self.syncing else None),
            ("compose", "写信", 60, False, lambda: self.open_target("/mail#compose")),
        )
        x = 0
        for key, label, size, primary, callback in actions:
            button_width = px(size)
            if key == "sync":
                x = max(x, body_w - px(128))
            self.round_box(self.body, x, y, button_width, px(25), px(6),
                           colors["accent" if primary else "card"], tags=key)
            self.text(self.body, x + button_width // 2, y + px(12), label, 11,
                      colors["primary_text" if primary else "text" if callback else "secondary"], button_width,
                      anchor="center", tags=key)
            if callback:
                self.action(key, callback)
            x += button_width + px(8)
        y += px(34)
        self.text(self.body, 0, y, self.prefix or snapshot["last_sync"], 9, colors["secondary"], body_w - px(84))
        self.text(self.body, body_w, y, "最近同步范围", 9, colors["secondary"], px(78), anchor="ne")
        self.body.configure(scrollregion=(0, 0, body_w, y + px(14)))
        self.draw_focus()

    def draw_content(self, snapshot, colors, width):
        p = self.px
        y = p(6)
        if snapshot["problem"] or not snapshot["accounts"] or not self.preferences.get("showPreviews"):
            if snapshot["problem"]:
                lines = [("邮件资料待检查", 13), ("打开邮件设置查看本机资料。", 11)]
            elif not snapshot["accounts"]:
                lines = [("把邮箱带到桌面", 13), ("添加邮箱后，在这里查看缓存未读数量和同步状态。", 11)]
            else:
                unread = snapshot["unread"]
                lines = [("邮件预览已隐藏", 11),
                         (f"有 {unread} 封缓存未读邮件，打开收件箱查看。" if unread else "当前缓存中没有未读邮件。", 12),
                         ("可在邮件设置的外观页显示最近三封未读邮件。", 10)]
            height = p(20 + len(lines) * 18)
            self.round_box(self.body, 0, y, width, height, p(11), colors["card"])
            for i, (line, size) in enumerate(lines):
                self.text(self.body, p(10), y + p(8 + 18 * i), line, size,
                          colors["text" if i == 0 else "secondary"], width - p(20), bold=i == 0)
            y += height + p(6)
        elif not snapshot["previews"]:
            self.text(self.body, p(5), y + p(4), "暂无缓存未读邮件", 12, colors["secondary"], width - p(10))
            y += p(26)
        else:
            for index, preview in enumerate(snapshot["previews"]):
                y = self.preview(preview, colors, width, y, index)
        if snapshot["errors"] or snapshot["problem"]:
            link = "failure"
            self.text(self.body, p(4), y + p(2), "查看操作提示" if snapshot["problem"] else "查看邮箱状态",
                      11, colors["warning"], width - p(8), tags=link)
            self.action(link, lambda: self.open_target("/mail#settings" if snapshot["problem"] else "/mail#accounts"))
            y += p(23)
        return y

    def preview(self, preview, colors, width, y, index):
        p = self.px
        target, clip = f"message{index}", f"code{index}"
        code = preview["code"]
        height = p(88 if code else 63)
        self.round_box(self.body, 0, y, width, height, p(9), colors["card"], tags=target)
        self.body.create_oval(p(9), y + p(11), p(14), y + p(16), fill=colors["accent"], outline="", tags=("paint", target))
        self.text(self.body, p(22), y + p(7), preview["sender"], 10, colors["text"], width - p(77), bold=True, tags=target)
        self.text(self.body, width - p(9), y + p(7), preview["time"], 9, colors["secondary"], p(45), anchor="ne", tags=target)
        self.text(self.body, p(22), y + p(25), preview["subject"], 12, colors["text"], width - p(31), tags=target)
        if code:
            self.round_box(self.body, p(22), y + p(44), width - p(31), p(22), p(6), colors["tint"], tags=clip)
            self.text(self.body, p(28), y + p(48), code, 11, colors["accent"], width - p(94), bold=True, tags=clip)
            self.text(self.body, width - p(16), y + p(48), "已复制" if code == self.copied else "复制",
                      9, colors["accent"], p(46), anchor="ne", tags=clip)
            self.action(clip, lambda: self.copy_code(code))
        self.text(self.body, p(22), y + p(69 if code else 44), preview["account"], 9,
                  colors["secondary"], width - p(31), tags=target)
        self.action(target, lambda: self.open_target("/mail#message=" + quote(str(preview["id"]), safe="")))
        return y + height + p(6)


def smoke_mail_floating(service):
    """Exercise the packaged HWNDs without mapping windows or editing preferences."""
    import tkinter as tk

    from . import floating_win32 as desktop
    from .floating import system_appearance

    desktop.enable_thread_dpi()
    root = tk.Tk(className="GaoMenHuMailSmoke")
    root.withdraw()
    panel = None
    try:
        panel = MailFloatingPanel(tk, root, desktop, service, queue.SimpleQueue(), lambda _: None,
                                  lambda: None, system_appearance, present=False)
        panel.set_enabled(True)
        rail = panel.frame
        root.update_idletasks()
        panel.native.place(rail)
        desktop.place_window(panel.hit_window, rail)
        point = (rail.right - 1, rail.y + rail.height // 2)
        now = time.monotonic()
        panel.evaluate_pointer(now, point, 0)
        panel.evaluate_pointer(now + 0.30, point, 0)
        root.update_idletasks()
        card = panel.frame
        panel.native.place(card)
        if not (panel.expanded and desktop.window_rect(panel.native.window) == card
                and desktop.window_rect(panel.hit_window) == rail and panel.body.find_all()
                and panel.window.state() == panel.hit.state() == "withdrawn"
                and desktop.get_window_long(panel.native.window, -20) & desktop.NO_ACTIVATE):
            raise RuntimeError("Native mail rail or card failed the isolated smoke check")
        panel.evaluate_pointer(now + 0.32, (card.x - 5, card.y - 5), 1)
        if panel.expanded or panel.frame != rail:
            raise RuntimeError("Native mail panel did not collapse after an outside press")
        return {"dpi": panel.screen.dpi, "rail": [rail.width, rail.height], "card": [card.width, card.height]}
    finally:
        if panel is not None:
            panel.close()
        root.destroy()
        # Tcl finalization on the WebView2 thread would abort the process.
        panel = root = None
        gc.collect()
