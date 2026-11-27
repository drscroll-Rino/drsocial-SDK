/** One frame of a JavaScript stack, in the platform's crash frame shape (API.md `crashes`). */
export interface JsFrame {
  fn: string;
  file?: string;
  line?: number;
}

const MAX_FRAMES = 40;
const MAX_TEXT = 200;

/** The file's own name, never a whole path or address (a bundle URL can carry a host and a query). */
function fileName(raw: string): string {
  const noQuery = raw.split(/[?#]/)[0] ?? raw;
  const parts = noQuery.split('/');
  return (parts[parts.length - 1] || noQuery).slice(0, MAX_TEXT);
}

/**
 * Reads a JavaScript stack (Hermes, JSC and V8 shapes) into frames, top first, ≤ 40. A line that is no frame is skipped;
 * nothing else is kept from the stack, so a value inside a message never reaches a frame.
 */
export function parseStack(stack: string | undefined | null): JsFrame[] {
  if (!stack) return [];
  const frames: JsFrame[] = [];
  for (const raw of stack.split('\n')) {
    const line = raw.trim();
    if (line === '') continue;
    // V8 / Hermes: "at fn (file:line:col)", "at file:line:col", "at fn (address at file:line:col)"
    let m = /^at (?:(.+?) \()?(?:address at )?(.+?):(\d+):\d+\)?$/.exec(line);
    // JSC: "fn@file:line:col", "@file:line:col"
    if (!m) {
      const j = /^(.*?)@(.+?):(\d+):\d+$/.exec(line);
      if (j) m = j;
    }
    if (m) {
      frames.push({ fn: (m[1] || '?').slice(0, MAX_TEXT), file: fileName(m[2] ?? ''), line: Number(m[3]) });
    } else if (/^at (.+)$/.test(line) || /^[\w$.<>]+$/.test(line)) {
      // "at fn (native)", a bare name: a frame with no place
      const fn = line.replace(/^at /, '').replace(/ \(native\)$/, '');
      if (fn !== '' && !/[\s:]/.test(fn)) frames.push({ fn: fn.slice(0, MAX_TEXT) });
    }
    if (frames.length >= MAX_FRAMES) break;
  }
  return frames;
}

/** What a thrown value says about itself: its type and message (≤ 200 each). */
export function describeError(e: unknown): { type: string; message: string; frames: JsFrame[] } {
  if (e instanceof Error) {
    return { type: (e.name || 'Error').slice(0, MAX_TEXT), message: (e.message || '').slice(0, MAX_TEXT), frames: parseStack(e.stack) };
  }
  return { type: 'Error', message: String(e).slice(0, MAX_TEXT), frames: [] };
}
