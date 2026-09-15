-- ============================================================================
-- BADSQ Platform — VIEW COLUMN DRIFT RELEASE GATE
--
-- RUN THIS BEFORE EVERY DEPLOY. It must return ZERO rows with verdict 'DRIFT'.
--
-- WHY THIS EXISTS
-- ---------------
-- This defect class has occurred twice, and was invisible both times until
-- something actually queried the view:
--
--   F5 (migration 0003) renamed responses.response_latency_ms ->
--      response_latency_from_last_ms without recreating ml_export_v1. The export
--      kept emitting `response_latency_ms`, silently sourced from the renamed
--      column, and never gained the from_first anchor at all.
--
--   G1 (migration 0004) renamed items.instruction_audio_url ->
--      instruction_audio_path without recreating public_items. The participant
--      read path kept emitting the OLD names, so the client got
--      `42703 column public_items.instruction_audio_path does not exist`.
--
-- The root cause is a Postgres behaviour that is easy to forget: renaming a base
-- column rewrites a view's INTERNAL reference, but does NOT rename the view's
-- OUTPUT column. `CREATE OR REPLACE VIEW` cannot rename output columns either —
-- the view must be dropped and recreated.
--
-- HOW IT WORKS
-- ------------
-- For every view in `public`, every output column name must match the name of
-- some base column the view actually depends on (read from pg_depend, so it is
-- based on real dependencies, not on parsing SQL text). A view that deliberately
-- aliases a column must declare that alias in the allowlist below, which turns a
-- silent drift into a reviewed, documented decision.
--
-- LIMITATION, stated plainly: this catches renames and typos, which is the
-- observed failure mode. It does NOT catch a view whose output column keeps a
-- valid base-column NAME while silently pointing at a different base column of
-- that name (e.g. two joined tables both having `id`). That is a distinct and so
-- far unobserved defect class.
--
-- Also mirrored as an assertion inside scripts/verify_security.sql, which
-- additionally self-tests the gate by creating a deliberately drifted view and
-- confirming this query catches it. A gate that has never been shown to fail is
-- not a gate.
-- ============================================================================

