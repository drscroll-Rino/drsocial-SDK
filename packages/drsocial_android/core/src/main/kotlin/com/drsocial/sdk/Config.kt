package com.drsocial.sdk

import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.longOrNull
import java.security.MessageDigest
import java.time.Instant
import java.time.OffsetDateTime

/** One remote value as the platform sends it (stage M3). */
class RemoteValue(
    /** bool · number · string · json. */
    val type: String,
    val value: JsonElement?,
    /** The share of installations (0–100) that get the value. */
    val rollout: Int = 100,
    /** Below this app version the value is not given ('' = every version). */
    val minVersion: String = "",
) {
    companion object {
        fun from(j: JsonObject) = RemoteValue(
            type = j.str("type") ?: "string",
            value = j["value"],
            rollout = j.num("rollout")?.toInt() ?: 100,
            minVersion = j.str("min_version") ?: "",
        )
    }
}

/**
 * The installation's bucket for one key, 0–99: first 4 bytes of `sha256("<install id>|<key>")` as an unsigned big-endian
 * number, mod 100. Every DrSocial SDK and the platform (`RemoteControl::bucket`) use this same rule.
 */
fun rolloutBucket(installId: String, key: String): Int {
    val d = MessageDigest.getInstance("SHA-256").digest("$installId|$key".toByteArray(Charsets.UTF_8))
    val n = ((d[0].toLong() and 0xff) shl 24) or ((d[1].toLong() and 0xff) shl 16) or ((d[2].toLong() and 0xff) shl 8) or (d[3].toLong() and 0xff)
    return (n % 100).toInt()
}

/** Reads an ISO time as the platform writes it ("2026-12-01T00:00:00Z", "…+00:00"); null when it is not one. */
fun parseTime(s: String?): Instant? {
    if (s.isNullOrBlank()) return null
    return try {
        OffsetDateTime.parse(s).toInstant()
    } catch (_: Exception) {
        try { Instant.parse(s) } catch (_: Exception) { null }
    }
}

enum class UpdateNeed { NONE, SUGGESTED, REQUIRED }

class UpdateAdvice(
    val need: UpdateNeed,
    /** The store page (https) to open, '' when the company gave none. */
    val url: String = "",
    val message: String = "",
)

/** What the build's config says (GET /sdk/{key}/config, API v1). */
class SdkConfig private constructor(val raw: JsonObject) {
    companion object {
        /** Every feature off and nothing remote: the first run with no network. */
        val EMPTY = SdkConfig(JsonObject(emptyMap()))

        fun from(j: JsonObject) = SdkConfig(j)

        fun parse(body: String) = SdkConfig(parseObject(body))
    }

    /** A feature the SDK may start; anything not named is off. */
    fun feature(name: String): Boolean = raw.obj("features").isTrue(name)

    val ttlSeconds: Long get() = raw.num("ttl")?.toLong() ?: 300

    fun endpoint(name: String): String? = raw.obj("endpoints").str(name)

    /** The key generation; a device registered on an older one registers again. */
    val epoch: Int get() = raw.obj("security").num("epoch")?.toInt() ?: 1

    val requireToken: Boolean get() = raw.obj("security").isTrue("require_token")

    /** SPKI SHA-256 pins ("sha256/…") of the platform's certificate chain; empty = the system's trust only. */
    val pins: List<String> get() = raw.obj("security").arr("pins").strings()

    /** The remote values, or an empty map while remote config is off. */
    val remote: Map<String, RemoteValue>
        get() = (raw["remote"] as? JsonObject)?.entries?.mapNotNull { (k, v) -> (v as? JsonObject)?.let { k to RemoteValue.from(it) } }?.toMap() ?: emptyMap()

    /** The raw remote value of [key] for this installation and app version, or null when it is not given to it. */
    fun valueFor(key: String, installId: String, appVersion: String): JsonElement? {
        val v = remote[key] ?: return null
        if (v.rollout < 100 && rolloutBucket(installId, key) >= v.rollout) return null
        if (v.minVersion.isNotEmpty() && compareVersions(appVersion, v.minVersion) < 0) return null
        return v.value
    }

