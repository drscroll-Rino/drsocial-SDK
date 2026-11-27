import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'catalogue.dart';
import 'ids.dart';
import 'redact.dart';
import 'storage.dart';
import 'transport.dart';

const kSdkName = 'drsocial_monitor';
const kSdkVersion = '0.1.0';

/// What the app is set up with. [endpoint] is the build's own DrSocial address (Business Performance → Apps →
/// Applications → Key): it names one store build, so it is not a secret and is the only DrSocial value in the app.
/// No store key, Firebase key or DrSocial login ever goes here.
class MonitorConfig {
  const MonitorConfig({
    required this.endpoint,
    required this.appVersion,
    this.build = '',
    this.osVersion = '',
    this.deviceClass = 'other',
    this.enabled = true,
    this.batchSize = 50,
    this.flushInterval = const Duration(seconds: 30),
    this.maxQueue = 1000,
    this.sessionTimeout = const Duration(minutes: 30),
    this.log,
  });

  final Uri endpoint;
  final String appVersion;
  final String build;
  final String osVersion;

  /// phone · tablet · other
  final String deviceClass;

  /// false: nothing is recorded or sent (a build or a country where the company does not measure).
  final bool enabled;

  /// Events per batch (the platform takes 100 at most).
  final int batchSize;
  final Duration flushInterval;

  /// Events kept while offline; past it the oldest are dropped first.
  final int maxQueue;

  /// A new session after this long in the background.
  final Duration sessionTimeout;

  /// Debug lines (never the events' contents).
  final void Function(String line)? log;
}

/// The monitor: records the catalogue's events, keeps them (on disk through [MonitorStorage]) and sends them in
/// batches to the build's endpoint, waiting longer after each failure. Operational events (launches, screens,
/// requests, errors) are diagnostics; usage and sales events are recorded only once [setAnalyticsConsent] is true.
/// It never throws into the app: a wrong event is dropped and, with [MonitorConfig.log], said why.
class DrSocialMonitor {
  DrSocialMonitor._(this.config, this._storage, this._transport, this._now);

  static const _queueKey = 'drsocial_monitor.queue';
  static const _installKey = 'drsocial_monitor.install';
  static const _consentKey = 'drsocial_monitor.consent';
  static const _versionKey = 'drsocial_monitor.version';

  final MonitorConfig config;
  final MonitorStorage _storage;
  final MonitorTransport _transport;
  final DateTime Function() _now;

  final List<Map<String, Object?>> _queue = [];
  String _install = '';
  String _session = '';
  bool _consent = false;
  DateTime? _backgroundAt;
  DateTime _sessionStart = DateTime.fromMillisecondsSinceEpoch(0);
  String _screen = '';

  int _batch = 50;
  bool _sending = false;
  bool _stopped = false;
  DateTime? _retryAt;
  int _failures = 0;
  Timer? _timer;
  Future<void> _saving = Future.value();
  Future<void> _inflight = Future.value();

  /// Starts the monitor: reads the installation id (or makes one), the consent and what was not sent last time, and
  /// records `app_update_detected` when the version changed since the last start.
  static Future<DrSocialMonitor> start(
    MonitorConfig config, {
    required MonitorStorage storage,
    MonitorTransport? transport,
    DateTime Function()? now,
    bool timer = true,
  }) async {
    final m = DrSocialMonitor._(config, storage, transport ?? IoTransport(), now ?? DateTime.now);
    await m._load();
    if (timer && config.enabled) {
      m._timer = Timer.periodic(config.flushInterval, (_) => unawaited(m.flush()));
    }
    return m;
  }

  bool get analyticsConsent => _consent;

  /// The current session's id (random, new after [MonitorConfig.sessionTimeout] in the background).
  String get sessionId => _session;

  /// Events waiting to be sent.
  int get pending => _queue.length;

  /// The key was refused (replaced or removed): nothing more is sent until the app is updated.
  bool get stopped => _stopped;

