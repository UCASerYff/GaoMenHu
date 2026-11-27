import os
import time
from queue import SimpleQueue
from types import SimpleNamespace

import pytest

from gaomenhu import centers
from gaomenhu.desktop import Desktop, local_window_key
from gaomenhu.errors import AppError
from gaomenhu.floating_geometry import PointerTiming, Rect, Screen
from gaomenhu.mail_floating import MailFloatingPanel, mail_floating_summary
from gaomenhu.mail_floating_layout import (
    MailPlacement, carried_mail_frame, mail_frame, rounded_card_contains, separated_mail_position,
)
from gaomenhu.service import PortalService


def test_mail_geometry_shares_the_rail_anchor_across_expansion_and_dpi():
    screen = Screen("main", Rect(0, 0, 2560, 1440), Rect(0, 0, 2560, 1380), 144)
    default = MailPlacement()
    rail = mail_frame(screen, default, False)
    card = mail_frame(screen, default, True)
    assert rail == Rect(2530, 184, 30, 156)
    assert card == Rect(2050, 184, 510, 420)
    separated = separated_mail_position(screen, default, Rect(2530, 144, 30, 156))
    assert mail_frame(screen, separated, False).y == 318

    wanted = Rect(19, 267, 510, 420)
    left, position = carried_mail_frame(screen, wanted, "right", True)
    assert left.x == 0 and position.dock == position.side == "left"
    assert mail_frame(screen, position, False).y == left.y
    assert mail_frame(screen, position, True) == left

    free, position = carried_mail_frame(screen, Rect(870, 400, 510, 420), "right", True)
    assert position.dock == "free" and position.side == "right"
    assert mail_frame(screen, position, False).right == free.right
    replaced = Screen("main", Rect(-1920, 10, 1920, 1080), Rect(-1920, 10, 1920, 1040), 96)
    reloaded = MailPlacement.restore(position.serialized())
    assert mail_frame(replaced, reloaded, False).right == mail_frame(replaced, reloaded, True).right
    assert mail_frame(replaced, reloaded, True, 2000).height == 420


def test_mail_hover_leave_click_and_rounded_edges():
    timing = PointerTiming(reveal_delay=0.28, leave_delay=0.08, cooldown=0)

    def tick(t, *, inside=True, expanded=False, protected=False, outside_press=False):
        return timing.tick(t, expanded=expanded, inside=inside, buttons=int(outside_press),
                           outside_press=outside_press, protected=protected)

    assert tick(1) is None
    assert tick(1.27) is None
    assert tick(1.29) is True
    timing.transition(True, 1.29)
    assert tick(2, inside=False, expanded=True, protected=True) is None
    assert tick(3, inside=False, expanded=True) is None
    assert tick(3.07, inside=False, expanded=True) is None
    assert tick(3.09, inside=False, expanded=True) is False
    assert tick(4, inside=False, expanded=True, outside_press=True) is False
    timing.transition(False, 4)
    assert tick(5) is None and tick(6) is None
    assert tick(7, inside=False) is None and tick(8) is None and tick(8.3) is True
    frame = Rect(25, 60, 340, 280)
    assert not rounded_card_contains((25, 60), frame, 18)
    assert rounded_card_contains((43, 60), frame, 18)
    assert not rounded_card_contains((365, 165), frame, 18)


def test_mail_summary_remains_local_and_private_and_shows_only_latest_known_inbox_messages():
    accounts = [{"id": "known", "enabled": True, "email": "test@example.test", "lastSync": 150},
                {"id": "disabled", "enabled": False, "syncError": "Fixture error"}]
    messages = [{"id": str(i), "accountID": "known", "folder": "Inbox", "from": "Fixture",
                 "subject": "验证码 123456", "isRead": False, "date": i} for i in range(1, 6)]
    messages.extend([{"id": "removed", "accountID": "missing", "folder": "INBOX", "date": 25},
                     {"id": "sent", "accountID": "known", "folder": "Sent", "date": 30},
                     {"id": "read", "accountID": "known", "folder": "INBOX", "isRead": True}])
    store = SimpleNamespace(library={"accounts": accounts}, authorized={"known"}, messages=messages)
    private = mail_floating_summary(store, False, 300)
    assert private == {"accounts": 2, "enabled": 1, "unread": 5, "previews": [], "errors": 1,
                       "last_sync": "2 分钟前同步", "can_sync": True, "problem": False}
    revealed = mail_floating_summary(store, True, 300)
    assert [entry["id"] for entry in revealed["previews"]] == ["5", "4", "3"]
    assert revealed["previews"][0]["code"] == "123456"
    assert messages[0]["isRead"] is False


