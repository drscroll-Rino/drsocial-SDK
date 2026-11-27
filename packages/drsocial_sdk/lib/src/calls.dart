import 'dart:math';

import 'client.dart';
import 'http.dart';

/// One event the app tracks (`POST /sdk/{key}/track`). [id] is made once and sent again on a retry, so it is kept once.
class SdkEvent {
  SdkEvent(this.name, {Map<String, Object?>? props, DateTime? at, String? id})
      : props = props ?? const {},
        at = at ?? DateTime.now().toUtc(),
        id = id ?? newSdkId();

  final String id;
  final String name;
  final DateTime at;

  /// ≤ 20 plain values (text, numbers, true/false); never personal data.
  final Map<String, Object?> props;

  Map<String, Object?> toJson() => {'id': id, 'name': name, 'at': at.toUtc().toIso8601String(), if (props.isNotEmpty) 'props': props};
}

/// One frame of a crash's stack, as the runtime gives it. [offset] (hex) = the address in its image minus the image's load
/// address, on iOS, so the release's symbol table names it.
class SdkFrame {
  const SdkFrame(this.fn, {this.file, this.line, this.lib, this.offset});

  final String fn;
  final String? file;
  final int? line;
  final String? lib;
  final String? offset;

  Map<String, Object?> toJson() => {
        'fn': fn,
        if (file != null) 'file': file,
        if (line != null) 'line': line,
        if (lib != null) 'lib': lib,
        if (offset != null) 'offset': offset,
      };
}

/// A crash to report (on the next launch for a fatal one). Never put personal data in [message].
class SdkCrash {
  SdkCrash({
    required this.kind,
    required this.type,
    required this.frames,
    this.message,
    this.appVersion,
    this.osVersion,
    this.screen,
    DateTime? at,
    String? id,
  })  : at = at ?? DateTime.now().toUtc(),
        id = id ?? newSdkId();

  final String id;

  /// fatal · non_fatal · anr.
  final String kind;
  final String type;
  final String? message;
  final List<SdkFrame> frames;
  final String? appVersion;
  final String? osVersion;
  final String? screen;
  final DateTime at;

  Map<String, Object?> toJson() => {
        'id': id,
        'at': at.toUtc().toIso8601String(),
        'kind': kind,
        'type': type,
        if (message != null) 'message': message,
        'frames': [for (final f in frames.take(40)) f.toJson()],
        if (appVersion != null) 'app_version': appVersion,
        if (osVersion != null) 'os_version': osVersion,
        if (screen != null) 'screen': screen,
      };
}

/// What the store-review question answered: [ask] = open the store's own review box now.
class ReviewAnswer {
  const ReviewAnswer(this.ask, [this.reason = '']);

  final bool ask;

  /// off · asked_recently · too_new · too_few_sessions · no_event · recent_crash (when [ask] is false).
  final String reason;
}

/// A link that opened a screen after a first install (`deferred`): open [link] as if it had been tapped. [likely] = matched
/// by the network within 2 hours, not by the store's referrer.
class DeferredLink {
  const DeferredLink(this.code, this.link, {this.likely = false});

  final String code;
  final String link;
  final bool likely;
}

