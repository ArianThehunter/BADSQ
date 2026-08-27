-- BADSQ Platform — Migration 0006
-- Fixes H1 (PUBLIC grant survived the 0005 revoke). Adds save_item_version() for
-- atomic item editing, matching submit_session()'s transaction pattern. Consolidates
-- the two overlapping SELECT policies on `sessions`.
--
-- UNTESTED against a live instance. Verify and report failures rather than patching.

-- ============================================================
-- H1: the 0005 revoke targeted anon/authenticated but the functions were still
-- executable via the PUBLIC grant every role inherits by default. Not currently
-- exploitable over HTTP (PostgREST does not expose trigger-returning functions as
-- RPCs), but the SQL-level privilege was real. Revoking from the actual source.
-- ============================================================
revoke execute on function propagate_audio_rating() from public;
revoke execute on function link_researcher_on_signup() from public;

-- ============================================================
-- Atomic item versioning, matching the pattern submit_session() already
-- established. p_old_item_id is NULL for a brand-new item; otherwise the item
-- being superseded. Options are replaced wholesale for the new version.
-- ============================================================
create or replace function save_item_version(
  p_old_item_id  uuid,
  p_item         jsonb,
  p_options      jsonb
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old_item     items%rowtype;
  v_new_item_id  uuid;
  v_item_code    text;
  v_new_version  int;
  v_option       jsonb;
begin
  if not can_manage_items() then
    raise exception 'save_item_version: caller lacks item-management permission';
  end if;

  if p_old_item_id is not null then
    select * into v_old_item from items where id = p_old_item_id;
    if not found then
      raise exception 'save_item_version: unknown item_id %', p_old_item_id;
    end if;
    v_item_code   := v_old_item.item_code;
    v_new_version := v_old_item.version + 1;
  else
    v_item_code   := p_item->>'item_code';
    v_new_version := 1;
  end if;

  insert into items (
    item_code, version, domain, subdomain, response_format,
    instruction_audio_path, stimulus_audio_path, stimulus_text,
    is_instruction_replayable, is_stimulus_replayable,
    correct_answer, scoring_mode, is_practice, is_scored, display_order,
    active, edited_by
  ) values (
    v_item_code, v_new_version,
    p_item->>'domain', p_item->>'subdomain', p_item->>'response_format',
    p_item->>'instruction_audio_path', p_item->>'stimulus_audio_path', p_item->>'stimulus_text',
    coalesce((p_item->>'is_instruction_replayable')::boolean, true),
    (p_item->>'is_stimulus_replayable')::boolean,
    p_item->>'correct_answer',
    p_item->>'scoring_mode',
    coalesce((p_item->>'is_practice')::boolean, false),
    coalesce((p_item->>'is_scored')::boolean, true),
    (p_item->>'display_order')::int,
    coalesce((p_item->>'active')::boolean, false),  -- default inactive; activation guard runs client-side before the caller sets true
    (select id from researchers where user_id = auth.uid())
  )
  returning id into v_new_item_id;

  for v_option in select * from jsonb_array_elements(p_options)
  loop
    insert into item_options (item_id, option_key, option_text, is_correct)
    values (
      v_new_item_id,
      v_option->>'option_key',
      v_option->>'option_text',
      coalesce((v_option->>'is_correct')::boolean, false)
    );
  end loop;

  if p_old_item_id is not null then
    update items set active = false where id = p_old_item_id;
  end if;

  return v_new_item_id;
end;
$$;

grant execute on function save_item_version(uuid, jsonb, jsonb) to authenticated;
revoke execute on function save_item_version(uuid, jsonb, jsonb) from anon, public;

-- ============================================================
-- Consolidate the two overlapping SELECT policies on `sessions`
-- (advisor: multiple_permissive_policies).
-- ============================================================
drop policy if exists sessions_select_own on sessions;
drop policy if exists sessions_select_researcher on sessions;

create policy sessions_select on sessions
  for select using (auth_uid = auth.uid() or is_researcher());
