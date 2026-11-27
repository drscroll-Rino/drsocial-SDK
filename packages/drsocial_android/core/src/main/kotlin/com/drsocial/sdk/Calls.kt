package com.drsocial.sdk

import kotlinx.serialization.json.JsonObject
import java.time.Instant

/** One event the app tracks (`POST /sdk/{key}/track`). [id] is made once and sent again on a retry, so it is kept once. */
class SdkEvent(
    val name: String,
    /** ≤ 20 plain values (text, numbers, true/false); never personal data. */
    val props: Map<String, Any?> = emptyMap(),
    val at: Instant = Instant.now(),
    val id: String = newSdkId(),
) {
    fun toMap(): Map<String, Any?> = buildMap {
        put("id", id)
        put("name", name)
        put("at", at.toString())
        if (props.isNotEmpty()) put("props", props)
    }
}

/** One frame of a crash's stack, as the runtime gives it (R8-obfuscated names are mapped back on the server). */
class SdkFrame(val fn: String, val file: String? = null, val line: Int? = null, val lib: String? = null, val offset: String? = null) {
    fun toMap(): Map<String, Any?> = buildMap {
        put("fn", fn)
        file?.let { put("file", it) }
        line?.let { put("line", it) }
        lib?.let { put("lib", it) }
        offset?.let { put("offset", it) }
    }
}

/** A crash to report (on the next launch for a fatal one). Never put personal data in [message]. */
class SdkCrash(
    /** fatal · non_fatal · anr. */
    val kind: String,
    val type: String,
    val frames: List<SdkFrame>,
    val message: String? = null,
    val appVersion: String? = null,
    val osVersion: String? = null,
    val screen: String? = null,
    val at: Instant = Instant.now(),
    val id: String = newSdkId(),
) {
    fun toMap(): Map<String, Any?> = buildMap {
        put("id", id)
        put("at", at.toString())
        put("kind", kind)
        put("type", type)
        message?.let { put("message", it) }
        put("frames", frames.take(40).map { it.toMap() })
        appVersion?.let { put("app_version", it) }
        osVersion?.let { put("os_version", it) }
        screen?.let { put("screen", it) }
    }

    companion object {
        /** A crash written by [toMap] (kept on disk until sent). */
        fun parse(text: String): SdkCrash = from(parseObject(text))

        fun from(j: JsonObject) = SdkCrash(
            kind = j.str("kind") ?: "fatal",
            type = j.str("type") ?: "Error",
            frames = j.arr("frames").filterIsInstance<JsonObject>().map {
                SdkFrame(it.str("fn") ?: "?", it.str("file"), it.num("line")?.toInt(), it.str("lib"), it.str("offset"))
            },
            message = j.str("message"),
            appVersion = j.str("app_version"),
            osVersion = j.str("os_version"),
            screen = j.str("screen"),
            at = parseTime(j.str("at")) ?: Instant.now(),
            id = j.str("id") ?: newSdkId(),
        )
    }
}

/** What the store-review question answered: [ask] = open the store's own review box now. */
class ReviewAnswer(
    val ask: Boolean,
    /** off · asked_recently · too_new · too_few_sessions · no_event · recent_crash (when [ask] is false). */
    val reason: String = "",
)

/**
 * A link that opened a screen after a first install: open [link] as if it had been tapped. [likely] = matched by the
 * network within 2 hours, not by the store's referrer.
 */
class DeferredLink(val code: String, val link: String, val likely: Boolean = false)

/** A random id the platform accepts (8–64 of A–Z a–z 0–9 _ -): 24 hex characters. */
fun newSdkId(): String = DrSocialClient.randomHex(12)

/** Links the device to the company's own user. [identityHash] = hex HMAC-SHA256(server key secret, externalId), made on the company's server. */
suspend fun DrSocialClient.identify(
    externalId: String,
    identityHash: String? = null,
    traits: Map<String, Any?>? = null,
    analytics: Boolean? = null,
    messages: Boolean? = null,
    locale: String? = null,
    country: String? = null,
    /** name, email, phone; kept only with [identityHash]. */
    profile: Map<String, String>? = null,
): String? {
    val body = buildMap<String, Any?> {
        put("external_id", externalId)
        identityHash?.let { put("identity_hash", it) }
        traits?.let { put("traits", it) }
        if (analytics != null || messages != null) put("consent", buildMap { analytics?.let { put("analytics", it) }; messages?.let { put("messages", it) } })
        locale?.let { put("locale", it) }
        country?.let { put("country", it) }
        profile?.let { put("profile", it) }
    }
    return ok(authed("POST", "identify", body)).str("user")
}

suspend fun DrSocialClient.signOut() {
    ok(authed("POST", "sign-out", emptyMap<String, Any?>()))
}