  Future<void> _load() async {
    _batch = min(max(config.batchSize, 1), 100);
    _install = await _storage.read(_installKey) ?? '';
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(_install)) {
      _install = randomId();
      await _storage.write(_installKey, _install);
    }
    _consent = await _storage.read(_consentKey) == '1';
    final saved = await _storage.read(_queueKey);
    if (saved != null) {
      try {
        final list = jsonDecode(saved);
        if (list is List) {
          _queue.addAll(list.whereType<Map<String, dynamic>>().map((e) => Map<String, Object?>.from(e)));
        }
      } catch (_) {}
    }
    _newSession();
    final before = await _storage.read(_versionKey);
    if (before != config.appVersion) {
      await _storage.write(_versionKey, config.appVersion);
      if (before != null && before.isNotEmpty) track('app_update_detected', {'from_version': before});
    }
  }

  /// The user's answer about usage analytics (screens, searches, carts, purchases, notifications). Kept on the phone;
  /// turning it off drops the usage and sales events not sent yet.
  Future<void> setAnalyticsConsent(bool granted) async {
    _consent = granted;
    await _storage.write(_consentKey, granted ? '1' : '0');
    if (!granted) {
      _queue.removeWhere((e) => e['class'] != EventClass.operational.name);
      _save();
    }
  }

  /// Records one catalogue event. Returns whether it was kept: an unknown event, a missing required property or a
  /// usage event without consent is not.
  bool track(String name, [Map<String, Object?> props = const {}, String? screen]) {
    if (!config.enabled || _stopped) return false;
    final spec = kEvents[name];
    if (spec == null) return _drop('unknown event $name');
    if (spec.eventClass != EventClass.operational && !_consent) return false;
    final clean = <String, Object?>{};
    for (final entry in props.entries) {
      if (!spec.allows(entry.key)) continue;
      final v = _value(entry.key, entry.value);
      if (v != null) clean[entry.key] = v;
    }
    for (final p in spec.required) {
      if (!clean.containsKey(p)) return _drop('$name without $p');
    }
    final where = redactPath(screen ?? _screen);
    _queue.add({
      'id': uuid4(),
      'name': name,
      'v': spec.version,
      'at': _now().toUtc().toIso8601String(),
      if (where.isNotEmpty) 'screen': where,
      'props': clean,
      'class': spec.eventClass.name,
    });
    while (_queue.length > config.maxQueue) {
      _queue.removeAt(0);
    }
    _save();
    if (_queue.length >= _batch) unawaited(flush());
    return true;
  }

  // ---- shortcuts ------------------------------------------------------------------------------------------------

  /// The app is up: cold (a new process), warm or hot; [duration] from the process start when known.
  void appLaunch({String startType = 'cold', Duration? duration}) =>
      track('app_launch', {'start_type': startType, if (duration != null) 'duration_ms': duration.inMilliseconds});

  /// A screen was shown (a usage event: needs consent). Also sets the screen later events are tied to.
  void screenView(String screen, {String? from}) {
    final previous = _screen;
    _screen = screen;
    track('screen_view', {'screen': screen, 'from_screen': from ?? previous}, screen);
  }

  /// Starts timing a screen's load; complete the returned trace when its content is shown.
  ScreenLoadTrace startScreenLoad(String screen) {
    final trace = ScreenLoadTrace._(this, screen, uuid4(), _now());
    track('screen_load_started', {'screen': screen, 'trace_id': trace.id}, screen);
    return trace;
  }

  /// One API call, timed: [send] runs as given and its result or error is passed on unchanged. [statusOf] reads the
  /// HTTP status from the result. The endpoint is kept without query and ids; nothing of the request or answer is.
  Future<T> traceRequest<T>(String endpoint, String method, Future<T> Function() send, {int Function(T result)? statusOf}) async {
    final started = _now();
    final requestId = uuid4();
    try {
      final result = await send();
      final status = statusOf?.call(result) ?? 200;
      recordRequest(endpoint, method, status: status, duration: _now().difference(started), requestId: requestId);
      return result;
    } catch (e) {
      recordRequest(endpoint, method, error: errorKindOf(e), duration: _now().difference(started), requestId: requestId);
      rethrow;
    }
  }

  /// A finished API call: completed with [status], or failed with [error] (timeout · offline · dns · tls · http ·
  /// cancelled · parse · other). A status of 400 or more with no [error] counts as an `http` failure.
  void recordRequest(String endpoint, String method, {int? status, String? error, required Duration duration, String? requestId, int? responseBytes, String? networkType}) {
    final failed = error != null || (status != null && status >= 400);
    track(failed ? 'api_request_failed' : 'api_request_completed', {
      'endpoint': endpoint,
      'method': method.toLowerCase(),
      'request_id': requestId ?? uuid4(),
      'duration_ms': duration.inMilliseconds,
      if (status != null) 'status': status,
      if (failed) 'error_kind': error ?? 'http',
      if (responseBytes != null && !failed) 'response_bytes': responseBytes,
      if (networkType != null) 'network_type': networkType,
      if (_screen.isNotEmpty) 'screen': _screen,
    });
  }

  /// An error the app caught: its type only (never its message, which can hold the user's data), whether it ended the
  /// app, and an optional fingerprint the app computes to group the same error.
  void error(Object error, {bool fatal = false, String? fingerprint}) {
    track('app_error_detected', {
      'error_type': error.runtimeType.toString(),
      'fatal': fatal,
      if (fingerprint != null) 'fingerprint': fingerprint,
      if (_screen.isNotEmpty) 'screen': _screen,
    });
    if (fatal) unawaited(flush());
  }

  /// The app went to the background: the session's length so far, and what is waiting is sent.
  void background() {
    _backgroundAt = _now();
    track('app_background', {'session_ms': _now().difference(_sessionStart).inMilliseconds});
    _save();
    unawaited(flush());
  }

  /// The app came back: a new session when it was away longer than [MonitorConfig.sessionTimeout].
  void foreground() {
    final away = _backgroundAt == null ? Duration.zero : _now().difference(_backgroundAt!);
    if (away > config.sessionTimeout) _newSession();
    _backgroundAt = null;
    track('app_foreground', {'resume_ms': away.inMilliseconds});
  }

  // ---- sending --------------------------------------------------------------------------------------------------

  /// Sends what is waiting, one batch at a time, until the queue is empty or a batch has to wait.
  /// A flush already running is joined, not started twice.
  Future<void> flush() {
    if (_sending) return _inflight;
    if (_stopped || !config.enabled) return Future.value();
    if (_retryAt != null && _now().isBefore(_retryAt!)) return Future.value();
    _sending = true;
    return _inflight = _send();
  }

  Future<void> _send() async {
    try {
      while (_queue.isNotEmpty && !_stopped) {
        final take = min(_batch, _queue.length);
        final batch = _queue.sublist(0, take);
        TransportResponse res;
        try {
          res = await _transport.post(config.endpoint, _body(batch));
        } catch (_) {
          _wait();
          return;
        }
        if (res.status == 202 || res.status == 200) {
          _queue.removeRange(0, take);
          _failures = 0;
          _retryAt = null;
          if (res.body['disabled'] == true) {
            // Monitoring is off for this build: try again in an hour.
            _retryAt = _now().add(const Duration(hours: 1));
            _save();
            return;
          }
        } else if (res.status == 413 && take > 1) {
          _batch = max(1, take ~/ 2);
        } else if (res.status == 404) {
          _log('the key was refused: nothing more is sent');
          _stopped = true;
          _queue.clear();
        } else if (res.status == 400 || res.status == 413) {
          _log('a batch was refused (${res.status}) and dropped');
          _queue.removeRange(0, take);
        } else {
          _wait();
          return;
        }
        _save();
      }
    } finally {
      _sending = false;
    }
  }

  /// Stops the timer and saves what is waiting.
  Future<void> dispose() async {
    _timer?.cancel();
    _save();
    await _saving;
  }

  String _body(List<Map<String, Object?>> batch) => jsonEncode({
        'install_id': _install,
        'session_id': _session,
        'app': {'version': config.appVersion, 'build': config.build},
        'device': {'os_version': config.osVersion, 'class': config.deviceClass},
        'sdk': {'name': kSdkName, 'version': kSdkVersion},
        'events': [for (final e in batch) Map.of(e)..remove('class')],
      });

  void _wait() {
    _failures++;
    final seconds = min(300, 2 << min(_failures, 8));
    // A little jitter, so many phones coming back online do not send at the same second.
    _retryAt = _now().add(Duration(seconds: seconds, milliseconds: Random().nextInt(1000)));
    _save();
  }

  void _newSession() {
    _session = randomId();
    _sessionStart = _now();
  }

  void _save() {
    final snapshot = jsonEncode(_queue);
    _saving = _saving.then((_) => _storage.write(_queueKey, snapshot)).catchError((_) {});
  }

  bool _drop(String why) {
    _log('event dropped: $why');
    return false;
  }

  void _log(String line) => config.log?.call('[drsocial_monitor] $line');

  static const _ints = {
    'duration_ms': 600000, 'resume_ms': 600000, 'session_ms': 86400000, 'first_content_ms': 600000, 'data_ms': 600000, 'images_ms': 600000,
    'status': 599, 'response_bytes': 100000000, 'results': 100000, 'quantity': 10000, 'items': 10000,
  };
  static const _paths = {'endpoint', 'screen', 'from_screen'};

  static Object? _value(String prop, Object? v) {
    final top = _ints[prop];
    if (top != null) {
      if (v is num && v >= 0 && v <= top) return v.round();
      return null;
    }
    if (prop == 'fatal') return v is bool ? v : null;
    if (v is! String) return null;
    if (_paths.contains(prop)) {
      final p = redactPath(v);
      return p.isEmpty ? null : p;
    }
    final s = v.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '').trim();
    if (s.isEmpty || s.length > 120 || looksPersonal(s, ref: kRefs.contains(prop))) return null;
    return s;
  }
}

