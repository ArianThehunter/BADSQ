/**
 * RatingQueue — human rating of AUDIO_RECORD responses.
 *
 * Rating is binary (correct / incorrect), matching audio_recordings.primary_rating.
 * Saving a rating fires the propagate_audio_rating trigger (migration 0001),
 * which copies is_correct/scored_by onto the linked response row — this
 * component never writes to `responses` directly.
 *
 * is_reliability_subsample has no automatic assignment anywhere in the schema
 * (checked: submit_session() never sets it). Surfacing it "visibly" per the
 * brief therefore includes a way to actually set it — a Phase 3 addition
 * beyond the literal ask, documented in PHASE_3_REPORT.md.
 */

import { useCallback, useEffect, useState } from 'react';
import type { ResearcherProfile } from '../lib/supabaseClient';
import {
  listRatingQueue,
  signedRatingAudioUrl,
  submitPrimaryRating,
  setReliabilitySubsample,
  type RatingQueueRow,
} from '../lib/adminData';

export default function RatingQueue({ profile }: { profile: ResearcherProfile }) {
  const [rows, setRows] = useState<RatingQueueRow[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [includeRated, setIncludeRated] = useState(false);
  const [playingUrl, setPlayingUrl] = useState<Record<string, string>>({});
  const [busy, setBusy] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      const data = await listRatingQueue(includeRated);
      setRows(data);
      setError(null);
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    }
  }, [includeRated]);

  useEffect(() => {
    // (oxlint flags this as react/set-state-in-effect; not applicable here —
    // load()'s setState calls run after an await, on mount and whenever
    // includeRated changes, not synchronously as part of the effect's own
    // body. Same accepted pattern as AuthGate.tsx's resolve().)
    void load();
  }, [load]);

  async function handlePlay(row: RatingQueueRow) {
    if (playingUrl[row.audioId]) return;
    try {
      const url = await signedRatingAudioUrl(row.storagePath);
      setPlayingUrl((prev) => ({ ...prev, [row.audioId]: url }));
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    }
  }

  async function handleRate(row: RatingQueueRow, correct: boolean) {
    if (!profile.can_rate) return;
    setBusy(row.audioId);
    try {
      await submitPrimaryRating(row.audioId, correct, profile.id);
      await load();
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setBusy(null);
    }
  }

  async function handleToggleSubsample(row: RatingQueueRow) {
    if (!profile.can_rate) return;
    setBusy(row.audioId);
    try {
      await setReliabilitySubsample(row.audioId, !row.isReliabilitySubsample);
      await load();
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setBusy(null);
    }
  }

  if (!profile.can_rate) {
    return (
      <div className="notice notice-warn">
        Your account is not marked <code>can_rate</code>. Ask a project administrator to grant
        rating permission in the <code>researchers</code> table.
      </div>
    );
  }

  return (
    <div>
      <div className="row-between">
        <h2>Rating queue</h2>
        <label className="small">
          <input
            type="checkbox"
            checked={includeRated}
            onChange={(e) => setIncludeRated(e.target.checked)}
          />{' '}
          Show already-rated recordings
        </label>
      </div>

      {error && <div className="notice notice-error">{error}</div>}

      {rows === null ? (
        <p className="muted">Loading…</p>
      ) : rows.length === 0 ? (
        <p className="muted">
          {includeRated ? 'No audio recordings exist yet.' : 'Nothing pending rating right now.'}
        </p>
      ) : (
        <div className="table-scroll">
          <table>
            <thead>
              <tr>
                <th>Item</th>
                <th>Participant</th>
                <th>Recording</th>
                <th>Reliability subsample</th>
                <th>Status</th>
                <th>Rate</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((row) => (
                <tr key={row.audioId}>
                  <td>
                    <code>{row.itemCode}</code>
                    {row.stimulusText && <div className="muted small bangla-cell">{row.stimulusText}</div>}
                  </td>
                  <td className="small">
                    {row.anonymizedCode ?? '(no code)'}
                    {row.classGrade != null && <div className="muted">grade {row.classGrade}</div>}
                  </td>
                  <td>
                    {playingUrl[row.audioId] ? (
                      <audio controls src={playingUrl[row.audioId]} />
                    ) : (
                      <button type="button" onClick={() => handlePlay(row)}>
                        Load recording
                      </button>
                    )}
                    {row.durationMs != null && (
                      <div className="muted small">{Math.round(row.durationMs / 100) / 10}s</div>
                    )}
                  </td>
                  <td>
                    <label>
                      <input
                        type="checkbox"
                        checked={row.isReliabilitySubsample}
                        disabled={busy === row.audioId}
                        onChange={() => handleToggleSubsample(row)}
                      />{' '}
                      <span className="small">included</span>
                    </label>
                  </td>
                  <td>
                    <span className={row.ratingStatus === 'rated' ? 'pill pill-on' : 'pill'}>
                      {row.ratingStatus}
                    </span>
                    {row.primaryRating != null && (
                      <div className="muted small">primary: {row.primaryRating ? 'correct' : 'incorrect'}</div>
                    )}
                  </td>
                  <td className="actions-cell">
                    <button type="button" disabled={busy === row.audioId} onClick={() => handleRate(row, true)}>
                      Correct
                    </button>
                    <button type="button" disabled={busy === row.audioId} onClick={() => handleRate(row, false)}>
                      Incorrect
                    </button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
