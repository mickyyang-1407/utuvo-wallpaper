package com.utuvo.wallpaper.core

import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.StandardCopyOption

/**
 * 影像編解碼（平台相關的部分）。B 段用 `BitmapFactory`／`Bitmap.compress` 實作；
 * JVM 測試用假的。核心邏輯只透過這個介面碰影像。
 */
interface ImageCodec {
    /** 讀圖檔寬高；不是可解的影像回 null。 */
    fun pixelSize(bytes: ByteArray): Pair<Int, Int>?
    /** aspect-fill 置中裁切（[CropMath]）＋高品質縮放成 JPEG（品質 0.92）。失敗丟 [GenerationError.Decoding]。 */
    fun cropToJpeg(bytes: ByteArray, targetW: Int, targetH: Int): ByteArray
    /** 把 [LocalArt] 畫好的像素存成 PNG。 */
    fun encodePng(image: LocalArt.Image): ByteArray
}

/** 不解碼、只讀檔頭拿 PNG／JPEG 寬高（給 [ImageCodec.pixelSize] 實作或測試用）。 */
object ImageHeaders {
    /** PNG IHDR 或 JPEG SOFn 的寬高；看不懂回 null。 */
    fun pixelSize(b: ByteArray): Pair<Int, Int>? {
        fun u8(i: Int) = b[i].toInt() and 0xFF
        fun u16(i: Int) = (u8(i) shl 8) or u8(i + 1)
        fun u32(i: Int) = (u8(i).toLong() shl 24) or (u8(i + 1).toLong() shl 16) or (u8(i + 2).toLong() shl 8) or u8(i + 3).toLong()
        if (b.size >= 24 && u8(0) == 0x89 && u8(1) == 0x50 && u8(2) == 0x4E && u8(3) == 0x47) {
            val w = u32(16); val h = u32(20)
            return if (w in 1..Int.MAX_VALUE && h in 1..Int.MAX_VALUE) w.toInt() to h.toInt() else null
        }
        if (b.size >= 4 && u8(0) == 0xFF && u8(1) == 0xD8) {
            var i = 2
            while (i + 9 < b.size) {
                if (u8(i) != 0xFF) return null
                val marker = u8(i + 1)
                if (marker == 0xFF) { i++; continue }
                val len = u16(i + 2)
                if (marker in 0xC0..0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC) {
                    val h = u16(i + 5); val w = u16(i + 7)
                    return if (w > 0 && h > 0) w to h else null
                }
                i += 2 + len
            }
        }
        return null
    }
}

