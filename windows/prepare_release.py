"""Prepare version metadata and app artwork for the Windows installer."""

import json
import shutil
import struct
import sys
from pathlib import Path

from PIL import Image

WINDOWS = Path(__file__).resolve().parent
sys.path.insert(0, str(WINDOWS / "src"))
from gaomenhu import MARKETING_VERSION, NATIVE_HOST_NAME, WINDOWS_BUILD
from gaomenhu.native import native_manifest


def main():
    if sys.platform != "win32" or struct.calcsize("P") != 8:
        raise SystemExit("Use x64 Python on Windows to build this installer")
    version_source = (WINDOWS.parent / "VERSION").read_text(encoding="utf-8").strip()
    if MARKETING_VERSION != version_source:
        raise SystemExit("Windows release version differs from VERSION")
    version = (*map(int, MARKETING_VERSION.split(".")), 0, int(WINDOWS_BUILD))
    file_version = ".".join(str(value) for value in version)
    release_assets = WINDOWS / "build" / "release-assets"
    source_icon = WINDOWS.parent / "Assets" / "AppIcon.png"
    shutil.copyfile(source_icon, release_assets / "Mark.png")
    with Image.open(source_icon) as image:
        image.save(release_assets / "GaoMenHu.ico", sizes=[(size, size) for size in (16, 24, 32, 48, 64, 128, 256)])
    manifest = native_manifest("GaoMenHu-bridge.exe")
    manifest["path"] = "GaoMenHu-bridge.exe"
    (release_assets / (NATIVE_HOST_NAME + ".json")).write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    (release_assets / "version.txt").write_text(file_version, encoding="ascii")
    (release_assets / "version-info.txt").write_text(f"""VSVersionInfo(
  ffi=FixedFileInfo(filevers={version}, prodvers={version}, mask=0x3f, flags=0x0,
                    OS=0x40004, fileType=0x1, subtype=0x0, date=(0, 0)),
  kids=[StringFileInfo([StringTable('080404B0', [
    StringStruct('CompanyName', '搞系列'), StringStruct('ProductName', '搞门户'),
    StringStruct('FileDescription', '搞门户'), StringStruct('FileVersion', '{file_version}'),
    StringStruct('ProductVersion', '{MARKETING_VERSION}')])]), VarFileInfo([VarStruct('Translation', [2052, 1200])])])
""", encoding="utf-8")


if __name__ == "__main__":
    main()
