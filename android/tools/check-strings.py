#!/usr/bin/env python3
"""檢查 res/values（英文）與 res/values-zh-rTW（繁中）字串鍵 100% 對齊、格式參數一致。
用法：python3 android/tools/check-strings.py；不對齊 exit 1。"""
import re, sys, xml.etree.ElementTree as ET
from pathlib import Path

res = Path(__file__).resolve().parent.parent / "app/src/main/res"

def load(p):
    out = {}
    for s in ET.parse(p).getroot().iter("string"):
        if s.get("translatable") == "false":
            continue
        out[s.get("name")] = s.text or ""
    return out

en, zh = load(res / "values/strings.xml"), load(res / "values-zh-rTW/strings.xml")
fmt = lambda t: sorted(re.findall(r"%\d+\$[sd]", t))
only_en, only_zh = sorted(set(en) - set(zh)), sorted(set(zh) - set(en))
bad_fmt = [k for k in set(en) & set(zh) if fmt(en[k]) != fmt(zh[k])]
print(f"en={len(en)} zh-rTW={len(zh)} 只在 en={only_en} 只在 zh={only_zh} 參數不符={bad_fmt}")
sys.exit(1 if only_en or only_zh or bad_fmt else 0)
