package com.drsocial.sdk.android

import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager

/**
 * Switches the app's icon between icons built into the release (Google allows no other): each alternate icon is an
 * `<activity-alias>` in the app's manifest pointing at the launch activity, disabled by default; '' = the app's own
 * ([main], the alias or activity enabled by default). Only names in [aliases] are ever enabled.
 */
class IconSwitcher(private val context: Context, private val main: String, private val aliases: Map<String, String>) {
    val available: List<String> get() = aliases.keys.toList()

    /** The icon shown now: an alternate's name, or ''. */
    val current: String
        get() = aliases.entries.firstOrNull { state(it.value) == PackageManager.COMPONENT_ENABLED_STATE_ENABLED }?.key ?: ""

    /** Shows [name] ('' = the app's own). Answers whether anything changed. The launcher may take a moment to redraw. */
    fun apply(name: String): Boolean {
        val target = if (name.isEmpty() || name !in aliases) "" else name
        if (target == current) return false
        val pm = context.packageManager
        val flags = PackageManager.DONT_KILL_APP
        for ((n, cls) in aliases) {
            val want = if (n == target) PackageManager.COMPONENT_ENABLED_STATE_ENABLED else PackageManager.COMPONENT_ENABLED_STATE_DISABLED
            pm.setComponentEnabledSetting(ComponentName(context, cls), want, flags)
        }
        pm.setComponentEnabledSetting(
            ComponentName(context, main),
            if (target.isEmpty()) PackageManager.COMPONENT_ENABLED_STATE_DEFAULT else PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
            flags,
        )
        return true
    }

    private fun state(cls: String) = context.packageManager.getComponentEnabledSetting(ComponentName(context, cls))
}
