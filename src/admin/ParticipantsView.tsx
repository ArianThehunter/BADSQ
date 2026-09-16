/**
 * ParticipantsView — read-only roster, identified only by anonymized_code,
 * with a per-participant drill-down into their audio recordings.
 *
 * Never shows anything that could re-identify a participant (no raw session
 * auth_uid, no IP, no free-text). class_grade/age_months are the only
 * demographic fields the schema keeps at this table, and both were supplied
 * by the participant's own TestRunner session, not derived from anything
 * identifying.
 *
 * The drill-down reuses RecordingCard, so a recording can be played and rated
 * here exactly as it can in the Rating Queue — same underlying writes, no
 * second code path. Recordings load lazily per participant: a roster of many
 * completed sessions should not fetch every recording up front.
 */

import { Fragment, useCallback, useEffect, useState } from 'react';
import type { ResearcherProfile } from '../lib/supabaseClient';
import {
  listParticipants,
  listRecordings,
  deleteParticipant,
  type ParticipantRow,
  type RatingQueueRow,
} from '../lib/adminData';
import RecordingCard from './RecordingCard';

type RecState = { status: 'loading' } | { status: 'error'; message: string } | { status: 'ready'; rows: RatingQueueRow[] };

/** Stored values come from the participant's own background-info screen. */
const GENDER_LABELS: Record<string, string> = {
  boy: 'Boy',
  girl: 'Girl',
  prefer_not_to_say: 'Prefers not to say',
};

