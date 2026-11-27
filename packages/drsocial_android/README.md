# DrSocial SDK for Android (Kotlin)

The native Android SDK for the DrSocial platform. It covers API v1 of the contract, `API.md` at the root of this repository, and matches the Dart SDK (`packages/drsocial_sdk`) rule for rule. The platform holds every
rule. The SDK reads the signed config, sends what the app does, and shows what the platform says. Any feature switched off
in the config does nothing.

| Module | Artifact | What it is |
| --- | --- | --- |
| `core` | `com.drsocial:drsocial-sdk-core` | Pure Kotlin/JVM, no Android. Covers the signed config (Ed25519), remote values and rollout, icon, update rule, device registration and short tokens (P-256), and every call: identify, events, live, push token and opens, messages, attribution, deferred links, store review, icons, crashes. All of the tests live here. |
| `android` | `com.drsocial:drsocial-sdk-android` | The Android layer (AAR). Holds the device key in the Android Keystore, values in SharedPreferences, live sessions from the activity lifecycle, notification channels per vibration pattern, notifications with buttons, crashes and ANRs, the icon switch, and the full-screen blocks for a stopped phone and a required update. It has no Firebase or Play dependency. |
| `fcm` | `com.drsocial:drsocial-sdk-fcm` | A ready `FirebaseMessagingService` that hands tokens and data messages to the SDK. |
| `play` | `com.drsocial:drsocial-sdk-play` | Google Play's install referrer, the in-app review box and Play Integrity. |

Requirements: minSdk 26, compileSdk 35, Kotlin 2.4, AGP 8.13, JDK 17+ to build.

## Start

```kotlin
class App : Application() {
    override fun onCreate() {
        super.onCreate()
        DrSocial.start(this, DrSocialOptions(
            buildKey = "<32 hex from Settings → 📱 Mobile app, one per store build>",
            trustedKeys = mapOf("v1" to "<the platform's Ed25519 public key, base64>"),
            notificationIcon = R.drawable.ic_notification,
            attest = PlayIntegrity.maker(this, cloudProjectNumber = 123456789L),   // play module, optional
            referrer = PlayInstallReferrer.reader(this),                            // play module, optional
            onLink = { link -> router.open(link) },
            onConfig = { config -> /* config.bool("checkout_v2"), config.string("home.banner") … */ },
            onMessages = { list -> /* in-app messages, inbox, surveys, tours to show */ },
        ))
        DrSocialMessaging.sendCurrentToken()                                       // fcm module
    }
}
```

Each Google Play build and each AppGallery build has its own build key. `trustedKeys` should list every key this release
accepts (`php artisan mobile:signing-key`, README step 35 of the platform). Leave it empty only before the platform has a key.

```kotlin
val sdk = DrSocial.instance
sdk.identify("user-42", identityHash = hashFromYourServer, traits = mapOf("plan" to "gold"), analytics = true, messages = true)
sdk.track("purchase", mapOf("value" to 250))      // kept on the phone, sent in batches of up to 100; offline is fine
sdk.screen("product/123")                         // the id becomes {id}
sdk.reportError(e)                                // a caught error (kind non_fatal)
sdk.siteUrl("https://shop.example/cart")          // adds drs_d=<device> so a ban on the phone also holds on the site
if (sdk.update.need == UpdateNeed.SUGGESTED) { /* show your own banner */ }
PlayReview.askIfDue(activity)                     // after a success, never on launch
```

## Notifications

- **FCM:** add the `fcm` module and `google-services.json`. The module's manifest merges `DrSocialMessagingService`. If the
  app has its own service, remove the SDK's with `tools:node="remove"` and call `DrSocialMessaging.onNewToken(token)` and
  `DrSocialMessaging.onMessage(message)` from it.
- **Huawei Push Kit (AppGallery builds):** the SDK accepts provider `hms` and draws Huawei's data messages itself. Huawei's
  library is not in this repository (Huawei's Maven was not reachable when the SDK was built), so the app adds
  `com.huawei.hms:push` and two lines:

  ```kotlin
  class AppHmsService : HmsMessageService() {
      override fun onNewToken(token: String) = DrSocial.instance.pushToken("hms", token)
      override fun onMessageReceived(message: RemoteMessage) { DrSocial.instance.onPushMessage(message.dataOfMap) }
  }
  ```
- **HarmonyOS NEXT** is not Android: it needs its own ArkTS SDK. The platform already accepts provider `harmony`.
- The SDK creates one channel per vibration pattern (`drs_vibe_<name>`, plus `drs_default`). It draws a notification itself
  only when it has buttons or arrives as data. Tapping it, or one of its buttons, opens the launch activity, and the SDK
  reports the open (`push-opened` with the button's `action`) and opens the link.
- On Android 13+ the app asks for `POST_NOTIFICATIONS` in its own words. The SDK sends the permission with the token and
  sends it again when it changes.

## Icons

Each alternate icon is a disabled `<activity-alias>` in the app's manifest that points at the launch activity:

```xml
<activity-alias android:name=".IconRamadan" android:targetActivity=".MainActivity" android:icon="@mipmap/ic_ramadan"
    android:enabled="false" android:exported="true">
    <intent-filter><action android:name="android.intent.action.MAIN" /><category android:name="android.intent.category.LAUNCHER" /></intent-filter>
</activity-alias>
```

```kotlin
icons = IconSwitcher(this, main = "com.shop.MainActivity", aliases = mapOf("IconRamadan" to "com.shop.IconRamadan"))
```

The SDK tells the platform which icons this release holds, and switches to the icon the config names, including its schedule.

## Crashes

A fatal crash is written to disk while the app dies and sent on the next launch (up to 20 a call, 40 frames each, never the
error's message). ANRs come from Android's own record of exits (Android 11+). For readable lines, upload the release's R8
`mapping.txt` in Settings → 📱 Mobile app → crashes, or from CI through `POST /sdk-server/symbols` with a server key.

## Security

- The device key never leaves the Keystore, and every token is signed with it.
- The config is checked against `trustedKeys`. An unsigned or wrongly signed config is ignored and the last good one is
  kept.
- Every call except the config is pinned to the config's `pins` (SPKI sha256).
- A stopped phone gets `SdkBanned`: the SDK stops, calls `onBanned` and blocks the screens (`blockScreens`).
- R8: `consumer-rules.pro` keeps what the SDK needs.

iOS Live Activities do not exist on Android.

## Build and test

```
./gradlew :core:test :android:testDebugUnitTest :android:assembleRelease :fcm:assembleRelease :play:assembleRelease
```

`local.properties` names the Android SDK (`sdk.dir=…`). The Android tests run on Robolectric (SDK 33).

## License

MIT. See [LICENSE](LICENSE).
