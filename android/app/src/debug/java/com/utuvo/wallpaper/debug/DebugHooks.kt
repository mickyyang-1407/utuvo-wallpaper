package com.utuvo.wallpaper.debug

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Shader
import android.util.Log
import com.utuvo.wallpaper.core.AppPaths
import com.utuvo.wallpaper.core.DailyGenerationService
import com.utuvo.wallpaper.core.ImageProvider
import com.utuvo.wallpaper.core.OpenAIImageProvider
import com.utuvo.wallpaper.core.StableHash
import com.utuvo.wallpaper.platform.AppClock
import com.utuvo.wallpaper.platform.AppEnv
import com.utuvo.wallpaper.platform.Scheduler
import com.utuvo.wallpaper.platform.Wallpapers
import java.io.ByteArrayOutputStream

/**
 * Debug 專用（只在 src/debug，Release 不會編進去）：假 provider、時間快轉、網址覆寫。
 * 用 adb 驅動：`adb shell am broadcast -n com.utuvo.wallpaper/.debug.DebugReceiver --es cmd <指令> ...`
 */
object DebugHooks {
    const val ENABLED = true
    private fun sp(context: Context) = context.getSharedPreferences("debug", Context.MODE_PRIVATE)

    fun clockOffsetMs(context: Context): Long = sp(context).getLong("offset", 0L)
    fun fakeProvider(context: Context): ImageProvider? = if (sp(context).getBoolean("fake", false)) FakeProvider else null
    fun baseUrl(context: Context): String? = sp(context).getString("baseUrl", null)
    fun forceDaily(context: Context): Boolean = sp(context).getBoolean("forceDaily", false)

    internal fun edit(context: Context) = sp(context).edit()
}

/** 不連網：依提示詞雜湊畫一張 1152×2048 漸層 PNG；relight 把參考圖染色。 */
object FakeProvider : ImageProvider {
    override fun generateImage(prompt: String): ByteArray {
        val p = OpenAIImageProvider.validatePrompt(prompt)
        Thread.sleep(150)
        val h = StableHash.of(p)
        val c1 = Color.HSVToColor(floatArrayOf((h % 360u).toFloat(), 0.55f, 0.85f))
        val c2 = Color.HSVToColor(floatArrayOf(((h shr 12) % 360u).toFloat(), 0.7f, 0.35f))
        val bm = Bitmap.createBitmap(1152, 2048, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bm)
        canvas.drawPaint(Paint().apply { shader = LinearGradient(0f, 0f, 1152f, 2048f, c1, c2, Shader.TileMode.CLAMP) })
        val dot = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.argb(90, 255, 255, 255) }
        canvas.drawCircle(((h shr 24) % 1152u).toFloat(), ((h shr 36) % 2048u).toFloat(), 260f, dot)
        return png(bm)
    }

    override fun relight(reference: ByteArray, prompt: String): ByteArray {
        val p = OpenAIImageProvider.validatePrompt(prompt)
        Thread.sleep(150)
        val src = BitmapFactory.decodeByteArray(reference, 0, reference.size) ?: throw IllegalStateException()
        val bm = src.copy(Bitmap.Config.ARGB_8888, true)
        src.recycle()
        val tint = when {
            p.contains("night", true) -> Color.argb(150, 10, 20, 60)
            p.contains("dusk", true) || p.contains("sunset", true) -> Color.argb(110, 230, 110, 40)
            else -> Color.argb(90, 255, 200, 160)
        }
        Canvas(bm).drawColor(tint)
        return png(bm)
    }

    private fun png(bm: Bitmap): ByteArray {
        val out = ByteArrayOutputStream()
        bm.compress(Bitmap.CompressFormat.PNG, 100, out)
        bm.recycle()
        return out.toByteArray()
    }
}

/** adb 指令入口（需要 DUMP 權限＝只有 adb shell 能送）。 */
class DebugReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val cmd = intent.getStringExtra("cmd") ?: return
        val pending = goAsync()
        Thread {
            try { handle(context.applicationContext, cmd, intent) } catch (e: Exception) {
                Log.w(TAG, "debug $cmd failed: ${e.javaClass.simpleName}")
            } finally { pending.finish() }
        }.start()
    }

    private fun handle(context: Context, cmd: String, intent: Intent) {
        val env = AppEnv.get(context)
        when (cmd) {
            "fake" -> DebugHooks.edit(context).putBoolean("fake", intent.getBooleanExtra("on", true)).commit()
            "forceDaily" -> DebugHooks.edit(context).putBoolean("forceDaily", intent.getBooleanExtra("on", true)).commit()
            "offset" -> { DebugHooks.edit(context).putLong("offset", intent.getLongExtra("ms", 0L)).commit(); Scheduler.sync(context) }
            // 把 App 時間快轉到「下一個時段開始前 N 秒」，再排鬧鐘：到點由 AlarmManager 自己觸發。
            "jumpBeforeNextPhase" -> {
                val lead = intent.getLongExtra("leadSec", 60L)
                val now = AppClock.now(context)
                val next = env.prefs.schedule(env.data, now).next(now) ?: return
                val target = next.at.toInstant().toEpochMilli() - lead * 1000
                val offset = clockOffsetAdd(context, target - AppClock.nowMs(context))
                Log.i(TAG, "debug jump: next=${next.phase.raw} offset=$offset")
                Scheduler.sync(context)
            }
            "runDaily" -> Scheduler.runDailyNow(context)
            "refresh" -> Wallpapers.refresh(context, intent.getBooleanExtra("force", false))
            "applyDynamic" -> Wallpapers.applyDynamic(context)
            "dump" -> {
                val day = AppPaths.dayString(AppClock.now(context))
                Log.i(TAG, "debug state: appNow=${AppClock.now(context)} lastApplied=${Wallpapers.lastApplied(context)} " +
                    "dynamic=${env.prefs.dynamicEnabled} pinned=${env.prefs.pinnedID} " +
                    "phaseAlarmAt=${env.raw.getLong("phaseAlarmAt", -1)} phase=${env.raw.getString("phaseAlarmPhase", null)} " +
                    "daily=${DailyGenerationService.status(env.paths, day)} items=${Wallpapers.items(context).size}")
            }
        }
        Log.i(TAG, "debug cmd done: $cmd")
    }

    private fun clockOffsetAdd(context: Context, delta: Long): Long {
        val v = DebugHooks.clockOffsetMs(context) + delta
        DebugHooks.edit(context).putLong("offset", v).commit()
        return v
    }

    private companion object { const val TAG = "UTUVOWallpaper" }
}
