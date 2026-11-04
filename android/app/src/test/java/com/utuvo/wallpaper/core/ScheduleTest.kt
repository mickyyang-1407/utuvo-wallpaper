package com.utuvo.wallpaper.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.ZonedDateTime

/** 日夜四段、日出日落時間表、AI 自動排程狀態、本機畫圖、提示詞資料小工具。 */
class ScheduleTest {
    private val data = TestSupport.data
    private val taipei = ZoneId.of("Asia/Taipei")
    private fun at(h: Int, m: Int = 0, d: LocalDate = LocalDate.of(2026, 11, 4), zone: ZoneId = taipei) =
        ZonedDateTime.of(d, java.time.LocalTime.of(h, m), zone)

    @Test fun dayPhaseFixedHours() {
        val expected = (0..23).map {
            when (it) { in 6..8 -> DayPhase.DAWN; in 9..17 -> DayPhase.DAY; in 18..20 -> DayPhase.DUSK; else -> DayPhase.NIGHT }
        }
        assertEquals(expected, (0..23).map { DayPhase.current(it) })
        val fixed = DynamicSchedule(DynamicTiming.FIXED, Coordinate(0.0, 0.0))
        assertEquals(expected, (0..23).map { fixed.phase(at(it)) })
        assertEquals(DayPhase.NIGHT, fixed.phase(at(5, 59)))
        assertEquals(DayPhase.DAWN, fixed.phase(at(6, 0)))
        assertEquals(listOf("06:00", "09:00", "18:00", "21:00"), DayPhase.entries.map { fixed.startTime(it, at(0).toLocalDate(), taipei) })
        assertEquals(DayPhase.of("dusk"), DayPhase.DUSK); assertNull(DayPhase.of("x"))
    }

    @Test fun nextPhaseForAlarms() {
        val fixed = DynamicSchedule(DynamicTiming.FIXED, Coordinate(0.0, 0.0))
        assertEquals(DynamicSchedule.Next(DayPhase.DAY, at(9)), fixed.next(at(6)))
        assertEquals(DynamicSchedule.Next(DayPhase.DUSK, at(18)), fixed.next(at(9)))
        val tomorrow = LocalDate.of(2026, 11, 5)
        assertEquals(DynamicSchedule.Next(DayPhase.DAWN, at(6, d = tomorrow)), fixed.next(at(22)))
        assertNull(fixed.copy(timing = DynamicTiming.APPEARANCE).next(at(10)))
        assertEquals(5, fixed.segments(at(0).toLocalDate(), taipei).size)
        assertTrue(fixed.copy(timing = DynamicTiming.APPEARANCE).segments(at(0).toLocalDate(), taipei).isEmpty())
        assertEquals("23:30", DynamicSchedule.clock(-30))
        assertEquals("00:10", DynamicSchedule.clock(1450))
    }

    @Test fun solarStartsUseSixtyMinuteOffset() {
        val coord = Coordinate(25.03, 121.56)
        val date = LocalDate.of(2026, 1, 1)
        val sun = SolarCalculator.sunriseSunset(date, taipei, coord)!!
        assertEquals(SolarCalculator.SunTimes(398, 1035), sun) // 與 golden 第一筆相同
        val s = DynamicSchedule(DynamicTiming.SOLAR, coord).starts(date, taipei)
        assertEquals(mapOf(DayPhase.DAWN to 368, DayPhase.DAY to 458, DayPhase.DUSK to 975, DayPhase.NIGHT to 1065), s)
        // 極夜退回固定時間。
        val polar = DynamicSchedule(DynamicTiming.SOLAR, Coordinate(69.65, 18.96))
        assertEquals(DynamicSchedule.FIXED_STARTS, polar.starts(LocalDate.of(2026, 12, 21), ZoneId.of("Europe/Oslo")))
        // appearance 只看深淺色。
        val ap = DynamicSchedule(DynamicTiming.APPEARANCE, coord)
        assertEquals(DayPhase.NIGHT, ap.phase(at(12), isDark = true))
        assertEquals(DayPhase.DAY, ap.phase(at(23), isDark = false))
        assertNull(ap.startTime(DayPhase.DAY, date, taipei))
    }

    @Test fun coordinateEstimate() {
        assertEquals(Coordinate(25.03, 121.56), Coordinate.estimate(data, taipei))
        assertEquals(Coordinate(30.0, 135.0), Coordinate.estimate(data, ZoneId.of("Asia/Chita"), Instant.parse("2026-01-01T00:00:00Z")))
        assertEquals(Coordinate(30.0, -150.0), Coordinate.estimate(data, ZoneId.of("Etc/GMT+10")))
        assertEquals(Coordinate(30.0, 180.0), Coordinate.estimate(data, ZoneId.of("Pacific/Kiritimati")))
    }

