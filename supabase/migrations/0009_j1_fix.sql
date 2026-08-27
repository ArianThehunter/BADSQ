-- BADSQ Platform — Migration 0009
-- Fixes J1: adds pinned search_path = public to reliability_subsample_rate(),
-- restoring the G3 invariant across all public functions.

create or replace function reliability_subsample_rate() returns double precision
language sql
immutable
set search_path = public
as $$
  select 0.20;
$$;
