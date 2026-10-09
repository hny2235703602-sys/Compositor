#!/usr/bin/env python3
"""Build Compositor/Localizable.xcstrings from scripts/zh.json."""
import json, re, sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
spec = re.compile(r"%(?:\d+\$)?@|%(?:\d+\$)?lld|%(?:\d+\$)?ld|%(?:\d+\$)?d|%(?:\d+\$)?f|%%")
keys = Path("/tmp/ui-keys.txt").read_text().splitlines()
extra = json.loads((root / "scripts/zh-extra.json").read_text())
main = json.loads((root / "scripts/zh.json").read_text())
table = {**main, **extra}
missing = [k for k in keys if k not in table]
if missing:
    print("missing", len(missing))
    print("\n".join(missing))
    sys.exit(1)
bad = []
for k, v in table.items():
    if spec.findall(k) != spec.findall(v):
        bad.append(k)
if bad:
    print("placeholder mismatch")
    print("\n".join(bad))
    sys.exit(1)
strings = {}
for k, v in sorted(table.items()):
    strings[k] = {
        "localizations": {
            "zh-Hans": {"stringUnit": {"state": "translated", "value": v}}
        }
    }
catalog = {"sourceLanguage": "en", "strings": strings, "version": "1.0"}
out = root / "Compositor" / "Localizable.xcstrings"
out.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + "\n")
print("wrote", len(strings), "to", out)
