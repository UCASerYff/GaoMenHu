"""资料目录、初始化证据和原子替换。

证据放在资料目录旁边的偏好文件里，不放进 library.json。
目录已经存在但没有主库时，不会自动写入示例网站。
"""

import json
import os
import shutil
import threading
import uuid
from pathlib import Path

from .errors import AppError, RecoveryError
from .models import decode_library, encode_library, initial_library, validate_library

INIT_KEY = "GaoMenHu.LibraryInitialization.V1"
PHASES = {"ready", "initializing", "migrating", "writing"}
PENDING_PREFIXES = (
    ".gaomenhu-restore-",
    ".gaomenhu-library-write-",
    ".gaomenhu-library-init-",
)


def default_data_dir():
    if os.name == "nt":
        root = os.environ.get("LOCALAPPDATA") or str(Path.home() / "AppData" / "Local")
    else:
        root = os.environ.get("XDG_DATA_HOME") or str(Path.home() / ".local" / "share")
    return Path(root) / "MenDao"


def preferences_path(directory: Path) -> Path:
    return directory.parent / (directory.name + ".preferences.json")


class Preferences:
    def __init__(self, path: Path):
        self.path = path
        self.data = {}
        self._lock = threading.Lock()
        if path.is_file() and not path.is_symlink():
            try:
                loaded = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError) as exc:
                raise RecoveryError() from exc
            if not isinstance(loaded, dict):
                raise RecoveryError()
            self.data = loaded

    def has_historical(self):
        for key in self.data:
            if key == INIT_KEY:
                continue
            if key.startswith("GaoMenHu.") or key.startswith("MenDao.") or key.startswith("NSWindow Frame MenDao."):
                return True
        return False

    def read_evidence(self):
        value = self.data.get(INIT_KEY)
        if value is None:
            return None
        if not isinstance(value, dict) or value.get("format") != 1 or value.get("phase") not in PHASES:
            raise RecoveryError()
        return value

    def write_evidence(self, phase):
        if phase not in PHASES:
            raise RecoveryError()
        self.set(INIT_KEY, {"format": 1, "phase": phase})
        if self.read_evidence()["phase"] != phase:
            raise RecoveryError()

    def get(self, key, default=None):
        return self.data.get(key, default)

    def set(self, key, value):
        self.update({key: value})

    def update(self, changes):
        with self._lock:
            data = self.data | changes
            self.path.parent.mkdir(parents=True, exist_ok=True)
            temporary = self.path.with_name(self.path.name + f".tmp-{uuid.uuid4().hex}")
            payload = json.dumps(data, ensure_ascii=False, indent=2, sort_keys=True).encode("utf-8")
            try:
                with open(temporary, "wb") as handle:
                    handle.write(payload)
                    handle.flush()
                    os.fsync(handle.fileno())
                os.replace(temporary, self.path)
            finally:
                temporary.unlink(missing_ok=True)
            self.data = data


def _kind(path: Path):
    try:
        exists = path.exists() or path.is_symlink()
    except OSError as exc:
        raise RecoveryError() from exc
    if path.is_symlink():
        raise RecoveryError()
    if not exists:
        return None
    if path.is_dir():
        return "dir"
    if path.is_file():
        return "file"
    raise RecoveryError()


def read_regular(path: Path, limit=30_000_000):
    if _kind(path) != "file":
        raise RecoveryError()
    try:
        data = path.read_bytes()
    except OSError as exc:
        raise RecoveryError() from exc
    if len(data) > limit:
        raise RecoveryError()
    return data


def write_exclusive(path: Path, data: bytes):
    # Windows 默认把 os.open 当成文本文件，会把换行改成 CRLF，读回校验就会失败。
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_BINARY"):
        flags |= os.O_BINARY
    try:
        fd = os.open(str(path), flags, 0o600)
    except OSError as exc:
        raise RecoveryError() from exc
    try:
        view = memoryview(data)
        while view:
            written = os.write(fd, view)
            if written <= 0:
                raise RecoveryError()
            view = view[written:]
        os.fsync(fd)
    except OSError as exc:
        raise RecoveryError() from exc
    finally:
        os.close(fd)


