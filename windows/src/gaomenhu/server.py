"""只监听 127.0.0.1 的本地网页。"""

import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

from . import VERSION_LABEL
from .backup import export_zip, read_zip
from .errors import AppError, RecoveryError
from .models import decode_library
from .transport import authorization_url


def asset_root():
    import sys
    if getattr(sys, "frozen", False):
        return Path(sys._MEIPASS) / "gaomenhu_assets"
    return Path(__file__).resolve().parent / "assets"


class PortalServer:
    def __init__(self, service, host="127.0.0.1", port=0):
        self.service = service
        handler = self._handler_class()
        self.httpd = ThreadingHTTPServer((host, port), handler)
        self.httpd.service = service
        self.port = self.httpd.server_address[1]

    def serve_forever(self):
        self.httpd.serve_forever(poll_interval=0.2)

    def shutdown(self):
        self.httpd.shutdown()
        self.httpd.server_close()

    def _handler_class(self):
        server = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                server._get(self)

            def do_POST(self):
                server._post(self)

            def log_message(self, fmt, *args):
                return

        return Handler

    def _get(self, handler):
        path = urlparse(handler.path).path
        if path in ("/", "/float"):
            page = (asset_root() / "index.html").read_text(encoding="utf-8")
            page = page.replace("__GAO_TOKEN__", self.service.page_token).replace("__GAO_VERSION__", VERSION_LABEL)
            if path == "/float":
                page = page.replace("<body>", '<body class="float-mode">', 1)
            self._bytes(handler, 200, page.encode("utf-8"), "text/html; charset=utf-8")
            return
        if path.startswith("/assets/"):
            name = Path(path).name
            target = asset_root() / name
            if target.is_file() and target.parent == asset_root():
                kind = "text/css; charset=utf-8" if name.endswith(".css") else "text/javascript; charset=utf-8"
                self._bytes(handler, 200, target.read_bytes(), kind)
                return
        self._bytes(handler, 404, b"not found", "text/plain; charset=utf-8")

    def _post(self, handler):
        path = urlparse(handler.path).path
        length = int(handler.headers.get("Content-Length") or 0)
        if length > 40_000_000:
            self._json(handler, 413, {"ok": False, "error": "请求过大。"})
            return
        raw = handler.rfile.read(length) if length else b"{}"
        try:
            payload = json.loads(raw.decode("utf-8") or "{}")
        except (UnicodeError, json.JSONDecodeError):
            self._json(handler, 400, {"ok": False, "error": "请求不是 JSON。"})
            return
        if not isinstance(payload, dict):
            payload = {}
        host_header = (handler.headers.get("Host") or "").split(":")[0]
        if host_header not in ("127.0.0.1", "localhost", "[::1]"):
            self._json(handler, 403, {"ok": False, "error": "只接受本机请求。"})
            return
        if path == "/api/native":
            if handler.headers.get("X-Gao-Host") != self.service.host_token:
                self._json(handler, 403, {"ok": False, "error": "助手令牌无效。"})
                return
            result = self.service.native_message(payload.get("message") or {}, payload.get("browser") or "")
            self._json(handler, 200, result)
            return
        if handler.headers.get("X-Gao-Token") != self.service.page_token:
            self._json(handler, 403, {"ok": False, "error": "页面令牌无效，请刷新。"})
            return
        try:
            result = self._dispatch(path, payload)
            status = 200
        except RecoveryError as exc:
            result = {"ok": False, "error": str(exc), "state": self.service.state()}
            status = 409
        except AppError as exc:
            result = {"ok": False, "error": str(exc), "code": exc.code}
            status = 400
        except Exception as exc:
            result = {"ok": False, "error": "操作没有完成。"}
            status = 500
            result["detail"] = type(exc).__name__
        self._json(handler, status, result)

    def _dispatch(self, path, payload):
        service = self.service
        if path == "/api/state":
            return service.state()
        if path == "/api/library/create":
            return service.create_library()
        if path == "/api/sites/save":
            state = service.save_site(payload)
            return {"ok": True, "state": state}
        if path == "/api/sites/launch":
            return service.launch_site(payload.get("siteID"), payload.get("browserID"))
        if path == "/api/sites/remove":
            return {"ok": True, "state": service.remove_site(payload.get("id"))}
        if path == "/api/sites/restore":
            return {"ok": True, "state": service.restore_site(payload.get("id"))}
        if path == "/api/layout":
            return {"ok": True, "state": service.set_layout(payload.get("tiles") or [])}
        if path == "/api/batch":
            return {"ok": True, "state": service.batch(payload)}
        if path == "/api/undo":
            return {"ok": True, "state": service.undo()}
        if path == "/api/preferences":
            return {"ok": True, "state": service.set_preferences(payload.get("layoutDensity"), payload.get("iconSize"))}
        if path == "/api/appearance":
            return {"ok": True, "state": service.set_appearance(payload.get("appearance"))}
        if path == "/api/workspaces/save":
            return {"ok": True, "state": service.save_workspace(payload.get("workspace") or {})}
        if path == "/api/workspaces/delete":
            return {"ok": True, "state": service.delete_workspace(payload.get("id"))}
        if path == "/api/workspaces/launch":
            return service.launch_workspace(payload.get("id"))
        if path == "/api/accounts/delete":
            return {"ok": True, "state": service.delete_account(payload.get("siteID"), payload.get("accountID"))}
        if path == "/api/vault/unlock":
            return {"ok": True, "state": service.unlock()}
        if path == "/api/vault/lock":
            return {"ok": True, "state": service.lock()}
        if path == "/api/backup/preview":
            document = payload.get("library")
            if isinstance(document, str):
                document = json.loads(document)
            return service.preview_backup(document, payload.get("mode") or "merge")
        if path == "/api/backup/apply":
            return {"ok": True, "state": service.apply_pending(payload.get("token"), payload.get("kind") or "backup")}
        if path == "/api/backup/export":
            if service.store.access != "ready":
                raise RecoveryError(service.store.message)
            return {"ok": True, "library": service.store.library, "note": "密码留在本机，未导出。"}
        if path == "/api/backup/zip":
            if service.store.access != "ready":
                raise RecoveryError(service.store.message)
            import base64
            blob = export_zip(service.store.library)
            return {"ok": True, "zipBase64": base64.b64encode(blob).decode(), "snapshotCount": 0}
        if path == "/api/backup/zip-preview":
            import base64
            archive = base64.b64decode(payload.get("zipBase64") or "")
            loaded = read_zip(archive)
            return service.preview_backup(loaded["library"], "restore")
        if path == "/api/bookmarks/sources":
            return {"ok": True, "sources": service.bookmark_sources(payload.get("home") or str(Path.home()))}
        if path == "/api/bookmarks/preview":
            return service.preview_bookmarks(payload.get("home") or str(Path.home()), payload.get("sourceID"))
        if path == "/api/actions/open":
            return service.open_action(payload.get("path"))
        if path == "/api/actions/catalog":
            return {"ok": True, "catalog": service.export_catalog(payload.get("kind") or "sites", payload.get("ids") or [])}
        if path == "/api/floating":
            return {"ok": True, "sites": [site["id"] for site in service.floating_sites(payload.get("query") or "")], "floating": service.set_floating(payload) if "dock" in payload or "enabled" in payload else service._floating()}
        if path == "/api/downloads/prepare":
            manager = service.download_manager()
            return {"ok": True, "prepared": manager.prepare(payload.get("urls") or [])}
        if path == "/api/downloads/destination":
            grant = service.download_manager().add_destination(Path(payload.get("path") or ""))
            return {"ok": True, "destination": grant, "state": service.state()}
        if path == "/api/downloads/create":
            jobs = service.download_manager().create_jobs(payload.get("urls") or [], payload.get("destinationID"), payload.get("requestID"), bool(payload.get("strip")))
            if payload.get("run"):
                service.downloads.run_authorized()
            return {"ok": True, "jobs": jobs, "state": service.state()}
        if path == "/api/downloads/pause":
            service.download_manager().pause(payload.get("id"))
            return {"ok": True, "state": service.state()}
        if path == "/api/downloads/resume":
            service.download_manager().resume(payload.get("id"))
            if payload.get("run"):
                service.downloads.run_authorized()
            return {"ok": True, "state": service.state()}
        if path == "/api/downloads/cancel":
            service.download_manager().cancel(payload.get("id"), bool(payload.get("removePartial")))
            return {"ok": True, "state": service.state()}
        if path == "/api/downloads/retry":
            service.download_manager().retry(payload.get("id"))
            return {"ok": True, "state": service.state()}
        if path == "/api/mail/account":
            account = service.mail_store().save_account(payload.get("account") or {})
            return {"ok": True, "account": account, "state": service.state()}
        if path == "/api/mail/authorize":
            service.mail_store().authorize(payload.get("id"))
            return {"ok": True, "state": service.state()}
        if path == "/api/mail/sync":
            messages = service.sync_mail(payload.get("id"))
            return {"ok": True, "messages": messages, "state": service.state()}
        if path == "/api/mail/send":
            record = service.send_draft(payload.get("draftID"))
            return {"ok": True, "submission": record}
        if path == "/api/mail/draft":
            draft = service.mail_store().save_draft(payload.get("draft") or {})
            return {"ok": True, "draft": draft}
        if path == "/api/mail/codes":
            return {"ok": True, **service.codes(payload.get("subject") or "", payload.get("body") or "", payload.get("html"))}
        if path == "/api/mail/aliases":
            return {"ok": True, **service.aliases(payload.get("email") or "", payload.get("service"), int(payload.get("count") or 8))}
        if path == "/api/mail/oauth-url":
            return {"ok": True, "url": authorization_url(
                payload.get("provider"), payload.get("clientID") or "", payload.get("redirectURI") or "http://127.0.0.1/oauth",
                payload.get("state") or "state", payload.get("verifier") or "verifier-verifier-verifier", payload.get("nonce") or "nonce",
                payload.get("tenant") or "common", payload.get("loginHint") or "",
            )}
        if path == "/api/shutdown":
            threading_shutdown(self)
            return {"ok": True}
        raise AppError("没有这个接口。")

    def _json(self, handler, status, payload):
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self._bytes(handler, status, data, "application/json; charset=utf-8")

    def _bytes(self, handler, status, data, content_type):
        handler.send_response(status)
        handler.send_header("Content-Type", content_type)
        handler.send_header("Content-Length", str(len(data)))
        handler.send_header("Cache-Control", "no-store")
        handler.end_headers()
        handler.wfile.write(data)


def threading_shutdown(server: PortalServer):
    import threading
    threading.Thread(target=server.shutdown, daemon=True).start()
