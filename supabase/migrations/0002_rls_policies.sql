-- BADSQ Platform — Row-Level Security policies
-- Two identities in this system:
--   1. Participants: Supabase anonymous auth (no email/password), scoped to their own session
--   2. Researchers: real magic-link accounts, checked against the `researchers` allowlist

alter table participants enable row level security;
alter table consent_records enable row level security;
alter table items enable row level security;
alter table item_options enable row level security;
alter table sessions enable row level security;
alter table responses enable row level security;
alter table audio_recordings enable row level security;
alter table domain_score_results enable row level security;
alter table criterion_classification enable row level security;
alter table researchers enable row level security;

-- Helper: is the current user a researcher, and can they manage items?
create or replace function is_researcher() returns boolean as $$
  select exists (select 1 from researchers where user_id = auth.uid());
$$ language sql security definer stable;

create or replace function can_manage_items() returns boolean as $$
  select exists (select 1 from researchers where user_id = auth.uid() and can_manage_items = true);
$$ language sql security definer stable;

create or replace function can_rate() returns boolean as $$
  select exists (select 1 from researchers where user_id = auth.uid() and can_rate = true);
$$ language sql security definer stable;

-- ============================================================
-- Sessions — a participant's anonymous auth session may create
-- and later fill in only its own row.
-- ============================================================
create policy sessions_insert_own on sessions
  for insert
  with check (auth_uid = auth.uid());

create policy sessions_update_own_in_progress on sessions
  for update
  using (auth_uid = auth.uid() and status = 'in_progress')
  with check (auth_uid = auth.uid());

create policy sessions_select_researcher on sessions
  for select
  using (is_researcher());

-- ============================================================
-- Participants — created at final submit, tied to the same
-- anonymous auth identity that owns the session being completed.
-- ============================================================
create policy participants_insert_own on participants
  for insert
  with check (created_by_auth_uid = auth.uid());

create policy participants_select_researcher on participants
  for select
  using (is_researcher());

-- ============================================================
-- Responses / audio_recordings — writable only by the anonymous
-- session that owns them (checked via the parent session's auth_uid),
-- readable by researchers. Rating fields on audio_recordings are
-- updatable only by researchers with can_rate.
-- ============================================================
create policy responses_insert_via_own_session on responses
  for insert
  with check (
    exists (select 1 from sessions s where s.id = session_id and s.auth_uid = auth.uid())
  );

create policy responses_select_researcher on responses
  for select
  using (is_researcher());

create policy audio_insert_via_own_session on audio_recordings
  for insert
  with check (
    exists (
      select 1 from responses r
      join sessions s on s.id = r.session_id
      where r.id = response_id and s.auth_uid = auth.uid()
    )
  );

create policy audio_select_researcher on audio_recordings
  for select
  using (is_researcher());

create policy audio_update_rater on audio_recordings
  for update
  using (can_rate())
  with check (can_rate());

-- ============================================================
-- Item bank — publicly readable (participants need it to take the
-- test), writable only by researchers with can_manage_items.
-- ============================================================
create policy items_select_all on items
  for select
  using (active = true or is_researcher());

create policy items_write_manager on items
  for insert
  with check (can_manage_items());

create policy items_update_manager on items
  for update
  using (can_manage_items())
  with check (can_manage_items());

create policy item_options_select_all on item_options
  for select
  using (true);

create policy item_options_write_manager on item_options
  for all
  using (can_manage_items())
  with check (can_manage_items());

-- ============================================================
-- Consent, scoring outputs, researcher table — researcher-only throughout.
-- ============================================================
create policy consent_researcher_all on consent_records
  for all
  using (is_researcher())
  with check (is_researcher());

create policy domain_scores_researcher_all on domain_score_results
  for all
  using (is_researcher())
  with check (is_researcher());

create policy criterion_classification_researcher_all on criterion_classification
  for all
  using (is_researcher())
  with check (is_researcher());

create policy researchers_self_select on researchers
  for select
  using (user_id = auth.uid());
