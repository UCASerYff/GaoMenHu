"""Cover DevToolsActivePort readiness without launching a browser."""

from types import SimpleNamespace
from unittest.mock import Mock

import pytest

import test_launcher_ui as launcher_ui


@pytest.mark.parametrize("launcher_return_code", [None, 0])
def test_waits_for_readable_file_with_complete_port_and_path(monkeypatch, launcher_return_code):
    endpoint = "/devtools/browser/002f263a-7937-4f1e-98ec-9b227d9714e4"
    reads = [FileNotFoundError(), PermissionError(), "", "9222\n", f"9222\n{endpoint[:-3]}",
             f"65536\n{endpoint}", f"9222\n{endpoint}"]
    debug_port = SimpleNamespace(read_text=Mock(side_effect=reads))
    process = SimpleNamespace(poll=lambda: launcher_return_code)
    monkeypatch.setattr(launcher_ui, "time", SimpleNamespace(monotonic=lambda: 0, sleep=lambda _: None))

    assert launcher_ui.wait_for_devtools_port(process, debug_port, None) == 9222
    assert debug_port.read_text.call_count == len(reads)


@pytest.mark.parametrize("return_code", [None, 1])
def test_stops_at_the_deadline_or_browser_exit_and_reports_the_log(tmp_path, monkeypatch, return_code):
    debug_port = SimpleNamespace(read_text=Mock(side_effect=PermissionError()))
    output = tmp_path / "chromium.log"
    output.write_text("isolated Chromium startup log", encoding="utf-8")
    process = SimpleNamespace(poll=lambda: return_code)
    times = iter([0, 0, 12, 12])
    monkeypatch.setattr(launcher_ui, "time", SimpleNamespace(monotonic=lambda: next(times), sleep=lambda _: None))

    with pytest.raises(AssertionError, match="isolated Chromium startup log"):
        launcher_ui.wait_for_devtools_port(process, debug_port, output)
    assert debug_port.read_text.call_count == (1 if return_code is None else 0)
