import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:drsocial_monitor/drsocial_monitor.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'file_storage.dart';

/// Starts drsocial_monitor in a Flutter app:
///
/// ```dart
/// Future<void> main() async {
///   WidgetsFlutterBinding.ensureInitialized();
///   final monitor = await DrSocialFlutter.start(
///     endpoint: const String.fromEnvironment('DRSOCIAL_ENDPOINT'),
///     appVersion: '1.4.0',
///     build: '140',
///   );
///   runApp(MaterialApp(navigatorObservers: [monitor.navigatorObserver], home: const Home()));
/// }
/// ```
///
/// The endpoint is the build's own address from Business Performance → Apps → Applications → Key (one per store
/// build and environment). It is not a secret; no store, Firebase or DrSocial login key ever goes in the app.
class DrSocialFlutter with WidgetsBindingObserver {
  DrSocialFlutter._(this.monitor);

  final DrSocialMonitor monitor;
  late final MonitorNavigatorObserver navigatorObserver = MonitorNavigatorObserver(monitor);

  /// [endpoint] empty = nothing is recorded (a build without monitoring). [launchStarted] is when `main()` began, for
  /// the cold start's duration.
  static Future<DrSocialFlutter> start({
    required String endpoint,
    required String appVersion,
    String build = '',
    DateTime? launchStarted,
    bool hookErrors = true,
    void Function(String line)? log,
  }) async {
    final started = launchStarted ?? DateTime.now();
    final uri = Uri.tryParse(endpoint);
    final enabled = uri != null && uri.scheme == 'https' && uri.host.isNotEmpty;
    final view = PlatformDispatcher.instance.implicitView;
    final shortest = view == null ? 0.0 : view.physicalSize.shortestSide / view.devicePixelRatio;
    final monitor = await DrSocialMonitor.start(
      MonitorConfig(
        endpoint: uri ?? Uri(),
        appVersion: appVersion,
        build: build,
        osVersion: _osVersion(),
        deviceClass: shortest == 0 ? 'other' : (shortest >= 600 ? 'tablet' : 'phone'),
        enabled: enabled,
        log: log ?? (kDebugMode ? debugPrint : null),
      ),
      storage: await FileStorage.open(),
    );
    final glue = DrSocialFlutter._(monitor);
    WidgetsBinding.instance.addObserver(glue);
    if (hookErrors) glue._hookErrors();
    // The cold start ends at the first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      monitor.appLaunch(startType: 'cold', duration: DateTime.now().difference(started));
    });
    return glue;
  }

  /// The user's answer about usage analytics; ask it in the app's own words before turning it on.
  Future<void> setAnalyticsConsent(bool granted) => monitor.setAnalyticsConsent(granted);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) monitor.background();
    if (state == AppLifecycleState.resumed) monitor.foreground();
  }

  void _hookErrors() {
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      monitor.error(details.exception, fatal: false, fingerprint: _fingerprint(details.exception, details.stack));
      previous?.call(details);
    };
    final platformPrevious = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stack) {
      monitor.error(error, fatal: true, fingerprint: _fingerprint(error, stack));
      return platformPrevious?.call(error, stack) ?? false;
    };
  }

  /// The error's type and its first frame in the app's own code (file and line), never its message: the same bug
  /// gives the same fingerprint, and nothing the user typed is in it.
  static String? _fingerprint(Object error, StackTrace? stack) {
    if (stack == null) return null;
    final frame = stack.toString().split('\n').map((l) => RegExp(r'\((package:[^)]+:\d+)').firstMatch(l)?.group(1)).whereType<String>().firstWhere(
          (f) => !f.startsWith('package:flutter/') && !f.startsWith('package:drsocial_monitor'),
          orElse: () => '',
        );
    if (frame.isEmpty) return null;
    final text = '${error.runtimeType}@$frame';
    return text.length > 120 ? text.substring(0, 120) : text;
  }

  static String _osVersion() {
    final m = RegExp(r'(\d+(\.\d+){0,2})').firstMatch(Platform.operatingSystemVersion);
    return m?.group(1) ?? '';
  }
}

/// Screen views (with consent) and each pushed route's load until its first frame. A route is named by its
/// `RouteSettings.name` (`/product/123` is kept as `/product/{id}`); an unnamed route is not recorded.
class MonitorNavigatorObserver extends NavigatorObserver {
  MonitorNavigatorObserver(this.monitor);

  final DrSocialMonitor monitor;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => _shown(route, previousRoute, timed: true);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (newRoute != null) _shown(newRoute, oldRoute, timed: true);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute != null) _shown(previousRoute, route, timed: false);
  }

  void _shown(Route<dynamic> route, Route<dynamic>? from, {required bool timed}) {
    final name = route.settings.name;
    if (name == null || name.isEmpty) return;
    monitor.screenView(name, from: from?.settings.name);
    if (!timed) return;
    final trace = monitor.startScreenLoad(name);
    WidgetsBinding.instance.addPostFrameCallback((_) => trace.complete());
  }
}