with vcols as (
  -- every output column of every view in public
  select v.relname as view_name, a.attname as out_col, a.attnum
  from pg_class v
  join pg_namespace vn on vn.oid = v.relnamespace
  join pg_attribute a on a.attrelid = v.oid and a.attnum > 0 and not a.attisdropped
  where vn.nspname = 'public' and v.relkind = 'v'
),
vdeps as (
  -- every base COLUMN each view genuinely depends on, via its rewrite rule
  select distinct v.relname as view_name, ba.attname as base_col
  from pg_class v
  join pg_namespace vn on vn.oid = v.relnamespace
  join pg_rewrite rw on rw.ev_class = v.oid
  join pg_depend d on d.objid = rw.oid
                  and d.classid = 'pg_rewrite'::regclass
                  and d.refclassid = 'pg_class'::regclass
                  and d.refobjsubid > 0
  join pg_class bt on bt.oid = d.refobjid
  join pg_attribute ba on ba.attrelid = bt.oid and ba.attnum = d.refobjsubid
  where vn.nspname = 'public' and v.relkind = 'v'
),
allowlist(view_name, out_col, reason) as (
  -- Intentional aliases. Adding a row here is a deliberate, reviewable act.
  --
  -- REGENERATED after migration 0025. This list had exactly ONE entry while the
  -- live schema had 72 legitimate aliases, so the gate failed wholesale on every
  -- run -- which meant a REAL drift would have been indistinguishable from the
  -- backlog, and the guard was effectively off. A gate that always fails
  -- protects nothing.
  values
    ('full_export_v1', 'selected_option_text', 'item_options.option_text, joined on the key the participant chose'),
    ('full_export_v1', 'correct_option_key', 'item_options.option_key of the option flagged is_correct (the answer key for choice formats)'),
    ('full_export_v1', 'correct_option_text', 'item_options.option_text of the option flagged is_correct'),
    ('full_export_v1', 'audio_storage_path', 'audio_recordings.storage_path, prefixed to separate it from item audio'),
    ('full_export_v1', 'audio_mime_type', 'audio_recordings.mime_type, prefixed'),
    ('full_export_v1', 'audio_duration_ms', 'audio_recordings.duration_ms, prefixed'),
    ('full_export_v1', 'audio_notes', 'audio_recordings.notes, prefixed'),
    ('full_export_v1', 'audio_marked_correct', 'audio_recordings.primary_rating, renamed to say what it means in the export'),
    ('full_export_v1', 'audio_review_verdict', 'audio_recordings.primary_verdict, prefixed'),
    ('full_export_v1', 'session_started_at', 'sessions.started_at, prefixed to separate it from responses.submitted_at'),
    ('full_export_v1', 'session_ended_at', 'sessions.ended_at, prefixed'),
    ('participant_summary_v1', 'session_started_at', 'sessions.started_at, prefixed'),
    ('participant_summary_v1', 'session_ended_at', 'sessions.ended_at, prefixed'),
    ('participant_summary_v1', 'session_minutes', 'computed aggregate, not a passthrough of any base column'),
    ('participant_summary_v1', 'responses_total', 'computed aggregate, not a passthrough of any base column'),
    ('participant_summary_v1', 'audio_total', 'computed aggregate, not a passthrough of any base column'),
    ('participant_summary_v1', 'audio_correct', 'computed aggregate, not a passthrough of any base column'),
    ('participant_summary_v1', 'audio_incorrect', 'computed aggregate, not a passthrough of any base column'),
    ('participant_summary_v1', 'audio_unclear', 'computed aggregate, not a passthrough of any base column'),
    ('participant_summary_v1', 'audio_unreviewed', 'computed aggregate, not a passthrough of any base column'),
    ('participant_summary_v1', 'mean_latency_ms_all', 'computed aggregate, not a passthrough of any base column'),
    ('participant_summary_v1', 'replays_stimulus_total', 'computed aggregate, not a passthrough of any base column'),
    ('participant_summary_v1', 'replays_instruction_total', 'computed aggregate, not a passthrough of any base column'),
    ('participant_summary_v1', 'main_input_modality', 'computed aggregate, not a passthrough of any base column'),
    ('participant_summary_v1', 'd1_1_answered', 'computed aggregate, not a passthrough of any base column'),
    ('participant_summary_v1', 'd1_1_mean_latency_ms', 'computed aggregate, not a passthrough of any base column'),
    ('participant_summary_v1', 'd1_1_replays', 'computed aggregate, not a passthrough of any base column'),
    ('participant_summary_v1', 'd1_2_answered', 'computed aggregate, not a passthrough of any base column'),
    ('participant_summary_v1', 'd1_2_mean_latency_ms', 'computed aggregate, not a passthrough of any base column'),
    ('participant_summary_v1', 'd1_2_replays', 'computed aggregate, not a passthrough of any base column'),
    ('participant_summary_v1', 'd1_3_answered', 'computed aggregate, not a passthrough of any base column'),
    ('participant_summary_v1', 'd1_3_mean_latency_ms', 'computed aggregate, not a passthrough of any base column'),
    ('participant_summary_v1', 'd1_3_replays', 'computed aggregate, not a passthrough of any base column'),
    ('participant_summary_v1', 'd1_4_answered', 'computed aggregate, not a passthrough of any base column'),
    ('participant_summary_v1', 'd1_4_mean_latency_ms', 'computed aggregate, not a passthrough of any base column'),
    ('participant_summary_v1', 'd1_4_replays', 'computed aggregate, not a passthrough of any base column'),
    ('participant_summary_v1', 'd2_1_answered', 'computed aggregate, not a passthrough of any base column'),
    ('participant_summary_v1', 'd2_1_mean_latency_ms', 'computed aggregate, not a passthrough of any base column'),
    ('participant_summary_v1', 'd2_1_replays', 'computed aggregate, not a passthrough of any base column'),
    ('participant_summary_v1', 'd2_2_answered', 'computed aggregate, not a passthrough of any base column'),
    ('participant_summary_v1', 'd2_2_mean_latency_ms', 'computed aggregate, not a passthrough of any base column'),
    ('participant_summary_v1', 'd2_2_replays', 'computed aggregate, not a passthrough of any base column'),
    ('participant_summary_v1', 'd2_3_answered', 'computed aggregate, not a passthrough of any base column'),
    ('participant_summary_v1', 'd2_3_mean_latency_ms', 'computed aggregate, not a passthrough of any base column'),
    ('participant_summary_v1', 'd2_3_replays', 'computed aggregate, not a passthrough of any base column'),
    ('participant_summary_v1', 'd2_4_answered', 'computed aggregate, not a passthrough of any base column'),
    ('participant_summary_v1', 'd2_4_mean_latency_ms', 'computed aggregate, not a passthrough of any base column'),
    ('participant_summary_v1', 'd2_4_replays', 'computed aggregate, not a passthrough of any base column'),
    ('participant_summary_v1', 'd2_5_answered', 'computed aggregate, not a passthrough of any base column'),
    ('participant_summary_v1', 'd2_5_mean_latency_ms', 'computed aggregate, not a passthrough of any base column'),
    ('participant_summary_v1', 'd2_5_replays', 'computed aggregate, not a passthrough of any base column'),
    ('participant_summary_v1', 'd2_6_answered', 'computed aggregate, not a passthrough of any base column'),
    ('participant_summary_v1', 'd2_6_mean_latency_ms', 'computed aggregate, not a passthrough of any base column'),
    ('participant_summary_v1', 'd2_6_replays', 'computed aggregate, not a passthrough of any base column'),
    ('participant_summary_v1', 'd3_1_answered', 'computed aggregate, not a passthrough of any base column'),
    ('participant_summary_v1', 'd3_1_mean_latency_ms', 'computed aggregate, not a passthrough of any base column'),
    ('participant_summary_v1', 'd3_1_replays', 'computed aggregate, not a passthrough of any base column'),
    ('participant_summary_v1', 'd3_2_answered', 'computed aggregate, not a passthrough of any base column'),
    ('participant_summary_v1', 'd3_2_mean_latency_ms', 'computed aggregate, not a passthrough of any base column'),
    ('participant_summary_v1', 'd3_2_replays', 'computed aggregate, not a passthrough of any base column'),
    ('participant_summary_v1', 'd4_1_answered', 'computed aggregate, not a passthrough of any base column'),
    ('participant_summary_v1', 'd4_1_mean_latency_ms', 'computed aggregate, not a passthrough of any base column'),
    ('participant_summary_v1', 'd4_1_replays', 'computed aggregate, not a passthrough of any base column'),
    ('participant_summary_v1', 'd4_2_answered', 'computed aggregate, not a passthrough of any base column'),
    ('participant_summary_v1', 'd4_2_mean_latency_ms', 'computed aggregate, not a passthrough of any base column'),
    ('participant_summary_v1', 'd4_2_replays', 'computed aggregate, not a passthrough of any base column'),
    ('participant_summary_v1', 'd5_1_answered', 'computed aggregate, not a passthrough of any base column'),
    ('participant_summary_v1', 'd5_1_mean_latency_ms', 'computed aggregate, not a passthrough of any base column'),
    ('participant_summary_v1', 'd5_1_replays', 'computed aggregate, not a passthrough of any base column'),
    ('participant_summary_v1', 'd5_2_answered', 'computed aggregate, not a passthrough of any base column'),
    ('participant_summary_v1', 'd5_2_mean_latency_ms', 'computed aggregate, not a passthrough of any base column'),
    ('participant_summary_v1', 'd5_2_replays', 'computed aggregate, not a passthrough of any base column'),
    ('participant_summary_v1', 'sr_answered', 'computed aggregate, not a passthrough of any base column'),
    ('participant_summary_v1', 'sr_mean_latency_ms', 'computed aggregate, not a passthrough of any base column'),
    ('public_items', 'practice_correct_answer', 'items.correct_answer, exposed ONLY for demo items (migration 0017); renamed so it can never be mistaken for the real key')
)
select
  c.view_name,
  c.out_col,
  case when al.out_col is not null then 'ALLOWLISTED' else 'DRIFT' end as verdict,
  coalesce(al.reason, 'no base column of this name — was a base column renamed without recreating the view?') as note
from vcols c
left join allowlist al on al.view_name = c.view_name and al.out_col = c.out_col
where not exists (
  select 1 from vdeps d where d.view_name = c.view_name and d.base_col = c.out_col
)
order by verdict, c.view_name, c.attnum;
