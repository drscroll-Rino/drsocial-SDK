package com.drsocial.reactnative

import android.app.Application
import com.drsocial.sdk.android.DrSocial
import com.drsocial.sdk.android.DrSocialAndroid
import com.drsocial.sdk.android.DrSocialOptions
import kotlinx.serialization.json.JsonArray

/**
 * Starts the native SDK for a React Native app: `DrSocialReact.start(this, DrSocialOptions(buildKey = "…"))` in
 * `MainApplication.onCreate`, before React. The app's own callbacks still run; links, messages, config reads and a stop
 * are also handed to JavaScript (`DrSocial.on(...)`), kept until JavaScript listens (a notification can open the app
 * before React is up).
 */
object DrSocialReact {
    fun start(app: Application, options: DrSocialOptions): DrSocialAndroid =
        DrSocial.start(
            app,
            DrSocialOptions(
                buildKey = options.buildKey,
                trustedKeys = options.trustedKeys,
                base = options.base,
                notificationIcon = options.notificationIcon,
                icons = options.icons,
                attest = options.attest,
                referrer = options.referrer,
                blockScreens = options.blockScreens,
                onLink = { link ->
                    options.onLink?.invoke(link)
                    JsEvents.send("link", link)
                },
                onConfig = { config ->
                    options.onConfig?.invoke(config)
                    JsEvents.send("config", null)
                },
                onMessages = { list ->
                    options.onMessages?.invoke(list)
                    JsEvents.send("messages", JsonArray(list).toString())
                },
                onUpdateSuggested = options.onUpdateSuggested,
                onBanned = { banned ->
                    options.onBanned?.invoke(banned)
                    JsEvents.send("banned", mapOf("message" to banned.message, "until" to (banned.until?.toString() ?: "")))
                },
                channelNames = options.channelNames,
                http = options.http,
                store = options.store,
                signer = options.signer,
            ),
        )
}
