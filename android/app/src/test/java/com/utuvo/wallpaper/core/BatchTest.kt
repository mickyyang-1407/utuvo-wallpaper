package com.utuvo.wallpaper.core

import com.utuvo.wallpaper.core.TestSupport.FakeCodec
import com.utuvo.wallpaper.core.TestSupport.ScriptedProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File

/** 每日批次（一天一批 10 張、先記次數、冷卻 60／300、最多 3 次）、手動產生、日夜場景、成功率紀錄。 */
class BatchTest {
    private val data = TestSupport.data
    private val day = "2026-11-04"
    private val aiOnly = DailyRecipe().withCategory(data, "自然", true)
    private val localOnly = DailyRecipe().withCategory(data, "純色", true).withCategory(data, "漸層", true)
    private var now = 1_000_000_000_000L

    private fun service(provider: ImageProvider, paths: AppPaths, recipe: DailyRecipe, codec: ImageCodec = FakeCodec()) =
        DailyGenerationService(data, provider, paths, codec, 108, 234, recipe, { now })

    @Test fun fullDailyBatchOfTen() {
        val paths = AppPaths(TestSupport.tempDir())
        val provider = ScriptedProvider()
        val progress = mutableListOf<Pair<Int, Int>>()
        val results = service(provider, paths, DailyRecipe()).run(day) { d, t -> progress += d to t }
        assertEquals(10, DailyGenerationService.BATCH_SIZE)
        assertEquals(10, results.size)
        assertEquals((0..10).map { it to 10 }, progress)
        val plan = DailyPlan.make(data, day, 10, DailyRecipe())
        // AI 那幾張送的是直式提示詞；本機畫的不送。
        assertEquals(plan.filter { !LocalArt.isLocal(it.prompt) }.map { PortraitPrompt.convert(it.prompt) }, provider.prompts)
        results.forEachIndexed { i, r ->
            assertEquals("${plan[i].slug}-daily-$day.jpg", r.wallpaperURL)
            assertEquals("${plan[i].slug}-daily-$day.png", r.nativeURL)
            assertEquals("108 × 234", r.wallpaperPixelSize)
            assertEquals("resampled", r.origin)
            assertEquals(data.template(plan[i].templateID)!!.title, r.title)
            assertTrue(File(paths.wallpapers, r.wallpaperURL).isFile)
            assertTrue(File(paths.originals, r.nativeURL).isFile)
        }
        val batch = DailyBatch.load(paths.root, day)
        assertEquals(10, batch.completed.size)
        assertNull(batch.retryAfterMs)
        assertEquals(plan, batch.plan)
        assertFalse(DailyGenerationService.hasWork(paths, day, now))
        assertEquals(10 to 10, DailyGenerationService.status(paths, day))
        // 同一天再跑：不再送請求。
        val again = ScriptedProvider()
        assertEquals(results, service(again, paths, DailyRecipe()).run(day))
        assertTrue(again.prompts.isEmpty())
    }

    @Test fun attemptsAreRecordedBeforeSendingAndCooldownsApply() {
        val paths = AppPaths(TestSupport.tempDir())
        var sawAttemptBeforeSend = false
        val provider = object : ImageProvider {
            var calls = 0
            override fun generateImage(prompt: String): ByteArray {
                calls++
                // 送出當下進度檔已經記了這次。
                sawAttemptBeforeSend = DailyBatch.load(paths.root, day).attempts[0] == calls
                throw GenerationError.HttpStatus(503)
            }
            override fun relight(reference: ByteArray, prompt: String) = error("no")
        }
        val svc = service(provider, paths, aiOnly)
        try { svc.run(day); fail() } catch (e: GenerationError.HttpStatus) { assertEquals(503, e.code) }
        assertTrue(sawAttemptBeforeSend)
        var b = DailyBatch.load(paths.root, day)
        assertEquals(listOf(1) + List(9) { 0 }, b.attempts)
        assertEquals(now + 60_000, b.retryAfterMs)
        // 冷卻中：不送請求。
        try { svc.run(day); fail() } catch (e: GenerationError) { assertEquals(GenerationError.Cooldown, e) }
        assertEquals(1, provider.calls)
        assertFalse(DailyGenerationService.hasWork(paths, day, now))
        now += 60_000
        assertTrue(DailyGenerationService.hasWork(paths, day, now))
        try { svc.run(day); fail() } catch (e: GenerationError.HttpStatus) { }
        b = DailyBatch.load(paths.root, day)
        assertEquals(2, b.attempts[0])
        assertEquals(now + 300_000, b.retryAfterMs)
        now += 300_000
        try { svc.run(day); fail() } catch (e: GenerationError.HttpStatus) { }
        b = DailyBatch.load(paths.root, day)
        assertEquals(3, b.attempts[0])
        assertNull("第 3 次失敗後不再自動試", b.retryAfterMs)
        now += 3_600_000
        try { svc.run(day); fail() } catch (e: GenerationError) { assertEquals(GenerationError.Cooldown, e) }
        assertEquals(3, provider.calls)
    }

