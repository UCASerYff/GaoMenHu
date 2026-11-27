"""System-browser authorization for user-configured desktop mail clients."""

import hmac
import json
import re
import secrets
import threading
import time
import uuid
import webbrowser
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlencode, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

import jwt
from jwt.algorithms import RSAAlgorithm

from .errors import AppError
from .transport import authorization_url, check_connection

CONFIG = {
    "google": {
        "imapHost": "imap.gmail.com", "imapPort": 993, "smtpHost": "smtp.gmail.com", "smtpPort": 465,
        "token_url": "https://oauth2.googleapis.com/token", "jwks": "https://www.googleapis.com/oauth2/v3/certs",
    },
    "microsoft": {
        "imapHost": "outlook.office365.com", "imapPort": 993, "smtpHost": "smtp.office365.com", "smtpPort": 587,
        "token_url": "https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token",
        "jwks": "https://login.microsoftonline.com/{tenant}/discovery/v2.0/keys",
    },
}
HOST_KEYS = ("imapHost", "imapPort", "smtpHost", "smtpPort")
CLIENT_SECRET = "oauth-client-google"
MAX_WAIT = 300


class _FixedProviderEndpoint(HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, newurl):
        raise AppError("服务商返回意外的授权地址。")


def _provider(provider, preferences):
    if provider not in CONFIG:
        raise AppError("请选择支持网页登录的邮件服务商。")
    client = preferences.get(provider + "ClientID") or ""
    if not client:
        raise AppError("请先填写邮件网页登录的客户端 ID。")
    tenant = preferences.get("microsoftTenant") or "common"
    return client, tenant if provider == "microsoft" else ""


def _request(url, form=None):
    request = Request(url, headers={"Accept": "application/json"}, data=urlencode(form).encode("ascii") if form else None)
    with build_opener(_FixedProviderEndpoint()).open(request, timeout=15) as response:
        if response.geturl() != url:
            raise AppError("服务商返回意外的授权地址。")
        data = response.read(1024 * 1024 + 1)
    if len(data) > 1024 * 1024:
        raise AppError("服务商返回的授权数据过大。")
    result = json.loads(data)
    if not isinstance(result, dict):
        raise AppError("服务商返回的授权数据无效。")
    return result


def _verify_id_token(attempt, token, access_token):
    provider, client, tenant = (attempt[key] for key in ("provider", "client", "tenant"))
    if not isinstance(token, str) or len(token) > 32768:
        raise AppError("服务商未返回可核对的身份令牌。")
    try:
        header = jwt.get_unverified_header(token)
        if header.get("alg") != "RS256" or not isinstance(header.get("kid"), str):
            raise ValueError("unexpected signing algorithm")
        options = {"require": ["sub", "exp", "iat", "iss", "aud", "nonce"]}
        keys = _request(CONFIG[provider]["jwks"].format(tenant=tenant))["keys"]
        key_data = next(key for key in keys if key.get("kid") == header["kid"] and key.get("kty") == "RSA")
        claims = jwt.decode(token, RSAAlgorithm.from_jwk(json.dumps(key_data)), algorithms=["RS256"],
                            audience=client, options=options, leeway=30)
        if claims.get("nonce") != attempt["nonce"] or (claims.get("azp") and claims["azp"] != client):
            raise ValueError("invalid nonce or authorized party")
        if claims.get("at_hash"):
            import base64
            import hashlib
            bound = base64.urlsafe_b64encode(hashlib.sha256(access_token.encode("ascii")).digest()[:16]).decode().rstrip("=")
            if not hmac.compare_digest(bound, claims["at_hash"]):
                raise ValueError("access token mismatch")
        if provider == "google":
            if claims["iss"] not in ("accounts.google.com", "https://accounts.google.com") or claims.get("email_verified") is not True:
                raise ValueError("unverified issuer or email")
            return claims.get("email")
        token_tenant = str(uuid.UUID(claims["tid"]))
        issuer = f"https://login.microsoftonline.com/{token_tenant}/v2.0"
        expected_key_issuer = key_data.get("issuer", issuer).replace("{tenantid}", token_tenant)
        if claims["iss"] != issuer or expected_key_issuer != issuer:
            raise ValueError("invalid tenant issuer")
        if tenant not in ("common", "organizations", "consumers") and re.fullmatch(r"[a-fA-F0-9-]{36}", tenant):
            if str(uuid.UUID(tenant)) != token_tenant:
                raise ValueError("unexpected tenant")
        return claims.get("email") or claims.get("preferred_username")
    except (KeyError, StopIteration, ValueError, TypeError, jwt.PyJWTError) as exc:
        raise AppError("服务商网页登录身份核对失败。") from exc


def _google_secret(service):
    service.mail_vault.unlock(service.clock())
    return service.mail_vault.cache.get(CLIENT_SECRET)


