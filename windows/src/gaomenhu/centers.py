"""Local HTTP endpoints for the download and mail windows."""

import base64
import copy
import csv
import hashlib
import io
import json
import os
import shutil
import subprocess
import threading
import time
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.parse import urlsplit

from . import APP_ID
from .actions import MAX_MANIFEST_BYTES, MAX_PAYLOAD_BYTES, filesystem_entry, package_manifest, read_package, validate_manifest, verify_payload
from .downloads import TERMINAL, file_digest, safe_download_name
from .errors import AppError
from .mail import extract_codes, generate_aliases, make_service_alias, primary_code, sanitize_mail_html
from .mail_oauth import CLIENT_SECRET, access_token
from .transport import fetch_mailbox, load_message, move_mail, prepare_outgoing, send_mail, set_mail_flag

OAUTH_GUIDE = (
    "使用你本人或所属组织有权使用的客户端配置。搞门户不附带共享客户端 ID。",
    "Google Cloud：创建桌面应用客户端，添加 https://mail.google.com/、openid、email 范围。启用测试模式时，把邮箱加入测试用户。回调使用 http://127.0.0.1:随机端口/。填写客户端 ID，以及配置中提供的客户端密钥。",
    "Microsoft Entra：注册移动和桌面应用，登记 http://localhost 为回调，并申请 Exchange Online 委托权限 IMAP.AccessAsUser.All 与 SMTP.Send。填入客户端 ID 和租户。桌面应用不需要客户端密钥。",
    "服务商和组织可能限制第三方客户端、IMAP 或 SMTP AUTH。网页授权后，搞门户会核对身份并试登 IMAP 与 SMTP。它不会发送测试邮件。",
)


def download_state(manager):
    with manager.lock:
        database = manager.database
        return {
            "items": [
                {key: item[key] for key in (
                    "id", "destinationID", "displayURL", "suggestedName", "state", "bytesReceived",
                    "totalBytes", "speed", "error", "errorCategory", "createdAt", "artifact", "requestID"
                ) if key in item}
                for item in database["items"]
            ],
            "busy": list(manager.workers),
            "destinations": copy.deepcopy(database["destinations"]),
            "settings": database["settings"].copy(),
            "requests": [
                {key: copy.deepcopy(record[key]) for key in ("id", "sourceBundleID", "stage", "itemIDs", "deliveries", "parentActionID") if key in record}
                for record in database.get("requests", [])
            ],
        }


def _request(manager, request_id):
    record = next((entry for entry in manager.database.get("requests", []) if entry["id"] == request_id), None)
    if record is None:
        raise AppError("未找到下载请求。")
    return record


def import_request(manager, manifest, *, fingerprint=None, now=None, parent_action=None):
    manifest = validate_manifest(manifest, now=now)
    action = "portal.prepareDownload" if parent_action else "downloads.prepare"
    if manifest["kind"] != "request" or manifest["action"] != action:
        raise AppError("请选择下载请求包。")
    if not parent_action and any(urlsplit(url).fragment for url in manifest["parameters"]["urls"]):
        raise AppError("跨应用下载请求中的文件链接不能包含片段。")
    requests = manager.database.setdefault("requests", [])
    request_id = str(uuid.UUID(manifest["requestID"]))
    for record in requests:
        if record["id"] == request_id or record["nonce"] == manifest["nonce"]:
            if fingerprint and record["id"] == request_id and record.get("fingerprint") == fingerprint:
                return request_id, True
            raise AppError("该下载请求已经接收。", "duplicate_id")
    if len(requests) >= 5000:
        raise AppError("交接记录已满。")
    record = {
        "id": request_id, "sourceBundleID": manifest["sourceBundleID"], "nonce": manifest["nonce"],
        "stage": "awaitingReview", "urls": manifest["parameters"]["urls"], "itemIDs": [], "deliveries": [],
        "expiresAt": manifest["expiresAt"],
    }
    if fingerprint:
        record["fingerprint"] = fingerprint
    if parent_action:
        record["parentActionID"] = parent_action
    requests.append(record)
    try:
        manager.store.save()
    except Exception:
        requests.remove(record)
        raise
    return (request_id, False) if fingerprint or parent_action else request_id


