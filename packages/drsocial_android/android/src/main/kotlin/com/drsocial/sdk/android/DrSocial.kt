package com.drsocial.sdk.android

import android.app.Activity
import android.app.Application
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import com.drsocial.sdk.AttestationMaker
import com.drsocial.sdk.DeferredLink
import com.drsocial.sdk.DrSocialClient
import com.drsocial.sdk.DrsPush
import com.drsocial.sdk.LiveSession
import com.drsocial.sdk.ReviewAnswer
import com.drsocial.sdk.SdkBanned
import com.drsocial.sdk.SdkConfig
import com.drsocial.sdk.SdkCrash
import com.drsocial.sdk.SdkEvent
import com.drsocial.sdk.SdkHttp
import com.drsocial.sdk.SdkStore
import com.drsocial.sdk.UpdateAdvice
import com.drsocial.sdk.UpdateNeed
import com.drsocial.sdk.CrashFormat
import com.drsocial.sdk.attribution
import com.drsocial.sdk.crashes
import com.drsocial.sdk.deferred
import com.drsocial.sdk.identify
import com.drsocial.sdk.live
import com.drsocial.sdk.messageEvent
import com.drsocial.sdk.messages
import com.drsocial.sdk.pushOpened
import com.drsocial.sdk.pushToken
import com.drsocial.sdk.reportIcons
import com.drsocial.sdk.review
import com.drsocial.sdk.screenName
import com.drsocial.sdk.signOut
import com.drsocial.sdk.siteUrl
import com.drsocial.sdk.toJson
import com.drsocial.sdk.track
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.Json
import java.lang.ref.WeakReference
import java.time.Instant
import java.time.LocalDate

/** How the app starts the SDK. Only [buildKey] is needed; everything else has a safe default. */
class DrSocialOptions(
    /** The build's public key (32 hex) from Settings → 📱 Mobile app, one per store build (Google Play, AppGallery). */
    val buildKey: String,
    /** The platform's Ed25519 public keys this release trusts, {"v1": base64}; empty only before the platform has one. */
    val trustedKeys: Map<String, String> = emptyMap(),
    val base: String = "https://social.drscroll.com/api/v1",
    /** The small icon of the notifications the SDK draws (a white silhouette); 0 = the app's own icon. */
    val notificationIcon: Int = 0,
    /** The alternate icons built into this release; null = the app does not switch icons. */
    val icons: IconSwitcher? = null,
    /** A Play Integrity proof for a nonce (the `play` module's `PlayIntegrity.maker`); null = none sent. */
    val attest: AttestationMaker? = null,
    /** Google Play's install referrer, read once on the first open (the `play` module's `PlayInstallReferrer.reader`). */
    val referrer: (suspend () -> String?)? = null,
    /** Draw the full-screen blocks of a stopped phone and a required update (on by default). */
    val blockScreens: Boolean = true,
    /** Opens a link from a notification, a button or a link after install; null = an ACTION_VIEW inside the app. */
    val onLink: ((String) -> Unit)? = null,
    /** Every config read (remote values, features). Called on a background thread. */
    val onConfig: ((SdkConfig) -> Unit)? = null,
    /** What the app should show inside it now (in-app messages, inbox, surveys, tours), each time they are read. */
    val onMessages: ((List<JsonObject>) -> Unit)? = null,
    /** A newer version exists (not required): called at most once a day with the store page and the company's words. */
    val onUpdateSuggested: ((UpdateAdvice) -> Unit)? = null,
    /** The phone was stopped; the SDK already blocks the screens when [blockScreens] is on. */
    val onBanned: ((SdkBanned) -> Unit)? = null,
    /** The words people see for each vibration channel in the phone's settings. */
    val channelNames: (String) -> String = Notifications::defaultName,
    /** For tests only: another way out and another store. */
    val http: SdkHttp? = null,
    val store: SdkStore? = null,
    val signer: com.drsocial.sdk.DeviceSigner? = null,
)

/** The SDK's single entry point: `DrSocial.start(app, DrSocialOptions(buildKey = "…"))` in `Application.onCreate`. */
object DrSocial {
    @Volatile
    private var current: DrSocialAndroid? = null

    /** The running SDK; throws before [start]. */
    val instance: DrSocialAndroid get() = current ?: error("DrSocial.start was not called")

    val isStarted: Boolean get() = current != null

    @Synchronized
    fun start(app: Application, options: DrSocialOptions): DrSocialAndroid =
        current ?: DrSocialAndroid(app, options).also { current = it; it.begin() }
}

