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
  values ('ml_export_v1', 'response_id', 'deliberate alias of responses.id, to disambiguate in the flat export')
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
