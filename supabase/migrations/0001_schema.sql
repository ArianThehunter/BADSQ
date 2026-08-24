-- BADSQ Platform — Phase 0 schema
-- Consolidates all decisions from the design conversation.
-- Run via `supabase migration up` (or paste into the SQL editor for initial setup).

-- ============================================================
-- Researchers (unifies "raters" and "admins" — one allowlist,
-- role flags rather than two tables to keep in sync)
-- ============================================================
create table researchers (
  id                  uuid primary key default gen_random_uuid(),
  email               text unique not null,          -- pre-provisioned allowlist entry
  user_id             uuid references auth.users(id),-- filled in on first real login
  can_rate            boolean not null default true,
  can_manage_items    boolean not null default false,
  added_at            timestamptz not null default now()
);

-- Links a researcher's Supabase auth account to their pre-provisioned
-- allowlist row the first time they log in via magic link.
create or replace function link_researcher_on_signup() returns trigger as $$
begin
  update researchers
  set user_id = NEW.id
  where email = NEW.email and user_id is null;
  return NEW;
end;
$$ language plpgsql security definer;

create trigger trg_link_researcher_on_signup
after insert on auth.users
for each row
execute function link_researcher_on_signup();

-- ============================================================
-- Participants & consent
-- Participants are created at final submit (not session start),
-- keeping the "nothing until submit" model for anything beyond
-- the minimal session-start ping.
-- ============================================================
create table participants (
  id                    uuid primary key default gen_random_uuid(),
  anonymized_code       text unique not null,
  class_grade           smallint not null check (class_grade in (6,7,8)),
  age_months            int,
  school_id             uuid,
  created_by_auth_uid   uuid default auth.uid(),   -- ties row to the anonymous session that created it, for RLS
  created_at            timestamptz not null default now()
);

create table consent_records (
  id                          uuid primary key default gen_random_uuid(),
  participant_id              uuid not null references participants(id),
  consent_given               boolean not null,
  consent_date                date not null,
  q1_doctor_eval              boolean,
  q1_school_eval              boolean,
  q1_not_sure                 boolean,
  q2_extra_primary_support    text check (q2_extra_primary_support in ('yes','no','not_sure')),
  q3_family_history           text check (q3_family_history in ('yes','no','not_sure')),
  digitized_at                timestamptz,
  digitized_by                uuid references researchers(id),  -- who transcribed the paper form
  paper_form_scan_ref         text
);

-- ============================================================
-- Item bank — versioned. Editing never mutates a row a completed
-- session already answered; it creates a new version and retires
-- the old one (active = false, never deleted).
-- ============================================================
create table items (
  id                          uuid primary key default gen_random_uuid(),
  item_code                   text not null,
  version                     int not null default 1,
  domain                      text not null,             -- '1'..'5' or 'criterion'
  subdomain                   text,
  response_format             text not null check (response_format in
                               ('MCQ_TAP','BINARY_TAP','TRI_TAP','NUMERIC_KEYPAD','LIKERT_5','AUDIO_RECORD')),
  instruction_audio_url       text,
  stimulus_audio_url          text,
  stimulus_text               text,
  is_instruction_replayable   boolean not null default true,
  is_stimulus_replayable      boolean,                   -- must be explicitly set per domain before go-live; NULL blocks publishing in the admin UI
  correct_answer              text,
  scoring_mode                text not null check (scoring_mode in ('auto','human_rated')),
  is_practice                 boolean not null default false,
  is_scored                   boolean not null default true,
  display_order               int,
  active                      boolean not null default true,
  edited_by                   uuid references researchers(id),
  created_at                  timestamptz not null default now(),
  unique (item_code, version)
);

create table item_options (
  id            uuid primary key default gen_random_uuid(),
  item_id       uuid not null references items(id),
  option_key    text not null,
  option_text   text not null,
  is_correct    boolean not null default false,
  unique (item_id, option_key)
);

-- ============================================================
-- Sessions — created at start (the approved minimal ping), with
-- everything else filled in only at final submit.
-- ============================================================
create table sessions (
  id              uuid primary key default gen_random_uuid(),
  auth_uid        uuid not null default auth.uid(),  -- ties the row to this browser's anonymous auth session
  participant_id  uuid references participants(id),  -- NULL until final submit
  session_part    smallint not null default 1,
  started_at      timestamptz not null default now(),
  ended_at        timestamptz,
  status          text not null default 'in_progress'
                  check (status in ('in_progress','completed','abandoned'))
);

-- ============================================================
-- Responses — written in the final batch submit, not incrementally.
-- Supersession columns preserve the full attempt history (edits before
-- advance) rather than overwriting, per the "editable before advance"
-- navigation policy decided earlier.
-- ============================================================
create table responses (
  id                        uuid primary key default gen_random_uuid(),
  session_id                uuid not null references sessions(id),
  item_id                   uuid not null references items(id),
  attempt_number            smallint not null default 1,
  is_superseded             boolean not null default false,
  submitted_at              timestamptz not null default now(),

  stimulus_end_client_ts    double precision,
  response_client_ts        double precision,
  response_latency_ms       double precision,

  input_modality            text check (input_modality in ('touch','mouse','pen','keyboard','unknown')),
  viewport_width            int,
  viewport_height           int,

  selected_option_key       text,
  typed_value               text,
  audio_recording_id        uuid,

  is_correct                boolean,
  scored_by                 text check (scored_by in ('system','human')),

  replay_count_instruction  int not null default 0,
  replay_count_stimulus     int not null default 0,
  technical_retry_count     int not null default 0,

  raw_client_event_log      jsonb
);

