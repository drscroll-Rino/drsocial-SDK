/// Flutter glue for drsocial_monitor: one call in `main()` hooks Flutter's and the platform's error handlers, the
/// app's lifecycle (sessions, sending on background) and gives a navigator observer for screen views and loads.
library;

export 'package:drsocial_monitor/drsocial_monitor.dart';

export 'src/file_storage.dart' show FileStorage;
export 'src/flutter_monitor.dart' show DrSocialFlutter, MonitorNavigatorObserver;
