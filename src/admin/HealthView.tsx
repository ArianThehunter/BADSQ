/**
 * HealthView — at-a-glance operational status.
 *
 * Deliberately just counts, not a dashboard library chart: this project has
 * no analytics/telemetry dependency and isn't adding one for an internal
 * five-number summary.
 */

import { useEffect, useState } from 'react';
import { getHealthSummary, downloadFullExportCsv, type HealthSummary } from '../lib/adminData';

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
          : `Downloaded ${count} row(s) as CSV.`,
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
        <h3 style={{ marginTop: 0 }}>Full raw-data export</h3>
        <p className="muted small">
          Every raw column collected about every participant — one row per response, including
          background info, consent answers, latency, replay counts, and audio metadata.
          <code>is_correct</code> is intentionally NULL for every format — all scoring happens in
          your own offline analysis against the answer key already in the item bank. For
          <code> AUDIO_RECORD</code> responses specifically, the export also includes a playable
          URL to the recording and, if a researcher has rated it in the Rating Queue, that
          reference correct/incorrect judgment (a separate column, not <code>is_correct</code>).
        </p>
        <button type="button" className="primary" disabled={exporting} onClick={() => void handleExport()}>
          {exporting ? 'Preparing…' : 'Download full dataset (CSV)'}
        </button>
        {exportMessage && <p className="muted small">{exportMessage}</p>}
      </div>
    </div>
  );
}
