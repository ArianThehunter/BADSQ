/**
 * RecordingCard — one participant audio recording, with everything a reviewer
 * needs to judge it and nothing else.
 *
 * Shared by the Rating Queue (all outstanding work, across participants) and
 * the Participants tab (one participant's recordings). Previously this was a
 * seven-column table in RatingQueue.tsx; a card reads far better for work that
 * is "look at one thing, listen, decide" rather than "scan a list".
 *
 * WORDING NOTE: the underlying column is `is_reliability_subsample`, which is
 * accurate but opaque to anyone who hasn't read the methods section. The label
 * here says what it actually does — get a second researcher to rate the same
 * recording — since that is the decision the reviewer is being asked to make.
 * See setReliabilitySubsample()'s doc comment: the 20% baseline is assigned
 * randomly at submission time and should normally be left alone.
 */

import { useState } from 'react';
import {
  signedRatingAudioUrl,
  submitAudioVerdict,
  saveRecordingNotes,
  setReliabilitySubsample,
  type AudioVerdict,
  type RatingQueueRow,
} from '../lib/adminData';

const VERDICTS: { value: AudioVerdict; label: string; className: string }[] = [
  { value: 'correct', label: '✓ Correct', className: 'selected-yes' },
  { value: 'incorrect', label: '✗ Incorrect', className: 'selected-no' },
  { value: 'unclear', label: '? Unclear', className: 'selected-unclear' },
];

const VERDICT_WORD: Record<AudioVerdict, string> = {
  correct: 'correct',
  incorrect: 'incorrect',
  unclear: 'unclear',
};

function secondsLabel(durationMs: number | null): string | null {
  if (durationMs == null) return null;
  return `${Math.round(durationMs / 100) / 10}s`;
}

export default function RecordingCard({
  row,
  canRate,
  raterId,
  onChanged,
  showParticipant = true,
}: {
  row: RatingQueueRow;
  canRate: boolean;
  raterId: string;
  onChanged: () => void | Promise<void>;
  showParticipant?: boolean;
}) {
  const [audioUrl, setAudioUrl] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [noteOpen, setNoteOpen] = useState(false);
  const [noteDraft, setNoteDraft] = useState(row.notes ?? '');

  async function run(action: () => Promise<void>) {
    setBusy(true);
    setError(null);
    try {
      await action();
      await onChanged();
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setBusy(false);
    }
  }

  // One click to hear it: fetch the signed URL and start playing, rather than
  // "load" and then a second click on the player's own play button.
  async function loadAndPlay() {
    setError(null);
    try {
      setAudioUrl(await signedRatingAudioUrl(row.storagePath));
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    }
  }

  const rated = row.verdict != null;
  const duration = secondsLabel(row.durationMs);

  return (
    <div className={rated ? 'rec-card rated' : 'rec-card'}>
      <div className="rec-head">
        <div>
          <code className="rec-item-code">{row.itemCode}</code>
          {row.subdomain && <span className="pill rec-subdomain">{row.subdomain}</span>}
        </div>
        {showParticipant && (
          <div className="small muted">
            <code>{row.anonymizedCode ?? '(no code)'}</code>
            {row.classGrade != null && <> · grade {row.classGrade}</>}
          </div>
        )}
      </div>

      {row.stimulusText && (
        <p className="rec-stimulus bangla-cell" lang="bn">
          {row.stimulusText}
        </p>
      )}

      {row.correctAnswer && (
        <p className="small rec-expected">
          Expected answer: <code lang="bn">{row.correctAnswer}</code>
        </p>
      )}

      <div className="rec-audio">
        {audioUrl ? (
          <audio controls autoPlay src={audioUrl} />
        ) : (
          <button type="button" onClick={() => void loadAndPlay()}>
            ▶ Play recording
          </button>
        )}
        {duration && <span className="small muted">{duration}</span>}
      </div>

      {canRate ? (
        <>
          <div className="rec-rate">
            <span className="small rec-rate-label">Was the spoken answer correct?</span>
            <div className="rec-rate-buttons">
              {VERDICTS.map((v) => (
                <button
                  key={v.value}
                  type="button"
                  className={row.verdict === v.value ? `choice ${v.className}` : 'choice'}
                  aria-pressed={row.verdict === v.value}
                  disabled={busy}
                  onClick={() => void run(() => submitAudioVerdict(row.audioId, v.value, raterId))}
                >
                  {v.label}
                </button>
              ))}
              <span className="small muted rec-rate-state">
                {rated
                  ? `Saved as ${VERDICT_WORD[row.verdict!]} — click any option to change it`
                  : 'Not yet reviewed'}
              </span>
            </div>
            {row.verdict === 'unclear' && (
              <p className="small muted" style={{ margin: 0 }}>
                Exported as <code>unclear</code> — distinct from "not yet reviewed", so it can be excluded from
                analysis rather than mistaken for outstanding work.
              </p>
            )}
          </div>

          <div className="rec-extras">
            <label className="inline small" title="A random 20% of recordings are flagged automatically at submission so a second researcher can rate the same audio independently — that is what lets you measure how much two raters agree. You normally do not need to change this.">
              <input
                type="checkbox"
                checked={row.isReliabilitySubsample}
                disabled={busy}
                onChange={() => void run(() => setReliabilitySubsample(row.audioId, !row.isReliabilitySubsample))}
              />{' '}
              Have a second researcher also rate this
            </label>

            {!noteOpen && !row.notes && (
              <button type="button" className="link-button small" onClick={() => setNoteOpen(true)}>
                ＋ Add note
              </button>
            )}
          </div>

          {(noteOpen || row.notes) && (
            <div className="rec-note">
              <textarea
                rows={2}
                className="small"
                placeholder="Optional note (e.g. unclear audio, background noise)…"
                value={noteDraft}
                disabled={busy}
                onChange={(e) => setNoteDraft(e.target.value)}
              />
              <button
                type="button"
                disabled={busy}
                onClick={() => void run(() => saveRecordingNotes(row.audioId, noteDraft, raterId))}
              >
                Save note
              </button>
            </div>
          )}
        </>
      ) : (
        <p className="small muted">
          {rated ? `Reviewed as ${VERDICT_WORD[row.verdict!]}.` : 'Not yet reviewed.'} Your account cannot rate
          recordings.
        </p>
      )}

      {error && <p className="error small">{error}</p>}
    </div>
  );
}
