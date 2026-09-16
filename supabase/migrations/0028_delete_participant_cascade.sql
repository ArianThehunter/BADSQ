-- 0028: researcher-initiated deletion of a single participant's entire record.
--
-- WHY THIS EXISTS
-- The instrument is about to be circulated by researchers rather than
-- administered one-to-one in front of a supervisor. That opens a gap the
-- platform previously had no answer for: a session submitted by someone who was
-- not a genuine participant -- a curious adult, a student filling it twice, a
-- researcher's own test run that reached the end. Those are identifiable after
-- the fact by listening to the audio, but until now there was no way to remove
-- one without hand-writing DELETEs in the SQL editor, in the right order,
-- against live participant data. That is exactly the sort of task that goes
-- wrong at 1am.
--
-- WHAT IT DOES NOT DO
-- There is no soft delete and no undo. A removed participant is gone from
-- `participants`, `sessions`, `responses`, `consent_records` and
-- `audio_recordings`, and the function hands back the storage paths so the
-- caller can delete the objects too. The confirmation step lives in the admin
-- UI (type the participant's code to arm the button), not here.
--
-- ORDERING
-- Every foreign key in this schema is NO ACTION -- nothing cascades. The delete
-- order below is therefore load-bearing, child-to-parent:
--   audio_recordings -> responses -> consent_records -> sessions -> participants
--
-- WHY SECURITY DEFINER
-- Participants sign in anonymously, so they hold the SAME Postgres role
-- (`authenticated`) as researchers do. Role alone proves nothing here. The
-- function therefore runs as its owner and does its own authorisation against
-- the `researchers` allowlist; an anonymous participant has no row there, so
-- coalesce(..., false) refuses them. search_path is pinned so a caller cannot
-- shadow `researchers` with their own table.
--
-- Gated on can_manage_items rather than a new column: it is already the
-- highest privilege in the allowlist, already used for destructive item-bank
-- work, and adding a fourth flag would mean another manual dashboard step for
-- every existing account.

create or replace function delete_participant_cascade(p_participant_id uuid)
returns setof text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_can   boolean;
  v_paths text[];
begin
  select r.can_manage_items into v_can
  from researchers r
  where r.user_id = auth.uid();

  if coalesce(v_can, false) is not true then
    raise exception 'Not authorised: deleting participant data requires can_manage_items';
  end if;

  if not exists (select 1 from participants p where p.id = p_participant_id) then
    raise exception 'No such participant: %', p_participant_id;
  end if;

  -- Capture the storage paths BEFORE the rows that name them are deleted.
  -- Storage objects live outside Postgres, so they cannot be removed in this
  -- transaction; the caller deletes them and the paths are the only record of
  -- what to remove.
  select coalesce(array_agg(ar.storage_path), '{}')
    into v_paths
  from audio_recordings ar
  join responses r on r.id = ar.response_id
  join sessions  s on s.id = r.session_id
  where s.participant_id = p_participant_id;

  delete from audio_recordings ar
   using responses r, sessions s
   where ar.response_id = r.id
     and r.session_id   = s.id
     and s.participant_id = p_participant_id;

  delete from responses r
   using sessions s
   where r.session_id = s.id
     and s.participant_id = p_participant_id;

  delete from consent_records cr
   where cr.participant_id = p_participant_id;

  -- A consent row transcribed from the paper form may be keyed by
  -- assigned_code alone, with participant_id still NULL (see 0025). Those
  -- would otherwise survive as orphans pointing at a session about to vanish.
  delete from consent_records cr
   using sessions s
   where cr.assigned_code = s.assigned_code
     and s.participant_id = p_participant_id;

  delete from sessions s
   where s.participant_id = p_participant_id;

  delete from participants p
   where p.id = p_participant_id;

  return query select unnest(v_paths);
end;
$$;

comment on function delete_participant_cascade(uuid) is
  'Permanently removes one participant and every row derived from their '
  'session. Returns the badsq-audio storage paths the caller must then delete. '
  'Requires researchers.can_manage_items. No undo.';

-- `anon` is revoked explicitly, not just via PUBLIC: Supabase's default
-- privileges grant EXECUTE on new functions to anon directly, so revoking
-- PUBLIC alone leaves it callable by an unauthenticated client. The function's
-- own allowlist check would still refuse, but a destructive SECURITY DEFINER
-- routine should not be reachable in the first place.
--
-- Participants are NOT affected: anonymous sign-in puts them in `authenticated`,
-- not `anon`, and the researchers check is what stops them.
revoke all on function delete_participant_cascade(uuid) from public;
revoke all on function delete_participant_cascade(uuid) from anon;
grant execute on function delete_participant_cascade(uuid) to authenticated;
