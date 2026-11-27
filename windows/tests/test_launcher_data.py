import base64
import copy
import io
import json
import zipfile

import pytest
from PIL import Image

from gaomenhu.backup import export_zip, read_zip
from gaomenhu.errors import AppError
from gaomenhu.icons import IconLinks, decode_image, manifest_icons, safe_url, website_root
from gaomenhu.service import PortalService


def test_package_preview_and_bookmarks_only_apply_after_confirmation(tmp_path):
    service = PortalService(tmp_path / "MenDao", browser_probe=lambda: ["chrome"])
    library = copy.deepcopy(service.store.library)
    assert read_zip(export_zip(library))["library"] == library
    backup = service.preview_backup(library, "restore")
    assert backup["preview"] == {
        "sites": 6, "folders": 0, "duplicates": 6,
        "message": "恢复排列、场景和设置。当前资料独有的网站将保留为移除入口。",
    }
    assert service.store.library == library

    bookmarks = tmp_path / "AppData/Local/Google/Chrome/User Data/Profile 2/Bookmarks"
    bookmarks.parent.mkdir(parents=True)
    bookmarks.write_text(json.dumps({"roots": {
        "bookmark_bar": {"type": "folder", "name": "收藏栏", "children": [
            {"type": "url", "name": "备份中的网址", "url": library["sites"][0]["url"]},
            {"type": "folder", "name": "研究", "children": [
                {"type": "url", "name": "隔离网站", "url": "https://isolated.example.test"}
            ]},
        ]},
        "other": {"type": "folder", "name": "其他", "children": [
            {"type": "url", "name": "其他网站", "url": "https://other.example.test"},
        ]},
    }}), encoding="utf-8")
    sources = service.bookmark_sources(tmp_path)
    assert [source["id"] for source in sources] == ["chrome:Profile 2"]
    imported = service.preview_bookmarks(tmp_path, sources[0]["id"])
    details = imported["preview"]
    assert (details["sites"], details["folders"], details["duplicates"], details["folderNames"]) == (1, 1, 1, ["研究"])
    assert service.store.library == library
    service.apply_pending(imported["token"], "bookmarks")
    names = {site["name"] for site in service.store.library["sites"]}
    assert "隔离网站" in names and "其他网站" not in names
    with pytest.raises(AppError):
        service.apply_pending(backup["token"], "backup")


def test_zip_rejects_nonregular_manifest_entry(tmp_path):
    service = PortalService(tmp_path / "MenDao", browser_probe=lambda: ["chrome"])
    supplied = io.BytesIO()
    with zipfile.ZipFile(supplied, "w") as package:
        symlink = zipfile.ZipInfo("manifest.json")
        symlink.create_system = 3
        symlink.external_attr = 0o120777 << 16
        package.writestr(symlink, "outside.json")
        package.writestr("library.json", json.dumps(service.store.library))
    with pytest.raises(AppError, match="不支持的条目"):
        read_zip(supplied.getvalue())


def test_edit_existing_account_replaces_password_after_library_commit(tmp_path, monkeypatch):
    service = PortalService(tmp_path / "MenDao", browser_probe=lambda: ["chrome"])
    site = copy.deepcopy(service.store.library["sites"][0])
    site["accounts"] = [{"id": "test-credential-id", "label": "Fixture", "username": "fixture@example.test",
                         "hasPassword": False, "loginHosts": ["Login.Example.Test"]}]
    site["defaultAccount"] = "test-credential-id"
    service.save_site({"site": site, "passwords": [{"id": "test-credential-id", "password": "first-fixture"}]})
    assert not service.vault.is_unlocked(service.clock())
    service.unlock()
    current = copy.deepcopy(service._site(site["id"]))
    assert current["accounts"][0]["loginHosts"] == ["login.example.test"]
    assert "first-fixture" not in service.store.file.read_text(encoding="utf-8")

    invalid = copy.deepcopy(current)
    invalid["defaultBrowser"] = "missing"
    with pytest.raises(AppError):
        service.save_site({"site": invalid, "passwords": [{"id": "test-credential-id", "password": "other-fixture"}]})
    assert service.vault.read("test-credential-id", service.clock()) == "first-fixture"

    with monkeypatch.context() as patch:
        def reject_write(_library):
            raise AppError("write rejected")
        patch.setattr(service.store, "save", reject_write)
        with pytest.raises(AppError, match="write rejected"):
            service.save_site({"site": current, "passwords": [{"id": "test-credential-id", "password": "other-fixture"}]})
        assert service.vault.cache == {"test-credential-id": "first-fixture"}

    service.save_site({"site": current, "passwords": [{"id": "test-credential-id", "password": "updated-fixture"}]})
    current = service._site(site["id"])
    replacement = current["defaultAccount"]
    assert replacement != "test-credential-id"
    assert service.vault.read(replacement, service.clock()) == "updated-fixture"
    with pytest.raises(AppError):
        service.vault.read("test-credential-id", service.clock())
    assert current["accounts"][0]["hasPassword"]


def test_website_icons_sanitize_urls_and_measure_real_pixels():
    root = website_root("http://Example.Test:80/private/path?token=fixture#anchor")
    assert root == "https://example.test/"
    assert safe_url("http://example.test/low.png", root) is None
    assert safe_url("https://user:pass@example.test/low.png", root) is None
    assert safe_url("/safe.png#unneeded", root) == "https://example.test/safe.png"
    parser = IconLinks(root)
    parser.feed('<script><link rel="icon" href="hidden.png"></script>'
                '<link rel="icon" href="large.png" sizes="64x64 192x192">'
                '<link rel="manifest" href="icons.webmanifest">')
    assert parser.icons == {"https://example.test/large.png": 192}
    assert parser.manifests == ["https://example.test/icons.webmanifest"]
    assert manifest_icons(b'{"icons":[{"src":"icon.png","sizes":"512x512"}]}', parser.manifests[0]) == [
        ("https://example.test/icon.png", 512),
    ]
    buf = io.BytesIO()
    Image.new("RGB", (512, 384)).save(buf, format="PNG")
    icon, original_pixels = decode_image(buf.getvalue())
    assert original_pixels == 384
    raster = Image.open(io.BytesIO(base64.b64decode(icon.split(",")[1])))
    assert raster.size == (256, 192)