/** 檔案小工具：原子寫入（暫存檔＋改名）。 */
object Files {
    /** 原子寫入；失敗丟 [GenerationError.WriteFailed]。 */
    fun write(bytes: ByteArray, to: File) {
        val tmp = File(to.parentFile, ".${to.name}.tmp")
        try {
            to.parentFile?.mkdirs()
            tmp.writeBytes(bytes)
            // 原子取代；不支援 ATOMIC_MOVE 時退回一般取代。絕不先刪舊檔（失敗時舊進度還在）。
            try {
                java.nio.file.Files.move(tmp.toPath(), to.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
            } catch (e: AtomicMoveNotSupportedException) {
                java.nio.file.Files.move(tmp.toPath(), to.toPath(), StandardCopyOption.REPLACE_EXISTING)
            }
        } catch (e: IOException) {
            tmp.delete()
            throw GenerationError.WriteFailed
        } catch (e: SecurityException) {
            tmp.delete()
            throw GenerationError.WriteFailed
        }
    }
}

/** 一次生成下來的結果（欄位與 iOS／Mac 相同，存進每日進度檔）。檔名都是相對於各自資料夾。 */
data class GeneratedWallpaper(
    val title: String,
    val nativeURL: String,
    val nativePixelSize: String,
    val wallpaperURL: String,
    val wallpaperPixelSize: String,
    val origin: String,
) {
    /** 轉 JSON。 */
    fun toJson(): JSONObject = JSONObject().put("title", title).put("nativeURL", nativeURL)
        .put("nativePixelSize", nativePixelSize).put("wallpaperURL", wallpaperURL)
        .put("wallpaperPixelSize", wallpaperPixelSize).put("origin", origin)

    companion object {
        /** 從 JSON 還原。 */
        fun fromJson(o: JSONObject) = GeneratedWallpaper(o.getString("title"), o.getString("nativeURL"),
            o.getString("nativePixelSize"), o.getString("wallpaperURL"), o.getString("wallpaperPixelSize"), o.getString("origin"))
    }
}

/**
 * 每日批次進度檔 `daily-<day>.json`（iOS／Mac 共用的 `DailyBatch` 規則）。
 * 請求送出前先記次數，當機也不會重置重試額度。[retryAfterMs] 為 null＝不再自動試。
 */
data class DailyBatch(
    val count: Int,
    val completed: List<GeneratedWallpaper> = emptyList(),
    val attempts: List<Int>,
    val retryAfterMs: Long?,
    val plan: List<PlannedPrompt>?,
) {
    /** 這一批要生成的內容：有存就照存的，舊檔照舊輪替。 */
    fun prompts(data: PromptData, day: String): List<PlannedPrompt> =
        if (plan != null && plan.size == count) plan else DailyPlan.legacy(data, day, count)

    /** 現在能不能續作下一張。 */
    fun canResume(nowMs: Long): Boolean {
        if (completed.size >= count || attempts.size != count || retryAfterMs == null) return false
        return retryAfterMs <= nowMs && attempts[completed.size] < RetryPolicy.MAX_ATTEMPTS
    }

    /** 寫回進度檔。 */
    fun save(root: File, day: String) {
        val o = JSONObject().put("count", count)
            .put("completed", JSONArray(completed.map { it.toJson() }))
            .put("attempts", JSONArray(attempts))
            .put("retryAfter", retryAfterMs ?: JSONObject.NULL)
        if (plan != null) o.put("plan", JSONArray(plan.map {
            JSONObject().put("templateID", it.templateID).put("slug", it.slug).put("prompt", it.prompt)
        }))
        Files.write(o.toString().toByteArray(), file(root, day))
    }

    companion object {
        /** 進度檔路徑。 */
        fun file(root: File, day: String) = File(root, "daily-$day.json")

        /** 讀進度檔；格式壞掉丟 [GenerationError.InvalidResponse]。 */
        fun load(root: File, day: String): DailyBatch = try {
            val o = JSONObject(file(root, day).readText())
            val completed = o.getJSONArray("completed").let { a -> List(a.length()) { GeneratedWallpaper.fromJson(a.getJSONObject(it)) } }
            val attempts = o.getJSONArray("attempts").let { a -> List(a.length()) { a.getInt(it) } }
            val plan = o.optJSONArray("plan")?.let { a ->
                List(a.length()) { a.getJSONObject(it).let { p -> PlannedPrompt(p.getString("templateID"), p.getString("slug"), p.getString("prompt")) } }
            }
            DailyBatch(o.getInt("count"), completed, attempts, if (o.isNull("retryAfter")) null else o.getLong("retryAfter"), plan)
        } catch (e: GenerationError) {
            throw e
        } catch (e: Exception) {
            throw GenerationError.InvalidResponse
        }

        /** 有檔就讀（張數不符丟錯），沒有就建立新的一批並存檔。 */
        fun prepare(root: File, day: String, count: Int, plan: List<PlannedPrompt>?, nowMs: Long): DailyBatch {
            if (file(root, day).exists()) {
                val b = load(root, day)
                if (b.count != count || b.attempts.size != count || b.completed.size > count) throw GenerationError.InvalidResponse
                return b
            }
            val b = DailyBatch(count, emptyList(), List(count) { 0 }, nowMs, plan)
            b.save(root, day)
            return b
        }
    }
}

/**
 * 每日批次與手動產生（iOS `DailyGenerationService`）。阻塞呼叫，請在 WorkManager／背景執行緒跑。
 * - 每天一批 [BATCH_SIZE] 張，進度檔續作；純色／漸層本機畫，不送 API。
 * - 手動產生不寫每日進度檔、不佔每天那一批。
 */
class DailyGenerationService(
    private val data: PromptData,
    private val provider: ImageProvider,
    private val paths: AppPaths,
    private val codec: ImageCodec,
    /** 裝置原生直式像素。 */
    private val targetW: Int,
    private val targetH: Int,
    private val recipe: DailyRecipe = DailyRecipe(),
    private val nowMs: () -> Long = System::currentTimeMillis,
    /** 回 true 就在下一張之前丟 [GenerationError.Cancelled]。 */
    private val isCancelled: () -> Boolean = { false },
) {
    /** 跑（或續作）[day] 的每日批次；回傳已完成的全部。冷卻中丟 [GenerationError.Cooldown]。 */
    fun run(day: String, count: Int = BATCH_SIZE, progress: (Int, Int) -> Unit = { _, _ -> }): List<GeneratedWallpaper> {
        if (count <= 0) throw GenerationError.EmptyPrompt
        paths.prepare()
        var batch = DailyBatch.prepare(paths.root, day, count, DailyPlan.make(data, day, count, recipe), nowMs())
        val plan = batch.prompts(data, day)
        val results = batch.completed.toMutableList()
        progress(results.size, count)
        for (index in results.size until count) {
            if (isCancelled()) throw GenerationError.Cancelled
            val planned = plan[index]
            val native = File(paths.originals, "${planned.slug}-daily-$day.png")
            val wallpaper = File(paths.wallpapers, "${planned.slug}-daily-$day.jpg")
            val png: ByteArray
            if (native.isFile) {
                png = native.readBytes()
            } else if (LocalArt.isLocal(planned.prompt)) {
                val drawn = LocalArt.render(planned.prompt, targetW, targetH) ?: throw GenerationError.Decoding
                png = codec.encodePng(drawn)
                Files.write(png, native)
            } else {
                if (!batch.canResume(nowMs())) throw GenerationError.Cooldown
                // 先記次數再送出：當機也不會重置重試額度。
                val attempts = batch.attempts.toMutableList().also { it[index] += 1 }
                batch = batch.copy(attempts = attempts, retryAfterMs = nowMs() + RetryPolicy.LATER_COOLDOWN_SECONDS * 1000)
                batch.save(paths.root, day)
                png = try {
                    // 解碼檢查放在同一個 try：解不開（不可重試）也走同一段冷卻規則，停住這批，不再付費重打。
                    provider.generateImage(PortraitPrompt.convert(planned.prompt)).also {
                        if (codec.pixelSize(it) == null) throw GenerationError.Decoding
                    }
                } catch (e: Throwable) {
                    // Throwable：provider 丟 Error（例如記憶體不足）也要寫回冷卻，不然 retryAfter 會停在請求前的 +300 秒。
                    val cooldown = RetryPolicy.cooldownSeconds(attempts[index], RetryPolicy.isResumable(e))
                    batch = batch.copy(retryAfterMs = cooldown?.let { nowMs() + it * 1000 })
                    batch.save(paths.root, day)
                    throw e
                }
                Files.write(png, native)
            }
            val size = codec.pixelSize(png) ?: throw GenerationError.Decoding
            Files.write(codec.cropToJpeg(png, targetW, targetH), wallpaper)
            results += GeneratedWallpaper(titleOf(planned), native.name, CropMath.label(size.first, size.second),
                wallpaper.name, CropMath.label(targetW, targetH), "resampled")
            batch = batch.copy(completed = results.toList(), retryAfterMs = if (results.size < count) nowMs() else null)
            batch.save(paths.root, day)
            progress(results.size, count)
        }
        return results
    }

    /**
     * 手動「立即產生」：每次加隨機 salt 換一組主題；每完成一張立刻寫檔，中途失敗已完成的保留。
     * [runID] 有給時（背景工作 id）：salt 固定用它、檔名可預測（`<slug>-<runID>-<第幾張>`），
     * 重跑時該張檔案已存在就直接沿用、不再呼叫 provider——續作以檔案為準，不會重付。
     */
    fun runManual(day: String, count: Int, salt: String = java.util.UUID.randomUUID().toString().uppercase(),
                  progress: (Int, Int) -> Unit = { _, _ -> }, runID: String? = null): List<GeneratedWallpaper> {
        if (count <= 0) throw GenerationError.EmptyPrompt
        paths.prepare()
        val plan = DailyPlan.make(data, day, count, recipe, runID ?: salt)
        val results = mutableListOf<GeneratedWallpaper>()
        progress(0, count)
        for ((index, planned) in plan.withIndex()) {
            val id = if (runID != null) "$runID-${index + 1}" else RandomID.make()
            val native = File(paths.originals, "${planned.slug}-$id.png")
            val wallpaper = File(paths.wallpapers, "${planned.slug}-$id.jpg")
            if (runID != null && native.isFile && wallpaper.isFile) {
                // 上次（被系統中斷前）已做完這張：沿用，不重付。
                val size = codec.pixelSize(native.readBytes())
                if (size != null) {
                    results += GeneratedWallpaper(titleOf(planned), native.name, CropMath.label(size.first, size.second),
                        wallpaper.name, CropMath.label(targetW, targetH), "resampled")
                    progress(results.size, count)
                    continue
                }
            }
            if (isCancelled()) throw GenerationError.Cancelled
            val png = if (runID != null && native.isFile && codec.pixelSize(native.readBytes()) != null) {
                native.readBytes() // 原生圖已存、裝置尺寸還沒裁：重裁就好。
            } else if (LocalArt.isLocal(planned.prompt)) {
                codec.encodePng(LocalArt.render(planned.prompt, targetW, targetH) ?: throw GenerationError.Decoding)
            } else {
                provider.generateImage(PortraitPrompt.convert(planned.prompt))
            }
            val size = codec.pixelSize(png) ?: throw GenerationError.Decoding
            Files.write(png, native)
            Files.write(codec.cropToJpeg(png, targetW, targetH), wallpaper)
            results += GeneratedWallpaper(titleOf(planned), native.name, CropMath.label(size.first, size.second),
                wallpaper.name, CropMath.label(targetW, targetH), "resampled")
            progress(results.size, count)
        }
        return results
    }

    private fun titleOf(p: PlannedPrompt) = data.template(p.templateID)?.title ?: p.templateID

    companion object {
        const val BATCH_SIZE = 10

        /** 今天是否還有工作可做（未建立、或可續作）。 */
        fun hasWork(paths: AppPaths, day: String, nowMs: Long): Boolean {
            if (!DailyBatch.file(paths.root, day).exists()) return true
            return runCatching { DailyBatch.load(paths.root, day).canResume(nowMs) }.getOrDefault(false)
        }

        /** (完成張數, 總張數)；沒有進度檔回 null。 */
        fun status(paths: AppPaths, day: String): Pair<Int, Int>? =
            runCatching { DailyBatch.load(paths.root, day) }.getOrNull()?.let { it.completed.size to it.count }
    }
}

/** 日夜場景紀錄（`dynamic/<id>/scene.json` 與 `dynamic/current.json`）。 */
data class SceneRecord(val id: String, val prompt: String, val completed: Boolean) {
    /** 轉 JSON 位元組。 */
    fun toBytes(): ByteArray = JSONObject().put("id", id).put("prompt", prompt).put("completed", completed).toString().toByteArray()