/** Sends the events in batches of 100; answers how many were kept (0 while the person said no to analytics). */
suspend fun DrSocialClient.track(events: List<SdkEvent>): Int {
    var accepted = 0
    for (part in events.chunked(100)) {
        val res = ok(authed("POST", "track", mapOf("events" to part.map { it.toMap() })))
        accepted += res.num("accepted")?.toInt() ?: 0
    }
    return accepted
}

/** One live beat: open · screen · ping · close. Answers the seconds until the next ping, null while live is off. */
suspend fun DrSocialClient.live(session: String, kind: String, screen: String? = null): Int? {
    val res = ok(authed("POST", "live", buildMap { put("session", session); put("kind", kind); screen?.let { put("screen", it) }; put("app_version", appVersion) }))
    return if (res.isTrue("disabled")) null else res.num("ping")?.toInt() ?: 30
}

/** The installation's notification token: fcm · hms · harmony; permission granted · denied. False while push is off. */
suspend fun DrSocialClient.pushToken(provider: String, token: String, permission: String): Boolean =
    !ok(authed("POST", "push-token", mapOf("provider" to provider, "token" to token, "permission" to permission))).isTrue("disabled")

/** The person opened a notification ([push] = its `drs_push`), or pressed one of its buttons ([action]). */
suspend fun DrSocialClient.pushOpened(push: String, action: String? = null) {
    ok(authed("POST", "push-opened", buildMap { put("push", push); action?.let { put("action", it) } }))
}

/** What this installation should have inside the app now (in-app messages, inbox, surveys, tours). */
suspend fun DrSocialClient.messages(): List<JsonObject> = ok(authed("GET", "messages")).arr("messages").filterIsInstance<JsonObject>()

/** shown · clicked · dismissed · answered · completed · read; a survey's [answer] is {question id: value}. */
suspend fun DrSocialClient.messageEvent(id: String, kind: String, answer: Map<String, Any?>? = null) {
    ok(authed("POST", "messages/$id/event", buildMap { put("kind", kind); answer?.let { put("answer", it) } }))
}

/** Where the installation came from, once on the first open (Play's install referrer, or the link that opened the app). */
suspend fun DrSocialClient.attribution(referrer: String? = null, link: String? = null): String? {
    if (store.read("attributed") != null) return null
    val res = ok(authed("POST", "attribution", buildMap { referrer?.let { put("referrer", it) }; link?.let { put("link", it) } }))
    if (res.isTrue("disabled")) return null
    store.write("attributed", "1")
    return res.str("network")
}

/** A link tapped before the app was installed, once on the very first open. */
suspend fun DrSocialClient.deferred(referrer: String? = null): DeferredLink? {
    if (store.read("deferred") != null) return null
    val res = ok(authed("POST", "deferred", buildMap { referrer?.let { put("referrer", it) } }))
    if (res.isTrue("disabled")) return null
    store.write("deferred", "1")
    if (!res.isTrue("matched")) return null
    return DeferredLink(res.str("code") ?: "", res.str("link") ?: "", likely = res.str("by") == "network")
}

/** Whether to open the store's review box now; ask at a calm moment, never on launch or after an error. */
suspend fun DrSocialClient.review(): ReviewAnswer {
    val res = ok(authed("POST", "review", emptyMap<String, Any?>()))
    return ReviewAnswer(res.isTrue("ask"), res.str("reason") ?: if (res.isTrue("disabled")) "off" else "")
}

/** The icons built into this release and the one shown now, on start. */
suspend fun DrSocialClient.reportIcons(available: List<String>, current: String) {
    ok(authed("POST", "icons", mapOf("available" to available.take(10), "current" to current, "app_version" to appVersion)))
}

/** Up to 20 crashes a call; answers how many were kept. */
suspend fun DrSocialClient.crashes(list: List<SdkCrash>): Int {
    var accepted = 0
    for (part in list.chunked(20)) {
        val res = ok(authed("POST", "crashes", mapOf("crashes" to part.map { it.toMap() })))
        accepted += res.num("accepted")?.toInt() ?: 0
    }
    return accepted
}

/**
 * The company's own site with the device id added (`drs_d=<device id>`, the config's `bans.site_param`), so a stopped
 * phone is refused there too. Open the company's site through this, in a WebView or the browser.
 */
fun DrSocialClient.siteUrl(url: String): String {
    val device = deviceId ?: return url
    val param = config.siteBanParam
    val hash = url.indexOf('#')
    val head = if (hash >= 0) url.substring(0, hash) else url
    val tail = if (hash >= 0) url.substring(hash) else ""
    val sep = if (head.contains('?')) "&" else "?"
    return head + sep + param + "=" + java.net.URLEncoder.encode(device, "UTF-8") + tail
}
