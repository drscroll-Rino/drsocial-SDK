package com.drsocial.sdk

/** Turns what the runtime gives into the platform's crash shape. Frames stay as the runtime wrote them (R8 maps them back on the server). */
object CrashFormat {
    /** A thrown error: its type and the stack of the deepest cause (where it really failed). Its message is never sent. */
    fun fromThrowable(e: Throwable, kind: String = "fatal", appVersion: String? = null, osVersion: String? = null, screen: String? = null): SdkCrash {
        var root = e
        val seen = HashSet<Throwable>()
        while (root.cause != null && seen.add(root)) root = root.cause!!
        val frames = root.stackTrace.take(40).map { f ->
            SdkFrame(fn = "${f.className}.${f.methodName}", file = f.fileName, line = f.lineNumber.takeIf { it > 0 })
        }
        return SdkCrash(kind = kind, type = root.javaClass.name, frames = frames, appVersion = appVersion, osVersion = osVersion, screen = screen)
    }

    private val AT = Regex("""^\s*at ([\w$.<>]+)\(([^:)]*)(?::(\d+))?\)""")

    /**
     * An ANR's trace as Android writes it (ApplicationExitInfo.traceInputStream): the frames of the "main" thread, or of
     * the first thread when none is named main.
     */
    fun fromAnrTrace(trace: String, appVersion: String? = null, osVersion: String? = null): SdkCrash {
        val blocks = trace.split(Regex("\\n\\s*\\n"))
        val main = blocks.firstOrNull { it.trimStart().startsWith("\"main\"") } ?: blocks.firstOrNull { it.contains("\n  at ") } ?: ""
        val frames = main.lines().mapNotNull { l ->
            val m = AT.find(l) ?: return@mapNotNull null
            SdkFrame(fn = m.groupValues[1], file = m.groupValues[2].takeIf { it.isNotEmpty() && it != "Native method" }, line = m.groupValues[3].toIntOrNull())
        }.take(40)
        return SdkCrash(kind = "anr", type = "ANR", frames = frames, appVersion = appVersion, osVersion = osVersion)
    }
}