    companion object {
        /** 讀檔；壞檔或不存在回 null。 */
        fun read(file: File): SceneRecord? = runCatching {
            JSONObject(file.readText()).let { SceneRecord(it.getString("id"), it.getString("prompt"), it.getBoolean("completed")) }
        }.getOrNull()
    }
}

/**
 * 日夜場景生成（iOS `SceneGenerationService`）：白天生成 → 同一張做 3 次 edits（清晨／黃昏／夜晚）
 * → 四張都裁成裝置尺寸。全部完成才寫 `dynamic/current.json` 發布。已存在的時段檔會續用（續作）。
 */
class SceneGenerationService(
    private val provider: ImageProvider,
    private val paths: AppPaths,
    private val codec: ImageCodec,
    private val targetW: Int,
    private val targetH: Int,
    private val isCancelled: () -> Boolean = { false },
) {
    /** 場景資料夾。 */
    fun directory(id: String) = File(paths.dynamic, id)

    /** 生成（或續作）一組四時段；同 id 但提示詞不同丟 [GenerationError.InvalidResponse]。 */
    fun generate(rawPrompt: String, id: String = "scene-" + RandomID.make(), progress: (Int) -> Unit = {}): SceneRecord {
        val prompt = OpenAIImageProvider.validatePrompt(rawPrompt)
        paths.prepare()
        val dir = directory(id).apply { mkdirs() }
        val manifest = File(dir, "scene.json")
        val old = SceneRecord.read(manifest)
        if (old != null) {
            if (old.prompt != prompt) throw GenerationError.InvalidResponse
        } else {
            Files.write(SceneRecord(id, prompt, false).toBytes(), manifest)
        }
        val baseFile = File(dir, "day.png")
        val base = if (baseFile.isFile) baseFile.readBytes() else {
            // 第一個付費請求送出前也要檢查是否已取消。
            if (isCancelled()) throw GenerationError.Cancelled
            provider.generateImage(DayPhase.basePrompt(prompt)).also {
                if (codec.pixelSize(it) == null) throw GenerationError.Decoding
                Files.write(it, baseFile)
            }
        }
        Files.write(codec.cropToJpeg(base, targetW, targetH), File(dir, "day.jpg"))
        progress(1)
        RELIGHT_ORDER.forEachIndexed { offset, phase ->
            if (isCancelled()) throw GenerationError.Cancelled
            val native = File(dir, phase.raw + ".png")
            val png = if (native.isFile) native.readBytes() else {
                provider.relight(base, phase.relightPrompt).also {
                    if (codec.pixelSize(it) == null) throw GenerationError.Decoding
                    Files.write(it, native)
                }
            }
            Files.write(codec.cropToJpeg(png, targetW, targetH), File(dir, phase.raw + ".jpg"))
            progress(offset + 2)
        }
        val record = SceneRecord(id, prompt, true)
        Files.write(record.toBytes(), manifest)
        Files.write(record.toBytes(), paths.currentScenePointer)
        return record
    }

    companion object {
        val RELIGHT_ORDER = listOf(DayPhase.DAWN, DayPhase.DUSK, DayPhase.NIGHT)

        /** 目前已發布的場景；沒有或未完成回 null。 */
        fun published(paths: AppPaths): SceneRecord? = SceneRecord.read(paths.currentScenePointer)?.takeIf { it.completed }
    }
}

/** 一次生圖請求的結果（不記提示詞、key 或回應內容）。 */
data class GenerationLogEntry(val atMs: Long, val kind: String, val outcome: String, val seconds: Double) {
    val succeeded: Boolean get() = outcome == "ok"
}

/** 成功率紀錄（iOS `GenerationLog`）：`generation-log.json`，最多 [LIMIT] 筆。 */
object GenerationLog {
    const val LIMIT = 300
    private val lock = Any()

