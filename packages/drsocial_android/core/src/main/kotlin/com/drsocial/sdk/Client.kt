package com.drsocial.sdk

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.JsonObject
import org.bouncycastle.crypto.params.Ed25519PublicKeyParameters
import org.bouncycastle.crypto.signers.Ed25519Signer
import java.security.KeyPair
import java.security.PrivateKey
import java.security.PublicKey
import java.security.SecureRandom
import java.security.Signature
import java.time.Instant
import java.util.Base64

/** Where the SDK keeps its few values between runs (the last config, the device id, its epoch, flags). */
interface SdkStore {
    fun read(name: String): String?
    fun write(name: String, value: String?)
}

class MemorySdkStore : SdkStore {
    val values = mutableMapOf<String, String>()
    override fun read(name: String): String? = values[name]
    override fun write(name: String, value: String?) {
        if (value == null) values.remove(name) else values[name] = value
    }
}

/**
 * The device's own P-256 key, made and kept by the platform (the Android Keystore); it never leaves the device. The core
 * only asks for the public half and a signature.
 */
interface DeviceSigner {
    /** Base64 DER SubjectPublicKeyInfo. */
    suspend fun publicKey(): String

    /** Base64 DER ECDSA-SHA256 over [message]. */
    suspend fun sign(message: ByteArray): String
}

/** A [DeviceSigner] over any JCA P-256 key pair (the Android Keystore's, or a test's). */
class JcaDeviceSigner(private val private: PrivateKey, private val public: PublicKey) : DeviceSigner {
    constructor(pair: KeyPair) : this(pair.private, pair.public)

    override suspend fun publicKey(): String = Base64.getEncoder().encodeToString(public.encoded)

    override suspend fun sign(message: ByteArray): String {
        val s = Signature.getInstance("SHA256withECDSA")
        s.initSign(private)
        s.update(message)
        return Base64.getEncoder().encodeToString(s.sign())
    }
}

/** A proof from the store that this is the real app (Play Integrity: `{kind: play_integrity, token}`), made for a nonce. */
typealias AttestationMaker = suspend (nonce: String) -> Map<String, String>?

/**
 * The phone (or its person) is stopped by the company: show a full-screen block with [message] and stop; ask the config
 * again only on the next start.
 */
class SdkBanned(
    /** The company's words to show ('' = the SDK's own short default). */
    override val message: String,
    /** When the stop ends; null = until the company lifts it. */
    val until: Instant?,
) : Exception(message)

class SdkFailure(val code: String, val status: Int = 0) : Exception("SdkFailure($code, $status)")

