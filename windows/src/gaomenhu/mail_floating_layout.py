"""Windows mail rail and expanded card placement in per-monitor pixels."""

from dataclasses import asdict, dataclass
from math import isfinite

from .floating_geometry import Rect, snap_frame

RAIL_WIDTH = 20
RAIL_HEIGHT = 104
CARD_WIDTH = 340
CARD_LIMIT = 420
CARD_RADIUS = 18
HEADER = 80


def is_ratio(value):
    return type(value) in (int, float) and 0 <= value <= 1


@dataclass(frozen=True)
class MailPlacement:
    screen: str = ""
    dock: str = "right"
    side: str = "right"
    across: float = 1
    down: float = 0.15

    @staticmethod
    def valid(data):
        return (isinstance(data, dict) and set(data) == {"screen", "dock", "side", "across", "down"}
                and isinstance(data["screen"], str) and len(data["screen"]) <= 128
                and data["dock"] in ("left", "right", "free") and data["side"] in ("left", "right")
                and (data["dock"] == "free" or data["side"] == data["dock"])
                and is_ratio(data["across"]) and is_ratio(data["down"]))

    @classmethod
    def restore(cls, data):
        return cls(**data) if cls.valid(data) else cls()

    def serialized(self):
        return asdict(self)


def mail_opacity(value):
    if type(value) not in (int, float) or not 0.65 <= value <= 1:
        return 1.0
    return float(value)


def mail_size(screen, expanded, ideal=280):
    bounds = screen.bounds
    width = screen.px(CARD_WIDTH if expanded else RAIL_WIDTH)
    height = screen.px(min(CARD_LIMIT, max(ideal, 1)) if expanded else RAIL_HEIGHT)
    return min(max(width, 1), bounds.width), min(max(height, 1), bounds.height)


def mail_frame(screen, position, expanded, ideal=280):
    width, height = mail_size(screen, expanded, ideal)
    rail_width, rail_height = mail_size(screen, False)
    bounds = screen.bounds
    y = bounds.y + round(position.down * (bounds.height - rail_height))
    if position.dock == "left":
        x = bounds.x
    elif position.dock == "right":
        x = bounds.right - width
    else:
        x = bounds.x + round(position.across * (bounds.width - rail_width))
        if position.side == "right":
            x += rail_width - width
    return Rect(x, y, width, height).clamp(bounds)


def carried_mail_frame(screen, requested, side, expanded):
    frame, dock = snap_frame(screen, requested)
    bounds = screen.bounds
    rail_width, rail_height = mail_size(screen, False)
    if dock != "none":
        side = dock
    elif not expanded:
        side = "left" if frame.x * 2 + frame.width < bounds.x * 2 + bounds.width else "right"
    x = frame.x if side == "left" else frame.right - rail_width
    across = (x - bounds.x) / max(1, bounds.width - rail_width)
    down = (frame.y - bounds.y) / max(1, bounds.height - rail_height)
    return frame, MailPlacement(screen.name, dock if dock != "none" else "free", side,
                                min(max(across, 0), 1), min(max(down, 0), 1))


def rounded_card_contains(point, frame, radius):
    if not all(isfinite(v) for v in point) or not frame.contains(point):
        return False
    radius = min(radius, frame.width / 2, frame.height / 2)
    x, y = point
    dx = x - min(max(x, frame.x + radius), frame.right - radius)
    dy = y - min(max(y, frame.y + radius), frame.bottom - radius)
    return dx * dx + dy * dy <= radius * radius


def separated_mail_position(screen, position, neighboring_rail):
    rail = mail_frame(screen, position, False)
    if (not neighboring_rail or rail.x >= neighboring_rail.right or neighboring_rail.x >= rail.right
            or rail.y >= neighboring_rail.bottom or neighboring_rail.y >= rail.bottom):
        return position
    bounds, gap = screen.bounds, screen.px(12)
    y = neighboring_rail.bottom + gap
    if y + rail.height > bounds.bottom:
        y = max(bounds.y, neighboring_rail.y - gap - rail.height)
    _, height = mail_size(screen, False)
    down = (y - bounds.y) / max(1, bounds.height - height)
    return MailPlacement(position.screen, position.dock, position.side, position.across, min(max(down, 0), 1))
