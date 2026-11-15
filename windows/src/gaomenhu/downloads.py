"""内置下载队列。崩溃后不自动续传；完成文件不覆盖已有文件。"""

import hashlib
import json
import os
import re
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path

from .errors import AppError
from .models import checked_url, redacted_download_url

ACTIVE_STATES = {"running", "pausing", "verifying", "committing"}
QUEUED_STATES = {"queued"}
TERMINAL = {"completed", "partial", "failed", "cancelled"}
SAFE_NAME = re.compile(r"[^A-Za-z0-9._\-\u4e00-\u9fff]+")


def safe_download_name(name):
    base = name or "download"
    base = SAFE_NAME.sub("_", base).strip(" .")
    if not base or base in {".", ".."} or base.startswith("."):
        base = "download"
    encoded = base.encode("utf-8")
    if len(encoded) > 200:
        base = encoded[:200].decode("utf-8", "ignore") or "download"
    return base


def fingerprint(url):
    return hashlib.sha256(url.encode("utf-8")).hexdigest()


def strong_etag(value):
    if not isinstance(value, str) or len(value) < 2 or not value.startswith('"') or not value.endswith('"'):
        return None
    body = value[1:-1]
    if not body:
        return None
    for char in body:
        code = ord(char)
        if code == 0x21 or 0x23 <= code <= 0x7E or code >= 0x80:
            continue
        return None
    return value


class DownloadStore:
    def __init__(self, root: Path):
        self.root = Path(root)
        self.file = self.root / "downloads.json"
        self.database = None

    def load(self):
        self.root.mkdir(parents=True, exist_ok=True)
        if not self.file.exists():
            self.database = self._empty()
            self.save()
            return self.database
        raw = json.loads(self.file.read_text(encoding="utf-8"))
        payload = raw.get("payload")
        digest = raw.get("sha256")
        if not isinstance(payload, str) or not isinstance(digest, str):
            raise AppError("下载资料校验失败，已停止改写。")
        data = _b64decode(payload)
        if hashlib.sha256(data).hexdigest() != digest:
            raise AppError("下载资料校验失败，已停止改写。")
        self.database = json.loads(data.decode("utf-8"))
        self._validate()
        self.recover()
        self.save()
        return self.database

    def save(self):
        self.database["revision"] = int(self.database.get("revision") or 0) + 1
        data = json.dumps(self.database, ensure_ascii=False, sort_keys=True).encode("utf-8")
        envelope = {"payload": _b64encode(data), "sha256": hashlib.sha256(data).hexdigest()}
        temporary = self.file.with_name(self.file.name + f".tmp-{uuid.uuid4().hex}")
        temporary.write_text(json.dumps(envelope, sort_keys=True), encoding="utf-8")
        os.replace(temporary, self.file)

    def recover(self):
        for item in self.database["items"]:
            if item["state"] in ACTIVE_STATES or item["state"] in QUEUED_STATES:
                item["state"] = "paused"
                item["error"] = "上次退出时任务未完成，已暂停。需要时请继续。"
        for grant in self.database["destinations"]:
            if grant.get("requiresReauthorization"):
                for item in self.database["items"]:
                    if item.get("destinationID") == grant["id"] and item["state"] not in TERMINAL:
                        item["state"] = "waitingForDestination"

    def _empty(self):
        return {
            "schemaVersion": 1,
            "revision": 0,
            "installationID": str(uuid.uuid4()),
            "migrationHistory": [],
            "jobs": [],
            "items": [],
            "destinations": [],
            "settings": {
                "concurrency": 2,
                "speedLimitBytesPerSecond": 0,
                "maxItemBytes": 20 * 1024 * 1024 * 1024,
                "maxStagingBytes": 40 * 1024 * 1024 * 1024,
                "appearance": "system",
            },
        }

    def _validate(self):
        db = self.database
        if db.get("schemaVersion") != 1:
            raise AppError("下载资料版本不受支持。")
        if len(db.get("items") or []) > 5000 or len(db.get("jobs") or []) > 5000:
            raise AppError("下载资料超出容量。")


def _b64encode(data: bytes) -> str:
    import base64
    return base64.b64encode(data).decode("ascii")


