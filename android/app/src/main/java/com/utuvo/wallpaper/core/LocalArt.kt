package com.utuvo.wallpaper.core

import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sin

/**
 * 純色與漸層桌布（Swift `LocalArt`）：本機畫、不送 AI、不需 key。
 * 規格寫在提示詞欄：`local:solid:#RRGGBB`、`local:gradient:#A,#B,#C|角度`。
 * 輸出 ARGB_8888 像素陣列（列優先、左上原點），B 段用 `Bitmap.createBitmap(pixels, w, h, ARGB_8888)` 轉圖。
 */
object LocalArt {
    const val PREFIX = "local:"

    /** 畫好的像素。 */
    class Image(val width: Int, val height: Int, val pixels: IntArray) {
        /** 取 (x, y) 的 ARGB（左上原點）。 */
        fun pixel(x: Int, y: Int): Int = pixels[y * width + x]
    }

    /** 是否是本機規格。 */
    fun isLocal(prompt: String): Boolean = prompt.startsWith(PREFIX)

    /** "#RRGGBB" → 0xFFRRGGBB；格式不對回 null。 */
    fun color(hex: String): Int? {
        val text = hex.trim(' ', '\t').replace("#", "")
        if (text.length != 6) return null
        val v = text.toIntOrNull(16) ?: return null
        if (text.startsWith("+") || text.startsWith("-")) return null
        return (0xFF shl 24) or v
    }

    /** 依規格畫一張；不是本機規格或格式錯誤回 null。 */
    fun render(spec: String, width: Int, height: Int): Image? {
        if (!isLocal(spec) || width <= 0 || height <= 0) return null
        val body = spec.removePrefix(PREFIX)
        val colon = body.indexOf(':')
        if (colon < 0) return null
        val kind = body.substring(0, colon)
        val arg = body.substring(colon + 1)
        val buf = FloatArray(width * height * 3)
        when (kind) {
            "solid" -> {
                val c = color(arg) ?: return null
                val rgb = floatArrayOf(r(c), g(c), b(c))
                for (i in 0 until width * height) { buf[i * 3] = rgb[0]; buf[i * 3 + 1] = rgb[1]; buf[i * 3 + 2] = rgb[2] }
                addGrain(buf, width, height, 0.012f)
            }
            "gradient" -> {
                val pieces = arg.split("|")
                val colors = pieces[0].split(",").mapNotNull { color(it) }
                if (colors.size < 2) return null
                val angle = (if (pieces.size > 1) pieces[1].trim().toDoubleOrNull() else null) ?: 135.0
                val radians = Math.toRadians(angle)
                val half = hypot(width.toDouble(), height.toDouble()) / 2
                // Core Graphics 原點在左下：dy 換到左上座標要反向。
                val dx = cos(radians) * half
                val dy = -sin(radians) * half
                val cx = width / 2.0
                val cy = height / 2.0
                val len2 = 4 * (dx * dx + dy * dy)
                val mid = colors[colors.size / 2]
                val glowX = width * 0.68
                val glowY = height * (1 - 0.62)
                val glowR = half * 0.9
                for (y in 0 until height) for (x in 0 until width) {
                    val px = x + 0.5 - (cx - dx)
                    val py = y + 0.5 - (cy - dy)
                    val t = ((px * 2 * dx + py * 2 * dy) / len2).coerceIn(0.0, 1.0)
                    val scaled = t * (colors.size - 1)
                    val i0 = min(scaled.toInt(), colors.size - 2)
                    val f = (scaled - i0).toFloat()
                    val a = colors[i0]; val c = colors[i0 + 1]
                    var rr = r(a) + (r(c) - r(a)) * f
                    var gg = g(a) + (g(c) - g(a)) * f
                    var bb = b(a) + (b(c) - b(a)) * f
                    // 一層柔光：中間色，透明度 0.45 → 0。
                    val d = hypot(x + 0.5 - glowX, y + 0.5 - glowY)
                    if (d < glowR) {
                        val alpha = (0.45 * (1 - d / glowR)).toFloat()
                        rr += (r(mid) - rr) * alpha; gg += (g(mid) - gg) * alpha; bb += (b(mid) - bb) * alpha
                    }
                    val o = (y * width + x) * 3
                    buf[o] = rr; buf[o + 1] = gg; buf[o + 2] = bb
                }
                addGrain(buf, width, height, 0.025f)
            }
            else -> return null
        }
        val pixels = IntArray(width * height) { i ->
            fun ch(v: Float) = (v.coerceIn(0f, 1f) * 255).roundToInt()
            (0xFF shl 24) or (ch(buf[i * 3]) shl 16) or (ch(buf[i * 3 + 1]) shl 8) or ch(buf[i * 3 + 2])
        }
        return Image(width, height, pixels)
    }

    private fun r(c: Int) = ((c shr 16) and 0xFF) / 255f
    private fun g(c: Int) = ((c shr 8) and 0xFF) / 255f
    private fun b(c: Int) = (c and 0xFF) / 255f

    /** 固定種子的細小亮暗點（overlay 混合），同一張每次畫都一樣。 */
    private fun addGrain(buf: FloatArray, width: Int, height: Int, strength: Float) {
        var seed = 0x9E3779B97F4A7C15uL
        val step = max(2, min(width, height) / 900)
        // Core Graphics 從底部那列開始畫，這裡同順序取亂數，結果與 Swift 版位置一致。
        var cgY = 0
        while (cgY < height) {
            var x = 0
            while (x < width) {
                seed = seed * 6364136223846793005uL + 1442695040888963407uL
                val v = ((seed shr 33) and 0xFFuL).toFloat() / 255
                for (yy in max(0, height - cgY - step) until height - cgY) for (xx in x until min(width, x + step)) {
                    val o = (yy * width + xx) * 3
                    for (k in 0..2) {
                        val base = buf[o + k]
                        val blended = if (base < 0.5f) 2 * base * v else 1 - 2 * (1 - base) * (1 - v)
                        buf[o + k] = base + (blended - base) * strength
                    }
                }
                x += step
            }
            cgY += step
        }
    }
}
