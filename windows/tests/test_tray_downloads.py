"""The tray reports only current download workers and measured transfer progress."""

from types import SimpleNamespace

from gaomenhu.downloads import DownloadManager
from gaomenhu.floating import FloatingPanel


def test_tray_counts_active_owned_items_and_weights_progress_by_bytes(tmp_path):
    manager = DownloadManager(tmp_path / "isolated")
    manager.database["items"] = [
        {"id": "running", "state": "running", "bytesReceived": 15, "totalBytes": 100},
        {"id": "verifying", "state": "verifying", "bytesReceived": 300, "totalBytes": 300},
        {"id": "paused", "state": "paused", "bytesReceived": 50, "totalBytes": 100},
        {"id": "queued", "state": "queued", "bytesReceived": 0, "totalBytes": None},
        {"id": "unowned", "state": "running", "bytesReceived": 10, "totalBytes": 100},
    ]
    manager.workers = dict.fromkeys(("running", "verifying", "paused", "queued"))
    assert manager.tray_progress() == (2, 78)
    manager.database["items"][0]["totalBytes"] = None
    assert manager.tray_progress() == (2, None)
    manager.workers.clear()
    assert manager.tray_progress() == (0, None)


def test_tray_updates_existing_icon_when_activity_changes_and_keeps_idle_label():
    changes = []
    results = iter(((2, None), None, (2, None), (2, 40), (0, None)))
    panel = SimpleNamespace(tray_download_summary="", native=SimpleNamespace(set_tray_tip=changes.append),
                            service=SimpleNamespace(downloads=SimpleNamespace(tray_progress=lambda: next(results))))
    for _ in range(5):
        FloatingPanel.sync_tray_download(panel)
    assert changes == ["搞门户 · 2 项下载进行中", "搞门户 · 2 项下载进行中 · 已传输 40%", "搞门户"]
