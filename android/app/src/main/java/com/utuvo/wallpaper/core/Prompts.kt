package com.utuvo.wallpaper.core

import java.time.LocalDate
import java.time.temporal.ChronoUnit

/** FNV-1a 64-bit 字串雜湊（UTF-8），與 Swift `DynamicAutoPlanner.stableHash` 相同。 */
object StableHash {
    /** 回傳無號 64 位元雜湊值。 */
    fun of(text: String): ULong {
        var hash = 0xcbf29ce484222325uL
        for (b in text.encodeToByteArray()) hash = (hash xor (b.toUByte().toULong())) * 0x100000001b3uL
        return hash
    }
}

/** 一張要生成的圖：用哪個風格、檔名前綴、送出的提示詞（Swift `PlannedPrompt`）。 */
data class PlannedPrompt(val templateID: String, val slug: String, val prompt: String)

/**
 * 使用者選的每日生成方式（Swift `DailyRecipe`）：哪些風格（模板 id，空＝全部）、自己的想法。
 */
data class DailyRecipe(val styles: List<String> = emptyList(), val idea: String = "") {
    /** 選了哪些分類（空＝全部）。 */
    fun categories(data: PromptData): List<String> =
        data.categories.filter { c -> data.templates.any { it.category == c && styles.contains(it.id) } }

    /** 打開／關閉一個分類，回傳新的設定（風格依模板原順序排列）。 */
    fun withCategory(data: PromptData, category: String, on: Boolean): DailyRecipe {
        val ids = data.templates.filter { it.category == category }.map { it.id }
        var next = styles.filter { it !in ids }
        if (on) next = next + ids
        return copy(styles = data.templates.map { it.id }.filter { it in next })
    }

    /** 實際要用的模板（沒選＝全部）。 */
    fun templates(data: PromptData): List<PromptTemplate> {
        val picked = data.templates.filter { styles.contains(it.id) }
        return picked.ifEmpty { data.templates }
    }

    /** 選的分類全是本機畫的（純色／漸層）：不需要 API key。 */
    fun isLocalOnly(data: PromptData): Boolean = templates(data).all { it.local != null }

    /** 去頭尾空白並截到 [IDEA_LIMIT] 個字。 */
    val trimmedIdea: String get() = SwiftText.prefix(SwiftText.trim(idea), IDEA_LIMIT)

    /** 存檔用：idea 截到上限、未知的風格 id 移除。 */
    fun sanitized(data: PromptData): DailyRecipe {
        val known = data.templates.map { it.id }.toSet()
        return DailyRecipe(styles.filter { it in known }, SwiftText.prefix(idea, IDEA_LIMIT))
    }

    companion object {
        const val IDEA_LIMIT = 200
        /** 手動「產生桌布」另存一組設定用的前綴，不影響每日排程。 */
        const val MANUAL_PREFIX = "manual"
        const val DAILY_PREFIX = "daily"
    }
}

/** 每日計畫（Swift `DailyPlan`）：同一天同一組設定結果固定。 */
object DailyPlan {
    /** 產生 [count] 張的計畫；手動生成帶 [salt] 與當天每日批次錯開。 */
    fun make(data: PromptData, day: String, count: Int, recipe: DailyRecipe, salt: String = ""): List<PlannedPrompt> {
        if (count <= 0) return emptyList()
        val templates = recipe.templates(data)
        val idea = recipe.trimmedIdea
        val dayNumber = dayIndex(day) + if (salt.isEmpty()) 0 else (StableHash.of(salt) % 997uL).toInt()
        val offset = dayNumber % templates.size
        val used = HashMap<String, Int>()
        return (0 until count).map { index ->
            val template = templates[(offset + index) % templates.size]
            val round = used[template.id] ?: 0
            used[template.id] = round + 1
            val base = (StableHash.of(template.id) % 1000uL).toInt()
            fun <T> pick(list: List<T>, stride: Int): T = list[(base + dayNumber * stride + round) % list.size]
            val subject = if (idea.isEmpty() || template.local != null) pick(subjectPool(data, template), 1) else idea
            val palette = pick(template.palettes, 1)
            val light = pick(data.lights, 5)
            val composition = pick(data.compositions, if (idea.isEmpty()) 1 else 7)
            // 約一半的圖再加一句氣氛／構圖細節。
            val roll = (StableHash.of("$day#$salt#$index") % 1_000_000uL).toInt()
            val slot = roll % (data.details.size * 2)
            val detail = if (slot < data.details.size) data.details[slot].en else null
            // 內容型分類約一半換畫風；自己寫想法時照想法走。
            val styleRoll = (StableHash.of("style#$day#$salt#$index") % 1_000_000uL).toInt()
            val artStyle = if (idea.isEmpty() && template.id in data.mixedStyleTemplates && styleRoll % 2 == 1)
                data.autoStyles[(styleRoll / 2) % data.autoStyles.size].en else null
            val slug = if (round == 0) template.id else "${template.id}-${round + 1}"
            PlannedPrompt(template.id, slug, template.compose(subject, palette, light, composition, detail, artStyle))
        }
    }

