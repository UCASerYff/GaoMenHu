"""Prepare a replacement library from Edge's bookmarks bar without changing Edge.

The output is a private staging file, never a bundled default or source fixture.
Stop MenDao and validate the staged file before replacing its live library.
"""
import argparse
import json
import os
from pathlib import Path
from urllib.parse import urlsplit
from uuid import NAMESPACE_URL, uuid5

PALETTE = ["#D97757", "#248977", "#537CE6", "#35384B", "#ED83A7", "#AC83C8", "#C29A55", "#5B9DAD"]


def convert(bookmarks, appearance="dusk"):
    bar = bookmarks["roots"]["bookmark_bar"]
    sites, tiles = [], []

    def site(node, position):
        value = node["url"]
        parsed = urlsplit(value)
        if parsed.scheme.lower() not in ("http", "https") or not parsed.hostname or parsed.username is not None or parsed.password is not None or len(value) >= 8192:
            raise ValueError("收藏栏含无法作为网站启动的网址；未生成替换数据。")
        name = node.get("name", "").strip() or parsed.hostname
        if len(name) > 100:
            raise ValueError("收藏名称超过搞门户的 100 字限制；未生成替换数据。")
        identity = str(uuid5(NAMESPACE_URL, "mendao-edge-bookmark:" + position))
        sites.append({"id": identity, "name": name, "url": value,
                      "color": PALETTE[len(sites) % len(PALETTE)], "allowedBrowsers": ["edge"],
                      "defaultBrowser": "edge", "accounts": [], "profiles": {}})
        return identity

    for index, node in enumerate(bar.get("children", [])):
        if node.get("type") == "url":
            tiles.append({"id": site(node, str(index)), "kind": "site"})
        elif node.get("type") == "folder":
            children = node.get("children", [])
            if any(child.get("type") != "url" for child in children):
                raise ValueError("收藏栏含多层文件夹；请先确认层级安排，未生成替换数据。")
            if children:
                ids = [site(child, f"{index}/{i}") for i, child in enumerate(children)]
                tiles.append({"id": str(uuid5(NAMESPACE_URL, f"mendao-edge-folder:{index}")),
                              "kind": "folder", "name": node.get("name") or "文件夹", "children": ids})
        else:
            raise ValueError("收藏栏含未知条目；未生成替换数据。")
    if not sites or len(sites) > 5000:
        raise ValueError("收藏栏为空或超出容量；未生成替换数据。")
    return {"schema": 1, "appearance": appearance, "sites": sites, "tiles": tiles}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bookmarks", type=Path, required=True)
    parser.add_argument("--current-library", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    current = json.loads(args.current_library.read_text())
    if any(site.get("accounts") for site in current.get("sites", [])):
        raise ValueError("现有收藏关联了账号，需先保留账号资料；未生成替换数据。")
    result = convert(json.loads(args.bookmarks.read_text()), current.get("appearance", "dusk"))
    if args.output.resolve() in (args.current_library.resolve(), args.bookmarks.resolve()):
        raise ValueError("输出必须是独立的暂存文件。")
    with os.fdopen(os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as file:
        json.dump(result, file, ensure_ascii=False, indent=2)
        file.write("\n")
    print(json.dumps({"replaced_websites": len(current["sites"]), "imported_websites": len(result["sites"]),
                      "folders": [{"name": t["name"], "websites": len(t["children"])} for t in result["tiles"] if t["kind"] == "folder"],
                      "default_browser": "edge"}, ensure_ascii=False))


if __name__ == "__main__":
    main()
