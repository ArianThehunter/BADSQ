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

export default function App() {
  const [items, setItems] = useState<CheckState>({ kind: 'pending' });
  const [options, setOptions] = useState<CheckState>({ kind: 'pending' });

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
        </ul>
        <p style={{ color: 'var(--color-muted)', fontSize: '0.875rem' }}>
          Both checks are expected to FAIL until finding F1 in PHASE_0_REPORT.md is resolved:
          migration 0003 revoked SELECT on <code>items</code> from the client roles while its
          replacement views use <code>security_invoker = on</code>, which defers the base-table
          privilege check to the caller. No client role can read the item bank through any path.
        </p>
      </section>
    </main>
  );
}
