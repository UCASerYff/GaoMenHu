"""Reuse the released portal UI with Windows window, settings and data adapters."""

import os
import sys
from pathlib import Path

from . import MARKETING_VERSION
from .errors import AppError


PORTAL_MIME = {
    "app.js": "text/javascript; charset=utf-8",
    "features.js": "text/javascript; charset=utf-8",
    "style.css": "text/css; charset=utf-8",
    "Mark.png": "image/png",
}


def _portal_root():
    if getattr(sys, "frozen", False):
        return Path(sys._MEIPASS) / "gaomenhu_portal"
    return Path(__file__).resolve().parents[3] / "Resources"


def _workspace_document():
    root = Path(sys._MEIPASS) / "gaomenhu_assets" if getattr(sys, "frozen", False) else Path(__file__).resolve().parent / "assets"
    return (root / "workspace.html").read_text(encoding="utf-8")


def portal_document(token, settings=False):
    page = (_portal_root() / "index.html").read_text(encoding="utf-8")
    page = page.replace(
        '<meta name="viewport" content="width=device-width, initial-scale=1">',
        '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
        f'  <meta name="gao-token" content="{token}">',
    )
    page = page.replace("connect-src 'none'", "connect-src 'self'").replace(
        "img-src 'self' data:", "img-src 'self' data: blob:"
    )
    page = page.replace('href="style.css">', 'href="/portal-assets/style.css">\n'
                        '  <link rel="stylesheet" href="/assets/launcher.css">\n'
                        '  <link rel="stylesheet" href="/assets/settings.css">')
    page = page.replace('src="Mark.png"', 'src="/portal-assets/Mark.png"')
    page = page.replace('src="app.js"></script>', 'src="/portal-assets/app.js"></script>\n'
                        '  <script src="/assets/launcher.js"></script>\n'
                        '  <script src="/assets/settings-dialogs.js"></script>')
    page = page.replace('src="features.js"', 'src="/portal-assets/features.js"')
    page = page.replace("⌘ ,", "Ctrl + ,").replace("⌘ F", "Ctrl + F")
    page = page.replace("⌘ Z", "Ctrl + Z").replace("⌃ ⌥ Space", "Ctrl + Alt + Space")
    if settings:
        page = page.replace("<title>搞门户</title>", "<title>搞门户设置</title>")
        page = page.replace("<body>", '<body class="settings-window">')
    else:
        start = page.index('  <div class="app-shell">')
        end = page.index('  <div id="folderOverlay"', start)
        page = page[:start] + _workspace_document() + page[end:]
        page = page.replace("<body>", '<body class="workspace-window">')
        page = page.replace("</head>", '  <link rel="stylesheet" href="/assets/workspace.css">\n</head>')
        page = page.replace('  <script src="/portal-assets/features.js">',
                            '  <script src="/assets/workspace.js"></script>\n  <script src="/portal-assets/features.js">')
    return page.encode("utf-8")


def portal_asset(name):
    root = _portal_root()
    if name == "Mark.png":
        asset = root / name if getattr(sys, "frozen", False) else root.parent / "Assets" / "AppIcon.png"
        return asset.read_bytes()
    asset = root / name
    if name == "style.css":
        return asset.read_bytes()
    script = asset.read_text(encoding="utf-8")
    script = script.replace("⌘ Z", "Ctrl + Z").replace("macOS 钥匙串", "Windows 凭据保护")
    script = script.replace("验证 Mac 身份", "确认解锁").replace("本机钥匙串", "Windows 凭据保护")
    script = script.replace("已保存在钥匙串", "密码已保存").replace("||'safari'", "||'edge'")
    script = script.replace("()=>$('folderName').select()", "()=>$('folderName')?.select()")
    script = script.replace("()=>$('folderClose').focus()", "()=>$('folderClose')?.focus()")
    return script.encode("utf-8")


def reveal_data_directory(service):
    if os.name != "nt":
        raise AppError("请在 Windows 文件资源管理器中打开资料目录。")
    path = service.data_dir.resolve()
    if not path.exists():
        path = path.parent
    try:
        os.startfile(path)
    except OSError as exc:
        raise AppError("无法打开资料目录。") from exc
    return {"ok": True}


def launcher_runtime_state(service):
    state = service.launcher_runtime()
    state["version"] = MARKETING_VERSION
    state["revision"] = state.pop("libraryRevision")
    return state
