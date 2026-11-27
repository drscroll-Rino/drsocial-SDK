# DrSocial mobile SDK — API v1

The contract every DrSocial SDK speaks (Android, iOS, Flutter, React Native, the JavaScript for WebView apps).
All logic lives on the server; an SDK collects, sends and shows. A change that would break an SDK already in a
store becomes `v2`; `v1` keeps working.

Base address: `https://social.drscroll.com/api/v1`

## Keys

| Key | Where it lives | What it can do |
| --- | --- | --- |
| Build key (32 hex, public) | inside the app, one per store build (Settings → Mobile app) | read this build's config, send this build's events |
| Server key `drsk_<id>_<secret>` | the company's own server only, never in the app | send events from the server, ask for a push to one user, sign who the user is |

The build key is not a secret: it names one build of one company's app. Pressing "New key" on the build stops the
old one at once (the SDK gets `404 unknown_key`). On top of it (stage M2), each installation has its own device key,
asks for short tokens, and may have to prove it is the store's app; everything is changed from the server, never by
a new release.

## GET /sdk/{key}/config

Asked when the app opens, then again after `ttl` seconds. No session, no cookie.

```json
{
  "api": "v1",
  "app": { "code": "myapp", "tech": "native" },
  "build": { "platform": "ios", "environment": "production" },
  "features": { "monitoring": true, "ai_analysis": true, "live": false, "push": false, "in_app": false, "...": false },
  "endpoints": {
    "telemetry": "https://social.drscroll.com/api/v1/app-telemetry/<key>",
    "config": "https://social.drscroll.com/api/v1/sdk/<key>/config"
  },
  "remote": { "home.banner": { "type": "string", "value": "Black Friday", "rollout": 50, "min_version": "" } },
  "icon": { "current": "IconRamadan", "default": "", "available": ["IconRamadan", "IconEid"],
            "schedule": [{ "icon": "IconEid", "from": "2026-12-01T00:00:00Z", "to": "2026-12-04T00:00:00Z" }] },
  "update": { "min_version": "1.2", "latest_version": "1.10.0", "url": "https://play.google.com/…", "message": "" },
  "security": { "require_token": false, "attestation": "off", "epoch": 1, "pins": ["sha256/…"], "signing_keys": { "v1": "<base64 Ed25519 public key>" } },
  "ttl": 300,
  "server_time": "2026-11-26T08:00:00+00:00"
}
```

- The answer is signed when the server has a signing key: header `X-DrS-Signature: v1:<base64 Ed25519 signature of
  the exact body>`. An SDK carries the public keys it trusts (shipped in the build) and ignores an answer whose
  signature does not check; `signing_keys` in the answer only adds keys signed by one it already trusts.
- `pins`: SPKI SHA-256 pins of the platform's certificate chain (empty = the system's trust only). Two or more are
  given so a certificate can change without a release.
- `epoch`: the key generation. When it is higher than the one the device registered with, the SDK registers again.

- `features`: every feature is named; `false` means the SDK must not start it. A feature not built yet on the server
  is always `false`. `monitoring` is `true` only when the app's switch and the company's monitoring (Settings →
  Business performance → Apps) are both on.
- `tech`: native · flutter · react_native · webview. Informative only.
- `404 {"error": "unknown_key"}`: the key was replaced, the build was removed or switched off, the app was archived,
  or the company is not active. The SDK stops and keeps no events.
- `429`: too many requests; wait and ask again (600 a minute per address, 3000 a minute per key).
- An SDK that cannot reach the server keeps its last answer (or everything off on the first run).

## Remote values, icon, update (stage M3)

Each is `null` while its feature (remote_config · app_icons · force_update) is off.

- `remote`: the values for this build's platform. `type` bool · number · string · json. An installation takes a
  value only when its bucket < `rollout` — bucket = first 4 bytes of `sha256("<install id>|<key>")` as an unsigned
  big-endian number, mod 100 (vector: `install-1|home.banner` → 47) — and the app's version ≥ `min_version`
  (dotted numbers, compared part by part). Otherwise the app's own default.
