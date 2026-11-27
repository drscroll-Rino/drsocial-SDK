import 'dart:convert';
import 'dart:io';

import 'package:drsocial_monitor/drsocial_monitor.dart';
import 'package:path_provider/path_provider.dart';

/// The monitor's values in one small JSON file in the app's support directory (not backed up to the cloud on iOS,
/// not shown to the user). Holds the random installation id, the consent answer and the events not sent yet.
class FileStorage implements MonitorStorage {
  FileStorage._(this._file, this._values);

  final File _file;
  final Map<String, String> _values;
  Future<void> _writing = Future.value();

  static Future<FileStorage> open() async {
    final dir = await getApplicationSupportDirectory();
    final file = File('${dir.path}/drsocial_monitor.json');
    var values = <String, String>{};
    try {
      if (await file.exists()) {
        final parsed = jsonDecode(await file.readAsString());
        if (parsed is Map) values = parsed.map((k, v) => MapEntry('$k', '$v'));
      }
    } catch (_) {
      // A broken file is started again: nothing in it is worth stopping the app for.
    }
    return FileStorage._(file, values);
  }

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) {
    _values[key] = value;
    final snapshot = jsonEncode(_values);
    return _writing = _writing.then((_) async {
      final tmp = File('${_file.path}.tmp');
      await tmp.writeAsString(snapshot, flush: true);
      await tmp.rename(_file.path);
    }).catchError((Object _) {});
  }
}