def _result(manager, record, phase, folder, *, automatic=False):
    if phase not in ("pending", "final"):
        raise AppError("请选择回执或最终结果。", "invalid_result")
    if record.get("parentActionID"):
        raise AppError("请从主窗口的交接结果回送网站动作回执。")
    if record["stage"] == "awaitingReview":
        raise AppError("请先复核请求。")
    items = [manager._item(item_id) for item_id in record["itemIDs"]]
    if phase == "pending":
        if record["stage"] != "accepted":
            raise AppError("此请求已结束。")
        status, artifacts = "pending", []
    else:
        if record["stage"] == "rejected":
            status, artifacts = "cancelled", []
        else:
            if not any(delivery["status"] == "pending" and delivery.get("sendState") not in ("prepared", "failed")
                       for delivery in record["deliveries"]):
                raise AppError("请先保存并交付接收回执，再回送最终结果。")
            if not items or any(item["state"] not in TERMINAL for item in items):
                raise AppError("等待下载任务结束后再回送结果。")
            artifacts = [item["artifact"] for item in items if item.get("artifact") and item["state"] == "completed"]
            if len(artifacts) == len(items):
                status = "completed"
            elif artifacts:
                status = "partial"
            elif all(item["state"] == "cancelled" for item in items):
                status = "cancelled"
            else:
                status = "failed"
    if sum(artifact["byteCount"] for artifact in artifacts) > MAX_PAYLOAD_BYTES:
        raise AppError("结果附件超过 2 GiB，已停止复制。", "payloadTooLarge")
    if not folder.is_absolute() or not folder.is_dir():
        raise AppError("请选择结果包保存目录。")
    for component in (*reversed(folder.parents), folder):
        filesystem_entry(component, directory=True)
    now = datetime.now(timezone.utc)
    request_id = str(uuid.uuid4())
    temporary = folder / ("." + request_id + ".tmp")
    published = folder / (request_id + ".gaoaction")
    payload = temporary / "payload"
    payload.mkdir(parents=True)
    files = []
    try:
        for index, artifact in enumerate(artifacts):
            source = Path(artifact["path"])
            if filesystem_entry(source).st_size != artifact["byteCount"]:
                raise AppError("下载文件已变化，停止回送。")
            name = f"{index + 1:02d}-{safe_download_name(artifact['fileName'])}"
            target = payload / name
            with source.open("rb") as incoming, target.open("xb") as outgoing:
                shutil.copyfileobj(incoming, outgoing, 1024 * 1024)
                outgoing.flush()
                os.fsync(outgoing.fileno())
            if target.stat().st_size != artifact["byteCount"] or file_digest(target) != artifact["sha256"]:
                raise AppError("下载文件摘要已变化，停止回送。")
            files.append({
                "id": str(uuid.uuid4()), "relativePath": "payload/" + name, "uti": "public.data",
                "byteCount": artifact["byteCount"], "sha256": artifact["sha256"],
            })
        manifest = {
            "schemaVersion": 1, "kind": "result", "requestID": request_id, "sourceBundleID": APP_ID,
            "targetBundleID": record["sourceBundleID"], "action": "downloads.prepare",
            "createdAt": _iso(now), "expiresAt": _iso(now + timedelta(seconds=120)),
            "nonce": base64.b64encode(os.urandom(32)).decode("ascii"),
            "items": files, "references": [], "parameters": {}, "inReplyTo": record["id"], "status": status,
            "errorCode": "download_failed" if status == "failed" else None,
            "provenance": {"workflowState": "accepted" if status == "pending" else status, "taskIDs": record["taskIDs"] if "taskIDs" in record else []},
        }
        validate_manifest(manifest, record["sourceBundleID"], now)
        with (temporary / "manifest.json").open("x", encoding="utf-8") as handle:
            json.dump(manifest, handle, ensure_ascii=False)
            handle.flush()
            os.fsync(handle.fileno())
        temporary.rename(published)
    finally:
        if temporary.is_dir():
            shutil.rmtree(temporary)
    record["deliveries"].append({"status": status, "path": str(published), "sendState": "prepared" if automatic else "saved",
                                 "fingerprint": file_digest(published / "manifest.json")})
    manager.store.save()
    return str(published)


