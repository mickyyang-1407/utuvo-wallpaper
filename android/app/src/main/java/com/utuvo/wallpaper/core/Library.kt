package com.utuvo.wallpaper.core

import java.io.File
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.ZonedDateTime
import kotlin.math.floor

/** 檔名 → 分類（與 iOS／Mac `WallpaperCategory` 相同：檔名前綴＝模板 id，取最長匹配）。 */
object WallpaperCategory {
    const val OTHER = "其他"
    private val legacy = listOf("alpine-dawn" to "自然", "paper-landscape" to "極簡")

    /** 依檔名判斷分類；認不出回「其他」。 */
    fun category(data: PromptData, fileName: String): String {
        val lowered = fileName.lowercase()
        val matches = data.templates.map { it.id to it.category } + legacy
        return matches.filter { (id, _) -> lowered == id || lowered.startsWith("$id-") || lowered.startsWith("$id.") }
            .maxByOrNull { it.first.length }?.second ?: OTHER
    }

    /** 分類順序（模板出現順序），「其他」放最後。 */
    fun order(data: PromptData): List<String> = data.categories + OTHER
}

/** 圖庫頂部的篩選。 */
sealed class GalleryFilter(val id: String) {
    data object All : GalleryFilter("all")
    data object Favorites : GalleryFilter("favorites")
    data class Category(val name: String) : GalleryFilter("c-$name")

    companion object {
        /** 全部篩選選項：全部、收藏、各分類。 */
        fun allFilters(data: PromptData): List<GalleryFilter> =
            listOf(All, Favorites) + WallpaperCategory.order(data).map { Category(it) }
    }
}

/**
 * 一張桌布。生成的：id＝檔名（wallpapers 資料夾的 jpg）；示範圖：id＝`demo:<檔名>`。
 * [modifiedMs] 是檔案修改時間（epoch ms），示範圖用 [Long.MIN_VALUE]。
 */
data class WallpaperItem(val id: String, val file: File?, val isDemo: Boolean, val modifiedMs: Long, val category: String) {
    /** 實際檔名（示範圖去掉 `demo:`）。 */
    val fileName: String get() = if (isDemo) id.removePrefix(DEMO_PREFIX) else id

    companion object {
        const val DEMO_PREFIX = "demo:"
    }
}

/** App 資料夾結構（iOS `AppPaths`）。Android 傳 `context.filesDir/UTUVO Wallpaper`。 */
class AppPaths(val root: File) {
    val wallpapers get() = File(root, "wallpapers")
    val originals get() = File(root, "originals")
    val dynamic get() = File(root, "dynamic")
    val demoCache get() = File(root, "demo-cache")
    val currentScenePointer get() = File(dynamic, "current.json")
    val dynamicAutoState get() = File(dynamic, "auto.json")

    /** 建立資料夾。 */
    fun prepare() {
        for (d in listOf(wallpapers, originals, dynamic, demoCache)) d.mkdirs()
    }

    /** 已用空間（bytes）。 */
    fun usedBytes(): Long = root.walkTopDown().filter { it.isFile }.sumOf { it.length() }

    companion object {
        /** 本機日期字串 yyyy-MM-dd（批次檔名用）。 */
        fun dayString(at: ZonedDateTime): String = "%04d-%02d-%02d".format(at.year, at.monthValue, at.dayOfMonth)
    }
}

/** 圖庫操作（iOS `WallpaperLibrary`）。 */
object WallpaperLibrary {
    /** 大圖頁刪掉一張後要停在哪張：優先下一張，最後一張退回上一張；只剩它自己回 null。 */
    fun neighborID(id: String, ids: List<String>): String? {
        val i = ids.indexOf(id)
        if (i < 0 || ids.size <= 1) return null
        return if (i + 1 < ids.size) ids[i + 1] else ids[i - 1]
    }

    /** 生成的桌布（新的在前，同時間依 id）＋示範圖（最後，依傳入順序）。 */
    fun load(data: PromptData, paths: AppPaths, demoNames: List<String> = emptyList()): List<WallpaperItem> {
        val files = paths.wallpapers.listFiles().orEmpty().filter {
            !it.name.startsWith(".") && it.isFile && it.extension.lowercase() in setOf("jpg", "jpeg")
        }
        val generated = files.map { WallpaperItem(it.name, it, false, it.lastModified(), WallpaperCategory.category(data, it.name)) }
            .sortedWith(compareByDescending<WallpaperItem> { it.modifiedMs }.thenBy { it.id })
        val demos = demoNames.map {
            WallpaperItem(WallpaperItem.DEMO_PREFIX + it, null, true, Long.MIN_VALUE, WallpaperCategory.category(data, it))
        }
        return generated + demos
    }

