package com.utuvo.wallpaper.ui

import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.utuvo.wallpaper.R
import com.utuvo.wallpaper.core.GenerationError

/** 配色抄 iPhone 版 Style.swift（深色）：底色 #14171D、藍色主按鈕、白色 5% 卡片。 */
object Palette {
    val canvas = Color(0xFF14171D)
    val blueTop = Color(0xFF3B82F6)
    val blueBottom = Color(0xFF2563EB)
    val accent = blueTop
    val green = Color(0xFF30D158)
    val orange = Color(0xFFFF9F0A)
    val red = Color(0xFFFF453A)
    val pink = Color(0xFFFF375F)
    val cardFill = Color.White.copy(alpha = 0.05f)
    val cardStroke = Color.White.copy(alpha = 0.08f)
    val trackFill = Color.White.copy(alpha = 0.04f)
    val secondary = Color.White.copy(alpha = 0.6f)
    val glow = Color(0xFF2A3B5C).copy(alpha = 0.45f)

    /** 分類配色（TileStyle.category）。 */
    fun category(name: String): Color = when (name) {
        "自然" -> Color(0xFF30D158); "極簡" -> Color(0xFF8E8E93); "抽象" -> Color(0xFF7D5CFF)
        "插畫" -> Color(0xFFFF9F0A); "宇宙" -> Color(0xFF5E5CE6); "水彩" -> Color(0xFF40C8E0)
        "建築" -> Color(0xFFC9A26B); "動畫" -> Color(0xFFFF6482); "純色" -> Color(0xFF64D2FF)
        "漸層" -> Color(0xFFBF5AF2); "深色" -> Color(0xFF48484A); "幾何" -> Color(0xFF0A84FF)
        "城市" -> Color(0xFFFF453A); "動物" -> Color(0xFFA2845E); "3D" -> Color(0xFF5AC8FA)
        else -> Color(0xFF636366)
    }
}

@Composable
fun AppTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = darkColorScheme(
            primary = Palette.accent, onPrimary = Color.White, secondary = Palette.accent,
            background = Palette.canvas, surface = Color(0xFF1C2028), surfaceContainer = Color(0xFF1C2028),
            surfaceContainerHigh = Color(0xFF232833), surfaceContainerLow = Color(0xFF181B22),
            onSurface = Color.White, onBackground = Color.White, onSurfaceVariant = Palette.secondary,
            secondaryContainer = Palette.accent.copy(alpha = 0.25f), onSecondaryContainer = Color.White,
            outline = Palette.cardStroke, error = Palette.red,
        ),
    ) {
        androidx.compose.runtime.CompositionLocalProvider(androidx.compose.material3.LocalContentColor provides Color.White, content = content)
    }
}

/** 底色＋頂部淡藍光暈。 */
fun Modifier.canvasBackground(): Modifier = this
    .background(Palette.canvas)
    .background(Brush.radialGradient(listOf(Palette.glow, Color.Transparent), center = androidx.compose.ui.geometry.Offset(540f, 0f), radius = 1400f))

/** 圓角玻璃卡片。 */
@Composable
fun GlassCard(modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
    val shape = RoundedCornerShape(18.dp)
    Column(modifier.clip(shape).background(Palette.cardFill).border(1.dp, Palette.cardStroke, shape).padding(16.dp), content = content)
}

/** 彩色圓角方塊（內放一個字）。 */
@Composable
fun IconTile(label: String, color: Color, size: Dp = 30.dp) {
    Box(Modifier.size(size).clip(RoundedCornerShape(size * 0.26f))
        .background(Brush.verticalGradient(listOf(color.copy(alpha = 0.85f), color))), contentAlignment = Alignment.Center) {
        Text(label, color = Color.White, fontSize = (size.value * 0.42f).sp, fontWeight = FontWeight.SemiBold)
    }
}

/** 介面文字：core 繁中 key → 目前語言；錯誤 → 訊息。 */
object Strings {
    fun isChinese(context: Context): Boolean = context.resources.configuration.locales[0].language == "zh"

    fun core(context: Context, zh: String): String {
        CORE_KEYS[zh]?.let { return context.getString(it) }
        if (zh.startsWith("HTTP ")) return zh
        return zh
    }

    fun phase(context: Context, raw: String): String = context.getString(when (raw) {
        "dawn" -> R.string.phase_dawn; "day" -> R.string.phase_day; "dusk" -> R.string.phase_dusk; else -> R.string.phase_night
    })

    fun error(context: Context, e: Throwable): String = when (e) {
        is GenerationError.EmptyPrompt -> context.getString(R.string.err_empty_prompt)
        is GenerationError.MissingCredential -> context.getString(R.string.err_missing_key)
        is GenerationError.InvalidResponse -> context.getString(R.string.err_invalid_response)
        is GenerationError.HttpStatus -> when {
            e.code == 400 -> context.getString(R.string.err_http_400)
            e.code == 401 || e.code == 403 -> context.getString(R.string.err_http_auth, e.code)
            e.code == 429 -> context.getString(R.string.err_http_429)
            e.code in 500..599 -> context.getString(R.string.err_http_5xx, e.code)
            else -> context.getString(R.string.err_http_other, e.code)
        }
        is GenerationError.Timeout -> context.getString(R.string.err_timeout)
        is GenerationError.Transport -> context.getString(R.string.err_transport)
        is GenerationError.Decoding -> context.getString(R.string.err_decoding)
        is GenerationError.WriteFailed -> context.getString(R.string.err_write)
        is GenerationError.Cancelled -> context.getString(R.string.err_cancelled)
        is GenerationError.Cooldown -> context.getString(R.string.err_cooldown)
        is GenerationError.Interrupted -> context.getString(R.string.err_interrupted)
        else -> context.getString(R.string.err_generic)
    }
}
