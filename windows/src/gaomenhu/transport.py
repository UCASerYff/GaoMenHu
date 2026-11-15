"""邮件 OAuth 授权地址和 IMAP/SMTP。未连接的账号不会发出网络请求。"""

import hashlib
import imaplib
import smtplib
from email.message import EmailMessage
from urllib.parse import urlencode

from .errors import AppError


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


def fetch_inbox(account, password, limit=50):
    if account["id"] and not password:
        raise AppError("邮箱密码不可用。")
    host = account.get("imapHost") or ""
    if not host:
        raise AppError("请先填写 IMAP 主机。")
    port = int(account.get("imapPort") or 993)
    client = imaplib.IMAP4_SSL(host, port) if account.get("imapTLS", True) else imaplib.IMAP4(host, port)
    try:
        client.login(account["email"], password)
        client.select("INBOX", readonly=True)
        status, data = client.uid("SEARCH", None, "ALL")
        if status != "OK":
            raise AppError("无法读取收件箱。")
        uids = (data[0] or b"").split()[-max(1, min(limit, 500)):]
        messages = []
        for uid in uids:
            status, fetched = client.uid("FETCH", uid, "(BODY.PEEK[HEADER.FIELDS (SUBJECT FROM DATE)])")
            if status != "OK" or not fetched or not fetched[0]:
                continue
            header = fetched[0][1].decode("utf-8", "replace") if isinstance(fetched[0], tuple) else ""
            messages.append({
                "id": f"{account['id']}|INBOX|0|{uid.decode()}",
                "accountID": account["id"],
                "subject": _header(header, "Subject"),
                "from": _header(header, "From"),
                "loaded": False,
            })
        return messages
    finally:
        try:
            client.logout()
        except Exception:
            pass


def send_mail(account, password, draft):
    host = account.get("smtpHost") or ""
    if not host:
        raise AppError("请先填写 SMTP 主机。")
    message = EmailMessage()
    message["From"] = account["email"]
    message["To"] = ", ".join(draft.get("to") or [])
    message["Subject"] = draft.get("subject") or ""
    message.set_content(draft.get("body") or "")
    port = int(account.get("smtpPort") or 465)
    if account.get("smtpTLS", True):
        client = smtplib.SMTP_SSL(host, port, timeout=30)
    else:
        client = smtplib.SMTP(host, port, timeout=30)
    try:
        client.login(account["email"], password)
        client.send_message(message)
    finally:
        try:
            client.quit()
        except Exception:
            pass


def _header(text, name):
    prefix = name.lower() + ":"
    for line in text.splitlines():
        if line.lower().startswith(prefix):
            return line.split(":", 1)[1].strip()
    return ""