/** Speaks API v1 for one store build: the signed config, the device's registration and its short token. */
class DrSocialClient(
    /** The build's public key (32 hex), from Settings → Mobile app. */
    val buildKey: String,
    val installId: String,
    /**
     * The platform's Ed25519 public keys this release trusts, {"v1": base64}. Empty = the config is not checked (only for a
     * company whose platform has no signing key yet).
     */
    val trustedKeys: Map<String, String>,
    val base: String = "https://social.drscroll.com/api/v1",
    http: SdkHttp? = null,
    val store: SdkStore = MemorySdkStore(),
    val os: String = "",
    val appVersion: String = "",
    /** The phone's own id that survives deleting the app (Android `ANDROID_ID`); only its hash is kept. */
    val hardwareId: String? = null,
    private val now: () -> Instant = Instant::now,
) {
    @Volatile
    var config: SdkConfig = SdkConfig.EMPTY
        private set

    val http: SdkHttp = http ?: UrlConnectionHttp(pins = { config.pins })

    private var signer: DeviceSigner? = null
    private var attest: AttestationMaker? = null
    private var token: String? = null
    private var tokenUntil: Instant = Instant.EPOCH
    private val tokenLock = Mutex()

    /** The device's key and the store proof every call after [refresh] uses ([authed]). */
    fun use(signer: DeviceSigner, attest: AttestationMaker? = null) {
        this.signer = signer
        this.attest = attest
    }

    /**
     * Reads the config. A signature that does not check, or no network, keeps the last good answer; an unknown key turns
     * everything off and forgets it.
     */
    suspend fun refresh(): SdkConfig {
        if (config.raw.isEmpty()) store.read("config")?.let { config = SdkConfig.parse(it) }
        val res = try {
            http.send("GET", "$base/sdk/$buildKey/config", headers = token?.let { mapOf("authorization" to "Bearer $it") } ?: emptyMap())
        } catch (e: Exception) {
            if (e is SdkBanned) throw e
            return config
        }
        banned(res)
        if (res.status == 404) {
            config = SdkConfig.EMPTY
            store.write("config", null)
            return config
        }
        if (res.status != 200 || !verify(res.body, res.headers["x-drs-signature"])) return config
        config = SdkConfig.parse(res.body)
        store.write("config", res.body)
        return config
    }

    /** Whether [body] carries a good signature from a trusted key (`v1:<base64>`). */
    fun verify(body: String, header: String?): Boolean {
        if (trustedKeys.isEmpty()) return true
        if (header == null) return false
        val i = header.indexOf(':')
        if (i < 1) return false
        val key = trustedKeys[header.substring(0, i)] ?: return false
        return try {
            val v = Ed25519Signer()
            v.init(false, Ed25519PublicKeyParameters(Base64.getDecoder().decode(key), 0))
            val bytes = body.toByteArray(Charsets.UTF_8)
            v.update(bytes, 0, bytes.size)
            v.verifySignature(Base64.getDecoder().decode(header.substring(i + 1)))
        } catch (_: Exception) {
            false
        }
    }

    /** Registers the device (again when the key generation moved), with a store proof when [attest] is given. */
    suspend fun register(signer: DeviceSigner, attest: AttestationMaker? = null): String {
        val kept = store.read("device")
        val keptEpoch = store.read("epoch")?.toIntOrNull() ?: 0
        if (kept != null && keptEpoch >= config.epoch) return kept
        val body = mutableMapOf<String, Any?>("install_id" to installId, "public_key" to signer.publicKey(), "os" to os, "app_version" to appVersion)
        if (hardwareId != null) body["hardware_id"] = hardwareId
        if (attest != null) {
            val c = http.send("GET", "$base/sdk/$buildKey/challenge")
            c.json.str("nonce")?.let { nonce ->
                body["nonce"] = nonce
                body["attestation"] = attest(nonce)
            }
        }
        val res = http.send("POST", "$base/sdk/$buildKey/devices", toJson(body).toString())
        banned(res)
        if (res.status != 201) throw SdkFailure(res.json.str("error") ?: "register_failed", res.status)
        val id = res.json.str("device_id") ?: throw SdkFailure("register_failed", res.status)
        store.write("device", id)
        store.write("epoch", (res.json.num("epoch")?.toInt() ?: 1).toString())
        return id
    }

    /** The device id the platform gave this installation, once registered. */
    val deviceId: String? get() = store.read("device")

    /** A short token for the calls, asked again a minute before it ends. On `re_register` the device registers again once. */
    suspend fun token(signer: DeviceSigner, attest: AttestationMaker? = null): String = tokenLock.withLock {
        val t = now()
        token?.let { if (t.isBefore(tokenUntil.minusSeconds(60))) return it }
        for (attempt in 0 until 2) {
            val device = register(signer, attest)
            val time = (t.toEpochMilli() / 1000).toString()
            val nonce = randomHex(16)
            val message = tokenMessage(buildKey, device, time, nonce).toByteArray(Charsets.UTF_8)
            val body = mapOf("device_id" to device, "time" to time, "nonce" to nonce, "signature" to signer.sign(message))
            val res = http.send("POST", "$base/sdk/$buildKey/token", toJson(body).toString())
            banned(res)
            if (res.status == 200) {
                val tok = res.json.str("token") ?: throw SdkFailure("token_failed", res.status)
                token = tok
                tokenUntil = t.plusSeconds(res.json.num("expires_in")?.toLong() ?: 900)
                return tok
            }
            if (res.json.str("error") == "re_register" && attempt == 0) {
                store.write("device", null)
                continue
            }
            throw SdkFailure(res.json.str("error") ?: "token_failed", res.status)
        }
        throw SdkFailure("token_failed")
    }

    /**
     * A call made with the device's token ([use] first). A token that ended or a device the platform no longer knows is
     * fixed once (a new token, or registering again); a stopped phone throws [SdkBanned].
     */
    suspend fun authed(method: String, path: String, body: Any? = null): SdkResponse {
        val signer = this.signer ?: throw SdkFailure("no_signer")
        for (attempt in 0 until 2) {
            val t = token(signer, attest)
            val res = http.send(method, "$base/sdk/$buildKey/$path", body?.let { toJson(it).toString() }, mapOf("authorization" to "Bearer $t"))
            banned(res)
            val error = res.json.str("error")
            if (res.status == 401 && attempt == 0 && (error == "token_required" || error == "re_register")) {
                tokenLock.withLock { token = null }
                if (error == "re_register") store.write("device", null)
                continue
            }
            return res
        }
        throw SdkFailure("token_failed")
    }

    private fun banned(res: SdkResponse) {
        if (res.status != 403 || res.json.str("error") != "device_banned") return
        token = null
        throw SdkBanned(res.json.str("message") ?: "", parseTime(res.json.str("until")))
    }

    internal fun ok(res: SdkResponse): JsonObject {
        if (res.status in 200..299) return res.json
        throw SdkFailure(res.json.str("error") ?: "http_${res.status}", res.status)
    }

    companion object {
        /** What the device signs to get a token (API.md): `drs-token\n{key}\n{device}\n{time}\n{nonce}`. */
        fun tokenMessage(key: String, device: String, time: String, nonce: String) = "drs-token\n$key\n$device\n$time\n$nonce"

        private val random = SecureRandom()

        internal fun randomHex(bytes: Int): String {
            val b = ByteArray(bytes)
            random.nextBytes(b)
            return b.joinToString("") { "%02x".format(it) }
        }
    }
}
