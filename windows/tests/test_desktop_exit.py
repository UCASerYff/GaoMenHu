"""Check desktop lifetime and service shutdown decisions at the native boundary."""

import threading
from types import SimpleNamespace

import pytest

from gaomenhu.desktop import Desktop
from gaomenhu.errors import AppError
from gaomenhu.server import PortalServer
from gaomenhu.service import PortalService


class Window:
    def __init__(self, **state):
        self.state = state
        self.events = SimpleNamespace(loaded=threading.Event(), closed=threading.Event(), shown=threading.Event())
        self.events.loaded.set()
        self.events.shown.set()
        self.native = None
        self.visible = True
        self.saves = 0
        self.save_succeeds = True

    def show(self):
        self.visible = True

    def hide(self):
        self.visible = False

    def destroy(self):
        self.visible = False
        self.events.closed.set()

    def evaluate_js(self, script, callback=None):
        if callback is None:
            assert "gaoCloseState" in script
            return self.state.copy()
        assert "gaoSaveDraftBeforeClose" in script
        self.saves += 1
        if self.save_succeeds:
            self.state["draft"] = False
        callback({"ok": self.save_succeeds})


@pytest.fixture
def desktop(tmp_path):
    service = PortalService(tmp_path / "isolated", browser_probe=lambda: ["edge"])
    app = Desktop(SimpleNamespace(service=service, port=12345))
    app.ready.set()
    app.windows["/"] = Window()
    return app


def test_primary_close_hides_through_explorer_restart_and_preserves_the_view(desktop):
    original = desktop.windows["/"]
    original.state["editing"] = True
    assert desktop._close_main() is False
    assert not original.visible and not desktop.stop.is_set()
    desktop._tray_status(True, None)
    assert desktop.show_main() and original.visible
    desktop._tray_status(False, None)
    assert desktop._close_main() is False
    assert not original.visible and not desktop.stop.is_set()
    desktop._tray_status(True, None)
    assert desktop.show_main() and original.visible
    assert desktop.windows["/"] is original and original.state["editing"]


def test_unavailable_tray_does_not_leave_the_initial_window_unreachable(desktop, monkeypatch):
    original = desktop.windows["/"]
    assert desktop._close_main() is False and not original.visible
    desktop._tray_status(False, None)
    assert desktop.dock_open_requests.get_nowait() == "/"
    assert desktop.show_main()
    assert original.visible
    requested = []
    monkeypatch.setattr(desktop, "request_quit", lambda: requested.append(True))
    assert desktop._close_main() is False and requested == [True]


def test_window_stays_reachable_when_tray_fails_during_the_native_hide(desktop, monkeypatch):
    main = desktop.windows["/"]
    real_hide = main.hide

    def hide_after_registration_failed():
        desktop._tray_status(False, None)
        real_hide()

    monkeypatch.setattr(main, "hide", hide_after_registration_failed)
    assert desktop._close_main() is False
    assert main.visible and not desktop.tray_registered and not desktop.stop.is_set()


def test_cancel_keeps_editors_and_acceptance_saves_draft_before_destroy(desktop, monkeypatch):
    main = desktop.windows["/"]
    main.state["editing"] = True
    mail = desktop.windows["/mail"] = Window(draft=True)
    prompts = []
    decisions = iter((False, True))
    monkeypatch.setattr(desktop, "_exit_prompt", lambda message, *, confirm=False:
                        prompts.append((message, confirm)) or next(decisions))
    desktop._confirm_exit()
    assert main.visible and mail.visible and mail.saves == 0
    assert not desktop.stop.is_set() and not desktop.service.stopping.is_set()
    desktop._confirm_exit()
    assert len(prompts) == 2 and all(confirm for _, confirm in prompts)
    assert "草稿" in prompts[0][0] and "未保存" in prompts[0][0]
    assert mail.saves == 1 and all(window.events.closed.is_set() for window in (mail, main))
    assert desktop.stop.is_set() and desktop.service.stopping.is_set()


def test_busy_view_failed_draft_and_active_submission_keep_the_app_running(desktop, monkeypatch):
    mail = desktop.windows["/mail"] = Window(busy=True, draft=True)
    prompts = []
    monkeypatch.setattr(desktop, "_exit_prompt", lambda message, *, confirm=False:
                        prompts.append(message) or confirm)
    desktop._confirm_exit()
    assert "进行" in prompts[-1] and mail.saves == 0
    mail.state["busy"] = False
    mail.save_succeeds = False
    desktop._confirm_exit()
    assert "未能保存" in prompts[-1] and mail.saves == 1
    with desktop.service.mail_submission("fixture"):
        desktop._confirm_exit()
        assert "正在发送" in prompts[-1]
        assert not desktop.service.begin_shutdown()
    assert not desktop.stop.is_set() and not mail.events.closed.is_set()
    assert desktop.service.begin_shutdown()
    with pytest.raises(AppError, match="正在退出"), desktop.service.mail_submission("later"):
        raise AssertionError("Shutdown must reject a new mail submission")


def test_exit_rechecks_other_windows_after_the_confirmation(desktop, monkeypatch):
    desktop.windows["/"].state["editing"] = True
    mail = desktop.windows["/mail"] = Window()

    def prompt(message, *, confirm=False):
        if confirm:
            mail.state["draft"] = True
            return True
        assert "新的编辑" in message
        return False

    monkeypatch.setattr(desktop, "_exit_prompt", prompt)
    desktop._confirm_exit()
    assert not desktop.stop.is_set() and mail.visible and mail.saves == 0


def test_close_only_mail_window_preserves_dirty_draft_on_failure(desktop, monkeypatch):
    mail = desktop.windows["/mail"] = Window(draft=True)
    prompts = []
    monkeypatch.setattr(desktop, "_exit_prompt", lambda message: prompts.append(message))
    mail.save_succeeds = False
    desktop._finish_mail_close(mail)
    assert "未能保存" in prompts[-1] and mail.visible and mail.saves == 1
    mail.save_succeeds = True
    desktop._finish_mail_close(mail)
    assert not mail.visible and mail.saves == 2 and desktop.windows["/"].visible
    assert not desktop.stop.is_set() and not desktop.service.stopping.is_set()


def test_http_exit_uses_the_existing_desktop_owner(desktop):
    server = PortalServer(desktop.service)
    called = []
    server.quit_desktop = lambda: called.append(True) or True
    try:
        assert server._dispatch("/api/shutdown", {}) == {"ok": True}
        assert called == [True] and not desktop.service.stopping.is_set()
    finally:
        server.httpd.server_close()


def test_active_oauth_commit_protects_account_and_credential_writes(desktop):
    service = desktop.service
    service.mail_oauth.attempts["mail-fixture"] = {"status": "committing"}
    service.mail_oauth.attempts["pending-fixture"] = {"status": "pending"}
    assert service.mail_blocks_exit() and not service.begin_shutdown()
    service.mail_oauth.attempts["mail-fixture"]["status"] = "complete"
    assert not service.mail_blocks_exit() and service.begin_shutdown()
    service.finish_shutdown()
    assert service.mail_oauth.attempts["pending-fixture"]["status"] == "failed"
