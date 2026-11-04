package com.utuvo.wallpaper.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.ZonedDateTime

/** 圖庫（分類、排序、刪除、收藏、固定）、選圖規則（日夜＞固定＞輪換、上一張）、裁切、名稱、總覽。 */
class LibraryTest {
    private val data = TestSupport.data
    private val taipei = ZoneId.of("Asia/Taipei")
    private fun at(y: Int, mo: Int, d: Int, h: Int, mi: Int = 0, zone: ZoneId = taipei) =
        ZonedDateTime.of(y, mo, d, h, mi, 0, 0, zone)

    @Test fun categoryFromFileName() {
        assertEquals("自然", WallpaperCategory.category(data, "nature-dawn-daily-2026-11-03.jpg"))
        assertEquals("自然", WallpaperCategory.category(data, "NATURE-DAWN-2.jpg"))
        assertEquals("漸層", WallpaperCategory.category(data, "gradient-soft-abcd2345.jpg"))
        assertEquals("抽象", WallpaperCategory.category(data, "gradient-tide.jpg"))
        assertEquals("自然", WallpaperCategory.category(data, "alpine-dawn-5k.png"))
        assertEquals("極簡", WallpaperCategory.category(data, "paper-landscape-demo-5k.jpg"))
        assertEquals("其他", WallpaperCategory.category(data, "random.jpg"))
        assertEquals("其他", WallpaperCategory.category(data, "nature-dawnx.jpg"))
        assertEquals("其他", WallpaperCategory.order(data).last())
        assertEquals(data.categories, WallpaperCategory.order(data).dropLast(1))
        assertEquals(listOf("all", "favorites"), GalleryFilter.allFilters(data).take(2).map { it.id })
        assertEquals(data.categories.size + 3, GalleryFilter.allFilters(data).size)
    }

    @Test fun loadSortFilterDelete() {
        val paths = AppPaths(TestSupport.tempDir()).apply { prepare() }
        fun put(name: String, modified: Long) = File(paths.wallpapers, name).apply { writeText("x"); setLastModified(modified) }
        put("city-a.jpg", 2_000_000L); put("animals-b.jpg", 3_000_000L); put("nature-dawn-c.jpg", 2_000_000L)
        put("notes.txt", 9_000_000L); put(".hidden.jpg", 9_000_000L); put("dark-oled-d.JPEG", 1_000_000L)
        File(paths.originals, "animals-b.png").writeText("png")
        val items = WallpaperLibrary.load(data, paths, listOf("paper-landscape-demo-5k.jpg"))
        assertEquals(listOf("animals-b.jpg", "city-a.jpg", "nature-dawn-c.jpg", "dark-oled-d.JPEG", "demo:paper-landscape-demo-5k.jpg"),
            items.map { it.id })
        assertTrue(items.last().isDemo)
        assertEquals("paper-landscape-demo-5k.jpg", items.last().fileName)
        assertEquals(listOf("動物", "城市", "自然", "深色", "極簡"), items.map { it.category })
        assertEquals(listOf("city-a.jpg"), WallpaperLibrary.filter(items, GalleryFilter.Category("城市"), emptySet()).map { it.id })
        assertEquals(listOf("nature-dawn-c.jpg"), WallpaperLibrary.filter(items, GalleryFilter.Favorites, setOf("nature-dawn-c.jpg")).map { it.id })
        assertEquals(items, WallpaperLibrary.filter(items, GalleryFilter.All, emptySet()))

        val prefs = Preferences(MemoryStore())
        val cw = CurrentWallpaper(data, paths, prefs)
        val animals = items.first()
        assertTrue(cw.toggleFavorite(animals))
        assertEquals(setOf("animals-b.jpg"), prefs.favorites)
        prefs.dynamicEnabled = true
        assertEquals(true to true, cw.togglePin(animals))
        assertFalse(prefs.dynamicEnabled)
        cw.delete(animals)
        assertFalse(File(paths.wallpapers, "animals-b.jpg").exists())
        assertFalse(File(paths.originals, "animals-b.png").exists())
        assertTrue(prefs.favorites.isEmpty())
        assertNull(prefs.pinnedID)
        cw.delete(items.last()) // 示範圖不能刪
        assertEquals(4, WallpaperLibrary.load(data, paths, listOf("paper-landscape-demo-5k.jpg")).size)
        assertEquals(false to false, cw.togglePin(items[1]).let { cw.togglePin(items[1]) })
        assertFalse(cw.toggleFavorite(items[1]).let { cw.toggleFavorite(items[1]) })
    }