    /** 依篩選條件過濾。 */
    fun filter(items: List<WallpaperItem>, filter: GalleryFilter, favorites: Set<String>): List<WallpaperItem> = when (filter) {
        GalleryFilter.All -> items
        GalleryFilter.Favorites -> items.filter { it.id in favorites }
        is GalleryFilter.Category -> items.filter { it.category == filter.name }
    }

    /** 刪掉裝置尺寸 JPEG 與同名原生 PNG；示範圖不能刪。 */
    fun delete(item: WallpaperItem, paths: AppPaths) {
        if (item.isDemo) return
        File(paths.wallpapers, item.id).delete()
        File(paths.originals, item.id.substringBeforeLast('.') + ".png").delete()
    }

    /** 日夜場景某時段的裝置尺寸 JPEG；不存在回 null（示範場景由 B 段從 assets 取）。 */
    fun scenePhaseFile(paths: AppPaths, sceneID: String, phase: DayPhase): File? =
        File(File(paths.dynamic, sceneID), phase.raw + ".jpg").takeIf { it.isFile }
}

/** 輪換頻率。Android 背景工作最短 15 分鐘，所以 B 段介面不提供 [EVERY_RUN]（保留給「下一張」手動觸發語意）。 */
enum class RotationFrequency(val raw: String, val minutes: Int?) {
    EVERY_RUN("everyRun", null), FIFTEEN_MINUTES("fifteenMinutes", 15), THIRTY_MINUTES("thirtyMinutes", 30),
    HOURLY("hourly", 60), DAILY("daily", 1440);

    companion object {
        /** 從 raw 字串還原，未知值＝HOURLY。 */
        fun of(raw: String?): RotationFrequency = entries.firstOrNull { it.raw == raw } ?: HOURLY
    }
}

/** 輪換游標（持久化）。 */
data class RotationState(val cursor: Int = 0, val lastServedSlot: Long? = null)

/** 選圖規則（iOS `WallpaperSelection`）：日夜 → 固定（釘選）→ 輪換。純函式。 */
object WallpaperSelection {
    private const val REFERENCE_EPOCH = 978_307_200L // 2001-01-01T00:00:00Z

    /** 選圖來源。 */
    sealed class Source {
        data class Dynamic(val phase: DayPhase) : Source()
        data object Pinned : Source()
        data class Rotation(val index: Int) : Source()
    }

    /** 選到的那張。 */
    data class Choice(val id: String, val source: Source)

    /** [choose] 的結果：選到的與新的游標狀態。 */
    data class Result(val choice: Choice?, val state: RotationState)

    /** 當地「小時序號」：自 2001-01-01 起的日數 × 24 ＋ 小時。 */
    fun hourSlot(at: ZonedDateTime): Long {
        val days = LocalDate.of(at.year, at.monthValue, at.dayOfMonth).toEpochDay() - LocalDate.of(2001, 1, 1).toEpochDay()
        return days * 24 + at.hour
    }

    /** 依頻率的時間格序號（單調遞增）；everyRun 回 null。秋天撥回的那小時會落在不同格。 */
    fun slot(at: ZonedDateTime, frequency: RotationFrequency): Long? {
        val size = frequency.minutes ?: return null
        if (frequency == RotationFrequency.DAILY) return Math.floorDiv(hourSlot(at), 24L)
        val instant = at.toInstant()
        val standard = at.zone.rules.getStandardOffset(instant).totalSeconds
        val seconds = (instant.epochSecond - REFERENCE_EPOCH) + instant.nano / 1e9 + standard
        val minutes = seconds / 60
        val truncated = if (minutes < 0) kotlin.math.ceil(minutes).toLong() else floor(minutes).toLong()
        return floor(truncated.toDouble() / size).toLong()
    }

    /** 前進一步：force＝強制前進 [delta]；否則時間格變了才前進一格，第一次只記錄。 */
    fun step(state: RotationState, slot: Long, count: Int, force: Boolean, delta: Int = 1): Pair<RotationState, Int?> {
        var cursor = state.cursor
        if (force) cursor += delta
        else if (state.lastServedSlot != null && state.lastServedSlot != slot) cursor += 1
        val next = RotationState(cursor, slot)
        if (count <= 0) return next to null
        return next to ((cursor % count) + count) % count
    }