    @Test fun nonRetryableErrorStopsTheDay() {
        val paths = AppPaths(TestSupport.tempDir())
        val svc = service(ScriptedProvider(GenerationError.HttpStatus(401)), paths, aiOnly)
        try { svc.run(day); fail() } catch (e: GenerationError.HttpStatus) { }
        assertNull(DailyBatch.load(paths.root, day).retryAfterMs)
        assertFalse(DailyGenerationService.hasWork(paths, day, now + 86_400_000))
    }

    @Test fun cancellationIsResumable() {
        val paths = AppPaths(TestSupport.tempDir())
        val svc = service(ScriptedProvider(GenerationError.Cancelled), paths, aiOnly)
        try { svc.run(day); fail() } catch (e: GenerationError) { assertEquals(GenerationError.Cancelled, e) }
        assertEquals(now + 60_000, DailyBatch.load(paths.root, day).retryAfterMs)
    }

    @Test fun resumeAfterFailureKeepsCompletedAndPlan() {
        val paths = AppPaths(TestSupport.tempDir())
        val provider = ScriptedProvider(TestSupport.png(1, 2), TestSupport.png(1, 2), GenerationError.Timeout)
        try { service(provider, paths, aiOnly).run(day); fail() } catch (e: GenerationError) { assertEquals(GenerationError.Timeout, e) }
        val b = DailyBatch.load(paths.root, day)
        assertEquals(2, b.completed.size)
        assertEquals(listOf(1, 1, 1) + List(7) { 0 }, b.attempts)
        now += 60_000
        // 換了設定也照原計畫續作（同一天結果固定）。
        val rest = ScriptedProvider()
        val all = service(rest, paths, DailyRecipe()).run(day)
        assertEquals(10, all.size)
        assertEquals(DailyPlan.make(data, day, 10, aiOnly).drop(2).map { PortraitPrompt.convert(it.prompt) }, rest.prompts)
    }

    @Test fun localOnlyNeedsNoProvider() {
        val paths = AppPaths(TestSupport.tempDir())
        val codec = FakeCodec()
        val provider = ScriptedProvider(GenerationError.MissingCredential)
        assertTrue(localOnly.isLocalOnly(data))
        val results = service(provider, paths, localOnly, codec).run(day)
        assertEquals(10, results.size)
        assertTrue(provider.prompts.isEmpty())
        assertEquals(10, codec.pngs)
        assertTrue(results.all { it.nativePixelSize == "108 × 234" })
    }

    @Test fun undecodableImageFails() {
        val paths = AppPaths(TestSupport.tempDir())
        try { service(ScriptedProvider("garbage".toByteArray()), paths, aiOnly).run(day); fail() } catch (e: GenerationError) {
            assertEquals(GenerationError.Decoding, e)
        }
    }

