package com.utuvo.wallpaper.core

import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.SocketEffect
import okhttp3.OkHttpClient
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import java.util.Base64
import java.util.concurrent.TimeUnit

/** 用本機假伺服器測請求格式、錯誤對應與重試規則。全程假 key，不連 OpenAI。 */
class OpenAITest {
    private val fakeKey = "sk-test-FAKE-0000"
    private lateinit var server: MockWebServer
    private lateinit var provider: OpenAIImageProvider
    private val png = TestSupport.png(2160, 3840)

    @Before fun setUp() {
        server = MockWebServer()
        server.start()
        val client = OkHttpClient.Builder().readTimeout(1, TimeUnit.SECONDS).callTimeout(5, TimeUnit.SECONDS).build()
        provider = OpenAIImageProvider(fakeKey, server.url("/"), client)
    }

    @After fun tearDown() { server.close() }

    private fun ok(bytes: ByteArray = png) =
        MockResponse.Builder().code(200).body("""{"data":[{"b64_json":"${Base64.getEncoder().encodeToString(bytes)}"}]}""").build()

    @Test fun generationRequestFormat() {
        server.enqueue(ok())
        val out = provider.generateImage("  a calm lake  ")
        assertArrayEquals(png, out)
        val r = server.takeRequest()
        assertEquals("POST", r.method)
        assertEquals("/v1/images/generations", r.url.encodedPath)
        assertEquals("Bearer $fakeKey", r.headers["Authorization"])
        assertTrue(r.headers["Content-Type"]!!.startsWith("application/json"))
        val body = JSONObject(r.body!!.utf8())
        assertEquals("gpt-image-2", body.getString("model"))
        assertEquals("a calm lake", body.getString("prompt"))
        assertEquals("2160x3840", body.getString("size"))
        assertEquals("high", body.getString("quality"))
        assertEquals(1, body.getInt("n"))
        assertEquals("png", body.getString("output_format"))
        assertEquals(setOf("model", "prompt", "size", "quality", "n", "output_format"), body.keys().asSequence().toSet())
    }

    @Test fun editRequestIsMultipartWithImageArray() {
        server.enqueue(ok())
        val reference = TestSupport.png(10, 20)
        provider.relight(reference, ScenePrompt.relight("night"))
        val r = server.takeRequest()
        assertEquals("/v1/images/edits", r.url.encodedPath)
        assertEquals("Bearer $fakeKey", r.headers["Authorization"])
        val type = r.headers["Content-Type"]!!
        assertTrue(type, type.startsWith("multipart/form-data; boundary=UTUVO-"))
        val boundary = type.substringAfter("boundary=")
        val text = r.body!!.string(Charsets.ISO_8859_1)
        for ((k, v) in listOf("model" to "gpt-image-2", "size" to "2160x3840", "quality" to "high", "output_format" to "png", "n" to "1")) {
            assertTrue(k, text.contains("Content-Disposition: form-data; name=\"$k\"\r\n") && text.contains("\r\n\r\n$v\r\n"))
        }
        assertTrue(text.contains("Content-Disposition: form-data; name=\"prompt\""))
        assertTrue(r.body!!.utf8().contains(ScenePrompt.relight("night")))
        assertTrue(text.contains("Content-Disposition: form-data; name=\"image[]\"; filename=\"reference.png\""))
        assertTrue(text.contains("Content-Type: image/png"))
        assertTrue(text.contains(String(reference, Charsets.ISO_8859_1)))
        assertTrue(text.trimEnd().endsWith("--$boundary--"))
        // 欄位順序與 iOS 相同：model、size、quality、output_format、n、prompt、image[]
        val order = listOf("model", "size", "quality", "output_format", "n", "prompt", "image[]").map { text.indexOf("name=\"$it\"") }
        assertEquals(order.sorted(), order)
    }

    @Test fun emptyPromptNeverSends() {
        try { provider.generateImage(" \n\t "); fail() } catch (e: GenerationError.EmptyPrompt) { }
        try { provider.relight(png, ""); fail() } catch (e: GenerationError.EmptyPrompt) { }
        assertEquals(0, server.requestCount)
    }