    /**
     * 選圖。[dynamicPhase]＋[dynamicPhaseIDs]：日夜模式啟用時目前時段與四時段檔案 id（null＝未啟用）。
     * 只有真的走到輪換才更新游標。
     */
    fun choose(
        at: ZonedDateTime,
        dynamicPhase: DayPhase?,
        dynamicPhaseIDs: Map<DayPhase, String>?,
        pinnedID: String?,
        available: List<String>,
        favorites: Set<String>,
        favoritesOnly: Boolean,
        state: RotationState,
        force: Boolean = false,
        delta: Int = 1,
        frequency: RotationFrequency = RotationFrequency.HOURLY,
    ): Result {
        if (dynamicPhaseIDs != null && dynamicPhase != null) {
            dynamicPhaseIDs[dynamicPhase]?.let { return Result(Choice(it, Source.Dynamic(dynamicPhase)), state) }
        }
        if (pinnedID != null && pinnedID in available) return Result(Choice(pinnedID, Source.Pinned), state)
        val pool = rotationPool(available, favorites, favoritesOnly)
        val slotValue = slot(at, frequency) ?: ((state.lastServedSlot ?: -1L) + 1)
        val (next, index) = step(state, slotValue, pool.size, force, delta)
        if (index == null) return Result(null, state)
        return Result(Choice(pool[index], Source.Rotation(index)), next)
    }

    /** 輪換池：只限收藏且有收藏時用收藏，否則全部。 */
    fun rotationPool(available: List<String>, favorites: Set<String>, favoritesOnly: Boolean): List<String> {
        if (!favoritesOnly) return available
        return available.filter { it in favorites }.ifEmpty { available }
    }

    /** 「上一張」：歷史最後一筆是目前這張，往前找第一筆不同且還在圖庫裡的；回傳 (id, 剩下的歷史)。 */
    fun previous(history: List<String>, available: Set<String>): Pair<String, List<String>>? {
        val current = history.lastOrNull() ?: return null
        val rest = history.dropLast(1).toMutableList()
        while (rest.isNotEmpty()) {
            val candidate = rest.last()
            if (candidate != current && candidate in available) return candidate to rest.toList()
            rest.removeAt(rest.size - 1)
        }
        return null
    }
}

/** 顯示名稱（iOS `WallpaperTitles`）：只影響顯示，不改檔名。 */
object WallpaperTitles {
    /** 模板 id → 繁中顯示名稱（B 段以此為 key 查英文）。 */
    val templateTitles: Map<String, String> = mapOf(
        "nature-dawn" to "自然風景", "minimal-paper" to "紙雕極簡", "abstract-flow" to "流動光帶",
        "illustration-dusk" to "插畫街景", "cosmic-nebula" to "深空", "botanical-macro" to "自然微距",
        "watercolor-meadow" to "水彩風景", "architecture-arcade" to "建築光影", "animation-coast" to "手繪動畫",
        "gradient-tide" to "柔和漸層", "solid-color" to "純色", "gradient-soft" to "漸層", "dark-oled" to "深色",
        "geometric" to "幾何", "city" to "城市", "animals" to "動物", "render-3d" to "3D 立體",
    )

    /** 早期示範檔固定名稱。 */
    fun legacyTitle(fileName: String): String? = when (fileName.lowercase()) {
        "abstract-flow-5k.png" -> "流光"
        "alpine-dawn-5k.png" -> "湖畔晨光"
        "paper-landscape-5k.png", "paper-landscape-demo-5k.jpg" -> "紙上山丘"
        else -> null
    }

    private val dailyDay = Regex("""daily-(\d{4}-\d{2}-\d{2})""")

    /**
     * 「範本標題 · 日期」。[localize] 把繁中 key 轉成目前語言；[formatDay] 把日期轉成顯示字串
     * （中文 M/d、英文 "Nov 1"）。
     */
    fun baseTitle(data: PromptData, item: WallpaperItem, zone: ZoneId, localize: (String) -> String,
                  formatDay: (LocalDate) -> String): String {
        val name = item.fileName
        legacyTitle(name)?.let { return localize(it) }
        val lowered = name.lowercase()
        val template = data.templates.map { it.id }.filter { lowered.startsWith("$it-") || lowered.startsWith("$it.") }
            .maxByOrNull { it.length }
        val title = template?.let { templateTitles[it] } ?: return name.substringBeforeLast('.', name)
        val day = dailyDay.find(lowered)?.groupValues?.get(1)?.let { runCatching { LocalDate.parse(it) }.getOrNull() }
            ?: Instant.ofEpochMilli(item.modifiedMs.coerceAtLeast(0)).atZone(zone).toLocalDate()
        return "${localize(title)} · ${formatDay(day)}"
    }

