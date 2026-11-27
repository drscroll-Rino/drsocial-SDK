package com.drsocial.sdk.play

import android.app.Activity
import android.content.Context
import com.android.installreferrer.api.InstallReferrerClient
import com.android.installreferrer.api.InstallReferrerStateListener
import com.drsocial.sdk.AttestationMaker
import com.drsocial.sdk.android.DrSocial
import com.google.android.play.core.integrity.IntegrityManagerFactory
import com.google.android.play.core.integrity.IntegrityTokenRequest
import com.google.android.play.core.review.ReviewManagerFactory
import com.google.android.gms.tasks.Task
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.coroutines.resume

/** Google Play's install referrer: `DrSocialOptions(referrer = PlayInstallReferrer.reader(app))`. */
object PlayInstallReferrer {
    fun reader(context: Context): suspend () -> String? = { read(context.applicationContext) }

    /** The referrer string Play kept for this install (utm_* , drs_link=…), or null when Play has none or cannot say. */
    suspend fun read(context: Context): String? = withTimeoutOrNull(10_000) {
        suspendCancellableCoroutine { cont ->
            val client = InstallReferrerClient.newBuilder(context).build()
            client.startConnection(object : InstallReferrerStateListener {
                override fun onInstallReferrerSetupFinished(code: Int) {
                    val value = if (code == InstallReferrerClient.InstallReferrerResponse.OK) {
                        try { client.installReferrer.installReferrer } catch (_: Exception) { null }
                    } else null
                    try { client.endConnection() } catch (_: Exception) {}
                    if (cont.isActive) cont.resume(value?.takeIf { it.isNotEmpty() })
                }

                override fun onInstallReferrerServiceDisconnected() {
                    if (cont.isActive) cont.resume(null)
                }
            })
        }
    }
}

/** Play Integrity (classic request): `DrSocialOptions(attest = PlayIntegrity.maker(app, <Google Cloud project number>))`. */
object PlayIntegrity {
    fun maker(context: Context, cloudProjectNumber: Long? = null): AttestationMaker = { nonce ->
        val manager = IntegrityManagerFactory.create(context.applicationContext)
        val request = IntegrityTokenRequest.builder().setNonce(nonce).apply { cloudProjectNumber?.let { setCloudProjectNumber(it) } }.build()
        val token = withTimeoutOrNull(20_000) { manager.requestIntegrityToken(request).await()?.token() }
        token?.let { mapOf("kind" to "play_integrity", "token" to it) }
    }
}

/** The in-app review box, opened only when the platform says so (`reviewQuestion().ask`). */
object PlayReview {
    /**
     * Asks the platform, then opens Google Play's review box over [activity]. Answers whether it was opened; Google does not
     * say whether a review was written, and may show nothing (its own quota).
     */
    suspend fun askIfDue(activity: Activity): Boolean {
        if (!DrSocial.isStarted || !DrSocial.instance.reviewQuestion().ask) return false
        return show(activity)
    }

    suspend fun show(activity: Activity): Boolean {
        val manager = ReviewManagerFactory.create(activity)
        val info = manager.requestReviewFlow().await() ?: return false
        manager.launchReviewFlow(activity, info).await()
        return true
    }
}

private suspend fun <T> Task<T>.await(): T? = suspendCancellableCoroutine { cont ->
    addOnCompleteListener { t -> if (cont.isActive) cont.resume(if (t.isSuccessful) t.result else null) }
}