def _iso(date):
    return date.isoformat(timespec="milliseconds").replace("+00:00", "Z")


def _reveal(path, *, select=False):
    if os.name != "nt" or not path.exists():
        raise AppError("文件位置不可用。")
    if select:
        subprocess.Popen(["explorer.exe", "/select,", str(path)])
    else:
        os.startfile(path)


def download_route(service, action, body):
    manager = service.download_manager()
    result = {}
    with manager.lock:
        if action == "state":
            expired = [record for record in manager.database.get("requests", []) if record["stage"] == "awaitingReview"
                       and datetime.now(timezone.utc) >= datetime.fromisoformat(record["expiresAt"].replace("Z", "+00:00"))]
            if expired:
                for record in expired:
                    record["stage"] = "expired"
                manager.store.save()
                for record in expired:
                    if record.get("parentActionID"):
                        service.action_exchange.finish(record["parentActionID"], "failed", "failed", "expired")
            return {"ok": True, **download_state(manager)}
        if action == "prepare":
            if body.get("review"):
                with service.center_init_lock:
                    ticket = getattr(service, "download_composers", {}).pop(body["review"], None)
                if not ticket or ticket[0] <= service.clock():
                    raise AppError("下载复核已过期，请重新发起。")
                return {"ok": True, "prepared": ticket[1]}
            urls = body.get("urls") or ([service._site(body["siteID"])["url"]] if body.get("siteID") else [])
            return {"ok": True, "prepared": manager.prepare(urls)}
        if action == "destination":
            directory = Path(body.get("path") or "")
            if not directory.is_dir():
                raise AppError("请选择已存在的保存目录。")
            result["destination"] = manager.add_destination(directory)
        elif action == "reauthorize":
            result["destination"] = manager.reauthorize(body.get("destinationID"), Path(body.get("path") or ""))
        elif action == "create":
            urls = body.get("urls") or []
            request_id = body.get("requestID")
            if request_id:
                request = _request(manager, request_id)
                if request["stage"] != "awaitingReview":
                    raise AppError("此请求已经复核。")
                expires = datetime.fromisoformat(request["expiresAt"].replace("Z", "+00:00"))
                if datetime.now(timezone.utc) >= expires:
                    raise AppError("请求已过期，请从来源重新发起。")
                urls = request["urls"]
            prepared = manager.prepare(urls)
            privacy = body.get("privacy")
            if any(entry["requiresPrivacyReview"] for entry in prepared) and privacy not in ("keep", "strip"):
                raise AppError("请确认保留还是移除查询参数及片段。")
            destination = body.get("destinationID")
            if request_id:
                previous = [job for job in manager.database["jobs"] if job.get("requestID") == request_id]
                expected = [row["displayURL"] if privacy == "strip" else row["url"] for row in prepared]
                if previous:
                    observed = []
                    for job in previous:
                        if len(job["itemIDs"]) != 1:
                            raise AppError("上次交接的任务映射不完整，请保留已有资料。")
                        item = manager._item(job["itemIDs"][0])
                        if item["requestID"] != request_id or item["destinationID"] != destination:
                            raise AppError("上次交接已审批其他目录，请核对现有下载任务。")
                        observed.append(item["sourceURL"])
                    if observed != expected:
                        raise AppError("上次交接已审批另一组链接，请核对现有下载任务。")
            result["jobs"] = manager.create_jobs(urls, destination, request_id, use_stripped=privacy == "strip")
            if request_id:
                request.update(stage="accepted", taskIDs=[job["id"] for job in result["jobs"]],
                               itemIDs=[item_id for job in result["jobs"] for item_id in job["itemIDs"]])
                try:
                    manager.store.save()
                    if request.get("parentActionID"):
                        service.action_exchange.finish(request["parentActionID"], "pending", "accepted")
                    else:
                        folder = service.action_exchange._exchange_directory("Outgoing")
                        _result(manager, request, "pending", folder, automatic=True)
                except (AppError, OSError):
                    for item_id in request["itemIDs"]:
                        manager.pause(item_id)
                    raise
            if body.get("run", True):
                manager.start()
        elif action in ("pause", "resume", "cancel", "retry", "delete"):
            item_id = body.get("id")
            if action == "cancel":
                manager.cancel(item_id, bool(body.get("removePartial")))
            elif action == "retry":
                manager.retry(item_id, bool(body.get("restart")))
            elif action == "delete":
                manager.delete_history(item_id)
            else:
                getattr(manager, action)(item_id)
            if action in ("resume", "retry") and body.get("run", True):
                manager.start()
        elif action in ("pause-all", "resume-all"):
            if action == "pause-all":
                manager.pause_all()
            else:
                manager.resume_all()
                manager.start()
        elif action == "settings":
            manager.update_settings(body.get("settings") or {})
            manager.start()
        elif action == "reveal":
            if body.get("id"):
                item = manager._item(body["id"])
                if item.get("artifact"):
                    _reveal(Path(item["artifact"]["path"]), select=True)
                else:
                    _reveal(Path(manager.destination(item["destinationID"], ready=True)["displayPath"]))
            else:
                _reveal(manager.store.root)
        elif action == "verify-artifact":
            item = manager._item(body.get("id"))
            artifact = item.get("artifact")
            target = Path(artifact["path"]) if artifact else None
            if target is None or not target.is_file() or target.stat().st_size != artifact["byteCount"] or file_digest(target) != artifact["sha256"]:
                raise AppError("完成文件不可读取，或长度、SHA-256 已变化。")
        elif action == "request":
            result["requestID"] = import_request(manager, body.get("manifest"))
        elif action == "request-directory":
            directory = Path(body.get("path") or "")
            manifest = directory / "manifest.json"
            if not directory.is_absolute() or not manifest.is_file() or manifest.stat().st_size > MAX_MANIFEST_BYTES:
                raise AppError("请选择有效的 .gaoaction 下载请求目录。")
            manifest, raw = package_manifest(directory)
            if manifest["kind"] != "request" or manifest["action"] != "downloads.prepare":
                raise AppError("请选择下载请求包。")
            verify_payload(directory, manifest)
            result["requestID"], _ = import_request(manager, manifest, fingerprint=hashlib.sha256(raw).hexdigest())
        elif action == "request-preview":
            record = _request(manager, body.get("id"))
            if record["stage"] != "awaitingReview" or datetime.now(timezone.utc) >= datetime.fromisoformat(record["expiresAt"].replace("Z", "+00:00")):
                raise AppError("该下载请求已结束或已过期。", "expired")
            return {"ok": True, "prepared": manager.prepare(record["urls"])}
        elif action == "request-reject":
            record = _request(manager, body.get("id"))
            if record["stage"] != "awaitingReview":
                raise AppError("此请求已经复核。")
            record["stage"] = "rejected"
            manager.store.save()
            if record.get("parentActionID"):
                service.action_exchange.finish(record["parentActionID"], "cancelled", "cancelled")
        elif action == "request-result":
            record = _request(manager, body.get("id"))
            send = body.get("send") is True
            folder = service.action_exchange._exchange_directory("Outgoing") if send else Path(body.get("path") or "")
            previous = next((entry for entry in reversed(record["deliveries"])
                             if entry["status"] == "pending" and body.get("phase") == "pending"
                             or entry["status"] != "pending" and body.get("phase") != "pending"), None)
            published = None
            if send and previous:
                try:
                    old = Path(previous["path"])
                    if old.parent == folder:
                        manifest, raw = package_manifest(old, target_bundle_id=record["sourceBundleID"])
                        verify_payload(old, manifest)
                        if (manifest["inReplyTo"] == record["id"] and manifest["status"] == previous["status"]
                                and previous.get("fingerprint") == hashlib.sha256(raw).hexdigest()):
                            published = str(old)
                except AppError:
                    pass
            result["package"] = published or _result(manager, record, body.get("phase"), folder)
            if send:
                delivery = previous if published else record["deliveries"][-1]
                package = Path(result["package"])
                manifest = read_package(package, target_bundle_id=record["sourceBundleID"])
                try:
                    service.action_exchange.transport.send(package, manifest)
                except AppError as exc:
                    delivery["sendState"] = "failed"
                    result["deliveryError"] = str(exc)
                else:
                    delivery["sendState"] = "launched"
                    result["delivered"] = True
                manager.store.save()
        else:
            raise AppError("下载操作不存在。")
    return {"ok": True, **result, **download_state(manager)}


