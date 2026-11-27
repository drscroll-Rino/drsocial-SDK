/// The events DrSocial takes, as the platform's `AppCatalogue::EVENTS` defines them: one meaning per name on every
/// platform, its schema version, its class (how long DrSocial keeps it, and whether it needs the user's consent to
/// usage analytics) and its properties. An event or property not listed here is never sent.
library;

/// operational: diagnostics (launches, screens, requests, errors); product: usage; business: sales.
enum EventClass { operational, product, business }

class EventSpec {
  const EventSpec(this.version, this.eventClass, this.required, [this.optional = const []]);

  final int version;
  final EventClass eventClass;
  final List<String> required;
  final List<String> optional;

  bool allows(String prop) => required.contains(prop) || optional.contains(prop);
}

const Map<String, EventSpec> kEvents = {
  'app_launch': EventSpec(1, EventClass.operational, ['start_type'], ['duration_ms']),
  'app_foreground': EventSpec(1, EventClass.operational, [], ['resume_ms']),
  'app_background': EventSpec(1, EventClass.operational, [], ['session_ms']),
  'app_update_detected': EventSpec(1, EventClass.operational, ['from_version']),
  'screen_view': EventSpec(1, EventClass.product, ['screen'], ['from_screen']),
  'screen_load_started': EventSpec(1, EventClass.operational, ['screen', 'trace_id']),
  'screen_load_completed':
      EventSpec(1, EventClass.operational, ['screen', 'trace_id', 'duration_ms', 'outcome'], ['first_content_ms', 'data_ms', 'images_ms']),
  'api_request_started': EventSpec(1, EventClass.operational, ['endpoint', 'method', 'request_id']),
  'api_request_completed':
      EventSpec(1, EventClass.operational, ['endpoint', 'method', 'request_id', 'status', 'duration_ms'], ['response_bytes', 'network_type', 'screen']),
  'api_request_failed':
      EventSpec(1, EventClass.operational, ['endpoint', 'method', 'request_id', 'error_kind', 'duration_ms'], ['status', 'network_type', 'screen']),
  'app_error_detected': EventSpec(1, EventClass.operational, ['error_type', 'fatal'], ['screen', 'fingerprint']),
  'login_started': EventSpec(1, EventClass.product, ['method']),
  'login_completed': EventSpec(1, EventClass.product, ['method', 'outcome']),
  'search_performed': EventSpec(1, EventClass.product, ['results']),
  'product_viewed': EventSpec(1, EventClass.business, ['product_ref'], ['list']),
  'add_to_cart': EventSpec(1, EventClass.business, ['product_ref', 'quantity']),
  'checkout_started': EventSpec(1, EventClass.business, ['items']),
  'payment_started': EventSpec(1, EventClass.business, ['method']),
  'payment_failed': EventSpec(1, EventClass.business, ['method', 'reason']),
  'payment_cancelled': EventSpec(1, EventClass.business, ['method']),
  'purchase_completed': EventSpec(1, EventClass.business, ['order_ref', 'transaction_id'], ['coupon']),
  'push_received': EventSpec(1, EventClass.product, ['campaign_id']),
  'push_opened': EventSpec(1, EventClass.product, ['campaign_id']),
};