/// A screen's load being timed: [complete] once, when its content is shown (or it failed).
class ScreenLoadTrace {
  ScreenLoadTrace._(this._monitor, this.screen, this.id, this._started);

  final DrSocialMonitor _monitor;
  final String screen;
  final String id;
  final DateTime _started;
  bool _done = false;

  /// success · error · cancelled · timeout · empty
  void complete({String outcome = 'success', Duration? firstContent, Duration? data, Duration? images}) {
    if (_done) return;
    _done = true;
    _monitor.track('screen_load_completed', {
      'screen': screen,
      'trace_id': id,
      'duration_ms': _monitor._now().difference(_started).inMilliseconds,
      'outcome': outcome,
      if (firstContent != null) 'first_content_ms': firstContent.inMilliseconds,
      if (data != null) 'data_ms': data.inMilliseconds,
      if (images != null) 'images_ms': images.inMilliseconds,
    }, screen);
  }
}

/// The kind of a failed request, from its error's type name only.
String errorKindOf(Object e) {
  final n = e.runtimeType.toString();
  if (n.contains('Timeout')) return 'timeout';
  if (n.contains('Socket')) return 'offline';
  if (n.contains('Handshake') || n.contains('Tls') || n.contains('Certificate')) return 'tls';
  if (n.contains('Format')) return 'parse';
  if (n.contains('Cancel')) return 'cancelled';
  return 'other';
}
