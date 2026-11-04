#!/bin/bash
# 從共用 Swift 原始碼匯出 Android 用的提示詞資料（data.json）與標準答案（golden.json）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
swiftc -O -o "$OUT/export" \
  "$ROOT/android/tools/export/main.swift" \
  "$ROOT/Sources/PromptTemplates.swift" "$ROOT/Sources/ScenePrompts.swift" "$ROOT/Sources/DynamicSchedule.swift" \
  "$ROOT/Sources/DynamicAuto.swift" "$ROOT/Sources/DailyBatch.swift" "$ROOT/Sources/AppDefaults.swift" \
  "$ROOT/Sources/LocalArt.swift" "$ROOT/Sources/Localization.swift" \
  "$ROOT/ios/App/Core/Models.swift" "$ROOT/ios/App/Core/PortraitPrompt.swift" "$ROOT/ios/App/Core/DayPhase.swift"
mkdir -p "$ROOT/android/app/src/main/assets" "$ROOT/android/app/src/test/resources"
"$OUT/export" "$ROOT/android/app/src/main/assets/prompts.json" "$ROOT/android/app/src/test/resources/golden.json"
