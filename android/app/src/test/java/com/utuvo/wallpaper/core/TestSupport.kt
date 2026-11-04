package com.utuvo.wallpaper.core

import java.io.File
import java.nio.file.Files as NioFiles

/** 測試共用：資料、假影像、暫存資料夾。 */
object TestSupport {
    val data: PromptData get() = GoldenTest.data

    /** 只有檔頭的假 PNG（[ImageHeaders] 讀得到寬高）。 */
    fun png(w: Int, h: Int): ByteArray {
        val b = ByteArray(33)
        byteArrayOf(0x89.toByte(), 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A).copyInto(b)
        "IHDR".toByteArray().copyInto(b, 12)
        for (i in 0..3) { b[16 + i] = (w ushr (24 - 8 * i)).toByte(); b[20 + i] = (h ushr (24 - 8 * i)).toByte() }
        return b
    }

    /** 只有 SOF0 的假 JPEG。 */
    fun jpeg(w: Int, h: Int): ByteArray = byteArrayOf(
        0xFF.toByte(), 0xD8.toByte(), 0xFF.toByte(), 0xC0.toByte(), 0, 17, 8,
        (h shr 8).toByte(), h.toByte(), (w shr 8).toByte(), w.toByte(), 3, 0, 0, 0, 0, 0)

    /** 假 codec：讀檔頭、裁切回傳目標尺寸的假 JPEG。 */
    class FakeCodec : ImageCodec {
        var crops = 0
        var pngs = 0
        override fun pixelSize(bytes: ByteArray) = ImageHeaders.pixelSize(bytes)
        override fun cropToJpeg(bytes: ByteArray, targetW: Int, targetH: Int): ByteArray {
            pixelSize(bytes) ?: throw GenerationError.Decoding
            crops++
            return jpeg(targetW, targetH)
        }
        override fun encodePng(image: LocalArt.Image): ByteArray { pngs++; return png(image.width, image.height) }
    }

    /** 可程式化的假 provider：依序回傳結果或丟錯。 */
    class ScriptedProvider(vararg script: Any) : ImageProvider {
        val queue = ArrayDeque(script.toList())
        val prompts = mutableListOf<String>()
        val relights = mutableListOf<String>()
        var fallback: Any = png(1024, 1536)
        private fun next(): ByteArray = when (val v = queue.removeFirstOrNull() ?: fallback) {
            is ByteArray -> v
            is Throwable -> throw v
            else -> error("bad script")
        }
        override fun generateImage(prompt: String): ByteArray { prompts += prompt; return next() }
        override fun relight(reference: ByteArray, prompt: String): ByteArray { relights += prompt; return next() }
    }

    /** 新的暫存資料夾。 */
    fun tempDir(): File = NioFiles.createTempDirectory("utuvo-wp-test").toFile().apply { deleteOnExit() }
}
