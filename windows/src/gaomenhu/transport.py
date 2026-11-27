"""邮件 OAuth 授权地址和 IMAP/SMTP。未连接的账号不会发出网络请求。"""

import base64
import hashlib
import imaplib
import re
import smtplib
import ssl
from contextlib import contextmanager
from email import policy
from email.message import EmailMessage
from email.parser import BytesParser
from email.utils import formatdate, getaddresses, make_msgid, parsedate_to_datetime
from urllib.parse import urlencode

from .errors import AppError

MAX_MAIL_BYTES = 25 * 1024 * 1024


def code_challenge(verifier: str) -> str:
    import base64
    digest = hashlib.sha256(verifier.encode("ascii")).digest()
    return base64.urlsafe_b64encode(digest).decode("ascii").rstrip("=")


def authorization_url(provider, client_id, redirect_uri, state, verifier, nonce, tenant="common", login_hint=""):
    if provider not in ("google", "microsoft"):
        raise AppError("不支持这个邮箱授权提供方。")
    if not client_id or any(ch.isspace() for ch in client_id) or len(client_id) >= 1024:
        raise AppError("OAuth 客户端标识无效。")
    if provider == "google":
        base = "https://accounts.google.com/o/oauth2/v2/auth"
        scope = "https://mail.google.com/ openid email"
        extra = {"access_type": "offline", "prompt": "consent select_account"}
    else:
        if not tenant or len(tenant) >= 256 or any(ch not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-" for ch in tenant):
            raise AppError("Microsoft 租户标识无效。")
        base = f"https://login.microsoftonline.com/{tenant}/oauth2/v2.0/authorize"
        scope = "https://outlook.office.com/IMAP.AccessAsUser.All https://outlook.office.com/SMTP.Send offline_access openid profile email"
        extra = {"response_mode": "query", "prompt": "select_account"}
    query = {
        "client_id": client_id,
        "response_type": "code",
        "redirect_uri": redirect_uri,
        "scope": scope,
        "state": state,
        "nonce": nonce,
        "code_challenge": code_challenge(verifier),
        "code_challenge_method": "S256",
        **extra,
    }
    if login_hint:
        query["login_hint"] = login_hint
    return base + "?" + urlencode(query)


def _smtp_client(account):
    host = account.get("smtpHost") or ""
    if not host:
        raise AppError("请先填写 SMTP 主机。")
    port = int(account.get("smtpPort") or 465)
    if account.get("smtpTLS", True) and port == 465:
        return smtplib.SMTP_SSL(host, port, timeout=20, context=ssl.create_default_context())
    client = smtplib.SMTP(host, port, timeout=20)
    try:
        client.ehlo()
        if account.get("smtpTLS", True):
            client.starttls(context=ssl.create_default_context())
            client.ehlo()
        return client
    except Exception:
        client.close()
        raise


def _imap_client(account):
    host = account.get("imapHost") or ""
    if not host:
        raise AppError("请先填写 IMAP 主机。")
    port = int(account.get("imapPort") or 993)
    if account.get("imapTLS", True) and port != 143:
        return imaplib.IMAP4_SSL(host, port, timeout=20, ssl_context=ssl.create_default_context())
    client = imaplib.IMAP4(host, port, timeout=20)
    try:
        if account.get("imapTLS", True):
            client.starttls(ssl.create_default_context())
        return client
    except Exception:
        client.shutdown()
        raise


def _xoauth(user, token):
    return f"user={user}\x01auth=Bearer {token}\x01\x01"


def _authenticate(client, account, credential, smtp=False):
    if not credential:
        raise AppError("邮箱凭据不可用。")
    login = account.get("username") or account["email"]
    if account.get("auth", "password") == "password":
        client.login(login, credential)
    elif smtp:
        client.auth("XOAUTH2", lambda challenge=None: _xoauth(login, credential) if challenge is None else "")
    else:
        client.authenticate("XOAUTH2", lambda challenge: _xoauth(login, credential).encode("utf-8") if not challenge else b"")


@contextmanager
def imap_connection(account, credential):
    client = _imap_client(account)
    try:
        _authenticate(client, account, credential)
        yield client
    finally:
        try:
            client.logout()
        except (OSError, imaplib.IMAP4.error):
            client.shutdown()


@contextmanager
def smtp_connection(account, credential):
    client = _smtp_client(account)
    try:
        _authenticate(client, account, credential, smtp=True)
        yield client
    finally:
        try:
            client.quit()
        except (OSError, smtplib.SMTPException):
            client.close()


def check_connection(account, credential):
    with imap_connection(account, credential), smtp_connection(account, credential):
        pass


def _mailbox(folder):
    return '"' + folder.replace("\\", "\\\\").replace('"', '\\"') + '"'


def _uidvalidity(client):
    _, values = client.response("UIDVALIDITY")
    return (values[0] or b"0").decode("ascii") if values else "0"


def _status(response, error):
    status, values = response
    if status != "OK":
        raise AppError(error)
    return values


def list_folders(client):
    folders = []
    for entry in _status(client.list(), "无法读取邮箱文件夹。"):
        if not isinstance(entry, bytes):
            continue
        match = re.fullmatch(rb'\(([^)]*)\) (?:NIL|"[^"]*") (.+)', entry)
        if not match:
            continue
        flags, name = match.groups()
        try:
            path = name.decode("ascii")
        except UnicodeError:
            continue
        if path.startswith('"') and path.endswith('"'):
            path = re.sub(r'\\(.)', r'\1', path[1:-1])
        title = re.sub(r"&([A-Za-z0-9+,]*)-", _decode_folder, path)
        folders.append({"path": path, "displayName": title, "selectable": b"\\noselect" not in flags.lower()})
    return folders


def _decode_folder(match):
    encoded = match[1].replace(",", "/")
    if not encoded:
        return "&"
    try:
        return base64.b64decode(encoded + "=" * (-len(encoded) % 4), validate=True).decode("utf-16-be")
    except ValueError:
        return match[0]


def _parse_message(raw):
    return BytesParser(policy=policy.default).parsebytes(raw)


def _text(message, key):
    return str(message.get(key, ""))


def _date(message):
    try:
        return parsedate_to_datetime(_text(message, "Date")).timestamp()
    except (TypeError, ValueError, OverflowError, OSError):
        return 0


def _fetch_parts(client, uid, fields):
    fetched = _status(client.uid("FETCH", uid, fields), "无法读取这封邮件。")
    return next((entry for entry in fetched if isinstance(entry, tuple)), (b"", b""))


def fetch_mailbox(account, credential, folder="INBOX", limit=50):
    with imap_connection(account, credential) as client:
        folders = list_folders(client)
        _status(client.select(_mailbox(folder), readonly=True), "无法打开此邮件文件夹。")
        version = _uidvalidity(client)
        result = _status(client.uid("SEARCH", None, "ALL"), "无法读取邮件列表。")
        uids = (result[0] or b"").split()[-max(1, min(limit, 500)):]
        messages = []
        for uid in reversed(uids):
            flags, header = _fetch_parts(client, uid, "(FLAGS RFC822.SIZE BODY.PEEK[HEADER.FIELDS (SUBJECT FROM TO CC DATE REPLY-TO MESSAGE-ID)])")
            if not header:
                continue
            parsed = _parse_message(header)
            size = re.search(rb"RFC822.SIZE (\d+)", flags)
            messages.append({
                "id": f"{account['id']}|{folder}|{version}|{uid.decode('ascii')}", "accountID": account["id"],
                "folder": folder, "uid": uid.decode("ascii"), "uidValidity": version,
                "subject": _text(parsed, "Subject"), "from": _text(parsed, "From"), "to": _text(parsed, "To"),
                "cc": _text(parsed, "Cc"), "replyTo": _text(parsed, "Reply-To"), "messageID": _text(parsed, "Message-ID"),
                "date": _date(parsed), "isRead": b"\\Seen" in flags, "isFlagged": b"\\Flagged" in flags,
                "size": int(size[1]) if size else None, "loaded": False,
            })
        return messages, folders


def fetch_inbox(account, password, limit=50):
    return fetch_mailbox(account, password, limit=limit)[0]


def _open_message_folder(client, message, readonly):
    folder = message.get("folder") or "INBOX"
    _status(client.select(_mailbox(folder), readonly=readonly), "无法打开此邮件文件夹。")
    version = message.get("uidValidity") or message["id"].rsplit("|", 2)[-2]
    if version != "0" and _uidvalidity(client) != version:
        raise AppError("服务器已更换文件夹版本，请重新同步后再操作。")
    uid = message.get("uid") or message["id"].rsplit("|", 1)[-1]
    if not re.fullmatch(r"[0-9]+", uid):
        raise AppError("邮件标识无效。")
    return uid


def load_message(account, credential, message):
    with imap_connection(account, credential) as client:
        uid = _open_message_folder(client, message, readonly=True)
        sizes = _status(client.uid("FETCH", uid, "(RFC822.SIZE)"), "无法读取邮件大小。")
        match = re.search(rb"RFC822.SIZE (\d+)", next((entry for entry in sizes if isinstance(entry, bytes)), b""))
        if not match or int(match[1]) > MAX_MAIL_BYTES:
            raise AppError("邮件超过此设备可读取的大小。")
        _, raw = _fetch_parts(client, uid, "(BODY.PEEK[])")
        if not raw or len(raw) > MAX_MAIL_BYTES:
            raise AppError("邮件正文不可用。")
    parsed = _parse_message(raw)
    body = parsed.get_body(preferencelist=("plain",))
    html = parsed.get_body(preferencelist=("html",))
    attachments = []
    for part in parsed.walk():
        if part.is_multipart() or (part.get_content_disposition() != "attachment" and not part.get_filename()):
            continue
        data = part.get_payload(decode=True) or b""
        attachments.append({
            "id": str(len(attachments)), "filename": part.get_filename() or "附件",
            "type": part.get_content_type(), "byteCount": len(data), "base64": base64.b64encode(data).decode("ascii"),
        })
    message.update(
        loaded=True, body=_body_text(body), html=_body_text(html), attachments=attachments,
        preview=_body_text(body)[:180],
    )
    return message


def _body_text(part):
    if part is None:
        return ""
    try:
        return part.get_content()
    except (LookupError, UnicodeError):
        return (part.get_payload(decode=True) or b"").decode("utf-8", "replace")


def set_mail_flag(account, credential, message, flag, enabled):
    with imap_connection(account, credential) as client:
        uid = _open_message_folder(client, message, readonly=False)
        mode = "+FLAGS.SILENT" if enabled else "-FLAGS.SILENT"
        _status(client.uid("STORE", uid, mode, "(" + flag + ")"), "无法更新服务器邮件标记。")


def move_mail(account, credential, message, folder):
    with imap_connection(account, credential) as client:
        uid = _open_message_folder(client, message, readonly=False)
        if "MOVE" not in client.capabilities:
            raise AppError("服务器未提供安全的邮件移动命令。")
        status, _ = client._simple_command("UID", "MOVE", uid, _mailbox(folder))
        if status != "OK":
            raise AppError("无法移动这封邮件。")


def prepare_outgoing(account, draft):
    message = EmailMessage()
    message["From"] = draft.get("from") or account["email"]
    allowed = [account["email"], *account.get("aliases", [])]
    senders = message["From"].addresses
    if len(senders) != 1 or senders[0].addr_spec.casefold() not in [address.casefold() for address in allowed if isinstance(address, str)]:
        raise AppError("请使用邮箱主地址或已登记的发件别名。")
    for key in ("to", "cc", "bcc"):
        raw = draft.get(key) or []
        values = [raw] if isinstance(raw, str) else raw
        if values:
            message[key] = ", ".join(values)
            if not getaddresses(values) or any("@" not in email for _, email in getaddresses(values)):
                raise AppError("收件人地址无效。")
    if not message["To"]:
        raise AppError("请填写收件人。")
    message["Subject"] = draft.get("subject") or ""
    message["Date"] = formatdate()
    message["Message-ID"] = make_msgid(domain=account["email"].split("@")[-1])
    if draft.get("inReplyTo"):
        message["In-Reply-To"] = draft["inReplyTo"]
        message["References"] = draft["inReplyTo"]
    message.set_content(draft.get("body") or "")
    for part in draft.get("attachments") or []:
        content_type = part.get("type", "application/octet-stream").split("/", 1)
        message.add_attachment(base64.b64decode(part["base64"], validate=True), maintype=content_type[0],
                               subtype=content_type[-1], filename=part["filename"])
    return message


def send_mail(account, credential, draft, outgoing=None):
    message = outgoing or prepare_outgoing(account, draft)
    with smtp_connection(account, credential) as client:
        refused = client.send_message(message)
        if refused:
            raise AppError("部分收件地址未被服务器接收，请核对发送状态。")
    return message