def _metadata(attachments):
    return [{key: value for key, value in part.items() if key != "base64"} for part in attachments or []]


def mail_state(store):
    return {
        "accounts": copy.deepcopy(store.library["accounts"]),
        "identities": copy.deepcopy(store.library["identities"]),
        "platforms": copy.deepcopy(store.library["platforms"]),
        "preferences": store.library["preferences"].copy(),
        "drafts": [{key: draft.get(key) for key in ("id", "accountID", "to", "subject", "updatedAt")} for draft in store.library["drafts"]],
        "messages": [
            {key: message[key] for key in (
                "id", "accountID", "folder", "subject", "from", "date", "preview", "isRead", "isFlagged", "loaded"
            ) if key in message} | {"code": _message_code(message)}
            for message in store.messages
        ],
        "submissions": copy.deepcopy(store.submissions),
        "authorized": sorted(store.authorized),
    }


def _message_code(message):
    code = primary_code(message.get("subject", ""), (message.get("body") or "")[:16384], (message.get("html") or "")[:16384])
    return code["value"] if code and code["type"] != "link" and code["confidence"] >= .5 else None


def _credential(service, account):
    account_id = account["id"]
    if account_id not in service.mail_store().authorized:
        raise AppError("此邮箱本次尚未连接，请先明确授权。")
    service.mail_vault.unlock(service.clock())
    stored = service.mail_vault.read(account_id, service.clock())
    return stored if account.get("auth", "password") == "password" else access_token(service, account, stored)