/**
 * The SDK running in the app. The platform keeps every rule; this reads, sends and shows. A switch that is off in the
 * config means the matching part does nothing.
 */
class DrSocialAndroid internal constructor(private val app: Application, val options: DrSocialOptions) : Application.ActivityLifecycleCallbacks {
    val store: SdkStore = options.store ?: PrefsStore(app)
    val installId: String = Installation.id(store)
    val appVersion: String = Installation.appVersion(app)
    private val os = Installation.os()

    val client = DrSocialClient(
        buildKey = options.buildKey,
        installId = installId,
        trustedKeys = options.trustedKeys,
        base = options.base,
        http = options.http,
        store = store,
        os = os,
        appVersion = appVersion,
        hardwareId = Installation.hardwareId(app),
    )

    val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val main = Handler(Looper.getMainLooper())
    private val crashes = CrashBox(app, store)
    private val session = LiveSession()
    private val eventsLock = Mutex()
    private var started = 0
    private var resumed: WeakReference<Activity>? = null
    private var pingJob: Job? = null
    private var screen: String? = null
    private var readAt: Instant = Instant.EPOCH

    @Volatile
    var banned: SdkBanned? = null
        private set

    val config: SdkConfig get() = client.config

    internal fun begin() {
        client.use(options.signer ?: KeystoreSigner(), options.attest)
        crashes.install(appVersion, os) { screen }
        Notifications.createChannels(app, options.channelNames)
        app.registerActivityLifecycleCallbacks(this)
        scope.launch { boot() }
    }

    private suspend fun boot() {
        read()
        if (banned != null) return
        safely { firstOpen() }
        safely { sendCrashes() }
        safely { icons(report = true) }
        safely { resendPushToken() }
        safely { flushEvents() }
    }

    /** Reads the config (and what depends on it) again. Never throws. */
    suspend fun read() {
        safely {
            client.refresh()
            readAt = Instant.now()
            options.onConfig?.invoke(client.config)
            updateRule()
            if (MESSAGE_KINDS.any { client.config.feature(it) }) options.onMessages?.invoke(client.messages())
        }
    }

    // ---- people and events ----------------------------------------------------------------------------------------

    /** Links the phone to the company's own user (see `identify` in API.md); null when it could not be sent. */
    suspend fun identify(
        externalId: String,
        identityHash: String? = null,
        traits: Map<String, Any?>? = null,
        analytics: Boolean? = null,
        messages: Boolean? = null,
        locale: String? = null,
        country: String? = null,
        profile: Map<String, String>? = null,
    ): String? = safely { client.identify(externalId, identityHash, traits, analytics, messages, locale, country, profile) }

    suspend fun signOut() {
        safely { client.signOut() }
    }

    /**
     * Records one of the app's own events (`cart_add`, `purchase` {value: 250}…). Kept on the phone and sent in batches,
     * so an event made offline goes out later with its time and id (sent twice = kept once).
     */
    fun track(name: String, props: Map<String, Any?> = emptyMap()) {
        val e = SdkEvent(name, props)
        scope.launch {
            eventsLock.withLock {
                val list = keptEvents().toMutableList()
                list += toJson(e.toMap()) as JsonObject
                store.write("events", JsonArray(list.takeLast(MAX_EVENTS)).toString())
            }
            if (keptEvents().size >= FLUSH_AT) flushEvents()
        }
    }

    /** Sends the kept events now. */
    suspend fun flushEvents() {
        if (banned != null) return
        eventsLock.withLock {
            val list = keptEvents()
            if (list.isEmpty()) return
            val events = list.map { SdkEvent(it["name"].str() ?: "event", fromProps(it["props"]), com.drsocial.sdk.parseTime(it["at"].str()) ?: Instant.now(), it["id"].str() ?: com.drsocial.sdk.newSdkId()) }
            safely {
                client.track(events)
                store.write("events", null)
            }
        }
    }

    private fun keptEvents(): List<JsonObject> = try {
        (Json.parseToJsonElement(store.read("events") ?: "[]") as? JsonArray)?.filterIsInstance<JsonObject>() ?: emptyList()
    } catch (_: Exception) {
        emptyList()
    }

    /** The screen now (a name or a route; ids and queries are removed). Sent to live while it is on. */
    fun screen(name: String) {
        val s = screenName(name)
        screen = s
        if (!client.config.feature("live") || started == 0) return
        scope.launch { safely { client.live(session.id, "screen", s) } }
    }

