package com.utuvo.wallpaper.platform

import android.content.Context
import android.content.SharedPreferences
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Rect
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import android.util.DisplayMetrics
import android.view.WindowManager
import com.utuvo.wallpaper.core.AppPaths
import com.utuvo.wallpaper.core.CropMath
import com.utuvo.wallpaper.core.GenerationError
import com.utuvo.wallpaper.core.ImageCodec
import com.utuvo.wallpaper.core.KeyValueStore
import com.utuvo.wallpaper.core.LocalArt
import com.utuvo.wallpaper.core.PromptData
import com.utuvo.wallpaper.debug.DebugHooks
import java.io.ByteArrayOutputStream
import java.io.File
import java.security.KeyStore
import java.time.Instant
import java.time.ZoneId
import java.time.ZonedDateTime
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** [ImageCodec] 的 Android 實作（BitmapFactory／Bitmap.compress）。 */
object BitmapCodec : ImageCodec {
    override fun pixelSize(bytes: ByteArray): Pair<Int, Int>? {
        val o = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, o)
        return if (o.outWidth > 0 && o.outHeight > 0) o.outWidth to o.outHeight else null
    }

    override fun cropToJpeg(bytes: ByteArray, targetW: Int, targetH: Int): ByteArray {
        val bitmap = cropToBitmap(bytes, targetW, targetH) ?: throw GenerationError.Decoding
        return try { jpeg(bitmap) } finally { bitmap.recycle() }
    }

    override fun encodePng(image: LocalArt.Image): ByteArray {
        val bitmap = Bitmap.createBitmap(image.pixels, image.width, image.height, Bitmap.Config.ARGB_8888)
        val out = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
        bitmap.recycle()
        return out.toByteArray()
    }

    /** JPEG 品質 0.92。 */
    fun jpeg(bitmap: Bitmap): ByteArray {
        val out = ByteArrayOutputStream()
        if (!bitmap.compress(Bitmap.CompressFormat.JPEG, 92, out)) throw GenerationError.Decoding
        return out.toByteArray()
    }

    /** aspect-fill 置中裁切＋縮放；大圖先用 inSampleSize 降採樣省記憶體。 */
    fun cropToBitmap(bytes: ByteArray, targetW: Int, targetH: Int): Bitmap? {
        val (w, h) = pixelSize(bytes) ?: return null
        val r = CropMath.aspectFillSourceRect(w, h, targetW, targetH)
        if (r.width <= 0 || r.height <= 0) return null
        var sample = 1
        while (r.width / (sample * 2) >= targetW && r.height / (sample * 2) >= targetH) sample *= 2
        val src = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, BitmapFactory.Options().apply { inSampleSize = sample })
            ?: return null
        val sx = src.width.toDouble() / w
        val sy = src.height.toDouble() / h
        val srcRect = Rect((r.x * sx).toInt(), (r.y * sy).toInt(), ((r.x + r.width) * sx).toInt(), ((r.y + r.height) * sy).toInt())
        val out = Bitmap.createBitmap(targetW, targetH, Bitmap.Config.ARGB_8888)
        Canvas(out).drawBitmap(src, srcRect, Rect(0, 0, targetW, targetH), Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG))
        src.recycle()
        return out
    }
}

/** [KeyValueStore] 的 SharedPreferences 實作（字串陣列存成換行分隔）。 */
class SharedPrefsStore(private val sp: SharedPreferences) : KeyValueStore {
    override fun getString(key: String): String? = sp.getString(key, null)
    override fun putString(key: String, value: String?) = sp.edit().apply { if (value == null) remove(key) else putString(key, value) }.apply()
    override fun getStringList(key: String): List<String>? =
        sp.getString("list.$key", null)?.let { s -> if (s.isEmpty()) emptyList() else s.split('\n') }
    override fun putStringList(key: String, value: List<String>?) =
        sp.edit().apply { if (value == null) remove("list.$key") else putString("list.$key", value.joinToString("\n")) }.apply()
    override fun getLong(key: String): Long? = if (sp.contains(key)) sp.getLong(key, 0) else null
    override fun putLong(key: String, value: Long?) = sp.edit().apply { if (value == null) remove(key) else putLong(key, value) }.apply()
    override fun getBoolean(key: String): Boolean? = if (sp.contains(key)) sp.getBoolean(key, false) else null
    override fun putBoolean(key: String, value: Boolean?) = sp.edit().apply { if (value == null) remove(key) else putBoolean(key, value) }.apply()
}

