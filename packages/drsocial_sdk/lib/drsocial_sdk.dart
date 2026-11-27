/// The DrSocial mobile SDK core (pure Dart, API v1): the build's signed config, remote settings and flags, the icon to
/// show, the update rule, the device's registration and short token, and every call made with it: people, events, live,
/// notifications, in-app messages, where the installation came from, deferred links, store review, crashes, Live Activities. The platform keeps every rule; the SDK reads,
/// sends and shows. The Flutter / native glue gives the device key ([DeviceSigner]), the store proof and a place to keep
/// values ([SdkStore]).
library;

export 'src/calls.dart' show DeferredLink, DrSocialCalls, ReviewAnswer, SdkCrash, SdkEvent, SdkFrame, newSdkId;
export 'src/client.dart' show AssertionMaker, AttestationMaker, DeviceCheckMaker, DeviceSigner, DrSocialClient, MemorySdkStore, SdkBanned, SdkFailure, SdkStore;
export 'src/config.dart' show RemoteValue, SdkConfig, UpdateAdvice, UpdateNeed, rolloutBucket;
export 'src/http.dart' show IoSdkHttp, SdkHttp, SdkResponse;
export 'src/version.dart' show compareVersions;
