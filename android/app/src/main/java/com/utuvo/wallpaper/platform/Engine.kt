package com.utuvo.wallpaper.platform

import android.app.AlarmManager
import android.app.PendingIntent
import android.app.WallpaperManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.graphics.BitmapFactory
import android.util.Log
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.utuvo.wallpaper.core.CurrentWallpaper
import com.utuvo.wallpaper.core.DailyGenerationService
import com.utuvo.wallpaper.core.DailyRecipe
import com.utuvo.wallpaper.core.DayPhase
import com.utuvo.wallpaper.core.DynamicAutoFrequency
import com.utuvo.wallpaper.core.DynamicAutoPlanner
import com.utuvo.wallpaper.core.DynamicAutoState
import com.utuvo.wallpaper.core.Files
import com.utuvo.wallpaper.core.GenerationError
import com.utuvo.wallpaper.core.ImageProvider
import com.utuvo.wallpaper.core.LoggingImageProvider
import com.utuvo.wallpaper.core.OpenAIImageProvider
import com.utuvo.wallpaper.core.RetryPolicy
import com.utuvo.wallpaper.core.SceneGenerationService
import com.utuvo.wallpaper.core.WallpaperItem
import com.utuvo.wallpaper.core.WallpaperLibrary
import com.utuvo.wallpaper.core.AppPaths
import com.utuvo.wallpaper.debug.DebugHooks
import com.utuvo.wallpaper.ui.Strings
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import okhttp3.HttpUrl.Companion.toHttpUrl
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

private const val TAG = "UTUVOWallpaper"

/** 選 provider：Debug 假 provider ＞ 存好的 key ＞ 沒有 key（只能畫純色／漸層）。 */
object Providers {
    fun make(context: Context): ImageProvider {
        val env = AppEnv.get(context)
        val base: ImageProvider = DebugHooks.fakeProvider(context) ?: env.keys.load()?.let { key ->
            val url = DebugHooks.baseUrl(context)?.toHttpUrl() ?: OpenAIImageProvider.DEFAULT_BASE.toHttpUrl()
            OpenAIImageProvider(key, url)
        } ?: MissingKeyProvider
        return LoggingImageProvider(base, env.paths) { AppClock.nowMs(context) }
    }

    /** 能不能送 AI 請求（有 key 或 Debug 假 provider）。 */
    fun canGenerate(context: Context): Boolean = DebugHooks.fakeProvider(context) != null || AppEnv.get(context).keys.hasKey

    private object MissingKeyProvider : ImageProvider {
        override fun generateImage(prompt: String): ByteArray {
            OpenAIImageProvider.validatePrompt(prompt); throw GenerationError.MissingCredential
        }
        override fun relight(reference: ByteArray, prompt: String): ByteArray = throw GenerationError.MissingCredential
    }
}

/** 換桌布：把「目前應該是哪張」解成檔案，用 WallpaperManager 設主畫面＋鎖定畫面。 */
object Wallpapers {
    private const val LAST_APPLIED = "lastApplied"
    /** 使用者按過「設為桌布」或「套用日夜桌布」之後，背景才會自己換。 */
    private const val MANAGING = "managing"
    private val lock = Any()

    fun isManaging(context: Context) = AppEnv.get(context).raw.getBoolean(MANAGING, false)
    fun lastApplied(context: Context): String? = AppEnv.get(context).raw.getString(LAST_APPLIED, null)

    fun items(context: Context): List<WallpaperItem> {
        val env = AppEnv.get(context)
        return WallpaperLibrary.load(env.data, env.paths, AppEnv.DEMO_NAMES)
    }

    /** 某張圖（含示範圖）的裝置尺寸 JPEG。 */
    fun deviceFile(context: Context, item: WallpaperItem): File? {
        if (!item.isDemo) return item.file?.takeIf { it.isFile }
        return cachedCrop(context, "wallpapers/" + item.fileName, "wall-" + item.fileName.substringBeforeLast('.'))
    }

    /** 日夜某時段的裝置尺寸 JPEG（示範場景從 assets 裁）。 */
    fun phaseFile(context: Context, sceneID: String, phase: DayPhase): File? {
        if (sceneID == "demo") return cachedCrop(context, "dynamic/mountain-hours/${phase.raw}.jpg", "hours-" + phase.raw)
        return WallpaperLibrary.scenePhaseFile(AppEnv.get(context).paths, sceneID, phase)
    }

    private fun cachedCrop(context: Context, asset: String, name: String): File? = runCatching {
        val env = AppEnv.get(context)
        val (w, h) = DeviceScreen.nativePixels(context)
        val out = File(env.paths.demoCache, "$name-${w}x$h.jpg")
        if (!out.isFile) {
            val bytes = context.assets.open(asset).use { it.readBytes() }
            Files.write(BitmapCodec.cropToJpeg(bytes, w, h), out)
        }
        out
    }.getOrNull()

