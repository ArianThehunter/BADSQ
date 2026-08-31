-- BADSQ Platform — Migration 0010
-- Decision change: correctness for AUDIO_RECORD responses will be decided later by an
-- offline model run against the raw stored audio, not by a human's live binary
-- correct/incorrect click. Automatic scoring for MCQ_TAP/BINARY_TAP/NUMERIC_KEYPAD is
-- UNCHANGED -- that comparison is deterministic against a known answer key, not a
-- judgment call, and stopping it would throw away information the raw-data approach
-- doesn't need thrown away.
--
-- This migration:
--   1. Adds a free-text `notes` column to audio_recordings, replacing the binary
--      Correct/Incorrect button in RatingQueue with a review/notes workflow.
--   2. Neuters propagate_audio_rating() so it no longer copies a rating onto
--      responses.is_correct/scored_by -- kept as a function (not dropped) so this
--      decision stays visible in the schema history rather than disappearing.
--   3. Backfills any already-human-scored rows back to NULL (defensive; no
--      AUDIO_RECORD item has been active yet, so this is expected to affect 0 rows).
--
-- primary_rating/secondary_rating/agreement/is_reliability_subsample are left in
-- place, unused by the new UI -- they were built for inter-rater kappa measurement,
-- which is a different question (human-vs-human agreement) from what feeds
-- responses.is_correct, and may still be useful for that purpose later.

alter table audio_recordings add column if not exists notes text;

create or replace function propagate_audio_rating() returns trigger as $$
begin
  -- Intentionally a no-op as of migration 0010 -- see header comment above.
  -- Previously copied NEW.primary_rating onto responses.is_correct/scored_by.
  return NEW;
end;
$$ language plpgsql
set search_path = public;

revoke execute on function propagate_audio_rating() from public;

update responses
set is_correct = null, scored_by = null
where scored_by = 'human';
