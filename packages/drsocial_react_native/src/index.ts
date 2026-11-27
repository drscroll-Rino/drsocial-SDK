import { NativeEventEmitter, NativeModules, Platform } from 'react-native';
import type { EmitterSubscription } from 'react-native';

import { describeError } from './stack';
import type { JsFrame } from './stack';
import { plainProps, readJson, validName } from './values';
import type { Plain } from './values';

export { parseStack, describeError } from './stack';
export type { JsFrame } from './stack';
export { plainProps, validName } from './values';
export type { Plain } from './values';

/**
 * The native module both phones register as `DrSocial` (android: DrSocialModule.kt, iOS: DrSocialModule.swift). The SDK
 * itself is started natively (Application.onCreate / application(_:didFinishLaunchingWithOptions:)), before React, so
 * crashes, notifications and the first open are caught even when JavaScript never loads.
 */
interface NativeDrSocial {
  isStarted(): boolean;
  identify(externalId: string, options: Record<string, unknown>): Promise<string | null>;
  signOut(): Promise<void>;
  track(name: string, props: Record<string, Plain>): void;
  screen(name: string): void;
  reportError(type: string, message: string, frames: JsFrame[]): void;
  flush(): Promise<void>;
  siteUrl(url: string): Promise<string>;
  value(key: string): string | null;
  update(): { need: number; url: string; message: string };
  askReviewIfDue(): Promise<boolean>;
  messages(): Promise<string>;
  messageEvent(id: string, kind: string, answer: string | null): Promise<void>;
  requestPush(provisional: boolean): void;
  liveActivity(kind: string, type: string, activity: string | null, token: string | null): void;
  addListener(event: string): void;
  removeListeners(count: number): void;
}

const LINKING_ERROR =
  "@drsocial/react-native: the native part is not linked. Rebuild the app after installing (cd ios && pod install), and start the SDK natively first (see the README).";

function native(): NativeDrSocial {
  const m = NativeModules.DrSocial as NativeDrSocial | undefined;
  if (!m) throw new Error(LINKING_ERROR);
  return m;
}

/** What the app must do about updating now. */
export type UpdateNeed = 'none' | 'suggested' | 'required';

export interface UpdateAdvice {
  need: UpdateNeed;
  /** The store page (https), '' when the company gave none. */
  url: string;
  message: string;
}

export interface IdentifyOptions {
  /** hex HMAC-SHA256(server key secret, externalId), made on the company's own server. */
  identityHash?: string;
  /** ≤ 30 plain values (names a–z 0–9 _). */
  traits?: Record<string, unknown>;
  /** The person's answers: analytics (events kept) and messages (notifications, in-app). */
  analytics?: boolean;
  messages?: boolean;
  locale?: string;
  country?: string;
  /** name, email, phone: kept sealed, only with identityHash. */
  profile?: { name?: string; email?: string; phone?: string };
}

/** One in-app message, inbox item, survey or tour as the platform sent it (see API.md `messages`). */
export type DrSocialMessage = Record<string, unknown> & { id: string; kind: string };

export type DrSocialEvent = 'link' | 'messages' | 'config' | 'banned';

export interface BannedInfo {
  message: string;
  /** ISO time, '' = until lifted. */
  until: string;
}

const NEEDS: UpdateNeed[] = ['none', 'suggested', 'required'];
const KINDS = ['shown', 'clicked', 'dismissed', 'answered', 'completed', 'read'];

let emitter: NativeEventEmitter | null = null;

function on(event: 'link', listener: (link: string) => void): EmitterSubscription;
function on(event: 'messages', listener: (list: DrSocialMessage[]) => void): EmitterSubscription;
function on(event: 'config', listener: () => void): EmitterSubscription;
function on(event: 'banned', listener: (info: BannedInfo) => void): EmitterSubscription;
function on(event: DrSocialEvent, listener: (value: never) => void): EmitterSubscription {
  if (!emitter) emitter = new NativeEventEmitter(native() as never);
  return emitter.addListener(`drsocial.${event}`, (payload: unknown) => {
    let value: unknown = payload;
    if (event === 'messages') {
      const list = readJson(payload as string);
      value = Array.isArray(list) ? list : [];
    }
    (listener as (v: unknown) => void)(value);
  });
}

