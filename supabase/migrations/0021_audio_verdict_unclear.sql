-- 0021: three-way reviewer verdict on participant audio — correct / incorrect
-- / unclear.
--
-- `primary_rating` is a boolean, so it can only carry two states plus NULL,
-- and NULL already means "not reviewed yet". Overloading NULL for "unclear"
-- would make those two indistinguishable — the difference matters, because
-- "nobody has listened yet" is outstanding work while "listened, could not
-- tell" is a finished review whose audio is unusable. So the verdict gets its
-- own column and `primary_rating` stays in sync underneath it.
--
-- primary_rating remains the boolean the existing export column
-- `audio_marked_correct` reads (correct -> true, incorrect -> false,
-- unclear -> NULL), so nothing already built on that column changes meaning;
-- `audio_review_verdict` is added alongside it for the unambiguous value.
alter table audio_recordings
  add column if not exists primary_verdict text
  check (primary_verdict in ('correct', 'incorrect', 'unclear'));

comment on column audio_recordings.primary_verdict is
  'Reviewer verdict: correct | incorrect | unclear. NULL = not yet reviewed. '
  'Authoritative; primary_rating is the two-state projection of this.';

-- Backfill from the ratings already made (16 of them at time of writing).
update audio_recordings
set primary_verdict = case when primary_rating then 'correct' else 'incorrect' end
where primary_verdict is null and primary_rating is not null;

-- Expose the verdict in the export next to the existing boolean.
drop view if exists full_export_v1;
create view full_export_v1 with (security_invoker = true) as
select r.id as response_id,
  p.anonymized_code, p.class_grade, p.age_years, p.age_months, p.gender, p.home_area,
  cr.q1_doctor_eval, cr.q1_school_eval, cr.q1_not_sure,
  cr.q2_extra_primary_support, cr.q3_family_history,
  i.item_code, i.domain, i.subdomain, i.response_format, i.scoring_mode,
  r.selected_option_key, r.typed_value, r.is_correct, r.scored_by,
  ar.storage_path as audio_storage_path,
  ar.mime_type as audio_mime_type,
  ar.duration_ms as audio_duration_ms,
  ar.notes as audio_notes,
  ar.primary_rating as audio_marked_correct,
  ar.primary_verdict as audio_review_verdict,
  ar.is_reliability_subsample,
  r.stimulus_first_end_client_ts, r.stimulus_last_end_client_ts, r.response_client_ts,
  r.response_latency_from_first_ms, r.response_latency_from_last_ms,
  r.input_modality, r.viewport_width, r.viewport_height,
  r.replay_count_instruction, r.replay_count_stimulus,
  r.technical_retry_count, r.selection_change_count,
  r.attempt_number, r.is_superseded,
  s.id as session_id, s.started_at as session_started_at, s.ended_at as session_ended_at,
  r.submitted_at
from responses r
  join sessions s on s.id = r.session_id
  join participants p on p.id = s.participant_id
  join items i on i.id = r.item_id
  left join audio_recordings ar on ar.response_id = r.id
  left join consent_records cr on cr.participant_id = p.id
where r.is_superseded = false;
