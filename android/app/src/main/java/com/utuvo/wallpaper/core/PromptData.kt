package com.utuvo.wallpaper.core

import org.json.JSONArray
import org.json.JSONObject

/** 中英一組文字（Swift 的 `(zh:, en:)`）。 */
data class ZhEn(val zh: String, val en: String)

/** 日夜 AI 自動的主題（Swift `DynamicAutoPlanner.Subject`）。 */
data class AutoSubject(val id: String, val zh: String, val en: String, val winterOnly: Boolean = false)

/**
 * 一組原創風格提示詞模板（Swift `PromptTemplate`）。
 * `local` 不為 null 時代表本機畫（"solid"／"gradient"），palettes 放色碼規格。
 */
data class PromptTemplate(
    val id: String,
    val title: String,
    val category: String,
    val style: String,
    val subjects: List<String>,
    val palettes: List<String>,
    val representational: Boolean = true,
    val local: String? = null,
) {
    /** 預設組合（第一個主題、第一組配色）。 */
    val prompt: String get() = compose(subjects[0], palettes[0], null, null)

    /**
     * 組出送給模型的橫式提示詞（與 Swift `compose` 逐字相同）。
     * [artStyle] 有值時開頭改成 "Art style: …, rich detail, calm mood"；[detail] 接在構圖之後。
     */
    fun compose(subject: String, palette: String, light: String?, composition: String?,
                detail: String? = null, artStyle: String? = null): String {
        if (local != null) return LocalArt.PREFIX + local + ":" + palette
        val lead = artStyle?.let { "Art style: $it, rich detail, calm mood" } ?: style
        val parts = mutableListOf(lead, "Subject: $subject", "Palette: $palette")
        if (light != null && representational) parts.add(light)
        if (composition != null) parts.add(composition)
        if (detail != null) parts.add(detail)
        parts.add("wide 16:9 desktop wallpaper, no text, no watermark, no logos")
        return parts.joinToString(". ") + "."
    }
}

/**
 * 提示詞資料（由 `android/tools/export/export.sh` 從 Swift 匯出成 `assets/prompts.json`，不要手改）。
 * App 端用 [PromptData.parse] 讀 asset 字串；所有提示詞邏輯都吃這個物件。
 */
data class PromptData(
    val templates: List<PromptTemplate>,
    val lights: List<String>,
    val compositions: List<String>,
    /** 分類 → 靈感點子。 */
    val ideas: Map<String, List<ZhEn>>,
    val details: List<ZhEn>,
    val autoSubjects: List<AutoSubject>,
    val autoStyles: List<ZhEn>,
    val autoWeathers: List<ZhEn>,
    /** 時區 id → (緯度, 經度)，只含代表城市表內的時區。 */
    val timeZoneCities: Map<String, Coordinate>,
    /** 可以換畫風的模板 id（內容型分類）。 */
    val mixedStyleTemplates: Set<String> = emptySet(),
) {
    /** 分類（與圖庫側欄相同順序，去重）。 */
    val categories: List<String> by lazy { templates.map { it.category }.distinct() }

    /** 依 id 找模板。 */
    fun template(id: String): PromptTemplate? = templates.firstOrNull { it.id == id }

    companion object {
        /** 解析 prompts.json 內容。 */
        fun parse(json: String): PromptData {
            val o = JSONObject(json)
            fun strings(a: JSONArray) = List(a.length()) { a.getString(it) }
            fun pairs(a: JSONArray) = List(a.length()) { i -> a.getJSONArray(i).let { ZhEn(it.getString(0), it.getString(1)) } }
            val templates = o.getJSONArray("templates").let { a ->
                List(a.length()) { i ->
                    val t = a.getJSONObject(i)
                    PromptTemplate(
                        id = t.getString("id"), title = t.getString("title"), category = t.getString("category"),
                        style = t.getString("style"), subjects = strings(t.getJSONArray("subjects")),
                        palettes = strings(t.getJSONArray("palettes")),
                        representational = t.optBoolean("representational", true),
                        local = if (t.has("local")) t.getString("local") else null,
                    )
                }
            }
            val ideasObj = o.getJSONObject("ideas")
            val ideas = ideasObj.keys().asSequence().associateWith { pairs(ideasObj.getJSONArray(it)) }
            val subjects = o.getJSONArray("autoSubjects").let { a ->
                List(a.length()) { i ->
                    val s = a.getJSONObject(i)
                    AutoSubject(s.getString("id"), s.getString("zh"), s.getString("en"), s.optBoolean("winterOnly", false))
                }
            }
            val tzObj = o.getJSONObject("timeZoneCities")
            val tz = tzObj.keys().asSequence().associateWith { k ->
                tzObj.getJSONArray(k).let { Coordinate(it.getDouble(0), it.getDouble(1)) }
            }
            return PromptData(
                templates = templates,
                lights = strings(o.getJSONArray("lights")),
                compositions = strings(o.getJSONArray("compositions")),
                ideas = ideas,
                details = pairs(o.getJSONArray("details")),
                autoSubjects = subjects,
                autoStyles = pairs(o.getJSONArray("autoStyles")),
                autoWeathers = pairs(o.getJSONArray("autoWeathers")),
                timeZoneCities = tz,
                mixedStyleTemplates = o.optJSONArray("mixedStyleTemplates")?.let { strings(it).toSet() } ?: emptySet(),
            )
        }
    }
}

/** 與 Swift 相同語意的字串小工具。 */
object SwiftText {
    /** Swift `CharacterSet.whitespacesAndNewlines`。 */
    fun isWhitespaceOrNewline(c: Char): Boolean =
        c in '\u0009'..'\u000D' || c == '\u0085' || when (Character.getType(c).toByte()) {
            Character.SPACE_SEPARATOR, Character.LINE_SEPARATOR, Character.PARAGRAPH_SEPARATOR -> true
            else -> false
        }

    /** Swift `trimmingCharacters(in: .whitespacesAndNewlines)`。 */
    fun trim(text: String): String = text.trim(::isWhitespaceOrNewline)

    /** Swift `String.prefix(n)`：以字元（grapheme cluster）計數。 */
    fun prefix(text: String, limit: Int): String {
        if (text.length <= limit) return text
        val breaks = java.text.BreakIterator.getCharacterInstance()
        breaks.setText(text)
        var end = 0
        repeat(limit) {
            val next = breaks.next()
            if (next == java.text.BreakIterator.DONE) return text
            end = next
        }
        return text.substring(0, end)
    }
}
