-- BADSQ Platform — Migration 0003: Phase 0 fixes
--
-- Addresses issues found in the agent's design audit of 0001/0002, plus three
-- further issues found on review. Apply AFTER 0001 and 0002.
--
-- NOTE: the submit_session() function below has not been executed against a live
-- Postgres instance. It must be tested as part of Phase 0 verification before any
-- frontend work depends on it. Report failures rather than patching around them.

-- ============================================================
-- FIX 1: Remove the circular FK between responses and audio_recordings.
-- The 1:1 relationship is fully captured by audio_recordings.response_id.
-- ============================================================
alter table responses drop constraint if exists fk_responses_audio_recording;
alter table responses drop column if exists audio_recording_id;

-- ============================================================
-- FIX 2: Dual latency anchors.
-- Rather than deciding now whether a replayed stimulus should re-anchor t0,
-- capture both and defer the analytic choice to the pilot data.
--   *_from_first = anchored to the first time the stimulus audio ever ended
--   *_from_last  = anchored to the most recent ended event before the response
-- ============================================================
alter table responses rename column stimulus_end_client_ts to stimulus_last_end_client_ts;
alter table responses rename column response_latency_ms to response_latency_from_last_ms;
alter table responses add column stimulus_first_end_client_ts double precision;
alter table responses add column response_latency_from_first_ms double precision;

-- ============================================================
-- FIX 3: Answer keys must never reach the client.
-- Participants read items through these views, which exclude correct_answer
-- and is_correct entirely. Scoring happens server-side in submit_session().
-- ============================================================
drop policy if exists items_select_all on items;
drop policy if exists item_options_select_all on item_options;

create policy items_select_researcher on items
  for select using (is_researcher());

create policy item_options_select_researcher on item_options
  for select using (is_researcher());

create view public_items
with (security_invoker = on) as
select
  id, item_code, version, domain, subdomain, response_format,
  instruction_audio_url, stimulus_audio_url, stimulus_text,
  is_instruction_replayable, is_stimulus_replayable,
  is_practice, is_scored, display_order
from items
where active = true;

create view public_item_options
with (security_invoker = on) as
select io.id, io.item_id, io.option_key, io.option_text
from item_options io
join items i on i.id = io.item_id
where i.active = true;

-- These views are the participant-facing read path. security_invoker is ON, but
-- the underlying tables' SELECT policies are researcher-only, so grant explicitly.
grant select on public_items to anon, authenticated;
grant select on public_item_options to anon, authenticated;

-- Because security_invoker = on defers to the caller's RLS, and the caller is an
-- anonymous participant with no SELECT policy on items, we need a permissive
-- policy scoped to non-answer columns. Postgres RLS is row-level, not column-level,
-- so the column filtering is done by the view definition above and the base-table
-- policy below permits reading active rows.
create policy items_select_active_public on items
  for select using (active = true);

create policy item_options_select_active_public on item_options
  for select using (
    exists (select 1 from items i where i.id = item_id and i.active = true)
  );

-- IMPORTANT: the two policies above make base-table rows readable, which means a
-- client querying `items` directly (not the view) could still see correct_answer.
-- Revoke direct table access from client roles so the views are the only path.
revoke select on items from anon, authenticated;
revoke select on item_options from anon, authenticated;

-- ============================================================
-- FIX 4: ml_export_v1 must not bypass RLS.
-- Without security_invoker, a view runs with its owner's privileges, which would
-- let any caller read the full dataset through it.
-- ============================================================
alter view ml_export_v1 set (security_invoker = on);
revoke all on ml_export_v1 from anon;

-- ============================================================
-- FIX 5: Researchers can see the full researcher roster
-- (needed for rater names in the rating queue and admin views).
-- ============================================================
drop policy if exists researchers_self_select on researchers;
create policy researchers_select_researcher on researchers
  for select using (is_researcher());

-- ============================================================
-- FIX 6: Storage bucket and policies for audio recordings.
-- Participants may upload into their own session's folder; only researchers read.
-- Path convention: {session_id}/{response_client_id}.{ext}
-- ============================================================
insert into storage.buckets (id, name, public)
values ('badsq-audio', 'badsq-audio', false)
on conflict (id) do nothing;

create policy audio_upload_own_session on storage.objects
  for insert to anon, authenticated
  with check (
    bucket_id = 'badsq-audio'
    and exists (
      select 1 from sessions s
      where s.auth_uid = auth.uid()
        and s.status = 'in_progress'
        and (storage.foldername(name))[1] = s.id::text
    )
  );

create policy audio_read_researcher on storage.objects
  for select to authenticated
  using (bucket_id = 'badsq-audio' and is_researcher());

create policy audio_delete_researcher on storage.objects
  for delete to authenticated
  using (bucket_id = 'badsq-audio' and is_researcher());

-- ============================================================
-- FIX 7: Atomic submission RPC.
-- Replaces the multi-step client-side batch insert. One transaction:
-- participant → responses (scored server-side) → audio rows → session completed.
-- Audio files are uploaded to Storage BEFORE calling this; the payload carries
-- their storage paths only.
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
  v_response       jsonb;
  v_response_id    uuid;
  v_item           items%rowtype;
  v_is_correct     boolean;
begin
  -- Caller must own this session and it must still be open.
  if not exists (
    select 1 from sessions
    where id = p_session_id
      and auth_uid = auth.uid()
      and status = 'in_progress'
  ) then
    raise exception 'Session not found, not owned by caller, or already submitted';
  end if;

  insert into participants (anonymized_code, class_grade, age_months, school_id, created_by_auth_uid)
  values (
    p_participant->>'anonymized_code',
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

    -- Server-side scoring. Auto-scorable formats only; audio items stay NULL
    -- until a human rater sets them. TRI_TAP/LIKERT_5 are self-report and have
    -- no correct answer by design.
    v_is_correct := null;
    if v_item.scoring_mode = 'auto' then
      if v_item.response_format in ('MCQ_TAP', 'BINARY_TAP') then
        select io.is_correct into v_is_correct
        from item_options io
        where io.item_id = v_item.id
          and io.option_key = v_response->>'selected_option_key';
        v_is_correct := coalesce(v_is_correct, false);
      elsif v_item.response_format = 'NUMERIC_KEYPAD' then
        v_is_correct := ((v_response->>'typed_value') is not distinct from v_item.correct_answer);
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

-- Client-side direct INSERT on responses/audio_recordings is no longer the
-- submission path; the RPC is. Remove the participant insert policies so the
-- RPC (security definer) is the only way in.
drop policy if exists responses_insert_via_own_session on responses;
drop policy if exists audio_insert_via_own_session on audio_recordings;

-- ============================================================
-- FIX 8: Indexes for the query patterns the admin panel and export actually use.
-- ============================================================
create index if not exists idx_responses_session on responses(session_id);
create index if not exists idx_responses_item on responses(item_id);
create index if not exists idx_audio_rating_status on audio_recordings(rating_status)
  where rating_status = 'pending';
create index if not exists idx_items_active_order on items(active, display_order);
create index if not exists idx_sessions_status on sessions(status);