    /** 解出來的結果 → (識別字串, 檔案)。 */
    fun fileFor(context: Context, r: CurrentWallpaper.Resolved): Pair<String, File?> = when (r) {
        is CurrentWallpaper.Resolved.Item -> r.item.id to deviceFile(context, r.item)
        is CurrentWallpaper.Resolved.Dynamic -> "dynamic:${r.sceneID}:${r.phase.raw}" to phaseFile(context, r.sceneID, r.phase)
    }

    /** 真的換桌布（主畫面＋鎖定畫面）。 */
    fun apply(context: Context, key: String, file: File): Boolean = synchronized(lock) {
        val bitmap = BitmapFactory.decodeFile(file.path) ?: return false
        try {
            WallpaperManager.getInstance(context)
                .setBitmap(bitmap, null, true, WallpaperManager.FLAG_SYSTEM or WallpaperManager.FLAG_LOCK)
        } catch (e: Exception) {
            Log.w(TAG, "wallpaper set failed: ${e.javaClass.simpleName}")
            return false
        } finally {
            bitmap.recycle()
        }
        AppEnv.get(context).raw.edit().putString(LAST_APPLIED, key).putBoolean(MANAGING, true).apply()
        Log.i(TAG, "wallpaper applied: $key")
        true
    }

    private fun isDark(context: Context) =
        (context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES

    /** 「現在應該是哪張」，跟目前不同才換。force＝不管是否相同都設一次。回傳換上的 key。 */
    fun refresh(context: Context, force: Boolean = false): String? {
        if (!force && !isManaging(context)) return null
        val env = AppEnv.get(context)
        val resolved = CurrentWallpaper(env.data, env.paths, env.prefs).resolve(AppClock.now(context), items(context), isDark(context))
            ?: return null
        val (key, file) = fileFor(context, resolved)
        if (!force && key == lastApplied(context)) return null
        return if (file != null && apply(context, key, file)) key else null
    }

    /** 「設為桌布」：固定這張、關日夜、立刻換。回傳 (成功, 是否關掉了日夜)。 */
    fun setItem(context: Context, item: WallpaperItem): Pair<Boolean, Boolean> {
        val env = AppEnv.get(context)
        val file = deviceFile(context, item) ?: return false to false
        val turnedOff = CurrentWallpaper(env.data, env.paths, env.prefs).setAsWallpaper(item)
        val ok = apply(context, item.id, file)
        Scheduler.sync(context)
        return ok to turnedOff
    }

    /** 「套用日夜桌布」：開日夜、清固定、換成目前時段。 */
    fun applyDynamic(context: Context): DayPhase? {
        val env = AppEnv.get(context)
        env.prefs.dynamicEnabled = true
        env.prefs.pinnedID = null
        val now = AppClock.now(context)
        val phase = env.prefs.schedule(env.data, now).phase(now.plusMinutes(if (env.prefs.dynamicTiming.raw == "solar") 5 else 0), isDark(context))
        val key = refresh(context, force = true)
        Scheduler.sync(context)
        return if (key != null) phase else null
    }
}

/** 一次只跑一個生成作業（手動、每日、日夜都共用）。進度給介面看。 */
object Jobs {
    data class State(val kind: String, val done: Int, val total: Int)
    val running = MutableStateFlow<State?>(null)
    /** 最近一次完成／失敗的訊息 key（給介面顯示，顯示後清空）。 */
    val finished = MutableStateFlow<Result<Pair<String, Int>>?>(null)
    private val busy = AtomicBoolean(false)
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /** 拿到鎖才跑；拿不到回 false。 */
    fun <T> exclusive(kind: String, total: Int, work: ((Int, Int) -> Unit) -> T): Result<T>? {
        if (!busy.compareAndSet(false, true)) return null
        running.value = State(kind, 0, total)
        return try {
            Result.success(work { d, t -> running.value = State(kind, d, t) })
        } catch (e: Throwable) {
            Result.failure(e)
        } finally {
            running.value = null
            busy.set(false)
        }
    }

    fun isBusy() = busy.get()

    fun daily(context: Context, env: AppEnv = AppEnv.get(context), recipe: DailyRecipe = env.prefs.recipe(env.data)) =
        DailyGenerationService(env.data, Providers.make(context), env.paths, BitmapCodec,
            DeviceScreen.nativePixels(context).first, DeviceScreen.nativePixels(context).second, recipe,
            nowMs = { AppClock.nowMs(context) })

