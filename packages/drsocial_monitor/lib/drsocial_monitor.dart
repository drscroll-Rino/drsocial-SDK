/// DrSocial app performance monitoring: the app's own events (launches, screens, requests, errors, purchases,
/// notifications), batched to the store build's DrSocial endpoint. Pure Dart; the Flutter glue (error hooks, the
/// navigator observer, the app's lifecycle, a file for the queue) is `drsocial_monitor_flutter`.
library;

export 'src/catalogue.dart' show EventClass, EventSpec, kEvents;
export 'src/ids.dart' show uuid4;
export 'src/monitor.dart' show DrSocialMonitor, MonitorConfig, ScreenLoadTrace, errorKindOf, kSdkName, kSdkVersion;
export 'src/redact.dart' show looksPersonal, redactPath;
export 'src/storage.dart' show MemoryStorage, MonitorStorage;
export 'src/transport.dart' show IoTransport, MonitorTransport, TransportResponse;
