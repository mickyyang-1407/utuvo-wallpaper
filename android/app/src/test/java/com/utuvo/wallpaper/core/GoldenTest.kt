package com.utuvo.wallpaper.core

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

/**
 * 與 Swift 匯出的標準答案（golden.json）逐筆、逐欄位比對。不抽樣、不放寬。
 * 每一組的欄位集合也要完全符合，Swift 匯出多了欄位這裡會失敗（提醒補測）。
 */
class GoldenTest {
    companion object {
        val data: PromptData by lazy { PromptData.parse(File("src/main/assets/prompts.json").readText()) }
        val golden: JSONObject by lazy {
            JSONObject(GoldenTest::class.java.getResource("/golden.json")!!.readText())
        }

        fun strings(a: JSONArray) = List(a.length()) { a.getString(it) }
        fun objects(a: JSONArray) = List(a.length()) { a.getJSONObject(it) }
        fun keys(o: JSONObject) = o.keys().asSequence().toSet()
    }

    @Test fun topLevelKeysAllCovered() {
        assertEquals(setOf("plans", "hashes", "dayIndexes", "inspirations", "autoPicks", "periods", "solar", "scene", "sceneInput"),
            keys(golden))
    }

    @Test fun plans() {
        val rows = objects(golden.getJSONArray("plans"))
        assertEquals(207, rows.size)
        var items = 0
        for (row in rows) {
            assertEquals(setOf("day", "recipe", "styles", "idea", "salt", "plan"), keys(row))
            val name = row.getString("recipe")
            val recipe = recipeNamed(name)
            val ctx = "${row.getString("day")} $name salt=${row.getString("salt")}"
            assertEquals(ctx, strings(row.getJSONArray("styles")), recipe.styles)
            assertEquals(ctx, row.getString("idea"), recipe.idea)
            val plan = DailyPlan.make(data, row.getString("day"), 10, recipe, row.getString("salt"))
            val expected = objects(row.getJSONArray("plan"))
            assertEquals(ctx, expected.size, plan.size)
            expected.forEachIndexed { i, e ->
                assertEquals(setOf("templateID", "slug", "prompt", "portrait"), keys(e))
                assertEquals("$ctx #$i templateID", e.getString("templateID"), plan[i].templateID)
                assertEquals("$ctx #$i slug", e.getString("slug"), plan[i].slug)
                assertEquals("$ctx #$i prompt", e.getString("prompt"), plan[i].prompt)
                assertEquals("$ctx #$i portrait", e.getString("portrait"), PortraitPrompt.convert(plan[i].prompt))
                items++
            }
        }
        assertEquals(2070, items)
    }

    /** 與 main.swift 相同的方式組出各組設定。 */
    private fun recipeNamed(name: String): DailyRecipe {
        val mixed = DailyRecipe().withCategory(data, "自然", true).withCategory(data, "純色", true).withCategory(data, "城市", true)
        return when {
            name == "all" -> DailyRecipe()
            name.startsWith("cat-") -> DailyRecipe().withCategory(data, name.removePrefix("cat-"), true)
            name == "mixed" -> mixed
            name == "idea" -> mixed.copy(idea = "  一隻在窗邊打盹的橘貓  ")
            name == "idea-all" -> DailyRecipe(idea = "a lighthouse in the rain")
            else -> error("unknown recipe $name")
        }
    }

    @Test fun hashes() {
        val rows = objects(golden.getJSONArray("hashes"))
        assertEquals(6 + data.templates.size, rows.size)
        for (row in rows) {
            assertEquals(setOf("text", "hash"), keys(row))
            assertEquals(row.getString("text"), row.getString("hash"), StableHash.of(row.getString("text")).toString())
        }
    }

    @Test fun dayIndexes() {
        val rows = objects(golden.getJSONArray("dayIndexes"))
        assertEquals(9, rows.size)
        for (row in rows) {
            assertEquals(setOf("day", "index"), keys(row))
            assertEquals(row.getString("day"), row.getInt("index"), DailyPlan.dayIndex(row.getString("day")))
        }
    }

