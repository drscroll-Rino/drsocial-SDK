package com.drsocial.sdk

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.Base64
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLPeerUnverifiedException

/** One answer: status, headers (lower-case names) and the body exactly as received (the config's signature covers it). */
class SdkResponse(val status: Int, val body: String, val headers: Map<String, String> = emptyMap()) {
    val json by lazy { parseObject(body) }
}

/** The SDK's only way out. Throws an [IOException] on no network. */
interface SdkHttp {
    suspend fun send(method: String, url: String, body: String? = null, headers: Map<String, String> = emptyMap()): SdkResponse
}

/**
 * The JDK / Android HttpURLConnection: no cookie, nothing but what the SDK writes. When [pins] gives SPKI SHA-256 pins
 * ("sha256/<base64>") and [pinned] says the call is pinned, the server's chain must hold one of them before anything is
 * sent; the signed config itself is read unpinned, so a wrong pin can never lock an app out of the config that fixes it.
 */
class UrlConnectionHttp(
    private val timeoutMs: Int = 15_000,
    private val pins: () -> List<String> = { emptyList() },
    private val pinned: (String) -> Boolean = { !it.endsWith("/config") },
) : SdkHttp {
    override suspend fun send(method: String, url: String, body: String?, headers: Map<String, String>): SdkResponse = withContext(Dispatchers.IO) {
        val conn = URL(url).openConnection() as HttpURLConnection
        try {
            conn.requestMethod = method
            conn.connectTimeout = timeoutMs
            conn.readTimeout = timeoutMs
            conn.useCaches = false
            conn.instanceFollowRedirects = false
            conn.setRequestProperty("accept", "application/json")
            headers.forEach { (k, v) -> conn.setRequestProperty(k, v) }
            if (body != null) {
                conn.doOutput = true
                conn.setRequestProperty("content-type", "application/json; charset=utf-8")
            }
            conn.connect()
            val wanted = pins()
            if (conn is HttpsURLConnection && wanted.isNotEmpty() && pinned(url)) checkPins(conn, wanted)
            if (body != null) conn.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
            val status = conn.responseCode
            val stream = if (status >= 400) conn.errorStream else conn.inputStream
            val text = stream?.use { it.readBytes().toString(Charsets.UTF_8) } ?: ""
            val h = conn.headerFields.filterKeys { it != null }.map { (k, v) -> k.lowercase() to v.joinToString(",") }.toMap()
            SdkResponse(status, text, h)
        } finally {
            conn.disconnect()
        }
    }

    companion object {
        /** "sha256/<base64>" of a certificate's SubjectPublicKeyInfo. */
        fun pinOf(spki: ByteArray): String = "sha256/" + Base64.getEncoder().encodeToString(MessageDigest.getInstance("SHA-256").digest(spki))

        internal fun checkPins(conn: HttpsURLConnection, wanted: List<String>) {
            val seen = conn.serverCertificates.map { pinOf(it.publicKey.encoded) }
            if (seen.none { it in wanted }) {
                conn.disconnect()
                throw SSLPeerUnverifiedException("pin_mismatch")
            }
        }
    }
}
