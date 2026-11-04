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

    @Test fun undecodableImageStopsTheDayWithoutRepaying() {
        val paths = AppPaths(TestSupport.tempDir())
        val provider = ScriptedProvider("garbage".toByteArray())
        try { service(provider, paths, aiOnly).run(day); fail() } catch (e: GenerationError) {
            assertEquals(GenerationError.Decoding, e)
        }
        val batch = DailyBatch.load(paths.root, day)
        assertNull(batch.retryAfterMs)
        assertEquals(1, batch.attempts[0])
        assertFalse(batch.canResume(now + 86_400_000))
        assertFalse(DailyGenerationService.hasWork(paths, day, now + 86_400_000))
        assertEquals(1, provider.prompts.size)
    }

    @Test fun providerErrorStillWritesTheCooldown() {
        val paths = AppPaths(TestSupport.tempDir())
        val provider = object : ImageProvider {
            override fun generateImage(prompt: String): ByteArray = throw OutOfMemoryError("test")
            override fun relight(reference: ByteArray, prompt: String): ByteArray = throw OutOfMemoryError("test")
        }
        try { service(provider, paths, aiOnly).run(day); fail() } catch (e: OutOfMemoryError) {}
        val batch = DailyBatch.load(paths.root, day)
        assertEquals(1, batch.attempts[0])
        assertNull(batch.retryAfterMs)
    }

    @Test fun atomicWriteReplacesWithoutLeavingTemp() {
        val dir = TestSupport.tempDir()
        val f = java.io.File(dir, "daily-x.json")
        Files.write("one".toByteArray(), f)
        Files.write("two".toByteArray(), f)
        assertEquals("two", f.readText())
        assertFalse(java.io.File(dir, ".daily-x.json.tmp").exists())
    }

    @Test fun manualResumeReusesExistingFilesWithoutRepaying() {
        val paths = AppPaths(TestSupport.tempDir())
        val png = TestSupport.png(4, 8)
        // 第一次：前 3 張完成，第 4 張時被中斷（例如行程被殺）。
        val first = ScriptedProvider(png, png, png, GenerationError.Cancelled)
        try { service(first, paths, aiOnly).runManual(day, 5, runID = "abcd1234"); fail() } catch (e: GenerationError.Cancelled) { }
        assertEquals(4, first.prompts.size)
        assertEquals(3, paths.wallpapers.listFiles()!!.count { it.name.contains("-abcd1234-") })
        // 重跑同一個工作：第 1–3 張檔案已存在，只請求剩下的 2 張。
        val second = ScriptedProvider(png, png)
        val results = service(second, paths, aiOnly).runManual(day, 5, runID = "abcd1234")
        assertEquals(5, results.size)
        assertEquals(2, second.prompts.size)
        assertEquals(first.prompts.drop(3).take(1), second.prompts.take(1)) // 同一個計畫：第 4 張主題不變
        val names = paths.wallpapers.listFiles()!!.map { it.name }.sorted()
        assertEquals(5, names.size)
        assertEquals((1..5).map { "-abcd1234-$it.jpg" }.toSet(), names.map { it.substring(it.indexOf("-abcd1234-")) }.toSet())
    }

    @Test fun manualDoesNotResendRequestInterruptedMidFlight() {
        val paths = AppPaths(TestSupport.tempDir())
        val png = TestSupport.png(4, 8)
        // 第 2 張送出後行程就死了（不是 GenerationError，標記留著）。
        val first = ScriptedProvider(png, IllegalStateException("process killed"))
        try { service(first, paths, aiOnly).runManual(day, 3, runID = "k1"); fail() } catch (e: IllegalStateException) { }
        assertEquals(2, first.prompts.size)
        // 重跑：第 2 張不重送（可能已收費），只送第 3 張。
        val second = ScriptedProvider(png)
        val results = service(second, paths, aiOnly).runManual(day, 3, runID = "k1")
        assertEquals(2, results.size)
        assertEquals(listOf(first.prompts[0]), listOf(first.prompts[0]))
        assertEquals(1, second.prompts.size)
        assertFalse(second.prompts[0] == first.prompts[1])
        // 再跑一次也一樣不送（標記沒被清掉）。
        val third = ScriptedProvider()
        assertEquals(2, service(third, paths, aiOnly).runManual(day, 3, runID = "k1").size)
        assertEquals(0, third.prompts.size)
    }

    @Test fun manualErrorWithKnownOutcomeClearsMarker() {
        val paths = AppPaths(TestSupport.tempDir())
        val png = TestSupport.png(4, 8)
        try { service(ScriptedProvider(GenerationError.HttpStatus(500)), paths, aiOnly).runManual(day, 1, runID = "h1"); fail() }
        catch (e: GenerationError.HttpStatus) { }
        assertTrue(paths.originals.listFiles().orEmpty().none { it.name.endsWith(".inflight") })
        val again = ScriptedProvider(png)
        assertEquals(1, service(again, paths, aiOnly).runManual(day, 1, runID = "h1").size)
        assertEquals(1, again.prompts.size)
    }

    @Test fun sceneDoesNotResendInterruptedRequest() {
        val paths = AppPaths(TestSupport.tempDir())
        val png = TestSupport.png(4, 8)
        // 白天那張好了，清晨那張送出後行程死掉。
        val first = ScriptedProvider(png, IllegalStateException("process killed"))
        try { SceneGenerationService(first, paths, FakeCodec(), 108, 234).generate("lake", "s9"); fail() } catch (e: IllegalStateException) { }
        val again = ScriptedProvider()
        try { SceneGenerationService(again, paths, FakeCodec(), 108, 234).generate("lake", "s9"); fail() }
        catch (e: GenerationError) { assertEquals(GenerationError.Interrupted, e) }
        assertTrue(again.prompts.isEmpty())
        assertTrue(again.relights.isEmpty())
        assertNull(SceneGenerationService.published(paths))
    }

    @Test fun manualResumeRecropsWhenOnlyOriginalExists() {
        val paths = AppPaths(TestSupport.tempDir())
        val png = TestSupport.png(4, 8)
        service(ScriptedProvider(png, png), paths, aiOnly).runManual(day, 2, runID = "r1")
        val jpg = paths.wallpapers.listFiles()!!.first { it.name.endsWith("-r1-2.jpg") }
        assertTrue(jpg.delete())
        val again = ScriptedProvider()
        assertEquals(2, service(again, paths, aiOnly).runManual(day, 2, runID = "r1").size)
        assertEquals(0, again.prompts.size)
        assertTrue(jpg.isFile)
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
