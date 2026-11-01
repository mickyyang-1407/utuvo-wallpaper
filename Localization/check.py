#!/usr/bin/env python3
"""檢查介面字串：用 swiftc 抽出所有會查表的 key，對照 en.lproj，列出缺翻譯與多餘項目。

用法：python3 -I Localization/check.py            # 缺翻譯數必須是 0
      python3 -I Localization/check.py --template  # 印出缺翻譯的 key（給翻譯用）
"""
import json, pathlib, subprocess, sys, tempfile, re

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = sorted((ROOT / "Sources").glob("*.swift"))
EN = ROOT / "Localization/en.lproj/Localizable.strings"

def extract():
    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run(["xcrun", "-sdk", "macosx", "swiftc", "-c", "-wmo", "-swift-version", "5",
                        "-target", "arm64-apple-macosx14.0", "-module-name", "WallpaperLab",
                        "-emit-localized-strings", "-emit-localized-strings-path", tmp,
                        "-o", str(pathlib.Path(tmp) / "out.o"), *map(str, SRC)], check=True)
        keys = {}
        for data in pathlib.Path(tmp).glob("*.stringsdata"):
            doc = json.loads(data.read_text())
            for table, entries in doc["tables"].items():
                for e in entries:
                    keys.setdefault(e["key"], f'{pathlib.Path(doc["source"]).name}:{e["location"]["startingLine"]}')
        return keys

def load_strings(path):
    out = subprocess.run(["plutil", "-convert", "json", "-o", "-", str(path)], capture_output=True, check=True)
    return json.loads(out.stdout)

keys = extract()
# 只檢查含中文的 key；純英文／符號 key（例如 "utuvo.app"）不需翻譯。
cjk = {k: v for k, v in keys.items() if re.search(r"[一-鿿]", k)}
en = load_strings(EN) if EN.exists() else {}
missing = sorted(k for k in cjk if k not in en)
extra = sorted(k for k in en if k not in keys)
if "--template" in sys.argv:
    for k in missing:
        print(json.dumps(k, ensure_ascii=False), "=", json.dumps(k, ensure_ascii=False) + ";", "//", cjk[k])
    sys.exit(0)
fmt = re.compile(r"%(?:\d+\$)?(?:lld|ld|d|@|lf|f)")
bad_fmt = sorted(k for k in cjk if k in en and sorted(fmt.findall(k)) != sorted(fmt.findall(en[k])))
print(f"查表 key：{len(keys)}（含中文 {len(cjk)}）；en 已翻 {len(en)}；缺翻譯 {len(missing)}；多餘 {len(extra)}；格式符號不符 {len(bad_fmt)}")
for k in missing: print("  缺：", k, "@", cjk[k])
for k in extra: print("  多餘：", k)
for k in bad_fmt: print("  格式不符：", k, "→", en[k])
sys.exit(1 if missing or bad_fmt else 0)