    @Test fun neighborAfterDelete() {
        val ids = listOf("a", "b", "c")
        assertEquals("b", WallpaperLibrary.neighborID("a", ids))
        assertEquals("c", WallpaperLibrary.neighborID("b", ids))
        assertEquals("b", WallpaperLibrary.neighborID("c", ids))
        assertNull(WallpaperLibrary.neighborID("a", listOf("a")))
        assertNull(WallpaperLibrary.neighborID("x", ids))
    }

    @Test fun rotationStepAndSlots() {
        val (s1, i1) = WallpaperSelection.step(RotationState(), 10, 3, force = false)
        assertEquals(RotationState(0, 10), s1); assertEquals(0, i1)
        val (s2, i2) = WallpaperSelection.step(s1, 10, 3, force = false)
        assertEquals(0, i2); assertEquals(s1, s2)
        val (s3, i3) = WallpaperSelection.step(s2, 11, 3, force = false)
        assertEquals(1, i3); assertEquals(RotationState(1, 11), s3)
        val (_, i4) = WallpaperSelection.step(RotationState(0, 11), 11, 3, force = true, delta = -1)
        assertEquals(2, i4)
        assertNull(WallpaperSelection.step(RotationState(), 1, 0, force = false).second)

        assertEquals(0L, WallpaperSelection.hourSlot(at(2001, 1, 1, 0, zone = ZoneId.of("UTC"))))
        assertEquals(24L * 365 + 5, WallpaperSelection.hourSlot(at(2002, 1, 1, 5)))
        val base = at(2026, 11, 4, 10, 0)
        val h = WallpaperSelection.slot(base, RotationFrequency.HOURLY)!!
        assertEquals(h, WallpaperSelection.slot(base.plusMinutes(59), RotationFrequency.HOURLY))
        assertEquals(h + 1, WallpaperSelection.slot(base.plusMinutes(60), RotationFrequency.HOURLY))
        val q = WallpaperSelection.slot(base, RotationFrequency.FIFTEEN_MINUTES)!!
        assertEquals(q + 1, WallpaperSelection.slot(base.plusMinutes(15), RotationFrequency.FIFTEEN_MINUTES))
        assertEquals(q, WallpaperSelection.slot(base.plusMinutes(14), RotationFrequency.FIFTEEN_MINUTES))
        val d = WallpaperSelection.slot(base, RotationFrequency.DAILY)!!
        assertEquals(d, WallpaperSelection.slot(at(2026, 11, 4, 23, 59), RotationFrequency.DAILY))
        assertEquals(d + 1, WallpaperSelection.slot(at(2026, 11, 5, 0, 0), RotationFrequency.DAILY))
        assertNull(WallpaperSelection.slot(base, RotationFrequency.EVERY_RUN))
        // 秋天撥回：紐約 2026-11-01 01:30 出現兩次，落在不同格。
        val ny = ZoneId.of("America/New_York")
        val first = ZonedDateTime.ofLocal(LocalDateTime.of(2026, 11, 1, 1, 30), ny, java.time.ZoneOffset.ofHours(-4))
        val second = first.withLaterOffsetAtOverlap()
        assertTrue(WallpaperSelection.slot(second, RotationFrequency.HOURLY)!! > WallpaperSelection.slot(first, RotationFrequency.HOURLY)!!)
        assertEquals(RotationFrequency.HOURLY, RotationFrequency.of("nope"))
        assertEquals(15, RotationFrequency.of("fifteenMinutes").minutes)
    }

    @Test fun choosePriorityDynamicThenPinnedThenRotation() {
        val ids = listOf("a", "b", "c")
        val t = at(2026, 11, 4, 10)
        val dyn = WallpaperSelection.choose(t, DayPhase.DAY, DayPhase.entries.associateWith { "scene-${it.raw}" }, "b", ids,
            emptySet(), false, RotationState())
        assertEquals(WallpaperSelection.Choice("scene-day", WallpaperSelection.Source.Dynamic(DayPhase.DAY)), dyn.choice)
        assertEquals(RotationState(), dyn.state)
        val pinned = WallpaperSelection.choose(t, null, null, "b", ids, emptySet(), false, RotationState(5, 1))
        assertEquals(WallpaperSelection.Choice("b", WallpaperSelection.Source.Pinned), pinned.choice)
        assertEquals(RotationState(5, 1), pinned.state)
        val missingPin = WallpaperSelection.choose(t, null, null, "zzz", ids, emptySet(), false, RotationState())
        assertEquals("a", missingPin.choice!!.id)
        val favs = WallpaperSelection.choose(t, null, null, null, ids, setOf("c"), true, RotationState())
        assertEquals("c", favs.choice!!.id)
        val noFavs = WallpaperSelection.choose(t, null, null, null, ids, emptySet(), true, RotationState())
        assertEquals("a", noFavs.choice!!.id)
        assertNull(WallpaperSelection.choose(t, null, null, null, emptyList(), emptySet(), false, RotationState()).choice)
        // everyRun：每次呼叫前進一格，第一次停在第一張。
        var s = RotationState()
        val seen = (0 until 4).map {
            WallpaperSelection.choose(t, null, null, null, ids, emptySet(), false, s, frequency = RotationFrequency.EVERY_RUN)
                .also { r -> s = r.state }.choice!!.id
        }
        assertEquals(listOf("a", "b", "c", "a"), seen)
    }

