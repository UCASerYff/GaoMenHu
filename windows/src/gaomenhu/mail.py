"""邮件缓存、验证码、别名和连接闸门。未明确连接前只读缓存。"""

import base64
import json
import os
import random
import re
import time
import uuid
from html import escape
from html.parser import HTMLParser
from pathlib import Path
from email.utils import parseaddr

from .errors import AppError
from .transport import MAX_MAIL_BYTES

CODE_KEYWORDS = re.compile(r"验证码|verification|verify|code|otp|pin|passcode|one.?time|确认码|安全码|动态码|captcha|校验码", re.I)
LINK_KEYWORDS = re.compile(r"verify|confirm|activate|token|click|validate|magic|login|auth|reset", re.I)
UNSUBSCRIBE = re.compile(r"unsubscribe|退订|opt-?out", re.I)
PHONE = re.compile(r"phone|电话|手机|tel|fax", re.I)
MONEY = re.compile(r"[\$¥€£]|价格|金额|amount|price|total|fee|cost|rmb", re.I)
ZIP = re.compile(r"zip|postal|邮编", re.I)
NUMERIC = re.compile(r"\b(\d{4,8})\b")
ALNUM = re.compile(r"\b([A-Za-z0-9]{4,10})\b")
HREF = re.compile(r"""href=["']([^"']+)["']""", re.I)
PLAIN_LINK = re.compile(r"""https?://[^\s<>"'\]\)]+""", re.I)


def strip_html(html):
    text = re.sub(r"(?is)<style[^>]*>.*?</style>", " ", html or "")
    text = re.sub(r"(?is)<script[^>]*>.*?</script>", " ", text)
    text = re.sub(r"<[^>]+>", " ", text)
    return re.sub(r"\s+", " ", decode_entities(text)).strip()


class _StaticMailHTML(HTMLParser):
    allowed = set("p div span br hr h1 h2 h3 h4 h5 h6 em strong i b u s small big sup sub pre code blockquote dl dt dd ul ol li table caption tbody thead tfoot tr td th".split())
    hidden = {"title", "script", "style", "noscript", "template", "iframe", "svg", "object"}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.result = []
        self.suppressed = []

    def handle_starttag(self, tag, attrs):
        if tag in self.hidden:
            self.suppressed.append(tag)
        elif not self.suppressed and tag in self.allowed:
            self.result.append(f"<{tag}>")

    def handle_endtag(self, tag):
        if self.suppressed and self.suppressed[-1] == tag:
            self.suppressed.pop()
        elif not self.suppressed and tag in self.allowed and tag not in {"br", "hr"}:
            self.result.append(f"</{tag}>")

    def handle_data(self, data):
        if not self.suppressed:
            self.result.append(escape(data, quote=False))


def sanitize_mail_html(html):
    parser = _StaticMailHTML()
    parser.feed(html or "")
    parser.close()
    return "".join(parser.result)


def decode_entities(value):
    return (value.replace("&nbsp;", " ").replace("&amp;", "&").replace("&quot;", '"')
            .replace("&#39;", "'").replace("&lt;", "<").replace("&gt;", ">"))


def _context(text, start, end, radius=40):
    return text[max(0, start - radius): min(len(text), end + radius)].strip()


def extract_codes(subject, body, html=None):
    plain = body if body else (strip_html(html) if html else "")
    full = f"{subject}\n{plain}"
    results = []
    results.extend(_numeric(full))
    results.extend(_alnum(full))
    if html:
        results.extend(_links(html))
    else:
        results.extend(_plain_links(full))
    results.sort(key=lambda item: item["confidence"], reverse=True)
    seen = set()
    unique = []
    for item in results:
        if item["value"] in seen:
            continue
        seen.add(item["value"])
        unique.append(item)
    return unique


def primary_code(subject, body, html=None):
    all_codes = extract_codes(subject, body, html)
    for item in all_codes:
        if item["type"] != "link" and item["confidence"] >= 0.5:
            return item
    return all_codes[0] if all_codes else None


