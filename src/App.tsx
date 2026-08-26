/**
 * Phase 0 status page.
 *
 * This is NOT the participant test flow — that is Phase 1 (TestRunner). Its only
 * job is to prove the scaffold builds, the Supabase client is wired to the right
 * project, the pinned Unicode Bangla font renders, and to report the live state
 * of the participant read path honestly rather than hiding a failure.
 */

import { useEffect, useState } from 'react';
import { supabase, SUPABASE_URL } from './lib/supabaseClient';
import AuthGate from './admin/AuthGate';
import AdminShell from './admin/AdminShell';
import './admin.css';

type CheckState =
  | { kind: 'pending' }
  | { kind: 'ok'; detail: string }
  | { kind: 'fail'; detail: string };

function Row({ label, state }: { label: string; state: CheckState }) {
  const symbol = state.kind === 'ok' ? 'PASS' : state.kind === 'fail' ? 'FAIL' : '…';
  const color =
    state.kind === 'ok' ? '#0f7b3f' : state.kind === 'fail' ? '#b3261e' : 'var(--color-muted)';
  return (
    <li style={{ marginBottom: '1rem' }}>
      <div style={{ fontWeight: 600 }}>
        <span style={{ color, fontVariantNumeric: 'tabular-nums' }}>[{symbol}]</span> {label}
      </div>
      {state.kind !== 'pending' && (
        <div
          style={{
            color: 'var(--color-muted)',
            fontSize: '0.875rem',
            whiteSpace: 'pre-wrap',
            wordBreak: 'break-word',
          }}
        >
          {state.detail}
        </div>
      )}
    </li>
  );
}

/** Trivial hash router: `#/admin...` goes to the researcher panel, anything
 * else is the Phase 0 status page. No routing library — the surface here is
 * two branches. */
function useIsAdminRoute(): boolean {
  const [isAdmin, setIsAdmin] = useState(() => window.location.hash.startsWith('#/admin'));
  useEffect(() => {
    const onHash = () => setIsAdmin(window.location.hash.startsWith('#/admin'));
    window.addEventListener('hashchange', onHash);
    return () => window.removeEventListener('hashchange', onHash);
  }, []);
  return isAdmin;
}

export default function App() {
  const isAdminRoute = useIsAdminRoute();

  if (isAdminRoute) {
    return (
      <AuthGate>
        {({ profile, email }) => <AdminShell profile={profile} email={email} />}
      </AuthGate>
    );
  }

  return <StatusPage />;
}

function StatusPage() {
  const [items, setItems] = useState<CheckState>({ kind: 'pending' });
  const [options, setOptions] = useState<CheckState>({ kind: 'pending' });
  const [audioCols, setAudioCols] = useState<CheckState>({ kind: 'pending' });

  useEffect(() => {
    let cancelled = false;

    (async () => {
      // The participant-facing read path, exactly as TestRunner will use it.
      const { data, error } = await supabase
        .from('public_items')
        .select('item_code, domain, response_format')
        .order('display_order', { ascending: true });

      if (cancelled) return;
      setItems(
        error
          ? { kind: 'fail', detail: `${error.code ?? '?'}: ${error.message}` }
          : { kind: 'ok', detail: `${data?.length ?? 0} active item(s) readable` },
      );

      const res = await supabase.from('public_item_options').select('item_id, option_key');
      if (cancelled) return;
      setOptions(
        res.error
          ? { kind: 'fail', detail: `${res.error.code ?? '?'}: ${res.error.message}` }
          : { kind: 'ok', detail: `${res.data?.length ?? 0} option row(s) readable` },
      );

      // Migration 0004 renamed items.*_audio_url to *_audio_path but never
      // recreated public_items (finding G1, PHASE_0_REPORT.md). Migration 0005
      // dropped and recreated the view with the correct names — this check now
      // asserts that fix holds, rather than documenting the defect.
      const audio = await supabase
        .from('public_items')
        .select('item_code, instruction_audio_path, stimulus_audio_path');
      if (cancelled) return;
      setAudioCols(
        audio.error
          ? { kind: 'fail', detail: `${audio.error.code ?? '?'}: ${audio.error.message}` }
          : { kind: 'ok', detail: 'view exposes instruction_audio_path / stimulus_audio_path (G1 fix holds)' },
      );
    })();

    return () => {
      cancelled = true;
    };
  }, []);

  return (
    <main style={{ maxWidth: '44rem', margin: '0 auto', padding: '2rem 1.25rem' }}>
      <h1 style={{ marginBottom: '0.25rem' }}>BADSQ — Phase 0</h1>
      <p style={{ color: 'var(--color-muted)', marginTop: 0 }}>
        Scaffold, migrations, and RLS verification. The participant test flow is Phase 1.
      </p>
      <p style={{ marginTop: 0 }}>
        <a href="#/admin">Researcher admin panel &rarr;</a>
      </p>

      <section
        style={{
          border: '1px solid var(--color-border)',
          borderRadius: 8,
          padding: '1rem 1.25rem',
          marginTop: '1.5rem',
        }}
      >
        <h2 style={{ fontSize: '1rem', marginTop: 0 }}>Bangla Unicode rendering</h2>
        <p lang="bn" style={{ fontSize: '1.5rem', margin: '0.5rem 0' }}>
          বাংলা শব্দ — দ্বিতীয় প্রশ্ন — হ্যাঁ / না — ০১২৩৪৫৬৭৮৯
        </p>
        <p style={{ color: 'var(--color-muted)', fontSize: '0.875rem', margin: 0 }}>
          If the line above shows Latin letters or boxes instead of Bangla script, the pinned
          Unicode font did not load — treat that as a correctness failure, not a styling issue.
        </p>
      </section>

      <section style={{ marginTop: '1.5rem' }}>
        <h2 style={{ fontSize: '1rem' }}>Live database checks</h2>
        <p style={{ color: 'var(--color-muted)', fontSize: '0.875rem', marginTop: 0 }}>
          Project: <code>{SUPABASE_URL}</code>
        </p>
        <ul style={{ listStyle: 'none', padding: 0 }}>
          <Row label="Read the item bank via public_items" state={items} />
          <Row label="Read options via public_item_options" state={options} />
          <Row label="public_items exposes the renamed *_audio_path columns" state={audioCols} />
        </ul>
        <p style={{ color: 'var(--color-muted)', fontSize: '0.875rem' }}>
          All three checks should now pass (as of migration 0005). Row counts reflect whatever is
          currently in the item bank — 0 is expected on an empty bank, not a failure. What matters
          is HTTP 200 with no permission error, and (for the third check) that the renamed audio
          path columns actually resolve. See PHASE_0_REPORT.md (F1) and MIGRATION_0004_REPORT.md
          (G1) for the history of this defect, and PHASE_1_REPORT.md for the 0005 fix.
        </p>
      </section>
    </main>
  );
}
