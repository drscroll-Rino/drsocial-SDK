import 'dart:convert';
import 'dart:io';

/// The answer to one batch: the HTTP status and the JSON body (empty when there is none).
class TransportResponse {
  const TransportResponse(this.status, [this.body = const {}]);

  final int status;
  final Map<String, dynamic> body;
}

/// Sends one batch. Throws on no network; the monitor then waits and tries again.
abstract class MonitorTransport {
  Future<TransportResponse> post(Uri endpoint, String jsonBody);
}

/// dart:io's own client (iOS, Android, HarmonyOS builds with dart:io): no cookie, no auth header, nothing but the batch.
class IoTransport implements MonitorTransport {
  IoTransport({HttpClient? client, this.timeout = const Duration(seconds: 15)}) : _client = client ?? HttpClient();

  final HttpClient _client;
  final Duration timeout;

  @override
  Future<TransportResponse> post(Uri endpoint, String jsonBody) async {
    final req = await _client.postUrl(endpoint).timeout(timeout);
    req.headers.contentType = ContentType.json;
    req.add(utf8.encode(jsonBody));
    final res = await req.close().timeout(timeout);
    final text = await res.transform(utf8.decoder).join().timeout(timeout);
    Map<String, dynamic> body = const {};
    try {
      final parsed = jsonDecode(text);
      if (parsed is Map<String, dynamic>) body = parsed;
    } catch (_) {}
    return TransportResponse(res.statusCode, body);
  }
}