    @Test fun autoPlannerDueAndManual() {
        val now = at(10)
        val due = DynamicAutoPlanner.due(data, null, now, DynamicAutoFrequency.DAILY, chinese = true)!!
        assertEquals("2026-11-04", due.period)
        val pick = DynamicAutoPlanner.pick(data, "2026-11-04", 0, Season.AUTUMN, emptyList(), true)
        assertEquals(pick.subject, due.subject); assertEquals(pick.prompt, due.prompt)
        assertEquals(DynamicAutoPlanner.sceneID("2026-11-04", 0, pick.subject), due.sceneID)
        assertNull(DynamicAutoPlanner.due(data, null, now, DynamicAutoFrequency.OFF, chinese = true))
        // 同一期：失敗 → 30 分鐘後才再到期；成功 → 這期不再到期。
        val failed = due.copy(attempts = 1).recordFailure(true, now.toInstant().toEpochMilli())
        assertNull(DynamicAutoPlanner.due(data, failed, now.plusMinutes(29), DynamicAutoFrequency.DAILY, chinese = true))
        assertEquals(failed, DynamicAutoPlanner.due(data, failed, now.plusMinutes(30), DynamicAutoFrequency.DAILY, chinese = true))
        val stopped = due.recordFailure(false, 0)
        assertEquals(DynamicAutoState.MAX_ATTEMPTS, stopped.attempts)
        assertNull(DynamicAutoPlanner.due(data, stopped, now.plusHours(3), DynamicAutoFrequency.DAILY, chinese = true))
        val done = due.recordSuccess()
        assertTrue(done.completed); assertEquals(listOf(due.subject), done.recentSubjects)
        assertNull(DynamicAutoPlanner.due(data, done, now, DynamicAutoFrequency.DAILY, chinese = true))
        // 隔天：新的一期，避開上一期的主題。
        val next = DynamicAutoPlanner.due(data, done, now.plusDays(1), DynamicAutoFrequency.DAILY, chinese = true)!!
        assertEquals("2026-11-05", next.period)
        assertNotEquals(due.subject, next.subject)
        assertEquals(listOf(due.subject), next.recentSubjects)
        // 上一期沒做完的主題也算用過。
        val unfinished = DynamicAutoPlanner.due(data, due, now.plusDays(1), DynamicAutoFrequency.DAILY, chinese = true)!!
        assertEquals(listOf(due.subject), unfinished.recentSubjects)
        // 手動：沒做完續作（attempts 封頂 2、清掉等待）；已完成就換 salt 重挑。
        val resumed = DynamicAutoPlanner.manual(data, failed.copy(attempts = 3), now, DynamicAutoFrequency.DAILY, chinese = true)
        assertEquals(2, resumed.attempts); assertNull(resumed.retryAfterEpochMs); assertEquals(due.sceneID, resumed.sceneID)
        val again = DynamicAutoPlanner.manual(data, done, now, DynamicAutoFrequency.OFF, chinese = false)
        assertEquals("2026-11-04", again.period)
        assertEquals(DynamicAutoPlanner.sceneID("2026-11-04", now.toEpochSecond(), again.subject), again.sceneID)
        assertFalse(again.completed)
        val weekly = DynamicAutoPlanner.manual(data, null, now, DynamicAutoFrequency.WEEKLY, chinese = true)
        assertEquals("2026-W45", weekly.period)
        // 最近主題最多 6 個。
        var st = due
        repeat(8) { st = st.copy(subject = "s$it").recordSuccess() }
        assertEquals((2..7).map { "s$it" }, st.recentSubjects)
    }

    @Test fun winterOnlySubjectsOnlyInWinter() {
        val winterOnly = data.autoSubjects.filter { it.winterOnly }.map { it.id }.toSet()
        assertTrue("資料裡要有冬季限定主題", winterOnly.isNotEmpty())
        for (i in 0 until 200) {
            val p = DynamicAutoPlanner.pick(data, "p$i", 0, Season.SUMMER, emptyList(), false)
            assertFalse(p.subject in winterOnly)
        }
    }