    /** Reports an error the app caught (kind `non_fatal`), sent at once while `crash_lines` is on, else on the next start. */
    fun reportError(e: Throwable) {
        crashes.keep(CrashFormat.fromThrowable(e, "non_fatal", appVersion, os, screen))
        scope.launch { safely { sendCrashes() } }
    }

    // ---- notifications ------------------------------------------------------------------------------------------

    /**
     * The installation's push token from Firebase (`fcm`), Huawei Push Kit (`hms`) or HarmonyOS (`harmony`). Call it whenever
     * the provider gives a new one; the SDK sends it again when the permission changes.
     */
    fun pushToken(provider: String, token: String) {
        store.write("push_provider", provider)
        store.write("push_token", token)
        scope.launch { safely { resendPushToken(force = true) } }
    }

    private suspend fun resendPushToken(force: Boolean = false) {
        val provider = store.read("push_provider") ?: return
        val token = store.read("push_token") ?: return
        if (!client.config.feature("push")) return
        val permission = Notifications.permission(app)
        val sent = "$provider|$token|$permission"
        if (!force && store.read("push_sent") == sent) return
        if (client.pushToken(provider, token, permission)) store.write("push_sent", sent)
    }

    /**
     * A message's data from FCM / Huawei / HarmonyOS. Answers false when it is not a DrSocial notification (the app's own
     * code handles it). A silent `refresh` reads the config and messages again; `ping` does nothing at all; a data-only
     * notification (buttons, Huawei) is drawn here.
     */
    fun onPushMessage(data: Map<String, String>): Boolean {
        val push = DrsPush(data)
        if (!push.isDrSocial) return false
        when (push.silent) {
            "ping" -> return true
            null -> Unit
            else -> {
                scope.launch { read() }
                return true
            }
        }
        if (push.needsDrawing) {
            scope.launch {
                val picture = if (push.image.isNotEmpty()) Notifications.picture(push.image) else null
                Notifications.show(app, push, smallIcon(), picture)
            }
        }
        return true
    }

    private fun smallIcon(): Int = options.notificationIcon.takeIf { it != 0 } ?: app.applicationInfo.icon

    private fun handleOpen(activity: Activity) {
        val intent = activity.intent ?: return
        val (push, action, link) = Notifications.opened(intent) ?: return
        intent.removeExtra(Notifications.EXTRA_PUSH)
        intent.removeExtra(Notifications.EXTRA_ACTION)
        intent.removeExtra(Notifications.EXTRA_LINK)
        scope.launch { safely { client.pushOpened(push, action) } }
        if (link.isNotEmpty()) openLink(link)
    }

    private fun openLink(link: String) {
        main.post {
            val handler = options.onLink
            if (handler != null) handler(link) else Notifications.linkIntent(app, link)?.let { i ->
                try { app.startActivity(i) } catch (_: Exception) { }
            }
        }
    }

    // ---- the first open: where it came from, links after install ------------------------------------------------

    private suspend fun firstOpen() {
        if (store.read("first_open") != null) return
        val referrer = try { options.referrer?.invoke() } catch (_: Exception) { null }
        val link = store.read("first_link")
        if (client.config.feature("attribution")) client.attribution(referrer, link)
        if (client.config.feature("deferred_links")) {
            val d: DeferredLink? = client.deferred(referrer)
            if (d != null && d.link.isNotEmpty()) openLink(d.link)
        }
        store.write("first_open", "1")
    }

    // ---- store review, update, icons, site ----------------------------------------------------------------------

    /** Whether to open the store's review box now (`ReviewAnswer.ask`); ask after a success, never on launch or after an error. */
    suspend fun reviewQuestion(): ReviewAnswer =
        if (!client.config.feature("store_review")) ReviewAnswer(false, "off") else safely { client.review() } ?: ReviewAnswer(false, "off")

    /** What the app must do about updating now. */
    val update: UpdateAdvice get() = client.config.update(appVersion)

    private fun updateRule() {
        val u = update
        if (u.need == UpdateNeed.REQUIRED && options.blockScreens) main.post { resumed?.get()?.let { BlockScreen.update(it, u.message, u.url) } }
        if (u.need == UpdateNeed.SUGGESTED) {
            val today = LocalDate.now().toString()
            if (store.read("update_told") != today) {
                store.write("update_told", today)
                options.onUpdateSuggested?.invoke(u)
            }
        }
    }

