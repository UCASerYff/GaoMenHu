"""内置下载队列。崩溃后不自动续传；完成文件不覆盖已有文件。"""

import hashlib
import json
import os
import re
import shutil
import threading
import time
import urllib.error
import urllib.request
import uuid
from email.message import Message
from pathlib import Path
from urllib.parse import unquote

from .errors import AppError
from .models import checked_url, redacted_download_url

ACTIVE_STATES = {"running", "pausing", "verifying", "committing"}
QUEUED_STATES = {"queued"}
TERMINAL = {"completed", "partial", "failed", "cancelled"}
SAFE_NAME = re.compile(r'[<>:"/\\|?*\x00-\x1f\x7f]+')
RESERVED_NAME = re.compile(r"^(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)", re.I)
CONTENT_RANGE = re.compile(r"bytes (\d+)-(\d+)/(\d+)")
GIB = 1024 ** 3


def safe_download_name(name):
    base = name or "download"
    base = SAFE_NAME.sub("_", base).strip(" .")
    if not base or base in {".", ".."} or base.startswith("."):
        base = "download"
    if RESERVED_NAME.match(base):
        base = "_" + base
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


def file_digest(path):
    with path.open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def directory_identity(path):
    if not path.is_absolute() or not path.is_dir():
        raise AppError("保存目录不可用，请重新选择原目录。")
    stat = path.stat()
    return {"device": stat.st_dev, "inode": stat.st_ino}


class DownloadRedirects(urllib.request.HTTPRedirectHandler):
    max_redirections = 5

    def redirect_request(self, request, fp, code, message, headers, newurl):
        checked_url(newurl)
        if request.type == "https" and _split(newurl).scheme != "https":
            raise AppError("下载链接重定向到不安全的连接。")
        return super().redirect_request(request, fp, code, message, headers, newurl)


class _RestartWithFullResponse(Exception):
    pass


class DownloadStore:
    def __init__(self, root: Path):
        self.root = Path(root)
        self.file = self.root / "downloads.json"
        self.database = None

    def load(self):
        self.root.mkdir(parents=True, exist_ok=True)
        if not self.file.exists():
            if (self.root / "MigrationEvidence").exists() or (self.root / "staging").exists():
                raise AppError("下载资料缺失，已停止写入。")
            self.database = self._empty()
            self.save()
            return self.database
        try:
            raw = json.loads(self.file.read_text(encoding="utf-8"))
            data = _b64decode(raw["payload"])
            if hashlib.sha256(data).hexdigest() != raw["sha256"]:
                raise ValueError("invalid download digest")
            self.database = json.loads(data.decode("utf-8"))
            self._validate()
        except (OSError, UnicodeError, ValueError, TypeError, KeyError, AttributeError) as exc:
            raise AppError("下载资料校验失败，已停止改写。") from exc
        if self.recover():
            self.save()
        return self.database

    def save(self):
        self.database["revision"] = int(self.database.get("revision") or 0) + 1
        data = json.dumps(self.database, ensure_ascii=False, sort_keys=True).encode("utf-8")
        envelope = {"payload": _b64encode(data), "sha256": hashlib.sha256(data).hexdigest()}
        temporary = self.file.with_name(self.file.name + f".tmp-{uuid.uuid4().hex}")
        try:
            with temporary.open("x", encoding="utf-8", newline="\n") as handle:
                json.dump(envelope, handle, sort_keys=True)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary, self.file)
        finally:
            temporary.unlink(missing_ok=True)

    def recover(self):
        changed = False
        for item in self.database["items"]:
            if item["state"] == "committing" and item.get("publishIntent"):
                intent = item.pop("publishIntent")
                try:
                    path = Path(intent["path"])
                    stat = path.stat()
                    if (stat.st_dev, stat.st_ino, stat.st_size) == (intent["device"], intent["inode"], intent["byteCount"]) and file_digest(path) == intent["sha256"]:
                        item.update(state="completed", error=None, errorCategory=None, artifact={
                            key: intent[key] for key in ("fileName", "byteCount", "sha256", "path")
                        })
                        changed = True
                        continue
                except OSError:
                    pass
            if item["state"] in ACTIVE_STATES or item["state"] in QUEUED_STATES:
                item["state"] = "paused"
                item["error"] = "上次退出时任务未完成，已暂停。需要时请继续。"
                changed = True
        for grant in self.database["destinations"]:
            if not grant.get("directoryIdentity") and not grant.get("requiresReauthorization"):
                grant["requiresReauthorization"] = True
                changed = True
            if grant.get("requiresReauthorization"):
                for item in self.database["items"]:
                    if item.get("destinationID") == grant["id"] and item["state"] not in (TERMINAL | {"waitingForDestination"}):
                        item["state"] = "waitingForDestination"
                        changed = True
        return changed

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
        for key, kind in (("jobs", list), ("items", list), ("destinations", list), ("settings", dict)):
            if not isinstance(db.get(key), kind):
                raise AppError("下载资料格式无效，已停止改写。")
        if db["settings"].get("concurrency") not in (1, 2):
            raise AppError("下载并发设置无效，已停止改写。")
        for item in db["items"]:
            if not re.fullmatch(r"[\w-]+", item["id"]) or item.get("stagingName") != item["id"] + ".part":
                raise AppError("下载暂存路径无效，已停止改写。")