def _b64decode(value: str) -> bytes:
    import base64
    return base64.b64decode(value.encode("ascii"))


class DownloadManager:
    def __init__(self, root: Path):
        self.store = DownloadStore(root)
        self.session_authorized = set()
        self.store.load()

    @property
    def database(self):
        return self.store.database

    def add_destination(self, path: Path):
        path = Path(path)
        path.mkdir(parents=True, exist_ok=True)
        if not path.is_dir():
            raise AppError("保存目录无效。")
        for grant in self.database["destinations"]:
            if Path(grant["displayPath"]) == path:
                grant["requiresReauthorization"] = False
                self.store.save()
                return grant
        grant = {
            "id": str(uuid.uuid4()),
            "displayPath": str(path),
            "requiresReauthorization": False,
        }
        self.database["destinations"].append(grant)
        self.store.save()
        return grant

    def prepare(self, urls):
        reviewed = []
        for url in urls:
            checked_url(url)
            parts = _split(url)
            reviewed.append({
                "url": url,
                "displayURL": redacted_download_url(url),
                "requiresPrivacyReview": bool(parts.query or parts.fragment),
                "suggestedName": safe_download_name(Path(parts.path).name or parts.hostname or "download"),
            })
        if not reviewed or len(reviewed) > 32:
            raise AppError("请提供 1 至 32 个下载地址。")
        return reviewed

    def create_jobs(self, urls, destination_id, request_id=None, use_stripped=False, reserved_ids=None):
        if request_id and request_id in set(reserved_ids or []):
            raise AppError("这个请求编号已保留在只读历史中。", "history_identity_reserved")
        if request_id:
            existing = [job for job in self.database["jobs"] if job.get("requestID") == request_id]
            if existing:
                return existing
        grant = next((item for item in self.database["destinations"] if item["id"] == destination_id), None)
        if grant is None:
            raise AppError("请先选择保存目录。")
        if grant.get("requiresReauthorization"):
            raise AppError("保存目录需要重新授权。")
        prepared = self.prepare(urls)
        if len(self.database["items"]) + len(prepared) > 5000:
            raise AppError("下载队列已满。")
        item_ids = []
        now = time.time()
        for entry in prepared:
            source = entry["displayURL"] if use_stripped else entry["url"]
            checked_url(source)
            item_id = str(uuid.uuid4())
            item = {
                "id": item_id,
                "requestID": request_id,
                "destinationID": destination_id,
                "sourceURL": source,
                "sourceFingerprint": fingerprint(source),
                "displayURL": redacted_download_url(source),
                "suggestedName": entry["suggestedName"],
                "stagingName": item_id + ".part",
                "state": "queued",
                "bytesReceived": 0,
                "totalBytes": None,
                "etag": None,
                "partialSHA256": None,
                "attempts": 0,
                "error": None,
                "errorCategory": None,
                "createdAt": now,
                "artifact": None,
            }
            self.database["items"].append(item)
            item_ids.append(item_id)
            self.session_authorized.add(item_id)
        job = {"id": str(uuid.uuid4()), "requestID": request_id, "itemIDs": item_ids, "createdAt": now}
        self.database["jobs"].append(job)
        self.store.save()
        return [job]

    def pause(self, item_id):
        item = self._item(item_id)
        if item["state"] in TERMINAL:
            return item
        item["state"] = "paused"
        self.session_authorized.discard(item_id)
        self.store.save()
        return item

    def resume(self, item_id):
        item = self._item(item_id)
        if item["state"] in {"paused", "waitingForNetwork", "waitingForDestination", "retryScheduled", "failed", "partial", "cancelled"} and not item.get("artifact"):
            item["state"] = "queued"
            item["error"] = None
            item["errorCategory"] = None
            self.session_authorized.add(item_id)
            self.store.save()
            return item
        raise AppError("这个任务现在不能继续。")

    def retry(self, item_id):
        item = self._item(item_id)
        item["attempts"] = 0
        return self.resume(item_id)

    def cancel(self, item_id, remove_partial=False):
        item = self._item(item_id)
        if item["state"] != "completed":
            item["state"] = "cancelled"
        self.session_authorized.discard(item_id)
        if remove_partial:
            self._partial_path(item).unlink(missing_ok=True)
            item["bytesReceived"] = 0
            item["partialSHA256"] = None
            item["etag"] = None
        self.store.save()
        return item

    def run_authorized(self, opener=None):
        ran = []
        for item in list(self.database["items"]):
            if item["id"] in self.session_authorized and item["state"] == "queued":
                self._transfer(item, opener=opener)
                ran.append(item["id"])
        return ran

    def _transfer(self, item, opener=None):
        if item["id"] not in self.session_authorized:
            return item
        item["state"] = "running"
        item["attempts"] = int(item.get("attempts") or 0) + 1
        self.store.save()
        partial = self._partial_path(item)
        partial.parent.mkdir(parents=True, exist_ok=True)
        offset = partial.stat().st_size if partial.exists() else 0
        if item.get("partialSHA256") and offset:
            digest = hashlib.sha256(partial.read_bytes()[:offset]).hexdigest()
            if digest != item["partialSHA256"]:
                item["state"] = "partial"
                item["errorCategory"] = "integrity_failure"
                item["error"] = "已下载片段的摘要不一致。"
                self.session_authorized.discard(item["id"])
                self.store.save()
                return item
        request = urllib.request.Request(item["sourceURL"], method="GET")
        request.add_header("Accept-Encoding", "identity")
        if offset and item.get("etag"):
            request.add_header("Range", f"bytes={offset}-")
            request.add_header("If-Range", item["etag"])
        try:
            response = (opener or urllib.request.urlopen)(request, timeout=60)
        except urllib.error.HTTPError as exc:
            return self._fail_http(item, exc.code)
        except Exception:
            item["state"] = "waitingForNetwork"
            item["errorCategory"] = "network_unavailable"
            item["error"] = "网络不可用，已停止。恢复网络后可以继续。"
            self.session_authorized.discard(item["id"])
            self.store.save()
            return item
        with response:
            status = getattr(response, "status", None) or response.getcode()
            etag = strong_etag(response.headers.get("ETag"))
            if offset and status != 206:
                partial.unlink(missing_ok=True)
                offset = 0
            if status not in (200, 206):
                return self._fail_http(item, status)
            mode = "ab" if status == 206 and offset else "wb"
            if mode == "wb":
                offset = 0
            hasher = hashlib.sha256()
            if offset and partial.exists():
                hasher.update(partial.read_bytes()[:offset])
            received = offset
            limit = int(self.database["settings"]["maxItemBytes"])
            with open(partial, mode) as handle:
                while True:
                    chunk = response.read(64 * 1024)
                    if not chunk:
                        break
                    received += len(chunk)
                    if received > limit:
                        item["state"] = "failed"
                        item["errorCategory"] = "permanent_http"
                        item["error"] = "文件超过允许的大小。"
                        self.session_authorized.discard(item["id"])
                        self.store.save()
                        return item
                    handle.write(chunk)
                    hasher.update(chunk)
                handle.flush()
                os.fsync(handle.fileno())
            item["bytesReceived"] = received
            item["etag"] = etag
            item["partialSHA256"] = hasher.hexdigest()
            item["state"] = "verifying"
            self.store.save()
            file_hash = hashlib.sha256(partial.read_bytes()).hexdigest()
            if file_hash != item["partialSHA256"]:
                item["state"] = "partial"
                item["errorCategory"] = "integrity_failure"
                item["error"] = "文件摘要不一致。"
                self.session_authorized.discard(item["id"])
                self.store.save()
                return item
            item["state"] = "committing"
            self.store.save()
            published = self._commit(item, partial, file_hash, received)
            item["artifact"] = published
            item["state"] = "completed"
            item["error"] = None
            item["errorCategory"] = None
            self.session_authorized.discard(item["id"])
            self.store.save()
            return item

    def _commit(self, item, partial: Path, digest, size):
        grant = next(entry for entry in self.database["destinations"] if entry["id"] == item["destinationID"])
        directory = Path(grant["displayPath"])
        directory.mkdir(parents=True, exist_ok=True)
        candidate = directory / item["suggestedName"]
        chosen = candidate
        stem = candidate.stem
        suffix = candidate.suffix
        for index in range(1, 1001):
            if not chosen.exists():
                break
            chosen = directory / f"{stem} ({index}){suffix}"
        else:
            raise AppError("目标目录里同名文件过多。")
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        if hasattr(os, "O_BINARY"):
            flags |= os.O_BINARY
        fd = os.open(str(chosen), flags, 0o600)
        try:
            with open(partial, "rb") as source, os.fdopen(fd, "wb") as target:
                while True:
                    chunk = source.read(1024 * 1024)
                    if not chunk:
                        break
                    target.write(chunk)
                target.flush()
                os.fsync(target.fileno())
        except Exception:
            try:
                chosen.unlink()
            except OSError:
                pass
            raise
        written = hashlib.sha256(chosen.read_bytes()).hexdigest()
        if written != digest or chosen.stat().st_size != size:
            chosen.unlink(missing_ok=True)
            raise AppError("写入后的文件摘要不一致，没有替换目标目录里的文件。")
        partial.unlink(missing_ok=True)
        return {"fileName": chosen.name, "byteCount": size, "sha256": digest, "path": str(chosen)}

    def _fail_http(self, item, status):
        if status in (401, 403, 404):
            item["state"] = "failed"
            item["errorCategory"] = "permanent_http"
        elif status == 416 or status >= 500 or status == 429:
            item["state"] = "retryScheduled"
            item["errorCategory"] = "server_retry"
        else:
            item["state"] = "failed"
            item["errorCategory"] = "permanent_http"
        item["error"] = f"服务器返回 {status}。"
        self.session_authorized.discard(item["id"])
        self.store.save()
        return item

    def _item(self, item_id):
        item = next((entry for entry in self.database["items"] if entry["id"] == item_id), None)
        if item is None:
            raise AppError("下载任务不存在。")
        return item

    def _partial_path(self, item):
        return self.store.root / "staging" / item["stagingName"]


