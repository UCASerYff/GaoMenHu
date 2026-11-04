"""Pure comparison for explicitly accepted original-directory reauthorization.

No path is opened, bookmark resolved, process started or credential requested.
The installer separately verifies a complete fresh snapshot and physical proof.
"""
import base64
import binascii
import copy
import hashlib
import json
import math
import re
import urllib.parse
import uuid


MAX_BYTES = 32 * 1024 * 1024
MAX_PAYLOAD_BYTES = 24 * 1024 * 1024
MAX_ITEM_BYTES = 1_099_511_627_776
STATES = {"awaitingReview", "queued", "running", "pausing", "paused", "waitingForNetwork",
          "waitingForDestination", "retryScheduled", "verifying", "committing", "completed",
          "partial", "failed", "cancelled"}


def _require(condition, message="下载重授权的资料范围或字段不符，保留原备份并停止验收。"):
    if not condition:
        raise RuntimeError(message)


def _uuid(value):
    _require(isinstance(value, str))
    try:
        return str(uuid.UUID(value)).upper()
    except (ValueError, AttributeError):
        raise RuntimeError("下载重授权的 UUID 无效，未放宽验收。") from None


def _int(value, minimum=0, maximum=2 ** 64 - 1):
    return type(value) is int and minimum <= value <= maximum


def _sha(value):
    return isinstance(value, str) and re.fullmatch(r"[0-9a-fA-F]{64}", value) is not None


