/**
 * Turn an unknown thrown value into something a human can act on.
 *
 * WHY THIS EXISTS: every catch block here used to do
 *   `e instanceof Error ? e.message : String(e)`
 * which is correct for `throw new Error(...)` and useless for everything else.
 * Supabase's client does NOT throw — it returns `{ data, error }` where `error`
 * is a plain object (`PostgrestError`: message/code/details/hint; `StorageError`:
 * message/statusCode). Code that did `if (err) throw err` therefore threw a
 * non-Error, `String(e)` produced the literal text "[object Object]", and the
 * participant-facing screen showed:
 *
 *     Could not load the test: [object Object]
 *
 * — which tells the supervising researcher nothing at all about what broke.
 * That is a real incident cost, not a cosmetic one: it happened during a live
 * test run and left no way to diagnose it from the device.
 */

/** Shape of the plain error objects the Supabase client returns (never throws). */
type SupabaseLikeError = {
  message?: unknown;
  code?: unknown;
  details?: unknown;
  hint?: unknown;
  statusCode?: unknown;
  error_description?: unknown;
};

function str(v: unknown): string | null {
  if (typeof v === 'string' && v.trim() !== '') return v.trim();
  if (typeof v === 'number') return String(v);
  return null;
}

export function errorMessage(e: unknown): string {
  if (e == null) return 'unknown error';

  // Error and its subclasses, including DOMException (IndexedDB, media).
  if (e instanceof Error) {
    const name = e.name && e.name !== 'Error' ? `${e.name}: ` : '';
    return `${name}${e.message || 'no message'}`;
  }

  if (typeof e === 'string') return e;

  if (typeof e === 'object') {
    const o = e as SupabaseLikeError;
    const parts: string[] = [];
    const msg = str(o.message) ?? str(o.error_description);
    if (msg) parts.push(msg);
    const code = str(o.code) ?? str(o.statusCode);
    if (code) parts.push(`[${code}]`);
    const details = str(o.details);
    if (details && details !== msg) parts.push(details);
    const hint = str(o.hint);
    if (hint) parts.push(`(hint: ${hint})`);
    if (parts.length > 0) return parts.join(' ');

    // Last resort: show the shape rather than "[object Object]".
    try {
      const json = JSON.stringify(e);
      if (json && json !== '{}') return json;
    } catch {
      // Circular or otherwise unserialisable — fall through.
    }
  }

  return String(e);
}

/**
 * Wrap a Supabase `{ error }` value in a real Error carrying context about
 * which call failed, so the message identifies the failing step rather than
 * just quoting Postgres.
 */
export function asError(context: string, e: unknown): Error {
  return new Error(`${context}: ${errorMessage(e)}`);
}