def _split(url):
    from urllib.parse import urlsplit
    return urlsplit(url)


def migration_status(source: Path, destination: Path):
    source_file = Path(source) / "downloads.json"
    dest_file = Path(destination) / "downloads.json"
    if dest_file.exists():
        return "alreadyPresent"
    if not source_file.exists():
        return "newInstallation"
    return "requiresMigration"


def migrate_downloads(source: Path, destination: Path):
    """只在目标还没有下载库时复制。已有库一律不覆盖。"""
    status = migration_status(source, destination)
    if status == "alreadyPresent":
        raise AppError("目标已有下载资料，没有覆盖。")
    if status == "newInstallation":
        raise AppError("没有可迁移的下载资料。")
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    raw = json.loads((Path(source) / "downloads.json").read_text(encoding="utf-8"))
    data = _b64decode(raw["payload"])
    if hashlib.sha256(data).hexdigest() != raw["sha256"]:
        raise AppError("来源下载资料校验失败，没有写入目标。")
    database = json.loads(data.decode("utf-8"))
    for grant in database.get("destinations") or []:
        grant["requiresReauthorization"] = True
    for item in database.get("items") or []:
        if item.get("state") not in TERMINAL:
            item["state"] = "waitingForDestination"
            item["error"] = "目录已迁移，请重新授权保存位置。"
    database.setdefault("migrationHistory", []).append("portal-download-migration")
    encoded = json.dumps(database, ensure_ascii=False, sort_keys=True).encode("utf-8")
    envelope = {"payload": _b64encode(encoded), "sha256": hashlib.sha256(encoded).hexdigest()}
    target = destination / "downloads.json"
    if target.exists():
        raise AppError("目标已有下载资料，没有覆盖。")
    temporary = target.with_name(target.name + f".tmp-{uuid.uuid4().hex}")
    temporary.write_text(json.dumps(envelope, sort_keys=True), encoding="utf-8")
    os.replace(temporary, target)
    receipt = destination / "MigrationEvidence"
    receipt.mkdir(exist_ok=True)
    (receipt / "receipt.json").write_text(json.dumps({
        "installationID": database.get("installationID"),
        "requiresReauthorization": True,
        "overwrote": False,
    }, sort_keys=True), encoding="utf-8")
    return database
