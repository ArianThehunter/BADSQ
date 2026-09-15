-- 0027: a real 90-day retention schedule for participant audio.
--
-- POLICY HISTORY, because this has changed twice and the record should say so:
--   0001  schema built for deletion after the study -- audio_recordings was
--         deliberately split from responses so a recording could be destroyed
--         while the derived rating survived. scheduled_deletion_at/deleted_at
--         existed from the start and were NEVER written by any code.
--   (Sep 2026) retention changed to indefinite; the 90-day expiry on exported
--         audio links was removed in favour of a 10-year horizon.
--   NOW   reverted to deletion 90 days after upload, by decision of the
--         principal researcher.
--
-- WHAT THIS MIGRATION DOES AND DOES NOT DO
-- It makes the schedule real and visible: every recording now carries the date
-- its audio must be destroyed. It does NOT delete anything on its own --
-- removing a Storage object reliably means going through the Storage API, not
-- deleting a storage.objects row (that is how this project produced orphaned
-- blobs before). Deletion is therefore performed from the admin panel, against
-- the list this column defines, and stamps deleted_at when it succeeds.
--
-- THE RISK THIS CREATES, stated plainly: a recording deleted before it has
-- been rated is data lost permanently, and with a second rating now required
-- for the reliability subsample, BOTH passes must finish inside 90 days of the
-- participant's session. The admin panel surfaces unrated recordings
-- approaching their deletion date for exactly this reason.

alter table audio_recordings
  alter column scheduled_deletion_at set default (now() + interval '90 days');

-- Existing rows: schedule from their own upload time, not from now, so the
-- clock a parent was promised starts when the child actually recorded.
update audio_recordings
set scheduled_deletion_at = uploaded_at + interval '90 days'
where scheduled_deletion_at is null
  and deleted_at is null;

create index if not exists idx_audio_recordings_scheduled_deletion
  on audio_recordings(scheduled_deletion_at)
  where deleted_at is null;

comment on column audio_recordings.scheduled_deletion_at is
  'When this recording''s audio must be destroyed (upload + 90 days). Set '
  'automatically. Deletion itself is performed from the admin panel via the '
  'Storage API -- deleting a storage.objects row leaves the blob behind.';

comment on column audio_recordings.deleted_at is
  'When the audio file was actually destroyed. NULL means the file still '
  'exists. The row itself is kept forever: the rating, latency and item '
  'linkage are the research data and outlive the audio by design.';
