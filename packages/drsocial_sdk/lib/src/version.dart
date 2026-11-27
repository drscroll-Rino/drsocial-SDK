/// Compares two dotted versions number by number: -1, 0 or 1 ("1.10" > "1.9"; a missing part is 0; anything that is
/// not a number counts as 0). The same rule as the platform's `RemoteControl::compare`.
int compareVersions(String a, String b) {
  List<int> parts(String v) => v.split('.').map((p) => int.tryParse(p.trim()) ?? 0).toList();
  final x = parts(a), y = parts(b);
  final n = x.length > y.length ? x.length : y.length;
  for (var i = 0; i < n; i++) {
    final d = (i < x.length ? x[i] : 0).compareTo(i < y.length ? y[i] : 0);
    if (d != 0) return d.sign;
  }
  return 0;
}
