/**
 * Supabase client for the BADSQ platform.
 *
 * Two identities use this client:
 *   - Participants: anonymous sign-in, no email/password. Scoped by RLS to
 *     their own session row. Never sees answer keys.
 *   - Researchers / raters: magic-link accounts, gated by the `researchers`
 *     allowlist table and enforced by RLS.
 *
 * PRIVACY: this app collects data from 12-14 year olds. There is no analytics,
 * telemetry, or third-party script anywhere in this bundle, by design. Do not
 * add one. The only network destination is the Supabase project below.
 */

import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import type { Database } from '../types/database.types';

function required(name: string): string {
  const value = import.meta.env[name as keyof ImportMetaEnv] as string | undefined;
  if (!value) {
    throw new Error(
      `Missing environment variable ${name}. Copy .env.example to .env and fill it in.`,
    );
  }
  return value;
}

export const SUPABASE_URL = required('VITE_SUPABASE_URL');
const SUPABASE_PUBLISHABLE_KEY = required('VITE_SUPABASE_PUBLISHABLE_KEY');

/** Storage bucket holding participant audio recordings (created by migration 0003). */
export const AUDIO_BUCKET =
  (import.meta.env.VITE_SUPABASE_AUDIO_BUCKET as string | undefined) ?? 'badsq-audio';

export const supabase: SupabaseClient<Database> = createClient<Database>(
  SUPABASE_URL,
  SUPABASE_PUBLISHABLE_KEY,
  {
    auth: {
      // Participants may reload mid-test; the session must survive that so the
      // same auth.uid() still owns their `sessions` row.
      persistSession: true,
      autoRefreshToken: true,
      // No OAuth redirects are used, so there is never a token in the URL.
      detectSessionInUrl: false,
    },
    global: {
      headers: { 'x-application-name': 'badsq-platform' },
    },
  },
);

/**
 * Ensure there is an authenticated identity for this browser before any write.
 *
 * Participants get an anonymous identity. This requires Anonymous Sign-ins to be
 * enabled in the Supabase dashboard (Authentication -> Providers); if it is not,
 * this throws with a message saying so rather than failing obscurely later.
 */
export async function ensureAnonymousSession() {
  const { data: existing } = await supabase.auth.getSession();
  if (existing.session) return existing.session;

  const { data, error } = await supabase.auth.signInAnonymously();
  if (error) {
    throw new Error(
      `Anonymous sign-in failed (${error.message}). If this says "Anonymous sign-ins are disabled", ` +
        'enable it in the Supabase dashboard under Authentication -> Providers.',
    );
  }
  return data.session;
}

/** Current auth uid, or null when not signed in. */
export async function currentAuthUid(): Promise<string | null> {
  const { data } = await supabase.auth.getUser();
  return data.user?.id ?? null;
}