    /** 手動產生（背景跑，關掉面板也會繼續）。 */
    fun launchManual(context: Context, count: Int, recipe: DailyRecipe): Boolean {
        if (isBusy()) return false
        val app = context.applicationContext
        scope.launch {
            val env = AppEnv.get(app)
            val day = AppPaths.dayString(AppClock.now(app))
            val r = exclusive("manual", count) { p -> daily(app, env, recipe).runManual(day, count, progress = p) }
            if (r != null) finished.value = r.map { "manual" to it.size }
        }
        return true
    }

    /** 每日批次（背景工作與 Debug 都走這裡）。 */
    fun runDaily(context: Context): Result<Int>? {
        val env = AppEnv.get(context)
        val day = AppPaths.dayString(AppClock.now(context))
        if (!DailyGenerationService.hasWork(env.paths, day, AppClock.nowMs(context))) return Result.success(0)
        return exclusive("daily", DailyGenerationService.BATCH_SIZE) { p -> daily(context, env).run(day, progress = p).size }
    }

    /** 日夜場景生成。完成後切到這個場景並開啟日夜。 */
    fun runScene(context: Context, prompt: String, id: String? = null): Result<String>? {
        val env = AppEnv.get(context)
        val (w, h) = DeviceScreen.nativePixels(context)
        val svc = SceneGenerationService(Providers.make(context), env.paths, BitmapCodec, w, h)
        return exclusive("scene", 4) { p ->
            val rec = if (id != null) svc.generate(prompt, id) { p(it, 4) } else svc.generate(prompt) { p(it, 4) }
            env.prefs.dynamicSceneID = rec.id
            rec.id
        }
    }

    fun launchScene(context: Context, prompt: String): Boolean {
        if (isBusy()) return false
        val app = context.applicationContext
        scope.launch {
            val r = runScene(app, prompt) ?: return@launch
            r.onSuccess { Wallpapers.applyDynamic(app) }
            finished.value = r.map { "scene" to 4 }
        }
        return true
    }

    /** 日夜 AI 自動：到期就生成一組，失敗記重試。manual＝使用者按「現在用 AI 生成一組」。 */
    fun runDynamicAuto(context: Context, manual: Boolean): Result<String>? {
        val env = AppEnv.get(context)
        val freq = env.prefs.dynamicAutoFrequency
        val now = AppClock.now(context)
        val chinese = Strings.isChinese(context)
        val prev = AutoStateFile.read(env.paths)
        val state = if (manual) DynamicAutoPlanner.manual(env.data, prev, now, freq, chinese = chinese)
        else DynamicAutoPlanner.due(env.data, prev, now, freq, chinese = chinese) ?: return null
        val counted = state.copy(attempts = state.attempts + 1)
        AutoStateFile.write(env.paths, counted)
        val r = runScene(context, state.prompt, state.sceneID) ?: return null
        r.onSuccess {
            AutoStateFile.write(env.paths, counted.recordSuccess())
            Wallpapers.applyDynamic(context)
        }.onFailure { e ->
            AutoStateFile.write(env.paths, counted.recordFailure(RetryPolicy.isRetryable(e), AppClock.nowMs(context)))
        }
        return r
    }
}

/** `dynamic/auto.json`（Swift `DynamicAutoState` 同欄位）。 */
object AutoStateFile {
    fun read(paths: AppPaths): DynamicAutoState? = runCatching {
        val o = JSONObject(paths.dynamicAutoState.readText())
        DynamicAutoState(o.getString("period"), o.getString("subject"), o.getString("prompt"), o.getString("sceneID"),
            o.optInt("attempts", 0), if (o.isNull("retryAfter")) null else o.optLong("retryAfter"),
            o.optBoolean("completed", false),
            o.optJSONArray("recentSubjects")?.let { a -> List(a.length()) { a.getString(it) } } ?: emptyList())
    }.getOrNull()

    fun write(paths: AppPaths, s: DynamicAutoState) {
        paths.prepare()
        val o = JSONObject().put("period", s.period).put("subject", s.subject).put("prompt", s.prompt).put("sceneID", s.sceneID)
            .put("attempts", s.attempts).put("retryAfter", s.retryAfterEpochMs ?: JSONObject.NULL).put("completed", s.completed)
            .put("recentSubjects", JSONArray(s.recentSubjects))
        runCatching { Files.write(o.toString().toByteArray(), paths.dynamicAutoState) }
    }
}

/** 背景排程：輪換與每日生成用 WorkManager；日夜到點用 AlarmManager（不精確鬧鐘）。 */
object Scheduler {
    const val ROTATION = "rotation"
    const val DAILY = "daily"
    const val DAILY_NOW = "daily-now"
    private const val PHASE_REQUEST = 7