    /** 一次算整個圖庫的名稱；重複者依檔名排序加「 · 1／· 2」。回傳 id → 名稱。 */
    fun titles(data: PromptData, items: List<WallpaperItem>, zone: ZoneId, localize: (String) -> String = { it },
               formatDay: (LocalDate) -> String = { "${it.monthValue}/${it.dayOfMonth}" }): Map<String, String> {
        val bases = items.sortedBy { it.id }.map { it.id to baseTitle(data, it, zone, localize, formatDay) }
        val totals = bases.groupingBy { it.second }.eachCount()
        val seen = HashMap<String, Int>()
        val result = LinkedHashMap<String, String>()
        for ((id, base) in bases) {
            if ((totals[base] ?: 0) <= 1) { result[id] = base; continue }
            val index = (seen[base] ?: 0) + 1
            seen[base] = index
            result[id] = "$base · $index"
        }
        return result
    }
}

/** 總覽的真實數字（iOS `OverviewFacts`）。 */
object OverviewFacts {
    /** 分類分布條的一段。 */
    data class CategorySegment(val category: String, val newCount: Int, val oldCount: Int) {
        val total: Int get() = newCount + oldCount
    }

    private fun isToday(item: WallpaperItem, now: ZonedDateTime): Boolean =
        !item.isDemo && Instant.ofEpochMilli(item.modifiedMs).atZone(now.zone).toLocalDate() == now.toLocalDate()

    /** 依分類順序統計；今天修改的生成圖算新的。沒有圖的分類不列。 */
    fun segments(data: PromptData, items: List<WallpaperItem>, now: ZonedDateTime): List<CategorySegment> =
        WallpaperCategory.order(data).mapNotNull { c ->
            val inCategory = items.filter { it.category == c }
            val new = inCategory.count { isToday(it, now) }
            CategorySegment(c, new, inCategory.size - new).takeIf { it.total > 0 }
        }

    /** 今天新增幾張。 */
    fun todayNew(items: List<WallpaperItem>, now: ZonedDateTime): Int = items.count { isToday(it, now) }

    /** 下一個時段與切換時間 "HH:mm"；appearance 模式回 (另一段, "")。 */
    fun nextPhase(schedule: DynamicSchedule, after: ZonedDateTime): Pair<DayPhase, String> {
        schedule.next(after)?.let { return it.phase to DynamicSchedule.clock(it.at.hour * 60 + it.at.minute) }
        val current = schedule.phase(after, isDark = false)
        return (if (current == DayPhase.NIGHT) DayPhase.DAY else DayPhase.NIGHT) to ""
    }
}

/** 隨機檔名識別碼（8 碼，去掉易混字元）。 */
object RandomID {
    private const val ALPHABET = "abcdefghijkmnpqrstuvwxyz23456789"

    /** 產生一個新 id。 */
    fun make(random: kotlin.random.Random = kotlin.random.Random.Default): String =
        String(CharArray(8) { ALPHABET[random.nextInt(ALPHABET.length)] })
}

/** aspect-fill 置中裁切數學（iOS `CropMath`）。 */
object CropMath {
    /** 整數像素矩形。 */
    data class Rect(val x: Int, val y: Int, val width: Int, val height: Int)

    /** 在來源像素座標中，回傳要取用的置中矩形。任一尺寸 ≤0 回全 0。 */
    fun aspectFillSourceRect(sourceW: Int, sourceH: Int, targetW: Int, targetH: Int): Rect {
        if (sourceW <= 0 || sourceH <= 0 || targetW <= 0 || targetH <= 0) return Rect(0, 0, 0, 0)
        val sourceAspect = sourceW.toDouble() / sourceH
        val targetAspect = targetW.toDouble() / targetH
        return if (sourceAspect > targetAspect) {
            val width = swiftRound(sourceH * targetAspect)
            val x = floor((sourceW - width) / 2.0).toInt()
            Rect(x, 0, width, sourceH)
        } else {
            val height = swiftRound(sourceW / targetAspect)
            val y = floor((sourceH - height) / 2.0).toInt()
            Rect(0, y, sourceW, height)
        }
    }

    /** 直式輸出尺寸（寬 < 高）。 */
    fun portraitPixels(w: Int, h: Int): Pair<Int, Int> = minOf(w, h) to maxOf(w, h)

    /** "W × H" 標籤。 */
    fun label(w: Int, h: Int): String = "$w × $h"

    private fun swiftRound(v: Double): Int = Math.round(v).toInt() // 輸入皆為正數：.5 遠離 0 與 round 相同
}
