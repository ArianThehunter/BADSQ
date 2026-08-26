-- BADSQ Platform — Migration 0005: hardening + defect fixes from the 0004 report
--
-- Fixes G1, G2, G3, G5, G6, G7, G8 and the NULL-answer-key scoring hazard.
-- G4 verified as intentional. G9/G10 noted, no action.
--
-- UNTESTED against a live instance. Verify and report failures rather than patching.

-- ============================================================
-- G1 (blocker): the 0004 audio-column rename never reached public_items.
--
-- Postgres rewrites a view's internal reference on a base-column rename but does
-- NOT rename the view's output column, so public_items still emitted
-- instruction_audio_url / stimulus_audio_url while the base table had *_path.
--
-- This is the second occurrence of this defect class (F5 was the first, in 0003).
-- CREATE OR REPLACE VIEW cannot rename output columns — the view must be dropped
-- and recreated. A standing column-name-drift assertion is being added to the
-- verification suite as a release gate; see the Phase 1 brief.
-- ============================================================
drop view if exists public_items;
create view public_items
with (security_invoker = off) as
select
  id, item_code, version, domain, subdomain, response_format,
  instruction_audio_path, stimulus_audio_path, stimulus_text,
  is_instruction_replayable, is_stimulus_replayable,
  is_practice, is_scored, display_order
from items
where active = true;

grant select on public_items to anon, authenticated;

-- Recreated for symmetry and to re-assert its security properties explicitly.
drop view if exists public_item_options;
create view public_item_options
with (security_invoker = off) as
select io.id, io.item_id, io.option_key, io.option_text
from item_options io
join items i on i.id = io.item_id
where i.active = true;

grant select on public_item_options to anon, authenticated;

-- ============================================================
-- G2: the paper-consent join key had no referential integrity.
--
-- Field sequence: session starts -> code issued -> teacher transcribes onto the
-- paper form -> form digitized later. The session therefore always exists before
-- the code can be written down, so an FK is safe.
--
-- NOTE (workflow change): the code must be transcribed at the CLOSING screen,
-- not at session start. If it were transcribed at start and the student then
-- abandoned and restarted, a new code would be issued and the paper form would
-- carry a stale one. An abandoned session then has neither a code on paper nor
-- submitted data, which is consistent rather than mismatched.
-- ============================================================
create unique index if not exists uq_consent_assigned_code
  on consent_records(assigned_code)
  where assigned_code is not null;

alter table consent_records
  add constraint fk_consent_session_code
  foreign key (assigned_code) references sessions(assigned_code);

-- ============================================================
-- G3: RLS helper functions had a mutable search_path.
-- These are called by every policy in the schema. Same latent defect class that
-- produced F2's outage.
-- ============================================================
create or replace function is_researcher() returns boolean
language sql security definer stable
set search_path = public
as $$
  select exists (select 1 from researchers where user_id = auth.uid());
$$;

create or replace function can_manage_items() returns boolean
language sql security definer stable
set search_path = public
as $$
  select exists (select 1 from researchers where user_id = auth.uid() and can_manage_items = true);
$$;

create or replace function can_rate() returns boolean
language sql security definer stable
set search_path = public
as $$
  select exists (select 1 from researchers where user_id = auth.uid() and can_rate = true);
$$;

create or replace function generate_participant_code() returns text
language plpgsql
set search_path = public
as $$
declare
  v_alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_code text;
  i int;
begin
  loop
    v_code := 'BADSQ-';
    for i in 1..4 loop
      v_code := v_code || substr(v_alphabet, (floor(random() * 32) + 1)::int, 1);
    end loop;
    v_code := v_code || '-';
    for i in 1..4 loop
      v_code := v_code || substr(v_alphabet, (floor(random() * 32) + 1)::int, 1);
    end loop;
    exit when not exists (select 1 from sessions where assigned_code = v_code);
  end loop;
  return v_code;
end;
$$;

-- ============================================================
-- G5: trigger functions should not be public RPC surface.
-- Not exploitable (PostgreSQL rejects trigger functions called outside trigger
-- context, and neither takes arguments), but the endpoint should not exist.
-- ============================================================
revoke execute on function propagate_audio_rating() from anon, authenticated;
revoke execute on function link_researcher_on_signup() from anon, authenticated;