/** The DrSocial SDK from JavaScript. Every call is safe offline, and a feature switched off on the platform does nothing. */
export const DrSocial = {
  /** Whether the native SDK was started (DrSocialReact.start on Android, DrSocialReact.start on iOS). */
  isStarted(): boolean {
    return NativeModules.DrSocial ? native().isStarted() : false;
  },

  /** Links the phone to the company's own user; answers the platform's user id, null when it could not be sent. */
  identify(externalId: string, options: IdentifyOptions = {}): Promise<string | null> {
    const id = String(externalId).slice(0, 128);
    if (id === '') return Promise.resolve(null);
    const o: Record<string, unknown> = {};
    if (options.identityHash) o.identityHash = options.identityHash;
    if (options.traits) o.traits = plainProps(options.traits, 30);
    if (options.analytics !== undefined) o.analytics = options.analytics;
    if (options.messages !== undefined) o.messages = options.messages;
    if (options.locale) o.locale = options.locale;
    if (options.country) o.country = options.country;
    if (options.profile && options.identityHash) {
      const p: Record<string, string> = {};
      for (const k of ['name', 'email', 'phone'] as const) {
        const v = options.profile[k];
        if (typeof v === 'string' && v !== '') p[k] = v.slice(0, 200);
      }
      if (Object.keys(p).length > 0) o.profile = p;
    }
    return native().identify(id, o);
  },

  signOut(): Promise<void> {
    return native().signOut();
  },

  /** One of the app's own events (`cart_add`, `purchase` {value: 250}); kept on the phone and sent in batches. */
  track(name: string, props?: Record<string, unknown>): void {
    if (!validName(name)) return;
    native().track(name, plainProps(props));
  },

  /** The screen now (a name or a route; ids and queries are removed natively). */
  screen(name: string): void {
    if (name) native().screen(String(name).slice(0, 200));
  },

  /** An error the app caught (kind non_fatal), with its JavaScript frames. */
  reportError(error: unknown): void {
    const d = describeError(error);
    native().reportError(d.type, d.message, d.frames);
  },

  /** Sends the kept events now. */
  flush(): Promise<void> {
    return native().flush();
  },

  /** The company's own site with this phone's id (drs_d), so a stop on the phone also holds on the site. */
  siteUrl(url: string): Promise<string> {
    return native().siteUrl(url);
  },

  /** A remote value for this installation (rollout and version rules applied natively); undefined when not set. */
  value(key: string): unknown {
    return readJson(native().value(key));
  },

  string(key: string, fallback = ''): string {
    const v = this.value(key);
    return typeof v === 'string' ? v : fallback;
  },

  bool(key: string, fallback = false): boolean {
    const v = this.value(key);
    return typeof v === 'boolean' ? v : fallback;
  },

  number(key: string, fallback = 0): number {
    const v = this.value(key);
    return typeof v === 'number' && Number.isFinite(v) ? v : fallback;
  },

  update(): UpdateAdvice {
    const u = native().update();
    return { need: NEEDS[u.need] ?? 'none', url: u.url ?? '', message: u.message ?? '' };
  },

  /** Opens the store's own review box when the platform says now is the moment; answers whether it was opened. */
  askReviewIfDue(): Promise<boolean> {
    return native().askReviewIfDue();
  },

  /** What the app should show now (in-app messages, inbox, surveys, tours). */
  async messages(): Promise<DrSocialMessage[]> {
    const list = readJson(await native().messages());
    return Array.isArray(list) ? (list.filter((m) => m && typeof m === 'object' && typeof m.id === 'string') as DrSocialMessage[]) : [];
  },

  /** shown · clicked · dismissed · answered · completed · read; a survey's answer is {question id: value}. */
  messageEvent(id: string, kind: string, answer?: Record<string, unknown>): Promise<void> {
    if (!KINDS.includes(kind)) return Promise.reject(new Error(`@drsocial/react-native: unknown message event ${kind}`));
    return native().messageEvent(id, kind, answer ? JSON.stringify(answer) : null);
  },

  /** iOS: asks for notifications (Android 13+: ask with PermissionsAndroid; the token comes from the fcm module). */
  requestPush(provisional = false): void {
    if (Platform.OS === 'ios') native().requestPush(provisional);
  },

  /** iOS Live Activities: start (the type's push-to-start token) · update (a running activity's token) · end. */
  liveActivity(kind: 'start' | 'update' | 'end', type: string, activity?: string, token?: string): void {
    if (Platform.OS === 'ios') native().liveActivity(kind, type, activity ?? null, token ?? null);
  },

  /**
   * link: a notification's, a button's or a link after install, to open. messages: what to show now. config: the config
   * was read. banned: the phone was stopped (the SDK already blocks the screens).
   */
  on,

  /**
   * Sends JavaScript errors that nothing caught as non-fatal crashes, then hands them on to the handler that was there
   * (React Native's own, which shows the red box or closes the app). Call once, at the top of index.js.
   */
  catchJsErrors(): void {
    const g = globalThis as unknown as {
      ErrorUtils?: { getGlobalHandler(): (e: unknown, fatal?: boolean) => void; setGlobalHandler(h: (e: unknown, fatal?: boolean) => void): void };
    };
    const eu = g.ErrorUtils;
    if (!eu || (eu as { __drs?: boolean }).__drs) return;
    const before = eu.getGlobalHandler();
    eu.setGlobalHandler((e, fatal) => {
      try {
        DrSocial.reportError(e);
      } catch {
        // the SDK never stands in the app's way
      }
      before(e, fatal);
    });
    (eu as { __drs?: boolean }).__drs = true;
  },
};

export default DrSocial;
