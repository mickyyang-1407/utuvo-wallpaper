package com.utuvo.wallpaper.platform

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.pm.ServiceInfo
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.work.CoroutineWorker
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.ForegroundInfo
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.OutOfQuotaPolicy
import androidx.work.WorkInfo
import androidx.work.WorkManager
import com.utuvo.wallpaper.core.AppPaths
import androidx.work.WorkerParameters
import com.utuvo.wallpaper.R
import com.utuvo.wallpaper.core.DailyRecipe
import com.utuvo.wallpaper.core.GenerationError
import com.utuvo.wallpaper.core.RetryPolicy

/**
 * 手動產生、自己描述的日夜場景、「現在用 AI 生成一組」：都交給這個 WorkManager 工作（expedited）。
 * 行程被系統回收或工作被系統停掉時 WorkManager 會重跑：手動產生只補剩下的張數、
 * 場景用同一個 id 續作（已付費的時段不重打）。
 * 不在 doWork 裡 setForeground：Android 16 實測行程被殺後系統重啟 SystemForegroundService
 * 會 ForegroundServiceDidNotStartInTimeException 閃退。前景資訊只給 Android 11 以下的 expedited 用。
 */
class GenerateWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {

    override suspend fun getForegroundInfo(): ForegroundInfo = foregroundInfo(0, 0)

    override suspend fun doWork(): Result {
        val ctx = applicationContext
        val kind = inputData.getString(KIND) ?: run { clearPending(ctx); return Result.failure() }
        Log.i(TAG, "generate start: $kind attempt=$runAttemptCount")
        // 每張之間檢查：被取消或被系統停掉就不再送新請求。
        val stop = { isStopped }
        val result: kotlin.Result<Int>? = when (kind) {
            "manual" -> {
                val recipe = DailyRecipe(inputData.getStringArray(STYLES)?.toList() ?: emptyList(), inputData.getString(IDEA) ?: "")
                val count = inputData.getInt(COUNT, 1)
                val day = inputData.getString(DAY) ?: AppPaths.dayString(AppClock.now(ctx))
                // 續作以檔案為準：檔名含工作 id 前 8 碼＋第幾張，已存在的直接沿用。
                val runID = inputData.getString(RUN_ID) ?: id.toString().take(8)
                Jobs.runManual(ctx, count, recipe, runID, day, stop) { d ->
                    Log.i(TAG, "generate progress: manual $d/$count")
                }
            }
            "scene" -> Jobs.runScene(ctx, inputData.getString(PROMPT) ?: "", inputData.getString(SCENE_ID), stop, userStarted = true)
                ?.map { Wallpapers.sceneReady(ctx); 4 }
            "auto" -> Jobs.runDynamicAuto(ctx, manual = true, isCancelled = stop, userStarted = true)?.map { 4 }
            else -> {
                // 未知種類（不該發生）：清掉續作紀錄，免得看門狗一直重排一個註定失敗的工作。
                Log.w(TAG, "generate: unknown kind")
                clearPending(ctx)
                return Result.failure()
            }
        }
        if (result == null) {
            Log.i(TAG, "generate busy, retry later")
            return Result.retry()
        }
        // 只認使用者按的取消（同一行程內的旗標）；看門狗重新排入造成的取消不算，照「被系統停掉」處理。
        if (isStopped && cancelRequested) {
            // 使用者按取消：不重跑、不算錯誤，介面顯示「已取消」。
            Log.i(TAG, "generate cancelled: $kind")
            Jobs.finished.value = kotlin.Result.failure(GenerationError.Cancelled)
            clearPending(ctx)
            return Result.failure()
        }
        if (isStopped || result.exceptionOrNull()?.let { RetryPolicy.isCancellation(it) } == true) {
            Log.i(TAG, "generate stopped by system, will resume")
            return Result.retry()
        }
        clearPending(ctx)
        result.onSuccess { Log.i(TAG, "generate done: $kind $it") }
            .onFailure { Log.w(TAG, "generate failed: $kind ${(it as? GenerationError)?.kind ?: it.javaClass.simpleName}") }
        Jobs.finished.value = result.map { (if (kind == "manual") "manual" else "scene") to it }
        return Result.success()
    }

