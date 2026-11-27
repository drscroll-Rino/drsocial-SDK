package com.drsocial.sdk

import java.time.Duration
import java.time.Instant

/**
 * The live session's rule (API.md, stage M5): a new session id each time the app comes to the front after 30 minutes
 * away; the same one when it comes back sooner.
 */
class LiveSession(private val gap: Duration = Duration.ofMinutes(30)) {
    var id: String = newSdkId()
        private set
    private var leftAt: Instant? = null

    private var started = false

    /** The app came to the front: answers true when this starts a new session (send `open`), false when it goes on. */
    fun front(now: Instant): Boolean {
        val left = leftAt
        leftAt = null
        if (!started) {
            started = true
            return true
        }
        if (left != null && Duration.between(left, now) >= gap) {
            id = newSdkId()
            return true
        }
        return false
    }

    fun back(now: Instant) {
        leftAt = now
    }
}

/** A screen name or route as the platform keeps it: no query, no fragment, ids become `{id}`. */
fun screenName(route: String): String {
    val path = route.substringBefore('?').substringBefore('#')
    return path.split('/').joinToString("/") { part ->
        if (part.isNotEmpty() && (part.all { it.isDigit() } || Regex("^[0-9a-fA-F-]{16,}$").matches(part))) "{id}" else part
    }.take(120)
}
