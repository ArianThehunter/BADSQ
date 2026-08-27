/**
 * HealthView — at-a-glance operational status.
 *
 * Deliberately just counts, not a dashboard library chart: this project has
 * no analytics/telemetry dependency and isn't adding one for an internal
 * five-number summary.
 */

import { useEffect, useState } from 'react';
import { getHealthSummary, type HealthSummary } from '../lib/adminData';

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
    </div>
  );
}
