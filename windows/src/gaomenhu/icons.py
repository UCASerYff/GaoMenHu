"""Discover high-resolution icons without visiting saved paths or sending credentials."""

import base64
import io
import json
import threading
from collections import deque
from html.parser import HTMLParser
from urllib.error import HTTPError
from urllib.parse import urljoin, urlsplit, urlunsplit
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener

from PIL import Image, ImageOps


MAX_IMAGE_BYTES = 4 * 1024 * 1024
MAX_DOCUMENT_BYTES = 512 * 1024


def safe_url(value, base=None):
    if not isinstance(value, str) or len(value) > 4096 or any(ord(char) < 32 or char == "\\" for char in value):
        return None
    try:
        parts = urlsplit(urljoin(base or "", value.strip()))
        if parts.scheme.lower() != "https" or not parts.hostname or parts.username is not None or parts.password is not None:
            return None
        host = parts.hostname.encode("idna").decode("ascii")
        if ":" in host:
            host = f"[{host}]"
        if parts.port and parts.port != 443:
            host = f"{host}:{parts.port}"
        path = parts.path or "/"
        return urlunsplit(("https", host, path, parts.query, ""))
    except (UnicodeError, ValueError):
        return None


def website_root(value):
    try:
        parts = urlsplit(value)
        if parts.scheme not in ("http", "https") or parts.username is not None or parts.password is not None:
            return None
        host = parts.netloc
        if parts.scheme == "http" and parts.port == 80:
            host = host.rsplit(":", 1)[0]
        return safe_url(urlunsplit(("https", host, "/", "", "")))
    except ValueError:
        return None


class HTTPSOnly(HTTPRedirectHandler):
    max_redirections = 4

    def redirect_request(self, request, fp, code, msg, headers, newurl):
        if not (url := safe_url(newurl, request.full_url)):
            raise HTTPError(request.full_url, code, "Invalid icon redirect", headers, fp)
        return super().redirect_request(request, fp, code, msg, headers, url)


def fetch(opener, url, limit):
    if not url:
        return None, None
    try:
        with opener.open(Request(url, headers={"User-Agent": "GaoMenHu-Icon/1.19"}), timeout=4) as response:
            if int(response.headers.get("Content-Length", "0")) > limit:
                return None, None
            data = response.read(limit + 1)
            return (data, response.url) if len(data) <= limit else (None, None)
    except (OSError, UnicodeError, ValueError):
        return None, None


def size_hint(value):
    if not isinstance(value, str):
        return 0
    dimensions = [item.split("x") for item in value.lower().split()]
    return max((min(map(int, pair)) for pair in dimensions if len(pair) == 2 and all(
        field.isascii() and field.isdigit() and len(field) < 6 for field in pair
    )), default=0)


class IconLinks(HTMLParser):
    def __init__(self, base):
        super().__init__(convert_charrefs=True)
        self.icons = {}
        self.manifests = []
        self.base = base

    def handle_starttag(self, tag, attrs):
        if tag != "link" or len(self.icons) >= 128:
            return
        link = dict(attrs)
        url = safe_url(link.get("href"), self.base)
        if url is None:
            return
        relation = set((link.get("rel") or "").lower().split())
        if "manifest" in relation and len(self.manifests) < 2 and url not in self.manifests:
            self.manifests.append(url)
        if relation.intersection({"icon", "apple-touch-icon", "apple-touch-icon-precomposed"}):
            hint = max(size_hint(link.get("sizes")), 180 if "apple-touch-icon" in relation else 0)
            self.icons[url] = max(self.icons.get(url, 0), hint)


def manifest_icons(data, base):
    try:
        document = json.loads(data)
    except (ValueError, TypeError):
        return []
    if not isinstance(document, dict) or not isinstance(document.get("icons"), list):
        return []
    return [
        (url, size_hint(item.get("sizes"))) for item in document["icons"][:32]
        if isinstance(item, dict) and (url := safe_url(item.get("src"), base))
    ]


