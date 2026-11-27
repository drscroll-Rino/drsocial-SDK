package com.drsocial.sdk

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.longOrNull

internal val sdkJson = Json { ignoreUnknownKeys = true }

/** Plain Kotlin values (maps, lists, text, numbers, true/false, null) as JSON, the way the platform reads them. */
fun toJson(value: Any?): JsonElement = when (value) {
    null -> JsonNull
    is JsonElement -> value
    is String -> JsonPrimitive(value)
    is Boolean -> JsonPrimitive(value)
    is Number -> JsonPrimitive(value)
    is Map<*, *> -> JsonObject(value.entries.filter { it.key != null }.associate { it.key.toString() to toJson(it.value) })
    is Iterable<*> -> JsonArray(value.map { toJson(it) })
    is Array<*> -> JsonArray(value.map { toJson(it) })
    else -> JsonPrimitive(value.toString())
}

/** JSON back into plain Kotlin values: objects → Map, arrays → List, numbers → Long or Double. */
fun fromJson(e: JsonElement?): Any? = when (e) {
    null, JsonNull -> null
    is JsonObject -> e.mapValues { fromJson(it.value) }
    is JsonArray -> e.map { fromJson(it) }
    is JsonPrimitive -> if (e.isString) e.content else e.booleanOrNull ?: e.longOrNull ?: e.doubleOrNull ?: e.content
}

internal fun parseObject(text: String): JsonObject = try {
    sdkJson.parseToJsonElement(text) as? JsonObject ?: JsonObject(emptyMap())
} catch (_: Exception) {
    JsonObject(emptyMap())
}

internal fun JsonObject.obj(key: String): JsonObject = this[key] as? JsonObject ?: JsonObject(emptyMap())
internal fun JsonObject.arr(key: String): List<JsonElement> = (this[key] as? JsonArray) ?: emptyList()

/** A string only when the value is JSON text (a number is not a string). */
internal fun JsonObject.str(key: String): String? = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content
internal fun JsonObject.num(key: String): Double? = (this[key] as? JsonPrimitive)?.takeIf { !it.isString }?.doubleOrNull
internal fun JsonObject.bool(key: String): Boolean? = (this[key] as? JsonPrimitive)?.takeIf { !it.isString }?.booleanOrNull
internal fun JsonObject.isTrue(key: String): Boolean = bool(key) == true
internal fun List<JsonElement>.strings(): List<String> = mapNotNull { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content }
