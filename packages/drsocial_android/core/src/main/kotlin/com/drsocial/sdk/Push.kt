package com.drsocial.sdk

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject

/** The vibration patterns the platform names (`PushVibration::PATTERNS`): wait, buzz, wait, buzz… in ms. */
object PushVibration {
    val PATTERNS: Map<String, LongArray?> = linkedMapOf(
        "default" to null,
        "none" to longArrayOf(),
        "short" to longArrayOf(0, 150),
        "double" to longArrayOf(0, 120, 100, 120),
        "long" to longArrayOf(0, 700),
        "heartbeat" to longArrayOf(0, 90, 110, 90, 500, 90, 110, 90),
        "ripple" to longArrayOf(0, 60, 60, 90, 60, 120, 60, 160),
        "urgent" to longArrayOf(0, 400, 150, 400, 150, 400),
    )

    /** The Android channel the SDK makes for a pattern (`drs_vibe_<name>`); null = the app's own default channel. */
    fun channel(name: String?): String? = if (name == null || name == "default" || name !in PATTERNS) null else "drs_vibe_$name"

    /** `drs_vibe_ms` ("0,120,100,120") read back; null when absent or not numbers. */
    fun parseMs(s: String?): LongArray? {
        if (s.isNullOrBlank()) return null
        val parts = s.split(',').map { it.trim().toLongOrNull() ?: return null }
        return parts.toLongArray()
    }
}

/** One button of a notification (`drs_buttons`): [link] opens a screen when the app's deep links are on. */
class PushButton(val id: String, val label: String, val link: String)

/**
 * A DrSocial notification's data, as FCM, Huawei Push Kit or HarmonyOS hand it to the app (string values). Not ours
 * ([isDrSocial] false) when it carries no `drs_push`.
 */
class DrsPush(val data: Map<String, String>) {
    val push: String? get() = data["drs_push"]?.takeIf { it.isNotEmpty() }
    val isDrSocial: Boolean get() = push != null
    val link: String get() = data["drs_link"] ?: ""

    /** refresh = read the config, the messages and the remote values again; ping = do nothing at all. Null = a visible notification. */
    val silent: String? get() = data["drs_silent"]?.takeIf { it.isNotEmpty() }

    val title: String get() = data["drs_title"] ?: ""
    val body: String get() = data["drs_body"] ?: ""
    val image: String get() = data["drs_image"] ?: ""
    val vibration: String get() = data["drs_vibe"]?.takeIf { it in PushVibration.PATTERNS } ?: "default"
    val vibrationMs: LongArray? get() = PushVibration.parseMs(data["drs_vibe_ms"]) ?: PushVibration.PATTERNS[vibration]
    val channel: String? get() = PushVibration.channel(vibration)

    /** Up to 3 buttons; `drs_buttons` comes as a JSON string. */
    val buttons: List<PushButton>
        get() {
            val raw = data["drs_buttons"]?.takeIf { it.isNotBlank() } ?: return emptyList()
            val arr = try { sdkJson.parseToJsonElement(raw) as? JsonArray } catch (_: Exception) { null } ?: return emptyList()
            return arr.filterIsInstance<JsonObject>().mapNotNull { b ->
                val id = b.str("id")?.takeIf { ID.matches(it) } ?: return@mapNotNull null
                PushButton(id, b.str("label") ?: id, b.str("link") ?: "")
            }.take(3)
        }

    /** A data-only notification the SDK must draw itself (buttons, or Huawei's data message): it has words to show. */
    val needsDrawing: Boolean get() = isDrSocial && silent == null && (title.isNotEmpty() || body.isNotEmpty())

    companion object {
        private val ID = Regex("^[a-z0-9_]{1,32}$")
    }
}
