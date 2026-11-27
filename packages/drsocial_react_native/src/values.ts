/** A value the platform accepts in an event's props or a person's traits: text, number, true/false or null. */
export type Plain = string | number | boolean | null;

const NAME = /^[a-z][a-z0-9_]{0,63}$/;

/** An event or trait name as the platform takes it (lower case, digits, _; starts with a letter; ≤ 64). */
export function validName(name: string): boolean {
  return NAME.test(name);
}

/**
 * Keeps up to [max] plain values with valid names; drops objects, lists, functions, NaN and Infinity, which the native
 * layer could not carry the same way on both phones.
 */
export function plainProps(props: Record<string, unknown> | undefined, max = 20): Record<string, Plain> {
  const out: Record<string, Plain> = {};
  if (!props) return out;
  let n = 0;
  for (const [k, v] of Object.entries(props)) {
    if (n >= max) break;
    if (!validName(k)) continue;
    if (v === null || typeof v === 'string' || typeof v === 'boolean' || (typeof v === 'number' && Number.isFinite(v))) {
      out[k] = typeof v === 'string' ? v.slice(0, 200) : (v as Plain);
      n++;
    }
  }
  return out;
}

/** Reads a remote value the native layer handed over as JSON text ('' or bad text = not set). */
export function readJson(text: string | null | undefined): unknown {
  if (text == null || text === '') return undefined;
  try {
    return JSON.parse(text);
  } catch {
    return undefined;
  }
}