def decode_image(data, website=True):
    if not data or len(data) > MAX_IMAGE_BYTES:
        return None
    try:
        with Image.open(io.BytesIO(data), formats=["PNG", "JPEG", "WEBP", "ICO", "GIF"]) as image:
            width, height = image.size
            pixels = min(width, height)
            if max(width, height) > 8192 or width * height > 16_777_216:
                return None
            if website and (pixels < 64 or max(width, height) > pixels * 4):
                return None
            target = 256 if website else 1536
            image = ImageOps.exif_transpose(image)
            image.thumbnail((target, target), Image.Resampling.LANCZOS)
            output = io.BytesIO()
            image.convert("RGBA").save(output, format="PNG")
            if output.tell() > MAX_IMAGE_BYTES:
                return None
            return "data:image/png;base64," + base64.b64encode(output.getvalue()).decode("ascii"), pixels
    except (Image.DecompressionBombError, OSError, ValueError):
        return None


def load_website_icon(url):
    if not (root := website_root(url)):
        return None
    opener = build_opener(ProxyHandler({}), HTTPSOnly())
    html, resolved = fetch(opener, root, MAX_DOCUMENT_BYTES)
    parser = IconLinks(resolved or root)
    if html:
        parser.feed(html.decode("utf-8", errors="replace"))
    for manifest in parser.manifests:
        data, base = fetch(opener, manifest, MAX_DOCUMENT_BYTES)
        for icon, hint in manifest_icons(data, base):
            parser.icons[icon] = max(parser.icons.get(icon, 0), hint)
    for name, hint in [("apple-touch-icon.png", 180), ("favicon.ico", 0)]:
        parser.icons.setdefault(urljoin(root, name), hint)
    best = None
    for candidate, _ in sorted(parser.icons.items(), key=lambda entry: -entry[1])[:8]:
        data, _ = fetch(opener, candidate, MAX_IMAGE_BYTES)
        if result := decode_image(data):
            if best is None or result[1] > best[1]:
                best = result
            if best[1] >= 256:
                break
    return best


class WebsiteIcons:
    FIELDS = ("icon", "iconSource", "iconRevision", "iconSourcePixels", "iconCheckedAt")

    def __init__(self, service):
        self.service = service
        self.pending = deque()
        self.active = set()
        self.lock = threading.Lock()
        self.workers = 0

    def schedule(self, sites):
        with self.lock:
            count = 0
            for site in sites:
                key = (site["id"], site["url"])
                if site.get("iconSource") == "custom" or key in self.active:
                    continue
                self.active.add(key)
                self.pending.append(key)
                count += 1
            for _ in range(min(3 - self.workers, len(self.pending))):
                self.workers += 1
                threading.Thread(target=self._work, name="GaoMenHu icons", daemon=True).start()
            return count

    def _work(self):
        while True:
            with self.lock:
                if not self.pending:
                    self.workers -= 1
                    return
                site_id, url = self.pending.popleft()
            try:
                icon = load_website_icon(url)
                if icon:
                    self._save(site_id, url, icon)
            except Exception:
                # Website response or app shutdown can interrupt this optional fetch.
                pass
            finally:
                with self.lock:
                    self.active.discard((site_id, url))

    def _save(self, site_id, url, result):
        service = self.service
        with service.library_lock:
            library = service.store.library
            if not library:
                return
            site = next((item for item in library["sites"] if item["id"] == site_id), None)
            if not site or site["url"] != url or site.get("iconSource") == "custom":
                return
            icon, pixels = result
            updated = dict(site, icon=icon, iconSource="website", iconRevision=2,
                           iconSourcePixels=pixels, iconCheckedAt=service.clock())
            if site.get("iconSourcePixels", 0) > pixels:
                return
            sites = [updated if item is site else item for item in library["sites"]]
            service.store.save(dict(library, sites=sites))
