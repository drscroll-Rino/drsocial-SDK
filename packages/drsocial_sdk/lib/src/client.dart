import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

import 'config.dart';
import 'http.dart';

/// Where the SDK keeps its few values between runs (the last config, the device id, its epoch). The Flutter/native glue
/// gives a file or the platform's preferences; tests use [MemorySdkStore].
abstract class SdkStore {
  Future<String?> read(String name);
  Future<void> write(String name, String? value);
}

class MemorySdkStore implements SdkStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String name) async => values[name];

  @override
  Future<void> write(String name, String? value) async => value == null ? values.remove(name) : values[name] = value;
}

/// The device's own P-256 key, made and kept by the platform (Android Keystore, the iOS Secure Enclave); it never leaves
/// the device. The glue implements it; the core only asks for the public half and a signature.
abstract class DeviceSigner {
  /// Base64 DER SubjectPublicKeyInfo.
  Future<String> publicKey();

  /// Base64 DER ECDSA-SHA256 over [message].
  Future<String> sign(List<int> message);
}

/// A proof from the store that this is the real app (Play Integrity token, App Attest), made by the glue for a nonce.
typedef AttestationMaker = Future<Map<String, String>?> Function(String nonce);

/// iOS App Attest: base64 of `generateAssertion(keyId, clientDataHash: SHA256(message))` with the key that passed at
/// registration; null when the device has none.
typedef AssertionMaker = Future<String?> Function(List<int> message);

/// iOS DeviceCheck: base64 of a fresh `DCDevice.current.generateToken`; null when none can be made.
typedef DeviceCheckMaker = Future<String?> Function();

/// The phone (or its person) is stopped by the company: show a full-screen block with [message] and stop; ask the config
/// again only on the next start.
class SdkBanned implements Exception {
  SdkBanned(this.message, this.until);

  final String message;

  /// When the stop ends; null = until the company lifts it.
  final DateTime? until;

  @override
  String toString() => 'SdkBanned($until)';
}

class SdkFailure implements Exception {
  SdkFailure(this.code, [this.status = 0]);

  final String code;
  final int status;

  @override
  String toString() => 'SdkFailure($code, $status)';
}

/// Speaks API v1 for one store build: the signed config, the device's registration and its short token.
class DrSocialClient {
  DrSocialClient({
    required this.buildKey,
    required this.installId,
    required this.trustedKeys,
    this.base = 'https://social.drscroll.com/api/v1',
    SdkHttp? http,
    SdkStore? store,
    this.os = '',
    this.appVersion = '',
    this.hardwareId,
  })  : http = http ?? IoSdkHttp(),
        store = store ?? MemorySdkStore();

  /// The build's public key (32 hex), from Settings → Mobile app.
  final String buildKey;
  final String installId;

  /// The platform's Ed25519 public keys this release trusts, {"v1": base64}. Empty = the config is not checked (only
  /// for a company whose platform has no signing key yet).
  final Map<String, String> trustedKeys;
  final String base;
  final SdkHttp http;
  final SdkStore store;
  final String os;
  final String appVersion;

  /// The phone's own id that survives deleting the app (Android `ANDROID_ID`, iOS a Keychain id); only its hash is kept.
  final String? hardwareId;

  DeviceSigner? _signer;
  AttestationMaker? _attest;
  AssertionMaker? _assertion;
  DeviceCheckMaker? _deviceCheck;

  /// The device's key and the store proofs every call after [refresh] uses ([authed]).
  void use(DeviceSigner signer, {AttestationMaker? attest, AssertionMaker? assertion, DeviceCheckMaker? deviceCheck}) {
    _signer = signer;
    _attest = attest;
    _assertion = assertion;
    _deviceCheck = deviceCheck;
  }

  SdkConfig _config = SdkConfig.empty;
  String? _token;
  DateTime _tokenUntil = DateTime.fromMillisecondsSinceEpoch(0);

  SdkConfig get config => _config;

  /// Reads the config. A signature that does not check, or no network, keeps the last good answer; an unknown key turns
  /// everything off and forgets it.
  Future<SdkConfig> refresh() async {
    if (_config.raw.isEmpty) {
      final kept = await store.read('config');
      if (kept != null) _config = SdkConfig.fromJson(jsonDecode(kept) as Map<String, dynamic>);
    }
    final SdkResponse res;
    try {
      res = await http.send('GET', Uri.parse('$base/sdk/$buildKey/config'), headers: _token == null ? const {} : {'authorization': 'Bearer $_token'});
    } catch (_) {
      return _config;
    }
    _banned(res);
    if (res.status == 404) {
      _config = SdkConfig.empty;
      await store.write('config', null);
      return _config;
    }
    if (res.status != 200 || !await verify(res.body, res.headers['x-drs-signature'])) return _config;
    _config = SdkConfig.fromJson(res.json);
    await store.write('config', res.body);
    return _config;
  }