    @Test fun inspirations() {
        val rows = objects(golden.getJSONArray("inspirations"))
        assertEquals(60, rows.size)
        for (row in rows) {
            assertEquals(setOf("categories", "chinese", "current", "rolls", "result"), keys(row))
            val rolls = row.getJSONArray("rolls").let { a -> List(a.length()) { a.getInt(it) } }
            var used = 0
            val text = PromptInspiration.pick(data, strings(row.getJSONArray("categories")), row.getString("current"),
                row.getBoolean("chinese")) { rolls[used++] }
            assertEquals(row.toString(), row.getString("result"), text)
            assertEquals("rolls consumed", rolls.size, used)
        }
    }

    @Test fun autoPicks() {
        val rows = objects(golden.getJSONArray("autoPicks"))
        assertEquals(288, rows.size)
        for (row in rows) {
            assertEquals(setOf("period", "season", "recent", "salt", "chinese", "subject", "prompt", "sceneID"), keys(row))
            val season = Season.entries.first { it.raw == row.getString("season") }
            val period = row.getString("period")
            val salt = row.getLong("salt")
            val r = DynamicAutoPlanner.pick(data, period, salt, season, strings(row.getJSONArray("recent")), row.getBoolean("chinese"))
            assertEquals(row.toString(), row.getString("subject"), r.subject)
            assertEquals(row.toString(), row.getString("prompt"), r.prompt)
            assertEquals(row.toString(), row.getString("sceneID"), DynamicAutoPlanner.sceneID(period, salt, r.subject))
        }
    }

    @Test fun periods() {
        val rows = objects(golden.getJSONArray("periods"))
        assertEquals(8, rows.size)
        for (row in rows) {
            assertEquals(setOf("epoch", "zone", "daily", "weekly", "season", "seasonSouth"), keys(row))
            val t = Instant.ofEpochSecond(row.getLong("epoch")).atZone(ZoneId.of(row.getString("zone")))
            assertEquals(row.toString(), row.getString("daily"), DynamicAutoPlanner.period(t, DynamicAutoFrequency.DAILY))
            assertEquals(row.toString(), row.getString("weekly"), DynamicAutoPlanner.period(t, DynamicAutoFrequency.WEEKLY))
            assertEquals(row.toString(), row.getString("season"), DynamicAutoPlanner.season(t).raw)
            assertEquals(row.toString(), row.getString("seasonSouth"), DynamicAutoPlanner.season(t, southern = true).raw)
        }
        assertNull(DynamicAutoPlanner.period(Instant.EPOCH.atZone(ZoneId.of("UTC")), DynamicAutoFrequency.OFF))
    }

    @Test fun solar() {
        val rows = objects(golden.getJSONArray("solar"))
        assertEquals(48, rows.size)
        var polar = 0
        for (row in rows) {
            val k = keys(row)
            assertTrue(k == setOf("zone", "lat", "lon", "date") || k == setOf("zone", "lat", "lon", "date", "sunrise", "sunset"))
            val r = SolarCalculator.sunriseSunset(LocalDate.parse(row.getString("date")), ZoneId.of(row.getString("zone")),
                Coordinate(row.getDouble("lat"), row.getDouble("lon")))
            if (!row.has("sunrise")) {
                assertNull(row.toString(), r); polar++
            } else {
                assertEquals(row.toString(), row.getInt("sunrise"), r!!.sunrise)
                assertEquals(row.toString(), row.getInt("sunset"), r.sunset)
            }
        }
        assertTrue("至少要有一組極晝極夜", polar > 0)
    }

    @Test fun scene() {
        val scene = golden.getJSONObject("scene")
        assertEquals(setOf("base", "dawn", "day", "dusk", "night"), keys(scene))
        val input = golden.getString("sceneInput")
        assertEquals(scene.getString("base"), DayPhase.basePrompt(input))
        for (p in DayPhase.entries) assertEquals(p.raw, scene.getString(p.raw), p.relightPrompt)
        for (p in ScenePrompt.phases) assertEquals(scene.getString(p), ScenePrompt.relight(p, ScenePrompt.Canvas.PHONE))
    }
}
