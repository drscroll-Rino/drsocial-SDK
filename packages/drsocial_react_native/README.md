# DrSocial for React Native

A thin bridge from JavaScript to the native DrSocial SDKs: `packages/drsocial_android` (Kotlin) and `packages/drsocial_ios`
(Swift). It does not reimplement anything. Every rule lives on the platform, and every request, key, signature, crash and
notification is handled by the native SDK. It works with the old and the new architecture (through React Native's interop
layer for modules). It needs React Native 0.74 or newer, Android minSdk 26, and iOS 14.

## Why the SDK starts natively

The SDK starts in native code, before React. This way crashes, notifications that open the app, the first open and a
stopped phone are all handled even when JavaScript has not loaded yet, or never loads. The bridge then talks to that
running SDK. Events that happen before JavaScript listens (a link from a notification at a cold start, for example) wait,
up to 20, and are delivered once JavaScript listens.

## Install

The packages are not on npm or Maven yet. Install them from a checkout of `drsocial-SDK`:

```sh
npm install ../drsocial-SDK/packages/drsocial_react_native
```

### Android

In `android/settings.gradle`, after React Native's own lines, add the native SDK so Gradle builds it with the app:

```groovy
includeBuild('../../drsocial-SDK/packages/drsocial_android') {
    dependencySubstitution {
        substitute(module('com.drsocial:drsocial-sdk-play')).using(project(':play'))
        substitute(module('com.drsocial:drsocial-sdk-android')).using(project(':android'))
        substitute(module('com.drsocial:drsocial-sdk-core')).using(project(':core'))
        substitute(module('com.drsocial:drsocial-sdk-fcm')).using(project(':fcm'))
    }
}
```

In `MainApplication.kt`:

```kotlin
override fun onCreate() {
    super.onCreate()
    DrSocialReact.start(this, DrSocialOptions(
        buildKey = "<32 hex from Settings → 📱 Mobile app, one per store build>",
        trustedKeys = mapOf("v1" to "<the platform's Ed25519 public key, base64>"),
        notificationIcon = R.drawable.ic_notification,
        attest = PlayIntegrity.maker(this, cloudProjectNumber = 123456789L),
        referrer = PlayInstallReferrer.reader(this),
    ))
    // ... then React Native's own loading
}
```

For notifications through Firebase, add `implementation 'com.drsocial:drsocial-sdk-fcm:0.1.0'` and `google-services.json`, as in
the Android SDK's README. If the app already uses `@react-native-firebase/messaging`, remove the SDK's service with
`tools:node="remove"`, then hand tokens and data messages to `DrSocialMessaging` from the app's own service. Huawei Push Kit:
see the Android SDK's README.

### iOS

In `ios/Podfile`, inside the app's target:

```ruby
pod 'DrSocial', :path => '../../drsocial-SDK/packages/drsocial_ios'
```

Then run `cd ios && pod install`. Autolinking adds `DrSocialReactNative`.

In `AppDelegate.swift`:

```swift
import DrSocial
import DrSocialReactNative

func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    DrSocialReact.start(DrSocialOptions(buildKey: "<32 hex>", trustedKeys: ["v1": "<base64>"]))
    UNUserNotificationCenter.current().delegate = self
    // ... then React Native's own loading
}
```

The notification delegate methods, the Notification Service Extension, App Attest and the Privacy Manifest are the same as
in the iOS SDK's README. An Objective-C AppDelegate calls `[DrSocialReact startWithBuildKey:… trustedKeys:…]`.

## JavaScript

```ts
import DrSocial from '@drsocial/react-native';

DrSocial.catchJsErrors();                            // once, at the top of index.js

await DrSocial.identify('user-42', { identityHash, traits: { plan: 'gold' }, analytics: true, messages: true });
DrSocial.track('purchase', { value: 250 });          // kept on the phone, sent in batches; offline is fine
DrSocial.screen('product/123');                      // from your navigation's state change
DrSocial.reportError(error);                         // a caught error, with its JavaScript frames

if (DrSocial.bool('checkout_v2')) { /* … */ }        // remote values: string · bool · number · value
const update = DrSocial.update();                    // { need: 'none' | 'suggested' | 'required', url, message }
await DrSocial.askReviewIfDue();                     // after a success, never on launch

const list = await DrSocial.messages();              // in-app messages, inbox, surveys, tours
await DrSocial.messageEvent(list[0].id, 'shown');

DrSocial.on('link', (link) => navigation.navigate(...));   // a notification's, a button's, a link after install
DrSocial.on('messages', (list) => show(list));
DrSocial.on('banned', ({ message, until }) => { /* the SDK already blocks the screens */ });

const url = await DrSocial.siteUrl('https://shop.example/cart');    // a stop on the phone holds on the site too
DrSocial.requestPush();                              // iOS; on Android 13+ ask with PermissionsAndroid
DrSocial.liveActivity('start', 'DeliveryAttributes', undefined, pushToStartToken);   // iOS
```

Event names: a lowercase letter first, then lowercase letters, digits and `_`, up to 64 characters. Values: up to 20 plain
values (text up to 200 characters, numbers, true/false, null). Anything else is dropped before it reaches the native SDK,
because the platform would refuse it anyway.

JavaScript errors: on Android they are kept on the phone like any caught error. Their type is
`com.drsocial.reactnative.JavaScriptError` and their frames are `js.<function>` with the bundle file and line. On iOS they
are sent right away with type `JavaScript.<name>`. Neither phone sends the message (the same rule as every crash). A fatal
error that closes the app is also caught by the native crash reporter.

## Checks

```sh
npm install && npm run type-check && npm test        # the JavaScript part (vitest, with a stand-in for react-native)
```

The Android bridge was compiled against `react-android` 0.88.1 and the SDK. The iOS bridge needs Xcode and a React Native
app to build: open the app's workspace after `pod install`.