    /** 每個風格可畫的主題：自己的＋同分類 AI 靈感（英文），去重保序；本機畫的只用自己的。 */
    fun subjectPool(data: PromptData, template: PromptTemplate): List<String> {
        if (template.local != null) return template.subjects
        return (template.subjects + (data.ideas[template.category]?.map { it.en } ?: emptyList())).distinct()
    }

    /** "yyyy-MM-dd" → 從 2000-01-01 起第幾天；看不懂就用雜湊 % 100000。 */
    fun dayIndex(day: String): Int {
        val parts = day.split("-").filter { it.isNotEmpty() }.mapNotNull { it.toLongOrNull() }
        val fallback = (StableHash.of(day) % 100_000uL).toInt()
        if (parts.size != 3) return fallback
        return try {
            // Foundation 的 Calendar 對超出範圍的月／日會順延，這裡照做。
            val date = LocalDate.of(parts[0].toInt(), 1, 1).plusMonths(parts[1] - 1).plusDays(parts[2] - 1)
            val days = ChronoUnit.DAYS.between(LocalDate.of(2000, 1, 1), date)
            if (days < 0 || days > Int.MAX_VALUE) fallback else days.toInt()
        } catch (e: RuntimeException) {
            fallback
        }
    }

    /** 舊版進度檔沒有存計畫：檔名照舊輪替，提示詞用新的組法。 */
    fun legacy(data: PromptData, day: String, count: Int): List<PlannedPrompt> {
        if (data.templates.isEmpty() || count <= 0) return emptyList()
        val templates = (0 until count).map { data.templates[it % data.templates.size] }
        val fresh = make(data, day, count, DailyRecipe())
        return templates.mapIndexed { index, t ->
            val match = fresh.firstOrNull { it.templateID == t.id }?.prompt ?: t.prompt
            PlannedPrompt(t.id, t.id, if (index < fresh.size) match else t.prompt)
        }
    }
}

/** 「AI 靈感」：依分類挑一個主題點子（本機挑選，不連網）。Swift `PromptInspiration`。 */
object PromptInspiration {
    /** [random] 回傳 0..<1_000_000 的整數；測試可餵固定序列。 */
    fun pick(
        data: PromptData,
        categories: List<String>,
        current: String,
        chinese: Boolean,
        random: () -> Int = { kotlin.random.Random.nextInt(0, 1_000_000) },
    ): String {
        val withIdeas = categories.filter { data.ideas[it] != null }
        val keys = withIdeas.ifEmpty { data.categories }
        val pool = keys.flatMap { data.ideas[it] ?: emptyList() }
        if (pool.isEmpty()) return current
        val details = data.details
        repeat(8) {
            val roll = random()
            val idea = pool[roll % pool.size]
            val slot = (roll / pool.size) % (details.size * 2)
            var text = if (chinese) idea.zh else idea.en
            if (slot < details.size) text += if (chinese) "，" + details[slot].zh else ", " + details[slot].en
            if (text != current) return text
        }
        return if (chinese) pool[0].zh else pool[0].en
    }
}

/** 橫式 16:9 提示詞轉直式（Swift `PortraitPrompt`）。 */
object PortraitPrompt {
    const val CLOCK_SENTENCE =
        "vertical 9:16 iPhone wallpaper, leave the top fifth of the frame uncluttered for the lock-screen clock"

    private const val MARKER = "vertical 9:16 iPhone wallpaper"
    private const val WHITESPACE = "[\\t\\n\\f\\r\\p{Z}]"

