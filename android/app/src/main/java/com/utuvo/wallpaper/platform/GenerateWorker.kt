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
import androidx.work.WorkManager
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
        val kind = inputData.getString(KIND) ?: return Result.failure()
        Log.i(TAG, "generate start: $kind attempt=$runAttemptCount")
        val doneKey = "gen.done.$id"
        val raw = AppEnv.get(ctx).raw
        val result: kotlin.Result<Int>? = when (kind) {
            "manual" -> {
                val recipe = DailyRecipe(inputData.getStringArray(STYLES)?.toList() ?: emptyList(), inputData.getString(IDEA) ?: "")
                val count = inputData.getInt(COUNT, 1)
                val already = raw.getInt(doneKey, 0)
                if (already > 0) Log.i(TAG, "generate resume: manual $already/$count already done")
                Jobs.runManual(ctx, count, recipe, already) { d ->
                    raw.edit().putInt(doneKey, d).commit()
                    Log.i(TAG, "generate progress: manual $d/$count")
                }
            }
            "scene" -> Jobs.runScene(ctx, inputData.getString(PROMPT) ?: "", inputData.getString(SCENE_ID))
                ?.map { Wallpapers.sceneReady(ctx); 4 }
            "auto" -> Jobs.runDynamicAuto(ctx, manual = true)?.map { 4 }
            else -> return Result.failure()
        }
        if (result == null) {
            Log.i(TAG, "generate busy, retry later")
            return Result.retry()
        }
        if (isStopped || result.exceptionOrNull()?.let { RetryPolicy.isCancellation(it) } == true) {
            Log.i(TAG, "generate stopped, will resume")
            return Result.retry()
        }
        raw.edit().remove(doneKey).apply()
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
        private const val CHANNEL = "generate"
        private const val NOTIFICATION_ID = 41
        private const val TAG = "UTUVOWallpaper"

        /** 排一個生成工作；已有一個在跑或排隊（或每日批次正在跑）回 false。 */
        fun enqueue(context: Context, data: Data): Boolean {
            val wm = WorkManager.getInstance(context)
            val active = runCatching { wm.getWorkInfosForUniqueWork(UNIQUE).get() }.getOrDefault(emptyList())
                .any { !it.state.isFinished }
            if (active || Jobs.isBusy()) return false
            wm.enqueueUniqueWork(UNIQUE, ExistingWorkPolicy.KEEP, OneTimeWorkRequestBuilder<GenerateWorker>()
                .setInputData(data).setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST).build())
            return true
        }
    }
}