/**
 * OpenAI API key：AES-GCM 加密，金鑰放 Android Keystore（不可匯出）。只存密文；
 * 介面永遠不回填 key 本身，只問「有沒有」。
 */
class ApiKeyStore(context: Context) {
    private val sp = context.getSharedPreferences("credential", Context.MODE_PRIVATE)

    val hasKey: Boolean get() = sp.contains(CIPHER)

    /** 驗格式：不能空、不能有空白或非 ASCII。 */
    fun isValid(raw: String): Boolean {
        val k = raw.trim()
        return k.isNotEmpty() && k.all { it.code in 0x21..0x7E }
    }

    fun save(raw: String): Boolean {
        val k = raw.trim()
        if (!isValid(k)) return false
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, secret()) }
        val enc = cipher.doFinal(k.toByteArray())
        sp.edit().putString(CIPHER, Base64.encodeToString(enc, Base64.NO_WRAP))
            .putString(IV, Base64.encodeToString(cipher.iv, Base64.NO_WRAP)).apply()
        return true
    }

    fun load(): String? = runCatching {
        val enc = Base64.decode(sp.getString(CIPHER, null) ?: return null, Base64.NO_WRAP)
        val iv = Base64.decode(sp.getString(IV, null) ?: return null, Base64.NO_WRAP)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.DECRYPT_MODE, secret(), GCMParameterSpec(128, iv)) }
        String(cipher.doFinal(enc))
    }.getOrNull()

    fun remove() { sp.edit().remove(CIPHER).remove(IV).apply() }

    private fun secret(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getEntry(ALIAS, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        gen.init(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256).build())
        return gen.generateKey()
    }

    private companion object {
        const val ALIAS = "utuvo-wallpaper-openai"
        const val CIPHER = "openai.cipher"
        const val IV = "openai.iv"
    }
}

/** 時間來源。Release 永遠是系統時間；Debug 可用廣播加偏移量快轉。 */
object AppClock {
    fun nowMs(context: Context): Long = System.currentTimeMillis() + DebugHooks.clockOffsetMs(context)
    fun now(context: Context): ZonedDateTime = Instant.ofEpochMilli(nowMs(context)).atZone(ZoneId.systemDefault())
    /** App 時間 → 系統真實時間（排鬧鐘用）。 */
    fun realMs(context: Context, appMs: Long): Long = appMs - DebugHooks.clockOffsetMs(context)
}

/** 裝置螢幕原生直式像素。 */
object DeviceScreen {
    fun nativePixels(context: Context): Pair<Int, Int> {
        val wm = context.getSystemService(WindowManager::class.java)
        val (w, h) = if (Build.VERSION.SDK_INT >= 30) {
            wm.maximumWindowMetrics.bounds.let { it.width() to it.height() }
        } else {
            @Suppress("DEPRECATION")
            DisplayMetrics().also { wm.defaultDisplay.getRealMetrics(it) }.let { it.widthPixels to it.heightPixels }
        }
        return CropMath.portraitPixels(w, h)
    }
}

/** App 共用的資料與路徑（行程內單例）。 */
class AppEnv private constructor(val context: Context) {
    val data: PromptData = PromptData.parse(context.assets.open("prompts.json").bufferedReader().use { it.readText() })
    val paths = AppPaths(File(context.filesDir, "UTUVO Wallpaper"))
    val prefs = com.utuvo.wallpaper.core.Preferences(SharedPrefsStore(context.getSharedPreferences("prefs", Context.MODE_PRIVATE)))
    val keys = ApiKeyStore(context)
    val raw: SharedPreferences = context.getSharedPreferences("app", Context.MODE_PRIVATE)

    companion object {
        /** 示範圖（assets/wallpapers）。 */
        val DEMO_NAMES = listOf("paper-landscape-demo-5k.jpg")
        @Volatile private var instance: AppEnv? = null
        fun get(context: Context): AppEnv = instance ?: synchronized(this) {
            instance ?: AppEnv(context.applicationContext).also { instance = it }
        }
    }
}
