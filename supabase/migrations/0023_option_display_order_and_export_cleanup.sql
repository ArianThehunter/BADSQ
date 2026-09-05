-- 0023: deterministic, semantically-correct option order + export cleanup.
--
-- BUG THIS FIXES (live, participant-facing):
-- TestRunner sorted every item's options by `option_key.localeCompare`. That
-- was correct while keys were A/B/C/D/E — the letters encoded the intended
-- order. Migration 0014 replaced them with semantic English tokens
-- ('never', 'sometimes', 'yes', ...) for ML readability, and silently broke
-- the ordering that sort depended on: keys now sort ALPHABETICALLY BY ENGLISH
-- WORD, which scrambles every ordered scale.
--
--   3.2 Likert-5 was rendering  always, frequently, hardly, never, sometimes
--             i.e. সবসময় → প্রায়ই → খুব কম → কখনো না → মাঝে মাঝে
--   SR tri-tap was rendering    little, no, yes      (should be yes/little/no)
--   3.1 binary was rendering    no, yes              (instruction says হ্যাঁ first)
--
-- TestRunner's comment already said TRI_TAP/LIKERT_5 must not be reordered
-- because "the position IS the meaning" — the shuffle exclusion honoured that,
-- but the sort above it did not. option_key can no longer carry order, so
-- order gets its own column.
--
-- Also: the option shuffle for MCQ_TAP/BINARY_TAP/FLASH_JUDGMENT is removed in
-- the accompanying client change, on the researcher's instruction. Rationale
-- recorded here because it is a real methodological trade: shuffling removed
-- position bias, but it also injected variance into response latency that was
-- never recorded anywhere (presented order is not stored), making it
-- unmodellable downstream. The 4.1 answer key was deliberately rebalanced to
-- A:2/B:2/C:3/D:3 in migration 0016, so a fixed order no longer concentrates
-- the correct answer in one position.

-- ---- 1. option display order -------------------------------------------
alter table item_options add column if not exists display_order smallint;

comment on column item_options.display_order is
  'Presentation order within an item, 1-based. Authoritative: option_key no longer encodes order (see migration 0014).';

-- Backfill. Letters keep their positions; semantic tokens get the order the
-- instrument intends. 9 = "always last" so a single map serves both
-- yes/no (binary) and yes/little/no (tri-tap) without conflicting.
update item_options set display_order = case option_key
  when 'A' then 1  when 'B' then 2  when 'C' then 3  when 'D' then 4  when 'E' then 5
  when 'correct' then 1    when 'wrong' then 9
  when 'match' then 1      when 'no_match' then 9
  when 'yes' then 1        when 'little' then 2      when 'no' then 9
  when 'never' then 1      when 'hardly' then 2      when 'sometimes' then 3
  when 'frequently' then 4 when 'always' then 5
end
where display_order is null;

-- ---- 2. keep it populated for options authored in the Item Bank Editor --
-- The editor sends options as a JSON array in the order shown on screen, so
-- array position IS the researcher's intended order. Previously the loop
-- discarded it; WITH ORDINALITY preserves it.
create or replace function public.save_item_version(p_old_item_id uuid, p_item jsonb, p_options jsonb)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_old_item     items%rowtype;
  v_new_item_id  uuid;
  v_item_code    text;
  v_new_version  int;
  v_option       jsonb;
  v_ord          int;
