-- BADSQ Platform — Migration 0008
-- Switches reliability-subsample assignment from manual-only (a methodological
-- risk: a rater choosing which recordings get double-scored can bias the
-- resulting Cohen's kappa away from a true population-level agreement estimate)
-- to automatic random assignment at submission time, at a fixed configurable
-- rate. The manual toggle built in Phase 3 stays available as an override.
--
-- UNTESTED against a live instance. Verify and report failures rather than patching.

-- ============================================================
-- Single source of truth for the subsample rate, so it can be changed later
-- without touching submit_session()'s body.
-- ============================================================
create or replace function reliability_subsample_rate() returns double precision
language sql
immutable
as $$
  select 0.20;  -- 20% of audio recordings, randomly, at submission time
$$;

-- ============================================================
-- submit_session(): audio_recordings insert now sets is_reliability_subsample
-- via reliability_subsample_rate() rather than always defaulting to false.
-- Everything else in the function is unchanged from 0005.
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
      coalesce((v_response->>'replay_count_instruction')::int, 0),
      coalesce((v_response->>'replay_count_stimulus')::int, 0),
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

grant execute on function submit_session(uuid, jsonb, jsonb) to anon, authenticated;
