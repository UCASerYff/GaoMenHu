"""搜索和悬浮窗排序。拼音表代替 macOS 的 toLatin 转写。"""

import math
import unicodedata

from .pinyin_data import load_pinyin

_PINYIN = None
MAX_USAGE_RECORDS = 5000
MAX_OPEN_COUNT = 2**63 - 1


def pinyin_table():
    global _PINYIN
    if _PINYIN is None:
        _PINYIN = load_pinyin()
    return _PINYIN


def fold(value):
    text = unicodedata.normalize("NFKC", value or "")
    decomposed = unicodedata.normalize("NFD", text)
    stripped = "".join(ch for ch in decomposed if unicodedata.category(ch) != "Mn")
    return stripped.casefold().strip()


def romanize(value):
    table = pinyin_table()
    parts = []
    for char in value or "":
        syllable = table.get(ord(char))
        if syllable:
            parts.append(syllable)
            parts.append(" ")
        else:
            parts.append(char)
    return "".join(parts)


def search_key(site):
    source = site.get("name", "") + " " + (site.get("aliases") or "")
    romanized = fold(romanize(source))
    words = [word for word in _split_words(romanized)]
    initials = "".join(word[0] for word in words if word)
    return romanized + " " + "".join(words) + " " + initials


def search_text(site):
    source = site.get("name", "") + " " + (site.get("aliases") or "")
    romanized = fold(romanize(source))
    words = [word for word in _split_words(romanized)]
    initials = "".join(word[0] for word in words if word)
    base = fold(source + " " + site.get("url", ""))
    account_bits = []
    for account in site.get("accounts") or []:
        account_bits.append(account.get("label") or "")
        account_bits.append(account.get("username") or "")
    accounts = fold(" ".join(account_bits))
    return base + " " + romanized + " " + "".join(words) + " " + initials + " " + accounts


def _split_words(value):
    word = []
    for char in value:
        if char.isalnum():
            word.append(char)
        elif word:
            yield "".join(word)
            word = []
    if word:
        yield "".join(word)


def ordered_sites(library):
    by_id = {site["id"]: site for site in library.get("sites") or []}
    seen = set()
    result = []
    for tile in library.get("tiles") or []:
        if tile.get("kind") == "site":
            ids = [tile.get("id")]
        elif tile.get("kind") == "folder":
            ids = tile.get("children") or []
        else:
            continue
        for site_id in ids:
            site = by_id.get(site_id)
            if site and site_id not in seen:
                seen.add(site_id)
                result.append(site)
    return result


def _valid_usage(record):
    if not isinstance(record, dict):
        return False
    count = record.get("openCount")
    opened = record.get("lastOpenedAt")
    return type(count) is int and 0 <= count <= MAX_OPEN_COUNT and type(opened) in (int, float) and 0 <= opened < math.inf


def _recent_usage_key(item):
    site, usage = item
    return -usage["lastOpenedAt"], -usage["openCount"], site


def normalized_usage(raw):
    if not isinstance(raw, dict):
        return {}
    records = [(key, record) for key, record in raw.items() if key and _valid_usage(record)]
    return dict(sorted(records, key=_recent_usage_key)[:MAX_USAGE_RECORDS])


def floating_sites(library, query="", usage=None, limit=8):
    ordered = ordered_sites(library)
    usage = usage or {}
    terms = [fold(part) for part in (query or "").split() if fold(part)]
    if terms:
        matched = []
        for site in ordered:
            base = fold(site.get("name", "") + " " + (site.get("aliases") or "") + " " + site.get("url", ""))
            text = base + " " + search_key(site)
            if all(term in text for term in terms):
                matched.append(site)
        return matched
    capacity = max(0, limit)
    if capacity == 0:
        return []
    positions = {site["id"]: index for index, site in enumerate(ordered)}
    used = []
    for site in ordered:
        record = usage.get(site["id"])
        if _valid_usage(record) and record["openCount"] > 0:
            used.append(site)

    def recent_key(site):
        record = usage[site["id"]]
        return (-record["lastOpenedAt"], positions[site["id"]])

    def frequent_key(site):
        record = usage[site["id"]]
        return (-record["openCount"], -record["lastOpenedAt"], positions[site["id"]])

    recent = sorted(used, key=recent_key)
    result = recent[: min(3, capacity)]
    seen = {site["id"] for site in result}
    frequent = sorted(used, key=frequent_key)
    for site in frequent + ordered:
        if len(result) >= capacity:
            break
        if site["id"] not in seen:
            seen.add(site["id"])
            result.append(site)
    return result


def record_launch(usage, site_id, at):
    if not site_id or type(at) not in (int, float) or not 0 <= at < math.inf:
        return usage
    usage = dict(usage or {})
    old = usage.get(site_id) if _valid_usage(usage.get(site_id)) else None
    if old is None and len(usage) >= MAX_USAGE_RECORDS:
        oldest = max(usage.items(), key=_recent_usage_key)[0]
        usage.pop(oldest, None)
    count = old["openCount"] if old else 0
    if count < MAX_OPEN_COUNT:
        count += 1
    usage[site_id] = {"openCount": count, "lastOpenedAt": float(at)}
    return usage