    /** 成功率摘要；failures 依次數多到少、同數依名稱。 */
    data class Summary(val succeeded: Int, val total: Int, val failures: List<Pair<String, Int>>)

    /** 紀錄檔路徑。 */
    fun file(paths: AppPaths) = File(paths.root, "generation-log.json")

    /** 讀全部紀錄；壞檔回空。 */
    fun load(paths: AppPaths): List<GenerationLogEntry> = runCatching {
        val a = JSONArray(file(paths).readText())
        List(a.length()) { i -> a.getJSONObject(i).let { GenerationLogEntry(it.getLong("at"), it.getString("kind"), it.getString("outcome"), it.getDouble("seconds")) } }
    }.getOrDefault(emptyList())

    /** 加一筆（超過上限丟掉最舊的）。 */
    fun append(entry: GenerationLogEntry, paths: AppPaths) = synchronized(lock) {
        val entries = (load(paths) + entry).takeLast(LIMIT)
        val a = JSONArray(entries.map { JSONObject().put("at", it.atMs).put("kind", it.kind).put("outcome", it.outcome).put("seconds", it.seconds) })
        runCatching { Files.write(a.toString().toByteArray(), file(paths)) }
        Unit
    }

    /** 錯誤 → 結果代碼（http-429、timeout、transport、cancelled、decoding、invalid-response、other）。 */
    fun outcome(error: Throwable): String = when (error) {
        is GenerationError.HttpStatus -> "http-${error.code}"
        is GenerationError.Timeout -> "timeout"
        is GenerationError.Transport -> "transport"
        is GenerationError.Cancelled, is InterruptedException, is java.util.concurrent.CancellationException -> "cancelled"
        is GenerationError.Decoding -> "decoding"
        is GenerationError.InvalidResponse -> "invalid-response"
        else -> "other"
    }

