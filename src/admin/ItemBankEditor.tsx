/**
 * Item Bank Editor.
 *
 * Editing NEVER mutates a row a completed session answered — it writes a new
 * version and retires the old one (see src/lib/itemBank.ts). "Delete" is always
 * soft.
 *
 * The activation guard (src/lib/itemValidation.ts) is the safety-critical part:
 * an item cannot be set active while its stimulus replayability is undecided,
 * while a scored item has no answer key, or while a choice item has duplicate or
 * blank option text.
 */

import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import type { ResearcherProfile } from '../lib/supabaseClient';
import {
  listItems,
  listOptions,
  createItem,
  saveNewVersion,
  setActive,
  retireItem,
  uploadItemAudio,
  signedAudioUrl,
  bulkSetReplayability,
  type ItemRow,
} from '../lib/itemBank';
import {
  activationBlockers,
  activationWarnings,
  isChoiceFormat,
  type DraftItem,
  type DraftOption,
  type ResponseFormat,
  type ScoringMode,
} from '../lib/itemValidation';

const FORMATS: ResponseFormat[] = [
  'MCQ_TAP',
  'BINARY_TAP',
  'TRI_TAP',
  'NUMERIC_KEYPAD',
  'LIKERT_5',
  'AUDIO_RECORD',
];
const DOMAINS = ['1', '2', '3', '4', '5', 'criterion'];
const OPTION_KEYS = ['A', 'B', 'C', 'D', 'E'];

function emptyDraft(): DraftItem {
  return {
    item_code: '',
    domain: '2',
    subdomain: null,
    response_format: 'MCQ_TAP',
    scoring_mode: 'auto',
    correct_answer: null,
    stimulus_text: null,
    instruction_audio_path: null,
    stimulus_audio_path: null,
    is_instruction_replayable: true,
    is_stimulus_replayable: null,
    is_practice: false,
    is_scored: true,
    display_order: null,
    options: [
      { option_key: 'A', option_text: '', is_correct: false },
      { option_key: 'B', option_text: '', is_correct: false },
    ],
  };
}

function draftFromRow(row: ItemRow, options: DraftOption[]): DraftItem {
  return { ...row, options };
}

/** Play a private storage object via a short-lived signed URL. */
function AudioPreview({ path, label }: { path: string | null; label: string }) {
  const [url, setUrl] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    // (oxlint flags this as react/set-state-in-effect; accepted — resetting the
    // preview when `path` changes IS what this effect synchronizes: an external
    // resource (the signed URL) with a prop, not a derivable render-time value.)
    setUrl(null);
    setErr(null);
    if (!path) return;
    signedAudioUrl(path)
      .then((u) => !cancelled && setUrl(u))
      .catch((e) => !cancelled && setErr(e instanceof Error ? e.message : String(e)));
    return () => {
      cancelled = true;
    };
  }, [path]);

  if (!path) return <span className="muted small">No {label} audio uploaded.</span>;
  if (err) return <span className="error small">Could not load {label} audio: {err}</span>;
  if (!url) return <span className="muted small">Preparing {label} audio…</span>;
  return (
    <span className="audio-preview">
      <audio controls preload="none" src={url} />
      <code className="small">{path}</code>
    </span>
  );
}

function AudioField({
  label,
  kind,
  itemCode,
  path,
  onChange,
  disabled,
}: {
  label: string;
  kind: 'instruction' | 'stimulus';
  itemCode: string;
  path: string | null;
  onChange: (p: string | null) => void;
  disabled: boolean;
}) {
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const inputRef = useRef<HTMLInputElement>(null);

  async function handleFile(file: File) {
    setErr(null);
    if (!itemCode.trim()) {
      setErr('Set the item code first — it determines the storage path.');
      return;
    }
    setBusy(true);
    try {
      onChange(await uploadItemAudio(file, itemCode, kind));
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
      if (inputRef.current) inputRef.current.value = '';
    }
  }

  return (
    <div className="field">
      <span className="field-label">{label}</span>
      <div className="audio-row">
        <input
          ref={inputRef}
          type="file"
          accept="audio/*"
          disabled={disabled || busy}
          onChange={(e) => {
            const f = e.target.files?.[0];
            if (f) void handleFile(f);
          }}
        />
        {path && (
          <button type="button" onClick={() => onChange(null)} disabled={disabled}>
            Remove
          </button>
        )}
      </div>
      {busy && <span className="muted small">Uploading…</span>}
      {err && <span className="error small">{err}</span>}
      <AudioPreview path={path} label={label.toLowerCase()} />
    </div>
  );
}