- `icon`: `current` = the alternate icon to show now ('' = the app's own); only names in `available`, which are icons
  built into the release (Apple and Google allow no other). `default` = the one chosen outside any switch; `schedule` =
  the next switches (≤ 5, not yet ended, oldest start first): between `from` and `to` show `icon`, and when two cover the
  same moment the one that started last wins. The SDK applies the next switch itself when it comes, even offline until
  the next config read.
- On start, the SDK tells which icons the build carries: `POST /sdk/{key}/icons` (device token) `{available: [names],
  current, app_version}` → `202 {ok}`. Names are letters, digits, `_ . -`, ≤ 10; they fill the list in Settings.
- `update`: below `min_version` the app shows a screen that only opens `url`; below `latest_version` it suggests
  updating once a day.

The Dart core is `drsocial_sdk` in this repository (`packages/drsocial_sdk`).

## Devices and tokens (stage M2)

1. `GET /sdk/{key}/challenge` → `{nonce, expires_in}` (300 s, used once).
2. The SDK makes a P-256 key pair kept in the Keystore / Secure Enclave (never leaves the device) and calls
   `POST /sdk/{key}/devices` `{install_id, public_key (base64 DER SubjectPublicKeyInfo), os, app_version, hardware_id?, nonce?,
   attestation?: {kind: "play_integrity" | "app_attest", token, key_id? (App Attest)}}` → `201 {device_id, epoch, attestation}`. The same
   `install_id` keeps its row. With `attestation: enforce` a device without a passed check gets
   `403 {error: "attestation_required", attestation, reason}`. Play Integrity is checked with the company's Google
   Play key (nonce, package, PLAY_RECOGNIZED, MEETS_DEVICE_INTEGRITY). Apple App Attest: `token` = base64 of the attestation
   object from `DCAppAttestService.attestKey(keyId, clientDataHash: SHA256(nonce as UTF-8))`, `key_id` = the base64 key id; checked
   against Apple's App Attestation Root CA with the app id `<Team ID>.<bundle id>` (the Team ID from the company's APNs or DeviceCheck
   key; none = `unverified` / `no_team_id`); a `testing` build may use the development environment. Reasons: attest_format ·
   attest_chain · attest_expired · attest_nonce · attest_key · attest_key_id · attest_app · attest_auth_data.
3. `POST /sdk/{key}/token` `{device_id, time (unix seconds), nonce (random, ≥ 16 chars), signature, assertion?}` where signature
   = base64 DER ECDSA-SHA256 of `drs-token\n{key}\n{device_id}\n{time}\n{nonce}` → `{token, expires_in: 900}`. An iPhone whose
   App Attest key passed adds `assertion` = base64 of `generateAssertion(keyId, clientDataHash: SHA256(that same message))`; with
   `attestation: enforce` it must (`assertion_required`), and its counter must grow.
   Errors (401): `clock` (± 300 s, with `server_time`), `re_register` (unknown device, revoked, or older epoch),
   `bad_signature`, `replayed`, `assertion_required`, `bad_assertion` {reason: assert_format · assert_signature · assert_app ·
   assert_replayed}.
4. Events carry `Authorization: Bearer <token>`. While the app's `require_token` is on, a batch without a valid token
   for this build and epoch gets `401 {error: "token_required"}`: ask for a new token, re-register on `re_register`.

"The connection was exposed" (Settings → Mobile app, per build) raises the epoch: every device and every token of
the older generation stop at once and the apps register again on their own.

## Stopped phones and people

