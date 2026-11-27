/// What is never sent: the same rules the platform applies on arrival, applied first on the phone so nothing
/// personal leaves it. Paths keep no scheme, host, query or fragment, and each id-like part becomes `{id}`.
library;

final _control = RegExp(r'[\x00-\x1F\x7F]');
final _email = RegExp(r'[^\s@]+@[^\s@]+\.[^\s@]+');
final _phone = RegExp(r'^\+?[\d\s()-]{8,}$');
final _token = RegExp(r'^(bearer\s+)?[A-Za-z0-9_\-.=]{32,}$', caseSensitive: false);
final _bearer = RegExp(r'^bearer\s', caseSensitive: false);
final _card = RegExp(r'\b\d{13,19}\b');
final _digits = RegExp(r'^\d+$');
final _uuid = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', caseSensitive: false);
final _hex = RegExp(r'^[0-9a-f]{12,}$', caseSensitive: false);
final _longId = RegExp(r'^[A-Za-z0-9_\-.=]+$');
final _hasDigit = RegExp(r'\d');
final _scheme = RegExp(r'^[a-z][a-z0-9+.-]*://', caseSensitive: false);

/// References, not people: the company's own (an order, a payment's transaction, a product, a campaign) and the
/// random ids this package makes for a request or a trace. Long ids are fine there.
const kRefs = {'order_ref', 'transaction_id', 'product_ref', 'campaign_id', 'request_id', 'trace_id'};

/// An e-mail address or a bearer token; outside a reference also a phone or card number or a token-like string.
bool looksPersonal(String v, {bool ref = false}) =>
    _email.hasMatch(v) ||
    _bearer.hasMatch(v) ||
    (!ref && (_phone.hasMatch(v) || _token.hasMatch(v) || _card.hasMatch(v.replaceAll(RegExp(r'[ -]'), ''))));

/// A path or route as sent: `/orders/12345?x=1` → `/orders/{id}`. A screen name with no `/` is kept as it is.
String redactPath(String raw) {
  var s = raw.replaceAll(_control, '').trim();
  if (s.isEmpty) return '';
  if (!s.contains('/')) return looksPersonal(s) ? '' : _cut(s);
  if (_scheme.hasMatch(s)) {
    s = Uri.tryParse(s)?.path ?? '/';
  }
  final q = s.indexOf(RegExp(r'[?#]'));
  if (q >= 0) s = s.substring(0, q);
  final parts = s.split('/').map((seg) {
    var d = seg;
    try {
      d = Uri.decodeComponent(seg);
    } catch (_) {}
    if (d.isEmpty) return d;
    final idLike = _digits.hasMatch(d) ||
        _uuid.hasMatch(d) ||
        _hex.hasMatch(d) ||
        (d.length >= 20 && _hasDigit.hasMatch(d) && _longId.hasMatch(d)) ||
        looksPersonal(d);
    return idLike ? '{id}' : d;
  });
  final path = parts.join('/');
  return _cut(path.startsWith('/') ? path : '/$path');
}

String _cut(String s) => s.length > 120 ? s.substring(0, 120) : s;
