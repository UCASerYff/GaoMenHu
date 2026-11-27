"""Shared Windows floating-surface colors and CJK font selection."""

PALETTE = {
    "light": {
        "bg": "#f2f4f8", "surface": "#ffffff", "text": "#182237", "secondary": "#526078",
        "border": "#d8ddea", "line": "#e2e5ee", "card": "#e9edf5", "field": "#f7f8fc",
        "tint": "#eeeafa", "accent": "#6452c5", "rail": "#7162ce", "primary_text": "#ffffff",
        "warning": "#874918", "warning_bg": "#fff1db", "disabled": "#687389",
    },
    "dark": {
        "bg": "#151822", "surface": "#202534", "text": "#f2f4fc", "secondary": "#aeb8cf",
        "border": "#3b4359", "line": "#343b4e", "card": "#292e41", "field": "#1c212e",
        "tint": "#352e58", "accent": "#b7adff", "rail": "#a095ec", "primary_text": "#201735",
        "warning": "#ffc693", "warning_bg": "#4a341f", "disabled": "#909bb1",
    },
}


def font_family(widget):
    families = widget.tk.splitlist(widget.tk.call("font", "families"))
    names = {name.casefold(): name for name in families}
    preferences = ("Microsoft YaHei UI", "Microsoft YaHei", "DengXian", "Segoe UI Variable Text", "Segoe UI")
    return next((names[family.casefold()] for family in preferences if family.casefold() in names), "TkDefaultFont")
