/**
 * Item bank data access.
 *
 * The versioning rule is the important part and lives here rather than in the
 * component: editing an item NEVER mutates the row a completed session already
 * answered. It writes a NEW row with version + 1 and retires the previous one
 * (active = false). `responses.item_id` keeps pointing at the exact version the
 * student was shown, which is what makes retired versions correct rather than a
 * defect — a session must score against what it actually presented.
 *
 * "Delete" is always soft: active = false, never a DELETE.
 */

import { supabase, AUDIO_BUCKET } from './supabaseClient';
import { activationBlockers } from './itemValidation';
import type { DraftItem, DraftOption, ResponseFormat, ScoringMode } from './itemValidation';
import {
  ITEM_AUDIO_BUCKET,
  uploadItemAudio as sharedUploadItemAudio,
  signedItemAudioUrl,
} from './media';

export { ITEM_AUDIO_BUCKET, AUDIO_BUCKET };

export type ItemRow = {
  id: string;
  item_code: string;
  version: number;
  domain: string;
  subdomain: string | null;
  response_format: ResponseFormat;
  scoring_mode: ScoringMode;
  correct_answer: string | null;
  stimulus_text: string | null;
  instruction_audio_path: string | null;
  stimulus_audio_path: string | null;
  is_instruction_replayable: boolean;
  is_stimulus_replayable: boolean | null;
  is_practice: boolean;
  is_scored: boolean;
  display_order: number | null;
  active: boolean;
  created_at: string;
};

export type OptionRow = DraftOption & { id: string; item_id: string };

// NOTE: this must be ONE string literal, not built with `+`. The `+` operator
// widens even literal operands to `string`, which defeats supabase-js's
// compile-time parsing of the select list and silently falls back to an
// untyped `GenericStringError` result — caught here, not worth re-discovering.
const ITEM_COLUMNS =
  'id, item_code, version, domain, subdomain, response_format, scoring_mode, correct_answer, stimulus_text, instruction_audio_path, stimulus_audio_path, is_instruction_replayable, is_stimulus_replayable, is_practice, is_scored, display_order, active, created_at';

function fail(context: string, error: { message: string; code?: string } | null): never {
  throw new Error(`${context}: ${error?.code ? `${error.code} ` : ''}${error?.message ?? 'unknown error'}`);
}

/** All items, newest version of each code first. Researchers only (RLS). */
export async function listItems(opts?: { domain?: string; includeRetired?: boolean }): Promise<ItemRow[]> {
  let q = supabase.from('items').select(ITEM_COLUMNS);
  if (opts?.domain) q = q.eq('domain', opts.domain);
  if (!opts?.includeRetired) q = q.eq('active', true);

  const { data, error } = await q
    .order('display_order', { ascending: true, nullsFirst: false })
    .order('item_code', { ascending: true })
    .order('version', { ascending: false });

  if (error) fail('Could not load items', error);
  return (data ?? []) as ItemRow[];
}

export async function listOptions(itemId: string): Promise<OptionRow[]> {
  const { data, error } = await supabase
    .from('item_options')
    .select('id, item_id, option_key, option_text, is_correct')
    .eq('item_id', itemId)
    .order('option_key', { ascending: true });
  if (error) fail('Could not load options', error);
  return (data ?? []) as OptionRow[];
}

/** Distinct domains present, for the filter control. */
export async function listDomains(): Promise<string[]> {
  const { data, error } = await supabase.from('items').select('domain');
  if (error) fail('Could not load domains', error);
  return [...new Set((data ?? []).map((r) => (r as { domain: string }).domain))].sort();
}

/**
 * Payload shape for the `save_item_version` RPC (migration 0006). `version` is
 * never included — the server computes it (1 for a brand-new item_code, or
 * previous+1 when superseding), which is what makes the write race-free: the
 * client never has to read-then-write a version number.
 */
function rpcItemPayload(draft: DraftItem, active: boolean) {
  return {
    item_code: draft.item_code.trim(),
    domain: draft.domain.trim(),
    subdomain: draft.subdomain?.trim() || null,
    response_format: draft.response_format,
    scoring_mode: draft.scoring_mode,
    correct_answer: draft.correct_answer?.trim() || null,
    stimulus_text: draft.stimulus_text?.trim() || null,
    instruction_audio_path: draft.instruction_audio_path || null,
    stimulus_audio_path: draft.stimulus_audio_path || null,
    is_instruction_replayable: draft.is_instruction_replayable,
    is_stimulus_replayable: draft.is_stimulus_replayable,
    is_practice: draft.is_practice,
    is_scored: draft.is_scored,
    display_order: draft.display_order,
    active,
  };
}