    private fun foregroundInfo(done: Int, total: Int): ForegroundInfo {
        val ctx = applicationContext
        val nm = ctx.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CHANNEL, ctx.getString(R.string.generating_title), NotificationManager.IMPORTANCE_LOW))
        val n = NotificationCompat.Builder(ctx, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle(ctx.getString(R.string.generating_title))
            .setContentText(if (total > 0) ctx.getString(R.string.generating_progress, done, total) else null)
            .setProgress(total, done, total == 0)
            .setOngoing(true).setSilent(true).build()
        return ForegroundInfo(NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
    }

    companion object {
        const val UNIQUE = "generate"
        const val KIND = "kind"
        const val COUNT = "count"
        const val STYLES = "styles"
        const val IDEA = "idea"
        const val PROMPT = "prompt"
        const val SCENE_ID = "sceneID"
        const val DAY = "day"
        const val RUN_ID = "runID"
        const val WATCHDOG_MS = 120_000L
        /** 行程剛啟動時先跳過時，看門狗改排的短間隔。 */
        const val WATCHDOG_SHORT_MS = 30_000L
        private const val YOUNG_PROCESS_MS = 20_000L
        private const val PENDING = "gen.pending"

        /** Android 11 以下拿不到 stopReason：用這個旗標分辨「使用者取消」。 */
        @Volatile var cancelRequested = false
        private const val CHANNEL = "generate"
        private const val NOTIFICATION_ID = 41
        private const val TAG = "UTUVOWallpaper"

        /** 排一個生成工作；已有一個在跑或排隊（或每日批次正在跑）回 false。 */
        fun enqueue(context: Context, data: Data): Boolean {
            val wm = WorkManager.getInstance(context)
            val active = runCatching { wm.getWorkInfosForUniqueWork(UNIQUE).get() }.getOrDefault(emptyList())
                .any { !it.state.isFinished }
            if (active || Jobs.isBusy()) return false
            cancelRequested = false
            // 續作識別碼（檔名用）放在輸入資料裡：工作被重新排入時仍是同一個，已做完的檔案會被沿用。
            val full = Data.Builder().putAll(data).putString(RUN_ID, com.utuvo.wallpaper.core.RandomID.make()).build()
            AppEnv.get(context).raw.edit().putString(PENDING, android.util.Base64.encodeToString(full.toByteArray(), android.util.Base64.NO_WRAP)).commit()
            submit(wm, full, ExistingWorkPolicy.KEEP)
            armWatchdog(context)
            return true
        }

        /**
         * 看門狗鬧鐘（約 2 分鐘後，不精確）：行程被殺後鬧鐘仍在，會把 App 叫起來跑 [kick]。
         * 還有沒做完的產生就再排下一次；做完、取消後自然停止。
         */
        fun armWatchdog(context: Context, delayMs: Long = WATCHDOG_MS) {
            val am = context.getSystemService(android.app.AlarmManager::class.java)
            val pi = android.app.PendingIntent.getBroadcast(context, 8, android.content.Intent(context, GenerateWatchdogReceiver::class.java),
                android.app.PendingIntent.FLAG_UPDATE_CURRENT or android.app.PendingIntent.FLAG_IMMUTABLE)
            am.set(android.app.AlarmManager.ELAPSED_REALTIME_WAKEUP, android.os.SystemClock.elapsedRealtime() + delayMs, pi)
        }

        fun hasPending(context: Context) = AppEnv.get(context).raw.contains(PENDING)

        private fun submit(wm: WorkManager, data: Data, policy: ExistingWorkPolicy) {
            wm.enqueueUniqueWork(UNIQUE, policy, OneTimeWorkRequestBuilder<GenerateWorker>()
                .setInputData(data).setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST).build())
        }

        fun clearPending(context: Context) { AppEnv.get(context).raw.edit().remove(PENDING).commit() }

        /**
         * 保險：行程被殺後 WorkManager 與 JobScheduler 偶爾會互相取消，留下一個「排隊中但沒有排程」的工作
         * （Android 16 模擬器實測）。行程啟動後與輪換工作時檢查：還有沒做完的產生、而且不是正在跑，就用同一份輸入
         * （同一個續作識別碼）重新排入。已做完的張數靠檔案沿用，不會重付。
         */
        /** 回 true＝因為行程剛啟動而先跳過（看門狗改排短間隔再查）。 */
        fun kick(context: Context): Boolean {
            if (Jobs.isBusy()) return false
            // 行程剛起來時 WorkManager 自己會把沒做完的工作排回去並開始跑；先讓它處理，避免兩邊互相取消。
            if (android.os.SystemClock.uptimeMillis() - android.os.Process.getStartUptimeMillis() < YOUNG_PROCESS_MS) return true
            val wm = WorkManager.getInstance(context)
            val infos = runCatching { wm.getWorkInfosForUniqueWork(UNIQUE).get() }.getOrNull() ?: return false
            if (infos.any { it.state == WorkInfo.State.RUNNING }) return false
            val saved = AppEnv.get(context).raw.getString(PENDING, null)
            if (saved == null) {
                // 沒有輸入紀錄卻卡著一個排隊中的工作（舊版本留下的）：取消，免得之後永遠顯示「另一個生成作業正在進行」。
                if (infos.any { it.state == WorkInfo.State.ENQUEUED }) wm.cancelUniqueWork(UNIQUE)
                return false
            }
            // 全部都結束了而且是被取消的：使用者取消過，不再重排。
            if (infos.isNotEmpty() && infos.all { it.state.isFinished } && infos.any { it.state == WorkInfo.State.CANCELLED }) {
                clearPending(context); return false
            }
            val data = runCatching { Data.fromByteArray(android.util.Base64.decode(saved, android.util.Base64.NO_WRAP)) }.getOrNull()
                ?: run { clearPending(context); return false }
            Log.i(TAG, "generate kick: re-enqueue unfinished work")
            submit(wm, data, ExistingWorkPolicy.REPLACE)
            return false
        }
    }
}

/** 產生工作的看門狗：叫醒 App、必要時重新排入卡住的產生工作。 */
class GenerateWatchdogReceiver : android.content.BroadcastReceiver() {
    override fun onReceive(context: Context, intent: android.content.Intent) {
        val pending = goAsync()
        Thread {
            try {
                if (GenerateWorker.hasPending(context)) {
                    val skippedYoung = GenerateWorker.kick(context)
                    // 這次是看門狗把 App 冷啟動的，剛啟動先跳過：30 秒後再查一次，不要等 2 分鐘又冷啟動又跳過。
                    GenerateWorker.armWatchdog(context, if (skippedYoung) GenerateWorker.WATCHDOG_SHORT_MS else GenerateWorker.WATCHDOG_MS)
                    Log.i("UTUVOWallpaper", "generate watchdog: skippedYoung=$skippedYoung")
                }
            } finally {
                pending.finish()
            }
        }.start()
    }
}
