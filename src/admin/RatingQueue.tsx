/**
 * RatingQueue — researcher review of AUDIO_RECORD responses.
 *
 * CHANGED IN MIGRATION 0010: this used to require a binary correct/incorrect
 * click per recording, which the `propagate_audio_rating` trigger copied onto
 * `responses.is_correct`. That decision was reversed — correctness for
 * AUDIO_RECORD responses is now decided later by an offline model run against
 * the raw stored audio, not live by a human. This component is now a
 * listen-and-note tool: play the recording, optionally leave a free-text
 * note, mark it reviewed. It never writes `responses.is_correct`.
 *
 * is_reliability_subsample is assigned automatically at submission time
 * (migration 0008, reliability_subsample_rate() — 20% by default) so the
 * double-scored sample is unbiased by construction rather than rater-chosen.
 * The checkbox below is a manual OVERRIDE on top of that random baseline —
 * not the primary assignment mechanism. See PHASE_3_REPORT.md for why it
 * started as manual-only, and PHASE_4_REPORT.md for why that was a
 * methodological problem worth fixing before any real kappa gets computed.
 */

import { useCallback, useEffect, useState } from 'react';
import type { ResearcherProfile } from '../lib/supabaseClient';
import {
  listRatingQueue,
  signedRatingAudioUrl,
  saveRecordingNotes,
  setReliabilitySubsample,
  type RatingQueueRow,
} from '../lib/adminData';

export default function RatingQueue({ profile }: { profile: ResearcherProfile }) {
  const [rows, setRows] = useState<RatingQueueRow[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [includeRated, setIncludeRated] = useState(false);
  const [playingUrl, setPlayingUrl] = useState<Record<string, string>>({});
  const [busy, setBusy] = useState<string | null>(null);
  const [noteDrafts, setNoteDrafts] = useState<Record<string, string>>({});

  const load = useCallback(async () => {
    try {
      const data = await listRatingQueue(includeRated);
      setRows(data);
      setNoteDrafts((prev) => {
        const next = { ...prev };
        for (const row of data) if (!(row.audioId in next)) next[row.audioId] = row.notes ?? '';
        return next;
      });
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

  async function handleSaveNote(row: RatingQueueRow) {
    if (!profile.can_rate) return;
    setBusy(row.audioId);
    try {
      await saveRecordingNotes(row.audioId, noteDrafts[row.audioId] ?? '', profile.id);
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
          Show already-reviewed recordings
        </label>
      </div>

      <p className="muted small">
        Correctness for these recordings is decided later by an offline model against the raw
        audio, not here. Use this to listen and leave notes for your own records — it never sets a
        correct/incorrect score.
      </p>

      {error && <div className="notice notice-error">{error}</div>}

      {rows === null ? (
        <p className="muted">Loading…</p>
      ) : rows.length === 0 ? (
        <p className="muted">
          {includeRated ? 'No audio recordings exist yet.' : 'Nothing pending review right now.'}
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
                <th>Notes</th>
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
                      {row.ratingStatus === 'rated' ? 'reviewed' : row.ratingStatus}
                    </span>
                  </td>
                  <td className="notes-cell">
                    <textarea
                      rows={2}
                      className="small"
                      placeholder="Optional note (e.g. unclear audio, background noise)…"
                      value={noteDrafts[row.audioId] ?? ''}
                      disabled={busy === row.audioId}
                      onChange={(e) =>
                        setNoteDrafts((prev) => ({ ...prev, [row.audioId]: e.target.value }))
                      }
                    />
                    <button type="button" disabled={busy === row.audioId} onClick={() => void handleSaveNote(row)}>
                      Mark reviewed
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
