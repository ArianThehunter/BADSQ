/**
 * Admin shell — identity banner, sign out, nav.
 *
 * Deliberately minimal. The only view implemented in this phase is the Item Bank
 * Editor; the rest are declared so the structure is visible and are shown as
 * "not built yet" rather than as broken links.
 */

import { useEffect, useState } from 'react';
import { signOut, type ResearcherProfile } from '../lib/supabaseClient';
import ItemBankEditor from './ItemBankEditor';
import ParticipantsView from './ParticipantsView';
import RatingQueue from './RatingQueue';
import HealthView from './HealthView';

type Tab = 'items' | 'participants' | 'rating' | 'health';

const TABS: { id: Tab; label: string; phase: string | null }[] = [
  { id: 'items', label: 'Item bank', phase: null },
  { id: 'participants', label: 'Participants', phase: null },
  { id: 'rating', label: 'Rating queue', phase: null },
  { id: 'health', label: 'Health', phase: null },
];

function readTab(): Tab {
  const m = /^#\/admin\/(\w+)/.exec(window.location.hash);
  const found = TABS.find((t) => t.id === m?.[1]);
  return found ? found.id : 'items';
}

export default function AdminShell({
  profile,
  email,
}: {
  profile: ResearcherProfile;
  email: string | null;
}) {
  const [tab, setTab] = useState<Tab>(readTab);

  useEffect(() => {
    const onHash = () => setTab(readTab());
    window.addEventListener('hashchange', onHash);
    return () => window.removeEventListener('hashchange', onHash);
  }, []);

  const roles = [
    profile.can_manage_items ? 'can manage items' : null,
    profile.can_rate ? 'can rate audio' : null,
  ].filter(Boolean);

  return (
    <div className="admin">
      <header className="admin-bar">
        <div>
          <span className="admin-title">BADSQ admin</span>
          <span className="muted small">
            {email ?? profile.email}
            {roles.length > 0 ? ` · ${roles.join(' · ')}` : ' · no permissions granted'}
          </span>
        </div>
        <button type="button" onClick={() => void signOut()}>
          Sign out
        </button>
      </header>

      <nav className="admin-nav" aria-label="Admin sections">
        {TABS.map((t) => (
          <a
            key={t.id}
            href={`#/admin/${t.id}`}
            aria-current={tab === t.id ? 'page' : undefined}
            className={tab === t.id ? 'active' : undefined}
          >
            {t.label}
            {t.phase && <span className="badge">{t.phase}</span>}
          </a>
        ))}
      </nav>

      <main className="admin-main">
        {tab === 'items' && <ItemBankEditor profile={profile} />}
        {tab === 'participants' && <ParticipantsView profile={profile} />}
        {tab === 'rating' && <RatingQueue profile={profile} />}
        {tab === 'health' && <HealthView />}
      </main>
    </div>
  );
}