    fun string(key: String, fallback: String, installId: String, appVersion: String): String =
        (valueFor(key, installId, appVersion) as? JsonPrimitive)?.takeIf { it.isString }?.content ?: fallback

    fun bool(key: String, fallback: Boolean, installId: String, appVersion: String): Boolean =
        (valueFor(key, installId, appVersion) as? JsonPrimitive)?.takeIf { !it.isString }?.booleanOrNull ?: fallback

    fun long(key: String, fallback: Long, installId: String, appVersion: String): Long {
        val p = (valueFor(key, installId, appVersion) as? JsonPrimitive)?.takeIf { !it.isString } ?: return fallback
        return p.longOrNull ?: fallback
    }

    fun double(key: String, fallback: Double, installId: String, appVersion: String): Double =
        (valueFor(key, installId, appVersion) as? JsonPrimitive)?.takeIf { !it.isString && it.booleanOrNull == null }?.doubleOrNull ?: fallback

    /** A `json` value (object or array) as JSON; [fallback] when it is not given. */
    fun json(key: String, fallback: JsonElement?, installId: String, appVersion: String): JsonElement? {
        val v = valueFor(key, installId, appVersion) ?: return fallback
        return if (v is JsonPrimitive) fallback else v
    }

    private fun iconObj(): JsonObject? = raw["icon"] as? JsonObject

    /**
     * The icon the app should show: an alternate icon's name, '' for the app's own, null while icon switching is off.
     * Only names built into the release are ever returned.
     */
    val icon: String?
        get() {
            val i = iconObj() ?: return null
            val current = i.str("current") ?: ""
            val available = i.arr("available").strings()
            return if (current.isEmpty() || current in available) current else ""
        }

    /**
     * The icon to show at [now], applying the coming switches of `schedule` even offline: between `from` and `to` show its
     * `icon`; when two cover [now] the one that started last wins; outside them the `default`. Null while switching is off.
     */
    fun iconAt(now: Instant): String? {
        val i = iconObj() ?: return null
        val available = i.arr("available").strings().toSet()
        fun pick(name: String) = if (name.isEmpty() || name in available) name else ""
        val schedule = i.arr("schedule").filterIsInstance<JsonObject>()
        var started: Instant? = null
        var chosen: String? = null
        for (s in schedule) {
            val from = parseTime(s.str("from")) ?: continue
            val to = parseTime(s.str("to")) ?: continue
            if (now.isBefore(from) || !now.isBefore(to)) continue
            if (started == null || from.isAfter(started)) {
                started = from
                chosen = s.str("icon") ?: ""
            }
        }
        if (chosen != null) return pick(chosen)
        // `current` is the platform's answer when the config was read; once a switch it named has ended, fall back to `default`.
        val current = i.str("current") ?: ""
        val inSchedule = schedule.any { it.str("icon") == current }
        return pick(if (inSchedule) i.str("default") ?: "" else current)
    }

    /** The store-review rules while `store_review` is on, else null. */
    val review: JsonObject? get() = raw["review"] as? JsonObject

    /** The query name the app adds to the company's own site's address with the device id, so a stopped phone is refused there too. */
    val siteBanParam: String get() = raw.obj("bans").str("site_param") ?: "drs_d"

    /** What the app must do about updating, for [appVersion]. */
    fun update(appVersion: String): UpdateAdvice {
        val u = raw["update"] as? JsonObject ?: return UpdateAdvice(UpdateNeed.NONE)
        val min = u.str("min_version") ?: ""
        val latest = u.str("latest_version") ?: ""
        val url = u.str("url") ?: ""
        val message = u.str("message") ?: ""
        if (min.isNotEmpty() && compareVersions(appVersion, min) < 0) return UpdateAdvice(UpdateNeed.REQUIRED, url, message)
        if (latest.isNotEmpty() && compareVersions(appVersion, latest) < 0) return UpdateAdvice(UpdateNeed.SUGGESTED, url, message)
        return UpdateAdvice(UpdateNeed.NONE)
    }
}
