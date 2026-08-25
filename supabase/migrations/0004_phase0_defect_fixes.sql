-- BADSQ Platform — Migration 0004: Phase 0 defect fixes + new requirements
--
-- Fixes F1-F7 from the Phase 0 verification report. All seven originated in
-- migrations 0001-0003. Adds: item-audio storage bucket, server-generated
-- participant codes, and paper-consent linkage.
--
-- UNTESTED against a live instance. Verify every fix with the existing assertion
-- suite and report failures rather than patching around them.

-- ============================================================
-- F2 (blocking): researcher signup fails with HTTP 500.
-- SECURITY DEFINER without SET search_path; GoTrue runs as supabase_auth_admin
-- with search_path=auth, so `researchers` does not resolve.
-- ============================================================
create or replace function link_researcher_on_signup() returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.researchers
  set user_id = NEW.id
  where email = NEW.email and user_id is null;
  return NEW;
end;
$$;

-- ============================================================
-- F4 (blocking, silent data loss): audio ratings never reach responses.
-- Trigger defaulted to SECURITY INVOKER; responses has no UPDATE policy, so the
-- inner UPDATE was RLS-filtered to zero rows without raising.
-- Now DEFINER, and fails loudly if the target row is missing.
-- ============================================================
create or replace function propagate_audio_rating() returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if NEW.primary_rating is distinct from OLD.primary_rating then
    update responses
    set is_correct = NEW.primary_rating,
        scored_by  = 'human'
    where id = NEW.response_id;

    if not found then
      raise exception 'propagate_audio_rating: no responses row for id %', NEW.response_id;
    end if;
  end if;
  return NEW;
end;
$$;

-- ============================================================
-- F3 (blocking): ml_snapshots is world-writable — RLS never enabled and anon
-- holds default grants. This table holds the entire flattened export.
-- ============================================================
alter table ml_snapshots enable row level security;
revoke all on ml_snapshots from anon;
grant select, insert, delete on ml_snapshots to authenticated;

drop policy if exists ml_snapshots_researcher_all on ml_snapshots;
create policy ml_snapshots_researcher_all on ml_snapshots
  for all using (is_researcher()) with check (is_researcher());

-- ============================================================
-- F1 (blocking): the item bank is unreadable by everyone.
--
-- Root cause: participants and researchers share the SAME Postgres role.
-- Supabase anonymous sign-in issues a JWT with role='authenticated' and
-- is_anonymous=true, so no role-level or column-level GRANT can separate them.
-- Separation must be: RLS policies (via is_researcher()) on the base tables,
-- and a SECURITY DEFINER view projecting only non-answer columns for participants.
--
-- NOTE: Supabase's advisor will flag public_items/public_item_options as
-- `security_definer_view`. That is intentional and is the mechanism keeping
-- answer keys away from clients. Document it; do not "fix" it.
-- ============================================================

-- Remove the 0003 policies that exposed base-table rows to participants.
drop policy if exists items_select_active_public on items;
drop policy if exists item_options_select_active_public on item_options;

-- Restore base-table grants. RLS (researcher-only, from 0003) does the filtering.
grant select on items to authenticated;
grant select on item_options to authenticated;
revoke select on items from anon;
revoke select on item_options from anon;

-- Views run with owner privileges, bypassing base-table RLS, and expose only
-- safe columns.
alter view public_items set (security_invoker = off);
alter view public_item_options set (security_invoker = off);
grant select on public_items to anon, authenticated;
grant select on public_item_options to anon, authenticated;

-- ============================================================
-- F6/F7 (blocking): participants cannot read their own session row, which
-- breaks (a) the storage upload policy's subquery and (b) the §5e resume anchor.
-- ============================================================
drop policy if exists sessions_select_own on sessions;
create policy sessions_select_own on sessions
  for select using (auth_uid = auth.uid());

-- ============================================================
-- F5: ml_export_v1 never picked up the dual-anchor latency columns.
-- ============================================================
drop view if exists ml_export_v1;
create view ml_export_v1
with (security_invoker = on) as
select
  r.id                              as response_id,
  p.anonymized_code,
  p.class_grade,
  i.item_code,
  i.domain,
  i.subdomain,
  i.response_format,
  r.response_latency_from_first_ms,
  r.response_latency_from_last_ms,
  r.input_modality,
  r.selected_option_key,
  r.typed_value,
  r.is_correct,
  r.scored_by,
  r.replay_count_instruction,
  r.replay_count_stimulus,
  r.technical_retry_count,
  r.submitted_at
