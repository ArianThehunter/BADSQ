-- BADSQ Platform — Migration 0007
-- Fixes I1 (participant audio uploads fail because INSERT...RETURNING requires a
-- satisfying SELECT policy, which badsq-audio never had for participants).
-- Also: auth_rls_initplan performance fixes, and a lightweight revision counter.
--
-- UNTESTED against a live instance. Verify with the exact Phase 2 Playwright Run 1
-- walkthrough (all six formats) before considering I1 closed.

-- ============================================================
-- I1: participants had an INSERT policy on badsq-audio but no SELECT policy.
-- Postgres RLS requires INSERT ... RETURNING to also satisfy a SELECT policy for
-- the row to be returned — Supabase Storage's upload endpoint always uses
-- RETURNING, so every real participant upload failed regardless of correct
-- session/auth/path. Documented Postgres behavior, confirmed against the
-- PostgreSQL mailing list and RLS docs before writing this fix.
--
-- Not gated on session status: the INSERT policy already governs whether a NEW
-- upload can happen; visibility of an already-legitimate upload shouldn't
-- additionally depend on whether the session has since completed.
-- ============================================================
create policy audio_select_own_session on storage.objects
  for select using (
    bucket_id = 'badsq-audio'
    and exists (
      select 1 from sessions s
      where s.auth_uid = auth.uid()
        and (storage.foldername(objects.name))[1] = s.id::text
    )
  );

-- ============================================================
-- auth_rls_initplan: wrap auth.uid() so it evaluates once per statement rather
-- than once per row.
-- ============================================================
drop policy if exists sessions_select on sessions;
create policy sessions_select on sessions
  for select using (auth_uid = (select auth.uid()) or is_researcher());

drop policy if exists participants_insert_own on participants;
create policy participants_insert_own on participants
  for insert with check (created_by_auth_uid = (select auth.uid()));

-- ============================================================
-- Lightweight revision signal, short of full attempt-history logging.
-- Response history stays one row per item (confirmed final scope, not deferred);
-- this is the cheap middle ground for "did the student change their mind before
-- locking in," without building the unused attempt_number/is_superseded path.
-- ============================================================
alter table responses add column if not exists selection_change_count int not null default 0;