    @Test fun previousFromHistory() {
        assertEquals("b" to listOf("a", "b"), WallpaperSelection.previous(listOf("a", "b", "c"), setOf("a", "b", "c")))
        assertEquals("a" to listOf("a"), WallpaperSelection.previous(listOf("a", "x", "c", "c"), setOf("a", "c")))
        assertNull(WallpaperSelection.previous(listOf("c"), setOf("c")))
        assertNull(WallpaperSelection.previous(emptyList(), emptySet()))
    }

    @Test fun currentWallpaperFlow() {
        val paths = AppPaths(TestSupport.tempDir()).apply { prepare() }
        val items = listOf("a.jpg", "b.jpg", "c.jpg").map { WallpaperItem(it, null, false, 0, WallpaperCategory.OTHER) }
        val prefs = Preferences(MemoryStore())
        val cw = CurrentWallpaper(data, paths, prefs)
        val t = at(2026, 11, 4, 10)
        fun id(r: CurrentWallpaper.Resolved?) = (r as CurrentWallpaper.Resolved.Item).item.id
        assertEquals("a.jpg", id(cw.resolve(t, items)))
        assertEquals("a.jpg", id(cw.resolve(t.plusMinutes(30), items)))
        assertEquals("b.jpg", id(cw.resolve(t.plusHours(1), items)))
        assertEquals("c.jpg", id(cw.advance(t.plusHours(1), items)))
        assertEquals(listOf("a.jpg", "b.jpg", "c.jpg"), prefs.servedHistory)
        assertEquals("b.jpg", id(cw.previous(t.plusHours(1), items)))
        assertEquals(1, prefs.rotation.cursor)
        assertEquals(listOf("a.jpg", "b.jpg"), prefs.servedHistory)
        // 設為桌布＝固定＋關日夜。
        prefs.dynamicEnabled = true
        assertTrue(cw.setAsWallpaper(items[2]))
        assertFalse(prefs.dynamicEnabled)
        assertEquals("c.jpg", id(cw.resolve(t.plusHours(5), items)))
        // 日夜：示範場景直接回時段；自訂場景檔不見時退回一般規則。
        prefs.dynamicEnabled = true
        val dyn = cw.resolve(at(2026, 11, 4, 19), items) as CurrentWallpaper.Resolved.Dynamic
        assertEquals(CurrentWallpaper.Resolved.Dynamic("demo", DayPhase.DUSK), dyn)
        assertEquals("dynamic:dusk", prefs.servedHistory.last())
        prefs.dynamicSceneID = "scene-missing"
        assertEquals("c.jpg", id(cw.resolve(at(2026, 11, 4, 19), items)))
        File(paths.dynamic, "scene-x").mkdirs(); File(paths.dynamic, "scene-x/night.jpg").writeText("j")
        prefs.dynamicSceneID = "scene-x"
        assertEquals(CurrentWallpaper.Resolved.Dynamic("scene-x", DayPhase.NIGHT), cw.resolve(at(2026, 11, 4, 23), items))
        // 歷史最多 30 筆。
        prefs.servedHistory = (1..40).map { "$it" }
        assertEquals(30, prefs.servedHistory.size)
        assertEquals("40", prefs.servedHistory.last())
    }