begin
  if not can_manage_items() then
    raise exception 'save_item_version: caller lacks item-management permission';
  end if;

  if p_old_item_id is not null then
    select * into v_old_item from items where id = p_old_item_id;
    if not found then
      raise exception 'save_item_version: unknown item_id %', p_old_item_id;
    end if;
    v_item_code   := v_old_item.item_code;
    v_new_version := v_old_item.version + 1;
  else
    v_item_code   := p_item->>'item_code';
    v_new_version := 1;
  end if;

  insert into items (
    item_code, version, domain, subdomain, response_format,
    instruction_audio_path, stimulus_audio_path, stimulus_text,
    is_instruction_replayable, is_stimulus_replayable,
    correct_answer, scoring_mode, is_practice, is_scored, display_order,
    active, edited_by
  ) values (
    v_item_code, v_new_version,
    p_item->>'domain', p_item->>'subdomain', p_item->>'response_format',
    p_item->>'instruction_audio_path', p_item->>'stimulus_audio_path', p_item->>'stimulus_text',
    coalesce((p_item->>'is_instruction_replayable')::boolean, true),
    (p_item->>'is_stimulus_replayable')::boolean,
    p_item->>'correct_answer',
    p_item->>'scoring_mode',
    coalesce((p_item->>'is_practice')::boolean, false),
    coalesce((p_item->>'is_scored')::boolean, true),
    (p_item->>'display_order')::int,
    coalesce((p_item->>'active')::boolean, false),
    (select id from researchers where user_id = auth.uid())
  )
  returning id into v_new_item_id;

  for v_option, v_ord in
    select value, ordinality from jsonb_array_elements(p_options) with ordinality
  loop
    insert into item_options (item_id, option_key, option_text, is_correct, display_order)
    values (
      v_new_item_id,
      v_option->>'option_key',
      v_option->>'option_text',
      coalesce((v_option->>'is_correct')::boolean, false),
      v_ord
    );
  end loop;

  if p_old_item_id is not null then
    update items set active = false where id = p_old_item_id;
  end if;

  return v_new_item_id;
end;
$function$;

-- ---- 3. expose the order to the participant client ---------------------
-- security_invoker restated explicitly: CREATE OR REPLACE must not silently
-- drop the setting this view was created with.
create or replace view public_item_options with (security_invoker = off) as
select io.id, io.item_id, io.option_key, io.option_text, io.display_order
from item_options io
  join items i on i.id = io.item_id
where i.active = true;

-- ---- 4. drop the three permanently-empty export columns ----------------
-- is_correct / scored_by: fossils of the server-side auto-scoring removed in
-- migrations 0010 and 0012 — NULL on all 231 rows and by design forever.
-- age_months: superseded by age_years (migration 0011); never written since.
-- Dropped now, while the dataset is still 5 pilot participants, because
-- changing export shape mid-collection is what actually costs.
drop view if exists full_export_v1;
create view full_export_v1 with (security_invoker = true) as
select r.id as response_id,
  p.anonymized_code, p.class_grade, p.age_years, p.gender, p.home_area,
  cr.q1_doctor_eval, cr.q1_school_eval, cr.q1_not_sure,
  cr.q2_extra_primary_support, cr.q3_family_history,
  i.item_code, i.domain, i.subdomain, i.response_format, i.scoring_mode,
  r.selected_option_key, r.typed_value,
  ar.storage_path as audio_storage_path,
  ar.mime_type as audio_mime_type,
  ar.duration_ms as audio_duration_ms,
  ar.notes as audio_notes,
  ar.primary_rating as audio_marked_correct,
  ar.primary_verdict as audio_review_verdict,
  ar.is_reliability_subsample,
  r.stimulus_first_end_client_ts, r.stimulus_last_end_client_ts, r.response_client_ts,
  r.response_latency_from_first_ms, r.response_latency_from_last_ms,
  r.input_modality, r.viewport_width, r.viewport_height,
  r.replay_count_instruction, r.replay_count_stimulus,
  r.technical_retry_count, r.selection_change_count,
  r.attempt_number, r.is_superseded,
  s.id as session_id, s.started_at as session_started_at, s.ended_at as session_ended_at,
  r.submitted_at
from responses r
  join sessions s on s.id = r.session_id
  join participants p on p.id = s.participant_id
  join items i on i.id = r.item_id
  left join audio_recordings ar on ar.response_id = r.id
  left join consent_records cr on cr.participant_id = p.id
where r.is_superseded = false;