    @Test fun localArtRendering() {
        assertTrue(LocalArt.isLocal("local:solid:#112233"))
        assertFalse(LocalArt.isLocal("a cat"))
        assertEquals(0xFF112233.toInt(), LocalArt.color(" #112233 "))
        assertNull(LocalArt.color("#12345"))
        assertNull(LocalArt.color("#GG0000"))
        val solid = LocalArt.render("local:solid:#1C2B4A", 90, 160)!!
        assertEquals(90 * 160, solid.pixels.size)
        // 顆粒很淡：每個像素都接近原色。
        for (p in solid.pixels) {
            assertEquals(0xFF, p ushr 24)
            assertTrue(kotlin.math.abs(((p shr 16) and 0xFF) - 0x1C) <= 3)
            assertTrue(kotlin.math.abs((p and 0xFF) - 0x4A) <= 3)
        }
        // 同一張每次畫都一樣。
        assertTrue(solid.pixels.contentEquals(LocalArt.render("local:solid:#1C2B4A", 90, 160)!!.pixels))
        // 漸層 90°（Core Graphics 往上）：底部是第一色、頂部是最後一色。
        val g = LocalArt.render("local:gradient:#FF0000,#0000FF|90", 100, 200)!!
        fun red(p: Int) = (p shr 16) and 0xFF
        fun blue(p: Int) = p and 0xFF
        assertTrue(red(g.pixel(5, 199)) > 200 && blue(g.pixel(5, 199)) < 60)
        assertTrue(blue(g.pixel(5, 0)) > 200 && red(g.pixel(5, 0)) < 60)
        // 預設角度 135°、三色也能畫。
        val first = data.templates.first { it.local == "gradient" }.palettes.first()
        assertTrue(LocalArt.render("local:gradient:$first", 60, 120) != null)
        assertTrue(LocalArt.render("local:gradient:#000000,#FFFFFF,#FF0000", 30, 60) != null)
        for (bad in listOf("local:gradient:#000000", "local:solid:nope", "local:wave:#000000", "local:solid", "cat")) {
            assertNull(bad, LocalArt.render(bad, 10, 10))
        }
        assertNull(LocalArt.render("local:solid:#000000", 0, 10))
        // 每個內建純色、漸層規格都畫得出來。
        for (t in data.templates.filter { it.local != null }) for (p in t.palettes) {
            assertTrue("${t.id} $p", LocalArt.render(LocalArt.PREFIX + t.local + ":" + p, 12, 24) != null)
        }
    }

    @Test fun promptDataAndText() {
        assertEquals(17, data.templates.size)
        assertEquals(data.templates.map { it.category }.distinct(), data.categories)
        assertEquals("nature-dawn", data.template("nature-dawn")!!.id)
        assertNull(data.template("nope"))
        assertEquals("abc", SwiftText.trim("　\n abc\t\u0085"))
        assertEquals("\u001Cabc", SwiftText.trim("\u001Cabc ")) // Swift 不把 U+001C 當空白
        assertEquals("ab", SwiftText.prefix("abc", 2))
        assertEquals("👨‍👩‍👧x", SwiftText.prefix("👨‍👩‍👧xyz", 2))
        val idea = DailyRecipe(idea = "  " + "貓".repeat(300) + "  ")
        assertEquals(200, idea.trimmedIdea.length)
        val all = DailyRecipe()
        assertEquals(data.templates, all.templates(data))
        assertFalse(all.isLocalOnly(data))
        assertTrue(all.categories(data).isEmpty())
        val city = all.withCategory(data, "城市", true)
        assertEquals(listOf("城市"), city.categories(data))
        assertEquals(DailyRecipe(), city.withCategory(data, "城市", false))
        assertTrue(DailyPlan.make(data, "2026-11-04", 0, all).isEmpty())
        assertEquals(DailyPlan.dayIndex("2026-01-31") + 1, DailyPlan.dayIndex("2026-01-32")) // Foundation 會順延
        assertEquals(DailyPlan.dayIndex("1999-12-31"), (StableHash.of("1999-12-31") % 100_000uL).toInt())
        val t = data.template("nature-dawn")!!
        assertEquals("${t.style}. Subject: ${t.subjects[0]}. Palette: ${t.palettes[0]}. wide 16:9 desktop wallpaper, no text, no watermark, no logos.", t.prompt)
        assertEquals("${PortraitPrompt.CLOCK_SENTENCE}.", PortraitPrompt.convert("WIDE  16:9 Desktop Wallpaper."))
        assertEquals("x, ${PortraitPrompt.CLOCK_SENTENCE}, y.", PortraitPrompt.convert("x, vertical 9:16 iPhone wallpaper, y."))
        assertEquals(12, data.lights.size); assertEquals(12, data.compositions.size)
        assertEquals(setOf("animals", "architecture-arcade", "city", "nature-dawn"), data.mixedStyleTemplates)
        val pool = DailyPlan.subjectPool(data, data.template("city")!!)
        assertEquals(data.template("city")!!.subjects, pool.take(data.template("city")!!.subjects.size))
        assertEquals(pool.distinct(), pool)
        assertEquals(data.template("solid-color")!!.subjects, DailyPlan.subjectPool(data, data.template("solid-color")!!))
        assertEquals("a 9:16 b, ${PortraitPrompt.CLOCK_SENTENCE}.", PortraitPrompt.convert("a 16 : 9 b"))
        assertEquals(ScenePrompt.base("x", ScenePrompt.Canvas.DESKTOP).contains("wide 16:9 desktop wallpaper"), true)
        assertFalse(ScenePrompt.base("x", ScenePrompt.Canvas.DESKTOP).contains("clock area"))
        assertTrue(ScenePrompt.relight("dusk", ScenePrompt.Canvas.DESKTOP).endsWith("Output the same wide 16:9 image, fully aligned to the reference."))
    }
}