def _bytes(value, maximum):
    _require(isinstance(value, str) and value and len(value) <= ((maximum + 2) // 3) * 4)
    try:
        result = base64.b64decode(value.encode("ascii"), validate=True)
    except (UnicodeError, ValueError, binascii.Error):
        raise RuntimeError("下载重授权的二进制字段编码无效。") from None
    _require(0 < len(result) <= maximum and base64.b64encode(result).decode("ascii") == value)
    return result


def _pairs(values):
    result = {}
    for key, value in values:
        _require(key not in result, "下载资料存在重复 JSON 字段，不能选择性接纳。")
        result[key] = value
    return result


def _json(raw):
    def invalid_constant(_):
        raise RuntimeError("下载资料含无效数值。")
    def finite_float(value):
        number = float(value)
        _require(math.isfinite(number), "下载资料含无效数值。")
        return number
    try:
        return json.loads(raw.decode("utf-8"), object_pairs_hook=_pairs, parse_constant=invalid_constant, parse_float=finite_float)
    except (UnicodeError, ValueError, TypeError):
        raise RuntimeError("下载资料 JSON 无法严格读取。") from None


def _canonical(value):
    # Preserve unknown keys and distinguish JSON true from numeric 1. Nothing is
    # projected into a DTO that could silently discard an unrecognized field.
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True, allow_nan=False)


def _envelope(raw):
    _require(type(raw) is bytes and 0 < len(raw) <= MAX_BYTES)
    envelope = _json(raw)
    _require(isinstance(envelope, dict) and isinstance(envelope.get("sha256"), str))
    payload = _bytes(envelope.get("payload"), MAX_PAYLOAD_BYTES)
    _require(hashlib.sha256(payload).hexdigest() == envelope["sha256"], "下载资料 envelope 摘要不符。")
    model = _json(payload)
    try:
        _validate_model(model)
    except (UnicodeError, ValueError, TypeError, KeyError):
        raise RuntimeError("下载资料模型字段无效，未放宽验收。") from None
    extras = {key: value for key, value in envelope.items() if key not in ("payload", "sha256")}
    return model, extras, {"fileSHA256": hashlib.sha256(raw).hexdigest(),
                           "payloadSHA256": hashlib.sha256(payload).hexdigest(), "revision": model["revision"]}


def _identities(rows):
    _require(isinstance(rows, list) and len(rows) <= 5000 and all(isinstance(row, dict) for row in rows))
    ids = [_uuid(row.get("id")) for row in rows]
    _require(len(ids) == len(set(ids)))
    return dict(zip(ids, rows))


def _validate_model(model):
    _require(isinstance(model, dict) and type(model.get("schemaVersion")) is int and model["schemaVersion"] == 1
             and _int(model.get("revision")))
    _uuid(model.get("installationID"))
    _require(isinstance(model.get("migrationHistory"), list) and len(model["migrationHistory"]) <= 1024
             and all(isinstance(value, str) and value for value in model["migrationHistory"]))
    settings = model.get("settings")
    _require(isinstance(settings, dict) and _int(settings.get("concurrency"), 1, 2)
             and _int(settings.get("speedLimitBytesPerSecond"), 0, 1_073_741_824)
             and _int(settings.get("maxItemBytes"), 1024, MAX_ITEM_BYTES)
             and _int(settings.get("maxStagingBytes"), 1024, 2 * MAX_ITEM_BYTES)
             and settings.get("appearance") in ("system", "light", "dark"))
    jobs = _identities(model.get("jobs")); items = _identities(model.get("items")); grants = _identities(model.get("destinations"))
    for grant in grants.values():
        path = grant.get("displayPath")
        _require(isinstance(path, str) and path.startswith("/") and len(path.encode("utf-8")) <= 16384
                 and "\0" not in path and not any(part in (".", "..") for part in path.split("/"))
                 and _int(grant.get("device"), 1) and _int(grant.get("inode"), 1)
                 and (grant.get("requiresReauthorization") is None or type(grant["requiresReauthorization"]) is bool))
        _bytes(grant.get("bookmark"), 1_048_576)
        if grant.get("volumeUUID") is not None:
            _uuid(grant["volumeUUID"])
    for item in items.values():
        job_id = _uuid(item.get("jobID")); grant_id = _uuid(item.get("destinationID"))
        _require(job_id in jobs and grant_id in grants and item.get("state") in STATES
                 and _int(item.get("bytesReceived"), 0, MAX_ITEM_BYTES)
                 and (item.get("expectedBytes") is None or _int(item["expectedBytes"], 0, MAX_ITEM_BYTES))
                 and item.get("stagingName") == item["id"] + ".part"
                 and (item.get("stagingDevice") is None) == (item.get("stagingInode") is None))
        source = item.get("sourceURL")
        _require(isinstance(source, str) and len(source.encode("utf-8")) <= 16384)
        try:
            url = urllib.parse.urlsplit(source)
            valid_url = url.scheme.lower() in ("http", "https") and bool(url.hostname) and url.username is None and url.password is None and not url.fragment
        except ValueError:
            valid_url = False
        _require(valid_url and item.get("sourceFingerprint") == hashlib.sha256(source.encode("utf-8")).hexdigest())
        speed = item.get("bytesPerSecond")
        _require(type(speed) in (int, float) and math.isfinite(speed) and speed >= 0)
        if item.get("stagingDevice") is not None:
            _require(_int(item["stagingDevice"], 1) and _int(item["stagingInode"], 1))
        if item.get("partialSHA256") is not None:
            _require(_sha(item["partialSHA256"]))
        for key in ("artifact", "pendingArtifact"):
            artifact = item.get(key)
            if artifact is None:
                continue
            _require(isinstance(artifact, dict) and _int(artifact.get("device"), 1) and _int(artifact.get("inode"), 1)
                     and _int(artifact.get("byteCount"), 0, MAX_ITEM_BYTES) and artifact["byteCount"] == item["bytesReceived"]
                     and _sha(artifact.get("sha256")) and isinstance(artifact.get("fileName"), str)
                     and artifact["fileName"] and not artifact["fileName"].startswith(".")
                     and not any(character in artifact["fileName"] for character in ("/", "\\", "\0")))
        _require(item.get("artifact") is None or (item["state"] == "completed" and item.get("pendingArtifact") is None))
    for job_id, job in jobs.items():
        item_ids = job.get("itemIDs")
        _require(isinstance(item_ids, list) and 1 <= len(item_ids) <= 32)
        ids = [_uuid(value) for value in item_ids]
        _require(len(ids) == len(set(ids)) and all(value in items and _uuid(items[value]["jobID"]) == job_id for value in ids))
    for item_id, item in items.items():
        _require(item_id in {_uuid(value) for value in jobs[_uuid(item["jobID"])]["itemIDs"]})


def accepted_download_reauthorization(original_bytes, current_bytes, previous_bytes, grant_id):
    """Accept only one explicit grant renewal against the original CURRENT model.

    Both current and current-previous must contain exactly the original business
    model with that same renewal. This never compares to or trusts old previous.
    A physical/evidence verifier and independent fresh snapshot remain required.
    """
    selected = _uuid(grant_id)
    original, old_extras, old_digest = _envelope(original_bytes)
    current, current_extras, current_digest = _envelope(current_bytes)
    previous, previous_extras, previous_digest = _envelope(previous_bytes)
    _require(_canonical(old_extras) == _canonical(current_extras) == _canonical(previous_extras))
    grants = _identities(original["destinations"])
    _require(selected in grants and old_digest["revision"] < previous_digest["revision"] <= current_digest["revision"])
    before = grants[selected]
    after_rows = [row for row in current["destinations"] if _uuid(row["id"]) == selected]
    _require(len(after_rows) == 1)
    after = after_rows[0]
    _require(before.get("requiresReauthorization") is True and after.get("requiresReauthorization") is False
             and _uuid(before.get("volumeUUID")) == _uuid(after.get("volumeUUID"))
             and before["inode"] == after["inode"] and before["displayPath"] == after["displayPath"])
    old_bookmark = _bytes(before["bookmark"], 1_048_576); new_bookmark = _bytes(after["bookmark"], 1_048_576)
    old_device, new_device = before["device"], after["device"]
    expected = copy.deepcopy(original)
    target = next(row for row in expected["destinations"] if _uuid(row["id"]) == selected)
    target.update(bookmark=after["bookmark"], device=new_device, requiresReauthorization=False)
    associated = []
    for item in expected["items"]:
        if _uuid(item["destinationID"]) != selected:
            continue
        entry = {"itemID": item["id"], "jobID": item["jobID"], "sourceFingerprint": item["sourceFingerprint"],
                 "state": item["state"], "bytesReceived": item["bytesReceived"], "stagingName": item["stagingName"],
                 "stagingInode": item.get("stagingInode"), "stagingDevice": item.get("stagingDevice"),
                 "partialSHA256": item.get("partialSHA256")}
        if item.get("stagingDevice") is not None:
            _require(item["stagingDevice"] == old_device)
            item["stagingDevice"] = new_device
        for key in ("artifact", "pendingArtifact"):
            artifact = item.get(key)
            if artifact is not None:
                _require(artifact["device"] == old_device)
                artifact["device"] = new_device
        associated.append(entry)
    _require(associated, "指定原目录没有可核对的关联下载记录。")
    for candidate in (current, previous):
        expected["revision"] = candidate["revision"]
        _require(_canonical(expected) == _canonical(candidate))
    original_items = _identities(original["items"])
    current_items = _identities(current["items"])
    previous_items = _identities(previous["items"])
    for entry in associated:
        item_id = _uuid(entry["itemID"])
        entry["currentStagingDevice"] = current_items[item_id].get("stagingDevice")
        entry["previousStagingDevice"] = previous_items[item_id].get("stagingDevice")
        for key in ("artifact", "pendingArtifact"):
            if original_items[item_id].get(key) is None:
                entry[key] = None
            else:
                entry[key] = {"original": copy.deepcopy(original_items[item_id][key]),
                              "current": copy.deepcopy(current_items[item_id][key]),
                              "previous": copy.deepcopy(previous_items[item_id][key])}
    return {"format": 1, "operation": "download.original-directory-reauthorization.acceptance.v1",
            "grantID": before["id"], "oldDevice": old_device, "newDevice": new_device,
            "volumeUUID": _uuid(before["volumeUUID"]), "directoryInode": before["inode"], "directoryPath": before["displayPath"],
            "originalBookmarkSHA256": hashlib.sha256(old_bookmark).hexdigest(),
            "renewedBookmarkSHA256": hashlib.sha256(new_bookmark).hexdigest(),
            "original": old_digest, "current": current_digest, "previous": previous_digest,
            "associatedItems": associated}
