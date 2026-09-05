-- 0022: participant_summary_v1 — one row per participant.
--
-- Companion to full_export_v1 (one row per RESPONSE). Same data, different
-- grain: this one is for visualisation and cross-participant comparison,
-- where repeating demographics on all ~99 response rows gets in the way.
--
-- Deliberately SUMMARY columns per subdomain, not one column per item. An
-- item-level wide layout would be 300-500 columns and would break every time
-- an item is added, renumbered or retired — which has happened repeatedly in
-- this project. Subdomains are far more stable, so these ~70 columns stay
-- valid across item-bank edits. If per-item columns are ever needed, pivot
-- the long export instead (one line in pandas/R) rather than freezing the
-- item list into the schema.
--
-- A VIEW, not a table: this is derived data. A physical copy would drift out
-- of sync the moment a recording is re-rated or an item changes.
--
-- security_invoker = true, same as full_export_v1 — without it the view would
-- run as its creator and expose every participant to any authenticated
-- session, including a participant own anonymous one.

create view participant_summary_v1 with (security_invoker = true) as
select
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
  s.started_at as session_started_at,
  s.ended_at as session_ended_at,
  round((extract(epoch from (s.ended_at - s.started_at)) / 60.0)::numeric, 1) as session_minutes,
  count(r.id) as responses_total,
  count(*) filter (where ar.id is not null) as audio_total,
  count(*) filter (where ar.primary_verdict = 'correct') as audio_correct,
  count(*) filter (where ar.primary_verdict = 'incorrect') as audio_incorrect,
  count(*) filter (where ar.primary_verdict = 'unclear') as audio_unclear,
  count(*) filter (where ar.id is not null and ar.primary_verdict is null) as audio_unreviewed,
  round(avg(r.response_latency_from_first_ms)::numeric, 0) as mean_latency_ms_all,
  sum(coalesce(r.replay_count_stimulus, 0)) as replays_stimulus_total,
  sum(coalesce(r.replay_count_instruction, 0)) as replays_instruction_total,
  mode() within group (order by r.input_modality) as main_input_modality,
  count(*) filter (where i.subdomain = '1.1 Digit Span Forward') as d1_1_answered,
  round(avg(r.response_latency_from_first_ms) filter (where i.subdomain = '1.1 Digit Span Forward')::numeric, 0) as d1_1_mean_latency_ms,
  sum(coalesce(r.replay_count_stimulus, 0)) filter (where i.subdomain = '1.1 Digit Span Forward') as d1_1_replays,
  count(*) filter (where i.subdomain = '1.2 Digit Span Backward') as d1_2_answered,
  round(avg(r.response_latency_from_first_ms) filter (where i.subdomain = '1.2 Digit Span Backward')::numeric, 0) as d1_2_mean_latency_ms,
  sum(coalesce(r.replay_count_stimulus, 0)) filter (where i.subdomain = '1.2 Digit Span Backward') as d1_2_replays,
  count(*) filter (where i.subdomain = '1.3 Letter Span Forward') as d1_3_answered,
  round(avg(r.response_latency_from_first_ms) filter (where i.subdomain = '1.3 Letter Span Forward')::numeric, 0) as d1_3_mean_latency_ms,
  sum(coalesce(r.replay_count_stimulus, 0)) filter (where i.subdomain = '1.3 Letter Span Forward') as d1_3_replays,
  count(*) filter (where i.subdomain = '1.4 Letter Span Backward') as d1_4_answered,
  round(avg(r.response_latency_from_first_ms) filter (where i.subdomain = '1.4 Letter Span Backward')::numeric, 0) as d1_4_mean_latency_ms,
  sum(coalesce(r.replay_count_stimulus, 0)) filter (where i.subdomain = '1.4 Letter Span Backward') as d1_4_replays,
  count(*) filter (where i.subdomain = '2.1 Elision') as d2_1_answered,
  round(avg(r.response_latency_from_first_ms) filter (where i.subdomain = '2.1 Elision')::numeric, 0) as d2_1_mean_latency_ms,
  sum(coalesce(r.replay_count_stimulus, 0)) filter (where i.subdomain = '2.1 Elision') as d2_1_replays,
  count(*) filter (where i.subdomain = '2.2 Pseudoword Judgment') as d2_2_answered,
  round(avg(r.response_latency_from_first_ms) filter (where i.subdomain = '2.2 Pseudoword Judgment')::numeric, 0) as d2_2_mean_latency_ms,
  sum(coalesce(r.replay_count_stimulus, 0)) filter (where i.subdomain = '2.2 Pseudoword Judgment') as d2_2_replays,
  count(*) filter (where i.subdomain = '2.3 Syllable Segmentation') as d2_3_answered,
  round(avg(r.response_latency_from_first_ms) filter (where i.subdomain = '2.3 Syllable Segmentation')::numeric, 0) as d2_3_mean_latency_ms,
  sum(coalesce(r.replay_count_stimulus, 0)) filter (where i.subdomain = '2.3 Syllable Segmentation') as d2_3_replays,
  count(*) filter (where i.subdomain = '2.4 Blending') as d2_4_answered,
  round(avg(r.response_latency_from_first_ms) filter (where i.subdomain = '2.4 Blending')::numeric, 0) as d2_4_mean_latency_ms,
  sum(coalesce(r.replay_count_stimulus, 0)) filter (where i.subdomain = '2.4 Blending') as d2_4_replays,
  count(*) filter (where i.subdomain = '2.5 Onset/Coda Matching') as d2_5_answered,
  round(avg(r.response_latency_from_first_ms) filter (where i.subdomain = '2.5 Onset/Coda Matching')::numeric, 0) as d2_5_mean_latency_ms,
  sum(coalesce(r.replay_count_stimulus, 0)) filter (where i.subdomain = '2.5 Onset/Coda Matching') as d2_5_replays,
  count(*) filter (where i.subdomain = '2.6 Substitution') as d2_6_answered,
  round(avg(r.response_latency_from_first_ms) filter (where i.subdomain = '2.6 Substitution')::numeric, 0) as d2_6_mean_latency_ms,
  sum(coalesce(r.replay_count_stimulus, 0)) filter (where i.subdomain = '2.6 Substitution') as d2_6_replays,
  count(*) filter (where i.subdomain = '3.1 Rhyme Judgment') as d3_1_answered,
  round(avg(r.response_latency_from_first_ms) filter (where i.subdomain = '3.1 Rhyme Judgment')::numeric, 0) as d3_1_mean_latency_ms,
  sum(coalesce(r.replay_count_stimulus, 0)) filter (where i.subdomain = '3.1 Rhyme Judgment') as d3_1_replays,
  count(*) filter (where i.subdomain = '3.2 Confusion Self-report') as d3_2_answered,
  round(avg(r.response_latency_from_first_ms) filter (where i.subdomain = '3.2 Confusion Self-report')::numeric, 0) as d3_2_mean_latency_ms,
  sum(coalesce(r.replay_count_stimulus, 0)) filter (where i.subdomain = '3.2 Confusion Self-report') as d3_2_replays,
  count(*) filter (where i.subdomain = '4.1 Multiple Choice') as d4_1_answered,
  round(avg(r.response_latency_from_first_ms) filter (where i.subdomain = '4.1 Multiple Choice')::numeric, 0) as d4_1_mean_latency_ms,
  sum(coalesce(r.replay_count_stimulus, 0)) filter (where i.subdomain = '4.1 Multiple Choice') as d4_1_replays,
  count(*) filter (where i.subdomain = '4.2 Flash Judgment') as d4_2_answered,
  round(avg(r.response_latency_from_first_ms) filter (where i.subdomain = '4.2 Flash Judgment')::numeric, 0) as d4_2_mean_latency_ms,
  sum(coalesce(r.replay_count_stimulus, 0)) filter (where i.subdomain = '4.2 Flash Judgment') as d4_2_replays,
  count(*) filter (where i.subdomain = '5.1 Spoonerisms') as d5_1_answered,
  round(avg(r.response_latency_from_first_ms) filter (where i.subdomain = '5.1 Spoonerisms')::numeric, 0) as d5_1_mean_latency_ms,
  sum(coalesce(r.replay_count_stimulus, 0)) filter (where i.subdomain = '5.1 Spoonerisms') as d5_1_replays,
  count(*) filter (where i.subdomain = '5.2 Jumbled-sentence Reading') as d5_2_answered,
  round(avg(r.response_latency_from_first_ms) filter (where i.subdomain = '5.2 Jumbled-sentence Reading')::numeric, 0) as d5_2_mean_latency_ms,
  sum(coalesce(r.replay_count_stimulus, 0)) filter (where i.subdomain = '5.2 Jumbled-sentence Reading') as d5_2_replays,
  count(*) filter (where i.domain = 'criterion') as sr_answered,
  round(avg(r.response_latency_from_first_ms) filter (where i.domain = 'criterion')::numeric, 0) as sr_mean_latency_ms

from participants p
  join sessions s on s.participant_id = p.id
  join responses r on r.session_id = s.id and r.is_superseded = false
  join items i on i.id = r.item_id
  left join audio_recordings ar on ar.response_id = r.id
  left join consent_records cr on cr.participant_id = p.id
group by p.id, s.id, cr.id;
