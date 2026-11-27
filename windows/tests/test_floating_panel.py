import json
from copy import deepcopy
from queue import SimpleQueue
from types import SimpleNamespace

import pytest

from gaomenhu.errors import AppError
from gaomenhu.floating import FloatingPanel, launch_floating_site
from gaomenhu.floating_geometry import (
    PointerTiming, Rect, Screen, panel_frame, panel_size, restore_anchor, save_anchor, screen_at, snap_frame, visible_rows,
)
from gaomenhu.search import floating_sites
from gaomenhu.service import PortalService


def test_edge_geometry_uses_physical_screen_for_selection_and_preserves_taskbar():
    primary = Screen("primary", Rect(0, 0, 2560, 1600), Rect(0, 0, 2560, 1540), 144)
    secondary = Screen("secondary", Rect(-1920, 0, 1920, 1080), Rect(-1880, 0, 1880, 1080))
    assert screen_at([primary, secondary], (-1919, 1)) == secondary
    assert secondary.bounds.x == -1880
    assert Screen("thin", Rect(0, 0, 1920, 1080), Rect(6, 0, 1914, 1080)).bounds.x == 0

    initial_screen, anchor = restore_anchor([primary, secondary], None)
    assert initial_screen == primary
    assert panel_frame(primary, anchor, "right", False, 0) == Rect(2530, 144, 30, 156)
    assert panel_frame(primary, anchor, "right", True, 11) == Rect(2014, 144, 546, 690)
    assert panel_frame(primary, anchor, "left", True, 0) == Rect(0, 144, 546, 234)
    assert panel_frame(primary, (1000, 1500), "none", True, 1).bottom == primary.work.bottom

    within = Rect(primary.bounds.right - 546 - 48, 144, 546, 234)
    outside = Rect(within.x - 1, within.y, within.width, within.height)
    assert snap_frame(primary, within)[1] == "right"
    assert snap_frame(primary, outside) == (outside, "none")


def test_saved_anchor_preserves_dips_after_a_monitor_and_dpi_change():
    first = Screen("side", Rect(-1600, 0, 1600, 1000), Rect(-1550, 0, 1550, 1000), 96)
    dragged = Rect(-1390, 200, 364, 230)
    saved = save_anchor(first, dragged, "none")
    moved = Screen("side", Rect(2200, 0, 1600, 1000), Rect(2250, 0, 1550, 1000), 120)
    assert restore_anchor([moved], saved) == (moved, (2450, 250))
    assert restore_anchor([moved], {**saved, "screen": "missing"}) == (moved, (3775, 120))
    for dpi in (96, 120, 144, 168, 192):
        screen = Screen("scaled", moved.physical, moved.work, dpi)
        assert visible_rows(screen, panel_size(screen, True, 8)[1]) == 8


def test_hold_hover_outside_click_and_protected_interaction():
    timing = PointerTiming()

    def tick(now, expanded=False, inside=True, buttons=0, outside_press=False, protected=False):
        return timing.tick(now, expanded=expanded, inside=inside, buttons=buttons,
                           outside_press=outside_press, protected=protected)

    assert tick(1.0) is None
    assert tick(1.44) is None
    assert tick(1.46) is True
    timing.transition(True, 1.46)
    assert tick(2.1, expanded=True, inside=False, protected=True) is None
    assert tick(2.8, expanded=True, inside=False) is None
    assert tick(2.94, expanded=True, inside=False) is None
    assert tick(2.96, expanded=True, inside=False) is False
    assert tick(3.0, expanded=True, inside=False, outside_press=True, buttons=1) is False
    timing.transition(False, 3.0)
    assert tick(4.0) is None
    assert tick(4.5) is None
    assert tick(4.6, inside=False) is None
    assert tick(4.7) is None
    assert tick(5.16) is True


def test_collects_all_search_results_without_adding_archived_sites_or_account_names():
    sites = [{"id": str(index), "name": "飞书", "url": "https://example.test", "aliases": "team",
              "accounts": [{"username": "only-user"}]} for index in range(11)]
    library = {"sites": sites, "tiles": [{"kind": "folder", "children": [str(index) for index in range(10)]}]}
    assert [site["id"] for site in floating_sites(library, "feishu team")] == [str(index) for index in range(10)]
    assert len(floating_sites(library, "")) == 8
    assert floating_sites(library, "only-user") == []


