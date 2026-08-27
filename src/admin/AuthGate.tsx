/**
 * Researcher authentication gate.
 *
 * CHANGED IN PHASE 3: email + password, not a magic link. Accounts are created
 * only via the Supabase dashboard by a human (Authentication -> Users -> Add
 * user) — there is no sign-up form here, and none should be added.
 * `signInWithPassword` cannot create an account on its own, so that property
 * holds without this component doing anything extra to enforce it.
 *
 * Three distinct states are deliberately kept apart:
 *   - not signed in                -> ask for email + password
 *   - signed in, not allowlisted   -> say so plainly and offer sign out
 *   - wrong credentials / unconfirmed email -> shown inline on the form, not
 *     conflated with "not allowlisted" (a wrong password and a correct
 *     password for an unauthorised address are different problems with
 *     different fixes)
 * The middle state is not an error to hide. RLS means such a user can read
 * nothing, but telling them "you are signed in as X and X is not on the
 * allowlist" is far easier to act on than an empty screen.
 */

import { useCallback, useEffect, useState } from 'react';
import type { ReactNode } from 'react';
import {
  supabase,
  signInResearcher,
  ResearcherSignInError,
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
  const [password, setPassword] = useState('');
  const [signingIn, setSigningIn] = useState(false);
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

  async function handleSignIn(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    setSigningIn(true);
    try {
      await signInResearcher(email, password);
      // resolve() runs automatically via the onAuthStateChange listener above.
    } catch (err) {
      if (err instanceof ResearcherSignInError && err.code === 'email_not_confirmed') {
        setError(
          'This account exists but has not been confirmed. Ask a project administrator to ' +
            'confirm it directly in the Supabase dashboard (Authentication -> Users).',
        );
      } else if (err instanceof ResearcherSignInError && err.code === 'invalid_credentials') {
        setError('Incorrect email or password.');
      } else {
        setError(err instanceof Error ? err.message : String(err));
      }
    } finally {
      setSigningIn(false);
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
        Sign in with your researcher account. Accounts are created by a project administrator —
        there is no self-service sign-up.
      </p>

      <form onSubmit={handleSignIn}>
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
        <label htmlFor="researcher-password">Password</label>
        <input
          id="researcher-password"
          type="password"
          required
          autoComplete="current-password"
          value={password}
          onChange={(e) => setPassword(e.target.value)}
        />
        <button type="submit" disabled={signingIn || !email.trim() || !password}>
          {signingIn ? 'Signing in…' : 'Sign in'}
        </button>
      </form>

      {error && (
        <div className="notice notice-error" role="alert">
          <strong>Could not sign in.</strong> {error}
        </div>
      )}
    </div>
  );
}