    @Test fun mismatchedProgressFileIsRejected() {
        val paths = AppPaths(TestSupport.tempDir())
        DailyBatch(5, emptyList(), List(5) { 0 }, now, null).save(paths.root, day)
        try { service(ScriptedProvider(), paths, aiOnly).run(day); fail() } catch (e: GenerationError) {
            assertEquals(GenerationError.InvalidResponse, e)
        }
        File(paths.root, "daily-bad.json").writeText("{")
        try { DailyBatch.load(paths.root, "bad"); fail() } catch (e: GenerationError) { assertEquals(GenerationError.InvalidResponse, e) }
    }

    @Test fun legacyProgressFileWithoutPlan() {
        val paths = AppPaths(TestSupport.tempDir())
        DailyBatch(3, emptyList(), List(3) { 0 }, now, null).save(paths.root, day)
        val provider = ScriptedProvider()
        val results = service(provider, paths, aiOnly).run(day, 3)
        val legacy = DailyPlan.legacy(data, day, 3)
        assertEquals(legacy.map { "${it.slug}-daily-$day.jpg" }, results.map { it.wallpaperURL })
        assertEquals(data.templates.take(3).map { it.id }, legacy.map { it.slug })
    }

    @Test fun manualDoesNotTouchDailyBatch() {
        val paths = AppPaths(TestSupport.tempDir())
        val provider = ScriptedProvider()
        val results = service(provider, paths, aiOnly).runManual(day, 4, salt = "abc")
        assertEquals(4, results.size)
        assertFalse(DailyBatch.file(paths.root, day).exists())
        assertTrue(DailyGenerationService.hasWork(paths, day, now))
        val plan = DailyPlan.make(data, day, 4, aiOnly, "abc")
        assertEquals(plan.map { PortraitPrompt.convert(it.prompt) }, provider.prompts)
        results.forEachIndexed { i, r ->
            assertTrue(r.wallpaperURL, Regex("""${Regex.escape(plan[i].slug)}-[a-z2-9]{8}\.jpg""").matches(r.wallpaperURL))
        }
        try { service(provider, paths, aiOnly).runManual(day, 0); fail() } catch (e: GenerationError) { assertEquals(GenerationError.EmptyPrompt, e) }
    }

    @Test fun manualKeepsFinishedOnesWhenFailing() {
        val paths = AppPaths(TestSupport.tempDir())
        val provider = ScriptedProvider(TestSupport.png(4, 8), GenerationError.HttpStatus(500))
        try { service(provider, paths, aiOnly).runManual(day, 3); fail() } catch (e: GenerationError.HttpStatus) { }
        assertEquals(1, paths.wallpapers.listFiles()!!.size)
    }

    @Test fun cancelBetweenImages() {
        val paths = AppPaths(TestSupport.tempDir())
        var cancel = false
        val provider = object : ImageProvider {
            override fun generateImage(prompt: String): ByteArray { cancel = true; return TestSupport.png(4, 8) }
            override fun relight(reference: ByteArray, prompt: String) = error("no")
        }
        val svc = DailyGenerationService(data, provider, paths, FakeCodec(), 108, 234, aiOnly, { now }, { cancel })
        try { svc.run(day); fail() } catch (e: GenerationError) { assertEquals(GenerationError.Cancelled, e) }
        assertEquals(1, DailyBatch.load(paths.root, day).completed.size)
    }

    @Test fun sceneGenerationPublishesAfterAllFour() {
        val paths = AppPaths(TestSupport.tempDir())
        val provider = ScriptedProvider()
        val progress = mutableListOf<Int>()
        val svc = SceneGenerationService(provider, paths, FakeCodec(), 108, 234)
        assertNull(SceneGenerationService.published(paths))
        val record = svc.generate("  雨天的咖啡廳  ", "scene-test") { progress += it }
        assertEquals(SceneRecord("scene-test", "雨天的咖啡廳", true), record)
        assertEquals(listOf(DayPhase.basePrompt("雨天的咖啡廳")), provider.prompts)
        assertEquals(listOf("dawn", "dusk", "night").map { ScenePrompt.relight(it) }, provider.relights)
        assertEquals(listOf(1, 2, 3, 4), progress)
        for (p in DayPhase.entries) assertTrue(p.raw, WallpaperLibrary.scenePhaseFile(paths, "scene-test", p) != null)
        assertEquals(record, SceneGenerationService.published(paths))
        // 同 id 換提示詞要拒絕。
        try { svc.generate("別的", "scene-test"); fail() } catch (e: GenerationError) { assertEquals(GenerationError.InvalidResponse, e) }
    }