    /** 依目前設定排好全部（開 App、開機、改設定後都呼叫）。 */
    fun sync(context: Context) {
        val env = AppEnv.get(context)
        val wm = WorkManager.getInstance(context)
        val minutes = (env.prefs.rotationFrequency.minutes ?: 15).coerceAtLeast(15).toLong()
        wm.enqueueUniquePeriodicWork(ROTATION, ExistingPeriodicWorkPolicy.UPDATE,
            PeriodicWorkRequestBuilder<RotationWorker>(minutes, TimeUnit.MINUTES).build())
        val needsDaily = env.prefs.dailyEnabled || env.prefs.dynamicAutoFrequency != DynamicAutoFrequency.OFF
        if (needsDaily) {
            wm.enqueueUniquePeriodicWork(DAILY, ExistingPeriodicWorkPolicy.KEEP,
                PeriodicWorkRequestBuilder<DailyWorker>(3, TimeUnit.HOURS)
                    .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build()).build())
        } else {
            wm.cancelUniqueWork(DAILY)
        }
        armPhaseAlarm(context)
    }

    /** 立刻跑一次每日批次（開 App 時、Debug）。 */
    fun runDailyNow(context: Context) {
        WorkManager.getInstance(context).enqueueUniqueWork(DAILY_NOW, ExistingWorkPolicy.KEEP,
            OneTimeWorkRequestBuilder<DailyWorker>().build())
    }

    private fun phaseIntent(context: Context) = PendingIntent.getBroadcast(context, PHASE_REQUEST,
        Intent(context, PhaseAlarmReceiver::class.java), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

    /** 日夜開著就排下一個時段的鬧鐘（不精確，最多晚 10 分鐘；輪換工作也會補換）。 */
    fun armPhaseAlarm(context: Context) {
        val env = AppEnv.get(context)
        val am = context.getSystemService(AlarmManager::class.java)
        val pi = phaseIntent(context)
        val now = AppClock.now(context)
        val next = if (env.prefs.dynamicEnabled) env.prefs.schedule(env.data, now).next(now) else null
        if (next == null) { am.cancel(pi); env.raw.edit().remove("phaseAlarmAt").apply(); return }
        val real = AppClock.realMs(context, next.at.toInstant().toEpochMilli()) + 1000
        am.setWindow(AlarmManager.RTC_WAKEUP, real, 10 * 60 * 1000L, pi)
        env.raw.edit().putLong("phaseAlarmAt", real).putString("phaseAlarmPhase", next.phase.raw).apply()
        Log.i(TAG, "phase alarm armed: ${next.phase.raw} at real=$real")
    }
}

/** 到點：換成新時段、排下一個。 */
class PhaseAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val pending = goAsync()
        Thread {
            try {
                Log.i(TAG, "phase alarm fired")
                Wallpapers.refresh(context)
                Scheduler.armPhaseAlarm(context)
            } finally {
                pending.finish()
            }
        }.start()
    }
}

/** 開機、更新 App、改時間／時區後重新排程。 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        Log.i(TAG, "reschedule after ${intent.action}")
        val pending = goAsync()
        Thread {
            try {
                Scheduler.sync(context)
                Wallpapers.refresh(context)
            } finally {
                pending.finish()
            }
        }.start()
    }
}

/** 輪換（也順便補換日夜時段）。 */
class RotationWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        Wallpapers.refresh(applicationContext)
        Scheduler.armPhaseAlarm(applicationContext)
        return Result.success()
    }
}

/** 每日 10 張＋日夜 AI 自動。 */
class DailyWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val ctx = applicationContext
        val env = AppEnv.get(ctx)
        if (env.prefs.dailyEnabled || DebugHooks.forceDaily(ctx)) {
            val r = Jobs.runDaily(ctx)
            r?.onFailure {
                // GenerationError 只記種類；其他程式錯誤記堆疊（不含提示詞、key）。
                if (it is GenerationError) Log.w(TAG, "daily batch stopped: ${it.kind}") else Log.w(TAG, "daily batch crashed", it)
            }
            r?.onSuccess { Log.i(TAG, "daily batch done: $it") }
            if (r?.isSuccess == true) Wallpapers.refresh(ctx)
        }
        if (env.prefs.dynamicAutoFrequency != DynamicAutoFrequency.OFF && Providers.canGenerate(ctx)) {
            Jobs.runDynamicAuto(ctx, manual = false)?.onFailure {
                Log.w(TAG, "dynamic auto stopped: ${(it as? GenerationError)?.kind ?: it.javaClass.simpleName}")
            }
        }
        return Result.success()
    }
}
