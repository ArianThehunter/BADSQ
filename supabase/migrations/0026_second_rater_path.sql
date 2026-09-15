-- 0026: make the reliability subsample actually collectable.
--
-- The 20% subsample has been assigned correctly since migration 0008 --
-- randomly, by the database, at submission, before any rater has listened.
-- That is the methodologically load-bearing half, and it was right. The other
-- half was missing entirely: there was no way to RECORD a second rating, so
-- the flags accumulated and Cohen's kappa could never be computed from them.
--
-- The blinding that makes the second rating meaningful lives in the data
-- layer, not here: listSecondRatingQueue() in src/lib/adminData.ts does not
-- select primary_verdict, primary_rating, notes, or participant identity. A
-- second rater who can see the first judgement is anchored by it, and the
-- resulting coefficient measures compliance rather than agreement.

-- ---------------------------------------------------------------------------
-- 1. A tri-state secondary verdict, matching the primary
-- ---------------------------------------------------------------------------
-- primary_verdict gained correct/incorrect/unclear in migration 0021 but
-- secondary_rating stayed a bare boolean, so a second rater could not express
-- "unclear" -- and kappa computed over unequal category sets is not kappa.
alter table audio_recordings
  add column if not exists secondary_verdict text;

alter table audio_recordings
  drop constraint if exists audio_recordings_secondary_verdict_check;
alter table audio_recordings
  add constraint audio_recordings_secondary_verdict_check
  check (secondary_verdict is null or secondary_verdict in ('correct','incorrect','unclear'));

-- ---------------------------------------------------------------------------
-- 2. The two ratings must come from two different people
-- ---------------------------------------------------------------------------
-- Enforced here rather than only in the UI: a coefficient of agreement between
-- one person and themselves is meaningless, and a UI-only rule is one refactor
-- away from silently lapsing.
alter table audio_recordings
  drop constraint if exists audio_recordings_distinct_raters;
alter table audio_recordings
  add constraint audio_recordings_distinct_raters
  check (
    secondary_rater_id is null
    or primary_rater_id is null
    or secondary_rater_id <> primary_rater_id
  );

-- ---------------------------------------------------------------------------
-- 3. Drop the `agreement` generated column
-- ---------------------------------------------------------------------------
-- It read `primary_rating is not distinct from secondary_rating` over two
-- booleans that are BOTH NULL when a recording is unrated OR judged unclear.
-- So an entirely unrated pair evaluated to `true` -- "agreement" -- which is
-- worse than absent: an analyst reading the schema would take it at face
-- value. Agreement over three categories is an analysis computation; the
-- platform's job is to hand over both verdicts intact, which it now does.
alter table audio_recordings drop column if exists agreement;

-- ---------------------------------------------------------------------------
-- 4. Surface both ratings in the export
-- ---------------------------------------------------------------------------
drop view if exists full_export_v1;

create view full_export_v1
with (security_invoker = true) as
select
  r.id                                as response_id,
  p.anonymized_code,
  p.class_grade,
  p.age_years,
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
  i.is_scored,
  r.selected_option_key,
  so.option_text                      as selected_option_text,
  r.typed_value,
  i.correct_answer,
  co.option_key                       as correct_option_key,
  co.option_text                      as correct_option_text,
  ar.storage_path                     as audio_storage_path,
  ar.mime_type                        as audio_mime_type,
  ar.duration_ms                      as audio_duration_ms,
  ar.notes                            as audio_notes,
  ar.primary_rating                   as audio_marked_correct,
  ar.primary_verdict                  as audio_review_verdict,
  ar.secondary_verdict                as audio_second_verdict,
  ar.is_reliability_subsample,
  r.client_time_origin_ms,
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
  s.id                                as session_id,
  s.started_at                        as session_started_at,
  s.ended_at                          as session_ended_at,
  r.submitted_at
from responses r
  join sessions s      on s.id = r.session_id
  join participants p  on p.id = s.participant_id
  join items i         on i.id = r.item_id
  left join audio_recordings ar on ar.response_id = r.id
  left join consent_records cr  on cr.participant_id = p.id
  left join item_options so on so.item_id = i.id and so.option_key = r.selected_option_key
  left join item_options co on co.item_id = i.id and co.is_correct
where r.is_superseded = false;

grant select on full_export_v1 to authenticated;

comment on view full_export_v1 is
  'One row per response, self-sufficient for analysis. audio_review_verdict is '
  'the primary rater''s judgement; audio_second_verdict is the independent '
  'second rating, present only for the ~20%% reliability subsample. Compute '
  'agreement between those two columns -- the platform deliberately does not.';
