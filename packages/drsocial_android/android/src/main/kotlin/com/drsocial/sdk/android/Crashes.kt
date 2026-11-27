package com.drsocial.sdk.android

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build
import com.drsocial.sdk.CrashFormat
import com.drsocial.sdk.SdkCrash
import com.drsocial.sdk.SdkStore
import com.drsocial.sdk.toJson
import java.io.File

/**
 * Keeps crashes on disk until they are sent: a fatal crash is written while the app dies (it cannot be sent then) and sent
 * on the next launch; ANRs are read from Android's own record of the last exits (Android 11+).
 */
class CrashBox(context: Context, private val store: SdkStore) {
    private val dir = File(context.applicationContext.filesDir, "drsocial/crashes").apply { mkdirs() }
    private val am = context.getSystemService(ActivityManager::class.java)

    /** Catches every uncaught error, writes it, then lets the app's previous handler (or Android) end the app. */
    fun install(appVersion: String, os: String, screen: () -> String?) {
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, e ->
            try {
                keep(CrashFormat.fromThrowable(e, "fatal", appVersion, os, screen()))
            } catch (_: Throwable) {
            }
            previous?.uncaughtException(thread, e)
        }
    }

    fun keep(crash: SdkCrash) {
        val files = dir.listFiles().orEmpty().sortedBy { it.name }
        if (files.size >= MAX_KEPT) files.take(files.size - MAX_KEPT + 1).forEach { it.delete() }
        File(dir, "${System.currentTimeMillis()}-${crash.id}.json").writeText(toJson(crash.toMap()).toString())
    }

    /** The crashes waiting to be sent, with their files. */
    fun pending(): List<Pair<File, SdkCrash>> = dir.listFiles().orEmpty().sortedBy { it.name }.mapNotNull { f ->
        try { f to SdkCrash.parse(f.readText()) } catch (_: Exception) { f.delete(); null }
    }

    fun sent(files: List<File>) = files.forEach { it.delete() }

    /** ANRs Android recorded since the last look (API 30+), as crashes of kind `anr`. */
    fun collectAnrs(appVersion: String, os: String) {
        if (Build.VERSION.SDK_INT < 30 || am == null) return
        val since = store.read("anr_seen")?.toLongOrNull() ?: 0L
        var newest = since
        val exits = try { am.getHistoricalProcessExitReasons(null, 0, 10) } catch (_: Exception) { emptyList<ApplicationExitInfo>() }
        for (exit in exits) {
            if (exit.reason != ApplicationExitInfo.REASON_ANR || exit.timestamp <= since) continue
            newest = maxOf(newest, exit.timestamp)
            val trace = try { exit.traceInputStream?.use { it.readBytes().toString(Charsets.UTF_8) } } catch (_: Exception) { null } ?: ""
            keep(CrashFormat.fromAnrTrace(trace, appVersion, os))
        }
        if (newest > since) store.write("anr_seen", newest.toString())
    }

    companion object {
        const val MAX_KEPT = 50
    }
}