def _sync(service, store, account_id, folder="INBOX"):
    account = store.account(account_id)
    folder = folder or "INBOX"
    if folder != "INBOX" and folder not in _folder_paths(account):
        raise AppError("请选择已同步的邮件文件夹。")
    credential = _credential(service, account)
    service.mail_last_attempt[account_id] = service.clock()
    try:
        result = store.sync(account_id, lambda _: fetch_mailbox(account, credential, folder, store.library["preferences"].get("fetchLimit", 50)))
    except Exception as exc:
        account["syncError"] = "连接或同步失败，请检查邮箱凭据、服务商协议设置与网络。"
        store._write_library()
        raise AppError(account["syncError"]) from exc
    return [{"id": item["id"]} for item in result]


def _autosync(service):
    while True:
        time.sleep(15)
        if not service.mail_lock.acquire(blocking=False):
            continue
        try:
            store = service.mail_store()
            interval = store.library["preferences"].get("syncMinutes", 15) * 60
            accounts = [account for account in store.library["accounts"] if account.get("enabled") and account["id"] in store.authorized]
            for account in accounts if interval else []:
                last = max(account.get("lastSync") or 0, service.mail_last_attempt.get(account["id"], 0))
                if service.clock() - last >= interval:
                    try:
                        _sync(service, store, account["id"])
                    except AppError:
                        service.mail_last_attempt[account["id"]] = service.clock()
        finally:
            service.mail_lock.release()


def sync_mail_floating(service):
    with service.mail_lock:
        store = service.mail_store()
        accounts = [account for account in store.library["accounts"]
                    if account["id"] in store.authorized and account["enabled"]]
        if not accounts:
            raise AppError("请先在邮箱管理连接邮箱。")
        completed = 0
        for account in accounts:
            try:
                _sync(service, store, account["id"])
                completed += 1
            except AppError:
                continue
        if completed != len(accounts):
            raise AppError("部分邮箱同步失败，请查看邮箱状态。" if completed else "同步失败，请查看邮箱状态。")


def _start_autosync(service):
    if service.mail_autosync is None:
        service.mail_autosync = threading.Thread(target=_autosync, args=(service,), daemon=True, name="Mail autosync")
        service.mail_autosync.start()


def _folder_paths(account):
    return {entry["path"] for entry in account.get("folders", []) if entry.get("selectable")}


