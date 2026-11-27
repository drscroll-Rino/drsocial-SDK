package com.drsocial.reactnative

import com.drsocial.sdk.UpdateNeed
import com.drsocial.sdk.android.DrSocial
import com.drsocial.sdk.android.DrSocialAndroid
import com.drsocial.sdk.play.PlayReview
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import com.facebook.react.bridge.ReadableArray
import com.facebook.react.bridge.ReadableMap
import com.facebook.react.bridge.ReadableType
import com.facebook.react.bridge.WritableMap
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.longOrNull

/**
 * `NativeModules.DrSocial` on Android: each call goes to the running native SDK (started in MainApplication through
 * [DrSocialReact.start]). Before the SDK is started a call does nothing and a promise answers null, never an error the
 * app has to catch.
 */
class DrSocialModule(private val ctx: ReactApplicationContext) : ReactContextBaseJavaModule(ctx) {
    init {
        JsEvents.attach(ctx)
    }

    override fun getName(): String = NAME

    override fun invalidate() {
        JsEvents.detach(ctx)
        super.invalidate()
    }

    private val sdk: DrSocialAndroid? get() = if (DrSocial.isStarted) DrSocial.instance else null

    private fun later(promise: Promise, block: suspend (DrSocialAndroid) -> Any?) {
        val s = sdk ?: return promise.resolve(null)
        s.scope.launch {
            try {
                promise.resolve(block(s))
            } catch (e: Exception) {
                promise.resolve(null)
            }
        }
    }

    @ReactMethod(isBlockingSynchronousMethod = true)
    fun isStarted(): Boolean = DrSocial.isStarted

    @ReactMethod
    fun identify(externalId: String, options: ReadableMap, promise: Promise) = later(promise) { s ->
        s.identify(
            externalId = externalId,
            identityHash = options.text("identityHash"),
            traits = if (options.hasKey("traits")) plain(options.getMap("traits")) else null,
            analytics = options.flag("analytics"),
            messages = options.flag("messages"),
            locale = options.text("locale"),
            country = options.text("country"),
            profile = if (options.hasKey("profile")) plain(options.getMap("profile")).mapValues { it.value.toString() } else null,
        )
    }

    @ReactMethod
    fun signOut(promise: Promise) = later(promise) { s -> s.signOut(); null }

    @ReactMethod
    fun track(name: String, props: ReadableMap) {
        sdk?.track(name, plain(props))
    }

    @ReactMethod
    fun screen(name: String) {
        sdk?.screen(name)
    }

    /** A JavaScript error: kept on the phone like any caught error (kind non_fatal) with its JavaScript frames. */
    @ReactMethod
    fun reportError(type: String, message: String, frames: ReadableArray) {
        val s = sdk ?: return
        s.reportError(JavaScriptError(type, message, frames))
    }

    @ReactMethod
    fun flush(promise: Promise) = later(promise) { s -> s.flushEvents(); null }

    @ReactMethod
    fun siteUrl(url: String, promise: Promise) {
        val s = sdk ?: return promise.resolve(url)
        promise.resolve(s.siteUrl(url))
    }

    /** A remote value as JSON text (null = not set). */
    @ReactMethod(isBlockingSynchronousMethod = true)
    fun value(key: String): String? {
        val s = sdk ?: return null
        return s.config.valueFor(key, s.installId, s.appVersion)?.toString()
    }

    @ReactMethod(isBlockingSynchronousMethod = true)
    fun update(): WritableMap {
        val u = sdk?.update
        return Arguments.createMap().apply {
            putInt("need", when (u?.need) { UpdateNeed.SUGGESTED -> 1; UpdateNeed.REQUIRED -> 2; else -> 0 })
            putString("url", u?.url ?: "")
            putString("message", u?.message ?: "")
        }
    }

    @ReactMethod
    fun askReviewIfDue(promise: Promise) {
        val activity = reactApplicationContext.currentActivity ?: return promise.resolve(false)
        later(promise) { PlayReview.askIfDue(activity) }
    }

    /** The messages as JSON text (the JavaScript side reads it). */
    @ReactMethod
    fun messages(promise: Promise) = later(promise) { s -> JsonArray(s.messages()).toString() }

    @ReactMethod
    fun messageEvent(id: String, kind: String, answer: String?, promise: Promise) = later(promise) { s ->
        s.messageEvent(id, kind, answer?.let { a -> runCatching { (Json.parseToJsonElement(a) as? JsonObject)?.let(::fromJson) }.getOrNull() })
        null
    }

    /** iOS only; Android asks with PermissionsAndroid in JavaScript. */
    @ReactMethod
    fun requestPush(provisional: Boolean) = Unit

    /** iOS only. */
    @ReactMethod
    fun liveActivity(kind: String, type: String, activity: String?, token: String?) = Unit

    @ReactMethod
    fun addListener(eventName: String) {
        JsEvents.listen()
    }

    @ReactMethod
    fun removeListeners(count: Double) = Unit

    companion object {
        const val NAME = "DrSocial"

        /** Plain values only (text, numbers, true/false, null), as the platform keeps them. */
        internal fun plain(map: ReadableMap?): Map<String, Any?> {
            if (map == null) return emptyMap()
            val out = LinkedHashMap<String, Any?>()
            val it = map.keySetIterator()
            while (it.hasNextKey()) {
                val k = it.nextKey()
                when (map.getType(k)) {
                    ReadableType.Null -> out[k] = null
                    ReadableType.Boolean -> out[k] = map.getBoolean(k)
                    ReadableType.Number -> map.getDouble(k).let { d -> out[k] = if (d % 1.0 == 0.0 && kotlin.math.abs(d) < 1e15) d.toLong() else d }
                    ReadableType.String -> out[k] = map.getString(k)
                    else -> Unit
                }
            }
            return out
        }

        /** A survey's answer {question id: value} read back from JSON. */
        internal fun fromJson(o: JsonObject): Map<String, Any?> = o.mapValues { (_, v) -> value(v) }

        private fun value(v: JsonElement): Any? = when (v) {
            is JsonNull -> null
            is JsonPrimitive -> if (v.isString) v.content else v.booleanOrNull ?: v.longOrNull ?: v.doubleOrNull
            is JsonArray -> v.map(::value)
            is JsonObject -> fromJson(v)
        }

        private fun ReadableMap.text(k: String): String? = if (hasKey(k) && getType(k) == ReadableType.String) getString(k) else null
        private fun ReadableMap.flag(k: String): Boolean? = if (hasKey(k) && getType(k) == ReadableType.Boolean) getBoolean(k) else null
    }
}

/**
 * A JavaScript error carried as a Throwable, so the SDK keeps it on the phone and sends it like any other (type
 * `com.drsocial.reactnative.JavaScriptError`, frames `js.<function>` with their bundle file and line). The message is never
 * sent, as with every crash.
 */
internal class JavaScriptError(private val jsType: String, message: String, frames: ReadableArray) : Exception(message) {
    init {
        stackTrace = Array(frames.size()) { i ->
            val f = frames.getMap(i)
            val line = if (f != null && f.hasKey("line") && f.getType("line") == ReadableType.Number) f.getInt("line") else -1
            StackTraceElement("js", f?.getString("fn") ?: "?", if (f != null && f.hasKey("file")) f.getString("file") else null, line)
        }
    }

    override fun toString(): String = "$jsType: $message"
}
