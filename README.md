# DrSocial SDK

The mobile SDKs for the [DrSocial](https://social.drscroll.com) platform: one SDK for any app, native, Flutter or React Native.
Every rule lives on the platform. The SDK reads the build's signed config, sends what the app does (events, sessions,
crashes, push tokens) and shows what the platform says (notifications, in-app messages, remote values, the update screen).
A feature switched off in DrSocial does nothing in the app.

| Kit | Folder | Version | Start here |
|---|---|---|---|
| Android (Kotlin, minSdk 26) | `packages/drsocial_android` | 0.1.0 | [README](packages/drsocial_android/README.md) |
| iOS 14+ (Swift, Objective-C facade) | `packages/drsocial_ios` | 0.1.0 | [README](packages/drsocial_ios/README.md) |
| Flutter / Dart | `packages/drsocial_sdk` + `packages/drsocial_monitor_flutter` | 0.2.0 | [README](packages/drsocial_sdk/README.md) |
| React Native 0.74+ | `packages/drsocial_react_native` (over the Android and iOS SDKs) | 0.1.0 | [README](packages/drsocial_react_native/README.md) |

The packages are not on Maven, CocoaPods trunk, pub.dev or npm yet. Clone this repository next to your app as
`drsocial-SDK` and add the folder you need by path, as each README shows.

Each build of your app gets its own key from DrSocial → Settings → 📱 Mobile app. The key names one store build and is not
a secret. No server key, store key or Firebase key ever goes in the app. The contract every SDK speaks is [API.md](API.md)
(API v1; a change that would break a store build becomes v2).

The same packages can be downloaded as zips from DrSocial → Settings → 📱 Mobile app.