def _detail(service, store, message_id, allow_network=False):
    message = store.message(message_id)
    if not message.get("loaded") and allow_network:
        account = store.account(message["accountID"])
        credential = _credential(service, account)
        try:
            load_message(account, credential, message)
        except Exception as exc:
            raise AppError("读取正文失败，请检查邮箱连接后重试。") from exc
        store._write_cache()
    return {
        **message, "html": sanitize_mail_html(message.get("html")), "attachments": _metadata(message.get("attachments")),
        "codes": extract_codes(message.get("subject", ""), message.get("body") or "", message.get("html")),
    }


def _send(service, store, draft_id):
    draft = store.draft(draft_id)
    account = store.account(draft.get("accountID"))
    credential = _credential(service, account)
    try:
        outgoing = prepare_outgoing(account, draft)
    except (TypeError, ValueError) as exc:
        raise AppError("请核对发件人与收件人地址。") from exc
    record = store.stage_submission(draft_id)
    service.mail_sending.add(draft_id)
    try:
        send_mail(account, credential, draft, outgoing)
    except Exception as exc:
        record["phase"] = "uncertain"
        store._write_submissions()
        raise AppError("未能确认邮件发送结果。发送记录已保留，请到邮箱服务商核对。") from exc
    finally:
        service.mail_sending.discard(draft_id)
    store.complete_submission(record["id"])
    store.messages.append({
        **draft,
        "id": "__local_sent__|" + record["id"], "folder": "__local_sent__", "isRead": True, "loaded": True,
        "date": service.clock(), "from": str(outgoing["From"]), "to": str(outgoing["To"]),
        "cc": str(outgoing["Cc"] or ""), "messageID": str(outgoing["Message-ID"]),
    })
    store._write_cache()
    return record


def _platform_csv(store, text=None):
    columns = ("name", "kind", "url", "username", "address", "loginMethod", "status", "notes")
    if text is not None:
        parsed = csv.DictReader(io.StringIO(text.lstrip("\ufeff")))
        if not parsed.fieldnames or "name" not in parsed.fieldnames:
            raise AppError("CSV 需要包含 name 列。")
        rows = list(parsed)
        if len(rows) > 1000 or any(not (row.get("name") or "").strip() or len(row["name"]) > 200 for row in rows):
            raise AppError("CSV 内容无效。")
        account_by_email = {record["email"].casefold(): record["id"] for record in store.library["accounts"]}
        records = []
        for row in rows:
            account_id = account_by_email.get((row.get("accountEmail") or "").casefold())
            records.append({key: (row.get(key) or "") for key in columns} | {
                "id": str(uuid.uuid4()), "accountID": account_id, "roles": (row.get("roles") or "").split(" · "),
            })
        store.library["platforms"].extend(records)
        store._write_library()
        return len(records)
    output = io.StringIO()
    writer = csv.DictWriter(output, fieldnames=[*columns, "accountEmail", "roles"])
    writer.writeheader()
    emails = {record["id"]: record["email"] for record in store.library["accounts"]}
    for record in store.library["platforms"]:
        row = {key: record.get(key, "") for key in columns}
        row["accountEmail"] = emails.get(record.get("accountID"), "")
        row["roles"] = " · ".join(record.get("roles") or [])
        writer.writerow({key: "'" + value if str(value).startswith(("=", "+", "-", "@")) else value for key, value in row.items()})
    return output.getvalue()


def _mail_backup(store):
    public_fields = {
        "accounts": {"id", "email", "displayName", "username", "provider", "identityID", "tags", "aliases", "signature",
                     "enabled", "auth", "imapHost", "imapPort", "imapTLS", "smtpHost", "smtpPort", "smtpTLS", "sentFolder"},
        "identities": {"id", "name", "description", "color", "icon"},
        "platforms": {"id", "name", "accountID", "kind", "url", "username", "address", "loginMethod", "roles", "status", "notes"},
        "drafts": {"id", "accountID", "to", "cc", "bcc", "from", "inReplyTo", "subject", "body", "attachments", "updatedAt"},
    }
    document = {"schemaVersion": 1, "format": "GaoMenHu-Windows-Mail"}
    for kind, allowed in public_fields.items():
        document[kind] = [{key: copy.deepcopy(value) for key, value in record.items() if key in allowed} for record in store.library[kind]]
    for draft in document["drafts"]:
        draft["attachments"] = [
            {key: value for key, value in item.items() if key in {"id", "filename", "byteCount", "base64", "type"}}
            for item in draft.get("attachments", [])
        ]
    return document