class LibraryStore:
    def __init__(self, directory: Path):
        self.directory = Path(directory)
        self.file = self.directory / "library.json"
        self.preferences = Preferences(preferences_path(self.directory))
        self.access = "unloaded"
        self.baseline = None
        self.library = None
        self.message = ""
        self._last_baseline = None
        self._revision = 0

    @property
    def baseline_identity(self):
        baseline = self.baseline
        if baseline is not self._last_baseline:
            self._last_baseline = baseline
            self._revision += 1
        return self._revision

    def load(self, browsers):
        if self.access == "blocked":
            raise RecoveryError(self.message or "网站资料不可读。")
        try:
            evidence = self.preferences.read_evidence()
            if evidence is not None and evidence["phase"] != "ready":
                raise RecoveryError()
            kind = _kind(self.directory)
            if kind is None:
                if evidence is not None or self.preferences.has_historical():
                    raise RecoveryError()
                return self._initialize(initial_library(browsers))
            if kind != "dir":
                raise RecoveryError()
            self._reject_pending()
            file_kind = _kind(self.file)
            if file_kind is None:
                if self._pristine_empty() and evidence is None and not self.preferences.has_historical():
                    self.access = "uninitialized"
                    self.library = None
                    self.message = "资料目录是空的。确认这是首次使用后，再创建网站资料。"
                    return None
                raise RecoveryError()
            if file_kind != "file":
                raise RecoveryError()
            data = read_regular(self.file)
            library = decode_library(data)
            if evidence is None:
                self.preferences.write_evidence("migrating")
                if read_regular(self.file) != data:
                    raise RecoveryError()
                self.preferences.write_evidence("ready")
            self.baseline = data
            self.library = library
            self.access = "ready"
            self.message = ""
            return library
        except (RecoveryError, AppError) as exc:
            self.access = "blocked"
            self.library = None
            self.message = (
                "网站资料处于恢复保护状态，已停止自动保存。原资料和附件保持不变；"
                "请检查主资料文件及未完成事务，处理后重新启动。\n" + str(exc)
            )
            return None

    def create(self, browsers):
        if self.access == "ready":
            return self.library
        if self.access == "blocked":
            raise RecoveryError(self.message)
        evidence = self.preferences.read_evidence()
        if evidence is not None or self.preferences.has_historical():
            self.access = "blocked"
            raise RecoveryError()
        if _kind(self.directory) is None:
            return self._initialize(initial_library(browsers))
        if not self._pristine_empty():
            self.access = "blocked"
            self.message = "资料目录不是空的，不能创建新的网站资料。"
            raise RecoveryError(self.message)
        return self._initialize(initial_library(browsers))

    def save(self, library):
        cleaned = validate_library(library)
        if self.access != "ready":
            raise RecoveryError(self.message or "网站资料不可写。")
        self._require_writable()
        data = encode_library(cleaned)
        if data == self.baseline:
            self.library = cleaned
            return cleaned
        transaction = self.directory / (".gaomenhu-library-write-" + uuid.uuid4().hex)
        previous = transaction / "previous.json"
        nxt = transaction / "next.json"
        replaced = False
        try:
            self.preferences.write_evidence("writing")
            transaction.mkdir()
            write_exclusive(previous, self.baseline)
            write_exclusive(nxt, data)
            if read_regular(self.file) != self.baseline:
                raise RecoveryError()
            os.replace(nxt, self.file)
            replaced = True
            if read_regular(self.file) != data:
                raise RecoveryError()
            self.preferences.write_evidence("ready")
            shutil.rmtree(transaction, ignore_errors=True)
            self.baseline = data
            self.library = cleaned
            return cleaned
        except Exception:
            if replaced:
                try:
                    if read_regular(self.file) == data and previous.is_file() and read_regular(previous) == self.baseline:
                        os.replace(previous, self.file)
                except (OSError, RecoveryError):
                    pass
            try:
                self.preferences.write_evidence("writing")
            except RecoveryError:
                pass
            self.access = "blocked"
            self.message = "写入网站资料失败，已停止自动保存。请检查未完成事务后重新启动。"
            raise

    def adopt(self, library):
        if self.access != "ready":
            raise RecoveryError()
        self._reject_pending()
        data = read_regular(self.file)
        decoded = decode_library(data)
        if decoded != validate_library(library):
            raise RecoveryError()
        self.baseline = data
        self.library = decoded
        return decoded

    def _initialize(self, library):
        data = encode_library(library)
        self.preferences.write_evidence("initializing")
        self.directory.parent.mkdir(parents=True, exist_ok=True)
        if _kind(self.directory) is None:
            self.directory.mkdir()
        if _kind(self.directory) != "dir":
            raise RecoveryError()
        self._reject_pending()
        if _kind(self.file) is not None:
            raise RecoveryError()
        staged = self.directory / (".gaomenhu-library-init-" + uuid.uuid4().hex)
        try:
            write_exclusive(staged, data)
            try:
                os.replace(staged, self.file)
            except OSError as exc:
                if _kind(self.file) == "file":
                    raise RecoveryError() from exc
                raise
            if read_regular(self.file) != data:
                raise RecoveryError()
            self.preferences.write_evidence("ready")
        except Exception:
            self.access = "blocked"
            raise
        self.baseline = data
        self.library = validate_library(library)
        self.access = "ready"
        self.message = ""
        return self.library

    def _require_writable(self):
        try:
            if self.access != "ready" or self.baseline is None:
                raise RecoveryError()
            evidence = self.preferences.read_evidence()
            if evidence is None or evidence["phase"] != "ready":
                raise RecoveryError()
            if _kind(self.directory) != "dir" or _kind(self.file) != "file":
                raise RecoveryError()
            self._reject_pending()
            if read_regular(self.file) != self.baseline:
                raise RecoveryError()
        except RecoveryError:
            self.access = "blocked"
            raise

    def _reject_pending(self):
        if _kind(self.directory) is None:
            return
        try:
            names = list(os.listdir(self.directory))
        except OSError as exc:
            raise RecoveryError() from exc
        for name in names:
            if name.startswith(PENDING_PREFIXES):
                raise RecoveryError()

    def _pristine_empty(self):
        if _kind(self.directory) != "dir":
            return False
        try:
            return not any(True for _ in self.directory.iterdir())
        except OSError as exc:
            raise RecoveryError() from exc
