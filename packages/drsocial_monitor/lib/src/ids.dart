import 'dart:math';

final _random = Random.secure();

/// A random UUID v4: every event's id (the platform keeps an event once per id, so a retried batch is not counted
/// twice) and the request and trace ids.
String uuid4() {
  final b = List<int>.generate(16, (_) => _random.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

/// A random id of 32 hex characters: the installation's and the session's. Never a device id.
String randomId() => List<int>.generate(16, (_) => _random.nextInt(256)).map((x) => x.toRadixString(16).padLeft(2, '0')).join();