def _restore_backup(store, document):
    kinds = ("identities", "accounts", "platforms", "drafts")
    if not isinstance(document, dict) or document.get("format") != "GaoMenHu-Windows-Mail" or document.get("schemaVersion") != 1:
        raise AppError("请选择搞门户 Windows 邮件模块导出的备份。")
    if any(not isinstance(document.get(kind), list) or len(document[kind]) > 2000 for kind in kinds):
        raise AppError("邮件备份格式无效或记录过多。")
    original = store.library
    candidate = copy.deepcopy(original)
    restore = type(store)(store.root)
    restore.library = candidate
    # Validate using the same editors, applying a single atomic write only after all rows have passed.
    restore._write_library = lambda: None
    existing_ids = {kind: {record["id"] for record in candidate[kind]} for kind in kinds}
    email_to_id = {account["email"].casefold(): account["id"] for account in candidate["accounts"]}
    account_map = {}
    for kind in kinds:
        seen = set()
        for raw in document[kind]:
            if not isinstance(raw, dict) or not isinstance(raw.get("id"), str) or raw["id"] in seen:
                raise AppError("邮件备份包含无效或重复的记录编号。")
            record = copy.deepcopy(raw)
            record_id = record["id"]
            seen.add(record_id)
            if record_id in existing_ids[kind]:
                continue
            if kind == "accounts":
                email = record.get("email") or ""
                if not isinstance(email, str):
                    raise AppError("邮件备份中的地址无效。")
                if email.casefold() in email_to_id:
                    account_map[record_id] = email_to_id[email.casefold()]
                    continue
                restore.save_account(record)
                email_to_id[email.casefold()] = record_id
            elif kind == "identities":
                restore.save_record(kind, record)
            else:
                if record.get("accountID"):
                    record["accountID"] = account_map.get(record["accountID"], record["accountID"])
                    if not any(account["id"] == record["accountID"] for account in candidate["accounts"]):
                        record["accountID"] = None
                if kind == "platforms":
                    restore.save_record(kind, record)
                else:
                    restore.save_draft(record)
    store.library = candidate
    try:
        store._write_library()
    except Exception:
        store.library = original
        raise


