-- BADSQ Platform — Migration 0011
-- Four additions, all requested together:
--   1. Background info (age/gender/home_area) on participants -- class_grade already existed.
--   2. Participant-entered consent-form replication (Q1-Q3), written via submit_session()
--      rather than a new anon RLS policy on consent_records, keeping "researchers write
--      consent_records directly" as the only other write path (defense in depth).
--   3. domain_intros: per-domain/subdomain instruction pages shown before that group's first
--      item, publicly readable like public_items, researcher-managed like items.
--   4. replay_count_instruction/replay_count_stimulus become nullable: an item with no
--      instruction (or no stimulus) audio at all should record NULL "not applicable", not 0
--      "had audio, never replayed it" -- those are different facts. submit_session() now
--      passes the client's value straight through instead of coalescing missing to 0.
--   5. full_export_v1: one wide, denormalized view -- every raw column collected about a
--      participant, in one row per response, for a single CSV download from the admin panel.

-- ============================================================ 1. Background info
alter table participants add column if not exists age_years smallint;
alter table participants add column if not exists gender text
  check (gender in ('boy', 'girl', 'prefer_not_to_say'));
alter table participants add column if not exists home_area text
  check (home_area in ('urban', 'rural'));

-- ============================================================ 2. domain_intros
create table if not exists domain_intros (
  id                uuid primary key default gen_random_uuid(),
  domain            text not null,
  subdomain         text,                    -- NULL = shown once before the domain's first item
  intro_text        text not null,
  intro_audio_path  text,
  display_order     int not null,
  active            boolean not null default true,
  edited_by         uuid references researchers(id),
  created_at        timestamptz not null default now(),
  unique (domain, subdomain)
);

alter table domain_intros enable row level security;

create policy domain_intros_select_all on domain_intros
  for select
  using (active = true or is_researcher());

create policy domain_intros_write_manager on domain_intros
  for insert
  with check (can_manage_items());

create policy domain_intros_update_manager on domain_intros
  for update
  using (can_manage_items())
  with check (can_manage_items());

-- ============================================================ 3. Nullable replay counts
alter table responses alter column replay_count_instruction drop not null;
alter table responses alter column replay_count_stimulus drop not null;
alter table responses alter column replay_count_instruction drop default;
alter table responses alter column replay_count_stimulus drop default;

-- ============================================================ 4. submit_session(): background
-- info, consent replication, and NULL-passthrough replay counts. Scoring logic (MCQ_TAP/
-- BINARY_TAP/NUMERIC_KEYPAD auto-scoring) is UNCHANGED from migration 0008/0010.
create or replace function submit_session(
  p_session_id  uuid,
  p_participant jsonb,
  p_responses   jsonb,
  p_consent     jsonb default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_participant_id uuid;
  v_assigned_code  text;
  v_response       jsonb;
  v_response_id    uuid;
  v_item           items%rowtype;
  v_is_correct     boolean;
  v_has_key        boolean;
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

    v_is_correct := null;

    if v_item.scoring_mode = 'auto' then
      if v_item.response_format in ('MCQ_TAP', 'BINARY_TAP') then
        select exists (
          select 1 from item_options
          where item_id = v_item.id and is_correct = true
        ) into v_has_key;

        if v_has_key then
          select coalesce(io.is_correct, false) into v_is_correct
          from item_options io
          where io.item_id = v_item.id
            and io.option_key = v_response->>'selected_option_key';
          v_is_correct := coalesce(v_is_correct, false);
        end if;

      elsif v_item.response_format = 'NUMERIC_KEYPAD' then
        if v_item.correct_answer is not null then
          v_is_correct := ((v_response->>'typed_value') is not distinct from v_item.correct_answer);
        end if;
      end if;
    end if;

    insert into responses (
      session_id, item_id, attempt_number, is_superseded,
      stimulus_first_end_client_ts, stimulus_last_end_client_ts, response_client_ts,
      response_latency_from_first_ms, response_latency_from_last_ms,
      input_modality, viewport_width, viewport_height,
      selected_option_key, typed_value,
      is_correct, scored_by,
      replay_count_instruction, replay_count_stimulus, technical_retry_count,
      raw_client_event_log
    ) values (
      p_session_id,
      (v_response->>'item_id')::uuid,
      coalesce((v_response->>'attempt_number')::smallint, 1),
      coalesce((v_response->>'is_superseded')::boolean, false),
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
      v_is_correct,
      case when v_is_correct is not null then 'system' else null end,
      -- CHANGED IN 0011: NULL passes through (item had no audio to replay) instead of
      -- being coalesced to 0 (item had audio, replayed zero times) -- see header comment.
      (v_response->>'replay_count_instruction')::int,
      (v_response->>'replay_count_stimulus')::int,
      coalesce((v_response->>'technical_retry_count')::int, 0),
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
$$;

grant execute on function submit_session(uuid, jsonb, jsonb, jsonb) to anon, authenticated;
revoke execute on function submit_session(uuid, jsonb, jsonb, jsonb) from public;

-- Old 3-arg overload is superseded (PostgREST resolves by argument count/name) --
-- drop it so there is exactly one submit_session to call.
drop function if exists submit_session(uuid, jsonb, jsonb);

-- ============================================================ 5. full_export_v1
-- One row per response, every raw column collected about that participant, denormalized
-- for a single CSV download. Superset of ml_export_v1 (kept as-is, unchanged).
-- security_invoker = true is load-bearing here, not a style choice: without it this view
-- would run as its (superuser) creator and bypass every RLS policy on participants/
-- consent_records/responses, handing any authenticated session -- including a
-- participant's own anonymous-sign-in session -- every OTHER participant's raw data. With
-- it, only a session whose own RLS lets it read all four base tables (i.e. is_researcher())
-- gets any rows back.
create or replace view full_export_v1
with (security_invoker = true)
as
select
  r.id                              as response_id,
  p.anonymized_code,
  p.class_grade,
  p.age_years,
  p.age_months,
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
  r.selected_option_key,
  r.typed_value,
  r.is_correct,
  r.scored_by,
  ar.storage_path                  as audio_storage_path,
  ar.mime_type                     as audio_mime_type,
  ar.duration_ms                   as audio_duration_ms,
  ar.notes                         as audio_notes,
  ar.is_reliability_subsample,
  r.stimulus_first_end_client_ts,
  r.stimulus_last_end_client_ts,
  r.response_client_ts,
  r.response_latency_from_first_ms,
  r.response_latency_from_last_ms,
  r.input_modality,
  r.viewport_width,
  r.viewport_height,
  r.replay_count_instruction,
  r.replay_count_stimulus,
  r.technical_retry_count,
  r.selection_change_count,
  r.attempt_number,
  r.is_superseded,
  s.id                              as session_id,
  s.started_at                     as session_started_at,
  s.ended_at                       as session_ended_at,
  r.submitted_at
from responses r
join sessions s on s.id = r.session_id
join participants p on p.id = s.participant_id
join items i on i.id = r.item_id
left join audio_recordings ar on ar.response_id = r.id
left join consent_records cr on cr.participant_id = p.id
where r.is_superseded = false;

grant select on full_export_v1 to authenticated;
