"""Durable user-reviewed GaoAction request and result coordination."""

import base64
import copy
import hashlib
import json
import os
import shutil
import threading
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

from . import APP_ID
from .action_transport import ActionTransport
from .actions import (
    ERROR_RE, PORTAL_ACTIONS, _parse_date, filesystem_entry, make_request, manifest_uuid,
    package_manifest, plan, strict_json, validate_manifest, verify_payload,
)
from .errors import AppError
from .models import strip_query_and_fragment

LIMIT = 24 * 1024 * 1024
MAX_RECORDS = 5000
MAX_PENDING = 8
TERMINAL = {"completed", "partial", "failed", "cancelled", "unsupported"}


def now_utc():
    return datetime.now(timezone.utc)


def encode(value):
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")


def atomic_bytes(path, content):
    temporary = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
    try:
        with temporary.open("xb") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def clean_error(value, fallback="operation_failed"):
    return value if isinstance(value, str) and ERROR_RE.fullmatch(value) else fallback


def validate_download_result(manifest):
    if manifest["action"] != "downloads.prepare" or manifest["parameters"] or manifest["references"]:
        raise AppError("下载回执或结果格式不兼容。", "invalid_result")
    status = manifest["status"]
    provenance = manifest["provenance"]
    tasks = provenance.get("taskIDs")
    state = provenance.get("workflowState")
    files = manifest["items"]
    error = manifest["errorCode"]
    if (set(provenance) != {"workflowState", "taskIDs"}
            or not isinstance(tasks, list) or len(tasks) > 32
            or len({manifest_uuid(task) for task in tasks}) != len(tasks)):
        raise AppError("下载结果任务编号无效。", "invalid_result")
    if status == "pending":
        valid = state == "accepted" and bool(tasks) and not files and not error
    elif status in ("completed", "partial"):
        valid = state == status and bool(tasks) and bool(files) and (status == "partial" or not error)
    else:
        valid = state == status and not files
    if not valid:
        raise AppError("下载状态与实际附件或任务不符。", "invalid_result")
    return sorted(manifest_uuid(task) for task in tasks)


def result_manifest(record, *, now=None):
    now = now or now_utc()
    provenance = {"workflowState": record["workflowState"]}
    if "sites" in record:
        provenance["sites"] = record["sites"]
    return {
        "schemaVersion": 1, "kind": "result", "requestID": str(uuid.uuid4()),
        "sourceBundleID": APP_ID, "targetBundleID": record["sourceBundleID"], "action": record["action"],
        "createdAt": now.isoformat(timespec="milliseconds").replace("+00:00", "Z"),
        "expiresAt": (now + timedelta(seconds=120)).isoformat(timespec="milliseconds").replace("+00:00", "Z"),
        "nonce": base64.b64encode(os.urandom(32)).decode("ascii"), "items": [], "references": [], "parameters": {},
        "inReplyTo": record["id"], "status": record["status"], "errorCode": record.get("errorCode"),
        "provenance": provenance,
    }


def write_empty_package(folder, manifest):
    if not isinstance(folder, Path) or not folder.is_absolute():
        raise AppError("请选择本机交接包的保存目录。", "invalid_directory")
    for component in (*reversed(folder.parents), folder):
        filesystem_entry(component, directory=True)
    name = manifest_uuid(manifest["requestID"])
    target = folder / f"{name}.gaoaction"
    staging = folder / f".{name}.tmp"
    staging.mkdir(mode=0o700)
    try:
        (staging / "payload").mkdir(mode=0o700)
        atomic_bytes(staging / "manifest.json", encode(manifest))
        if target.exists():
            raise AppError("该交接包已存在。", "duplicate_id")
        staging.rename(target)
    finally:
        if staging.exists():
            shutil.rmtree(staging)
    return target


