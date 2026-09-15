-- 0025: make the exports self-sufficient for analysis, close two timing
-- integrity gaps, and remove dead schema.
--
-- Driven by a real three-device pilot (Android/Chrome, iPhone/Safari, PC/Edge,
-- 77 responses each) and by reading the two exported CSVs as an analyst would.
--
-- ============================================================================
-- 1. responses.client_time_origin_ms — makes client timestamps interpretable
-- ============================================================================
-- stimulus_*_client_ts and response_client_ts come from performance.now(),
-- which is measured from PAGE LOAD, not from session start. A participant who
-- reloads mid-test (which resume explicitly supports) restarts that clock at
-- zero, so the second half of their session carries SMALLER timestamps than the
-- first half.
--
-- This is observable in the pilot data: BADSQ-VNSX-PT8W ran 1455 wall-clock
-- seconds but its largest response_client_ts is 750 s, because the clock reset
-- between items 2.3.2 and 2.4.1. Anyone ordering events by these columns, or
-- deriving "time elapsed into the session", gets nonsense for that participant
-- and has no way to tell it happened.
--
-- The individual LATENCIES are unaffected -- they are within-item deltas
-- computed inside one page load, and remain the authoritative measure.
--
-- Recording performance.timeOrigin (wall-clock ms at page load) alongside them
-- fixes both problems at once:
--   absolute wall time of an event = client_time_origin_ms + <client_ts>
--   a reload is visible as a change of client_time_origin_ms within a session.
alter table responses add column if not exists client_time_origin_ms double precision;

comment on column responses.client_time_origin_ms is
  'performance.timeOrigin at page load (wall-clock ms). Add to any *_client_ts '
  'to get absolute time. A change of this value within one session means the '
  'participant reloaded and the performance.now() clock restarted.';

-- ============================================================================
-- 2. consent_records: one row per participant
-- ============================================================================
-- Both export views LEFT JOIN consent_records on participant_id. Nothing
-- prevented a second row for the same participant (the child's own answers are
-- written at submit; a researcher transcribing the paper form later would add
-- another), and a second row would silently DOUBLE every response row for that
-- participant in both exports -- with no error anywhere.
--
-- Partial, because participant_id is deliberately nullable: a researcher may
-- key a transcribed form by assigned_code before the session is submitted.
create unique index if not exists consent_records_one_per_participant
  on consent_records(participant_id)
  where participant_id is not null;

-- ============================================================================
-- 3. Indexes for the foreign keys the exports actually join on
-- ============================================================================
create index if not exists idx_sessions_participant_id on sessions(participant_id);
create index if not exists idx_consent_records_participant_id on consent_records(participant_id);
create index if not exists idx_audio_recordings_primary_rater on audio_recordings(primary_rater_id);
create index if not exists idx_audio_recordings_secondary_rater on audio_recordings(secondary_rater_id);
create index if not exists idx_items_edited_by on items(edited_by);

-- ============================================================================
-- 4. item_options: one permissive SELECT policy, not two
-- ============================================================================
-- `item_options_write_manager` was FOR ALL, so it also granted SELECT and both
-- policies were evaluated on every read. Narrowing it to the write commands
-- leaves exactly one SELECT policy and changes nobody's access: every
-- can_manage_items() holder is also is_researcher().
drop policy if exists item_options_write_manager on item_options;

create policy item_options_insert_manager on item_options
  for insert to authenticated with check (can_manage_items());
create policy item_options_update_manager on item_options
  for update to authenticated using (can_manage_items()) with check (can_manage_items());
create policy item_options_delete_manager on item_options
  for delete to authenticated using (can_manage_items());

-- ============================================================================
-- 5. Drop dead schema
-- ============================================================================
-- ml_export_v1 (0001) was superseded by full_export_v1 (0011): fewer columns,
-- no audio, no consent, no dual latency anchors. ml_snapshots was its manual
-- point-in-time copy. Neither is referenced by any application code -- they
-- appear only in the generated database types. Keeping a second, staler export
-- view invites someone to analyse the wrong one.
drop view if exists ml_export_v1;
drop table if exists ml_snapshots;