def test_mail_preferences_survive_restart_and_keep_old_fields(tmp_path):
    path = tmp_path / "MenDao"
    service = PortalService(path, browser_probe=lambda: ["edge"])
    store = service.mail_store()
    store.save_preferences({"keepOnTop": False, "showPreviews": True, "syncMinutes": 5})
    position = MailPlacement("secondary", "left", "left", 0, 0.3).serialized()
    store.save_preferences({"floatingPlacement": position, "floatingVisible": True, "floatingOpacity": 0.83})
    restarted = PortalService(path, browser_probe=lambda: ["edge"]).mail_store()
    current = restarted.library["preferences"]
    assert current["floatingPlacement"] == position and current["floatingOpacity"] == 0.83
    assert current["floatingVisible"] is True and current["keepOnTop"] is False
    assert current["showPreviews"] is True and current["syncMinutes"] == 5
    with pytest.raises(AppError):
        restarted.save_preferences({"floatingPlacement": {**position, "down": float("nan")}})
    with pytest.raises(AppError):
        restarted.save_preferences({"floatingOpacity": True})
    restarted.save_preferences({"floatingPlacement": None})
    assert MailPlacement.restore(restarted.library["preferences"]["floatingPlacement"]) == MailPlacement()


def test_floating_sync_uses_only_enabled_and_connected_accounts(monkeypatch, tmp_path):
    service = PortalService(tmp_path / "MenDao", browser_probe=lambda: ["edge"])
    store = service.mail_store()
    for identity, enabled in (("valid", True), ("disabled", False), ("locked", True)):
        store.save_account({"id": identity, "email": f"{identity}@example.test", "enabled": enabled})
    store.authorized.update(("valid", "disabled"))
    synced = []
    monkeypatch.setattr(centers, "_sync", lambda _service, _store, identity: synced.append(identity))
    centers.sync_mail_floating(service)
    assert synced == ["valid"]
    store.authorized.clear()
    with pytest.raises(AppError, match="先在邮箱管理连接邮箱"):
        centers.sync_mail_floating(service)
    assert synced == ["valid"]


def test_desktop_routes_visible_mail_to_native_worker_and_reuses_the_settings_window():
    desktop = Desktop(SimpleNamespace(service=None, port=12345))
    desktop.ready.set()
    assert desktop.open_window("/mail#floating")
    assert desktop.mail_panel_commands.get_nowait() == "show"
    assert local_window_key("/mail#floating-settings") == "/mail#settings"
    assert local_window_key("/mail#message=7") == "/mail"


@pytest.mark.skipif(os.name != "nt", reason="requires native Windows Tk HWND")
def test_hidden_real_mail_hwnds_reflow_without_foreground_changes(tmp_path):
    import tkinter as tk

    from gaomenhu import floating_win32 as desktop

    desktop.enable_thread_dpi()
    try:
        root = tk.Tk(className="GaoMenHuMailIsolatedTest")
    except tk.TclError as exc:
        pytest.skip(f"Native Tk is unavailable: {exc}")
    root.withdraw()
    panel = None
    try:
        service = PortalService(tmp_path / "MenDao", browser_probe=lambda: ["edge"])
        opened, commands = [], SimpleQueue()
        panel = MailFloatingPanel(tk, root, desktop, service, commands, opened.append, lambda: None,
                                  lambda: "dark", present=False)
        assert service.mail is None
        commands.put("show")
        root.after_cancel(panel.schedule)
        panel.poll()
        assert panel.enabled and not panel.expanded
        assert panel.frame.width == panel.screen.px(20)
        assert panel.frame.height == panel.screen.px(104)
        assert desktop.get_window_long(panel.native.window, -20) & desktop.NO_ACTIVATE
        assert desktop.get_window_long(panel.hit_window, -20) & desktop.NO_ACTIVATE
        rail_point = (panel.frame.right - 2, panel.frame.y + panel.frame.height // 2)
        now = time.monotonic()
        panel.evaluate_pointer(now, rail_point, 0)
        panel.evaluate_pointer(now + 0.30, rail_point, 0)
        assert panel.expanded
        root.update_idletasks()
        assert panel.frame.width == panel.screen.px(340) and panel.theme == "dark"
        assert panel.window.state() == panel.hit.state() == "withdrawn"
        assert panel.body.itemcget(panel.body.find_all()[0], "fill")
        assert panel.focus_action(1) == "break"
        panel.invoke_focused(None)
        assert opened == ["/mail#add-account"] and not panel.expanded
        assert desktop.get_foreground() not in (panel.native.window, panel.hit_window)
        panel.command("hide")
        panel.refresh()
        assert service.mail.library["preferences"]["floatingVisible"] is False
    finally:
        if panel:
            panel.close()
        root.destroy()