def _b64encode(data: bytes) -> str:
    import base64
    return base64.b64encode(data).decode("ascii")


def _b64decode(value: str) -> bytes:
    import base64
    return base64.b64decode(value.encode("ascii"), validate=True)


class DownloadManager:
    def __init__(self, root: Path):
        self.store = DownloadStore(root)
        self.session_authorized = set()
        self.lock = threading.RLock()
        self.workers = {}
        self.stopping = False
        self.store.load()

    @property
    def database(self):
        return self.store.database

    def tray_progress(self):
        if not self.lock.acquire(blocking=False):
            return None
        try:
            active = [(item.get("bytesReceived"), item.get("totalBytes")) for item in self.database["items"]
                      if item["id"] in self.workers and item["state"] in ACTIVE_STATES] if self.workers else []
        finally:
            self.lock.release()
        count = len(active)
        if not active or any(type(received) is not int or type(total) is not int or not 0 <= received <= total
                             for received, total in active):
            return count, None
        total_bytes = sum(total for _, total in active)
        return count, (100 * sum(received for received, _ in active) // total_bytes if total_bytes else None)

    def add_destination(self, path: Path):
        path = Path(path)
        if not path.is_absolute():
            raise AppError("保存目录无效。")
        path.mkdir(parents=True, exist_ok=True)
        identity = directory_identity(path)
        for grant in self.database["destinations"]:
            if Path(grant["displayPath"]) == path:
                if grant.get("directoryIdentity") and grant["directoryIdentity"] != identity:
                    raise AppError("此路径下的目录身份已改变。请为新下载选择其他目录。")
                grant["requiresReauthorization"] = False
                grant["directoryIdentity"] = identity
                self.store.save()
                return grant
        grant = {
            "id": str(uuid.uuid4()),
            "displayPath": str(path),
            "directoryIdentity": identity,
            "requiresReauthorization": False,
        }
        self.database["destinations"].append(grant)
        self.store.save()
        return grant

    def prepare(self, urls):
        reviewed = []
        if not isinstance(urls, list) or not 1 <= len(urls) <= 32:
            raise AppError("请提供 1 至 32 个下载地址。")
        for url in urls:
            try:
                checked_url(url)
                parts = _split(url)
            except ValueError as exc:
                raise AppError("仅接受不含账号密码的完整 HTTP 或 HTTPS 网址。") from exc
            reviewed.append({
                "url": url,
                "displayURL": redacted_download_url(url),
                "requiresPrivacyReview": bool(parts.query or parts.fragment),
                "suggestedName": safe_download_name(unquote(parts.path.rsplit("/", 1)[-1]) or parts.hostname or "download"),
            })
        return reviewed

    def create_jobs(self, urls, destination_id, request_id=None, use_stripped=False, reserved_ids=None):
        if request_id and request_id in set(reserved_ids or []):
            raise AppError("这个请求编号已保留在只读历史中。", "history_identity_reserved")
        if request_id:
            existing = [job for job in self.database["jobs"] if job.get("requestID") == request_id]
            if existing:
                return existing
        self.destination(destination_id, ready=True)
        prepared = self.prepare(urls)
        if len(self.database["items"]) + len(prepared) > 5000:
            raise AppError("下载队列已满。")
        jobs = []
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
            job = {"id": str(uuid.uuid4()), "requestID": request_id, "itemIDs": [item_id], "createdAt": now}
            self.database["items"].append(item)
            self.database["jobs"].append(job)
            jobs.append(job)
            self.session_authorized.add(item_id)
        self.store.save()
        return jobs

    def pause(self, item_id):
        item = self._item(item_id)
        if item["state"] in TERMINAL | {"committing"}:
            return item
        item["state"] = "paused"
        self.session_authorized.discard(item_id)
        self.store.save()
        return item

    def resume(self, item_id):
        item = self._item(item_id)
        if item_id in self.workers:
            raise AppError("正在保存当前断点，请稍后再继续。")
        self.destination(item["destinationID"], ready=True)
        if item["state"] in {"paused", "waitingForNetwork", "waitingForDestination", "retryScheduled", "failed", "partial", "cancelled"} and not item.get("artifact"):
            item["state"] = "queued"
            item["error"] = None
            item["errorCategory"] = None
            self.session_authorized.add(item_id)
            self.store.save()
            return item
        raise AppError("这个任务现在不能继续。")

    def retry(self, item_id, restart=False):
        item = self._item(item_id)
        if restart and item_id not in self.workers and not item.get("artifact"):
            self._clear_partial(item)
        self.resume(item_id)
        item["attempts"] = 0
        self.store.save()
        return item

    def cancel(self, item_id, remove_partial=False):
        item = self._item(item_id)
        if item["state"] in {"completed", "committing"}:
            raise AppError("已落盘或正在正式落盘的文件无法取消。")
        item["state"] = "cancelled"
        self.session_authorized.discard(item_id)
        if remove_partial:
            if item_id in self.workers:
                item["discardPartial"] = True
            else:
                self._clear_partial(item)
        self.store.save()
        return item

    def destination(self, destination_id, ready=False):
        target = next((entry for entry in self.database["destinations"] if entry["id"] == destination_id), None)
        if target is None or ready and (target.get("requiresReauthorization") or not Path(target["displayPath"]).is_dir()):
            raise AppError("保存目录不可用，请重新选择原目录。")
        if ready and directory_identity(Path(target["displayPath"])) != target.get("directoryIdentity"):
            raise AppError("保存目录身份已改变，原授权不再有效。")
        return target

    def reauthorize(self, destination_id, selected):
        grant = self.destination(destination_id)
        if not selected.is_absolute() or selected != Path(grant["displayPath"]) or not selected.is_dir():
            raise AppError("请选择原保存目录。")
        return self.add_destination(selected)

    def delete_history(self, item_id):
        item = self._item(item_id)
        if item["state"] not in TERMINAL or item_id in self.workers or item.get("requestID"):
            raise AppError("这项历史当前无法删除。")
        self._clear_partial(item)
        self.database["items"].remove(item)
        for job in self.database["jobs"][:]:
            if item_id in job["itemIDs"]:
                job["itemIDs"].remove(item_id)
                if not job["itemIDs"]:
                    self.database["jobs"].remove(job)
        self.store.save()

    def update_settings(self, requested):
        accepted = {
            "concurrency": (1, 2),
            "speedLimitBytesPerSecond": (0, 256 * 1024, 1024 ** 2, 5 * 1024 ** 2, 20 * 1024 ** 2),
            "maxItemBytes": tuple(value * GIB for value in (1, 5, 20, 50, 100)),
            "maxStagingBytes": tuple(value * GIB for value in (5, 20, 40, 100, 200)),
            "appearance": ("system", "light", "dark"),
        }
        if any(key not in accepted or value not in accepted[key] for key, value in requested.items()):
            raise AppError("下载设置无效。")
        self.database["settings"].update(requested)
        self.store.save()

    def pause_all(self):
        for item in self.database["items"]:
            if item["state"] in ACTIVE_STATES | QUEUED_STATES:
                self.pause(item["id"])

    def resume_all(self):
        for item in self.database["items"]:
            if item["state"] in {"paused", "waitingForNetwork", "retryScheduled"}:
                try:
                    self.resume(item["id"])
                except AppError:
                    continue

    def start(self):
        with self.lock:
            if self.stopping:
                return
            hosts = {host for _, host in self.workers.values()}
            for item in self.database["items"]:
                if len(self.workers) >= self.database["settings"]["concurrency"]:
                    break
                item_id = item["id"]
                if item["state"] != "queued" or item_id not in self.session_authorized or item_id in self.workers:
                    continue
                host = _split(item["sourceURL"]).hostname
                if host in hosts:
                    continue
                thread = threading.Thread(target=self._background, args=(item,), daemon=True)
                self.workers[item_id] = (thread, host)
                hosts.add(host)
                thread.start()

    def _background(self, item):
        try:
            self._transfer(item)
        finally:
            with self.lock:
                if item.pop("discardPartial", False):
                    self._clear_partial(item)
                    self.store.save()
                self.workers.pop(item["id"], None)
                self.start()

    def shutdown(self):
        with self.lock:
            self.stopping = True
            self.pause_all()
            threads = [thread for thread, _ in self.workers.values()]
        for thread in threads:
            thread.join(timeout=15)

    def _clear_partial(self, item):
        self._partial_path(item).unlink(missing_ok=True)
        item.update(bytesReceived=0, partialSHA256=None, etag=None)

    def run_authorized(self, opener=None):
        ran = []
        for item in list(self.database["items"]):
            if item["id"] in self.session_authorized and item["state"] == "queued":
                self._transfer(item, opener=opener)
                ran.append(item["id"])
        return ran


    def _transfer(self, item, opener=None):
        item_id = item["id"]
        with self.lock:
            if item_id not in self.session_authorized:
                return item
            try:
                self.destination(item["destinationID"], ready=True)
            except AppError:
                return self._finish(item, "waitingForDestination", "destination", "请重新选择原保存目录。")
            item.update(state="running", attempts=int(item.get("attempts") or 0) + 1)
            self.store.save()
        partial = self._partial_path(item)
        try:
            partial.parent.mkdir(parents=True, exist_ok=True)
            offset = int(item.get("bytesReceived") or 0) if partial.is_file() else 0
            etag = strong_etag(item.get("etag"))
            hasher = hashlib.sha256()
            if offset:
                with partial.open("rb") as handle:
                    remaining = offset
                    while remaining:
                        chunk = handle.read(min(1024 * 1024, remaining))
                        if not chunk:
                            break
                        hasher.update(chunk)
                        remaining -= len(chunk)
                if remaining or hasher.hexdigest() != item.get("partialSHA256"):
                    return self._finish(item, "partial", "integrity_failure", "已下载片段的摘要不一致。可从头下载。")
            if not etag:
                offset = 0
            opener = opener or urllib.request.build_opener(DownloadRedirects()).open
            while True:
                request = urllib.request.Request(item["sourceURL"], method="GET", headers={"Accept-Encoding": "identity"})
                if offset:
                    request.add_header("Range", f"bytes={offset}-")
                    request.add_header("If-Range", etag)
                try:
                    with opener(request, timeout=12) as response:
                        return self._receive(item, response, partial, offset, etag, hasher)
                except urllib.error.HTTPError as exc:
                    if exc.code != 416 or not offset:
                        raise
                    exc.close()
                except _RestartWithFullResponse:
                    pass
                with self.lock:
                    if item_id not in self.session_authorized:
                        return item
                offset = 0
                etag = None
                hasher = hashlib.sha256()
        except urllib.error.HTTPError as exc:
            return self._fail_http(item, exc.code)
        except (urllib.error.URLError, TimeoutError, ConnectionError) as exc:
            return self._finish(item, "waitingForNetwork", "network_unavailable", "网络中断。恢复网络后可以继续。")
        except AppError as exc:
            return self._finish(item, "failed", exc.code, str(exc))
        except OSError:
            return self._finish(item, "waitingForDestination", "file_access", "无法读取或保存下载文件，请检查目录权限与可用空间。")
        except Exception:
            return self._finish(item, "partial", "incomplete", "传输中断，已保留可校验的片段。")

    def _receive(self, item, response, partial, offset, previous_etag, hasher):
        status = getattr(response, "status", None) or response.getcode()
        etag = strong_etag(response.headers.get("ETag"))
        length = response.headers.get("Content-Length")
        received = offset
        if length is not None and not length.isdecimal():
            return self._finish(item, "failed", "invalid_length", "服务器返回了无效的内容长度。")
        total = int(length) if length is not None else None
        if status == 206:
            span = CONTENT_RANGE.fullmatch(response.headers.get("Content-Range", ""))
            if not offset:
                return self._finish(item, "failed", "integrity_failure", "未请求断点却收到部分响应。")
            if etag != previous_etag or not span:
                raise _RestartWithFullResponse
            start, end, expected = map(int, span.groups())
            if (start != offset or not start <= end or end != expected - 1 or
                    item.get("totalBytes") not in (None, expected) or (total is not None and total != end - start + 1)):
                raise _RestartWithFullResponse
            total = expected
        elif status == 200:
            received = offset = 0
            hasher = hashlib.sha256()
        else:
            return self._fail_http(item, status)
        if response.headers.get("Content-Encoding", "identity").lower() != "identity":
            return self._finish(item, "failed", "invalid_encoding", "服务器未返回可校验的原始文件字节。")
        with self.lock:
            if item["id"] not in self.session_authorized:
                return item
            limit = self.database["settings"]["maxItemBytes"]
            if total is not None and total > limit:
                return self._finish(item, "failed", "size_limit", "文件超过允许的大小。")
            item.update(totalBytes=total, bytesReceived=received, etag=etag, partialSHA256=hasher.hexdigest())
            disposition = response.headers.get("Content-Disposition", "")
            if disposition and len(disposition) < 8192:
                header = Message()
                header["Content-Disposition"] = disposition
                if header.get_filename():
                    item["suggestedName"] = safe_download_name(header.get_filename())
        started = time.monotonic()
        checkpoint = started
        with partial.open("r+b" if offset else "wb") as handle:
            if offset:
                handle.truncate(offset)
                handle.seek(offset)
            try:
                while True:
                    with self.lock:
                        if item["id"] not in self.session_authorized:
                            break
                    chunk = response.read(64 * 1024)
                    if not chunk:
                        break
                    with self.lock:
                        if item["id"] not in self.session_authorized:
                            break
                        next_count = received + len(chunk)
                        if next_count > limit or (total is not None and next_count > total):
                            raise AppError("响应超出允许的大小。", "size_limit")
                        staging = sum(
                            entry.get("bytesReceived", 0) for entry in self.database["items"]
                            if not entry.get("artifact")
                        )
                        if staging + len(chunk) > self.database["settings"]["maxStagingBytes"]:
                            raise AppError("暂存预算已用完。", "staging_limit")
                        handle.write(chunk)
                        hasher.update(chunk)
                        received = next_count
                        item["bytesReceived"] = received
                        now = time.monotonic()
                        item["speed"] = int((received - offset) / max(now - started, .001))
                        speed_limit = self.database["settings"]["speedLimitBytesPerSecond"]
                        if now - checkpoint >= 1:
                            self._checkpoint(item, handle, hasher)
                            checkpoint = now
                    if speed_limit:
                        delay = (received - offset) / speed_limit - (time.monotonic() - started)
                        if delay > 0:
                            time.sleep(min(delay, .5))
            finally:
                with self.lock:
                    item.pop("speed", None)
                    self._checkpoint(item, handle, hasher)
        with self.lock:
            if item["id"] not in self.session_authorized:
                return item
            if total is not None and received != total:
                return self._finish(item, "partial", "incomplete", "响应提前结束，已保留校验断点。")
            item["state"] = "verifying"
            self.store.save()
        digest = file_digest(partial)
        if digest != hasher.hexdigest() or partial.stat().st_size != received:
            return self._finish(item, "partial", "integrity_failure", "文件摘要不一致。")
        with self.lock:
            if item["id"] not in self.session_authorized:
                return item
            item["state"] = "committing"
            self.store.save()
        result = self._commit(item, partial, digest, received)
        with self.lock:
            item["artifact"] = result
            self._finish(item, "completed", None, None)
        partial.unlink(missing_ok=True)
        return item

    def _checkpoint(self, item, handle, hasher):
        handle.flush()
        os.fsync(handle.fileno())
        item["partialSHA256"] = hasher.hexdigest()
        self.store.save()

    def _commit(self, item, partial, digest, size):
        grant = self.destination(item["destinationID"], ready=True)
        directory = Path(grant["displayPath"])
        name = Path(safe_download_name(item["suggestedName"]))
        temporary = directory / f".gaomenhu-{item['id']}-{uuid.uuid4().hex}.part"
        try:
            with partial.open("rb") as source, temporary.open("xb") as target:
                shutil.copyfileobj(source, target, 1024 * 1024)
                target.flush()
                os.fsync(target.fileno())
            stat = temporary.stat()
            if stat.st_size != size or file_digest(temporary) != digest:
                raise AppError("落盘校验失败，已保留下载断点。", "integrity_failure")
            for index in range(1001):
                self.destination(item["destinationID"], ready=True)
                chosen = directory / (name.name if index == 0 else f"{name.stem} ({index}){name.suffix}")
                if chosen.exists():
                    continue
                artifact = {"fileName": chosen.name, "byteCount": size, "sha256": digest, "path": str(chosen)}
                with self.lock:
                    item["publishIntent"] = dict(artifact, device=stat.st_dev, inode=stat.st_ino, temporary=str(temporary))
                    self.store.save()
                try:
                    if os.name == "nt":
                        temporary.rename(chosen)
                    else:
                        os.link(temporary, chosen)
                except FileExistsError:
                    continue
                return artifact
            raise AppError("目标目录里同名文件过多。")
        finally:
            temporary.unlink(missing_ok=True)

    def _finish(self, item, state, category, message):
        with self.lock:
            if item["state"] in {"paused", "cancelled"}:
                return item
            item.pop("publishIntent", None)
            item.update(state=state, errorCategory=category, error=message)
            self.session_authorized.discard(item["id"])
            self.store.save()
            return item

    def _fail_http(self, item, status):
        if status in (416, 429) or status >= 500:
            return self._finish(item, "retryScheduled", "server_retry", f"服务器返回 {status}，可重试。")
        return self._finish(item, "failed", "permanent_http", f"服务器返回 {status}。")

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
