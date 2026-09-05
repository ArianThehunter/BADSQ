/**
 * RatingQueue — researcher review of participant AUDIO_RECORD responses.
 *
 * WHAT A RATING HERE DOES (and does not do): the Correct/Incorrect judgment is
 * written to `audio_recordings.primary_rating` only. It never sets
 * `responses.is_correct`, which stays NULL for every response of every format
 * (migration 0012) — the tool does not grade participants. This judgment
 * exists as a researcher's own reference value, exported alongside a playable
 * URL in the full CSV (`full_export_v1.audio_marked_correct`). See
 * submitPrimaryRating()'s doc comment for the 0010 -> 0013 history.
 *
 * Rewritten from a seven-column table to filtered cards: this screen is used
 * to work through a backlog one recording at a time, so it now loads every
 * recording once, shows real progress, and lets a reviewer take one subdomain
 * at a time (rating all of 2.6 in a row is faster and more consistent than
 * jumping between task types).
 */

import { useCallback, useEffect, useMemo, useState } from 'react';
import type { ResearcherProfile } from '../lib/supabaseClient';
import { listRecordings, type RatingQueueRow } from '../lib/adminData';
import RecordingCard from './RecordingCard';

export default function RatingQueue({ profile }: { profile: ResearcherProfile }) {
  const [rows, setRows] = useState<RatingQueueRow[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [showReviewed, setShowReviewed] = useState(false);
  const [subdomain, setSubdomain] = useState<string>('all');

  const load = useCallback(async () => {
    try {
      // Everything, always: the counts below need the full picture, and
      // switching filters should not re-query.
      setRows(await listRecordings({ includeRated: true }));
      setError(null);
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    }
  }, []);

  useEffect(() => {
    // (oxlint flags this as react/set-state-in-effect; not applicable — load()'s
    // setState calls run after an await, on mount, not synchronously as part of
    // the effect body. Same accepted pattern as AuthGate.tsx's resolve().)
    void load();
  }, [load]);

  const subdomains = useMemo(() => {
    const set = new Set<string>();
    for (const r of rows ?? []) if (r.subdomain) set.add(r.subdomain);
    return [...set].sort();
  }, [rows]);

  // "Reviewed" means a verdict was recorded — including 'unclear', which is a
  // finished decision, not outstanding work.
  const pendingTotal = (rows ?? []).filter((r) => r.verdict == null).length;
  const reviewedTotal = (rows ?? []).filter((r) => r.verdict != null).length;
  const unclearTotal = (rows ?? []).filter((r) => r.verdict === 'unclear').length;

  const visible = useMemo(
    () =>
      (rows ?? []).filter((r) => {
        if (!showReviewed && r.verdict != null) return false;
        if (subdomain !== 'all' && r.subdomain !== subdomain) return false;
        return true;
      }),
    [rows, showReviewed, subdomain],
  );

  if (!profile.can_rate) {
    return (
      <div className="notice notice-warn">
        Your account is not marked <code>can_rate</code>. Ask a project administrator to grant rating permission
        in the <code>researchers</code> table.
      </div>
    );
  }

  return (
    <div>
      <div className="row-between">
        <h2>Rating queue</h2>
        {rows && (
          <p className="small muted">
            <strong>{pendingTotal}</strong> to review · {reviewedTotal} done
            {unclearTotal > 0 && ` (${unclearTotal} unclear)`}
          </p>
        )}
      </div>

      <div className="notice">
        <p className="small" style={{ margin: 0 }}>
          Listen to each recording and mark whether the participant's spoken answer was correct, or{' '}
          <strong>unclear</strong> if the audio can't be judged. This is your own reference judgment — it is saved
          with the recording's URL in the full CSV export and never scores the participant automatically. You can
          change a verdict later; the most recent one is what's stored.
        </p>
      </div>

      {error && <div className="notice notice-error">{error}</div>}

      <div className="filters">
        <label className="small">
          Task{' '}
          <select value={subdomain} onChange={(e) => setSubdomain(e.target.value)}>
            <option value="all">All tasks</option>
            {subdomains.map((s) => (
              <option key={s} value={s}>
                {s}
              </option>
            ))}
          </select>
        </label>
        <label className="small">
          <input type="checkbox" checked={showReviewed} onChange={(e) => setShowReviewed(e.target.checked)} />{' '}
          Show recordings I've already reviewed
        </label>
      </div>

      {rows === null ? (
        <p className="muted">Loading…</p>
      ) : visible.length === 0 ? (
        <p className="muted">
          {rows.length === 0
            ? 'No audio recordings have been submitted yet.'
            : pendingTotal === 0
              ? 'All recordings have been reviewed. ✓'
              : 'Nothing matches these filters.'}
        </p>
      ) : (
        <div className="rec-list">
          {visible.map((row) => (
            <RecordingCard
              key={row.audioId}
              row={row}
              canRate={profile.can_rate}
              raterId={profile.id}
              onChanged={load}
            />
          ))}
        </div>
      )}
    </div>
  );
}
