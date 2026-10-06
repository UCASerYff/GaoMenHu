"""Run once at the start of a user-requested release, never for a rebuild."""
from decimal import Decimal
import json
from pathlib import Path

root = Path(__file__).resolve().parent.parent
old = (root / "VERSION").read_text().strip()
new = f"{Decimal(old) + Decimal('0.01'):.2f}"
(root / "VERSION").write_text(new + "\n")
manifest_file = root / "BrowserExtension" / "manifest.json"
manifest = json.loads(manifest_file.read_text())
major, minor = new.split(".")
manifest["version"] = f"{int(major)}.{int(minor)}.0"
manifest_file.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
manual = root / "使用说明.txt"
text = manual.read_text()
text = text.replace("搞门户 V" + old, "搞门户 V" + new)
text = text.replace("GaoMenHu-" + old + ".dmg", "GaoMenHu-" + new + ".dmg")
text = text.replace("当前版本 V" + old, "当前版本 V" + new)
manual.write_text(text)
readme = root / "README.md"
text = readme.read_text().replace("# 搞门户 V" + old, "# 搞门户 V" + new)
text = text.replace("GaoMenHu-" + old + ".dmg", "GaoMenHu-" + new + ".dmg")
readme.write_text(text)
print(f"搞门户 V{old} → V{new}")