def test_floating_settings_migrate_and_reset_without_rewriting_website_data(tmp_path):
    location = tmp_path / "MenDao"
    service = PortalService(location, browser_probe=lambda: ["edge"])
    library = (location / "library.json").read_bytes()
    service.store.preferences.set("GaoMenHu.Floating.Dock", "free")
    service.store.preferences.set("GaoMenHu.Floating.Enabled", False)
    anchor = {"screen": "existing", "x": 32, "top": 123}
    assert service.floating_preferences() == {"dock": "none", "enabled": False, "anchor": None}
    assert service.set_floating({"dock": "left"}, anchor=anchor)["enabled"] is False
    restored = PortalService(location, browser_probe=lambda: ["edge"])
    assert restored.floating_preferences() == {"dock": "left", "enabled": False, "anchor": anchor}
    assert restored.set_floating({"reset": True}) == {"dock": "right", "enabled": True, "anchor": None}
    prefs = json.loads(restored.store.preferences.path.read_text(encoding="utf-8"))
    assert prefs["GaoMenHu.LibraryInitialization.V1"]["phase"] == "ready"
    assert (location / "library.json").read_bytes() == library


def test_floating_controls_do_not_turn_an_empty_library_into_historical_data(tmp_path):
    location = tmp_path / "MenDao"
    location.mkdir()
    service = PortalService(location, browser_probe=lambda: ["edge"])
    assert service.set_floating({"enabled": False})["enabled"] is False
    assert not service.store.preferences.path.exists()
    assert service.create_library()["access"] == "ready"
    assert PortalService(location, browser_probe=lambda: ["edge"]).floating_preferences()["enabled"] is False


@pytest.mark.parametrize("approve", [False, True])
def test_floating_launch_requires_explicit_confirmation_to_retry_unlock(approve):
    prompts, attempts = [], []
    site = {"name": "Fixture"}
    panel = SimpleNamespace(completions=SimpleQueue(), launching=True, status="", redraw=lambda: None,
                            confirm_unlock=lambda name: prompts.append(name) or approve,
                            submit_launch=lambda site, browser, **fields: attempts.append((site, browser, fields)))
    panel.completions.put((site, "edge", False, AppError("已锁定", "vault_locked")))
    FloatingPanel.finish_launch(panel)
    assert prompts == ["Fixture"]
    assert panel.launching is approve
    if approve:
        assert attempts == [(site, "edge", {"authorize": True})]
    else:
        assert attempts == [] and panel.status == "已取消解锁。"


def test_floating_launch_rechecks_login_target_after_confirmation(tmp_path):
    launches = []
    service = PortalService(tmp_path / "MenDao", browser_probe=lambda: ["edge"], launcher=lambda *args: launches.append(args))
    site = deepcopy(service.store.library["sites"][0])
    site["accounts"] = [{"id": "fixture", "label": "Test", "username": "fixture", "loginHosts": [], "hasPassword": True}]
    site["defaultAccount"] = "fixture"
    service.save_site({"site": site, "passwords": [{"id": "fixture", "password": "test-only"}]})
    site = deepcopy(service._site(site["id"]))
    service.vault.lock()
    with pytest.raises(AppError) as rejection:
        launch_floating_site(service, site, "edge")
    assert rejection.value.code == "vault_locked"
    assert not service.vault.is_unlocked(service.clock()) and launches == []

    service.save_site({"site": {**site, "url": "https://changed.example.test/"}})
    with pytest.raises(AppError, match="网站配置已变化"):
        launch_floating_site(service, site, "edge", authorize=True)
    assert not service.vault.is_unlocked(service.clock()) and launches == []

    launch_floating_site(service, service._site(site["id"]), "edge", authorize=True)
    assert service.vault.is_unlocked(service.clock())
    assert launches == [("edge", None)]
    service.browser_session.launches.clear()