class Journal:
    """Atomic JSON with an independent generation marker and interrupted-write detection."""

    def __init__(self, data_dir, name):
        self.directory = data_dir / "Exchange" / ("Windows-" + name)
        self.file = self.directory / "journal.json"
        self.marker = data_dir.with_name(data_dir.name + ".gaoaction-" + name + ".json")
        self.session = None

    def read(self):
        try:
            if not self.marker.exists() and not self.marker.is_symlink():
                if self.directory.exists() or self.directory.is_symlink() or self.session is not None:
                    raise ValueError("missing marker")
                return {}
            marker = self._read(self.marker, 4096)
            data = self._read(self.file, LIMIT, raw=True)
            journal = strict_json(data)
            digest = hashlib.sha256(data).hexdigest()
            if (not isinstance(marker, dict) or set(marker) != {"id", "generation", "sha256", "pending"}
                    or marker["pending"] is not False or marker["sha256"] != digest or type(marker["generation"]) is not int
                    or marker["generation"] < 1 or not isinstance(journal, dict)
                    or set(journal) != {"id", "generation", "records"} or not isinstance(journal["records"], dict)
                    or len(journal["records"]) > MAX_RECORDS or marker["id"] != journal["id"] or marker["generation"] != journal["generation"]):
                raise ValueError("invalid marker")
            manifest_uuid(marker["id"])
            current = (marker["id"], marker["generation"], digest)
            if self.session is not None and self.session != current:
                raise ValueError("journal was changed")
            self.session = current
            return journal["records"]
        except (AppError, OSError, ValueError, RecursionError, TypeError) as exc:
            raise AppError("交接历史不可读或已变化，已停止处理该类请求。", "exchange_recovery") from exc

    def _read(self, path, limit, raw=False):
        for component in reversed(path.parents):
            filesystem_entry(component, directory=True)
        if not 0 < filesystem_entry(path).st_size <= limit:
            raise ValueError("journal size")
        with path.open("rb") as source:
            data = source.read(limit + 1)
        if len(data) > limit:
            raise ValueError("journal size")
        return data if raw else strict_json(data)

    def commit(self, records):
        self.read()
        if len(records) > MAX_RECORDS:
            raise AppError("交接记录已满。", "exchange_capacity")
        identity, generation, _ = self.session or (str(uuid.uuid4()), 0, "")
        generation += 1
        data = encode({"id": identity, "generation": generation, "records": records})
        if len(data) > LIMIT:
            raise AppError("交接记录已达到存储上限。", "exchange_capacity")
        marker = {"id": identity, "generation": generation, "sha256": hashlib.sha256(data).hexdigest(), "pending": True}
        try:
            self.directory.mkdir(mode=0o700, parents=True, exist_ok=True)
            for component in (*reversed(self.directory.parents), self.directory):
                filesystem_entry(component, directory=True)
            atomic_bytes(self.marker, encode(marker))
            atomic_bytes(self.file, data)
            marker["pending"] = False
            atomic_bytes(self.marker, encode(marker))
            self.session = (identity, generation, marker["sha256"])
        except (AppError, OSError) as exc:
            raise AppError("无法持久写入交接记录，已停止执行。", "exchange_recovery") from exc


