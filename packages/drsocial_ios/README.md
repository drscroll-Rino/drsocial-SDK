# DrSocial SDK for iOS (Swift)

This is the native iOS SDK for the DrSocial platform. It covers API v1 of the contract
(`API.md` at the root of this repository). It follows the Dart core
(`packages/drsocial_sdk` 0.2.0) and the Kotlin SDK (`packages/drsocial_android`) rule for rule, with the same names and the
same test vectors. The platform holds every rule. The SDK reads the signed config, sends what the app does, and shows what
the platform says. A feature switched off in the config does nothing.

Requirements: iOS 14+, Swift 5.9+ (Xcode 15+). The package has no dependencies, only Apple frameworks: CryptoKit,
DeviceCheck, UserNotifications, StoreKit, CoreHaptics and ActivityKit.

| Part | What it is |
| --- | --- |
| Core (`Sources/DrSocial/*.swift`) | Pure Swift, no UIKit, so it also builds on macOS. Holds the signed config (Ed25519 checked with CryptoKit), remote values and the sha256 rollout bucket, `iconAt` over the schedule, the update rule, device registration and short tokens (P-256), and every call: identify, sign-out, live, track, push-token, push-opened, messages, attribution, deferred, review, icons, crashes, live-activity. Also the notification data, crash frames and the live session rule. All the tests cover this part. |
| Apple layer (`Sources/DrSocial/Apple/`) | `DrSocial`: start it once and it handles the rest. Also: the Secure Enclave key (Keychain fallback), App Attest and DeviceCheck, the crash reporter (NSException + signals), push helpers, haptics, the alternate icon, `SKStoreReviewController`, Live Activities, the full-screen blocks, and `DRSocial`, the Objective-C facade. |

## Install (Swift Package Manager)

SwiftPM can add a package by git URL only when its `Package.swift` is at the repository's root. This package lives in
`packages/drsocial_ios`, so for now add it from a checkout:

- **In Xcode:** File → Add Package Dependencies… → **Add Local…** → choose `packages/drsocial_ios`.
- **In `Package.swift`:**

```swift
.package(path: "../drsocial-SDK/packages/drsocial_ios")
// …
.target(name: "App", dependencies: [.product(name: "DrSocial", package: "drsocial_ios")])
```

To install by URL with a version (`.package(url:from:)`), the package needs its own repository or a mirror tagged with
versions.

## Setup

```swift
import DrSocial

@main
final class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ app: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        var o = DrSocialOptions(
            buildKey: "<32 hex from Settings → 📱 Mobile app, one per store build>",
            trustedKeys: ["v1": "<the platform's Ed25519 public key, base64>"])
        o.onLink = { link in Router.open(link) }
        o.onConfig = { _ in /* DrSocial.shared.bool("checkout_v2") … */ }
        o.onMessages = { list in /* in-app messages, inbox, surveys, tours */ }
        DrSocial.start(o)

        UNUserNotificationCenter.current().delegate = self
        DrSocial.shared.requestPush()            // or requestPush(provisional: true): quietly, with no prompt
        return true
    }
}
```

```swift
let sdk = DrSocial.shared
sdk.identify("user-42", identityHash: hashFromYourServer, traits: ["plan": "gold"], analytics: true, messages: true)
sdk.track("purchase", ["value": 250])      // kept on the phone, sent in batches of up to 100; offline is fine
sdk.screen("product/123")                  // the id becomes {id}
sdk.reportError(error)                     // a caught error (kind non_fatal); its message is never sent
let url = await sdk.siteUrl("https://shop.example/cart")   // adds drs_d=<device> so a ban also holds on the site
if sdk.update.need == .suggested { /* show your own banner */ }
sdk.askReviewIfDue()                       // after a success, never on launch → SKStoreReviewController
```

On start, the SDK:

- reads the config, honouring its `ttl`;
- sends the crashes from the last launch;
- sends attribution once (iOS has no install referrer, so it sends `options.openingLink` when there is one);
- asks once for a deferred link;
- applies the scheduled alternate icon (`setAlternateIconName`) and reports the icons;
- reads the messages.

Live sessions follow the app's foreground and background. Each one is a new session after 30 minutes away.

When a call answers `403 device_banned`, the SDK stops. It calls `onBanned(message, until)` and shows a full-screen block.
Below `min_version` it shows a block that only opens the store page. To show your own screens instead, set
`blockScreens = false`.

### The device and its proofs

- **Device key:** a P-256 key made in the Secure Enclave with CryptoKit. On a device without one, such as an older
  simulator, the key is made by CryptoKit and kept in the Keychain (`AfterFirstUnlockThisDeviceOnly`).
- **hardware_id:** API.md asks for a random id kept in the Keychain, so it survives deleting the app. If the Keychain
  refuses, the SDK falls back to `identifierForVendor`.
- **DeviceCheck:** `device_check_token` is a fresh `DCDevice.current.generateToken`, sent on `devices` and on `token`.
- **App Attest:** on a phone that supports it (`DCAppAttestService.isSupported`; a real device, never the simulator),
  registration adds `attestation {kind: app_attest, token, key_id}` made over `SHA256(nonce)`. Each token adds an
  `assertion` over `SHA256("drs-token\n{key}\n{device}\n{time}\n{nonce}")`.

#### The App Attest capability

In Xcode, go to Signing & Capabilities → **+ Capability** → **App Attest**. Xcode adds this to the entitlements:

```xml
<key>com.apple.developer.devicecheck.appattest-environment</key>
<string>production</string>   <!-- development while testing -->
```

