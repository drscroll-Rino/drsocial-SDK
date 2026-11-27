package com.drsocial.sdk.android

import android.annotation.SuppressLint
import android.content.Context
import android.content.SharedPreferences
import android.os.Build
import android.provider.Settings
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import com.drsocial.sdk.DeviceSigner
import com.drsocial.sdk.JcaDeviceSigner
import com.drsocial.sdk.SdkStore
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.spec.ECGenParameterSpec
import java.util.UUID

/** The SDK's few values in the app's private SharedPreferences (`drsocial_sdk`). */
class PrefsStore(context: Context, name: String = "drsocial_sdk") : SdkStore {
    private val prefs: SharedPreferences = context.applicationContext.getSharedPreferences(name, Context.MODE_PRIVATE)
    override fun read(name: String): String? = prefs.getString(name, null)
    override fun write(name: String, value: String?) {
        prefs.edit().apply { if (value == null) remove(name) else putString(name, value) }.apply()
    }
}

/**
 * The device's P-256 key in the Android Keystore (made once, never leaves the phone; StrongBox is not asked for, so every
 * phone has one). Deleting the app deletes it: the next install registers as a new device.
 */
class KeystoreSigner(private val alias: String = "drsocial.device") : DeviceSigner {
    private val inner: JcaDeviceSigner by lazy { load() }

    override suspend fun publicKey(): String = inner.publicKey()
    override suspend fun sign(message: ByteArray): String = inner.sign(message)

    private fun load(): JcaDeviceSigner {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if (!ks.containsAlias(alias)) {
            val g = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore")
            g.initialize(
                KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_SIGN)
                    .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                    .setDigests(KeyProperties.DIGEST_SHA256)
                    .build(),
            )
            g.generateKeyPair()
        }
        val key = ks.getKey(alias, null) as PrivateKey
        val public = ks.getCertificate(alias).publicKey
        return JcaDeviceSigner(key, public)
    }
}

/** What the SDK tells the platform about this installation. */
object Installation {
    private val HARDWARE = Regex("^[A-Za-z0-9._:-]{8,128}$")

    /** A random id made on the first run and kept until the app is deleted. */
    fun id(store: SdkStore): String = store.read("install_id") ?: UUID.randomUUID().toString().also { store.write("install_id", it) }

    /** `Settings.Secure.ANDROID_ID`: survives deleting the app (per app signing key); only its hash is kept by the platform. */
    @SuppressLint("HardwareIds")
    fun hardwareId(context: Context): String? =
        Settings.Secure.getString(context.contentResolver, Settings.Secure.ANDROID_ID)?.takeIf { HARDWARE.matches(it) }

    fun os(): String = Build.VERSION.RELEASE ?: Build.VERSION.SDK_INT.toString()

    fun appVersion(context: Context): String = try {
        context.packageManager.getPackageInfo(context.packageName, 0).versionName ?: ""
    } catch (_: Exception) {
        ""
    }
}