class ActionExchange:
    def __init__(self, service, transport=None, clock=now_utc):
        self.service = service
        self.clock = clock
        self.transport = transport or ActionTransport()
        self.lock = threading.RLock()
        self.requests = Journal(service.data_dir, "portal")
        self.outgoing = Journal(service.data_dir, "downloads")
        self.pending = {}
        self.started = False

    def start(self):
        if self.started:
            return
        self.started = True
        try:
            records = self.requests.read()
            interrupted = [r for r in records.values() if r["status"] == "pending" and r["workflowState"] != "accepted"]
            if interrupted:
                for record in interrupted:
                    record.update(status="failed", workflowState="failed", errorCode="interrupted_execution")
                self.requests.commit(records)
        except AppError:
            pass

    def open(self, directory, now=None):
        now = now or self.clock()
        manifest, raw = package_manifest(directory, now)
        identifier = manifest_uuid(manifest["requestID"])
        digest = hashlib.sha256(raw).hexdigest()
        if manifest["kind"] == "request" and manifest["action"] == "downloads.prepare":
            verify_payload(directory, manifest)
            return self.service.receive_action_download(manifest, digest, now)
        self.service._writable()
        with self.lock:
            self.start()
            self._prune(now)
            if manifest["kind"] == "result":
                return self._offer_download_result(directory, manifest, raw, digest)
            if manifest["action"] not in PORTAL_ACTIONS:
                raise AppError("搞门户未声明接收这类请求。", "unsupported_action")
            verify_payload(directory, manifest)
            records = self.requests.read()
            if identifier in records:
                if records[identifier]["digest"] != digest:
                    raise AppError("交接号已用于不同请求。", "duplicate_id")
                return {"ok": True, "record": self._public(records[identifier]), "repeated": True}
            if identifier in self.pending:
                raise AppError("交接号已用于待复核结果。", "duplicate_id")
            if any(r["nonce"] == manifest["nonce"] for r in records.values()):
                raise AppError("这条交接凭证已使用。", "duplicate_nonce")
            self._capacity()
            record = self._record(manifest, digest, "request")
            records[identifier] = record
            self.requests.commit(records)
            try:
                planned = self._plan(manifest)
            except AppError as exc:
                self.finish(identifier, "failed", "failed", clean_error(exc.code, "request_rejected"))
                raise
            self.pending[identifier] = {"manifest": manifest, "plan": planned, "inputs": self._inputs(planned)}
            return {"ok": True, "review": self._review(record, planned)}

    def _capacity(self):
        if len(self.pending) >= MAX_PENDING:
            raise AppError("请先处理正在复核的交接。", "review_busy")

    def _record(self, manifest, digest, direction):
        return {
            "id": manifest_uuid(manifest["requestID"]), "action": manifest["action"], "direction": direction,
            "sourceBundleID": manifest["sourceBundleID"], "targetBundleID": manifest["targetBundleID"],
            "nonce": manifest["nonce"], "digest": digest, "createdAt": manifest["createdAt"], "expiresAt": manifest["expiresAt"],
            "status": "pending", "workflowState": "awaitingUser", "errorCode": None,
        }

    def _plan(self, manifest):
        return plan(manifest["action"], manifest["parameters"], self.service.store.library,
                    self.service._installed(), self.service._connected_map())

    def _inputs(self, planned):
        kind = planned["type"]
        launches = [planned["launch"]] if kind == "openSite" else planned.get("sites", [])
        fields = ("id", "name", "url", "allowedBrowsers", "defaultBrowser", "defaultAccount", "accounts", "profiles")
        return [{key: copy.deepcopy(site.get(key)) for key in fields}
                for site in (self.service._site(launch["siteID"]) for launch in launches)]

    def _review(self, record, planned):
        summary = []
        if planned["type"] == "openSite":
            launch = planned["launch"]
            summary = [f"{self.service._site(launch['siteID'])['name']} · {launch['browserID']}"]
        elif planned["type"] == "openWorkspace":
            summary = [f"{self.service._site(item['siteID'])['name']} · {item['browserID']}" for item in planned["sites"]]
        elif planned["type"] == "focusSearch":
            summary = [planned["query"]]
        elif planned["type"] == "proposeSite":
            summary = [planned.get("title") or "建议网站", planned["url"]]
        else:
            summary = [row["withoutQueryAndFragment"] for row in planned["urls"]]
        return {"id": record["id"], "action": record["action"], "source": record["sourceBundleID"],
                "summary": summary, "kind": "request"}

    def _prune(self, now):
        for identifier, entry in tuple(self.pending.items()):
            if now < _parse_date(entry["manifest"]["expiresAt"]):
                continue
            if entry["manifest"]["kind"] == "request":
                self.finish(identifier, "failed", "failed", "expired")
            self._discard(identifier)

    def _discard(self, identifier):
        entry = self.pending.pop(identifier, None)
        if entry and entry.get("package"):
            shutil.rmtree(entry["package"], ignore_errors=True)

    def review_queue(self):
        with self.lock:
            self.start()
            self._prune(self.clock())
            for entry in self.pending.values():
                manifest = entry["manifest"]
                identifier = manifest_uuid(manifest["requestID"])
                if manifest["kind"] == "result":
                    return self._result_review(manifest)
                record = self.requests.read().get(identifier)
                if record:
                    return self._review(record, entry["plan"])
            return None

    def decide(self, identifier, approve, now=None):
        now = now or self.clock()
        if type(approve) is not bool:
            raise AppError("请选择确认或取消。", "invalid_review")
        with self.lock:
            self.start()
            if identifier not in self.pending:
                raise AppError("该交接已结束或待重新发起。", "review_unavailable")
            entry = self.pending[identifier]
            manifest = entry["manifest"]
            if now >= _parse_date(manifest["expiresAt"]):
                self._prune(now)
                raise AppError("交接请求已过期，请重新发起。", "expired")
            self.service._writable()
            if manifest["kind"] == "result":
                if approve:
                    record = self._accept_download_result(entry, now)
                    self.pending.pop(identifier)
                else:
                    self._discard(identifier)
                    record = None
                return {"ok": True, "record": record}
            if not approve:
                record = self.finish(identifier, "cancelled", "cancelled")
                self._discard(identifier)
                return {"ok": True, "record": record}
            try:
                fresh = self._plan(manifest)
                if fresh != entry["plan"] or self._inputs(fresh) != entry["inputs"]:
                    raise AppError("复核期间网站、场景或浏览器资料已变化，请重新发起。", "input_changed")
            except AppError as exc:
                self.finish(identifier, "failed", "failed", clean_error(exc.code, "input_changed"))
                self._discard(identifier)
                raise
            if fresh["type"] in ("openSite", "openWorkspace"):
                for target in [fresh["launch"]] if fresh["type"] == "openSite" else fresh["sites"]:
                    self.service.browser_session.require_consent(target)
            self.finish(identifier, "pending", "executing")
            self._discard(identifier)
        try:
            return self.service.execute_action_plan(identifier, manifest, fresh, now, entry["inputs"])
        except AppError as exc:
            self.finish(identifier, "failed", "failed", clean_error(exc.code))
            raise

    def finish(self, identifier, status, state, error=None, sites=None):
        with self.lock:
            self.start()
            records = self.requests.read()
            record = records.get(identifier)
            if not record:
                return None
            if record["status"] in TERMINAL:
                return self._public(record)
            record.update(status=status, workflowState=state, errorCode=error)
            if sites is not None:
                record["sites"] = sites
            self.requests.commit(records)
            return self._public(record)

    def history(self):
        with self.lock:
            self.start()
            try:
                self._prune(self.clock())
            except AppError:
                pass
            records, errors = [], []
            for journal, name in ((self.requests, "portal"), (self.outgoing, "downloads")):
                try:
                    records += [self._public(record) for record in journal.read().values()]
                except AppError:
                    errors.append(name)
            return {"ok": True, "records": sorted(records, key=lambda row: row["createdAt"], reverse=True), "unavailable": errors}

    def _public(self, record):
        keys = ("id", "action", "direction", "sourceBundleID", "targetBundleID", "createdAt", "status",
                "workflowState", "errorCode", "sites", "taskIDs", "deliveries", "fileCount", "sendState")
        public = {key: copy.deepcopy(record[key]) for key in keys if key in record}
        expires = _parse_date(record.get("expiresAt"))
        if record["direction"] == "outgoing" and not record["deliveries"] and expires and self.clock() >= expires:
            public["sendState"] = "expired"
        return public

    def _exchange_directory(self, name):
        folder = self.service.data_dir / "Exchange" / name
        folder.mkdir(mode=0o700, parents=True, exist_ok=True)
        for component in (*reversed(folder.parents), folder):
            filesystem_entry(component, directory=True)
        return folder

    def send_request(self, target, urls, privacy):
        self.service._writable()
        prepared = self.service.download_manager().prepare(urls)
        if any(entry["requiresPrivacyReview"] for entry in prepared) and privacy not in ("strip", "keep"):
            raise AppError("请先复核链接中的查询参数或片段。", "privacy_review_required")
        chosen = [strip_query_and_fragment(url)["withoutQueryAndFragment"] if privacy == "strip" else url for url in urls]
        from urllib.parse import urlsplit
        if any(urlsplit(url).fragment for url in chosen):
            raise AppError("文件下载交接不能保留 URL 片段。", "invalid_parameters")
        manifest = make_request("downloads.prepare", {"urls": chosen, "mediaType": "file"}, target=target, now=self.clock())
        validate_manifest(manifest, target, self.clock())
        self.transport.verify(manifest)
        with self.lock:
            records = self.outgoing.read()
            folder = self._exchange_directory("Outgoing")
            package = write_empty_package(folder, manifest)
            record = self._record(manifest, hashlib.sha256(encode(manifest)).hexdigest(), "outgoing")
            record.update(workflowState="handedOff", sendState="queued", taskIDs=[], deliveries=[])
            records[record["id"]] = record
            self.outgoing.commit(records)
        return self.resend_request(record["id"])

    def resend_request(self, identifier):
        self.service._writable()
        with self.lock:
            records = self.outgoing.read()
            record = records.get(manifest_uuid(identifier))
            if not record or record["status"] != "pending" or record["deliveries"]:
                raise AppError("没有可重新投递、尚未取得回执的请求。", "invalid_delivery")
            package = self._exchange_directory("Outgoing") / f"{record['id']}.gaoaction"
            manifest, raw = package_manifest(package, self.clock(), record["targetBundleID"])
            verify_payload(package, manifest)
            if hashlib.sha256(raw).hexdigest() != record["digest"]:
                raise AppError("本机留存交接包内容已变化。", "package_changed")
            problem = None
            try:
                self.transport.send(package, manifest)
            except AppError as exc:
                problem = str(exc)
            record["sendState"] = "failed" if problem else "launched"
            self.outgoing.commit(records)
            return {"ok": True, "record": self._public(record), "deliveryError": problem,
                    "message": "已交给接收方复核。" if not problem else problem}

    def publish_portal_result(self, identifier, folder=None, send=False):
        self.service._writable()
        with self.lock:
            self.start()
            record = self.requests.read().get(manifest_uuid(identifier))
            if not record or (record["status"] == "pending" and record["workflowState"] != "accepted"):
                raise AppError("这项交接还没有可交付的结果。", "invalid_delivery")
            manifest = result_manifest(record, now=self.clock())
            validate_manifest(manifest, manifest["targetBundleID"], self.clock())
            package = write_empty_package(folder or self._exchange_directory("Outgoing"), manifest)
        problem = None
        if send:
            try:
                self.transport.send(package, manifest)
            except AppError as exc:
                problem = str(exc)
        return {"ok": True, "package": str(package), "delivered": send and not problem, "deliveryError": problem}

    def _result_review(self, manifest):
        return {"id": manifest_uuid(manifest["requestID"]), "kind": "result", "source": manifest["sourceBundleID"],
                "action": manifest["action"], "inReplyTo": manifest_uuid(manifest["inReplyTo"]),
                "status": manifest["status"], "fileCount": len(manifest["items"])}

    def _correlate(self, records, manifest, digest):
        tasks = validate_download_result(manifest)
        related = manifest_uuid(manifest["inReplyTo"])
        identifier = manifest_uuid(manifest["requestID"])
        if identifier in records or related not in records:
            raise AppError("下载结果未关联本机登记的出站请求。", "result_unmatched")
        record = records[related]
        if manifest["sourceBundleID"] != record["targetBundleID"] or _parse_date(manifest["createdAt"]) < _parse_date(record["createdAt"]):
            raise AppError("下载结果来源或时间与原请求不符。", "result_unmatched")
        for other in records.values():
            for receipt in other["deliveries"]:
                if receipt["id"] == identifier:
                    if other["id"] == related and receipt["digest"] == digest:
                        return record, tasks, True
                    raise AppError("结果编号已用于其他内容。", "duplicate_id")
                if receipt["nonce"] == manifest["nonce"]:
                    raise AppError("结果随机数已使用。", "duplicate_nonce")
        if record["status"] in TERMINAL or len(record["deliveries"]) >= 256:
            raise AppError("该请求已有最终结果。", "result_final")
        if record["taskIDs"] and record["taskIDs"] != tasks:
            raise AppError("下载任务集合与已有接收回执不一致。", "result_unmatched")
        if not record["taskIDs"]:
            if manifest["status"] in ("completed", "partial") or (manifest["status"] != "pending" and tasks):
                raise AppError("请先接纳匹配的接收回执。", "receipt_required")
            if any(set(other["taskIDs"]) & set(tasks) for other in records.values()):
                raise AppError("下载任务已经属于其他交接请求。", "result_unmatched")
        return record, tasks, False

    def _offer_download_result(self, directory, manifest, raw, digest):
        records = self.outgoing.read()
        record, _, repeated = self._correlate(records, manifest, digest)
        if repeated:
            verify_payload(directory, manifest)
            return {"ok": True, "record": self._public(record), "repeated": True}
        identifier = manifest_uuid(manifest["requestID"])
        if identifier in self.pending:
            existing = self.pending[identifier]
            if existing.get("digest") != digest:
                raise AppError("结果编号已用于其他内容。", "duplicate_id")
            return {"ok": True, "review": self._result_review(manifest)}
        self._capacity()
        folder = self._exchange_directory("Incoming")
        package = folder / f"{uuid.uuid4()}.gaoaction"
        package.mkdir(mode=0o700)
        try:
            (package / "payload").mkdir(mode=0o700)
            verify_payload(directory, manifest, package)
            atomic_bytes(package / "manifest.json", raw)
        except (AppError, OSError):
            shutil.rmtree(package, ignore_errors=True)
            raise
        self.pending[identifier] = {"manifest": manifest, "digest": digest, "package": package}
        return {"ok": True, "review": self._result_review(manifest)}

    def _accept_download_result(self, entry, now):
        manifest, raw = package_manifest(entry["package"], now)
        digest = hashlib.sha256(raw).hexdigest()
        if digest != entry["digest"]:
            raise AppError("暂存回送已变化。", "package_changed")
        verify_payload(entry["package"], manifest)
        records = self.outgoing.read()
        record, tasks, repeated = self._correlate(records, manifest, digest)
        if repeated:
            shutil.rmtree(entry["package"], ignore_errors=True)
            return self._public(record)
        record.update(status=manifest["status"], workflowState=manifest["provenance"]["workflowState"],
                      errorCode=manifest["errorCode"], fileCount=len(manifest["items"]), taskIDs=tasks)
        record["deliveries"].append({
            "id": manifest_uuid(manifest["requestID"]), "status": manifest["status"], "digest": digest,
            "nonce": manifest["nonce"], "folder": entry["package"].name, "fileCount": len(manifest["items"]),
        })
        self.outgoing.commit(records)
        return self._public(record)

    def reveal_result(self, identifier):
        with self.lock:
            record = self.outgoing.read().get(manifest_uuid(identifier))
            delivery = record["deliveries"][-1] if record and record["deliveries"] else None
            if not delivery or not delivery["fileCount"]:
                raise AppError("这项交接没有可显示的文件副本。", "file_missing")
            name = delivery["folder"]
            if not isinstance(name, str) or not name.endswith(".gaoaction"):
                raise AppError("交接暂存路径无效。", "invalid_directory")
            manifest_uuid(name.removesuffix(".gaoaction"))
            package = self._exchange_directory("Incoming") / name
            filesystem_entry(package, directory=True)
            if os.name == "nt":
                os.startfile(str(package))
            return {"ok": True}


def action_route(service, action, body):
    exchange = service.action_exchange
    identifier = body.get("id")
    if action == "open":
        return service.open_action(body.get("path"))
    if action == "queue":
        with exchange.lock:
            review = exchange.review_queue()
            notice = service.action_notices[0] if service.action_notices else None
        return {"ok": True, "review": review, "notice": notice}
    if action == "ack-notice":
        with exchange.lock:
            if service.action_notices and service.action_notices[0]["noticeID"] == identifier:
                service.action_notices.pop(0)
        return {"ok": True}
    if action == "decide":
        return exchange.decide(identifier, body.get("approve"))
    if action == "history":
        return exchange.history()
    if action == "providers":
        return {"ok": True, "providers": exchange.transport.targets("downloads.prepare")}
    if action == "send":
        return exchange.send_request(body.get("target"), body.get("urls"), body.get("privacy"))
    if action == "resend":
        return exchange.resend_request(identifier)
    if action == "publish":
        target = body.get("path")
        return exchange.publish_portal_result(identifier, Path(target) if isinstance(target, str) else None,
                                              send=body.get("send") is True)
    if action == "reveal":
        return exchange.reveal_result(identifier)
    raise AppError("交接操作不存在。", "invalid_action")