    private val rules: List<Pair<Regex, String>> = listOf(
        "vertical texture yet wide 16:9 framing" to "vertical framing",
        """wide\s+16:9\s+desktop\s+wallpaper""" to "vertical 9:16 iPhone wallpaper",
        """16:9\s+desktop\s+wallpaper""" to "vertical 9:16 iPhone wallpaper",
        """wide\s+16:9""" to "vertical 9:16",
        """16\s*:\s*9""" to "9:16",
        """desktop\s+wallpaper""" to "iPhone wallpaper",
        """desktop\s+landscape""" to "phone landscape",
        "calm horizontal rhythm" to "calm layered rhythm",
    ).map { (p, r) ->
        // ICU（NSRegularExpression）的 \s＝[\t\n\f\r\p{Z}]、大小寫不分是 Unicode 版。
        // 不用 (?U)：Android 的 ICU regex 不支援 UNICODE_CHARACTER_CLASS（會丟 PatternSyntaxException）。
        Regex("(?iu)" + p.replace("\\s", WHITESPACE)) to r
    }

    /** 純函式：把橫式字樣換成直式，並補上時鐘區留白的說明。 */
    fun convert(prompt: String): String {
        var text = SwiftText.trim(prompt)
        for ((regex, replacement) in rules) text = regex.replace(text, Regex.escapeReplacement(replacement))
        if (text.endsWith(".")) text = text.dropLast(1)
        // 已寫過一次直式字樣時就地換成完整說明，不重複兩次。
        val i = text.indexOf(MARKER)
        if (i >= 0) return text.substring(0, i) + CLOCK_SENTENCE + text.substring(i + MARKER.length) + "."
        return "$text, $CLOCK_SENTENCE."
    }
}

/** 日夜場景提示詞（Swift `ScenePrompt`）。 */
object ScenePrompt {
    enum class Canvas { DESKTOP, PHONE }

    val phases = listOf("dawn", "day", "dusk", "night")

    /** 第一張（白天）：之後三個時段都從這張改光線。 */
    fun base(scene: String, canvas: Canvas = Canvas.PHONE): String {
        val frame = if (canvas == Canvas.DESKTOP) "wide 16:9 desktop wallpaper" else "vertical 9:16 iPhone wallpaper"
        val phoneNote = if (canvas == Canvas.PHONE)
            "\nLeave the top fifth of the frame uncluttered for the lock-screen clock." else ""
        return "Create one $frame image of: $scene.\n" +
            "Follow the art style, medium and subject in that description exactly. It can be anything: " +
            "hand-painted animation background art, anime, illustration, watercolor, painting, pixel art, 3D render or photography; " +
            "an interior, a street, a café, a still life, an animal, a character, a city or a landscape. " +
            "If no style is given, choose one that suits the subject.\n" +
            "Show it in clear daytime light from one fixed viewpoint with clear, stable shapes, because the same picture " +
            "will be relit for dawn, dusk and night. Where it fits, include something that shows the time of day, " +
            "such as sky, a window, lamps or shadows. No text, logos or watermark.$phoneNote"
    }

    /** 其他時段：同一張圖只換光線。[phase] 是 dawn／day／dusk／night。 */
    fun relight(phase: String, canvas: Canvas = Canvas.PHONE): String {
        val lighting = when (phase) {
            "dawn" -> "early dawn: pale pink and gold light, long soft shadows and a little mist"
            "dusk" -> "sunset: warm amber light, a glowing horizon where there is sky, and cool violet shadows"
            "night" -> "night: a dark blue sky with moonlight or stars where there is sky, darker surroundings, " +
                "and lamps, windows, screens or signs glowing warmly where they exist"
            else -> "clear daytime"
        }
        val frame = if (canvas == Canvas.DESKTOP) "wide 16:9" else "vertical 9:16"
        return "Change the time of day in this exact reference image to $lighting.\n" +
            "Keep its art style, medium, line work, brushwork and rendering exactly as they are. Keep the identical framing, " +
            "viewpoint and every object, character and building in the same place. Change only the light: sky, sun or moon, " +
            "shadows, color temperature, and lights that would naturally be on or off. Add nothing new, no text or watermark.\n" +
            "Output the same $frame image, fully aligned to the reference."
    }
}
