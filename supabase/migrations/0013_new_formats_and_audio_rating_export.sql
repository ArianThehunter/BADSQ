-- BADSQ Platform — Migration 0013
--   1. Adds two new response formats required by the latest question paper:
--      FLASH_JUDGMENT (Domain 1.2 — word flashes 2s, then correct/incorrect buttons)
--      LETTER_SPAN (Domain 3.3/3.4 — tap letters in order from an 8-letter grid)
--   2. Restores audio correctness marking -- NOT as live inline scoring (responses.is_correct
--      stays NULL for everything, per migration 0012), but as a researcher-only annotation on
--      audio_recordings.primary_rating (a column that already existed, unused since migration
--      0010) surfaced in full_export_v1 alongside the recording's storage path, so a researcher
--      can mark correct/incorrect from the Rating Queue and see both in the CSV export.

alter table items drop constraint items_response_format_check;
alter table items add constraint items_response_format_check
  check (response_format in
    ('MCQ_TAP','BINARY_TAP','TRI_TAP','NUMERIC_KEYPAD','LIKERT_5','AUDIO_RECORD',
     'FLASH_JUDGMENT','LETTER_SPAN'));

-- CREATE OR REPLACE VIEW cannot insert a column in the middle of the existing list
-- (Postgres treats that as a rename of every column after it) -- drop and recreate.
drop view if exists full_export_v1;

create view full_export_v1
with (security_invoker = true)
as
select
  r.id                              as response_id,
  p.anonymized_code,
  p.class_grade,
  p.age_years,
  p.age_months,
  p.gender,
  p.home_area,
  cr.q1_doctor_eval,
  cr.q1_school_eval,
  cr.q1_not_sure,
  cr.q2_extra_primary_support,
  cr.q3_family_history,
  i.item_code,
  i.domain,
  i.subdomain,
  i.response_format,
  i.scoring_mode,
  r.selected_option_key,
  r.typed_value,
  r.is_correct,
  r.scored_by,
  ar.storage_path                  as audio_storage_path,
  ar.mime_type                     as audio_mime_type,
  ar.duration_ms                   as audio_duration_ms,
  ar.notes                         as audio_notes,
  ar.primary_rating                as audio_marked_correct,
  ar.is_reliability_subsample,
  r.stimulus_first_end_client_ts,
  r.stimulus_last_end_client_ts,
  r.response_client_ts,
  r.response_latency_from_first_ms,
  r.response_latency_from_last_ms,
  r.input_modality,
  r.viewport_width,
  r.viewport_height,
  r.replay_count_instruction,
  r.replay_count_stimulus,
  r.technical_retry_count,
  r.selection_change_count,
  r.attempt_number,
  r.is_superseded,
  s.id                              as session_id,
  s.started_at                     as session_started_at,
  s.ended_at                       as session_ended_at,
  r.submitted_at
from responses r
join sessions s on s.id = r.session_id
join participants p on p.id = s.participant_id
join items i on i.id = r.item_id
left join audio_recordings ar on ar.response_id = r.id
left join consent_records cr on cr.participant_id = p.id
where r.is_superseded = false;

grant select on full_export_v1 to authenticated;