    @Test fun httpStatusMappingAndRetryability() {
        val cases = mapOf(400 to false, 401 to false, 403 to false, 404 to false, 429 to true, 500 to true, 502 to true, 503 to true, 599 to true)
        for ((code, retryable) in cases) {
            server.enqueue(MockResponse.Builder().code(code).body("""{"error":{"message":"secret detail $fakeKey"}}""").build())
            try {
                provider.generateImage("x"); fail("$code")
            } catch (e: GenerationError.HttpStatus) {
                assertEquals(code, e.code)
                assertEquals("$code", retryable, RetryPolicy.isRetryable(e))
                assertNoLeak(e)
            }
        }
    }

    @Test fun timeoutAndTransportMapping() {
        server.enqueue(MockResponse.Builder().code(200).body("{}").bodyDelay(3, TimeUnit.SECONDS).build())
        try { provider.generateImage("x"); fail() } catch (e: GenerationError) {
            assertEquals(GenerationError.Timeout, e); assertTrue(RetryPolicy.isRetryable(e)); assertNoLeak(e)
        }
        server.enqueue(MockResponse.Builder().onRequestStart(SocketEffect.CloseSocket()).build())
        try { provider.generateImage("x"); fail() } catch (e: GenerationError) {
            assertEquals(GenerationError.Transport, e); assertTrue(RetryPolicy.isRetryable(e)); assertNoLeak(e)
        }
        val closed = OpenAIImageProvider(fakeKey, server.url("/"), OkHttpClient())
        server.close()
        try { closed.generateImage("x"); fail() } catch (e: GenerationError) { assertEquals(GenerationError.Transport, e) }
    }

    @Test fun invalidResponses() {
        for (body in listOf("not json", "{}", """{"data":[]}""", """{"data":[{"url":"http://insecure/x.png"}]}""", """{"data":[{}]}""")) {
            server.enqueue(MockResponse.Builder().code(200).body(body).build())
            try { provider.generateImage("x"); fail(body) } catch (e: GenerationError) {
                assertEquals(body, GenerationError.InvalidResponse, e); assertFalse(RetryPolicy.isRetryable(e))
            }
        }
    }

    @Test fun cancelledCallMapsToCancelled() {
        assertTrue(RetryPolicy.isCancellation(GenerationError.Cancelled))
        assertTrue(RetryPolicy.isResumable(GenerationError.Cancelled))
        assertFalse(RetryPolicy.isRetryable(GenerationError.Cancelled))
    }

    @Test fun retryPolicyCooldowns() {
        assertEquals(3, RetryPolicy.MAX_ATTEMPTS)
        assertEquals(60L, RetryPolicy.cooldownSeconds(1, true))
        assertEquals(300L, RetryPolicy.cooldownSeconds(2, true))
        assertNull(RetryPolicy.cooldownSeconds(3, true))
        assertNull(RetryPolicy.cooldownSeconds(1, false))
        for (e in listOf(GenerationError.Decoding, GenerationError.InvalidResponse, GenerationError.MissingCredential,
            GenerationError.EmptyPrompt, GenerationError.WriteFailed, GenerationError.Cooldown, RuntimeException("x"))) {
            assertFalse(e.toString(), RetryPolicy.isRetryable(e))
        }
    }

    @Test fun urlsUseBase() {
        val p = OpenAIImageProvider(fakeKey)
        assertEquals("https://api.openai.com/v1/images/generations", p.generationsUrl.toString())
        assertEquals("https://api.openai.com/v1/images/edits", p.editsUrl.toString())
    }

    private fun assertNoLeak(e: Throwable) {
        val text = listOfNotNull(e.message, e.toString(), e.localizedMessage, e.cause?.toString()).joinToString(" ")
        assertFalse(text, text.contains(fakeKey))
        assertFalse(text, text.contains("secret detail"))
        assertFalse(text, text.contains("Authorization"))
    }
}
