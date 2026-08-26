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
      // CHANGED IN PHASE 1. Phase 0 set this false on the reasoning that "no
      // OAuth redirects are used" — but researcher magic-link login IS a
      // redirect flow, and with it false the returning link would never
      // establish a session. PKCE is chosen over the implicit flow so the
      // redirect carries a short-lived single-use `code` in the query string
      // rather than access/refresh tokens in the URL fragment.
      detectSessionInUrl: true,
      flowType: 'pkce',
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

/** A researcher's allowlist row. Absent means: signed in, but not authorised. */
export type ResearcherProfile = {
  id: string;
  email: string;
  can_rate: boolean;
  can_manage_items: boolean;
};

/**
 * Send a magic link to a researcher.
 *
 * Being on the `researchers` allowlist is NOT checked here, and cannot be:
 * `researchers` is readable only by an already-allowlisted user, so an
 * unauthorised address would learn nothing either way. Anyone may request a
 * link; authorisation is decided after sign-in by loadResearcherProfile(), and
 * enforced for real by RLS on every table.
 */
export async function sendResearcherMagicLink(email: string): Promise<void> {
  const { error } = await supabase.auth.signInWithOtp({
    email: email.trim().toLowerCase(),
    options: {
      emailRedirectTo: `${window.location.origin}${window.location.pathname}#/admin`,
      // Researchers are pre-provisioned in the allowlist. Never let a magic-link
      // request create a brand-new auth user.
      shouldCreateUser: false,
    },
  });
  if (error) throw new Error(error.message);
}

/**
 * Load the signed-in user's allowlist row, or null if they are not a researcher.
 *
 * Returns null both for "not on the allowlist" and for "on the allowlist but
 * user_id was never linked" — see the known gap noted in PHASE_1_REPORT.md:
 * `link_researcher_on_signup` fires only on auth.users INSERT, so an address
 * added to the allowlist AFTER that person first signed in stays unlinked.
 */
export async function loadResearcherProfile(): Promise<ResearcherProfile | null> {
  const { data: userData } = await supabase.auth.getUser();
  const uid = userData.user?.id;
  if (!uid) return null;

  const { data, error } = await supabase
    .from('researchers')
    .select('id, email, can_rate, can_manage_items')
    .eq('user_id', uid)
    .maybeSingle();

  if (error || !data) return null;
  return data as ResearcherProfile;
}

export async function signOut(): Promise<void> {
  await supabase.auth.signOut();
}

/**
 * Open a session and get back the participant code.
 *
 * The code is issued SERVER-SIDE (migration 0004) and is the join key between
 * the paper parental-consent form and this anonymous digital session. The
 * supervising teacher writes it onto the paper form; at submit it becomes
 * `participants.anonymized_code`. Never generate or override it client-side —
 * `submit_session()` deliberately ignores any code sent in its payload.
 *
 * Show the returned code on screen for transcription. Its alphabet excludes
 * I, O, 0 and 1 precisely because a person copies it by hand and another person
 * reads it back.
 */
export async function startSession(): Promise<{ sessionId: string; assignedCode: string }> {
  await ensureAnonymousSession();

  const { data, error } = await supabase.rpc('start_session');
  if (error) throw new Error(`start_session failed: ${error.message}`);

  const row = Array.isArray(data) ? data[0] : data;
  if (!row?.out_session_id || !row?.out_assigned_code) {
    throw new Error('start_session returned no session id or code');
  }
  return { sessionId: row.out_session_id, assignedCode: row.out_assigned_code };
}