    @Test fun sceneResumesWithoutRepaying() {
        val paths = AppPaths(TestSupport.tempDir())
        val failing = ScriptedProvider(TestSupport.png(4, 8), TestSupport.png(4, 8), GenerationError.Timeout)
        val svc = SceneGenerationService(failing, paths, FakeCodec(), 108, 234)
        try { svc.generate("lake", "s1"); fail() } catch (e: GenerationError) { assertEquals(GenerationError.Timeout, e) }
        assertNull(SceneGenerationService.published(paths))
        val rest = ScriptedProvider()
        SceneGenerationService(rest, paths, FakeCodec(), 108, 234).generate("lake", "s1")
        assertTrue(rest.prompts.isEmpty())
        assertEquals(listOf(ScenePrompt.relight("dusk"), ScenePrompt.relight("night")), rest.relights)
        assertTrue(SceneGenerationService.published(paths)!!.completed)
        try { svc.generate("   "); fail() } catch (e: GenerationError) { assertEquals(GenerationError.EmptyPrompt, e) }
    }

    @Test fun generationLogAndSummary() {
        val paths = AppPaths(TestSupport.tempDir())
        paths.prepare()
        var t = now
        val logged = LoggingImageProvider(
            ScriptedProvider(TestSupport.png(1, 1), GenerationError.HttpStatus(429), GenerationError.Timeout, GenerationError.HttpStatus(429)),
            paths, { t.also { t += 2_000 } })
        logged.generateImage("a")
        repeat(3) { runCatching { logged.generateImage("b") } }
        runCatching { logged.generateImage(" ") } // 空提示詞也走 provider，但 ScriptedProvider 回 fallback → ok
        val entries = GenerationLog.load(paths)
        assertEquals(listOf("ok", "http-429", "timeout", "http-429", "ok"), entries.map { it.outcome })
        assertEquals(2.0, entries[0].seconds, 0.0)
        val s = GenerationLog.summary(entries, 7, t)!!
        assertEquals(2, s.succeeded); assertEquals(5, s.total)
        assertEquals(listOf("http-429" to 2, "timeout" to 1), s.failures)
        assertNull(GenerationLog.summary(entries, 7, t + 8 * 86_400_000L))
        assertEquals("額度或限流", GenerationLog.labelKey("http-429"))
        assertEquals("HTTP 500", GenerationLog.labelKey("http-500"))
        assertEquals("回應無法解析", GenerationLog.labelKey("invalid-response"))
        assertEquals("其他", GenerationLog.labelKey("other"))
        assertEquals("cancelled", GenerationLog.outcome(GenerationError.Cancelled))
        assertEquals("invalid-response", GenerationLog.outcome(GenerationError.InvalidResponse))
        assertEquals("other", GenerationLog.outcome(GenerationError.WriteFailed))
        // 上限 300 筆。
        repeat(305) { GenerationLog.append(GenerationLogEntry(it.toLong(), "generate", "ok", 1.0), paths) }
        assertEquals(GenerationLog.LIMIT, GenerationLog.load(paths).size)
        // 真的空提示詞（OpenAI provider）不記。
        val before = GenerationLog.load(paths).size
        runCatching { LoggingImageProvider(OpenAIImageProvider("k"), paths).generateImage("  ") }
        assertEquals(before, GenerationLog.load(paths).size)
    }

    @Test fun imageHeaders() {
        assertEquals(2160 to 3840, ImageHeaders.pixelSize(TestSupport.png(2160, 3840)))
        assertEquals(1290 to 2796, ImageHeaders.pixelSize(TestSupport.jpeg(1290, 2796)))
        assertNull(ImageHeaders.pixelSize("hello".toByteArray()))
        assertNull(ImageHeaders.pixelSize(ByteArray(0)))
    }
}
