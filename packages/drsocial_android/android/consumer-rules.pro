# The SDK keeps its own public classes; the app's R8 may rename anything else.
-keep class com.drsocial.sdk.** { public *; }
-dontwarn org.bouncycastle.**
-keep class org.bouncycastle.crypto.signers.Ed25519Signer { *; }
-keep class org.bouncycastle.crypto.params.Ed25519PublicKeyParameters { *; }
