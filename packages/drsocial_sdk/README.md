# drsocial_sdk

The DrSocial SDK core for Dart and Flutter apps (pure Dart, API v1). It reads the build's signed config (remote values
and flags, the icon to show, the update rule), registers the device, keeps its short token, and makes every call with it:
people, events, live sessions, push tokens, in-app messages, attribution, deferred links, store review, crashes and Live
Activities. Every rule lives on the platform; the SDK reads, sends and shows.

## Add it

Clone the SDK next to your app and add the package by path:

```yaml
dependencies:
  drsocial_sdk:
    path: ../drsocial-SDK/packages/drsocial_sdk
```

For the Flutter glue (the icon, the update screen, the app's own monitoring) add `drsocial_monitor_flutter` the same way.

## Use it

```dart
import 'package:drsocial_sdk/drsocial_sdk.dart';

final client = DrSocialClient(
  buildKey: '<the build key from DrSocial → Settings → Mobile app>',
  installId: installId,          // your own random id, kept for the installation
  trustedKeys: {'v1': '<the platform\'s Ed25519 public key>'},
  appVersion: '1.0.0',
);

final config = await client.refresh();
final showBanner = config.value('show_banner', false, installId: installId, appVersion: '1.0.0');
```

`client.use(signer, ...)` once with the device key from the native glue (`DeviceSigner`: Android Keystore, iOS Secure
Enclave), then the calls in `DrSocialCalls` (`identify`, `track`, `live`, `pushToken`, `messages`, `crashes`…) go out with
the token. A stopped phone throws `SdkBanned`. The contract every call follows is `API.md`.

## License

MIT. See [LICENSE](LICENSE).
