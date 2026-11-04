package com.utuvo.wallpaper

import android.Manifest
import android.app.WallpaperManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.drawable.BitmapDrawable
import android.util.Log
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipeLeft
import androidx.compose.ui.test.swipeRight
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.utuvo.wallpaper.core.PortraitPrompt
import com.utuvo.wallpaper.platform.AppEnv
import com.utuvo.wallpaper.platform.Wallpapers
import com.utuvo.wallpaper.ui.MainActivity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.security.MessageDigest

/**
 * 模擬器自測（前提：已用 Debug 廣播跑完假 provider 每日批次，圖庫至少 3 張）。
 * 只讀寫這個 App 自己的資料與桌布。
 */
@RunWith(AndroidJUnit4::class)
class DeviceTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
    private val ctx get() = InstrumentationRegistry.getInstrumentation().targetContext

    /** core 的直式轉換在 Android regex 上也能跑（JVM 測試抓不到 ICU 差異）。 */
    @Test fun portraitPromptRunsOnAndroid() {
        val out = PortraitPrompt.convert("A wide 16:9 desktop wallpaper of hills.")
        assertTrue(out, out.startsWith("A vertical 9:16 iPhone wallpaper"))
    }

    /** 設為桌布後 WallpaperManager 讀回來的像素＝那張圖的像素。 */
    @Test fun setWallpaperReadsBackSamePixels() {
        val items = Wallpapers.items(ctx).filter { !it.isDemo }
        assertTrue("need generated items", items.size >= 3)
        val item = items[1]
        val (ok, _) = Wallpapers.setItem(ctx, item)
        assertTrue(ok)
        val expected = BitmapFactory.decodeFile(Wallpapers.deviceFile(ctx, item)!!.path)
        val ui = InstrumentationRegistry.getInstrumentation().uiAutomation
        ui.adoptShellPermissionIdentity()
        val back: Bitmap = try {
            (WallpaperManager.getInstance(ctx).getDrawable(WallpaperManager.FLAG_SYSTEM) as BitmapDrawable).bitmap
        } finally { ui.dropShellPermissionIdentity() }
        Log.i("UTUVOWallpaperTest", "item=${item.id} expected=${expected.width}x${expected.height} ${hash(expected)} " +
            "readback=${back.width}x${back.height} ${hash(back)}")
        assertEquals(expected.width, back.width)
        assertEquals(expected.height, back.height)
        assertEquals(hash(expected), hash(back))
        assertEquals(item.id, AppEnv.get(ctx).prefs.pinnedID)
    }

    /** 大圖頁：左滑 1→2、右滑 2→1、第一張再右滑仍是 1。 */
    @Test fun detailPagerSwipes() {
        val first = Wallpapers.items(ctx).first()
        val total = Wallpapers.items(ctx).size
        compose.waitForIdle()
        compose.onNodeWithTag("card-${first.id}").performClick()
        compose.waitForIdle()
        fun page(): String {
            compose.waitForIdle()
            val node = compose.onNodeWithTag("page-count").fetchSemanticsNode()
            return node.config.getOrNull(SemanticsProperties.Text)!!.joinToString { it.text }
        }
        val seen = mutableListOf(page())
        compose.onNodeWithTag("detail-pager").performTouchInput { swipeLeft() }
        seen += page()
        compose.onNodeWithTag("detail-pager").performTouchInput { swipeRight() }
        seen += page()
        compose.onNodeWithTag("detail-pager").performTouchInput { swipeRight() }
        seen += page()
        Log.i("UTUVOWallpaperTest", "pager pages: $seen (total $total)")
        val fmt = { n: Int -> ctx.getString(R.string.page_count, n, total) }
        assertEquals(listOf(fmt(1), fmt(2), fmt(1), fmt(1)), seen)
    }

    private fun useFakeProvider() {
        // Debug 版才有假 provider（src/debug 的 DebugHooks 讀這個偏好）。
        ctx.getSharedPreferences("debug", android.content.Context.MODE_PRIVATE).edit()
            .putBoolean("fake", true).putLong("fakeDelayMs", 50L).commit()
    }

    /** 新場景生成完、日夜沒開：只換場景 id，不開日夜、不換桌布（跟 iPhone 一樣）。 */
    @Test fun sceneReadyDoesNotTurnOnDynamic() {
        useFakeProvider()
        val prefs = AppEnv.get(ctx).prefs
        prefs.dynamicEnabled = false
        val before = Wallpapers.lastApplied(ctx)
        val id = "scene-test-off"
        val r = com.utuvo.wallpaper.platform.Jobs.runScene(ctx, "a quiet harbor", id)!!
        assertTrue(r.exceptionOrNull()?.toString(), r.isSuccess)
        assertEquals(null, Wallpapers.sceneReady(ctx))
        assertEquals(id, prefs.dynamicSceneID)
        assertEquals(false, prefs.dynamicEnabled)
        assertEquals(before, Wallpapers.lastApplied(ctx))
    }

    /** 日夜本來就開著（使用者按過套用）：新場景完成就換成新場景目前時段。 */
    @Test fun sceneReadyRefreshesWhenDynamicOn() {
        useFakeProvider()
        val prefs = AppEnv.get(ctx).prefs
        assertTrue(Wallpapers.applyDynamic(ctx) != null)
        val id = "scene-test-on"
        val r = com.utuvo.wallpaper.platform.Jobs.runScene(ctx, "a mountain lake", id)!!
        assertTrue(r.exceptionOrNull()?.toString(), r.isSuccess)
        val key = Wallpapers.sceneReady(ctx)
        Log.i("UTUVOWallpaperTest", "sceneReady on: $key")
        assertTrue("$key", key != null && key.startsWith("dynamic:$id:"))
        assertEquals(true, prefs.dynamicEnabled)
        assertEquals(key, Wallpapers.lastApplied(ctx))
    }

    /** exported 的 BootReceiver 收到別的 action 直接忽略（沒走到 goAsync，否則這裡會丟例外／閃退）。 */
    @Test fun bootReceiverIgnoresForeignActions() {
        com.utuvo.wallpaper.platform.BootReceiver().onReceive(ctx, android.content.Intent("com.example.EVIL"))
        com.utuvo.wallpaper.platform.BootReceiver().onReceive(ctx, android.content.Intent())
    }

    /** 工作輸入缺 kind 或 kind 不認得：回 failure 並清掉續作紀錄（不然看門狗會一直重排）。 */
    @Test fun generateWorkerClearsPendingOnBadInput() {
        val raw = AppEnv.get(ctx).raw
        for (input in listOf(androidx.work.Data.EMPTY, androidx.work.workDataOf("kind" to "bogus"))) {
            raw.edit().putString("gen.pending", "x").commit()
            assertTrue(com.utuvo.wallpaper.platform.GenerateWorker.hasPending(ctx))
            val worker = androidx.work.testing.TestListenableWorkerBuilder<com.utuvo.wallpaper.platform.GenerateWorker>(ctx)
                .setInputData(input).build()
            val result = kotlinx.coroutines.runBlocking { worker.doWork() }
            assertEquals(androidx.work.ListenableWorker.Result.failure(), result)
            assertEquals(false, com.utuvo.wallpaper.platform.GenerateWorker.hasPending(ctx))
        }
    }

    private fun hash(b: Bitmap): String {
        val px = IntArray(b.width * b.height)
        b.getPixels(px, 0, b.width, 0, 0, b.width, b.height)
        val md = MessageDigest.getInstance("SHA-256")
        val buf = java.nio.ByteBuffer.allocate(px.size * 4)
        buf.asIntBuffer().put(px)
        return md.digest(buf.array()).joinToString("") { "%02x".format(it) }.take(16)
    }

    @Suppress("unused") private val perm = Manifest.permission.SET_WALLPAPER
}