def _token_request(service, provider, client, tenant, form):
    form = {"client_id": client, **form}
    if provider == "google":
        secret = _google_secret(service)
        if secret:
            form["client_secret"] = secret
    try:
        result = _request(CONFIG[provider]["token_url"].format(tenant=tenant), form)
        token = result.get("access_token")
        if not isinstance(token, str) or not token or len(token) > 65536 or any(char in token for char in "\x00\r\n\x01"):
            raise ValueError("unusable access token")
        return result
    except (OSError, ValueError) as exc:
        raise AppError("服务商授权已失效或无法交换令牌，请重新授权。") from exc


def _pack(client, tenant, tokens, prior=None):
    refresh = tokens.get("refresh_token") or prior
    if not isinstance(refresh, str) or not refresh:
        raise AppError("服务商未提供离线访问权限，请重新授权。")
    now = time.time()
    seconds = max(0, min(86400, int(tokens.get("expires_in") or 3600)))
    return {"client": client, "tenant": tenant, "access": tokens["access_token"], "refresh": refresh,
            "expires": now + seconds}


def _save(service, account_id, config):
    service.mail_vault.save(account_id, json.dumps(config, separators=(",", ":")), service.clock())


def access_token(service, account, stored):
    provider = account.get("auth")
    client, tenant = _provider(provider, service.mail_store().library["preferences"])
    expected = CONFIG[provider]
    if any(account.get(key) != expected[key] for key in HOST_KEYS) or not account.get("imapTLS") or not account.get("smtpTLS"):
        raise AppError("网页授权邮箱需要使用服务商的安全服务器设置，请重新授权。")
    try:
        record = json.loads(stored)
        if record["client"] != client or record["tenant"] != tenant:
            raise ValueError("client configuration changed")
        if record["expires"] > time.time() + 90:
            return record["access"]
        refresh = record["refresh"]
    except (ValueError, KeyError, TypeError) as exc:
        raise AppError("邮箱需要重新完成网页登录授权。") from exc
    tokens = _token_request(service, provider, client, tenant, {"grant_type": "refresh_token", "refresh_token": refresh})
    record = _pack(client, tenant, tokens, refresh)
    _save(service, account["id"], record)
    return record["access"]


