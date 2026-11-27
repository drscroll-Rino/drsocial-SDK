package com.drsocial.sdk

/**
 * Compares two dotted versions number by number: -1, 0 or 1 ("1.10" > "1.9"; a missing part is 0; anything that is not a
 * number counts as 0). The same rule as the platform's `RemoteControl::compare` and the Dart core.
 */
fun compareVersions(a: String, b: String): Int {
    fun parts(v: String) = v.split('.').map { it.trim().toIntOrNull() ?: 0 }
    val x = parts(a)
    val y = parts(b)
    for (i in 0 until maxOf(x.size, y.size)) {
        val d = (x.getOrElse(i) { 0 }).compareTo(y.getOrElse(i) { 0 })
        if (d != 0) return Integer.signum(d)
    }
    return 0
}
