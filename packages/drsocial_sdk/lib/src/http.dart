import 'dart:convert';
import 'dart:io';

/// One answer: status, headers (lower-case names) and the body exactly as received (the config's signature covers it).
class SdkResponse {
  const SdkResponse(this.status, this.body, [this.headers = const {}]);

  final int status;
  final String body;
  final Map<String, String> headers;

  Map<String, dynamic> get json {
    try {
      final p = jsonDecode(body);
      return p is Map<String, dynamic> ? p : const {};
    } catch (_) {
      return const {};
    }
  }
}

/// The SDK's only way out. Throws on no network.
abstract class SdkHttp {
  Future<SdkResponse> send(String method, Uri url, {String? body, Map<String, String> headers = const {}});
}

/// dart:io's client: no cookie, nothing but what the SDK writes.
class IoSdkHttp implements SdkHttp {
  IoSdkHttp({HttpClient? client, this.timeout = const Duration(seconds: 15)}) : _client = client ?? HttpClient();

  final HttpClient _client;
  final Duration timeout;

  @override
  Future<SdkResponse> send(String method, Uri url, {String? body, Map<String, String> headers = const {}}) async {
    final req = await _client.openUrl(method, url).timeout(timeout);
    headers.forEach(req.headers.set);
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.add(utf8.encode(body));
    }
    final res = await req.close().timeout(timeout);
    final text = await res.transform(utf8.decoder).join().timeout(timeout);
    final h = <String, String>{};
    res.headers.forEach((name, values) => h[name.toLowerCase()] = values.join(','));
    return SdkResponse(res.statusCode, text, h);
  }
}
