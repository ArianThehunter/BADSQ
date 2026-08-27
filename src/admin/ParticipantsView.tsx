/**
 * ParticipantsView — read-only roster, identified only by anonymized_code.
 *
 * Never shows anything that could re-identify a participant (no raw session
 * auth_uid, no IP, no free-text). class_grade/age_months are the only
 * demographic fields the schema keeps at this table, and both were supplied
 * by the participant's own TestRunner session, not derived from anything
 * identifying.
 */

import { useEffect, useState } from 'react';
import { listParticipants, type ParticipantRow } from '../lib/adminData';

export default function ParticipantsView() {
  const [rows, setRows] = useState<ParticipantRow[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    listParticipants()
      .then((data) => {
        if (!cancelled) setRows(data);
      })
      .catch((err) => {
        if (!cancelled) setError(err instanceof Error ? err.message : String(err));
      });
    return () => {
      cancelled = true;
    };
  }, []);

  return (
    <div>
      <div className="row-between">
        <h2>Participants</h2>
      </div>

      {error && <div className="notice notice-error">{error}</div>}

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
                <th>Age (months)</th>
                <th>Session status</th>
                <th>Responses</th>
                <th>Completed</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((p) => (
                <tr key={p.id}>
                  <td><code>{p.anonymizedCode}</code></td>
                  <td>{p.classGrade ?? '—'}</td>
                  <td>{p.ageMonths ?? '—'}</td>
                  <td>
                    <span className={p.sessionStatus === 'completed' ? 'pill pill-on' : 'pill'}>
                      {p.sessionStatus ?? 'unknown'}
                    </span>
                  </td>
                  <td>{p.responseCount}</td>
                  <td className="small muted">{new Date(p.createdAt).toLocaleString()}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