function rpcOptionsPayload(options: DraftOption[]) {
  return options.map((o) => ({
    option_key: o.option_key.trim(),
    option_text: o.option_text,
    is_correct: o.is_correct,
  }));
}

async function fetchItemById(id: string): Promise<ItemRow> {
  const { data, error } = await supabase.from('items').select(ITEM_COLUMNS).eq('id', id).single();
  if (error) fail('Item was saved but could not be re-read', error);
  return data as ItemRow;
}

/** Highest version currently recorded for an item_code, or 0 if none. */
export async function highestVersion(itemCode: string): Promise<number> {
  const { data, error } = await supabase
    .from('items')
    .select('version')
    .eq('item_code', itemCode.trim())
    .order('version', { ascending: false })
    .limit(1);
  if (error) fail('Could not read current version', error);
  return data && data.length > 0 ? (data[0] as { version: number }).version : 0;
}

/**
 * Create version 1 of a brand-new item code, via the `save_item_version` RPC
 * (migration 0006) — atomic: the item row and every option are written in one
 * transaction, so a failure partway through never leaves an orphaned,
 * option-less item behind.
 */
export async function createItem(draft: DraftItem, active: boolean): Promise<ItemRow> {
  const existing = await highestVersion(draft.item_code);
  if (existing > 0) {
    throw new Error(
      `Item code "${draft.item_code}" already exists (highest version ${existing}). ` +
        'Edit that item instead — editing creates the next version.',
    );
  }
  const { data: newId, error } = await supabase.rpc('save_item_version', {
    p_old_item_id: null,
    p_item: rpcItemPayload(draft, active),
    p_options: rpcOptionsPayload(draft.options),
  });
  if (error) fail('Could not create item', error);
  return fetchItemById(newId as string);
}

/**
 * Save an edit as a NEW version, retiring the previous row — via the atomic
 * `save_item_version` RPC. Options are fully replaced for the new version, not
 * merged with the previous version's, matching the RPC's contract.
 */
export async function saveNewVersion(
  previous: ItemRow,
  draft: DraftItem,
  active: boolean,
): Promise<ItemRow> {
  const { data: newId, error } = await supabase.rpc('save_item_version', {
    p_old_item_id: previous.id,
    p_item: rpcItemPayload(draft, active),
    p_options: rpcOptionsPayload(draft.options),
  });
  if (error) fail('Could not save the new version', error);
  return fetchItemById(newId as string);
}

/** Soft delete. Never a hard DELETE — completed sessions reference this row. */
export async function retireItem(itemId: string): Promise<void> {
  const { error } = await supabase.from('items').update({ active: false }).eq('id', itemId);
  if (error) fail('Could not retire item', error);
}

export async function setActive(itemId: string, active: boolean): Promise<void> {
  const { error } = await supabase.from('items').update({ active }).eq('id', itemId);
  if (error) fail(active ? 'Could not activate item' : 'Could not deactivate item', error);
}

/* ------------------------------------------------------------------ audio */

/**
 * Upload item audio and return its storage OBJECT PATH (not a URL).
 *
 * `items.instruction_audio_path` / `stimulus_audio_path` store the path; the
 * bucket is private, so playback needs a short-lived signed URL. Item audio
 * reveals test content, which is why the bucket is not public.
 *
 * Thin re-export of src/lib/media.ts, which TestRunner also uses (participants
 * read the SAME item audio via the SAME signed-URL mechanism). Kept here too so
 * existing imports in ItemBankEditor.tsx do not need to change.
 */
export const uploadItemAudio = sharedUploadItemAudio;

/** Short-lived signed URL so a researcher can hear what they uploaded. */
export const signedAudioUrl = signedItemAudioUrl;

/* ------------------------------------------------- standing quality checks */

export type QualityFinding = { item_code: string; version: number; issue: string };

/**
 * The design doc section 6 checks, run across the whole live bank rather than
 * one item at a time — the per-item guard only fires when someone opens that
 * item, and these were originally found by a sweep.
 */
export async function itemBankQualitySweep(): Promise<QualityFinding[]> {
  const items = await listItems({ includeRetired: false });
  const findings: QualityFinding[] = [];

  for (const item of items) {
    const options = await listOptions(item.id);
    const blockers = activationBlockers({
      ...item,
      options: options.map((o) => ({
        option_key: o.option_key,
        option_text: o.option_text,
        is_correct: o.is_correct,
      })),
    });
    for (const b of blockers) {
      findings.push({ item_code: item.item_code, version: item.version, issue: b.message });
    }
  }
  return findings;
}