def mail_route(service, action, body):
    if action == "oauth-start":
        return {"ok": True, **service.mail_oauth.start(body.get("provider"), body.get("id"))}
    if action == "oauth-cancel":
        service.mail_oauth.cancel(body.get("id"))
        return {"ok": True}
    if action == "oauth-status":
        result = service.mail_oauth.status(body.get("id"))
        if result["status"] == "complete":
            with service.mail_lock:
                _start_autosync(service)
        return {"ok": True, **result}
    with service.mail_lock:
        store = service.mail_store()
        result = {}
        item_id = body.get("id")
        if action == "state":
            return {"ok": True, **mail_state(store)}
        if action == "account":
            raw = body.get("account") or {}
            password = body.get("password")
            if password:
                if raw.get("auth", "password") != "password":
                    raise AppError("网页登录凭据需要在服务商页面授权。")
                if not isinstance(password, str) or len(password.encode("utf-8")) > 8192:
                    raise AppError("邮箱凭据内容无效。")
                if not raw.get("id"):
                    raw["id"] = str(uuid.uuid4())
                service.mail_vault.unlock(service.clock())
                previous = service.mail_vault.cache.get(raw["id"])
                service.mail_vault.save(raw["id"], password, service.clock())
                try:
                    account = store.save_account(raw)
                except Exception:
                    if previous:
                        service.mail_vault.save(raw["id"], previous, service.clock())
                    else:
                        service.mail_vault.remove(raw["id"], service.clock())
                    raise
                store.authorized.discard(account["id"])
            else:
                account = store.save_account(raw)
            result["account"] = account
        elif action == "account-delete":
            store.account(item_id)
            service.mail_vault.remove(item_id, service.clock())
            store.delete_account(item_id)
        elif action == "authorize":
            store.authorize(item_id)
            try:
                _credential(service, store.account(item_id))
                if body.get("sync"):
                    result["messages"] = _sync(service, store, item_id)
                _start_autosync(service)
            except AppError:
                store.authorized.discard(item_id)
                raise
        elif action == "sync":
            result["messages"] = _sync(service, store, item_id, body.get("folder") or "INBOX")
        elif action == "draft":
            result["draft"] = store.save_draft(body.get("draft") or {})
        elif action == "draft-read":
            return {"ok": True, "draft": copy.deepcopy(store.draft(item_id))}
        elif action == "message":
            return {"ok": True, "message": _detail(service, store, item_id, allow_network=body.get("load") is True)}
        elif action == "attachment":
            message = store.message(item_id)
            attachment = next((part for part in message.get("attachments", []) if part.get("id") == body.get("attachmentID")), None)
            if attachment is None:
                raise AppError("附件不可用。")
            return {"ok": True, "attachment": attachment}
        elif action in ("message-flag", "message-move"):
            message = store.message(item_id)
            account = store.account(message.get("accountID"))
            credential = _credential(service, account)
            try:
                if action == "message-move":
                    folder = body.get("folder")
                    if folder not in _folder_paths(account) or folder == message.get("folder"):
                        raise AppError("请选择其他邮件文件夹。")
                    move_mail(account, credential, message, folder)
                    store.messages.remove(message)
                else:
                    field, flag = ("isRead", "\\Seen") if body.get("flag") == "read" else ("isFlagged", "\\Flagged")
                    value = not message.get(field)
                    set_mail_flag(account, credential, message, flag, value)
                    message[field] = value
                store._write_cache()
            except AppError:
                raise
            except Exception as exc:
                raise AppError("无法更新邮件，请检查连接。") from exc
        elif action == "send":
            result["submission"] = _send(service, store, body.get("draftID"))
        elif action == "record":
            result["record"] = store.save_record(body.get("kind"), body.get("record") or {})
        elif action == "record-delete":
            store.delete_record(body.get("kind"), item_id)
        elif action == "settings":
            secret = body.get("googleSecret")
            if secret:
                if not isinstance(secret, str) or len(secret) > 2048:
                    raise AppError("Google 客户端密钥无效。")
            store.save_preferences(body.get("preferences") or {})
            if secret:
                service.mail_vault.save(CLIENT_SECRET, secret, service.clock())
        elif action == "oauth-secret-clear":
            service.mail_vault.remove(CLIENT_SECRET, service.clock())
        elif action == "oauth-guide":
            return {"ok": True, "guide": OAUTH_GUIDE}
        elif action == "reveal":
            _reveal(store.root)
        elif action == "backup":
            return {"ok": True, "library": _mail_backup(store)}
        elif action == "restore":
            _restore_backup(store, body.get("library"))
        elif action == "platforms-csv":
            if body.get("text") is None:
                return {"ok": True, "csv": _platform_csv(store)}
            result["count"] = _platform_csv(store, body["text"])
        elif action == "codes":
            return {"ok": True, **service.codes(body.get("subject") or "", body.get("body") or "", body.get("html"))}
        elif action == "open-link":
            message = store.message(item_id)
            url = body.get("url")
            if not any(code["type"] == "link" and code["value"] == url for code in extract_codes(message.get("subject", ""), message.get("body") or "", message.get("html"))):
                raise AppError("验证链接不可用。")
            open_verification(url)
        elif action == "aliases":
            email = body.get("email") or ""
            if body.get("service"):
                return {"ok": True, "alias": make_service_alias(email, body["service"])}
            return {"ok": True, "aliases": generate_aliases(email, count=max(1, min(100, int(body.get("count") or 8))), options=body.get("options"))}
        else:
            raise AppError("邮件操作不存在。")
    return {"ok": True, **result}


def open_verification(url):
    from .models import checked_url
    import webbrowser
    checked_url(url)
    webbrowser.open(url)