export default function ItemBankEditor({ profile }: { profile: ResearcherProfile }) {
  const [items, setItems] = useState<ItemRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [domainFilter, setDomainFilter] = useState('');
  const [showRetired, setShowRetired] = useState(false);

  const [editing, setEditing] = useState<{ row: ItemRow | null; draft: DraftItem } | null>(null);
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);
  const [flash, setFlash] = useState<string | null>(null);

  const [bulkSubdomain, setBulkSubdomain] = useState('');
  const [bulkInstruction, setBulkInstruction] = useState<'' | 'true' | 'false'>('');
  const [bulkStimulus, setBulkStimulus] = useState<'' | 'true' | 'false'>('');
  const [bulkBusy, setBulkBusy] = useState(false);

  const canManage = profile.can_manage_items;

  // Subdomains present among the CURRENTLY LOADED items, i.e. within domainFilter
  // if one is set — bulk replayability only makes sense scoped to one domain,
  // since the same subdomain label could exist under a different domain.
  const subdomainsInView = useMemo(() => {
    const set = new Set(items.map((i) => i.subdomain).filter((s): s is string => !!s));
    return [...set].sort();
  }, [items]);

  const [hiddenInactiveCount, setHiddenInactiveCount] = useState(0);

  const refresh = useCallback(async () => {
    // (oxlint flags this as react/set-state-in-effect; accepted — standard
    // fetch-on-mount loading indicator. setLoading(true) runs synchronously up
    // to the first await, which is the intended immediate feedback, not a
    // cascading-render hazard.)
    setLoading(true);
    setLoadError(null);
    try {
      const rows = await listItems({ domain: domainFilter || undefined, includeRetired: showRetired });
      setItems(rows);
      // If the active-only view is empty, check whether that's because
      // everything here is a not-yet-activated draft — the checkbox below is
      // easy to miss, and "no items" reads very differently from "12 items
      // exist but are all inactive drafts".
      if (!showRetired && rows.length === 0) {
        const all = await listItems({ domain: domainFilter || undefined, includeRetired: true });
        setHiddenInactiveCount(all.length);
      } else {
        setHiddenInactiveCount(0);
      }
    } catch (e) {
      setLoadError(e instanceof Error ? e.message : String(e));
    } finally {
      setLoading(false);
    }
  }, [domainFilter, showRetired]);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  // Drop a stale subdomain selection when the domain filter changes underneath it.
  useEffect(() => {
    if (bulkSubdomain && !subdomainsInView.includes(bulkSubdomain)) setBulkSubdomain('');
  }, [subdomainsInView, bulkSubdomain]);

  const blockers = useMemo(
    () => (editing ? activationBlockers(editing.draft) : []),
    [editing],
  );
  const warnings = useMemo(
    () => (editing ? activationWarnings(editing.draft) : []),
    [editing],
  );

  function patch(p: Partial<DraftItem>) {
    setEditing((cur) => (cur ? { ...cur, draft: { ...cur.draft, ...p } } : cur));
  }

  function patchOption(idx: number, p: Partial<DraftOption>) {
    setEditing((cur) => {
      if (!cur) return cur;
      const options = cur.draft.options.map((o, i) => (i === idx ? { ...o, ...p } : o));
      return { ...cur, draft: { ...cur.draft, options } };
    });
  }

  async function openEdit(row: ItemRow) {
    setSaveError(null);
    const options = await listOptions(row.id);
    setEditing({
      row,
      draft: draftFromRow(
        row,
        options.map((o) => ({
          option_key: o.option_key,
          option_text: o.option_text,
          is_correct: o.is_correct,
        })),
      ),
    });
  }

  async function save(activate: boolean) {
    if (!editing) return;
    setSaving(true);
    setSaveError(null);
    try {
      if (editing.row) {
        const row = await saveNewVersion(editing.row, editing.draft, activate);
        setFlash(
          `Saved ${row.item_code} as version ${row.version}` +
            `${activate ? ' and activated it' : ' (inactive)'}. Version ${editing.row.version} retired — ` +
            'completed sessions still point at the version they showed.',
        );
      } else {
        const row = await createItem(editing.draft, activate);
        setFlash(`Created ${row.item_code} version 1${activate ? ' (active)' : ' (inactive)'}.`);
      }
      setEditing(null);
      await refresh();
    } catch (e) {
      setSaveError(e instanceof Error ? e.message : String(e));
    } finally {
      setSaving(false);
    }
  }

  async function toggleActive(row: ItemRow) {
    setFlash(null);
    try {
      if (row.active) {
        await retireItem(row.id);
        setFlash(`${row.item_code} v${row.version} retired (soft delete — the row is kept).`);
      } else {
        const options = await listOptions(row.id);
        const b = activationBlockers(draftFromRow(row, options));
        if (b.length > 0) {
          setFlash(null);
          setLoadError(
            `Cannot activate ${row.item_code} v${row.version}: ${b.map((x) => x.message).join(' ')}`,
          );
          return;
        }
        await setActive(row.id, true);
        setFlash(`${row.item_code} v${row.version} activated.`);
      }
      await refresh();
    } catch (e) {
      setLoadError(e instanceof Error ? e.message : String(e));
    }
  }

  async function handleBulkApply() {
    if (!domainFilter || !bulkSubdomain) return;
    const patch: { is_instruction_replayable?: boolean; is_stimulus_replayable?: boolean } = {};
    if (bulkInstruction !== '') patch.is_instruction_replayable = bulkInstruction === 'true';
    if (bulkStimulus !== '') patch.is_stimulus_replayable = bulkStimulus === 'true';
    if (Object.keys(patch).length === 0) return;

    setBulkBusy(true);
    setFlash(null);
    setLoadError(null);
    try {
      const count = await bulkSetReplayability(domainFilter, bulkSubdomain, patch);
      setFlash(
        `Updated replay settings on ${count} active item(s) in domain ${domainFilter} / ${bulkSubdomain}.`,
      );
      setBulkInstruction('');
      setBulkStimulus('');
      await refresh();
    } catch (e) {
      setLoadError(e instanceof Error ? e.message : String(e));
    } finally {
      setBulkBusy(false);
    }
  }

  /* ------------------------------------------------------------------ list */

  if (editing) {
    const d = editing.draft;
    const choice = isChoiceFormat(d.response_format);
    return (
      <section>
        <div className="row-between">
          <h2>
            {editing.row ? `Edit ${editing.row.item_code}` : 'New item'}
            {editing.row && <span className="muted small"> — saving creates version {editing.row.version + 1}</span>}
          </h2>
          <button type="button" onClick={() => setEditing(null)} disabled={saving}>
            Cancel
          </button>
        </div>

        {editing.row && (
          <div className="notice">
            Editing never overwrites version {editing.row.version}. Saving writes a new version and
            retires this one, so any completed session keeps scoring against exactly what it showed.
          </div>
        )}

        <div className="grid-2">
          <label>
            Item code
            <input value={d.item_code} onChange={(e) => patch({ item_code: e.target.value })} />
          </label>
          <label>
            Display order
            <input
              type="number"
              value={d.display_order ?? ''}
              onChange={(e) => patch({ display_order: e.target.value === '' ? null : Number(e.target.value) })}
            />
          </label>
          <label>
            Domain
            <select value={d.domain} onChange={(e) => patch({ domain: e.target.value })}>
              {DOMAINS.map((x) => (
                <option key={x} value={x}>{x}</option>
              ))}
            </select>
          </label>
          <label>
            Subdomain
            <input
              value={d.subdomain ?? ''}
              onChange={(e) => patch({ subdomain: e.target.value || null })}
              placeholder="e.g. 2.1 Elision"
            />
          </label>
          <label>
            Response format
            <select
              value={d.response_format}
              onChange={(e) => patch({ response_format: e.target.value as ResponseFormat })}
            >
              {FORMATS.map((x) => (
                <option key={x} value={x}>{x}</option>
              ))}
            </select>
          </label>
          <label>
            Scoring mode
            <select
              value={d.scoring_mode}
              onChange={(e) => patch({ scoring_mode: e.target.value as ScoringMode })}
            >
              <option value="auto">auto</option>
              <option value="human_rated">human_rated</option>
            </select>
          </label>
        </div>

        <label className="block">
          Stimulus text (optional caption — never the sole instruction)
          <textarea
            lang="bn"
            rows={2}
            value={d.stimulus_text ?? ''}
            onChange={(e) => patch({ stimulus_text: e.target.value || null })}
          />
        </label>

        <div className="grid-2">
          <AudioField
            label="Instruction"
            kind="instruction"
            itemCode={d.item_code}
            path={d.instruction_audio_path}
            onChange={(p) => patch({ instruction_audio_path: p })}
            disabled={!canManage || saving}
          />
          <AudioField
            label="Stimulus"
            kind="stimulus"
            itemCode={d.item_code}
            path={d.stimulus_audio_path}
            onChange={(p) => patch({ stimulus_audio_path: p })}
            disabled={!canManage || saving}
          />
        </div>

        <fieldset>
          <legend>Replay and scoring flags</legend>
          <label className="inline">
            <input
              type="checkbox"
              checked={d.is_instruction_replayable}
              onChange={(e) => patch({ is_instruction_replayable: e.target.checked })}
            />
            Instruction replayable
          </label>
          <label className="block">
            Stimulus replayable
            <select
              value={d.is_stimulus_replayable === null ? '' : String(d.is_stimulus_replayable)}
              onChange={(e) =>
                patch({ is_stimulus_replayable: e.target.value === '' ? null : e.target.value === 'true' })
              }
            >
              <option value="">— undecided (blocks activation) —</option>
              <option value="true">Yes — replayable</option>
              <option value="false">No — single presentation</option>
            </select>
          </label>
          <label className="inline">
            <input type="checkbox" checked={d.is_practice} onChange={(e) => patch({ is_practice: e.target.checked })} />
            Practice item
          </label>
          <label className="inline">
            <input type="checkbox" checked={d.is_scored} onChange={(e) => patch({ is_scored: e.target.checked })} />
            Scored
          </label>
        </fieldset>

        {d.response_format === 'NUMERIC_KEYPAD' && (
          <label className="block">
            Correct answer (digits)
            <input
              value={d.correct_answer ?? ''}
              onChange={(e) => patch({ correct_answer: e.target.value || null })}
              inputMode="numeric"
            />
          </label>
        )}

        {choice && (
          <fieldset>
            <legend>Options</legend>
            {d.options.map((o, i) => (
              <div className="option-row" key={o.option_key}>
                <span className="option-key">{o.option_key}</span>
                <input
                  lang="bn"
                  value={o.option_text}
                  onChange={(e) => patchOption(i, { option_text: e.target.value })}
                  placeholder="Option text (Bangla)"
                />
                <label className="inline">
                  <input
                    type="checkbox"
                    checked={o.is_correct}
                    onChange={(e) => patchOption(i, { is_correct: e.target.checked })}
                  />
                  Correct
                </label>
                <button
                  type="button"
                  onClick={() =>
                    patch({ options: d.options.filter((_, idx) => idx !== i) })
                  }
                  disabled={d.options.length <= 1}
                >
                  Remove
                </button>
              </div>
            ))}
            <button
              type="button"
              disabled={d.options.length >= OPTION_KEYS.length}
              onClick={() =>
                patch({
                  options: [
                    ...d.options,
                    { option_key: OPTION_KEYS[d.options.length], option_text: '', is_correct: false },
                  ],
                })
              }
            >
              Add option
            </button>
          </fieldset>
        )}

        {blockers.length > 0 && (
          <div className="notice notice-error" role="alert">
            <strong>Cannot be activated yet:</strong>
            <ul>
              {blockers.map((b) => (
                <li key={b.code}>{b.message}</li>
              ))}
            </ul>
            <p className="small">It can still be saved as an inactive draft.</p>
          </div>
        )}
        {warnings.length > 0 && (
          <div className="notice notice-warn">
            <strong>Worth checking:</strong>
            <ul>
              {warnings.map((w) => (
                <li key={w}>{w}</li>
              ))}
            </ul>
          </div>
        )}
        {saveError && (
          <div className="notice notice-error" role="alert">
            <strong>Save failed.</strong> {saveError}
          </div>
        )}

        <div className="actions">
          <button type="button" onClick={() => void save(false)} disabled={!canManage || saving}>
            {saving ? 'Saving…' : 'Save as inactive draft'}
          </button>
          <button
            type="button"
            className="primary"
            onClick={() => void save(true)}
            disabled={!canManage || saving || blockers.length > 0}
            title={blockers.length > 0 ? 'Resolve the blockers above first' : undefined}
          >
            {saving ? 'Saving…' : 'Save and activate'}
          </button>
        </div>
        {!canManage && (
          <p className="error small">
            Your account does not have <code>can_manage_items</code>, so saving is disabled.
          </p>
        )}
      </section>
    );
  }

  return (
    <section>
      <div className="row-between">
        <h2>Item bank</h2>
        <button
          type="button"
          className="primary"
          disabled={!canManage}
          onClick={() => {
            setSaveError(null);
            setEditing({ row: null, draft: emptyDraft() });
          }}
        >
          New item
        </button>
      </div>

      <div className="filters">
        <label className="inline">
          Domain
          <select value={domainFilter} onChange={(e) => setDomainFilter(e.target.value)}>
            <option value="">All</option>
            {DOMAINS.map((d) => (
              <option key={d} value={d}>{d}</option>
            ))}
          </select>
        </label>
        <label className="inline">
          <input type="checkbox" checked={showRetired} onChange={(e) => setShowRetired(e.target.checked)} />
          Show inactive items (new drafts &amp; retired versions)
        </label>
        <button type="button" onClick={() => void refresh()}>Refresh</button>
      </div>

      <fieldset>
        <legend>Bulk replay settings (per subdomain)</legend>
        {!domainFilter ? (
          <p className="muted small">Select a domain above to enable bulk replay editing for its subdomains.</p>
        ) : subdomainsInView.length === 0 ? (
          <p className="muted small">No active items in domain {domainFilter} carry a subdomain label.</p>
        ) : (
          <>
            <div className="grid-2">
              <label>
                Subdomain
                <select value={bulkSubdomain} onChange={(e) => setBulkSubdomain(e.target.value)}>
                  <option value="">— choose —</option>
                  {subdomainsInView.map((s) => (
                    <option key={s} value={s}>{s}</option>
                  ))}
                </select>
              </label>
              <label>
                Instruction replayable
                <select value={bulkInstruction} onChange={(e) => setBulkInstruction(e.target.value as typeof bulkInstruction)}>
                  <option value="">— no change —</option>
                  <option value="true">Yes — replayable</option>
                  <option value="false">No — single presentation</option>
                </select>
              </label>
              <label>
                Stimulus replayable
                <select value={bulkStimulus} onChange={(e) => setBulkStimulus(e.target.value as typeof bulkStimulus)}>
                  <option value="">— no change —</option>
                  <option value="true">Yes — replayable</option>
                  <option value="false">No — single presentation</option>
                </select>
              </label>
            </div>
            <button
              type="button"
              className="primary"
              disabled={!canManage || bulkBusy || !bulkSubdomain || (bulkInstruction === '' && bulkStimulus === '')}
              onClick={() => void handleBulkApply()}
            >
              {bulkBusy ? 'Applying…' : `Apply to every active item in ${bulkSubdomain || '…'}`}
            </button>
            <p className="muted small">
              Applies immediately to every active item sharing this domain and subdomain — no new
              version is created, since replay flags don't affect what a session was shown or scored.
            </p>
          </>
        )}
      </fieldset>

      {flash && <div className="notice notice-ok" role="status">{flash}</div>}
      {loadError && (
        <div className="notice notice-error" role="alert">
          {loadError}
        </div>
      )}

      {loading ? (
        <p className="muted">Loading…</p>
      ) : items.length === 0 ? (
        <p className="muted">
          {hiddenInactiveCount > 0 ? (
            <>
              No <strong>active</strong> items{domainFilter ? ` in domain ${domainFilter}` : ''} — but{' '}
              {hiddenInactiveCount} inactive item(s) exist here. Check “Show inactive items” above to see
              them.
            </>
          ) : (
            <>
              No items{domainFilter ? ` in domain ${domainFilter}` : ''} yet.
              {canManage ? ' Use “New item” to author the first one.' : ''}
            </>
          )}
        </p>
      ) : (
        <div className="table-scroll">
          <table>
            <thead>
              <tr>
                <th>Code</th>
                <th>v</th>
                <th>Domain</th>
                <th>Format</th>
                <th>Stimulus text</th>
                <th>Audio</th>
                <th>Replay</th>
                <th>Status</th>
                <th />
              </tr>
            </thead>
            <tbody>
              {items.map((it) => (
                <tr key={it.id} className={it.active ? undefined : 'retired'}>
                  <td><code>{it.item_code}</code></td>
                  <td>{it.version}</td>
                  <td>{it.domain}{it.subdomain ? ` · ${it.subdomain}` : ''}</td>
                  <td>{it.response_format}</td>
                  <td lang="bn" className="bangla-cell">{it.stimulus_text ?? <span className="muted">—</span>}</td>
                  <td className="small">
                    {it.instruction_audio_path ? 'instr' : <span className="muted">no instr</span>}
                    {it.stimulus_audio_path ? ' + stim' : ''}
                  </td>
                  <td className="small">
                    {it.is_stimulus_replayable === null
                      ? <span className="error">undecided</span>
                      : it.is_stimulus_replayable ? 'yes' : 'single'}
                  </td>
                  <td>{it.active ? <span className="pill pill-on">active</span> : <span className="pill">retired</span>}</td>
                  <td className="actions-cell">
                    <button type="button" onClick={() => void openEdit(it)}>Edit</button>
                    <button type="button" onClick={() => void toggleActive(it)} disabled={!canManage}>
                      {it.active ? 'Retire' : 'Activate'}
                    </button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </section>
  );
}
