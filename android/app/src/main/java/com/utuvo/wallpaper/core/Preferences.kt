package com.utuvo.wallpaper.core

import java.time.ZonedDateTime

/** 最小鍵值儲存介面。B 段用 SharedPreferences 實作；測試用 [MemoryStore]。 */
interface KeyValueStore {
    fun getString(key: String): String?
    fun putString(key: String, value: String?)
    fun getStringList(key: String): List<String>?
    fun putStringList(key: String, value: List<String>?)
    fun getLong(key: String): Long?
    fun putLong(key: String, value: Long?)
    fun getBoolean(key: String): Boolean?
    fun putBoolean(key: String, value: Boolean?)
}

/** 記憶體版 [KeyValueStore]（測試、預覽用）。 */
class MemoryStore : KeyValueStore {
    private val map = HashMap<String, Any>()
    private fun set(key: String, value: Any?) { if (value == null) map.remove(key) else map[key] = value }
    override fun getString(key: String) = map[key] as? String
    override fun putString(key: String, value: String?) = set(key, value)
    @Suppress("UNCHECKED_CAST")
    override fun getStringList(key: String) = map[key] as? List<String>
    override fun putStringList(key: String, value: List<String>?) = set(key, value?.toList())
    override fun getLong(key: String) = map[key] as? Long
    override fun putLong(key: String, value: Long?) = set(key, value)
    override fun getBoolean(key: String) = map[key] as? Boolean
    override fun putBoolean(key: String, value: Boolean?) = set(key, value)
}

/** 使用者選項（iOS `Preferences`，鍵名相同）。API key 不放這裡（B 段存 Keystore）。 */
class Preferences(val store: KeyValueStore) {
    /** 收藏的桌布 id。 */
    var favorites: Set<String>
        get() = store.getStringList("favorites")?.toSet() ?: emptySet()
        set(v) = store.putStringList("favorites", v.sorted())

    /** 固定（釘選）的桌布 id。 */
    var pinnedID: String?
        get() = store.getString("pinnedID")
        set(v) = store.putString("pinnedID", v)

    /** 輪換游標。 */
    var rotation: RotationState
        get() = RotationState((store.getLong("rotationCursor") ?: 0L).toInt(), store.getLong("rotationLastSlot"))
        set(v) { store.putLong("rotationCursor", v.cursor.toLong()); store.putLong("rotationLastSlot", v.lastServedSlot) }

    /** 輪換只用收藏。 */
    var favoritesOnly: Boolean
        get() = store.getBoolean("favoritesOnly") ?: false
        set(v) = store.putBoolean("favoritesOnly", v)

    /** 實際設過的圖片 id（最多 [HISTORY_LIMIT] 筆），給「上一張」用；日夜記成 `dynamic:<phase>`。 */
    var servedHistory: List<String>
        get() = store.getStringList("servedHistory") ?: emptyList()
        set(v) = store.putStringList("servedHistory", v.takeLast(HISTORY_LIMIT))

    /** 輪換頻率（預設每小時）。 */
    var rotationFrequency: RotationFrequency
        get() = RotationFrequency.of(store.getString("rotationFrequency"))
        set(v) = store.putString("rotationFrequency", v.raw)

    /** 每日自動生成開關。 */
    var dailyEnabled: Boolean
        get() = store.getBoolean("dailyEnabled") ?: false
        set(v) = store.putBoolean("dailyEnabled", v)

    /** 日夜桌布開關。 */
    var dynamicEnabled: Boolean
        get() = store.getBoolean("dynamicEnabled") ?: false
        set(v) = store.putBoolean("dynamicEnabled", v)

    /** "demo" 或已發布場景 id。 */
    var dynamicSceneID: String
        get() = store.getString("dynamicSceneID") ?: "demo"
        set(v) = store.putString("dynamicSceneID", v)

    /** 日夜切換方式。 */
    var dynamicTiming: DynamicTiming
        get() = DynamicTiming.of(store.getString("dynamic.timing"))
        set(v) = store.putString("dynamic.timing", v.raw)

    /** 使用者存過的位置；沒有回 null（用 [Coordinate.estimate]）。 */
    var coordinate: Coordinate?
        get() {
            val lat = store.getString("dynamic.latitude")?.toDoubleOrNull()
            val lon = store.getString("dynamic.longitude")?.toDoubleOrNull()
            return if (lat != null && lon != null) Coordinate(lat, lon).takeIf { it.isValid } else null
        }
        set(v) { store.putString("dynamic.latitude", v?.latitude?.toString()); store.putString("dynamic.longitude", v?.longitude?.toString()) }

    /** 日夜 AI 自動頻率。 */
    var dynamicAutoFrequency: DynamicAutoFrequency
        get() = DynamicAutoFrequency.of(store.getString("dynamic.auto.frequency"))
        set(v) = store.putString("dynamic.auto.frequency", v.raw)

    /** 每日（或手動，prefix＝[DailyRecipe.MANUAL_PREFIX]）生成設定。 */
    fun recipe(data: PromptData, prefix: String = DailyRecipe.DAILY_PREFIX): DailyRecipe =
        DailyRecipe(store.getStringList("$prefix.styles") ?: emptyList(), store.getString("$prefix.idea") ?: "").sanitized(data)

    /** 存生成設定（idea 截到 200 字）。 */
    fun saveRecipe(data: PromptData, recipe: DailyRecipe, prefix: String = DailyRecipe.DAILY_PREFIX) {
        val r = recipe.sanitized(data)
        store.putStringList("$prefix.styles", r.styles)
        store.putString("$prefix.idea", r.idea)
    }

