/// Where the monitor keeps its installation id and the events not sent yet, so a batch survives the app being closed
/// offline. The Flutter package gives a file in the app's support directory; tests use [MemoryStorage].
abstract class MonitorStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

class MemoryStorage implements MonitorStorage {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}
