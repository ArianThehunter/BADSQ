-- BADSQ Platform — participant data reset
--
-- Deletes every participant-generated row (sessions, responses, audio
-- recording metadata, consent records, and the two empty analysis tables)
-- so real data collection starts from zero. Does NOT touch the item bank
-- (items, item_options), domain_intros, or the researchers allowlist —
-- none of that is participant data.
--
-- This is a one-time operational script, not a schema migration — it is
-- intentionally kept out of supabase/migrations/ so it never runs again on
-- a fresh `supabase migration up`.
--
-- Run as `postgres` in the Supabase SQL Editor. Read the counts it prints
-- before and after; if the "before" counts don't match what you expect,
-- stop and check rather than proceeding.
--
-- IMPORTANT: this clears database rows only. Uploaded audio *files* live in
-- Storage (bucket `badsq-audio`) and are not reliably removed by deleting
-- storage.objects rows from SQL — see the note at the end of this file.

begin;

-- ---- Before counts ----------------------------------------------------
select
  (select count(*) from audio_recordings)         as audio_recordings,
  (select count(*) from responses)                as responses,
  (select count(*) from consent_records)          as consent_records,
  (select count(*) from domain_score_results)     as domain_score_results,
  (select count(*) from criterion_classification) as criterion_classification,
  (select count(*) from sessions)                 as sessions,
  (select count(*) from participants)             as participants;

-- ---- Delete in FK-safe order -------------------------------------------
-- audio_recordings.response_id -> responses(id)
delete from audio_recordings;

-- responses.session_id -> sessions(id), responses.item_id -> items(id)
delete from responses;

-- consent_records.participant_id -> participants(id)
-- consent_records.assigned_code   -> sessions(assigned_code)  (migration 0005)
delete from consent_records;

-- domain_score_results / criterion_classification -> participants(id), sessions(id)
-- (both are empty in current production data — deleted for idempotency)
delete from domain_score_results;
delete from criterion_classification;

-- sessions.participant_id -> participants(id)
delete from sessions;

delete from participants;

-- ---- After counts -- should all be zero --------------------------------
select
  (select count(*) from audio_recordings)         as audio_recordings,
  (select count(*) from responses)                as responses,
  (select count(*) from consent_records)          as consent_records,
  (select count(*) from domain_score_results)     as domain_score_results,
  (select count(*) from criterion_classification) as criterion_classification,
  (select count(*) from sessions)                 as sessions,
  (select count(*) from participants)             as participants;

commit;

-- ============================================================
-- Storage cleanup — do this separately, in the dashboard.
--
-- Deleting audio_recordings rows above does NOT delete the underlying
-- audio files in the `badsq-audio` Storage bucket. This is the same
-- mechanism behind the 3 orphaned objects already found in production
-- (DOCUMENTATION_NOTES.md §4.8): a deleted row does not imply a deleted
-- blob, and vice versa.
--
-- To actually clear the recordings:
--   1. Supabase dashboard -> Storage -> badsq-audio bucket.
--   2. Select all objects and delete them there (this goes through the
--      Storage API, which removes both the metadata row and the file).
--
-- Do NOT just run `delete from storage.objects where bucket_id =
-- 'badsq-audio'` in the SQL editor — that removes the metadata row but
-- has been observed to leave the actual file in the bucket, producing
-- more orphans, not fewer.
--
-- After clearing the bucket, a quick sanity check from the SQL editor:
--   select count(*) from storage.objects where bucket_id = 'badsq-audio';
-- should return 0.
-- ============================================================