-- ============================================================
-- G6: sessions must only be created and completed through the definer RPCs.
--
-- sessions_insert_own allowed a direct INSERT, which produced a row with
-- assigned_code = NULL that submit_session() then rejects — a dead session that
-- fails at the worst possible moment, after a child has completed the battery.
--
-- sessions_update_own_in_progress additionally let a participant set their own
-- session to 'completed' without submitting, orphaning it with no participant row.
-- ============================================================
drop policy if exists sessions_insert_own on sessions;
drop policy if exists sessions_update_own_in_progress on sessions;

revoke insert, update on sessions from anon, authenticated;

-- ============================================================
-- G7: removing a departed researcher's auth account was blocked by the allowlist FK.
-- ============================================================
alter table researchers drop constraint if exists researchers_user_id_fkey;
alter table researchers
  add constraint researchers_user_id_fkey
  foreign key (user_id) references auth.users(id) on delete set null;

-- ============================================================
-- G8 + NULL-answer-key scoring hazard.
--
-- The scoring hazard is the more serious of the two: a scored item with no answer
-- key defined previously marked EVERY student wrong (coalesce(..., false) for MCQ,
-- and `typed_value is not distinct from NULL` for keypad). Silent, and it would
-- depress a domain score without any error surfacing. Such items are now left
-- unscored and logged, and the Item Bank Editor's activation guard blocks them
-- from going live in the first place.
--
-- G8: the client should not learn which of the four rejection causes applied, but
-- the server log should record it, so a field failure is diagnosable.
-- ============================================================
create or replace function submit_session(
  p_session_id  uuid,
  p_participant jsonb,
  p_responses   jsonb
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_participant_id uuid;
  v_assigned_code  text;
  v_session        sessions%rowtype;
  v_response       jsonb;
  v_response_id    uuid;
  v_item           items%rowtype;
  v_is_correct     boolean;
  v_has_key        boolean;
begin
  select * into v_session from sessions where id = p_session_id;

  if not found then
    raise log 'submit_session: session % does not exist (uid %)', p_session_id, auth.uid();
    raise exception 'Session not found, not owned by caller, or already submitted';
  elsif v_session.auth_uid is distinct from auth.uid() then
    raise log 'submit_session: session % not owned by uid %', p_session_id, auth.uid();
    raise exception 'Session not found, not owned by caller, or already submitted';
  elsif v_session.status <> 'in_progress' then
    raise log 'submit_session: session % already %', p_session_id, v_session.status;
    raise exception 'Session not found, not owned by caller, or already submitted';
  elsif v_session.assigned_code is null then
    raise log 'submit_session: session % has no assigned_code (not created via start_session)', p_session_id;
    raise exception 'Session not found, not owned by caller, or already submitted';
  end if;

  v_assigned_code := v_session.assigned_code;

  insert into participants (anonymized_code, class_grade, age_months, school_id, created_by_auth_uid)
  values (
    v_assigned_code,
    (p_participant->>'class_grade')::smallint,
    nullif(p_participant->>'age_months', '')::int,
    nullif(p_participant->>'school_id', '')::uuid,
    auth.uid()
  )
  returning id into v_participant_id;

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

        if not v_has_key then
          raise log 'submit_session: item % (%) is scored but has no correct option; left unscored',
            v_item.item_code, v_item.id;
        else
          select coalesce(io.is_correct, false) into v_is_correct
          from item_options io
          where io.item_id = v_item.id
            and io.option_key = v_response->>'selected_option_key';
          v_is_correct := coalesce(v_is_correct, false);
        end if;

      elsif v_item.response_format = 'NUMERIC_KEYPAD' then
        if v_item.correct_answer is null then
          raise log 'submit_session: item % (%) is scored but has no correct_answer; left unscored',
            v_item.item_code, v_item.id;
        else
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
      coalesce((v_response->>'replay_count_instruction')::int, 0),
      coalesce((v_response->>'replay_count_stimulus')::int, 0),
      coalesce((v_response->>'technical_retry_count')::int, 0),
      v_response->'raw_client_event_log'
    )
    returning id into v_response_id;

    if v_response ? 'audio_storage_path' then
      insert into audio_recordings (response_id, storage_path, mime_type, duration_ms, file_size_bytes)
      values (
        v_response_id,
        v_response->>'audio_storage_path',
        v_response->>'audio_mime_type',
        (v_response->>'audio_duration_ms')::int,
        (v_response->>'audio_file_size_bytes')::bigint
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

grant execute on function submit_session(uuid, jsonb, jsonb) to anon, authenticated;
