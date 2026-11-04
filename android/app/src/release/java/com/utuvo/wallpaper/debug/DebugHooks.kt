package com.utuvo.wallpaper.debug

import android.content.Context
import com.utuvo.wallpaper.core.ImageProvider

/** Release 版：沒有假 provider、沒有時間快轉、沒有網址覆寫。（Debug 版在 src/debug。） */
object DebugHooks {
    const val ENABLED = false
    fun clockOffsetMs(context: Context): Long = 0L
    fun fakeProvider(context: Context): ImageProvider? = null
    fun baseUrl(context: Context): String? = null
    fun forceDaily(context: Context): Boolean = false
}
