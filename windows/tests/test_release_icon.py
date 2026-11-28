import runpy
from pathlib import Path

from PIL import Image


def test_release_icon_has_exact_windows_sizes_and_preserves_rounded_artwork(tmp_path):
    windows = Path(__file__).resolve().parents[1]
    source = windows.parent / "Assets" / "AppIcon.png"
    destination = tmp_path / "GaoMenHu.ico"
    prepare_release = runpy.run_path(str(windows / "prepare_release.py"))
    prepare_release["write_windows_icon"](source, destination)

    scales = (100, 125, 150, 175, 200)
    expected = {dip * scale // 100 for dip in (16, 24, 32, 48) for scale in scales}
    expected.update((80, 128, 256))
    with Image.open(destination) as icon:
        assert icon.ico.sizes() == {(size, size) for size in expected}
        for size in sorted(expected):
            frame = icon.ico.getimage((size, size))
            assert frame.size == (size, size)
            assert frame.mode == "RGBA"
            alpha = frame.getchannel("A")
            corners = ((0, 0), (size - 1, 0), (0, size - 1), (size - 1, size - 1))
            # Lanczos can leave less than 2% opacity at the smallest rounded corners.
            assert all(alpha.getpixel(point) <= 5 for point in corners)
            assert alpha.getpixel((size // 2, size // 2)) >= 240
            assert any(min(red, green, blue) >= 128 and opacity >= 240 for red, green, blue, opacity in frame.getdata())

        for size in (24, 48, 72, 256):
            alpha = icon.ico.getimage((size, size)).getchannel("A")
            occupied = alpha.point(lambda value: 255 if value >= 128 else 0)
            assert occupied.getbbox() == (0, 0, size, size)
            if size == 48:
                assert 0.95 <= occupied.histogram()[255] / (size * size) <= 0.98