/// A random id the platform accepts (8–64 of A–Z a–z 0–9 _ -): 24 hex characters.
String newSdkId() {
  final r = Random.secure();
  return List.generate(12, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

/// Every call of API v1 made with the device's token (call [DrSocialClient.use] first). A switch that is off answers
/// `disabled` and the call does nothing; the SDK never decides a rule itself.
extension DrSocialCalls on DrSocialClient {
  /// Links the device to the company's own user. [identityHash] = hex HMAC-SHA256(server key secret, externalId), made on the
  /// company's server; [profile] (name, email, phone) is kept only with it.
  Future<String?> identify(String externalId,
      {String? identityHash,
      Map<String, Object?>? traits,
      bool? analytics,
      bool? messages,
      String? locale,
      String? country,
      Map<String, String>? profile}) async {
    final res = await _ok(await authed('POST', 'identify', {
      'external_id': externalId,
      if (identityHash != null) 'identity_hash': identityHash,
      if (traits != null) 'traits': traits,
      if (analytics != null || messages != null) 'consent': {if (analytics != null) 'analytics': analytics, if (messages != null) 'messages': messages},
      if (locale != null) 'locale': locale,
      if (country != null) 'country': country,
      if (profile != null) 'profile': profile,
    }));
    return res.json['user'] as String?;
  }

  Future<void> signOut() async => _ok(await authed('POST', 'sign-out', const <String, Object?>{}));

  /// Sends up to 100 events; answers how many were kept (0 while the person said no to analytics).
  Future<int> track(List<SdkEvent> events) async {
    var accepted = 0;
    for (var i = 0; i < events.length; i += 100) {
      final part = events.sublist(i, min(i + 100, events.length));
      final res = await _ok(await authed('POST', 'track', {
        'events': [for (final e in part) e.toJson()]
      }));
      accepted += (res.json['accepted'] as num?)?.toInt() ?? 0;
    }
    return accepted;
  }

  /// One live beat: open · screen · ping · close. Answers the seconds until the next ping, null while live is off.
  Future<int?> live(String session, String kind, {String? screen}) async {
    final res = await _ok(await authed('POST', 'live', {'session': session, 'kind': kind, if (screen != null) 'screen': screen, 'app_version': appVersion}));
    return res.json['disabled'] == true ? null : (res.json['ping'] as num?)?.toInt() ?? 30;
  }

  /// The installation's notification token: fcm · apns (hex) · hms · harmony; permission granted · denied · provisional.
  Future<bool> pushToken(String provider, String token, String permission) async =>
      _on(await _ok(await authed('POST', 'push-token', {'provider': provider, 'token': token, 'permission': permission})));

  /// The person opened a notification ([push] = its `drs_push`), or pressed one of its buttons ([action]).
  Future<void> pushOpened(String push, {String? action}) async =>
      _ok(await authed('POST', 'push-opened', {'push': push, if (action != null) 'action': action}));

  /// What this installation should have inside the app now (in-app messages, inbox, surveys, tours).
  Future<List<Map<String, dynamic>>> messages() async {
    final res = await _ok(await authed('GET', 'messages'));
    return ((res.json['messages'] as List<dynamic>?) ?? const []).whereType<Map<String, dynamic>>().toList();
  }

  /// shown · clicked · dismissed · answered · completed · read; a survey's [answer] is {question id: value}.
  Future<void> messageEvent(String id, String kind, {Map<String, Object?>? answer}) async =>
      _ok(await authed('POST', 'messages/$id/event', {'kind': kind, if (answer != null) 'answer': answer}));

  /// Where the installation came from, once on the first open (Play's install referrer, or the link that opened the app).
  Future<String?> attribution({String? referrer, String? link}) async {
    if (await store.read('attributed') != null) return null;
    final res = await _ok(await authed('POST', 'attribution', {if (referrer != null) 'referrer': referrer, if (link != null) 'link': link}));
    if (res.json['disabled'] == true) return null;
    await store.write('attributed', '1');
    return res.json['network'] as String?;
  }

  /// A link tapped before the app was installed, once on the very first open.
  Future<DeferredLink?> deferred({String? referrer}) async {
    if (await store.read('deferred') != null) return null;
    final res = await _ok(await authed('POST', 'deferred', {if (referrer != null) 'referrer': referrer}));
    if (res.json['disabled'] == true) return null;
    await store.write('deferred', '1');
    if (res.json['matched'] != true) return null;
    return DeferredLink((res.json['code'] as String?) ?? '', (res.json['link'] as String?) ?? '', likely: res.json['by'] == 'network');
  }

  /// Whether to open the store's review box now; ask at a calm moment, never on launch or after an error.
  Future<ReviewAnswer> review() async {
    final res = await _ok(await authed('POST', 'review', const <String, Object?>{}));
    return ReviewAnswer(res.json['ask'] == true, (res.json['reason'] as String?) ?? (res.json['disabled'] == true ? 'off' : ''));
  }

  /// The icons built into this release and the one shown now, on start.
  Future<void> reportIcons(List<String> available, String current) async =>
      _ok(await authed('POST', 'icons', {'available': available.take(10).toList(), 'current': current, 'app_version': appVersion}));

  /// Up to 20 crashes a call; answers how many were kept.
  Future<int> crashes(List<SdkCrash> list) async {
    var accepted = 0;
    for (var i = 0; i < list.length; i += 20) {
      final part = list.sublist(i, min(i + 20, list.length));
      final res = await _ok(await authed('POST', 'crashes', {
        'crashes': [for (final c in part) c.toJson()]
      }));
      accepted += (res.json['accepted'] as num?)?.toInt() ?? 0;
    }
    return accepted;
  }

  /// iOS Live Activities: start (the type's push-to-start token) · update (a running activity's token) · end.
  Future<bool> liveActivity(String kind, String type, {String? activity, String? token}) async => _on(await _ok(
      await authed('POST', 'live-activity', {'kind': kind, 'type': type, if (activity != null) 'activity': activity, if (token != null) 'token': token})));

  bool _on(SdkResponse res) => res.json['disabled'] != true;

  Future<SdkResponse> _ok(SdkResponse res) async {
    if (res.status >= 200 && res.status < 300) return res;
    throw SdkFailure((res.json['error'] as String?) ?? 'http_${res.status}', res.status);
  }
}
