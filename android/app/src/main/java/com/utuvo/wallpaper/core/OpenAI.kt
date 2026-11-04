package com.utuvo.wallpaper.core

import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.io.IOException
import java.io.InterruptedIOException
import java.util.Base64
import java.util.UUID
import java.util.concurrent.TimeUnit

/**
 * 生成錯誤（與 iOS `GenerationError` 同名同義）。訊息只帶種類與狀態碼，絕不含 key、原始回應或 headers。
 * 介面文字由 B 段依 [kind]／[code] 查 strings.xml。
 */
sealed class GenerationError(val kind: String) : Exception(kind) {
    data object EmptyPrompt : GenerationError("emptyPrompt") { private fun readResolve(): Any = EmptyPrompt }
    data object MissingCredential : GenerationError("missingCredential") { private fun readResolve(): Any = MissingCredential }
    data object InvalidResponse : GenerationError("invalidResponse") { private fun readResolve(): Any = InvalidResponse }
    data class HttpStatus(val code: Int) : GenerationError("httpStatus") {
        override val message: String get() = "httpStatus $code"
    }
    data object Timeout : GenerationError("timeout") { private fun readResolve(): Any = Timeout }
    data object Transport : GenerationError("transport") { private fun readResolve(): Any = Transport }
    data object Decoding : GenerationError("decoding") { private fun readResolve(): Any = Decoding }
    data object WriteFailed : GenerationError("writeFailed") { private fun readResolve(): Any = WriteFailed }
    data object Cancelled : GenerationError("cancelled") { private fun readResolve(): Any = Cancelled }
    data object Cooldown : GenerationError("cooldown") { private fun readResolve(): Any = Cooldown }
    /** 上一次付費請求送出途中行程被中斷（結果不明）：不自動重送，免得同一張付兩次。 */
    data object Interrupted : GenerationError("interrupted") { private fun readResolve(): Any = Interrupted }
}

/** 重試規則（iOS `DailyBatch.isRetryable`＋每日批次冷卻）。 */
object RetryPolicy {
    /** 每張最多送幾次。 */
    const val MAX_ATTEMPTS = 3
    /** 第一次失敗後冷卻秒數。 */
    const val FIRST_COOLDOWN_SECONDS = 60L
    /** 之後（以及送出中當機）冷卻秒數。 */
    const val LATER_COOLDOWN_SECONDS = 300L

    /** 連線、逾時、429、5xx 可重試；其他不重試。 */
    fun isRetryable(error: Throwable): Boolean = when (error) {
        is GenerationError.Transport, is GenerationError.Timeout -> true
        is GenerationError.HttpStatus -> error.code == 429 || error.code in 500..599
        else -> false
    }

    /** 可重試或取消（背景被系統中斷）都算可續作。 */
    fun isResumable(error: Throwable): Boolean = isRetryable(error) || isCancellation(error)

    /** 使用者取消不顯示成錯誤。 */
    fun isCancellation(error: Throwable): Boolean =
        error is GenerationError.Cancelled || error is InterruptedException || error is java.util.concurrent.CancellationException

    /** 第 [attempts] 次失敗後要冷卻幾秒；不能再試回 null。 */
    fun cooldownSeconds(attempts: Int, resumable: Boolean): Long? =
        if (!resumable || attempts >= MAX_ATTEMPTS) null
        else if (attempts == 1) FIRST_COOLDOWN_SECONDS else LATER_COOLDOWN_SECONDS
}

/** 產生一張圖的抽象。正式用 [OpenAIImageProvider]；B 段的 Debug 假 provider 也實作這個。 */
interface ImageProvider {
    /** 回傳原生 PNG（阻塞呼叫，請在背景執行緒）。 */
    fun generateImage(prompt: String): ByteArray
    /** 用同一張參考圖只換光線（`/v1/images/edits`）。 */
    fun relight(reference: ByteArray, prompt: String): ByteArray
}

/**
 * OpenAI Images API（與 iOS 相同模型、直式尺寸、品質）。一次只送一個請求，不在這裡自動重試
 * （重試由每日批次的冷卻規則負責）。錯誤只帶狀態碼。
 */