-- ============================================================================
-- 6. full_export_v1 — rebuilt so the CSV can be analysed on its own
-- ============================================================================
-- What was missing, and why each addition matters:
--
--   * THE ANSWER KEY. The export carried what the child chose and never what
--     was correct, so nothing in it could be scored without going back to the
--     database. The key exists for every item that has a determinate answer --
--     it is just stored in two places depending on format: items.correct_answer
--     for typed and spoken items, item_options.is_correct for the choice
--     formats. Both are surfaced here.
--
--   * THE OPTION TEXT. selected_option_key is a semantic token for most formats
--     ('yes', 'match', 'frequently'), but subdomains 2.5 and 4.1 use bare
--     A/B/C/D. Those 13 items' responses were literally uninterpretable from the
--     CSV -- you could not tell what 'B' was.
--
--   * is_scored, so analysis-excluded items are filterable without a join.
--
--   * client_time_origin_ms, per section 1.
--
-- security_invoker stays ON. Without it the view runs as its creator and every
-- authenticated session -- including a participant's own anonymous one -- can
-- read every participant's data. This is load-bearing, not stylistic.
drop view if exists full_export_v1;

create view full_export_v1
with (security_invoker = true) as
select
  r.id                                as response_id,
  p.anonymized_code,
  p.class_grade,
  p.age_years,
  p.gender,
  p.home_area,
  cr.q1_doctor_eval,
  cr.q1_school_eval,
  cr.q1_not_sure,
  cr.q2_extra_primary_support,
  cr.q3_family_history,

  i.item_code,
  i.domain,
  i.subdomain,
  i.response_format,
  i.scoring_mode,
  i.is_scored,

  -- what the participant did
  r.selected_option_key,
  so.option_text                      as selected_option_text,
  r.typed_value,

  -- what the key says (never applied to the response by this platform)
  i.correct_answer,
  co.option_key                       as correct_option_key,
  co.option_text                      as correct_option_text,

  -- researcher judgement, audio items only
  ar.storage_path                     as audio_storage_path,
  ar.mime_type                        as audio_mime_type,
  ar.duration_ms                      as audio_duration_ms,
  ar.notes                            as audio_notes,
  ar.primary_rating                   as audio_marked_correct,
  ar.primary_verdict                  as audio_review_verdict,
  ar.is_reliability_subsample,

  -- timing
  r.client_time_origin_ms,
  r.stimulus_first_end_client_ts,
  r.stimulus_last_end_client_ts,
  r.response_client_ts,
  r.response_latency_from_first_ms,
  r.response_latency_from_last_ms,

  -- context
  r.input_modality,
  r.viewport_width,
  r.viewport_height,
  r.replay_count_instruction,
  r.replay_count_stimulus,
  r.technical_retry_count,
  r.selection_change_count,
  r.attempt_number,
  r.is_superseded,

  s.id                                as session_id,
  s.started_at                        as session_started_at,
  s.ended_at                          as session_ended_at,
  r.submitted_at
from responses r
  join sessions s      on s.id = r.session_id
  join participants p  on p.id = s.participant_id
  join items i         on i.id = r.item_id
  left join audio_recordings ar on ar.response_id = r.id
  left join consent_records cr  on cr.participant_id = p.id
  -- the option the participant selected, for its human-readable text
  left join item_options so on so.item_id = i.id and so.option_key = r.selected_option_key
  -- the option flagged correct, for the choice formats
  left join item_options co on co.item_id = i.id and co.is_correct
where r.is_superseded = false;

grant select on full_export_v1 to authenticated;

comment on view full_export_v1 is
  'One row per response, self-sufficient for analysis: participant background, '
  'consent answers, item metadata, the participant response, the answer key, '
  'the human audio verdict, both latency anchors, and device context. '
  'Nothing here is scored by the platform -- is_correct/scored_by are '
  'deliberately absent because they are always NULL (migration 0012).';


-- ============================================================================
-- 7. submit_session(): persist the two response fields that were being dropped
-- ============================================================================
-- MINIMAL DIFF against the live 0012 definition. Everything else -- the uuid
-- return, the age_months/school_id passthrough, the `?` test on
-- audio_storage_path, the no-scoring rule -- is reproduced verbatim on purpose.
--
-- Two additions:
--   client_time_origin_ms  -- new, see section 1.
--   selection_change_count -- the column has existed since migration 0007 and
--     was NEVER written here, so it exported as a constant 0 for every response
--     ever collected: a column that looks like data and is not. The client now
--     counts real answer changes; this stores them.
create or replace function submit_session(
  p_session_id  uuid,
  p_participant jsonb,
  p_responses   jsonb,
  p_consent     jsonb default null
) returns uuid
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_participant_id uuid;
  v_assigned_code  text;
  v_response       jsonb;
  v_response_id    uuid;
  v_item           items%rowtype;
