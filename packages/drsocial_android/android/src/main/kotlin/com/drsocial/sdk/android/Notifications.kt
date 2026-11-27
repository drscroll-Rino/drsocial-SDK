package com.drsocial.sdk.android

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.drsocial.sdk.DrsPush
import com.drsocial.sdk.PushVibration
import java.net.HttpURLConnection
import java.net.URL

/** The notification channels and the notifications the SDK draws itself (buttons, Huawei data messages). */
object Notifications {
    /** The channel for drawn notifications whose vibration is `default`. */
    const val DEFAULT_CHANNEL = "drs_default"

    const val EXTRA_PUSH = "drs_push"
    const val EXTRA_ACTION = "drs_action"
    const val EXTRA_LINK = "drs_link"

    /**
     * One channel per vibration pattern (`drs_vibe_<name>`), made on start: Android takes a channel's vibration only when
     * it is created, so the patterns never change. [names] = the words people see in the phone's settings.
     */
    fun createChannels(context: Context, names: (String) -> String = ::defaultName) {
        val nm = context.getSystemService(NotificationManager::class.java) ?: return
        val channels = mutableListOf(NotificationChannel(DEFAULT_CHANNEL, names("default"), NotificationManager.IMPORTANCE_HIGH))
        for ((name, pattern) in PushVibration.PATTERNS) {
            val id = PushVibration.channel(name) ?: continue
            val importance = if (name == "none") NotificationManager.IMPORTANCE_LOW else NotificationManager.IMPORTANCE_HIGH
            channels += NotificationChannel(id, names(name), importance).apply {
                if (pattern == null || pattern.isEmpty()) {
                    enableVibration(false)
                    if (name == "none") setSound(null, null)
                } else {
                    enableVibration(true)
                    vibrationPattern = pattern
                }
                if (name == "urgent") setBypassDnd(false)
            }
        }
        nm.createNotificationChannels(channels)
    }

    fun defaultName(pattern: String): String = when (pattern) {
        "default" -> "Notifications"
        "none" -> "Silent"
        else -> "Notifications (" + pattern + ")"
    }

    /** granted · denied, as the platform wants it on `push-token`. */
    fun permission(context: Context): String {
        val allowed = NotificationManagerCompat.from(context).areNotificationsEnabled() &&
            (Build.VERSION.SDK_INT < 33 || ContextCompat.checkSelfPermission(context, "android.permission.POST_NOTIFICATIONS") == PackageManager.PERMISSION_GRANTED)
        return if (allowed) "granted" else "denied"
    }

    /**
     * Draws a data-only DrSocial notification: title, words, picture (https only), up to 3 buttons, on its vibration's
     * channel. Tapping it (or a button) opens the app's launch activity with `drs_push` / `drs_action` / `drs_link`, which
     * [DrSocialAndroid] reads and reports. Answers false when it cannot (no permission, no words).
     */
    fun show(context: Context, push: DrsPush, smallIcon: Int, picture: Bitmap? = null): Boolean {
        if (!push.needsDrawing) return false
        if (permission(context) != "granted") return false
        val id = push.push.hashCode()
        val builder = NotificationCompat.Builder(context, push.channel ?: DEFAULT_CHANNEL)
            .setSmallIcon(smallIcon)
            .setContentTitle(push.title)
            .setContentText(push.body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(push.body))
            .setAutoCancel(true)
            .setPriority(if (push.vibration == "none") NotificationCompat.PRIORITY_LOW else NotificationCompat.PRIORITY_HIGH)
            .setContentIntent(openIntent(context, push, null, push.link, id))
        if (push.vibration == "none") builder.setSilent(true)
        if (picture != null) {
            builder.setLargeIcon(picture)
            builder.setStyle(NotificationCompat.BigPictureStyle().bigPicture(picture).setSummaryText(push.body))
        }
        push.buttons.forEachIndexed { i, b ->
            builder.addAction(0, b.label, openIntent(context, push, b.id, b.link.ifEmpty { push.link }, id + i + 1))
        }
        return try {
            NotificationManagerCompat.from(context).notify("drsocial", id, builder.build())
            true
        } catch (_: SecurityException) {
            false
        }
    }

    private fun openIntent(context: Context, push: DrsPush, action: String?, link: String, request: Int): PendingIntent {
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName) ?: Intent().setPackage(context.packageName)
        val intent = Intent(launch).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            putExtra(EXTRA_PUSH, push.push)
            if (action != null) putExtra(EXTRA_ACTION, action)
            if (link.isNotEmpty()) putExtra(EXTRA_LINK, link)
        }
        return PendingIntent.getActivity(context, request, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    /** The notification's picture, read only over https and only up to 5 MB; null on any problem (the words still show). */
    fun picture(url: String): Bitmap? {
        if (!url.startsWith("https://")) return null
        return try {
            val c = URL(url).openConnection() as HttpURLConnection
            c.connectTimeout = 8000
            c.readTimeout = 8000
            c.instanceFollowRedirects = true
            if (c.contentLengthLong > 5_000_000) return null
            c.inputStream.use { BitmapFactory.decodeStream(it) }
        } catch (_: Exception) {
            null
        }
    }

    /** What an opened activity's intent says about a notification: (push, action, link), or null when none. */
    fun opened(intent: Intent?): Triple<String, String?, String>? {
        val push = intent?.getStringExtra(EXTRA_PUSH)?.takeIf { it.isNotEmpty() } ?: return null
        return Triple(push, intent.getStringExtra(EXTRA_ACTION), intent.getStringExtra(EXTRA_LINK) ?: "")
    }

    internal fun linkIntent(context: Context, link: String): Intent? {
        val uri = Uri.parse(link)
        if (uri.scheme.isNullOrEmpty() || uri.scheme in setOf("javascript", "file", "data", "content", "intent")) return null
        return Intent(Intent.ACTION_VIEW, uri).setPackage(context.packageName).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    }

}