    /** 目前的日夜時間表。 */
    fun schedule(data: PromptData, now: ZonedDateTime): DynamicSchedule =
        DynamicSchedule(dynamicTiming, coordinate ?: Coordinate.estimate(data, now.zone, now.toInstant()))

    companion object {
        const val HISTORY_LIMIT = 30
    }
}

/**
 * 決定「現在要設哪張桌布」（iOS `CurrentWallpaper` 的選圖部分，不連網、不生圖、不碰 WallpaperManager）。
 * 回傳 [Resolved]，由 B 段把檔案設成桌布。示範圖（`demo:`）由 B 段自己從 assets 裁切。
 */
class CurrentWallpaper(private val data: PromptData, private val paths: AppPaths, private val prefs: Preferences) {
    /** 要設的圖：一般圖片 id（或 `demo:<檔名>`），或日夜某時段的檔案。 */
    sealed class Resolved {
        data class Item(val item: WallpaperItem) : Resolved()
        data class Dynamic(val sceneID: String, val phase: DayPhase) : Resolved()
    }

    /** 「目前桌布」：日夜 → 固定 → 輪換（時間格變了才前進）。[isDark] 只有 appearance 模式用。 */
    fun resolve(now: ZonedDateTime, items: List<WallpaperItem>, isDark: Boolean = false): Resolved? {
        if (prefs.dynamicEnabled) {
            val schedule = prefs.schedule(data, now)
            val lookahead = if (schedule.timing == DynamicTiming.SOLAR) 5L else 0L
            val phase = schedule.phase(now.plusMinutes(lookahead), isDark)
            val sceneID = prefs.dynamicSceneID
            if (sceneID == "demo" || WallpaperLibrary.scenePhaseFile(paths, sceneID, phase) != null) {
                val marker = "dynamic:" + phase.raw
                val history = prefs.servedHistory
                if (history.lastOrNull() != marker) prefs.servedHistory = history + marker
                return Resolved.Dynamic(sceneID, phase)
            }
            // 場景檔不見了：退回一般規則。
        }
        return pick(now, items, force = false)
    }

    /** 「下一張」：清除固定、強制前進一格（不受日夜影響）。 */
    fun advance(now: ZonedDateTime, items: List<WallpaperItem>): Resolved? {
        prefs.pinnedID = null
        return pick(now, items, force = true)
    }

    /** 「上一張」：清除固定，回到實際設過的上一張；它在輪換池裡時游標也對齊過去。 */
    fun previous(now: ZonedDateTime, items: List<WallpaperItem>): Resolved? {
        prefs.pinnedID = null
        val back = WallpaperSelection.previous(prefs.servedHistory, items.map { it.id }.toSet())
        val item = back?.let { b -> items.firstOrNull { it.id == b.first } } ?: return pick(now, items, force = true, delta = -1)
        val pool = WallpaperSelection.rotationPool(items.map { it.id }, prefs.favorites, prefs.favoritesOnly)
        val index = pool.indexOf(item.id)
        if (index >= 0) {
            val state = prefs.rotation
            prefs.rotation = RotationState(index, WallpaperSelection.slot(now, prefs.rotationFrequency) ?: state.lastServedSlot)
        }
        prefs.servedHistory = back.second
        return Resolved.Item(item)
    }

    /** 「設為桌布」：固定這張並關閉日夜（與 iOS 規則相同）。回傳是否順便關掉了日夜。 */
    fun setAsWallpaper(item: WallpaperItem): Boolean {
        val turnedOff = prefs.dynamicEnabled
        prefs.pinnedID = item.id
        prefs.dynamicEnabled = false
        val history = prefs.servedHistory
        if (history.lastOrNull() != item.id) prefs.servedHistory = history + item.id
        return turnedOff
    }

    /** 收藏／取消收藏。回傳新狀態。 */
    fun toggleFavorite(item: WallpaperItem): Boolean {
        val favs = prefs.favorites
        val on = item.id !in favs
        prefs.favorites = if (on) favs + item.id else favs - item.id
        return on
    }

    /** 固定／取消固定；固定時若日夜開著就關掉。回傳 (是否固定中, 是否關掉了日夜)。 */
    fun togglePin(item: WallpaperItem): Pair<Boolean, Boolean> {
        val pinned = prefs.pinnedID != item.id
        prefs.pinnedID = if (pinned) item.id else null
        val turnedOff = pinned && prefs.dynamicEnabled
        if (turnedOff) prefs.dynamicEnabled = false
        return pinned to turnedOff
    }

    /** 刪除：刪檔、移出收藏、若是固定的那張就取消固定。 */
    fun delete(item: WallpaperItem) {
        WallpaperLibrary.delete(item, paths)
        prefs.favorites = prefs.favorites - item.id
        if (prefs.pinnedID == item.id) prefs.pinnedID = null
    }

    private fun pick(now: ZonedDateTime, items: List<WallpaperItem>, force: Boolean, delta: Int = 1): Resolved? {
        val result = WallpaperSelection.choose(now, null, null, prefs.pinnedID, items.map { it.id }, prefs.favorites,
            prefs.favoritesOnly, prefs.rotation, force, delta, prefs.rotationFrequency)
        prefs.rotation = result.state
        val choice = result.choice ?: return null
        val item = items.firstOrNull { it.id == choice.id } ?: return null
        val history = prefs.servedHistory
        if (history.lastOrNull() != item.id) prefs.servedHistory = history + item.id
        return Resolved.Item(item)
    }
}