def _numeric(text):
    found = []
    for match in NUMERIC.finditer(text):
        value = match.group(1)
        ctx = _context(text, match.start(), match.end())
        if value.isdigit() and 2020 <= int(value) <= 2039 and len(value) == 4:
            continue
        if PHONE.search(ctx) or MONEY.search(ctx):
            continue
        if len(value) == 5 and ZIP.search(ctx):
            continue
        confidence = 0.90 if CODE_KEYWORDS.search(ctx) else 0.3
        if len(value) == 6:
            confidence += 0.05
        if re.search(r"[:：]\s*\d", ctx):
            confidence += 0.05
        found.append({"type": "numeric", "value": value, "confidence": min(confidence, 1), "context": ctx})
    return found


def _alnum(text):
    found = []
    for match in ALNUM.finditer(text):
        value = match.group(1)
        if not any(ch.isalpha() for ch in value) or not any(ch.isdigit() for ch in value):
            continue
        ctx = _context(text, match.start(), match.end())
        if not CODE_KEYWORDS.search(ctx):
            continue
        found.append({"type": "alphanumeric", "value": value, "confidence": 0.75, "context": ctx})
    return found


def _links(html):
    found = []
    for match in HREF.finditer(html):
        url = decode_entities(match.group(1))
        if not url.lower().startswith("http") or not LINK_KEYWORDS.search(url) or UNSUBSCRIBE.search(url):
            continue
        confidence = 0.65
        if re.search(r"verify|confirm|activate", url, re.I):
            confidence = 0.88
        if re.search(r"magic|login.*token|auth.*token", url, re.I):
            confidence = 0.85
        if re.search(r"token=|code=|key=", url, re.I):
            confidence += 0.08
        found.append({"type": "link", "value": url, "confidence": min(confidence, 1), "context": url[:80]})
    return found


def _plain_links(text):
    found = []
    for match in PLAIN_LINK.finditer(text):
        url = match.group(0)
        if not LINK_KEYWORDS.search(url) or UNSUBSCRIBE.search(url):
            continue
        confidence = 0.85 if re.search(r"verify|confirm|activate", url, re.I) else 0.60
        found.append({"type": "link", "value": url, "confidence": confidence, "context": url[:80]})
    return found


def make_service_alias(email, service):
    text = (email or "").strip()
    if "@" not in text:
        return text
    user, domain = text.split("@", 1)
    base = user.split("+", 1)[0]
    tag = service.lower().replace("https://", "").replace("http://", "")
    tag = tag.split("/", 1)[0]
    if "." in tag:
        tag = tag.split(".", 1)[0]
    tag = re.sub(r"[^a-z0-9]", "", tag) or "service"
    return f"{base}+{tag}@{domain}"


def generate_aliases(email, count=20, options=None, rng=None):
    options = options or {}
    rng = rng or random.SystemRandom()
    text = (email or "").strip()
    if "@" not in text or count <= 0:
        return []
    user, domain = text.split("@", 1)
    domain = domain.lower()
    if domain in ("gmail.com", "googlemail.com"):
        return _gmail(user, count, options, rng)
    return _generic(user, domain, count, options, rng)


def _gmail(raw_user, count, options, rng):
    base = raw_user.split("+", 1)[0].replace(".", "").lower()
    if not base:
        return []
    results = [f"{base}@gmail.com"]
    if options.get("useGooglemailDomain"):
        results.append(f"{base}@googlemail.com")
    pool = "abcdefghijklmnopqrstuvwxyz0123456789"
    attempts = 0
    seen = set(results)
    while len(results) < count and attempts < max(count * 30, 2000):
        attempts += 1
        local = base
        if options.get("useDots", True) and len(base) >= 2:
            chars = []
            for index, char in enumerate(base):
                chars.append(char)
                if index < len(base) - 1 and rng.random() < 0.5:
                    chars.append(".")
            local = "".join(chars)
        if options.get("usePlus", True):
            tag = (options.get("plusTag") or "").strip()
            if not tag:
                length = max(2, int(options.get("randomPlusCount") or 4))
                tag = "".join(rng.choice(pool) for _ in range(length))
            local = f"{local}+{tag}"
        target = "googlemail.com" if options.get("useGooglemailDomain") and rng.random() < 0.5 else "gmail.com"
        alias = f"{local}@{target}"
        if alias not in seen:
            seen.add(alias)
            results.append(alias)
    return results[:count]


