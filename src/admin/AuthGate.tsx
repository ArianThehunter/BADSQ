/**
 * Researcher authentication gate.
 *
 * Magic link only — no passwords anywhere in this system. Participants use
 * anonymous sign-in; researchers use a link sent to an address that must already
 * be on the `researchers` allowlist.
 *
 * Two distinct states are deliberately kept apart:
 *   - not signed in            -> ask for an email
 *   - signed in, not allowlisted -> say so plainly and offer sign out
 * The second is not an error to hide. RLS means such a user can read nothing,
 * but telling them "you are signed in as X and X is not on the allowlist" is far
 * easier to act on than an empty screen.
 */

import { useCallback, useEffect, useState } from 'react';
import type { ReactNode } from 'react';
import {
  supabase,
  sendResearcherMagicLink,
  loadResearcherProfile,
  signOut,
  type ResearcherProfile,
} from '../lib/supabaseClient';

type AuthState =
  | { kind: 'loading' }
  | { kind: 'signed_out' }
  | { kind: 'not_allowlisted'; email: string | null }
  | { kind: 'ready'; profile: ResearcherProfile; email: string | null };

export default function AuthGate({
  children,
}: {
  children: (ctx: { profile: ResearcherProfile; email: string | null }) => ReactNode;
}) {
  const [state, setState] = useState<AuthState>({ kind: 'loading' });
  const [email, setEmail] = useState('');
  const [sending, setSending] = useState(false);
  const [sent, setSent] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const resolve = useCallback(async () => {
    const { data } = await supabase.auth.getSession();
    if (!data.session) {
      setState({ kind: 'signed_out' });
      return;
    }
    const signedInAs = data.session.user.email ?? null;
    const profile = await loadResearcherProfile();
    // (oxlint flags this as react/set-state-in-effect; not applicable here — this
    // setState runs after an await, resolving the session on mount and on every
    // auth state change, not synchronously as part of the effect's own body.)
    setState(profile ? { kind: 'ready', profile, email: signedInAs } : { kind: 'not_allowlisted', email: signedInAs });
  }, []);

  useEffect(() => {
    void resolve();
    const { data: sub } = supabase.auth.onAuthStateChange(() => {
      void resolve();
    });
    return () => sub.subscription.unsubscribe();
  }, [resolve]);

  async function handleSend(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    setSending(true);
    try {
      await sendResearcherMagicLink(email);
      setSent(true);
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setSending(false);
    }
  }

  if (state.kind === 'loading') {
    return <p className="muted pad">Checking your session…</p>;
  }

  if (state.kind === 'ready') {
    return <>{children({ profile: state.profile, email: state.email })}</>;
  }

  if (state.kind === 'not_allowlisted') {
    return (
      <div className="auth-card">
        <h1>Not authorised</h1>
        <p>
          You are signed in as <strong>{state.email ?? 'an unknown address'}</strong>, but that
          address is not on the researcher allowlist, so there is nothing you can access.
        </p>
        <p className="muted small">
          A project administrator must add the address to the <code>researchers</code> table.
          Note that the allowlist link is made when the account is first created — if the address
          was added <em>after</em> you first signed in, it will need to be linked manually.
        </p>
        <button
          type="button"
          onClick={async () => {
            await signOut();
            await resolve();
          }}
        >
          Sign out
        </button>
      </div>
    );
  }

  return (
    <div className="auth-card">
      <h1>BADSQ — researcher sign in</h1>
      <p className="muted">
        Enter your allowlisted address and we will email you a sign-in link. There is no password.
      </p>

      {sent ? (
        <div className="notice notice-ok" role="status">
          <p>
            If <strong>{email}</strong> is on the allowlist, a sign-in link is on its way. Open it
            on this device — the link completes the sign-in here.
          </p>
          <button
            type="button"
            onClick={() => {
              setSent(false);
              setEmail('');
            }}
          >
            Use a different address
          </button>
        </div>
      ) : (
        <form onSubmit={handleSend}>
          <label htmlFor="researcher-email">Email address</label>
          <input
            id="researcher-email"
            type="email"
            required
            autoComplete="email"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            placeholder="you@example.org"
          />
          <button type="submit" disabled={sending || !email.trim()}>
            {sending ? 'Sending…' : 'Email me a sign-in link'}
          </button>
        </form>
      )}

      {error && (
        <div className="notice notice-error" role="alert">
          <strong>Could not send the link.</strong> {error}
        </div>
      )}
    </div>
  );
}
