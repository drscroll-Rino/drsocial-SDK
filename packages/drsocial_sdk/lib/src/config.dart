import 'package:crypto/crypto.dart';
import 'dart:convert';

import 'version.dart';

/// One remote value as the platform sends it (stage M3).
class RemoteValue {
  const RemoteValue({required this.type, required this.value, this.rollout = 100, this.minVersion = ''});

  factory RemoteValue.fromJson(Map<String, dynamic> j) => RemoteValue(
        type: (j['type'] as String?) ?? 'string',
        value: j['value'],
        rollout: (j['rollout'] as num?)?.toInt() ?? 100,
        minVersion: (j['min_version'] as String?) ?? '',
      );

  /// bool · number · string · json.
  final String type;
  final Object? value;

  /// The share of installations (0–100) that get the value.
  final int rollout;

  /// Below this app version the value is not given ('' = every version).
  final String minVersion;
}

/// The installation's bucket for one key, 0–99: first 4 bytes of `sha256("<install id>|<key>")` mod 100. Every DrSocial SDK
/// and the platform (`RemoteControl::bucket`) use this same rule, so a rollout is stable for an installation.
int rolloutBucket(String installId, String key) {
  final d = sha256.convert(utf8.encode('$installId|$key')).bytes;
  final n = (d[0] << 24) | (d[1] << 16) | (d[2] << 8) | d[3];
  return n % 100;
}

/// What the build's config says (GET /sdk/{key}/config, API v1).
class SdkConfig {
  SdkConfig._(this.raw);

  factory SdkConfig.fromJson(Map<String, dynamic> j) => SdkConfig._(j);

  /// Every feature off and nothing remote: the first run with no network.
  static final SdkConfig empty = SdkConfig._(const {});

  final Map<String, dynamic> raw;

  Map<String, dynamic> _map(String k) => raw[k] is Map<String, dynamic> ? raw[k] as Map<String, dynamic> : const {};

  /// A feature the SDK may start; anything not named is off.
  bool feature(String name) => _map('features')[name] == true;

  Duration get ttl => Duration(seconds: (raw['ttl'] as num?)?.toInt() ?? 300);

  String? endpoint(String name) => _map('endpoints')[name] as String?;

  /// The key generation; a device registered on an older one registers again.
  int get epoch => (_map('security')['epoch'] as num?)?.toInt() ?? 1;

  bool get requireToken => _map('security')['require_token'] == true;

  /// SPKI SHA-256 pins ("sha256/…") the app may check the platform's certificate against; empty = the system's trust.
  List<String> get pins => ((_map('security')['pins'] as List<dynamic>?) ?? const []).whereType<String>().toList();

  /// The remote values, or an empty map while remote config is off.
  Map<String, RemoteValue> get remote {
    final r = raw['remote'];
    if (r is! Map<String, dynamic>) return const {};
    return {
      for (final e in r.entries)
        if (e.value is Map<String, dynamic>) e.key: RemoteValue.fromJson(e.value as Map<String, dynamic>)
    };
  }

  /// The value of [key] for this installation and app version, else [fallback]: off when the installation is outside the
  /// rollout, the app is older than `min_version`, or the type does not match [T].
  T value<T>(String key, T fallback, {required String installId, required String appVersion}) {
    final v = remote[key];
    if (v == null) return fallback;
    if (v.rollout < 100 && rolloutBucket(installId, key) >= v.rollout) return fallback;
    if (v.minVersion.isNotEmpty && compareVersions(appVersion, v.minVersion) < 0) return fallback;
    final x = v.value;
    if (x is T) return x;
    if (T == double && x is num) return x.toDouble() as T;
    return fallback;
  }

  /// The icon the app should show: an alternate icon's name, '' for the app's own, null while icon switching is off.
  /// Only names built into the release are ever returned.
  String? get icon {
    final i = raw['icon'];
    if (i is! Map<String, dynamic>) return null;
    final current = (i['current'] as String?) ?? '';
    final available = ((i['available'] as List<dynamic>?) ?? const []).whereType<String>();
    return current.isEmpty || available.contains(current) ? current : '';
  }

  /// The icon to show at [now], applying the coming switches of `schedule` even offline: between `from` and `to` show its
  /// `icon`; when two cover [now] the one that started last wins; outside them the `default`. Null while switching is off.
  String? iconAt(DateTime now) {
    final i = raw['icon'];
    if (i is! Map<String, dynamic>) return null;
    final available = ((i['available'] as List<dynamic>?) ?? const []).whereType<String>().toSet();
    String pick(String name) => name.isEmpty || available.contains(name) ? name : '';
    DateTime? started;
    String? chosen;
    for (final s in ((i['schedule'] as List<dynamic>?) ?? const []).whereType<Map<String, dynamic>>()) {
      final from = DateTime.tryParse((s['from'] as String?) ?? ''), to = DateTime.tryParse((s['to'] as String?) ?? '');
      if (from == null || to == null || now.isBefore(from) || !now.isBefore(to)) continue;
      if (started == null || from.isAfter(started)) {
        started = from;
        chosen = (s['icon'] as String?) ?? '';
      }
    }
    if (chosen != null) return pick(chosen);
    // `current` is the platform's answer when the config was read; once a switch it named has ended, fall back to `default`.
    final current = (i['current'] as String?) ?? '';
    final inSchedule = ((i['schedule'] as List<dynamic>?) ?? const []).whereType<Map<String, dynamic>>().any((s) => s['icon'] == current);
    return pick(inSchedule ? ((i['default'] as String?) ?? '') : current);
  }

  /// The store-review rules while `store_review` is on, else null.
  Map<String, dynamic>? get review => raw['review'] is Map<String, dynamic> ? raw['review'] as Map<String, dynamic> : null;

  /// The query name the app adds to the company's own site's address with the device id (`drs_d`), so a stopped phone is
  /// refused there too.
  String get siteBanParam => (_map('bans')['site_param'] as String?) ?? 'drs_d';

  /// What the app must do about updating, for [appVersion].
  UpdateAdvice update(String appVersion) {
    final u = raw['update'];
    if (u is! Map<String, dynamic>) return const UpdateAdvice(UpdateNeed.none);
    final min = (u['min_version'] as String?) ?? '', latest = (u['latest_version'] as String?) ?? '';
    final url = (u['url'] as String?) ?? '', message = (u['message'] as String?) ?? '';
    if (min.isNotEmpty && compareVersions(appVersion, min) < 0) return UpdateAdvice(UpdateNeed.required, url: url, message: message);
    if (latest.isNotEmpty && compareVersions(appVersion, latest) < 0) return UpdateAdvice(UpdateNeed.suggested, url: url, message: message);
    return const UpdateAdvice(UpdateNeed.none);
  }
}

enum UpdateNeed { none, suggested, required }

class UpdateAdvice {
  const UpdateAdvice(this.need, {this.url = '', this.message = ''});

  final UpdateNeed need;

  /// The store page (https) to open, '' when the company gave none.
  final String url;
  final String message;
}