The platform checks the proof against the app id `<Team ID>.<bundle id>`. The Team ID comes from the APNs or DeviceCheck
key saved in Settings → Mobile app. A `testing` build may use `development`. If App Attest is not wanted, set
`appAttest = false`. Under `attestation: enforce`, a phone without a proof is refused.

## Push

The SDK sends the APNs device token as hex with provider `apns`. The permission is sent as `granted`, `denied` or
`provisional`, and the token is sent again whenever the token or the permission changes.

```swift
func application(_ app: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
    DrSocial.shared.setPushToken(token)
}

// Background Modes → Remote notifications: drs_silent = refresh reads the config, messages and remote values again;
// ping does nothing at all.
func application(_ app: UIApplication, didReceiveRemoteNotification info: [AnyHashable: Any],
                 fetchCompletionHandler done: @escaping (UIBackgroundFetchResult) -> Void) {
    if !DrSocial.shared.handleRemoteNotification(info, completion: done) { done(.noData) }
}

// While the app is open: drs_vibe is played with Core Haptics.
func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                            withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
    done(DrSocial.shared.willPresent(n) ?? [.banner, .sound])
}

// Opened, or a button pressed: push-opened {push, action} and the link opened through onLink.
func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse,
                            withCompletionHandler done: @escaping () -> Void) {
    DrSocial.shared.didReceive(r)
    done()
}
```

**Buttons and pictures:** add a Notification Service Extension target that also depends on `DrSocial`. Before the
notification shows, it registers the `drs_actions` category with the labels from `drs_buttons` and attaches `drs_image`:

```swift
final class NotificationService: UNNotificationServiceExtension {
    override func didReceive(_ request: UNNotificationRequest, withContentHandler handler: @escaping (UNNotificationContent) -> Void) {
        DrSocialPush.serviceExtension(request, contentHandler: handler)
    }
}
```

**Vibration:** Apple allows no custom vibration pattern for a notification. The platform sends `none` as `passive` and
`urgent` as `time-sensitive` (this needs the Time Sensitive Notifications capability). While the app is open, the SDK
plays the `drs_vibe_ms` pattern with Core Haptics.

## Live Activities

```swift
if #available(iOS 16.2, *) { DrSocialLiveActivities.observe(OrderActivityAttributes.self) }
```

This sends three kinds of call:

- the push-to-start token (`kind: start`, iOS 17.2+);
- each running activity's push token (`kind: update`, with `activity` set to the activity's id);
- `kind: end` when an activity ends.

`type` is the ActivityAttributes' Swift type name, and the widget extension must declare the same name. The app's
`ContentState` must decode the JSON the manager types. You can also call `DrSocial.shared.liveActivity(kind:type:activity:token:)`
yourself.

## Crashes

The SDK catches uncaught `NSException`s and fatal signals: SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP and SIGSYS. A
Swift `fatalError` or a forced unwrap ends in one of these signals.

- **Saving:** an exception is saved with its frames. A signal handler only calls `write()` on a file opened at start.
  At start, the SDK also saves that launch's image map (each image's name, load address and `__TEXT` size).
- **Sending:** on the next launch, while `crash_lines` is on, the SDK sends the saved crashes in batches of 20, at most
  40 frames each.
- **Frames:** each frame carries `lib` (its image's name) and `offset` (hex: the address minus the image's load
  address). With these, the platform finds the line in the symbol table uploaded for that release. Upload it with
  `nm -n` of the dSYM's binary, `kind: symbols`.
- **Privacy:** an exception's reason is never sent.

Install only one fatal-crash reporter. If the app already uses another one, set `crashes = false`.

## Objective-C

```objc
@import DrSocial;

[DRSocial startWithBuildKey:@"…" trustedKeys:@{@"v1": @"…"}];
[DRSocial identify:@"user-42" identityHash:hash];
[DRSocial track:@"purchase" properties:@{@"value": @250}];
[DRSocial setPushToken:deviceToken];
BOOL checkout = [DRSocial boolForKey:@"checkout_v2" fallback:NO];
```

## Privacy Manifest

The package includes `Sources/DrSocial/PrivacyInfo.xcprivacy`, and Xcode merges it into the app's privacy report. It
declares no tracking and no tracking domains. The data it declares is linked to the user and is not used for tracking:

| Data type | Purposes |
| --- | --- |
| Device ID | App functionality and Analytics |
| User ID | App functionality and Analytics |
| Product Interaction | Analytics |
| Crash Data | App functionality |
| Performance Data | App functionality |

It also declares two required-reason APIs:

- `UserDefaults`, reason CA92.1, for the SDK's own values.
- File timestamps, reason C617.1, for the crash files inside the app's container.

The app's own manifest must still declare whatever the app itself collects, such as the profile that `identify` sends.

## Tests

```bash
swift test                                                                                   # the core, on the Mac
xcodebuild test -scheme DrSocial -destination 'platform=iOS Simulator,name=iPhone 17'        # on a simulator
```

The tests use the Dart and Kotlin vectors:

- the token message;
- `rolloutBucket("install-1", "home.banner") = 47` and `("abc", "x") = 43`;
- `compareVersions`;
- `iconAt` over the Ramadan / Eid schedule;
- batches of 100 events and 20 crashes, with event ids kept on a retry;
- 401 `token_required` / `re_register` handled once, with a fake HTTP;
- 403 `device_banned` throwing `SdkBanned`.

They also cover:

- the Ed25519-signed config;
- a P-256 signature checked against its public key;
- App Attest at registration;
- Live Activity tokens;
- crash frame offsets and the crash files of an earlier launch;
- notification data and haptics.

The App Attest, DeviceCheck, Secure Enclave, APNs and ActivityKit calls themselves need a real device and a signed app, so
the unit tests cannot cover them.

## License

MIT. See [LICENSE](LICENSE).
