"""只监听 127.0.0.1 的本地网页。"""

import json
from contextlib import nullcontext
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

from . import EXTENSION_ID, VERSION_LABEL
from .action_exchange import action_route
from .backup import export_zip, read_zip
from .browsers import open_extension_setup
from .centers import download_route, mail_route
from .errors import AppError, RecoveryError
from .launcher import PORTAL_MIME, launcher_runtime_state, portal_asset, portal_document, reveal_data_directory
from .models import decode_library
from .transport import authorization_url


LIBRARY_CHANGES = {
    "/api/library/create", "/api/sites/save", "/api/sites/remove", "/api/sites/restore",
    "/api/layout", "/api/batch", "/api/undo", "/api/preferences", "/api/appearance",
    "/api/workspaces/save", "/api/workspaces/delete", "/api/accounts/delete",
    "/api/backup/preview", "/api/backup/apply", "/api/backup/zip-preview",
    "/api/bookmarks/preview",
}


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
        self.activate_desktop = None
        self.quit_desktop = None
        self.appearance_changed = None
        self.mail_panel_changed = None

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
        if not self._local_host(handler):
            self._bytes(handler, 403, b"local requests only", "text/plain; charset=utf-8")
            return
        path = urlparse(handler.path).path
        if path in ("/downloads", "/mail"):
            page = (asset_root() / "centers.html").read_text(encoding="utf-8")
            page = page.replace("__GAO_TOKEN__", self.service.page_token).replace("__GAO_VERSION__", VERSION_LABEL)
            self._bytes(handler, 200, page.encode("utf-8"), "text/html; charset=utf-8")
            return
        if path in ("/", "/settings"):
            page = portal_document(self.service.page_token, settings=path == "/settings")
            self._bytes(handler, 200, page, "text/html; charset=utf-8")
            return
        if path.startswith("/portal-assets/"):
            name = path.removeprefix("/portal-assets/")
            if name in PORTAL_MIME:
                self._bytes(handler, 200, portal_asset(name), PORTAL_MIME[name])
                return
        if path == "/float":
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
        if not self._local_host(handler):
            self._json(handler, 403, {"ok": False, "error": "只接受本机请求。"})
            return
        if self.service.stopping.is_set():
            self._json(handler, 503, {"ok": False, "error": "搞门户正在退出。"})
            return
        try:
            length = int(handler.headers.get("Content-Length") or 0)
        except ValueError:
            length = -1
        if length < 0:
            self._json(handler, 400, {"ok": False, "error": "请求长度无效。"})
            return
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
        if path in ("/api/native", "/api/desktop/activate", "/api/actions/activate"):
            if handler.headers.get("X-Gao-Host") != self.service.host_token:
                self._json(handler, 403, {"ok": False, "error": "助手令牌无效。"})
                return
            if path == "/api/desktop/activate":
                self._json(handler, 200, {"ok": bool(self.activate_desktop and self.activate_desktop())})
                return
            if path == "/api/actions/activate":
                accepted = self.service.enqueue_action(payload.get("path"))
                self._json(handler, 200, {"ok": accepted})
                if accepted and self.activate_desktop:
                    self.activate_desktop()
                return
            if payload.get("extension") != EXTENSION_ID:
                self._json(handler, 403, {"ok": False, "error": "连接身份无效。"})
                return
            message = payload.get("message") or {}
            lock = self.service.library_lock if isinstance(message, dict) and message.get("type") == "saveBookmark" else nullcontext()
            try:
                with lock:
                    result = self.service.native_message(message, payload.get("browser") or "")
            except (OSError, AppError):
                result = {"ok": False, "error": "助手请求未能完成，请在搞门户中重试。"}
            self._json(handler, 200, result)
            return
        if handler.headers.get("X-Gao-Token") != self.service.page_token:
            self._json(handler, 403, {"ok": False, "error": "页面令牌无效，请刷新。"})
            return
        try:
            lock = self.service.library_lock if path in LIBRARY_CHANGES else nullcontext()
            with lock:
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
        if path == "/api/launcher/state":
            return service.state(launcher_only=True)
        if path == "/api/launcher/runtime":
            return launcher_runtime_state(service)
        if path == "/api/launcher/data-directory":
            return reveal_data_directory(service)
        if path == "/api/browser/extensions":
            return open_extension_setup(payload.get("browserID"))
        if path == "/api/launcher/acknowledge":
            return service.acknowledge_action(payload.get("requestID"))
        if path == "/api/library/create":
            return service.create_library()
        if path == "/api/sites/save":
            state = service.save_site(payload)
            return {"ok": True, "state": state, "warning": state.pop("siteWarning", "")}
        if path == "/api/sites/launch":
            return service.launch_site(payload.get("siteID"), payload.get("browserID"), account_id=payload.get("accountID"))
        if path == "/api/sites/icon":
            return service.refresh_icons(payload.get("siteID"))
        if path == "/api/sites/icon-warmup":
            if service.store.access == "ready":
                service.icons.schedule(
                    site for site in service.store.library["sites"]
                    if not site.get("icon") and service.clock() - site.get("iconCheckedAt", 0) > 86400
                )
            return {"ok": True}
        if path == "/api/sites/icon-preview":
            import base64
            from .icons import MAX_IMAGE_BYTES, decode_image
            try:
                data = base64.b64decode(payload.get("iconBase64") or "", validate=True)
            except ValueError:
                data = b""
            if not data or len(data) > MAX_IMAGE_BYTES or not (icon := decode_image(data, website=False)):
                raise AppError("无法读取这张图片。请选择不超过 4 MB 的 PNG、JPEG、WebP、ICO 或 GIF 图片。")
            return {"ok": True, "icon": icon[0]}
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
            state = service.set_appearance(payload.get("appearance"))
            if self.appearance_changed:
                self.appearance_changed()
            return {"ok": True, "state": state}
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
            try:
                archive = base64.b64decode(payload.get("zipBase64") or "", validate=True)
            except (TypeError, ValueError) as exc:
                raise AppError("当前资料 ZIP 格式无效或已损坏。") from exc
            loaded = read_zip(archive)
            return service.preview_backup(loaded["library"], "restore")
        if path == "/api/bookmarks/sources":
            return {"ok": True, "sources": service.bookmark_sources(payload.get("home") or str(Path.home()))}
        if path == "/api/bookmarks/preview":
            return service.preview_bookmarks(payload.get("home") or str(Path.home()), payload.get("sourceID"))
        if path == "/api/actions/catalog":
            return {"ok": True, "catalog": service.export_catalog(payload.get("kind") or "sites", payload.get("ids") or [])}
        if path.startswith("/api/actions/"):
            return action_route(service, path.removeprefix("/api/actions/"), payload)
        if path == "/api/floating":
            query = payload.get("query")
            settings = service.set_floating(payload)
            return {"ok": True, "sites": [site["id"] for site in service.floating_sites(query if isinstance(query, str) else "")], "floating": settings}
        if path.startswith("/api/downloads/"):
            response = download_route(service, path.removeprefix("/api/downloads/"), payload)
            if path == "/api/downloads/settings" and self.appearance_changed:
                self.appearance_changed("/downloads")
            return response
        if path == "/api/mail/oauth-url":
            return {"ok": True, "url": authorization_url(
                payload.get("provider"), payload.get("clientID") or "", payload.get("redirectURI") or "http://127.0.0.1/oauth",
                payload.get("state") or "state", payload.get("verifier") or "verifier-verifier-verifier", payload.get("nonce") or "nonce",
                payload.get("tenant") or "common", payload.get("loginHint") or "",
            )}
        if path.startswith("/api/mail/"):
            result = mail_route(service, path.removeprefix("/api/mail/"), payload)
            if path == "/api/mail/settings" and self.mail_panel_changed:
                self.mail_panel_changed()
            return result
        if path == "/api/shutdown":
            if self.quit_desktop:
                return {"ok": self.quit_desktop()}
            if not service.begin_shutdown():
                raise AppError("正在发送邮件或保存邮箱授权，完成后即可退出。")
            threading_shutdown(self)
            return {"ok": True}
        raise AppError("没有这个接口。")

    def _json(self, handler, status, payload):
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self._bytes(handler, status, data, "application/json; charset=utf-8")

    def _local_host(self, handler):
        host = handler.headers.get("Host", "").lower()
        return host in ("127.0.0.1", "localhost", f"127.0.0.1:{self.port}", f"localhost:{self.port}")

    def _bytes(self, handler, status, data, content_type):
        handler.send_response(status)
        handler.send_header("Content-Type", content_type)
        handler.send_header("Content-Length", str(len(data)))
        handler.send_header("Cache-Control", "no-store")
        handler.send_header("X-Content-Type-Options", "nosniff")
        handler.send_header("X-Frame-Options", "DENY")
        handler.send_header("Referrer-Policy", "no-referrer")
        if content_type.startswith("text/html"):
            handler.send_header("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; frame-src 'self' blob:; object-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
        handler.end_headers()
        handler.wfile.write(data)


def threading_shutdown(server: PortalServer):
    import threading
    threading.Thread(target=server.shutdown, daemon=True).start()
