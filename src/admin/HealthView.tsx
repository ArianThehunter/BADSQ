/**
 * HealthView — at-a-glance operational status.
 *
 * Deliberately just counts, not a dashboard library chart: this project has
 * no analytics/telemetry dependency and isn't adding one for an internal
 * five-number summary.
 */

import { useEffect, useState } from 'react';
import {
  getHealthSummary,
  getRetentionSummary,
  deleteExpiredAudio,
  downloadFullExportCsv,
  downloadParticipantSummaryCsv,
  type HealthSummary,
  type RetentionSummary,
} from '../lib/adminData';

function Stat({ label, value, warn }: { label: string; value: number; warn?: boolean }) {
  return (
    <div className={warn && value > 0 ? 'notice notice-warn' : 'notice'}>
      <div style={{ fontSize: '1.75rem', fontWeight: 700 }}>{value}</div>
      <div className="small muted">{label}</div>
    </div>
  );
}

export default function HealthView() {
  const [summary, setSummary] = useState<HealthSummary | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [exporting, setExporting] = useState(false);
  const [exportMessage, setExportMessage] = useState<string | null>(null);
  const [retention, setRetention] = useState<RetentionSummary | null>(null);
  const [purging, setPurging] = useState(false);
  const [purgeMessage, setPurgeMessage] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    getHealthSummary()
      .then((data) => {
        if (!cancelled) setSummary(data);
      })
      .catch((err) => {
        if (!cancelled) setError(err instanceof Error ? err.message : String(err));
      });
    getRetentionSummary()
      .then((data) => {
        if (!cancelled) setRetention(data);
      })
      .catch(() => {
        // Retention is supplementary; a failure here must not blank the page.
      });
    return () => {
      cancelled = true;
    };
  }, []);

  async function handlePurge() {
    setPurging(true);
    setPurgeMessage(null);
    try {
      const result = await deleteExpiredAudio();
      setPurgeMessage(
        result.deleted === 0 && result.failed === 0
          ? 'Nothing is past its deletion date.'
          : `Destroyed ${result.deleted} recording(s).` +
              (result.failed > 0 ? ` ${result.failed} could not be removed and were left marked as still stored.` : '') +
              (result.remaining > 0 ? ` ${result.remaining} still overdue — run again.` : ''),
      );
      setRetention(await getRetentionSummary());
    } catch (err) {
      setPurgeMessage(err instanceof Error ? err.message : String(err));
    } finally {
      setPurging(false);
    }
  }

  async function handleExport() {
    setExporting(true);
    setExportMessage(null);
    try {
      const count = await downloadFullExportCsv();
      setExportMessage(
        count === 0
          ? 'No responses exist yet — nothing to export.'
          : `Downloaded ${count} response row(s) as CSV.`,
      );
    } catch (err) {
      setExportMessage(err instanceof Error ? err.message : String(err));
    } finally {
      setExporting(false);
    }
  }

  async function handleSummaryExport() {
    setExporting(true);
    setExportMessage(null);
    try {
      const count = await downloadParticipantSummaryCsv();
      setExportMessage(
        count === 0
          ? 'No completed sessions yet — nothing to summarise.'
          : `Downloaded ${count} participant row(s) as CSV.`,
      );
    } catch (err) {
      setExportMessage(err instanceof Error ? err.message : String(err));
    } finally {
      setExporting(false);
    }
  }

  if (error) return <div className="notice notice-error">{error}</div>;
  if (!summary) return <p className="muted">Loading…</p>;

  return (
    <div>
      <h2>Health</h2>
      <div className="grid-2">
        <Stat label="Sessions in progress" value={summary.sessionsInProgress} />
        <Stat label="Sessions completed" value={summary.sessionsCompleted} />
        <Stat label="Recordings pending rating" value={summary.recordingsPending} />
        <Stat label="Recordings rated" value={summary.recordingsRated} />
        <Stat
          label="Active items with NO instruction or stimulus audio"
          value={summary.itemsMissingAudio}
          warn
        />
        <Stat label="Active items total" value={summary.itemsActiveTotal} />
      </div>
      {summary.itemsMissingAudio > 0 && (
        <p className="muted small">
          An active item with no audio at all will unlock immediately for a participant instead of
          waiting for playback (see PHASE_2_REPORT.md deviation 1) — this is a real screening
          instrument, so every active item should carry real audio before use with actual
          participants.
        </p>
      )}

      {retention && (
        <div
          className={retention.overdue > 0 ? 'notice notice-warn' : 'notice'}
          style={{ marginTop: '1.5rem' }}
        >
          <h3 style={{ marginTop: 0 }}>Audio retention</h3>
          <p className="muted small">
            Participant recordings are destroyed <strong>90 days after upload</strong>. The rating, the latency
            and the item linkage are kept forever — only the audio itself goes.
          </p>

          <div className="grid-2">
            <Stat label="Recordings still stored" value={retention.liveRecordings} />
            <Stat label="Past their deletion date" value={retention.overdue} warn />
            <Stat label="Due within 14 days" value={retention.dueSoon} />
            <Stat label="Audio already destroyed" value={retention.alreadyDeleted} />
          </div>

          {(retention.dueSoonUnrated > 0 || retention.dueSoonMissingSecond > 0) && (
            <div className="notice notice-warn" style={{ marginTop: '0.75rem' }}>
              <p className="small" style={{ margin: 0 }}>
                <strong>Rate these before they are deleted.</strong>{' '}
                {retention.dueSoonUnrated > 0 && (
                  <>
                    {retention.dueSoonUnrated} recording(s) due within 14 days have <strong>no verdict yet</strong>.
                  </>
                )}{' '}
                {retention.dueSoonMissingSecond > 0 && (
                  <>
                    {retention.dueSoonMissingSecond} reliability-subsample recording(s) due within 14 days are still
                    missing their <strong>second rating</strong>.
                  </>
                )}{' '}
                Once the audio is gone the verdict cannot be recovered — it is the only thing that outlives the file.
              </p>
            </div>
          )}

          <div style={{ marginTop: '0.75rem' }}>
            <button type="button" disabled={purging || retention.overdue === 0} onClick={() => void handlePurge()}>
              {purging ? 'Destroying…' : `Destroy ${retention.overdue} expired recording(s)`}
            </button>
            {purgeMessage && (
              <p className="small" style={{ marginTop: '0.5rem' }}>
                {purgeMessage}
              </p>
            )}
            <p className="muted small" style={{ marginTop: '0.5rem', marginBottom: 0 }}>
              This is a manual step, run here rather than automatically: deleting a child&apos;s voice recording is
              not something that should happen without someone choosing to do it. It removes the file through
              Storage and records when that happened. Nothing is scheduled to run on its own, so it has to be done
              — put it in the project calendar.
            </p>
          </div>
        </div>
      )}

      <div className="notice" style={{ marginTop: '1.5rem' }}>
        <h3 style={{ marginTop: 0 }}>Exports</h3>
        <p className="muted small">
          Two files over the same data at different grains. Take the response-level file for
          cleaning and modelling, the participant-level one for charts and comparing children.
        </p>

        <h4 style={{ marginBottom: '0.25rem' }}>1. Response level — one row per answer</h4>
        <p className="muted small">
          Every raw column collected about every participant, including background info, consent
          answers, latency, replay counts, and audio metadata. <code>is_correct</code> is
          intentionally NULL for every format — all scoring happens in your own offline analysis
          against the answer key in the item bank. For <code>AUDIO_RECORD</code> responses the
          export also includes a playable URL (valid 90 days; <code>audio_storage_path</code> lets
          you regenerate it afterwards) and the reviewer's verdict as{' '}
          <code>audio_review_verdict</code> — <code>correct</code>, <code>incorrect</code> or{' '}
          <code>unclear</code>.
        </p>
        <button type="button" className="primary" disabled={exporting} onClick={() => void handleExport()}>
          {exporting ? 'Preparing…' : 'Download response-level CSV'}
        </button>

        <h4 style={{ marginBottom: '0.25rem', marginTop: '1.25rem' }}>
          2. Participant level — one row per child
        </h4>
        <p className="muted small">
          Demographics, consent answers and session length, then per-subdomain summaries (items
          answered, mean latency, replays) and audio verdict tallies. Summaries per subdomain
          rather than one column per item, so the columns stay stable when the item bank changes.
          For per-item columns, pivot the response-level file instead.
        </p>
        <button type="button" disabled={exporting} onClick={() => void handleSummaryExport()}>
          {exporting ? 'Preparing…' : 'Download participant-level CSV'}
        </button>

        {exportMessage && <p className="muted small">{exportMessage}</p>}
      </div>
    </div>
  );
}