    private suspend fun icons(report: Boolean) {
        val switcher = options.icons ?: return
        if (!client.config.feature("app_icons")) return
        if (report) client.reportIcons(switcher.available, switcher.current)
        client.config.iconAt(Instant.now())?.let { switcher.apply(it) }
    }

    /** The company's own site with this phone's id (`drs_d`), so a stopped phone is refused there too. */
    fun siteUrl(url: String): String = client.siteUrl(url)

    suspend fun messages(): List<JsonObject> = safely { client.messages() } ?: emptyList()

    suspend fun messageEvent(id: String, kind: String, answer: Map<String, Any?>? = null) {
        safely { client.messageEvent(id, kind, answer) }
    }

    // ---- crashes --------------------------------------------------------------------------------------------------

    private suspend fun sendCrashes() {
        crashes.collectAnrs(appVersion, os)
        if (!client.config.feature("crash_lines")) return
        val pending = crashes.pending()
        if (pending.isEmpty()) return
        client.crashes(pending.map { it.second })
        crashes.sent(pending.map { it.first })
    }

    /** For tests and the app's own reporting: the crashes waiting on the phone. */
    fun pendingCrashes(): List<SdkCrash> = crashes.pending().map { it.second }

    // ---- live and the activities ------------------------------------------------------------------------------------

    private fun foreground() {
        val new = session.front(Instant.now())
        scope.launch {
            if (Instant.now().isAfter(readAt.plusSeconds(client.config.ttlSeconds))) read()
            safely { icons(report = false) }
            if (!client.config.feature("live")) return@launch
            safely {
                val ping = client.live(session.id, if (new) "open" else "screen", screen) ?: return@safely
                pingJob?.cancel()
                pingJob = scope.launch {
                    var every = ping
                    while (isActive && started > 0) {
                        delay(every * 1000L)
                        if (started == 0) break
                        every = safely { client.live(session.id, "ping", screen) } ?: break
                    }
                }
            }
        }
    }

    private fun background() {
        session.back(Instant.now())
        pingJob?.cancel()
        scope.launch {
            if (client.config.feature("live")) safely { client.live(session.id, "close", screen) }
            flushEvents()
        }
    }

    override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {
        if (store.read("first_open") == null && store.read("first_link") == null) {
            activity.intent?.takeIf { it.action == Intent.ACTION_VIEW }?.dataString?.let { store.write("first_link", it.take(2048)) }
        }
    }

    override fun onActivityStarted(activity: Activity) {
        started++
        if (started == 1) foreground()
    }

    override fun onActivityResumed(activity: Activity) {
        resumed = WeakReference(activity)
        val b = banned
        if (b != null && options.blockScreens) {
            BlockScreen.banned(activity, b.message)
            return
        }
        val u = update
        if (u.need == UpdateNeed.REQUIRED && options.blockScreens) BlockScreen.update(activity, u.message, u.url)
        handleOpen(activity)
    }

    override fun onActivityPaused(activity: Activity) = Unit

    override fun onActivityStopped(activity: Activity) {
        started = maxOf(0, started - 1)
        if (started == 0) background()
    }

    override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit
    override fun onActivityDestroyed(activity: Activity) = Unit

    /** Runs a call; a stopped phone stops the SDK (and blocks the screens), anything else is swallowed: the app goes on. */
    private suspend fun <T> safely(block: suspend () -> T): T? {
        if (banned != null) return null
        return try {
            block()
        } catch (b: SdkBanned) {
            onBanned(b)
            null
        } catch (_: Exception) {
            null
        }
    }

    private fun onBanned(b: SdkBanned) {
        banned = b
        pingJob?.cancel()
        options.onBanned?.invoke(b)
        if (options.blockScreens) main.post { resumed?.get()?.let { BlockScreen.banned(it, b.message) } }
    }

    companion object {
        val MESSAGE_KINDS = listOf("in_app", "inbox", "surveys", "tours")
        const val MAX_EVENTS = 500
        const val FLUSH_AT = 20
    }
}

private fun kotlinx.serialization.json.JsonElement?.str(): String? =
    (this as? kotlinx.serialization.json.JsonPrimitive)?.takeIf { it.isString }?.content

@Suppress("UNCHECKED_CAST")
private fun fromProps(e: kotlinx.serialization.json.JsonElement?): Map<String, Any?> =
    (com.drsocial.sdk.fromJson(e) as? Map<String, Any?>) ?: emptyMap()
