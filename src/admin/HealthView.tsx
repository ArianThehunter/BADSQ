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
  downloadFullExportCsv,
  downloadParticipantSummaryCsv,
  type HealthSummary,
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

  useEffect(() => {
    let cancelled = false;
    getHealthSummary()
      .then((data) => {
        if (!cancelled) setSummary(data);
      })
      .catch((err) => {
        if (!cancelled) setError(err instanceof Error ? err.message : String(err));
      });
    return () => {
      cancelled = true;
    };
  }, []);

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