from responses r
join sessions s     on s.id = r.session_id
join participants p on p.id = s.participant_id
join items i        on i.id = r.item_id
where r.is_superseded = false;

revoke all on ml_export_v1 from anon;
grant select on ml_export_v1 to authenticated;

-- ml_snapshots must match the view's new shape.
drop table if exists ml_snapshots;
create table ml_snapshots (
  id                              uuid primary key default gen_random_uuid(),
  response_id                     uuid,
  anonymized_code                 text,
  class_grade                     smallint,
  item_code                       text,
  domain                          text,
  subdomain                       text,
  response_format                 text,
  response_latency_from_first_ms  double precision,
  response_latency_from_last_ms   double precision,
  input_modality                  text,
  selected_option_key             text,
  typed_value                     text,
  is_correct                      boolean,
  scored_by                       text,
  replay_count_instruction        int,
  replay_count_stimulus           int,
  technical_retry_count           int,
  submitted_at                    timestamptz,
  snapshot_label                  text,
  snapshot_taken_at               timestamptz not null default now()
);

alter table ml_snapshots enable row level security;
revoke all on ml_snapshots from anon;
grant select, insert, delete on ml_snapshots to authenticated;
create policy ml_snapshots_researcher_all on ml_snapshots
  for all using (is_researcher()) with check (is_researcher());

-- ============================================================
-- NEW: item audio is authored and uploaded by researchers.
-- Columns hold storage object paths, not URLs.
-- ============================================================
alter table items rename column instruction_audio_url to instruction_audio_path;
alter table items rename column stimulus_audio_url   to stimulus_audio_path;

insert into storage.buckets (id, name, public)
values ('badsq-item-audio', 'badsq-item-audio', false)
on conflict (id) do nothing;

-- Readable by researchers, and by participants with a live session. Not public:
-- item audio reveals test content, so it should not be world-downloadable.
create policy item_audio_read on storage.objects
  for select to authenticated
  using (
    bucket_id = 'badsq-item-audio'
    and (
      is_researcher()
      or exists (
        select 1 from sessions s
        where s.auth_uid = auth.uid() and s.status = 'in_progress'
      )
    )
  );

create policy item_audio_write_manager on storage.objects
  for insert to authenticated
  with check (bucket_id = 'badsq-item-audio' and can_manage_items());

create policy item_audio_update_manager on storage.objects
  for update to authenticated
  using (bucket_id = 'badsq-item-audio' and can_manage_items())
  with check (bucket_id = 'badsq-item-audio' and can_manage_items());

create policy item_audio_delete_manager on storage.objects
  for delete to authenticated
  using (bucket_id = 'badsq-item-audio' and can_manage_items());

-- ============================================================
-- NEW: participant code issued at session start, persisted at submit.
--
-- This is the join key between the PAPER parental consent form (which carries
-- criterion indicators Q1-Q3) and the anonymous digital session. Without it,
-- Q2/Q3 can never be joined to domain scores and the Section 10.2 classification
-- rule is uncomputable.
--
-- Flow: session start -> code generated and shown on screen -> supervising
-- teacher writes it on the paper form -> at submit it becomes
-- participants.anonymized_code (server-side, never client-supplied).
-- ============================================================
alter table sessions add column if not exists assigned_code text unique;

create or replace function generate_participant_code() returns text
language plpgsql
as $$
declare
  -- Ambiguous glyphs (I, O, 0, 1) excluded: this code is transcribed by hand
  -- onto a paper form and read back by a different person.
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

create or replace function start_session()
returns table (out_session_id uuid, out_assigned_code text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id   uuid;
  v_code text;
begin
  if auth.uid() is null then
    raise exception 'start_session: no authenticated identity';
  end if;

  v_code := generate_participant_code();

  insert into sessions (auth_uid, assigned_code)
  values (auth.uid(), v_code)
  returning id into v_id;

  return query select v_id, v_code;
end;
$$;

grant execute on function start_session() to anon, authenticated;

-- ============================================================
-- Paper consent forms are digitized against the code, often before the
-- participant row exists.
-- ============================================================
alter table consent_records alter column participant_id drop not null;
alter table consent_records add column if not exists assigned_code text;
create index if not exists idx_consent_assigned_code on consent_records(assigned_code);

-- ============================================================
-- submit_session: take anonymized_code from the session row rather than the
-- client payload, so the paper-form linkage cannot be tampered with.
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