export default function ParticipantsView({ profile }: { profile: ResearcherProfile }) {
  const [rows, setRows] = useState<ParticipantRow[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [expandedId, setExpandedId] = useState<string | null>(null);
  const [recordings, setRecordings] = useState<Record<string, RecState>>({});

  // Deletion is armed by typing the participant's own code, not by a generic
  // "are you sure?". The roster is a wall of near-identical BADSQ-XXXX-XXXX
  // rows; a misplaced click on a modal is exactly how the wrong session gets
  // destroyed, and there is no undo behind this button.
  const [pendingDelete, setPendingDelete] = useState<ParticipantRow | null>(null);
  const [confirmText, setConfirmText] = useState('');
  const [deleting, setDeleting] = useState(false);
  const [deleteError, setDeleteError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  const canDelete = profile.can_manage_items;
  const colCount = canDelete ? 9 : 8;

  const loadRoster = useCallback(async () => {
    try {
      setRows(await listParticipants());
      setError(null);
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    }
  }, []);

  useEffect(() => {
    // (oxlint flags this as react/set-state-in-effect; not applicable — the
    // setState calls run after an await, on mount. Same accepted pattern as
    // AuthGate.tsx's resolve().)
    void loadRoster();
  }, [loadRoster]);

  const loadRecordings = useCallback(async (participantId: string) => {
    setRecordings((prev) => ({ ...prev, [participantId]: { status: 'loading' } }));
    try {
      const data = await listRecordings({ participantId });
      setRecordings((prev) => ({ ...prev, [participantId]: { status: 'ready', rows: data } }));
    } catch (err) {
      setRecordings((prev) => ({
        ...prev,
        [participantId]: { status: 'error', message: err instanceof Error ? err.message : String(err) },
      }));
    }
  }, []);

  function toggle(p: ParticipantRow) {
    if (expandedId === p.id) {
      setExpandedId(null);
      return;
    }
    setExpandedId(p.id);
    if (!recordings[p.id] || recordings[p.id].status === 'error') void loadRecordings(p.id);
  }

  /** After a rating changes, refresh that participant's cards and the roster's pending counts. */
  const afterRatingChange = useCallback(
    async (participantId: string) => {
      await Promise.all([loadRecordings(participantId), loadRoster()]);
    },
    [loadRecordings, loadRoster],
  );

  async function confirmDelete() {
    if (!pendingDelete) return;
    const target = pendingDelete;
    setDeleting(true);
    setDeleteError(null);
    try {
      const res = await deleteParticipant(target.id);
      setNotice(
        res.audioFailed > 0
          ? `Deleted ${target.anonymizedCode}. ${res.audioDeleted} audio file(s) removed; ${res.audioFailed} could not be removed from storage and are now unreferenced.`
          : `Deleted ${target.anonymizedCode} and ${res.audioDeleted} audio file(s).`,
      );
      setPendingDelete(null);
      setConfirmText('');
      if (expandedId === target.id) setExpandedId(null);
      await loadRoster();
    } catch (err) {
      setDeleteError(err instanceof Error ? err.message : String(err));
    } finally {
      setDeleting(false);
    }
  }

  return (
    <div>
      <div className="row-between">
        <h2>Participants</h2>
      </div>

      <p className="small muted">Select a participant to play and rate their audio recordings.</p>

      {error && <div className="notice notice-error">{error}</div>}
      {notice && <div className="notice notice-ok">{notice}</div>}

      {rows === null ? (
        <p className="muted">Loading…</p>
      ) : rows.length === 0 ? (
        <p className="muted">No participants have completed a session yet.</p>
      ) : (
        <div className="table-scroll">
          <table>
            <thead>
              <tr>
                <th>Code</th>
                <th>Grade</th>
                <th>Age</th>
                <th>Gender</th>
                <th>Session status</th>
                <th>Responses</th>
                <th>Recordings</th>
                <th>Completed</th>
                {canDelete && <th>Delete</th>}
              </tr>
            </thead>
            <tbody>
              {rows.map((p) => {
                const open = expandedId === p.id;
                const rec = recordings[p.id];
                return (
                  <Fragment key={p.id}>
                    <tr
                      className={open ? 'row-clickable row-open' : 'row-clickable'}
                      onClick={() => toggle(p)}
                      aria-expanded={open}
                    >
                      <td>
                        <span className="row-caret" aria-hidden="true">
                          {open ? '▾' : '▸'}
                        </span>{' '}
                        <code>{p.anonymizedCode}</code>
                      </td>
                      <td>{p.classGrade ?? '—'}</td>
                      <td>{p.ageYears != null ? `${p.ageYears} yrs` : '—'}</td>
                      <td>{GENDER_LABELS[p.gender ?? ''] ?? p.gender ?? '—'}</td>
                      <td>
                        <span className={p.sessionStatus === 'completed' ? 'pill pill-on' : 'pill'}>
                          {p.sessionStatus ?? 'unknown'}
                        </span>
                      </td>
                      <td>{p.responseCount}</td>
                      <td>
                        {p.recordingCount === 0 ? (
                          <span className="muted">—</span>
                        ) : (
                          <>
                            {p.recordingCount}
                            {p.recordingsPending > 0 && (
                              <span className="pill rec-pending-pill">{p.recordingsPending} to review</span>
                            )}
                          </>
                        )}
                      </td>
                      <td className="small muted">{new Date(p.createdAt).toLocaleString()}</td>
                      {canDelete && (
                        <td>
                          <button
                            type="button"
                            className="danger"
                            // The row itself toggles the recordings drawer.
                            onClick={(e) => {
                              e.stopPropagation();
                              setPendingDelete(p);
                              setConfirmText('');
                              setDeleteError(null);
                              setNotice(null);
                            }}
                          >
                            Delete
                          </button>
                        </td>
                      )}
                    </tr>

                    {open && (
                      <tr className="row-detail">
                        <td colSpan={colCount}>
                          {!rec || rec.status === 'loading' ? (
                            <p className="muted small">Loading recordings…</p>
                          ) : rec.status === 'error' ? (
                            <div className="notice notice-error">{rec.message}</div>
                          ) : rec.rows.length === 0 ? (
                            <p className="muted small">
                              This participant has no audio recordings. (Only the spoken-response tasks produce
                              audio — Elision, Blending, Substitution, Spoonerisms and Jumbled-sentence Reading.)
                            </p>
                          ) : (
                            <div className="rec-list">
                              {rec.rows.map((r) => (
                                <RecordingCard
                                  key={r.audioId}
                                  row={r}
                                  canRate={profile.can_rate}
                                  raterId={profile.id}
                                  showParticipant={false}
                                  onChanged={() => afterRatingChange(p.id)}
                                />
                              ))}
                            </div>
                          )}
                        </td>
                      </tr>
                    )}

                    {canDelete && pendingDelete?.id === p.id && (
                      <tr className="row-detail">
                        <td colSpan={colCount}>
                          <div className="delete-confirm">
                            <p className="small">
                              This permanently deletes <code>{p.anonymizedCode}</code> — the participant
                              row, their session, all {p.responseCount} responses, their consent answers,
                              and all {p.recordingCount} audio recording(s) including any ratings already
                              given. <strong>There is no undo.</strong>
                            </p>
                            <p className="small muted">
                              Type <code>{p.anonymizedCode}</code> to confirm.
                            </p>
                            {deleteError && <div className="notice notice-error">{deleteError}</div>}
                            <input
                              value={confirmText}
                              autoComplete="off"
                              spellCheck={false}
                              aria-label={`Type ${p.anonymizedCode} to confirm deletion`}
                              placeholder="BADSQ-XXXX-XXXX"
                              onChange={(e) => setConfirmText(e.target.value)}
                            />
                            <button
                              type="button"
                              className="danger-armed"
                              disabled={deleting || confirmText.trim() !== p.anonymizedCode}
                              onClick={() => void confirmDelete()}
                            >
                              {deleting ? 'Deleting…' : 'Delete permanently'}
                            </button>{' '}
                            <button
                              type="button"
                              disabled={deleting}
                              onClick={() => {
                                setPendingDelete(null);
                                setConfirmText('');
                                setDeleteError(null);
                              }}
                            >
                              Cancel
                            </button>
                          </div>
                        </td>
                      </tr>
                    )}
                  </Fragment>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