class MailOAuth:
    def __init__(self, service):
        self.service = service
        self.attempts = {}
        self.lock = threading.RLock()

    def start(self, provider, account_id):
        with self.service.mail_lock:
            store = self.service.mail_store()
            client, tenant = _provider(provider, store.library["preferences"])
            account = store.account(account_id) if account_id else None
            if account and account.get("auth") != provider:
                raise AppError("授权服务商与已登记邮箱不匹配。")
            if account and not account.get("enabled", True):
                raise AppError("请先启用该邮箱的收发。")
        state = secrets.token_urlsafe(32)
        attempt = {"id": str(uuid.uuid4()), "nonce": secrets.token_urlsafe(32), "state": state,
                   "verifier": secrets.token_urlsafe(64), "provider": provider, "client": client, "tenant": tenant,
                   "accountID": account_id, "email": account["email"] if account else "", "status": "pending",
                   "expires": time.monotonic() + MAX_WAIT, "message": ""}
        owner = self

        class Callback(BaseHTTPRequestHandler):
            timeout = 3

            def log_message(self, format, *args):
                return

            def do_GET(self):
                parsed = urlsplit(self.path)
                try:
                    query = parse_qs(parsed.query, max_num_fields=24) if len(parsed.query) <= 65536 else {}
                except ValueError:
                    query = {}
                success = False
                if parsed.path == "/" and self.headers.get("Host") == attempt["host"]:
                    with owner.lock:
                        if attempt["status"] == "pending" and hmac.compare_digest(query.get("state", [""])[0].encode(), state.encode()):
                            code = query.get("code", [""])[0]
                            if code:
                                attempt["status"] = "checking"
                                threading.Thread(target=owner._complete, args=(attempt, code), daemon=True).start()
                                success = True
                            else:
                                attempt.update(status="failed", message="网页登录未完成。")
                text = "已收到服务商回复。请关闭浏览器页并返回搞门户核对授权状态。" if success else "网页登录回复无效或已取消，请返回搞门户。"
                body = ("<!doctype html><meta charset=utf-8><title>搞门户 · 邮件</title><p>" + text + "</p>").encode("utf-8")
                self.send_response(200 if success else 400)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Cache-Control", "no-store")
                self.send_header("Referrer-Policy", "no-referrer")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        with self.lock:
            now = time.monotonic()
            self.attempts = {key: value for key, value in self.attempts.items() if value["expires"] + 60 >= now}
            if any(value["status"] in ("pending", "checking","committing") for value in self.attempts.values()):
                raise AppError("已有网页登录正在进行。")
            listener = HTTPServer(("127.0.0.1", 0), Callback)
            listener.timeout = .4
            hostname = "localhost" if provider == "microsoft" else "127.0.0.1"
            attempt["host"] = f"{hostname}:{listener.server_port}"
            attempt["redirect"] = f"http://{attempt['host']}/"
            auth_url = authorization_url(provider, client, attempt["redirect"], state, attempt["verifier"],
                                         attempt["nonce"], tenant or "common", attempt["email"])
            self.attempts[attempt["id"]] = attempt
        threading.Thread(target=self._listen, args=(listener, attempt), daemon=True).start()
        # The caller clicked “网页登录添加”. No account or service automatically opens this page.
        try:
            if not webbrowser.open(auth_url):
                raise AppError("无法打开系统浏览器。")
        except Exception as exc:
            self.cancel(attempt["id"])
            raise AppError("无法打开系统浏览器。") from exc
        return {"id": attempt["id"]}

    def _listen(self, listener, attempt):
        try:
            while attempt["status"] == "pending" and time.monotonic() < attempt["expires"]:
                listener.handle_request()
            with self.lock:
                if attempt["status"] == "pending":
                    attempt.update(status="failed", message="网页登录已超时，请重新发起。")
        finally:
            listener.server_close()

    def _complete(self, attempt, code):
        provider, client, tenant = (attempt[key] for key in ("provider", "client", "tenant"))
        try:
            with self.service.mail_lock:
                tokens = _token_request(self.service, provider, client, tenant, {
                    "grant_type": "authorization_code", "code": code, "code_verifier": attempt["verifier"],
                    "redirect_uri": attempt["redirect"],
                })
            email = _verify_id_token(attempt, tokens.get("id_token"), tokens["access_token"])
            if not isinstance(email, str) or not re.fullmatch(r"[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+", email):
                raise AppError("服务商未返回可用于邮件登录的邮箱地址。")
            if attempt["email"] and email.casefold() != attempt["email"].casefold():
                raise AppError("网页登录的邮箱与已登记邮箱不一致。")
            account_id = attempt["accountID"] or str(uuid.uuid4())
            account = {"id": account_id, "email": email, "username": email, "provider": provider,
                       "auth": provider, "enabled": True, "imapTLS": True, "smtpTLS": True,
                       **{key: CONFIG[provider][key] for key in HOST_KEYS}}
            credential = _pack(client, tenant, tokens)
            check_connection(account, credential["access"])
            with self.service.lifecycle_lock, self.lock:
                if (self.service.stopping.is_set() or attempt["status"] != "checking"
                        or time.monotonic() >= attempt["expires"]):
                    return
                attempt["status"] = "committing"
            with self.service.mail_lock:
                store = self.service.mail_store()
                if _provider(provider, store.library["preferences"]) != (client, tenant):
                    raise AppError("网页登录配置已改变，请重新授权。")
                if attempt["accountID"] and store.account(account_id)["email"].casefold() != email.casefold():
                    raise AppError("已登记邮箱发生变化。")
                if any(other["id"] != account_id and other["email"].casefold() == email.casefold() for other in store.library["accounts"]):
                    raise AppError("此邮箱已登记。")
                self.service.mail_vault.unlock(self.service.clock())
                previous = self.service.mail_vault.cache.get(account_id)
                _save(self.service, account_id, credential)
                try:
                    store.save_account(account)
                    store.authorize(account_id)
                except Exception:
                    if previous:
                        self.service.mail_vault.save(account_id, previous, self.service.clock())
                    else:
                        self.service.mail_vault.remove(account_id, self.service.clock())
                    raise
            with self.lock:
                attempt.update(status="complete", accountID=account_id)
        except Exception as exc:
            with self.lock:
                if attempt["status"] in ("checking", "committing"):
                    message = str(exc) if isinstance(exc, AppError) else "无法验证邮箱收发登录，请核对服务商权限及网络。"
                    attempt.update(status="failed", message=message)

    def status(self, key):
        with self.lock:
            attempt = self.attempts.get(key)
            if not attempt:
                raise AppError("网页登录事务不存在。")
            status = attempt["status"]
            if status == "checking" and time.monotonic() >= attempt["expires"]:
                attempt.update(status="failed", message="邮箱登录检查已超时。")
            return {key: attempt[key] for key in ("status", "message", "accountID")}

    def cancel(self, key):
        with self.lock:
            attempt = self.attempts.get(key)
            if attempt and attempt["status"] in ("pending", "checking"):
                attempt.update(status="failed", message="已取消网页登录。")

    def cancel_pending(self):
        with self.lock:
            for key in self.attempts:
                self.cancel(key)

    def is_committing(self):
        with self.lock:
            return any(attempt["status"] == "committing" for attempt in self.attempts.values())