class OpenAIImageProvider(
    private val apiKey: String,
    baseUrl: HttpUrl = DEFAULT_BASE.toHttpUrl(),
    client: OkHttpClient? = null,
) : ImageProvider {
    private val client: OkHttpClient = client ?: OkHttpClient.Builder()
        .connectTimeout(30, TimeUnit.SECONDS)
        .readTimeout(300, TimeUnit.SECONDS)
        .writeTimeout(300, TimeUnit.SECONDS)
        .callTimeout(900, TimeUnit.SECONDS)
        .retryOnConnectionFailure(false)
        .build()

    /** `v1/images/generations` 完整網址。 */
    val generationsUrl: HttpUrl = baseUrl.newBuilder().addPathSegments("v1/images/generations").build()
    /** `v1/images/edits` 完整網址。 */
    val editsUrl: HttpUrl = baseUrl.newBuilder().addPathSegments("v1/images/edits").build()

    /** 組生圖請求（JSON）。 */
    fun makeGenerationRequest(prompt: String): Request {
        val trimmed = validatePrompt(prompt)
        val body = JSONObject()
            .put("model", MODEL).put("prompt", trimmed).put("size", SIZE)
            .put("quality", QUALITY).put("n", 1).put("output_format", "png")
        return Request.Builder().url(generationsUrl)
            .header("Authorization", "Bearer $apiKey")
            .post(body.toString().toRequestBody("application/json".toMediaType()))
            .build()
    }

    /** 組換光線請求（multipart，參考圖欄位 `image[]`）。 */
    fun makeEditRequest(reference: ByteArray, prompt: String): Request {
        val trimmed = validatePrompt(prompt)
        val builder = MultipartBody.Builder("UTUVO-" + UUID.randomUUID().toString().uppercase()).setType(MultipartBody.FORM)
        for ((k, v) in listOf("model" to MODEL, "size" to SIZE, "quality" to QUALITY, "output_format" to "png", "n" to "1", "prompt" to trimmed)) {
            builder.addFormDataPart(k, v)
        }
        builder.addFormDataPart("image[]", "reference.png", reference.toRequestBody("image/png".toMediaType()))
        return Request.Builder().url(editsUrl)
            .header("Authorization", "Bearer $apiKey")
            .post(builder.build())
            .build()
    }

    override fun generateImage(prompt: String): ByteArray = send(makeGenerationRequest(prompt))

    override fun relight(reference: ByteArray, prompt: String): ByteArray = send(makeEditRequest(reference, prompt))

    private fun send(request: Request): ByteArray {
        val call = client.newCall(request)
        val (code, bytes) = try {
            call.execute().use { r -> r.code to (if (r.isSuccessful) r.body.bytes() else ByteArray(0)) }
        } catch (e: InterruptedIOException) {
            if (call.isCanceled() || Thread.currentThread().isInterrupted) throw GenerationError.Cancelled
            throw GenerationError.Timeout
        } catch (e: IOException) {
            if (call.isCanceled()) throw GenerationError.Cancelled
            throw GenerationError.Transport
        }
        if (code !in 200..299) throw GenerationError.HttpStatus(code)
        return extractImage(bytes)
    }

    /** 支援 b64_json 與 https url 兩種回應。 */
    fun extractImage(data: ByteArray): ByteArray {
        val first = try {
            JSONObject(String(data, Charsets.UTF_8)).getJSONArray("data").getJSONObject(0)
        } catch (e: Exception) {
            throw GenerationError.InvalidResponse
        }
        first.optString("b64_json", "").takeIf { it.isNotEmpty() }?.let {
            try { return Base64.getMimeDecoder().decode(it) } catch (e: IllegalArgumentException) { /* 換 url */ }
        }
        val url = first.optString("url", "")
        if (url.startsWith("https://")) {
            val req = Request.Builder().url(url).get().build()
            val call = client.newCall(req)
            try {
                call.execute().use { r ->
                    if (!r.isSuccessful) throw GenerationError.HttpStatus(r.code)
                    return r.body.bytes()
                }
            } catch (e: GenerationError) {
                throw e
            } catch (e: IOException) {
                throw GenerationError.Transport
            }
        }
        throw GenerationError.InvalidResponse
    }

    companion object {
        const val DEFAULT_BASE = "https://api.openai.com/"
        const val MODEL = "gpt-image-2"
        const val SIZE = "2160x3840"
        const val QUALITY = "high"

        /** 去頭尾空白；空的丟 [GenerationError.EmptyPrompt]。 */
        fun validatePrompt(prompt: String): String {
            val trimmed = SwiftText.trim(prompt)
            if (trimmed.isEmpty()) throw GenerationError.EmptyPrompt
            return trimmed
        }
    }
}
