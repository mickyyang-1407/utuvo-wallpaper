package com.utuvo.wallpaper.ui

import android.app.Application
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Environment
import android.provider.MediaStore
import android.util.LruCache
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.setValue
import androidx.compose.foundation.layout.Box
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.core.content.FileProvider
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.utuvo.wallpaper.R
import com.utuvo.wallpaper.core.CurrentWallpaper
import com.utuvo.wallpaper.core.DailyRecipe
import com.utuvo.wallpaper.core.GalleryFilter
import com.utuvo.wallpaper.core.GenerationLog
import com.utuvo.wallpaper.core.RetryPolicy
import com.utuvo.wallpaper.core.WallpaperItem
import com.utuvo.wallpaper.core.WallpaperTitles
import com.utuvo.wallpaper.platform.AppClock
import com.utuvo.wallpaper.platform.AppEnv
import com.utuvo.wallpaper.platform.Jobs
import com.utuvo.wallpaper.platform.Scheduler
import com.utuvo.wallpaper.platform.Wallpapers
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

/** 介面狀態（iOS AppModel 的 Android 版）。 */
class AppModel(app: Application) : AndroidViewModel(app) {
    private val ctx: Context get() = getApplication()
    val env = AppEnv.get(app)

    var items by mutableStateOf<List<WallpaperItem>>(emptyList()); private set
    var titles by mutableStateOf<Map<String, String>>(emptyMap()); private set
    var favorites by mutableStateOf(env.prefs.favorites); private set
    var pinnedID by mutableStateOf(env.prefs.pinnedID); private set
    var dynamicEnabled by mutableStateOf(env.prefs.dynamicEnabled); private set
    var filter by mutableStateOf<GalleryFilter>(GalleryFilter.All)
    var message by mutableStateOf<String?>(null)
    /** 進大圖頁時圖庫的篩選結果（左右滑的清單）。 */
    var detailIDs: List<String> = emptyList()
    /** 每次 reload 加一，讓縮圖重讀。 */
    var revision by mutableStateOf(0); private set

    fun reload() {
        viewModelScope.launch {
            val loaded = withContext(Dispatchers.IO) { Wallpapers.items(ctx) }
            val zh = Strings.isChinese(ctx)
            val fmt = if (zh) DateTimeFormatter.ofPattern("M/d") else DateTimeFormatter.ofPattern("MMM d", Locale.ENGLISH)
            titles = WallpaperTitles.titles(env.data, loaded, ZoneId.systemDefault(), { Strings.core(ctx, it) }, { d: LocalDate -> d.format(fmt) })
            items = loaded
            favorites = env.prefs.favorites
            pinnedID = env.prefs.pinnedID
            dynamicEnabled = env.prefs.dynamicEnabled
            revision++
        }
    }

    fun title(item: WallpaperItem) = titles[item.id] ?: item.fileName

    private fun current() = CurrentWallpaper(env.data, env.paths, env.prefs)

    fun toggleFavorite(item: WallpaperItem) { current().toggleFavorite(item); favorites = env.prefs.favorites }

    fun togglePin(item: WallpaperItem) {
        val (_, turnedOff) = current().togglePin(item)
        pinnedID = env.prefs.pinnedID
        dynamicEnabled = env.prefs.dynamicEnabled
        if (turnedOff) message = ctx.getString(R.string.pinned_dynamic_off)
        viewModelScope.launch(Dispatchers.IO) { Scheduler.sync(ctx); Wallpapers.refresh(ctx) }
    }

    fun delete(item: WallpaperItem) {
        current().delete(item)
        items = items.filter { it.id != item.id }
        favorites = env.prefs.favorites
        pinnedID = env.prefs.pinnedID
    }

    fun setAsWallpaper(item: WallpaperItem) {
        viewModelScope.launch {
            val (ok, turnedOff) = withContext(Dispatchers.IO) { Wallpapers.setItem(ctx, item) }
            pinnedID = env.prefs.pinnedID
            dynamicEnabled = env.prefs.dynamicEnabled
            message = ctx.getString(when {
                !ok -> R.string.wallpaper_failed
                turnedOff -> R.string.wallpaper_changed_dynamic_off
                else -> R.string.wallpaper_changed
            })
        }
    }

    fun applyDynamic() {
        viewModelScope.launch {
            val phase = withContext(Dispatchers.IO) { Wallpapers.applyDynamic(ctx) }
            dynamicEnabled = env.prefs.dynamicEnabled
            pinnedID = env.prefs.pinnedID
            message = if (phase != null) ctx.getString(R.string.applied_dynamic, Strings.phase(ctx, phase.raw))
            else ctx.getString(R.string.wallpaper_failed)
        }
    }