The company can stop one phone or a person (Settings → Mobile app → People → a person's card; or its server, below). A stopped
phone gets `403 {error: "device_banned", message, until}` on `config` (when the request carries the device's token), on
`devices`, on `token` and on every call made with a token. The SDK must then show a full-screen block with `message` (or its own
short default) and stop: no screen of the app opens, nothing is sent, and it asks `config` again only on the next start.

- `hardware_id` (8–128 of `A-Z a-z 0-9 . _ : -`): the phone's own id that survives deleting the app — Android: `Settings.Secure.ANDROID_ID`;
  iOS: a random id the SDK keeps in the Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`). Only its hash is kept; a
  reinstalled app on a stopped phone is refused at `devices`.
- A person's ban covers every phone they are signed in on and any phone they sign in on later (`identify` answers 403 there).
- The company's site: when the app opens the company's own site (WebView or the browser), it adds `drs_d=<device_id>` to the
  address; a site with connector 0.32.0 then refuses a stopped phone even on another network, and remembers it with a cookie.
- `config.bans` = `{error: "device_banned", site_param: "drs_d"}`.
- `device_check_token` (iOS builds, on `devices` and on `token`): a fresh `DCDevice.current.generateToken` as base64. The platform
  keeps it encrypted and, when the company saved Apple's DeviceCheck key, reads the phone's DeviceCheck bits (on `devices`, and
  at most every 6 hours on `token`): an iPhone marked by a DeviceCheck ban is refused even after a factory reset. Optional; an SDK
  that cannot make one leaves it out.
- The ways a ban follows are the company's choice (account · install · hardware · device_check, plus its site): the SDK sends all
  it can and does nothing else differently.

## Server keys (stage M2)

Made in Settings → Mobile app, shown once, at most 5 live per company. Only `id` travels; every request is signed:

```
X-DrS-Key: <id>
X-DrS-Time: <unix seconds>
X-DrS-Nonce: <random, ≥ 16 chars, used once>
X-DrS-Signature: hex HMAC-SHA256(secret, METHOD\npath\ntime\nnonce\nhex sha256(body))
```

`path` is the request path without the host, e.g. `/api/v1/sdk-server/events`.

- `POST /sdk-server/events` `{build: <build key>, …the telemetry batch}`: events sent by the company's server for one
  of its builds; same answers as `/app-telemetry`. 401 = bad signature, time or reused nonce, or a stopped key.
- `POST /sdk-server/users/ban` `{app, external_id, message?, days?: 1|7|30|90|null, site?: true}` → `201 {banned}` stops a person
  (404 `unknown_user` when the app never saw them); `POST /sdk-server/users/unban` `{app, external_id}` → `{lifted}`.
- Signed identity: the app may tell who its user is only with `identity_hash` = hex HMAC-SHA256(secret, user id),
  computed on the company's server (used from stage M4).

## Users, the app's own events, privacy (stage M4)

Every call carries the device's token (`Authorization: Bearer`): the device and the company come from it, never
from the body. 401 `token_required` = get a token; 401 `re_register` = register the device again.

- `POST /sdk/{key}/identify` `{external_id (≤ 128, the company's own user id), identity_hash?, traits?, consent?,
  locale?, country?}` → `{user}`. While the app's `privacy.verified_identity` is on (the default), `identity_hash` =
  hex HMAC-SHA256(server key secret, external_id) made on the company's server, else 401 `identity_not_proved`.
  `traits`: ≤ 30 plain values (keys `^[a-z][a-z0-9_]{0,63}$`, text ≤ 200, numbers, true/false); a value that looks
  personal (e-mail, phone, token) is dropped. `consent`: `{analytics, messages}` as the person chose; kept until
  changed. The device is linked to the person until sign-out.
- `POST /sdk/{key}/sign-out` → `{ok}`: the device is no longer linked to anyone.
- `POST /sdk/{key}/track` `{events: [{id (8-64 of A-Z a-z 0-9 _ -), name, at? (ISO time, ≤ 30 days back, ≤ 10
  minutes ahead), props? (≤ 20 plain values)}]}` (≤ 100 events, ≤ 128 KB) → `202 {accepted, duplicates,
  rejected[{index, reason bad_event · bad_time}]}`; while the signed-in person said no to analytics →
  `202 {accepted: 0, no_consent: true}` and nothing is kept. An event id sent twice is kept once.
- Server: `POST /sdk-server/users/forget` `{app: <app code>, external_id}` (signed like every server request) →
  `{forgotten: true|false}`: the person and every event of theirs deleted at once. The same is in Settings → Mobile
  app → the app's people.

Events are kept `privacy.keep_days` days (30 · 90 · 180 · 365, default 90).

## Live (stage M5)

While the app's `live` switch is on (the config's `features.live`), the SDK sends a beat with the device's token:
`POST /sdk/{key}/live` `{session (8-64 of A-Z a-z 0-9 _ -, a new one each time the app comes to the front after 30
minutes away), kind: open · screen · ping · close, screen? (a screen name or a route; ids and queries are removed),
app_version?}` → `202 {ok, ping: 30}`: send `ping` every `ping` seconds while the app is in front, `close` when it
goes to the back. Off → `202 {disabled: true}` (send nothing more until the config says otherwise). A session with
no beat for 2 minutes is no longer live. The session id is kept only as a hash; sessions are kept 7 days.

## Notifications (stage M7)

While `features.push` is on, after the person allowed notifications the SDK hands over the installation's token:
`POST /sdk/{key}/push-token` `{provider: fcm · apns · hms · harmony, token, permission: granted · denied · provisional}` → `202 {ok}`
(off → `202 {disabled: true}`). Android and any app using Firebase send `fcm`; an iOS app without Firebase sends the
APNs device token as hex with `apns`; an AppGallery build (Huawei, no Google services) sends Push Kit's token with
`hms`; a HarmonyOS NEXT app sends Push Kit v3's token (`getToken()`) with `harmony` — HarmonyOS draws the notification itself,
so buttons are not shown there and the click opens the app with `drs_push` / `drs_link` in the click data. Send it again whenever it changes or the permission changes.

A notification carries `drs_push` (its id) and `drs_link` (a link to open, when the app's `deep_links` is on; empty
otherwise) in its data; a picture comes as FCM's `notification.image` or, on APNs, `drs_image` with `mutable-content`
(a Notification Service Extension shows it). When the person opens it: `POST /sdk/{key}/push-opened` `{push}` → `202`.

**How often and when.** The company sets per app a cap per phone (at most N in 24 hours and M in 7 days) and quiet hours in
the app's time zone; a notification inside them waits until they end, a phone that had its share is left out. Journeys keep
the same rules. A notification sent `important` (an order, a password) skips both. Nothing changes in the SDK.

**A/B tests.** A notification may carry a second version and a holdout group; each phone gets one version's title and words,
or nothing. The SDK sees an ordinary notification and reports `push-opened` as usual: the comparison is made on the server.

**Journeys may hand a message.** A message kept "only through journeys" appears in `GET /sdk/{key}/messages` once a journey
reached that phone; nothing changes in the SDK.

**Vibration.** Each notification names one pattern: default · none · short · double · long · heartbeat · ripple · urgent.
- Android: the SDK creates one notification channel per pattern on start, id `drs_vibe_<name>` (e.g. `drs_vibe_heartbeat`),
  with the pattern in ms below (Android takes a channel's vibration only when it is created). FCM and Huawei both name the
  channel and also carry the timings (`vibrate_timings` / `vibrate_config`). `default` uses the app's default channel.
- iOS: Apple allows no custom pattern. `none` arrives `passive` with no sound, `urgent` `time-sensitive` (needs the
  Time Sensitive capability), the rest `active`. When the app is open, the SDK plays the pattern with Core Haptics.
- Data on every provider: `drs_vibe` (name) and `drs_vibe_ms` (`"0,120,100,120"`: wait, buzz, wait, buzz… in ms).

| pattern | ms |
|---|---|
| short | 0,150 |
| double | 0,120,100,120 |
| long | 0,700 |
| heartbeat | 0,90,110,90,500,90,110,90 |
| ripple | 0,60,60,90,60,120,60,160 |
| urgent | 0,400,150,400,150,400 |
| none | (silent) |

**Buttons.** A notification may carry up to 3 buttons, `drs_buttons` = `[{id, label, link}]` (`link` empty unless `deep_links` is on;
then the button opens the app). Android (FCM and Huawei): such a notification comes as data only, with `drs_title`, `drs_body`,
`drs_image` and `drs_buttons` (a JSON string), so the SDK builds it with `NotificationCompat` actions on the vibration's channel.
iOS: the alert comes with `category: drs_actions` and `mutable-content`; the SDK's Notification Service Extension registers
`drs_actions` with the labels of `drs_buttons` before the notification shows. When a button is pressed:
`POST /sdk/{key}/push-opened` `{push, action: <button id>}` (`[a-z0-9_]{1,32}`).

**Silent notifications.** `drs_silent` in the data (Android data only, priority normal; iOS a background push with
`content-available: 1`, apns-priority 5) and no alert. `drs_silent: refresh` = read the config, the messages and the remote values
again now. `drs_silent: ping` = nothing to do (a daily check of whether the app is still installed); the SDK must not show or
log anything and must not call the server for it. A silent notification reaches a phone whose person refused notifications.

**Who removed the app.** No phone tells. While the app's `delivery.uninstall_check` is on, the server sends each phone with a
token one `ping` a day; when the store answers that the token is gone, the phone is counted as having removed the app. Sending a
new token (`push-token`) brings it back. Nothing else is asked of the SDK.

## Inside the app: messages, inbox, surveys, tours (stage M8)

`GET /sdk/{key}/messages` (the device's token) → `{messages: [...], ttl: 300}`: what this installation should have now,
only for the kinds switched on (`in_app`, `inbox`, `surveys`, `tours`). Each item: `{id, kind: in_app · inbox · survey ·
tour, content, trigger: {on: open · screen · event, value}, frequency: once · session · daily, last_shown_at}`; an inbox
item also `{read, at}`. Content by kind: in_app `{layout: banner · modal · full, title, body, image, buttons: [{label,
link}]}`; inbox `{title, body, image, link}`; survey `{title, questions: [{id, type: rating · choice · text, text,
options}]}`; tour `{steps: [{screen, target (the element's id in the app), title, body}]}`. The SDK draws them itself:
on the trigger, at most as often as `frequency` says (using `last_shown_at`).

`POST /sdk/{key}/messages/{id}/event` `{kind: shown · clicked · dismissed · answered · completed · read, answer?}` → `202`.
A survey's `answer` is `{q1: 1-5 (rating) | option index (choice) | text ≤ 500}`; personal-looking text is dropped. A
`once` message clicked, closed, answered or finished is not sent to that installation again.

## People, interests and the AI (stage M9)

The connection is always HTTPS, and a person's name, e-mail and phone are kept sealed with the company's own key
(found by search through keyed hashes, never stored as plain text; shown only to the company's managers; never sent
to the AI).

- `identify` may carry `profile: {name ≤ 120, email, phone (digits, a leading +)}`. It is kept only with a valid
  `identity_hash` (the answer then says `profile: kept`, or `partly` when a field was refused); without one the
  answer says `profile: not_proved` and nothing of it is kept. An empty value removes that field.
- Server: `POST /sdk-server/users/profile` `{app, external_id, name?, email?, phone?}` (signed) → `{saved: [fields]}`;
  the person is made when new; 422 `{error: bad_fields, fields}`. Prefer this from the company's own server.
- Interests come from the app's own events: an event whose name has `search` with a `query` · `term` · `q` · `search`
  property is a search; `category`, `product`, `item`, `brand`, `genre`, `game`, `plan` properties name what the
  person cares about (purchase-like events weigh more). Send them as plain props to make the AI's reading useful.
- Segments take the rule `{kind: interest, value, days?}`: devices or people whose events of `days` (default 30) name
  that value in one of those properties (case aside).
- A notification can go to one person (`user_id` from the people list, instead of a segment): only their devices,
  and only while their messages consent is not false.

## Journeys (stage M10)

Nothing new for the SDK: journeys run on the server from what the app already sends. A journey starts from an event the
app tracks (`POST /sdk/{key}/track`), a new installation (`POST /sdk/{key}/devices`) or a segment, then sends its
notifications through the same push token. A journey's notification carries the run's id in `drs_push`; report its
opening with `POST /sdk/{key}/push-opened` as for any notification. Send meaningful event names (`cart_add`,
`purchase`) so a journey can start on one, check for one, and end on its goal.

## Where the installation came from (stage M11)
`POST /sdk/{key}/attribution` with the device's token, once on the first open, while `features.attribution` is on:
`{referrer?, link?}` (each ≤ 2048 characters). `referrer` = Google Play's Install Referrer string as the store gives it
(`utm_source=…&utm_medium=…&gclid=…`); `link` = the first deep link / universal link that opened the app. The server reads
the utm_* values and the click ids (gclid · gbraid · wbraid, fbclid, ttclid, ScCid, twclid, li_fat_id) into network ·
source · medium · campaign · content and keeps them on the installation; the raw strings and the click ids' values are
not kept. First touch only: a later call answers `{kept: false}`. Nothing given = organic. 202 `{kept, network}`;
`{disabled: true}` while the switch is off. iOS has no install referrer: send the opening link when there is one.
A goal event with a numeric `value` property (e.g. `purchase` {value: 250}) is what the campaigns report adds up.

## Links that open a screen after a first install
The company makes a link in Settings → 📱 Mobile app: `https://<platform>/api/v1/go/<code>`. On a phone with the app the page's
button opens the link's screen (its own scheme or a universal / app link: register them as usual); without the app the page goes to
the phone's store after 4 seconds. Google Play's link carries `referrer=drs_link=<code>&utm_*`.
`POST /sdk/{key}/deferred` with the device's token, once on the very first open, while `features.deferred_links` is on:
`{referrer?}` = Google Play's Install Referrer string (iOS and Huawei: send `{}`). 200 `{matched: true, by: referrer | network,
code, link}` → open `link` as if it had been tapped; `by: network` = matched to a click from the same network within 2 hours (likely,
not certain); `{matched: false}`; `{matched: false, again: true}` when asked before; 202 `{disabled: true}` while the switch is off.
The link's utm values become the installation's source when it has none yet (same as `attribution`).

## Asking for a store review
While `features.store_review` is on, the config carries `review` {on, min_sessions, min_days, after_event, every_days,
skip_after_crash} (null otherwise). At a calm moment (after a success, never on launch or after an error) the app asks
`POST /sdk/{key}/review` with the device's token: `{ask: true}` → call the store's own review box (iOS `requestReview`,
Google Play In-App Review, Huawei's comments API); `{ask: false, reason: off | asked_recently | too_new | too_few_sessions |
no_event | recent_crash}` → do nothing. A yes counts as asked, whether or not the store showed its box. Send `app_open` events
(or live sessions) so the sessions can be counted.

## Crashes with their lines (stage M12)
`POST /sdk/{key}/crashes` with the device's token, while `features.crash_lines` is on (≤ 256 KB):
`{crashes: [{id, at?, kind: fatal | non_fatal | anr, type, message?, frames: [{fn, file?, line?, lib?, offset?}], app_version?,
os_version?, screen?}]}`, at most 20 crashes and 40 frames each. `id` is the SDK's own id (8–64 of A–Z a–z 0–9 _ -): a
crash sent twice is kept once. Send a fatal crash on the next launch (it cannot be sent while the app dies). Send the
stack as the runtime gives it, with the release's `app_version`. An obfuscated (R8 / ProGuard) frame is mapped back with
that release's mapping.txt, and an iOS frame with its symbol table when the frame carries `offset` (hex, the address in
its image minus the image's load address; `lib` = the image's name); without a file the stack is shown as sent. E-mails, phone numbers, tokens and card numbers inside the message
or the frames are replaced by `…` on the server; never put personal data there. 202 `{accepted, duplicates,
rejected: [{index, reason}]}`; `{disabled: true}` while the switch is off.

Symbol files are uploaded by a manager (Settings → Mobile app → crashes) or by the build server:
`POST /sdk-server/symbols` (signed like every server request, ≤ 30 MB) `{build: <build key>, app_version, kind: r8 | symbols,
content: <base64 of the file, gzip allowed>, image?, base?}` → `201 {id, entries}`; `kind: r8` = Android's
`mapping.txt`, `kind: symbols` (iOS builds only) = `nm -n` of the app binary from its dSYM, `image` = the binary's name,
`base` = its link address (hex, default 0x100000000). The same build × version × kind replaces the older file. 400
`bad_request`, 404 `unknown_key`, 413 `too_big`, 422 `unreadable` (nothing in it could be read).

Crashes, `app_error_detected`, `api_request_failed` and `screen_load_completed` also feed the team's problems report (e-mail + push, daily or weekly, and at
once for a crash that is new or came back). Nothing new is asked of the SDK: send these as they are, with `app_version`, `os_version` and `screen`.

## Live Activities (stage M12, iOS)
`POST /sdk/{key}/live-activity` with the device's token, from an iOS build only (422 `ios_only` otherwise), while
`features.live_activities` is on: `{kind: start, type, token}` = the type's push-to-start token
(`Activity<…>.pushToStartTokenUpdates`, iOS 17.2+); `{kind: update, type, activity, token}` = a running activity's push
token (`activity.pushTokenUpdates`), `activity` = the activity's own id; `{kind: end, type, activity}` when it ends on
the phone. `type` is the ActivityAttributes' Swift type name (`[A-Za-z][A-Za-z0-9_]{0,63}`), the same name the app's
widget extension declares; the token in hex. The platform sends start · update · end with APNs
(`apns-push-type: liveactivity`, topic `<bundle id>.push-type.liveactivity`) and `aps.content-state` = the JSON a manager
typed, so the app's `ContentState` must decode it. A token APNs refuses is never used again.

## POST /app-telemetry/{key}

The events, in batches. Unchanged from stage 22.2: up to 100 events or 64 KB, each event checked against the
catalogue (`AppCatalogue::EVENTS`), unknown properties dropped, personal-looking values dropped, ids and queries
removed from paths, an event sent twice kept once.

| Answer | Meaning |
| --- | --- |
| 202 | taken: `accepted`, `duplicates`, `dropped`, `rejected[{index, reason}]` |
| 202 with `disabled` | monitoring is off: try again in an hour |
| 400 | not a batch, or a bad envelope |
| 401 `token_required` | the app requires tokens: get one (or register again) |
| 404 | unknown key: stop sending |
| 413 | too big: halve the batch and send again |

## Features and their stages

| Feature | Stage |
| --- | --- |
| monitoring, ai_analysis | M1 (built) |
| remote_config, app_icons, force_update | M3 (built) |
| users, own events, privacy (always on) | M4 (built) |
| live | M5 (built) |
| segments (the shared audience, server only) | M6 (built) |
| push, rich_push, deep_links | M7 (built) |
| in_app, inbox, surveys, tours | M8 (built) |
| ai_messages | M9 (built) |
| journeys | M10 (built) |
| attribution | M11 (built) |
| crash_lines, live_activities | M12 (built) |

The list is `App\Services\MobileApp\MobileFeatures::FEATURES`.