def _generic(raw_user, domain, count, options, rng):
    base = raw_user.split("+", 1)[0]
    if not base:
        return []
    results = [f"{base}@{domain}"]
    pool = "abcdefghijklmnopqrstuvwxyz0123456789"
    seen = set(results)
    attempts = 0
    while len(results) < count and attempts < max(count * 20, 1000):
        attempts += 1
        fixed = (options.get("plusTag") or "").strip()
        if fixed:
            tag = fixed + "".join(rng.choice(pool) for _ in range(3))
        else:
            length = max(3, int(options.get("randomPlusCount") or 4))
            tag = "".join(rng.choice(pool) for _ in range(length))
        alias = f"{base}+{tag}@{domain}"
        if alias not in seen:
            seen.add(alias)
            results.append(alias)
    return results[:count]


class MailStore:
    def __init__(self, root: Path):
        self.root = Path(root)
        self.library_path = self.root / "Library.json"
        self.cache_path = self.root / "MailCache.json"
        self.submission_path = self.root / "MailSubmissions.json"
        self.authorized = set()
        self.library = None
        self.messages = []
        self.submissions = []

    def load(self):
        self.root.mkdir(parents=True, exist_ok=True)
        if self.library_path.exists():
            self.library = json.loads(self.library_path.read_text(encoding="utf-8"))
        else:
            if self.cache_path.exists() or self.submission_path.exists():
                raise AppError("邮件资料缺失，已停止写入。")
            self.library = {
                "schemaVersion": 1,
                "accounts": [],
                "identities": [],
                "platforms": [],
                "drafts": [],
                "preferences": {"syncMinutes": 15, "fetchLimit": 50, "appearance": "system"},
            }
            self._write_library()
        self.messages = json.loads(self.cache_path.read_text(encoding="utf-8")) if self.cache_path.exists() else []
        self.submissions = json.loads(self.submission_path.read_text(encoding="utf-8")) if self.submission_path.exists() else []
        if self.library.get("schemaVersion") != 1 or any(not isinstance(self.library.get(key), list) for key in ("accounts", "identities", "platforms", "drafts")):
            raise AppError("邮件资料格式无效或版本过新，已停止写入。")
        if not isinstance(self.messages, list) or not isinstance(self.submissions, list):
            raise AppError("邮件缓存或发送记录格式无效，已停止写入。")
        if not isinstance(self.library.get("preferences"), dict):
            raise AppError("邮件偏好资料格式无效，已停止写入。")
        return self.library

    def save_account(self, account):
        self._ensure()
        email = (account.get("email") or "").strip()
        if not re.fullmatch(r"[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+", email) or len(email) > 320:
            raise AppError("邮箱地址无效。")
        account_id = account.get("id") or str(uuid.uuid4())
        existing = next((entry for entry in self.library["accounts"] if entry["id"] == account_id), {})
        if any(entry["id"] != account_id and entry["email"].casefold() == email.casefold() for entry in self.library["accounts"]):
            raise AppError("此邮箱已登记。")
        account = {**existing, **account}
        hosts = [account.get(key, "") for key in ("imapHost", "smtpHost")]
        if any(host and (not isinstance(host, str) or not re.fullmatch(r"[\w.:-]+", host)) for host in hosts):
            raise AppError("服务器地址无效。")
        try:
            ports = [int(account.get(key) or default) for key, default in (("imapPort", 993), ("smtpPort", 465))]
        except (TypeError, ValueError) as exc:
            raise AppError("服务器端口无效。") from exc
        if any(not 1 <= port <= 65535 for port in ports):
            raise AppError("服务器端口无效。")
        identity_id = account.get("identityID")
        if identity_id and not any(entry["id"] == identity_id for entry in self.library["identities"]):
            raise AppError("关联的身份不存在。")
        cleaned = {
            **existing,
            "id": account_id,
            "email": email,
            "displayName": account.get("displayName") or email,
            "username": account.get("username") or email,
            "provider": account.get("provider") or "imap",
            "identityID": identity_id,
            "tags": account.get("tags") or [],
            "aliases": account.get("aliases") or [],
            "signature": account.get("signature") or "",
            "enabled": bool(account.get("enabled", True)),
            "auth": account.get("auth") if account.get("auth") in ("password", "google", "microsoft") else "password",
            "imapHost": hosts[0] or "",
            "imapPort": ports[0],
            "imapTLS": bool(account.get("imapTLS", True)),
            "smtpHost": hosts[1] or "",
            "smtpPort": ports[1],
            "smtpTLS": bool(account.get("smtpTLS", True)),
            "sentFolder": account.get("sentFolder") or "Sent",
            "lastSync": account.get("lastSync"),
            "syncError": None,
        }
        # Preserve cached connection state only while the connection configuration stays the same.
        if any(existing.get(key) != cleaned[key] for key in ("email", "username", "enabled", "auth", "imapHost", "imapPort", "imapTLS", "smtpHost", "smtpPort", "smtpTLS")):
            self.authorized.discard(account_id)
        for field in ("password", "secret", "token", "refreshToken", "accessToken"):
            cleaned.pop(field, None)
        accounts = self.library["accounts"]
        for index, existing in enumerate(accounts):
            if existing["id"] == account_id:
                accounts[index] = cleaned
                break
        else:
            accounts.append(cleaned)
        self._write_library()
        return cleaned

    def authorize(self, account_id):
        self._ensure()
        if not self.account(account_id).get("enabled", True):
            raise AppError("此邮箱仅登记，编辑后可启用收发。")
        self.authorized.add(account_id)
        return True

    def sync(self, account_id, transport):
        self._ensure()
        if account_id not in self.authorized:
            raise AppError("这个邮箱还没有连接。请先明确连接，再收取邮件。")
        incoming = transport(account_id)
        if isinstance(incoming, tuple):
            incoming, folders = incoming
            self.account(account_id)["folders"] = folders
        by_id = {item["id"]: item for item in self.messages}
        for message in incoming:
            previous = by_id.get(message["id"])
            if previous and previous.get("loaded") and not message.get("loaded"):
                for key in ("body", "html", "loaded", "attachments", "preview"):
                    if key in previous:
                        message[key] = previous[key]
            by_id[message["id"]] = message
        self.messages = list(by_id.values())
        self._write_cache()
        for account in self.library["accounts"]:
            if account["id"] == account_id:
                account["lastSync"] = time.time()
                account["syncError"] = None
        self._write_library()
        return [item for item in self.messages if item.get("accountID") == account_id]

    def save_draft(self, draft):
        self._ensure()
        draft_id = draft.get("id") or str(uuid.uuid4())
        if any(item["draftID"] == draft_id and item["phase"] in ("accepted", "completed", "uncertain") for item in self.submissions):
            raise AppError("此邮件已进入发送记录。请核对状态后新建草稿。")
        attachments = draft.get("attachments") or []
        if not isinstance(attachments, list) or len(attachments) > 24:
            raise AppError("附件超出限制。")
        total = 0
        for attachment in attachments:
            if not isinstance(attachment, dict) or not isinstance(attachment.get("filename"), str):
                raise AppError("附件格式无效。")
            try:
                total += len(base64.b64decode(attachment.get("base64", ""), validate=True))
            except ValueError as exc:
                raise AppError("附件格式无效。") from exc
        if total > MAX_MAIL_BYTES:
            raise AppError("附件总大小超过 25 MB。")
        cleaned = {
            "id": draft_id,
            "accountID": draft.get("accountID"),
            "to": draft.get("to") or [],
            "cc": draft.get("cc") or [],
            "bcc": draft.get("bcc") or [],
            "from": draft.get("from") or "",
            "inReplyTo": draft.get("inReplyTo") or "",
            "subject": draft.get("subject") or "",
            "body": draft.get("body") or "",
            "attachments": attachments,
            "updatedAt": time.time(),
        }
        drafts = self.library["drafts"]
        for index, existing in enumerate(drafts):
            if existing["id"] == draft_id:
                drafts[index] = cleaned
                break
        else:
            drafts.append(cleaned)
        self._write_library()
        return cleaned

    def stage_submission(self, draft_id):
        self._ensure()
        if any(item["draftID"] == draft_id and item["phase"] in ("accepted", "completed", "uncertain") for item in self.submissions):
            raise AppError("这封邮件已经进入发送记录，没有重复提交。")
        record = {"id": str(uuid.uuid4()), "draftID": draft_id, "phase": "pending", "createdAt": time.time()}
        self.submissions.append(record)
        self._write_submissions()
        record["phase"] = "accepted"
        self._write_submissions()
        return record

    def complete_submission(self, submission_id):
        for record in self.submissions:
            if record["id"] == submission_id:
                record["phase"] = "completed"
                self._write_submissions()
                return record
        raise AppError("找不到发送记录。")

    def account(self, account_id):
        return self._record(self.library["accounts"], account_id, "邮箱不存在。")

    def message(self, message_id):
        return self._record(self.messages, message_id, "邮件不存在。")

    def draft(self, draft_id):
        return self._record(self.library["drafts"], draft_id, "草稿不存在。")

    def _record(self, records, record_id, error):
        match = next((record for record in records if record["id"] == record_id), None)
        if match is None:
            raise AppError(error)
        return match

    def delete_account(self, account_id):
        account = self.account(account_id)
        self.authorized.discard(account_id)
        self.library["accounts"].remove(account)
        self.messages = [item for item in self.messages if item.get("accountID") != account_id]
        self._write_cache()
        self._write_library()

    def save_record(self, kind, record):
        if kind not in ("identities", "platforms"):
            raise AppError("资料类型无效。")
        title = (record.get("name") or "").strip()
        if not title or len(title) > 200:
            raise AppError("请填写有效名称。")
        record_id = record.get("id") or str(uuid.uuid4())
        keys = ("description", "color", "icon") if kind == "identities" else (
            "accountID", "kind", "url", "username", "address", "loginMethod", "roles", "status", "notes"
        )
        item = {"id": record_id, "name": title, **{key: record[key] for key in keys if key in record}}
        if kind == "platforms" and item.get("accountID"):
            self.account(item["accountID"])
        records = self.library[kind]
        records[:] = [old for old in records if old["id"] != record_id] + [item]
        self._write_library()
        return item

    def delete_record(self, kind, record_id):
        if kind not in ("identities", "platforms", "drafts"):
            raise AppError("资料类型无效。")
        if kind == "drafts" and any(entry["draftID"] == record_id and entry["phase"] in ("accepted", "uncertain") for entry in self.submissions):
            raise AppError("这封邮件的发送状态仍需核对。")
        self.library[kind].remove(self._record(self.library[kind], record_id, "资料不存在。"))
        if kind == "identities":
            for account in self.library["accounts"]:
                if account.get("identityID") == record_id:
                    account["identityID"] = None
        self._write_library()

    def save_preferences(self, updates):
        from .mail_floating_layout import MailPlacement, mail_opacity

        choices = {"appearance": ("system", "light", "dark"), "syncMinutes": (0, 1, 3, 5, 10, 15, 30, 60),
                   "fetchLimit": (25, 30, 50, 80, 100, 150, 200, 300), "showPreviews": (True, False),
                   "floatingVisible": (True, False), "keepOnTop": (True, False)}
        oauth = {"googleClientID", "microsoftClientID", "microsoftTenant"}
        for key, value in updates.items():
            if key in oauth:
                if not isinstance(value, str) or len(value) > 256 or (value and not re.fullmatch(r"[a-zA-Z0-9._-]+", value)):
                    raise AppError("网页登录客户端标识无效。")
            elif key == "floatingPlacement":
                if value is not None and not MailPlacement.valid(value):
                    raise AppError("邮件悬浮窗位置无效。")
            elif key == "floatingOpacity":
                if type(value) not in (int, float) or mail_opacity(value) != value:
                    raise AppError("邮件悬浮窗透明度无效。")
            elif key not in choices or value not in choices[key] or (type(choices[key][0]) is bool and type(value) is not bool):
                raise AppError("邮件设置无效。")
        previous = self.library["preferences"]
        self.library["preferences"] = previous | updates
        try:
            self._write_library()
        except OSError:
            self.library["preferences"] = previous
            raise

    def _ensure(self):
        if self.library is None:
            self.load()

    def _write_library(self):
        self._atomic(self.library_path, self.library)

    def _write_cache(self):
        self._atomic(self.cache_path, self.messages)

    def _write_submissions(self):
        self._atomic(self.submission_path, self.submissions)

    def _atomic(self, path: Path, value):
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_name(path.name + f".tmp-{uuid.uuid4().hex}")
        temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True), encoding="utf-8")
        os.replace(temporary, path)