-- ============================================================
-- Audio recordings — separated from responses so a recording can be
-- deleted post-study (per the parental consent commitment) while the
-- derived is_correct score persists in `responses`.
-- ============================================================
create table audio_recordings (
  id                        uuid primary key default gen_random_uuid(),
  response_id               uuid not null unique references responses(id),
  storage_path              text not null,
  mime_type                 text,              -- actual detected format (WebM/Opus, MP4/AAC on Safari, etc.) — do not assume one format
  duration_ms               int,
  file_size_bytes           bigint,
  uploaded_at               timestamptz not null default now(),

  rating_status             text not null default 'pending'
                            check (rating_status in ('pending','rated','flagged_unclear','needs_second_rater')),
  is_reliability_subsample  boolean not null default false,

  primary_rating            boolean,
  primary_rater_id          uuid references researchers(id),
  primary_rated_at          timestamptz,

  secondary_rating          boolean,
  secondary_rater_id        uuid references researchers(id),
  secondary_rated_at        timestamptz,
  agreement                 boolean generated always as (primary_rating is not distinct from secondary_rating) stored,

  scheduled_deletion_at     timestamptz,
  deleted_at                timestamptz
);

alter table responses
  add constraint fk_responses_audio_recording
  foreign key (audio_recording_id) references audio_recordings(id);

-- Propagates a rating into responses.is_correct automatically —
-- enforced at the database layer so it can never desync from the
-- application, regardless of what writes the rating.
create or replace function propagate_audio_rating() returns trigger as $$
begin
  if NEW.primary_rating is distinct from OLD.primary_rating then
    update responses
    set is_correct = NEW.primary_rating,
        scored_by = 'human'
    where id = NEW.response_id;
  end if;
  return NEW;
end;
$$ language plpgsql;

create trigger trg_propagate_audio_rating
after update on audio_recordings
for each row
execute function propagate_audio_rating();

-- ============================================================
-- Scoring outputs (populated by offline analysis, not live logic, at this phase)
-- ============================================================
create table domain_score_results (
  id                      uuid primary key default gen_random_uuid(),
  participant_id          uuid not null references participants(id),
  session_id              uuid not null references sessions(id),
  domain                  text not null,
  raw_score               numeric,
  z_score                 numeric,
  threshold_used          numeric,
  flagged_deficit         boolean,
  scoring_method_version  text not null,
  computed_at             timestamptz not null default now()
);

create table criterion_classification (
  participant_id     uuid primary key references participants(id),
  q2_score           smallint,
  q3_score           smallint,
  item5_score        smallint,
  items6_10_sum      smallint,
  strong_count       smallint,
  weak_count         smallint,
  classification     text check (classification in
                      ('dyslexia_consistent','non_dyslexia_consistent','unclassified')),
  rule_version       text not null,
  computed_at        timestamptz not null default now()
);

-- ============================================================
-- ML export view — always current by construction (see design doc §"automatic ML pipeline")
-- ============================================================
create view ml_export_v1 as
select
  r.id                        as response_id,
  p.anonymized_code,
  p.class_grade,
  i.item_code,
  i.domain,
  i.response_format,
  r.response_latency_ms,
  r.input_modality,
  r.selected_option_key,
  r.typed_value,
  r.is_correct,
  r.scored_by,
  r.replay_count_instruction,
  r.replay_count_stimulus,
  r.submitted_at
from responses r
join sessions s on s.id = r.session_id
join participants p on p.id = s.participant_id
join items i on i.id = r.item_id
where r.is_superseded = false;

-- Explicit columns (not `LIKE ml_export_v1`) to avoid relying on
-- CREATE TABLE ... LIKE-from-a-view syntax that wasn't verified against
-- a live Postgres instance in this environment.
create table ml_snapshots (
  id                        uuid primary key default gen_random_uuid(),
  response_id               uuid,
  anonymized_code           text,
  class_grade               smallint,
  item_code                 text,
  domain                    text,
  response_format           text,
  response_latency_ms       double precision,
  input_modality            text,
  selected_option_key       text,
  typed_value               text,
  is_correct                boolean,
  scored_by                 text,
  replay_count_instruction  int,
  replay_count_stimulus     int,
  submitted_at              timestamptz,
  snapshot_taken_at         timestamptz not null default now()
);
-- Populate a snapshot before each real analysis run:
--   insert into ml_snapshots (response_id, anonymized_code, class_grade, item_code, domain,
--     response_format, response_latency_ms, input_modality, selected_option_key, typed_value,
--     is_correct, scored_by, replay_count_instruction, replay_count_stimulus, submitted_at)
--   select * from ml_export_v1;