    @Test fun preferencesRoundTrip() {
        val prefs = Preferences(MemoryStore())
        assertEquals(RotationFrequency.HOURLY, prefs.rotationFrequency)
        assertEquals("demo", prefs.dynamicSceneID)
        assertEquals(DynamicTiming.FIXED, prefs.dynamicTiming)
        assertEquals(DynamicAutoFrequency.OFF, prefs.dynamicAutoFrequency)
        assertNull(prefs.coordinate)
        prefs.rotation = RotationState(4, 99)
        assertEquals(RotationState(4, 99), prefs.rotation)
        prefs.coordinate = Coordinate(25.03, 121.56)
        assertEquals(Coordinate(25.03, 121.56), prefs.coordinate)
        prefs.coordinate = Coordinate(95.0, 0.0)
        assertNull(prefs.coordinate)
        prefs.rotationFrequency = RotationFrequency.FIFTEEN_MINUTES
        assertEquals(RotationFrequency.FIFTEEN_MINUTES, prefs.rotationFrequency)
        prefs.dailyEnabled = true; assertTrue(prefs.dailyEnabled)
        val long = "字".repeat(250)
        prefs.saveRecipe(data, DailyRecipe(listOf("city", "nope", "animals"), long), DailyRecipe.MANUAL_PREFIX)
        val r = prefs.recipe(data, DailyRecipe.MANUAL_PREFIX)
        assertEquals(listOf("city", "animals"), r.styles)
        assertEquals(200, r.idea.length)
        assertEquals(DailyRecipe(), prefs.recipe(data))
        prefs.favorites = setOf("b", "a")
        assertEquals(listOf("a", "b"), prefs.store.getStringList("favorites"))
    }

    @Test fun cropMath() {
        assertEquals(CropMath.Rect(0, 0, 0, 0), CropMath.aspectFillSourceRect(0, 10, 10, 10))
        // 來源較寬：裁左右。
        assertEquals(CropMath.Rect(1213, 0, 1772, 3840), CropMath.aspectFillSourceRect(4199, 3840, 1290, 2796))
        // 來源較高：裁上下。
        assertEquals(CropMath.Rect(0, 255, 1080, 2340), CropMath.aspectFillSourceRect(1080, 2850, 1080, 2340))
        assertEquals(CropMath.Rect(0, 0, 2160, 3840), CropMath.aspectFillSourceRect(2160, 3840, 1080, 1920))
        assertEquals(1080 to 2400, CropMath.portraitPixels(2400, 1080))
        assertEquals("1290 × 2796", CropMath.label(1290, 2796))
    }

    @Test fun titlesAndOverview() {
        val zone = taipei
        val now = at(2026, 11, 4, 12)
        val today = now.toInstant().toEpochMilli()
        val old = at(2026, 10, 1, 12).toInstant().toEpochMilli()
        fun item(id: String, ms: Long, demo: Boolean = false) =
            WallpaperItem(if (demo) "demo:$id" else id, null, demo, ms, WallpaperCategory.category(data, id))
        val items = listOf(item("city-daily-2026-11-03.jpg", today), item("city-2-daily-2026-11-03.jpg", today),
            item("animals-abcd2345.jpg", old), item("random.jpg", today), item("paper-landscape-demo-5k.jpg", Long.MIN_VALUE, true))
        val titles = WallpaperTitles.titles(data, items, zone)
        assertEquals("城市 · 11/3 · 2", titles["city-daily-2026-11-03.jpg"])
        assertEquals("城市 · 11/3 · 1", titles["city-2-daily-2026-11-03.jpg"])
        assertEquals("動物 · 10/1", titles["animals-abcd2345.jpg"])
        assertEquals("random", titles["random.jpg"])
        assertEquals("紙上山丘", titles["demo:paper-landscape-demo-5k.jpg"])
        val en = WallpaperTitles.titles(data, items.take(1), zone, { if (it == "城市") "City" else it }) { d -> "Nov ${d.dayOfMonth}" }
        assertEquals("City · Nov 3", en.values.single())

        assertEquals(3, OverviewFacts.todayNew(items, now))
        val segs = OverviewFacts.segments(data, items, now)
        assertEquals(listOf("極簡", "城市", "動物", "其他"), segs.map { it.category })
        assertEquals(OverviewFacts.CategorySegment("城市", 2, 0), segs[1])
        assertEquals(OverviewFacts.CategorySegment("動物", 0, 1), segs[2])
        assertEquals(OverviewFacts.CategorySegment("極簡", 0, 1), segs[0])
        val fixed = DynamicSchedule(DynamicTiming.FIXED, Coordinate(25.03, 121.56))
        assertEquals(DayPhase.DUSK to "18:00", OverviewFacts.nextPhase(fixed, now))
        assertEquals(DayPhase.NIGHT to "", OverviewFacts.nextPhase(fixed.copy(timing = DynamicTiming.APPEARANCE), now))
        assertEquals(LocalDate.of(2026, 11, 4).toString(), AppPaths.dayString(now))
    }

    @Test fun randomID() {
        val r = RandomID.make(kotlin.random.Random(1))
        assertTrue(r, Regex("[a-km-np-z2-9]{8}").matches(r))
        assertEquals(r, RandomID.make(kotlin.random.Random(1)))
    }
}