    /** 最近 [days] 天的成功率；沒有請求回 null。 */
    fun summary(entries: List<GenerationLogEntry>, days: Int = 7, nowMs: Long = System.currentTimeMillis()): Summary? {
        val since = nowMs - days * 86_400_000L
        val recent = entries.filter { it.atMs >= since }
        if (recent.isEmpty()) return null
        val failures = recent.filter { !it.succeeded }.groupingBy { it.outcome }.eachCount().toList()
            .sortedWith(compareByDescending<Pair<String, Int>> { it.second }.thenBy { it.first })
        return Summary(recent.count { it.succeeded }, recent.size, failures)
    }

    /** 失敗原因的繁中 key（B 段查英文）；http-xxx 非 429 回 "HTTP xxx"。 */
    fun labelKey(outcome: String): String = when (outcome) {
        "timeout" -> "逾時"
        "transport" -> "連線中斷"
        "cancelled" -> "被中斷"
        "http-429" -> "額度或限流"
        "decoding", "invalid-response" -> "回應無法解析"
        else -> if (outcome.startsWith("http-")) "HTTP " + outcome.removePrefix("http-") else "其他"
    }
}

/** 包住真的 provider，每個請求記一筆結果（空提示詞沒送出，不記）。 */
class LoggingImageProvider(
    private val base: ImageProvider,
    private val paths: AppPaths,
    private val nowMs: () -> Long = System::currentTimeMillis,
) : ImageProvider {
    override fun generateImage(prompt: String): ByteArray = record("generate") { base.generateImage(prompt) }
    override fun relight(reference: ByteArray, prompt: String): ByteArray = record("relight") { base.relight(reference, prompt) }

    private fun record(kind: String, work: () -> ByteArray): ByteArray {
        val start = nowMs()
        try {
            val bytes = work()
            GenerationLog.append(GenerationLogEntry(start, kind, "ok", (nowMs() - start) / 1000.0), paths)
            return bytes
        } catch (e: GenerationError.EmptyPrompt) {
            throw e
        } catch (e: Throwable) {
            GenerationLog.append(GenerationLogEntry(start, kind, GenerationLog.outcome(e), (nowMs() - start) / 1000.0), paths)
            throw e
        }
    }
}
