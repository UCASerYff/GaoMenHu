"""The floating launcher's layout in Windows desktop coordinates."""

from dataclasses import dataclass
from math import inf


@dataclass(frozen=True)
class Rect:
    x: int
    y: int
    width: int
    height: int

    @property
    def right(self):
        return self.x + self.width

    @property
    def bottom(self):
        return self.y + self.height

    def contains(self, point):
        x, y = point
        return self.x <= x < self.right and self.y <= y < self.bottom

    def clamp(self, bounds):
        width = min(self.width, bounds.width)
        height = min(self.height, bounds.height)
        return Rect(min(max(self.x, bounds.x), bounds.right - width),
                    min(max(self.y, bounds.y), bounds.bottom - height), width, height)


@dataclass(frozen=True)
class Screen:
    name: str
    physical: Rect
    work: Rect
    dpi: int = 96

    def px(self, dip):
        return round(dip * self.dpi / 96)

    @property
    def bounds(self):
        left = self.physical.x if self.work.x - self.physical.x <= self.px(8) else self.work.x
        right = self.physical.right if self.physical.right - self.work.right <= self.px(8) else self.work.right
        return Rect(left, self.work.y, right - left, self.work.height)


def screen_at(screens, point):
    x, y = point

    def distance(screen):
        rect = screen.physical
        dx = max(rect.x - x, 0, x - rect.right + 1)
        dy = max(rect.y - y, 0, y - rect.bottom + 1)
        return dx * dx + dy * dy

    return min(screens, key=distance)


def valid_anchor(anchor):
    return (isinstance(anchor, dict) and isinstance(anchor.get("screen"), str)
            and 0 < len(anchor["screen"]) <= 128
            and all(type(anchor.get(key)) in (int, float) and -inf < anchor[key] < inf
                    and abs(anchor[key]) <= 32768 for key in ("x", "top")))


def restore_anchor(screens, saved):
    if valid_anchor(saved):
        for screen in screens:
            if screen.name == saved["screen"]:
                bounds = screen.bounds
                return screen, (bounds.x + screen.px(saved["x"]), bounds.y + screen.px(saved["top"]))
    screen = screens[0]
    return screen, (screen.bounds.right - screen.px(20), screen.bounds.y + screen.px(96))


def save_anchor(screen, frame, dock):
    x = frame.right - min(screen.px(20), screen.bounds.width) if dock == "right" else frame.x
    return {"screen": screen.name, "x": (x - screen.bounds.x) * 96 / screen.dpi,
            "top": (frame.y - screen.bounds.y) * 96 / screen.dpi}


def panel_size(screen, expanded, site_count):
    if not expanded:
        return screen.px(20), screen.px(104)
    return screen.px(364), screen.px(92 + (min(site_count, 8) * 46 if site_count else 64))


def visible_rows(screen, height):
    return next((count for count in range(8, 0, -1) if screen.px(92 + count * 46) <= height), 1)


def panel_frame(screen, anchor, dock, expanded, site_count):
    width, height = panel_size(screen, expanded, site_count)
    bounds = screen.bounds
    x, y = anchor
    if dock == "left":
        x = bounds.x
    if dock == "right":
        x = bounds.right - width
    return Rect(x, y, width, height).clamp(bounds)


def snap_frame(screen, wanted):
    bounds = screen.bounds
    frame = wanted.clamp(bounds)
    left, right = frame.x - bounds.x, bounds.right - frame.right
    threshold = screen.px(32)
    if left <= threshold and left <= right:
        return Rect(bounds.x, frame.y, frame.width, frame.height), "left"
    if right <= threshold:
        return Rect(bounds.right - frame.width, frame.y, frame.width, frame.height), "right"
    return frame, "none"


class PointerTiming:
    """The collapse cooldown requires a fresh entry into the handle."""

    def __init__(self):
        self.armed = True
        self.hold_until = 0.0
        self.entered = None
        self.left = None

    def transition(self, expanded, now):
        self.entered = self.left = None
        if not expanded:
            self.armed = False
            self.hold_until = now + 0.2

    def tick(self, now, *, expanded, inside, buttons, outside_press, protected):
        if not expanded:
            if not inside:
                self.armed = True
            if not inside or buttons or not self.armed or now < self.hold_until:
                self.entered = None
            else:
                if self.entered is None:
                    self.entered = now
                if now - self.entered >= 0.45:
                    return True
        elif inside or protected:
            self.left = None
        elif outside_press:
            return False
        else:
            if self.left is None:
                self.left = now
            if now - self.left >= 0.15:
                return False
        return None