    fun toggleDynamic(on: Boolean) {
        env.prefs.dynamicEnabled = on
        dynamicEnabled = on
        viewModelScope.launch(Dispatchers.IO) { Scheduler.sync(ctx); Wallpapers.refresh(ctx) }
    }

    fun saveToPhotos(item: WallpaperItem) {
        viewModelScope.launch {
            val ok = withContext(Dispatchers.IO) {
                runCatching {
                    val file = Wallpapers.deviceFile(ctx, item) ?: return@runCatching false
                    val values = ContentValues().apply {
                        put(MediaStore.Images.Media.DISPLAY_NAME, "UTUVO-" + item.fileName.substringBeforeLast('.') + ".jpg")
                        put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
                        put(MediaStore.Images.Media.RELATIVE_PATH, Environment.DIRECTORY_PICTURES + "/UTUVO Wallpaper")
                    }
                    val uri = ctx.contentResolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values) ?: return@runCatching false
                    ctx.contentResolver.openOutputStream(uri)?.use { out -> file.inputStream().use { it.copyTo(out) } } != null
                }.getOrDefault(false)
            }
            message = ctx.getString(if (ok) R.string.saved_photos else R.string.save_failed)
        }
    }

    fun shareIntent(item: WallpaperItem): Intent? {
        val file = Wallpapers.deviceFile(ctx, item) ?: return null
        val uri = FileProvider.getUriForFile(ctx, ctx.packageName + ".files", file)
        return Intent.createChooser(Intent(Intent.ACTION_SEND).setType("image/jpeg").putExtra(Intent.EXTRA_STREAM, uri)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION), null)
    }

    /** 手動產生。回傳 null＝已開始；否則是錯誤訊息。 */
    fun startManual(count: Int, recipe: DailyRecipe): String? {
        val r = recipe.sanitized(env.data)
        env.prefs.saveRecipe(env.data, r, DailyRecipe.MANUAL_PREFIX)
        if (!r.isLocalOnly(env.data) && !com.utuvo.wallpaper.platform.Providers.canGenerate(ctx)) return ctx.getString(R.string.need_key)
        return if (Jobs.launchManual(ctx, count, r)) null else ctx.getString(R.string.busy)
    }

    /** 背景作業完成的訊息。 */
    fun consumeFinished() {
        val r = Jobs.finished.value ?: return
        Jobs.finished.value = null
        reload()
        r.onSuccess { (kind, n) -> if (kind == "manual") message = ctx.getString(R.string.done_n, n) }
            .onFailure { e -> if (!RetryPolicy.isCancellation(e)) message = Strings.error(ctx, e) }
    }

    fun runDailyIfNeeded() {
        if (env.prefs.dailyEnabled || env.prefs.dynamicAutoFrequency.raw != "off") Scheduler.runDailyNow(ctx)
    }

    fun summary() = GenerationLog.summary(GenerationLog.load(env.paths), 7, AppClock.nowMs(ctx))
}

/** 縮圖快取（依檔案路徑＋最長邊）。 */
object Thumbs {
    private val cache = object : LruCache<String, Bitmap>(64 * 1024 * 1024) {
        override fun sizeOf(key: String, value: Bitmap) = value.byteCount
    }

    fun load(file: File, maxPixel: Int): Bitmap? {
        val key = "${file.path}#$maxPixel#${file.lastModified()}"
        cache.get(key)?.let { return it }
        val o = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.path, o)
        var sample = 1
        while (maxOf(o.outWidth, o.outHeight) / (sample * 2) >= maxPixel) sample *= 2
        val bm = BitmapFactory.decodeFile(file.path, BitmapFactory.Options().apply { inSampleSize = sample }) ?: return null
        cache.put(key, bm)
        return bm
    }
}

/** 非同步載入的圖（含示範圖）。 */
@Composable
fun WallpaperImage(context: Context, item: WallpaperItem?, maxPixel: Int, modifier: Modifier, file: File? = null,
                   scale: ContentScale = ContentScale.Crop, revision: Int = 0) {
    val image by produceState<ImageBitmap?>(null, item?.id, file?.path, revision) {
        value = withContext(Dispatchers.IO) {
            val f = file ?: item?.let { Wallpapers.deviceFile(context, it) }
            f?.let { Thumbs.load(it, maxPixel)?.asImageBitmap() }
        }
    }
    val img = image
    if (img != null) Image(img, contentDescription = null, modifier = modifier, contentScale = scale)
    else Box(modifier.background(Palette.trackFill))
}
