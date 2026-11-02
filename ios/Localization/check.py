#!/usr/bin/env python3
"""iOS 介面字串檢查：用 swiftc 抽出所有查表 key，對照 en.lproj 與 zh-Hant.lproj。

用法：python3 -I ios/Localization/check.py             # 缺翻譯必須是 0
      python3 -I ios/Localization/check.py --template  # 印出缺英文翻譯的 key（給翻譯用）
"""
import json, pathlib, re, subprocess, sys, tempfile

IOS = pathlib.Path(__file__).resolve().parent.parent
REPO = IOS.parent
SRC = sorted((IOS / "App").rglob("*.swift")) + [REPO / "Sources/PromptTemplates.swift", REPO / "Sources/DailyBatch.swift", REPO / "Sources/AppLanguage.swift", REPO / "Sources/DynamicSchedule.swift"]
TABLES = {lang: IOS / f"Localization/{lang}.lproj/Localizable.strings" for lang in ("en", "zh-Hant")}
INFOPLIST_KEYS = ["CFBundleDisplayName", "NSPhotoLibraryAddUsageDescription"]

def extract():
    sdk = subprocess.run(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], capture_output=True, text=True, check=True).stdout.strip()
    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run(["xcrun", "-sdk", "iphonesimulator", "swiftc", "-c", "-wmo", "-swift-version", "5", "-sdk", sdk,
                        "-target", "arm64-apple-ios17.0-simulator", "-module-name", "UTUVOWallpaper", "-D", "DEBUG",
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
    if not path.exists():
        return {}
    out = subprocess.run(["plutil", "-convert", "json", "-o", "-", str(path)], capture_output=True, check=True)
    return json.loads(out.stdout)

keys = extract()
# 只檢查含中文的 key；純英文／符號 key（例如 "OpenAI API key"）不需翻譯。
cjk = {k: v for k, v in keys.items() if re.search(r"[一-鿿]", k)}
tables = {lang: load_strings(path) for lang, path in TABLES.items()}
en = tables["en"]
if "--template" in sys.argv:
    for k in sorted(k for k in cjk if k not in en):
        print(json.dumps(k, ensure_ascii=False), "=", json.dumps(k, ensure_ascii=False) + ";", "//", cjk[k])
    sys.exit(0)

fmt = re.compile(r"%(?:\d+\$)?(?:lld|ld|d|@|lf|f)")
def specs(text):
    # 位置參數（%1$@）可調換順序，比對時只看型別與數量
    return sorted(re.sub(r"\d+\$", "", m) for m in fmt.findall(text))
failed = False
for lang, table in tables.items():
    missing = sorted(k for k in cjk if k not in table)
    extra = sorted(k for k in table if k not in keys)
    bad_fmt = sorted(k for k in cjk if k in table and specs(k) != specs(table[k]))
    untranslated = sorted(k for k in cjk if lang == "en" and k in table and re.search(r"[一-鿿]", table[k]))
    print(f"[{lang}] 查表 key：{len(keys)}（含中文 {len(cjk)}）；已翻 {len(table)}；缺翻譯 {len(missing)}；"
          f"多餘 {len(extra)}；格式符號不符 {len(bad_fmt)}；英文表仍含中文 {len(untranslated)}")
    for k in missing: print("  缺：", k, "@", cjk[k])
    for k in extra: print("  多餘：", k)
    for k in bad_fmt: print("  格式不符：", k, "→", table[k])
    for k in untranslated: print("  未翻：", k, "→", table[k])
    failed |= bool(missing or bad_fmt or untranslated)

for lang in TABLES:
    info = load_strings(IOS / f"Localization/{lang}.lproj/InfoPlist.strings")
    lack = [k for k in INFOPLIST_KEYS if k not in info]
    print(f"[{lang}] InfoPlist.strings 缺 {len(lack)}", *lack)
    failed |= bool(lack)
sys.exit(1 if failed else 0)
