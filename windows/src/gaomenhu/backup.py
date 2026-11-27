"""完整资料 ZIP。只允许 manifest.json 和 library.json，不打包密码。"""

import hashlib
import io
import json
import os
import re
import stat
import time
import uuid
import zipfile

from . import APP_ID, MARKETING_VERSION
from .errors import AppError
from .models import MAX_LIBRARY_BYTES, decode_library, validate_library

MAX_ARCHIVE_BYTES = 331_000_000
VERSION_RE = re.compile(r"^[1-9][0-9]{0,3}\.[0-9]{2}$")


def _digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _compact(value) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")


def _version_ok(value):
    return isinstance(value, str) and VERSION_RE.match(value) is not None


def _version_leq(left, right):
    def parts(value):
        major, minor = value.split(".")
        return int(major), int(minor)
    return parts(left) <= parts(right)


def export_zip(library, version=MARKETING_VERSION):
    if not _version_ok(version):
        raise AppError("导出参数无效。")
    library = validate_library(library)
    library_bytes = json.dumps(library, ensure_ascii=False, indent=2, sort_keys=True).encode("utf-8") + b"\n"
    if len(library_bytes) > MAX_LIBRARY_BYTES:
        raise AppError("资料过大：单个文件最多 30 MB。")
    manifest = {
        "appID": APP_ID,
        "format": 2,
        "version": version,
        "createdAt": time.time(),
        "files": {"library.json": _digest(library_bytes)},
    }
    manifest_bytes = _compact(manifest)
    return _make_zip({"library.json": library_bytes, "manifest.json": manifest_bytes})


def read_zip(archive: bytes, current_version=MARKETING_VERSION):
    if not _version_ok(current_version):
        raise AppError("当前应用版本无效。")
    if not isinstance(archive, (bytes, bytearray)) or len(archive) > MAX_ARCHIVE_BYTES:
        raise AppError("备份文件不是普通文件或超过大小限制。")
    try:
        with zipfile.ZipFile(io.BytesIO(archive)) as handle:
            infos = handle.infolist()
            names = [info.filename for info in infos]
            if sorted(names) != ["library.json", "manifest.json"]:
                raise AppError("资料包必须只包含清单和当前网站资料。")
            limits = {"library.json": MAX_LIBRARY_BYTES, "manifest.json": 100_000}
            if any(info.file_size > limits[info.filename] or info.is_dir() or info.flag_bits & 1
                   or stat.S_IFMT(info.external_attr >> 16) not in (0, stat.S_IFREG)
                   or info.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED)
                   for info in infos):
                raise AppError("资料包包含不支持的条目或超过大小限制。")
            files = {}
            for name in names:
                with handle.open(name) as entry:
                    files[name] = entry.read(limits[name] + 1)
    except (zipfile.BadZipFile, RuntimeError) as exc:
        raise AppError("当前资料 ZIP 格式无效或已损坏。") from exc
    except AppError:
        raise
    manifest_data = files["manifest.json"]
    library_data = files["library.json"]
    if len(manifest_data) > 100_000 or len(library_data) > MAX_LIBRARY_BYTES:
        raise AppError("资料包必须只包含清单和当前网站资料。")
    try:
        manifest = json.loads(manifest_data.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError) as exc:
        raise AppError("这不是兼容的搞门户当前资料包；请确认应用和版本。") from exc
    if not isinstance(manifest, dict):
        raise AppError("这不是兼容的搞门户当前资料包；请确认应用和版本。")
    created = manifest.get("createdAt")
    if manifest.get("appID") != APP_ID or manifest.get("format") != 2 or not _version_ok(manifest.get("version")):
        raise AppError("这不是兼容的搞门户当前资料包；请确认应用和版本。")
    if not _version_leq(manifest["version"], current_version):
        raise AppError("这不是兼容的搞门户当前资料包；请确认应用和版本。")
    if not isinstance(created, (int, float)) or created <= 0:
        raise AppError("这不是兼容的搞门户当前资料包；请确认应用和版本。")
    if manifest.get("files") != {"library.json": _digest(library_data)}:
        raise AppError("资料包校验失败，资料可能不完整或已被修改。")
    library = decode_library(library_data)
    return {"manifest": manifest, "library": library, "snapshotCount": 0}


def write_zip_file(destination, library, version=MARKETING_VERSION):
    payload = export_zip(library, version)
    destination.parent.mkdir(parents=True, exist_ok=True)
    sibling = destination.parent / (".gaomenhu-backup-" + uuid.uuid4().hex + ".zip")
    try:
        with open(sibling, "wb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        if _digest(sibling.read_bytes()) != _digest(payload):
            raise AppError("写入后的备份校验失败，原备份未替换。")
        os.replace(sibling, destination)
    finally:
        if sibling.exists():
            try:
                sibling.unlink()
            except OSError:
                pass
    return {"fileCount": 2, "zipBytes": len(payload), "snapshotCount": 0}


def _make_zip(files):
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", compression=zipfile.ZIP_DEFLATED) as handle:
        for name in sorted(files):
            handle.writestr(name, files[name])
    return buffer.getvalue()
