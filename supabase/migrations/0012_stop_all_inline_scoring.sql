-- BADSQ Platform — Migration 0012
-- Decision expanded from migration 0010: correctness is no longer computed inline for
-- ANY format, not just AUDIO_RECORD. MCQ_TAP/BINARY_TAP/NUMERIC_KEYPAD auto-scoring at
-- submit time is removed. responses.is_correct/scored_by are now always NULL, for every
-- format, going forward -- all scoring happens later in the researcher's own
-- model/analysis, against the raw responses (selected_option_key, typed_value, audio)
-- plus the answer key that STAYS in the database (item_options.is_correct,
-- items.correct_answer) for exactly that offline use.
--
-- This does not touch the answer key itself, is_scored/scoring_mode metadata, or the
-- NO_ANSWER_KEY activation guard (src/lib/itemValidation.ts) -- an item still needs a
-- real answer key before going live, it just no longer gets compared against it live.

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

    -- CHANGED IN 0012: no scoring here for any format -- see header comment.
    -- is_correct/scored_by are always NULL at insert time now.

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
      null,
      null,
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

-- Backfill: the one real flight-test session scored under the old rule (10 Domain-1
-- responses, scored_by='system') gets reset to NULL for consistency with the new rule.
update responses set is_correct = null, scored_by = null where scored_by = 'system';
