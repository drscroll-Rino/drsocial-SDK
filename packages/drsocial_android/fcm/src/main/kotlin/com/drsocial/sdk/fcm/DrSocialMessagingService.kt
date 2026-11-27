package com.drsocial.sdk.fcm

import com.drsocial.sdk.android.DrSocial
import com.google.firebase.messaging.FirebaseMessaging
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

/** The calls an app's own FirebaseMessagingService makes when it keeps its own instead of [DrSocialMessagingService]. */
object DrSocialMessaging {
    /** A new FCM token: sent to the platform as provider `fcm`. */
    fun onNewToken(token: String) {
        if (DrSocial.isStarted) DrSocial.instance.pushToken("fcm", token)
    }

    /** Answers true when the message was DrSocial's (silent refresh, ping, or a notification with buttons it drew). */
    fun onMessage(message: RemoteMessage): Boolean = DrSocial.isStarted && DrSocial.instance.onPushMessage(message.data)

    /** Reads the current token once (call after `DrSocial.start`): FCM calls onNewToken only when it changes. */
    fun sendCurrentToken() {
        FirebaseMessaging.getInstance().token.addOnSuccessListener { if (!it.isNullOrEmpty()) onNewToken(it) }
    }
}

/** Merged into the app by the module's manifest: FCM tokens and data messages go to the SDK. */
open class DrSocialMessagingService : FirebaseMessagingService() {
    override fun onNewToken(token: String) = DrSocialMessaging.onNewToken(token)

    override fun onMessageReceived(message: RemoteMessage) {
        if (!DrSocialMessaging.onMessage(message)) onOtherMessage(message)
    }

    /** A message that is not DrSocial's: override to handle the app's own. */
    open fun onOtherMessage(message: RemoteMessage) = Unit
}
