package com.drsocial.sdk.android

import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.net.Uri
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import java.util.Locale

/**
 * A full-screen block drawn over an activity: a stopped phone (no way out) or a required update (one button that opens
 * the store page). No activity has to be declared in the app's manifest.
 */
object BlockScreen {
    fun banned(activity: Activity, message: String) = show(activity, message.ifBlank { defaultBan() }, null, null)

    fun update(activity: Activity, message: String, url: String) =
        show(activity, message.ifBlank { defaultUpdate() }, if (url.startsWith("https://")) url else null, updateLabel())

    private fun show(activity: Activity, message: String, url: String?, button: String?) {
        val pad = dp(activity, 32f)
        val layout = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(pad, pad, pad, pad)
            setBackgroundColor(Color.WHITE)
            isClickable = true
            textDirection = View.TEXT_DIRECTION_FIRST_STRONG
        }
        layout.addView(TextView(activity).apply {
            text = message
            setTextColor(Color.rgb(30, 30, 30))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 18f)
            gravity = Gravity.CENTER
            textDirection = View.TEXT_DIRECTION_FIRST_STRONG
        })
        if (url != null && button != null) {
            layout.addView(Button(activity).apply {
                text = button
                setOnClickListener { activity.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
            })
        }
        activity.setContentView(layout)
    }

    private fun dp(a: Activity, v: Float) = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, a.resources.displayMetrics).toInt()
    private fun arabic() = Locale.getDefault().language == "ar"
    private fun defaultBan() = if (arabic()) "الجهاز ده موقوف من استخدام التطبيق." else "This phone can no longer use the app."
    private fun defaultUpdate() = if (arabic()) "فيه نسخة جديدة من التطبيق لازم تتنزل عشان تكمل." else "A new version of the app is needed to continue."
    private fun updateLabel() = if (arabic()) "حدّث التطبيق" else "Update"
}