begin
  select assigned_code into v_assigned_code
  from sessions
  where id = p_session_id
    and auth_uid = auth.uid()
    and status = 'in_progress';

  if v_assigned_code is null then
    raise exception 'Session not found, not owned by caller, or already submitted';
  end if;

  insert into participants (
    anonymized_code, class_grade, age_months, school_id, created_by_auth_uid,
    age_years, gender, home_area
  )
  values (
    v_assigned_code,
    (p_participant->>'class_grade')::smallint,
    nullif(p_participant->>'age_months', '')::int,
    nullif(p_participant->>'school_id', '')::uuid,
    auth.uid(),
    nullif(p_participant->>'age_years', '')::smallint,
    nullif(p_participant->>'gender', ''),
    nullif(p_participant->>'home_area', '')
  )
  returning id into v_participant_id;

  if p_consent is not null then
    insert into consent_records (
      participant_id, assigned_code, consent_given, consent_date,
      q1_doctor_eval, q1_school_eval, q1_not_sure,
      q2_extra_primary_support, q3_family_history
    ) values (
      v_participant_id, v_assigned_code, true, current_date,
      (p_consent->>'q1_doctor_eval')::boolean,
      (p_consent->>'q1_school_eval')::boolean,
      (p_consent->>'q1_not_sure')::boolean,
      p_consent->>'q2_extra_primary_support',
      p_consent->>'q3_family_history'
    );
  end if;

  for v_response in select * from jsonb_array_elements(p_responses)
  loop
    select * into v_item from items where id = (v_response->>'item_id')::uuid;
    if not found then
      raise exception 'Unknown item_id: %', v_response->>'item_id';
    end if;

    -- CHANGED IN 0012: no scoring here for any format.
    -- is_correct/scored_by are always NULL at insert time.
    insert into responses (
      session_id, item_id, attempt_number, is_superseded,
      client_time_origin_ms,
      stimulus_first_end_client_ts, stimulus_last_end_client_ts, response_client_ts,
      response_latency_from_first_ms, response_latency_from_last_ms,
      input_modality, viewport_width, viewport_height,
      selected_option_key, typed_value,
      is_correct, scored_by,
      replay_count_instruction, replay_count_stimulus, technical_retry_count,
      selection_change_count,
      raw_client_event_log
    ) values (
      p_session_id,
      (v_response->>'item_id')::uuid,
      coalesce((v_response->>'attempt_number')::smallint, 1),
      coalesce((v_response->>'is_superseded')::boolean, false),
      (v_response->>'client_time_origin_ms')::double precision,
      (v_response->>'stimulus_first_end_client_ts')::double precision,
      (v_response->>'stimulus_last_end_client_ts')::double precision,
      (v_response->>'response_client_ts')::double precision,
      (v_response->>'response_latency_from_first_ms')::double precision,
      (v_response->>'response_latency_from_last_ms')::double precision,
      v_response->>'input_modality',
      (v_response->>'viewport_width')::int,
      (v_response->>'viewport_height')::int,
      v_response->>'selected_option_key',
      v_response->>'typed_value',
      null,
      null,
      (v_response->>'replay_count_instruction')::int,
      (v_response->>'replay_count_stimulus')::int,
      coalesce((v_response->>'technical_retry_count')::int, 0),
      coalesce((v_response->>'selection_change_count')::int, 0),
      v_response->'raw_client_event_log'
    )
    returning id into v_response_id;

    if v_response ? 'audio_storage_path' then
      insert into audio_recordings (
        response_id, storage_path, mime_type, duration_ms, file_size_bytes,
        is_reliability_subsample
      )
      values (
        v_response_id,
        v_response->>'audio_storage_path',
        v_response->>'audio_mime_type',
        (v_response->>'audio_duration_ms')::int,
        (v_response->>'audio_file_size_bytes')::bigint,
        (random() < reliability_subsample_rate())
      );
    end if;
  end loop;

  update sessions
  set participant_id = v_participant_id,
      status         = 'completed',
      ended_at       = now()
  where id = p_session_id;

  return v_participant_id;
end;
$function$;

-- ============================================================================
-- 8. One correct option per item
-- ============================================================================
-- full_export_v1 now joins item_options on `is_correct` to surface the answer
-- key. If an item ever had TWO options flagged correct, that join would
-- duplicate every response row for that item in the export -- the same silent
-- row-doubling class as the consent_records duplicate closed in section 2, and
-- just as invisible. The Item Bank Editor does not prevent ticking two, so
-- prevent it here.
create unique index if not exists item_options_one_correct_per_item
  on item_options(item_id)
  where is_correct;