  /// Whether [body] carries a good signature from a trusted key (`v1:<base64>`).
  Future<bool> verify(String body, String? header) async {
    if (trustedKeys.isEmpty) return true;
    if (header == null) return false;
    final i = header.indexOf(':');
    if (i < 1) return false;
    final key = trustedKeys[header.substring(0, i)];
    if (key == null) return false;
    try {
      return await Ed25519().verify(utf8.encode(body),
          signature: Signature(base64Decode(header.substring(i + 1)), publicKey: SimplePublicKey(base64Decode(key), type: KeyPairType.ed25519)));
    } catch (_) {
      return false;
    }
  }

  /// Registers the device (again when the key generation moved), with a store proof when [attest] is given.
  Future<String> register(DeviceSigner signer, {AttestationMaker? attest}) async {
    final kept = await store.read('device');
    final keptEpoch = int.tryParse(await store.read('epoch') ?? '') ?? 0;
    if (kept != null && keptEpoch >= _config.epoch) return kept;
    final body = <String, Object?>{'install_id': installId, 'public_key': await signer.publicKey(), 'os': os, 'app_version': appVersion};
    if (hardwareId != null) body['hardware_id'] = hardwareId;
    final dc = await _deviceCheck?.call();
    if (dc != null) body['device_check_token'] = dc;
    if (attest != null) {
      final c = await http.send('GET', Uri.parse('$base/sdk/$buildKey/challenge'));
      final nonce = c.json['nonce'] as String?;
      if (nonce != null) {
        body['nonce'] = nonce;
        body['attestation'] = await attest(nonce);
      }
    }
    final res = await http.send('POST', Uri.parse('$base/sdk/$buildKey/devices'), body: jsonEncode(body));
    _banned(res);
    if (res.status != 201) throw SdkFailure((res.json['error'] as String?) ?? 'register_failed', res.status);
    final id = res.json['device_id'] as String;
    await store.write('device', id);
    await store.write('epoch', '${res.json['epoch']}');
    return id;
  }

  /// A short token for the events, asked again a minute before it ends. On `re_register` the device registers again once.
  Future<String> token(DeviceSigner signer, {AttestationMaker? attest, AssertionMaker? proof, DateTime Function()? now}) async {
    final t = (now ?? DateTime.now)();
    if (_token != null && t.isBefore(_tokenUntil.subtract(const Duration(minutes: 1)))) return _token!;
    for (var attempt = 0; attempt < 2; attempt++) {
      final device = await register(signer, attest: attest);
      final time = '${t.toUtc().millisecondsSinceEpoch ~/ 1000}';
      final nonce = _nonce();
      final message = utf8.encode(tokenMessage(buildKey, device, time, nonce));
      final body = <String, Object?>{'device_id': device, 'time': time, 'nonce': nonce, 'signature': await signer.sign(message)};
      final assertion = await (proof ?? _assertion)?.call(message);
      if (assertion != null) body['assertion'] = assertion;
      final dc = await _deviceCheck?.call();
      if (dc != null) body['device_check_token'] = dc;
      final res = await http.send('POST', Uri.parse('$base/sdk/$buildKey/token'), body: jsonEncode(body));
      _banned(res);
      if (res.status == 200) {
        _token = res.json['token'] as String;
        _tokenUntil = t.add(Duration(seconds: (res.json['expires_in'] as num?)?.toInt() ?? 900));
        return _token!;
      }
      if (res.json['error'] == 're_register' && attempt == 0) {
        await store.write('device', null);
        continue;
      }
      throw SdkFailure((res.json['error'] as String?) ?? 'token_failed', res.status);
    }
    throw SdkFailure('token_failed');
  }

  /// A call made with the device's token ([use] first). A token that ended or a device the platform no longer knows is
  /// fixed once (a new token, or registering again); a stopped phone throws [SdkBanned].
  Future<SdkResponse> authed(String method, String path, [Object? body]) async {
    final signer = _signer;
    if (signer == null) throw SdkFailure('no_signer');
    for (var attempt = 0; attempt < 2; attempt++) {
      final t = await token(signer, attest: _attest);
      final res = await http
          .send(method, Uri.parse('$base/sdk/$buildKey/$path'), body: body == null ? null : jsonEncode(body), headers: {'authorization': 'Bearer $t'});
      _banned(res);
      final error = res.json['error'];
      if (res.status == 401 && attempt == 0 && (error == 'token_required' || error == 're_register')) {
        _token = null;
        if (error == 're_register') await store.write('device', null);
        continue;
      }
      return res;
    }
    throw SdkFailure('token_failed');
  }

  void _banned(SdkResponse res) {
    if (res.status != 403 || res.json['error'] != 'device_banned') return;
    _token = null;
    throw SdkBanned((res.json['message'] as String?) ?? '', DateTime.tryParse((res.json['until'] as String?) ?? ''));
  }

  /// What the device signs to get a token (API.md): `drs-token\n{key}\n{device}\n{time}\n{nonce}`.
  static String tokenMessage(String key, String device, String time, String nonce) => 'drs-token\n$key\n$device\n$time\n$nonce';

  static String _nonce() {
    final r = Random.secure();
    return List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }
}
