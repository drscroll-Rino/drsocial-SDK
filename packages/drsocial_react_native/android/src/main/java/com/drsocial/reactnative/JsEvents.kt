package com.drsocial.reactnative

import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.modules.core.DeviceEventManagerModule

/** Hands the SDK's events to JavaScript; what comes before JavaScript listens waits here (≤ [MAX_WAITING], newest kept). */
internal object JsEvents {
    const val MAX_WAITING = 20
    private val waiting = ArrayDeque<Pair<String, Any?>>()
    private var context: ReactApplicationContext? = null
    private var listening = false

    @Synchronized
    fun send(name: String, value: Any?) {
        val ctx = context
        if (ctx == null || !listening || !ctx.hasActiveReactInstance()) {
            if (waiting.size >= MAX_WAITING) waiting.removeFirst()
            waiting.addLast(name to value)
            return
        }
        emit(ctx, name, value)
    }

    @Synchronized
    fun attach(ctx: ReactApplicationContext) {
        context = ctx
        listening = false
    }

    /** JavaScript added its first listener: what waited goes out in order. */
    @Synchronized
    fun listen() {
        listening = true
        val ctx = context ?: return
        while (waiting.isNotEmpty()) {
            val (name, value) = waiting.removeFirst()
            emit(ctx, name, value)
        }
    }

    @Synchronized
    fun detach(ctx: ReactApplicationContext) {
        if (context === ctx) {
            context = null
            listening = false
        }
    }

    private fun emit(ctx: ReactApplicationContext, name: String, value: Any?) {
        val payload: Any? = when (value) {
            is Map<*, *> -> Arguments.createMap().apply { value.forEach { (k, v) -> putString(k.toString(), v?.toString() ?: "") } }
            else -> value
        }
        ctx.getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter::class.java).emit("drsocial.$name", payload)
    }
}
