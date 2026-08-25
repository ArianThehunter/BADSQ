-- ============================================================================
-- BADSQ Platform — security verification suite (v2, post-migration 0004)
--
-- Proves the RLS / privilege model actually holds. Run as `postgres` (Supabase
-- SQL editor, or the MCP execute_sql tool). Re-runnable: PART 1 rebuilds all
-- fixtures from scratch.
--
-- v2 CHANGES vs the Phase 0 suite. Migration 0004 changed two contracts, so the
-- corresponding assertions changed with them. These are updates to match
-- intended new behaviour, NOT relaxations to make failures disappear:
--   * Sessions are created by start_session(), which issues assigned_code.
--     submit_session() now takes anonymized_code from the session row, so a new
--     assertion proves a client-supplied code is IGNORED (tamper resistance).
--   * Participants may now read their OWN sessions row (F7 fix), so the
--     "0 rows visible" assertion became "own rows only, never another's".
-- Everything else keeps its original expectation. Assertions that were expected
-- to fail before 0004 (F1, F3, F4, F5, F6) now expect success; if they still
-- fail, the fix did not work.
--
-- METHOD NOTE. Assertions that need a caller identity use the same mechanism
-- PostgREST and storage-api use internally:
--     set_config('role', 'authenticated', true)
--     set_config('request.jwt.claims', '{"sub":"<uid>","role":"authenticated"}', true)
-- so auth.uid() resolves exactly as it does for a real API request. This is a
-- faithful test of the POLICY. It is not a test of the HTTP transport; the
-- anon-role HTTP path is covered separately by scripts/verify-security.mjs.
--
-- Fixture identities:
--   P1    participant browser session 1  (anonymous auth user)
--   P2    participant browser session 2  (anonymous auth user)
--   UOUT  authenticated user NOT on the researchers allowlist
--   R1    authenticated user ON the allowlist, can_rate = can_manage_items = true
--
-- Read results with:  select * from verify.results order by id;
-- Tear down with PART 11.
-- ============================================================================


-- ============================================================================
-- PART 1 — fixtures and helpers
-- ============================================================================
drop schema if exists verify cascade;
create schema verify;

create table verify.results (
  id        serial primary key,
  section   text,
  assertion text,
  expected  text,
  actual    text,
  pass      boolean
);

create table verify.ids (k text primary key, v uuid);
insert into verify.ids (k, v) values
  ('P1',    '11111111-1111-4111-8111-111111111111'),
  ('P2',    '22222222-2222-4222-8222-222222222222'),
  ('UOUT',  '33333333-3333-4333-8333-333333333333'),
  ('R1',    '44444444-4444-4444-8444-444444444444'),
  ('IMCQ1', 'b0000000-0000-4000-8000-000000000001'),
  ('IMCQ2', 'b0000000-0000-4000-8000-000000000002'),
  ('INUM1', 'b0000000-0000-4000-8000-000000000003'),
  ('INUM2', 'b0000000-0000-4000-8000-000000000004'),
  ('IAUD',  'b0000000-0000-4000-8000-000000000005'),
  ('ID4',   'b0000000-0000-4000-8000-000000000006');

-- Session ids are no longer fixed constants: they are issued by start_session().
create table verify.sess (k text primary key, id uuid, code text);

create or replace function verify.uid(p_k text) returns uuid
language sql stable as $fn$ select v from verify.ids where k = p_k $fn$;

create or replace function verify.sid(p_k text) returns uuid
language sql stable as $fn$ select id from verify.sess where k = p_k $fn$;

create or replace function verify.assert(
  p_section text, p_assertion text, p_expected text, p_actual text, p_pass boolean
) returns void language sql as $fn$
  insert into verify.results (section, assertion, expected, actual, pass)
  values (p_section, p_assertion, p_expected, p_actual, p_pass);
$fn$;

create or replace function verify.become(p_uid uuid) returns void
language sql as $fn$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims',
                    json_build_object('sub', p_uid::text, 'role', 'authenticated',
                                      'aud', 'authenticated')::text, true);
$fn$;

create or replace function verify.become_anon() returns void
language sql as $fn$
  select set_config('role', 'anon', true),
         set_config('request.jwt.claims', '{"role":"anon"}', true);
$fn$;

create or replace function verify.unbecome() returns void
language sql as $fn$
  select set_config('role', 'postgres', true),
         set_config('request.jwt.claims', '', true);
$fn$;

grant usage on schema verify to anon, authenticated;
grant select, insert on verify.results to anon, authenticated;
grant usage, select on sequence verify.results_id_seq to anon, authenticated;
grant select on verify.ids, verify.sess to anon, authenticated;
grant execute on all functions in schema verify to anon, authenticated;

-- ---- clean any prior run's data (children first) ----
delete from audio_recordings where response_id in (
  select r.id from responses r join sessions s on s.id = r.session_id
  where s.auth_uid in (select v from verify.ids where k in ('P1','P2')));
delete from responses where session_id in (
  select id from sessions where auth_uid in (select v from verify.ids where k in ('P1','P2')));
-- NOTE: storage.objects rows are NOT cleaned here. Supabase installs a
-- BEFORE DELETE trigger (storage.protect_delete) that rejects direct SQL
-- deletion even for `postgres`. The storage assertions use a do-and-undo
-- pattern (nested PL/pgSQL block + forced rollback) so no row persists.
delete from sessions where auth_uid in (select v from verify.ids where k in ('P1','P2'));
delete from consent_records where assigned_code like 'BADSQ-%';
delete from participants where created_by_auth_uid in (select v from verify.ids where k in ('P1','P2'));
delete from item_options where item_id in (select v from verify.ids where k like 'I%');
delete from items where id in (select v from verify.ids where k like 'I%');
delete from researchers where email like '%@badsq-verify.test';
delete from auth.users where id in (select v from verify.ids where k in ('P1','P2','UOUT','R1'));

-- Pre-provision the allowlist row FIRST so trg_link_researcher_on_signup has
-- something to link when R1's auth user is created (this also tests that trigger).
insert into researchers (email, can_rate, can_manage_items)
values ('rater1@badsq-verify.test', true, true);

insert into auth.users (id, instance_id, aud, role, email, is_anonymous, created_at, updated_at)
values
  (verify.uid('P1'),   '00000000-0000-0000-0000-000000000000','authenticated','authenticated', null,                         true,  now(), now()),
  (verify.uid('P2'),   '00000000-0000-0000-0000-000000000000','authenticated','authenticated', null,                         true,  now(), now()),
  (verify.uid('UOUT'), '00000000-0000-0000-0000-000000000000','authenticated','authenticated', 'outsider@badsq-verify.test', false, now(), now()),
  (verify.uid('R1'),   '00000000-0000-0000-0000-000000000000','authenticated','authenticated', 'rater1@badsq-verify.test',   false, now(), now());

-- Item bank fixtures. The Bangla stimulus_text doubles as a Unicode round-trip probe.
insert into items (id, item_code, version, domain, subdomain, response_format, stimulus_text,
                   instruction_audio_path, stimulus_audio_path,
                   is_instruction_replayable, is_stimulus_replayable, correct_answer,
                   scoring_mode, is_practice, is_scored, display_order, active) values
  (verify.uid('IMCQ1'),'VT.MCQ1',1,'2','2.1 Elision','MCQ_TAP','বাংলা শব্দ','instr/vt-mcq1.mp3','stim/vt-mcq1.mp3', true, true, null,'auto',false,true,10,true),
  (verify.uid('IMCQ2'),'VT.MCQ2',1,'2','2.1 Elision','MCQ_TAP','দ্বিতীয় প্রশ্ন','instr/vt-mcq2.mp3',null, true, true, null,'auto',false,true,20,true),
  (verify.uid('INUM1'),'VT.NUM1',1,'3','3.1 Digit span','NUMERIC_KEYPAD',null,null,null, true, false,'42','auto',false,true,30,true),
  (verify.uid('INUM2'),'VT.NUM2',1,'3','3.1 Digit span','NUMERIC_KEYPAD',null,null,null, true, false,'5','auto',false,true,40,true),
  (verify.uid('IAUD'), 'VT.AUD1',1,'5','5.2 Spoonerisms','AUDIO_RECORD',null,null,null, true, true, null,'human_rated',false,true,50,true),
  -- Domain 4 replayability is still undecided, so this one stays NULL on purpose.
  (verify.uid('ID4'),  'VT.D4',  1,'4','4.1 Rhyme','MCQ_TAP','ছন্দ',null,null, true, null, null,'auto',false,true,60,true);

insert into item_options (item_id, option_key, option_text, is_correct) values
  (verify.uid('IMCQ1'),'A','সঠিক উত্তর',true),(verify.uid('IMCQ1'),'B','ভুল ১',false),
  (verify.uid('IMCQ1'),'C','ভুল ২',false),(verify.uid('IMCQ1'),'D','ভুল ৩',false),
  (verify.uid('IMCQ2'),'A','সঠিক উত্তর',true),(verify.uid('IMCQ2'),'B','ভুল ১',false),
  (verify.uid('IMCQ2'),'C','ভুল ২',false),(verify.uid('IMCQ2'),'D','ভুল ৩',false),
  (verify.uid('ID4'),'A','হ্যাঁ',true),(verify.uid('ID4'),'B','না',false);


-- ============================================================================
-- PART 2 — start_session(): server-issued participant codes  [NEW in 0004]
-- ============================================================================

-- 2.1 P1 starts a session through the RPC.
do $$
declare v_id uuid; v_code text; v_actual text; v_pass boolean := false;
begin
  begin
    perform verify.become(verify.uid('P1'));
    select out_session_id, out_assigned_code into v_id, v_code from start_session();
    perform verify.unbecome();
    insert into verify.sess values ('S1', v_id, v_code);
    v_actual := 'session '||coalesce(v_id::text,'NULL')||', code '||coalesce(v_code,'NULL');
    v_pass := v_id is not null and v_code is not null;
  exception when others then
    perform verify.unbecome();
    v_actual := SQLSTATE||': '||SQLERRM;
  end;
  perform verify.assert('start_session','start_session() as P1 returns a session id and an assigned code',
    'both non-null', v_actual, v_pass);
end $$;

-- 2.2 The row it created is owned by P1, in_progress, and carries the code.
do $$
declare v_owner uuid; v_status text; v_code text; v_pass boolean;
begin
  select auth_uid, status, assigned_code into v_owner, v_status, v_code
  from sessions where id = verify.sid('S1');
  v_pass := v_owner = verify.uid('P1') and v_status = 'in_progress'
            and v_code = (select code from verify.sess where k='S1');
  perform verify.assert('start_session','session row created by start_session()',
    'owned by P1, status=in_progress, assigned_code persisted',
    'owner='||(v_owner = verify.uid('P1'))||', status='||coalesce(v_status,'NULL')||', code='||coalesce(v_code,'NULL'),
    v_pass);
end $$;

-- 2.3 Code format: BADSQ-XXXX-XXXX using an alphabet with no I, O, 0 or 1.
do $$
declare v_code text; v_pass boolean;
begin
  select code into v_code from verify.sess where k='S1';
  v_pass := v_code ~ '^BADSQ-[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}$';
  perform verify.assert('start_session','assigned_code format excludes ambiguous glyphs I/O/0/1 (hand-transcribed onto paper)',
    'matches ^BADSQ-[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}$', coalesce(v_code,'NULL'), v_pass);
end $$;

-- 2.4 Unauthenticated anon cannot start a session.
do $$
declare v_id uuid; v_code text; v_actual text; v_pass boolean := false;
begin
  begin
    perform verify.become_anon();
    select out_session_id, out_assigned_code into v_id, v_code from start_session();
    v_actual := 'ACCEPTED -- issued '||coalesce(v_code,'NULL');
  exception when others then v_pass := true; v_actual := SQLSTATE||': '||SQLERRM;
  end;
  perform verify.unbecome();
  perform verify.assert('start_session','start_session() as unauthenticated anon','rejected', v_actual, v_pass);
end $$;

-- 2.5 Codes are distinct across repeated issuance.
do $$
declare v_n int; v_d int;
begin
  perform verify.become(verify.uid('P2'));
  create temp table verify_codes as select out_assigned_code as c from start_session();
  for i in 1..24 loop
    insert into verify_codes select out_assigned_code from start_session();
  end loop;
  perform verify.unbecome();
  select count(*), count(distinct c) into v_n, v_d from verify_codes;
  perform verify.assert('start_session','25 consecutively issued codes are distinct',
    '25 distinct', v_d||' distinct of '||v_n, v_d = v_n);
  -- keep one of P2's sessions as the "other participant" fixture
  insert into verify.sess
    select 'S2', s.id, s.assigned_code from sessions s
    where s.auth_uid = verify.uid('P2') order by s.started_at limit 1;
  drop table verify_codes;
end $$;

-- 2.6 A second session for P1, used by the storage assertions.
do $$
declare v_id uuid; v_code text;
begin
  perform verify.become(verify.uid('P1'));
  select out_session_id, out_assigned_code into v_id, v_code from start_session();
  perform verify.unbecome();
  insert into verify.sess values ('S4', v_id, v_code);
  perform verify.assert('start_session','second session for P1 (storage fixture)',
    'created', 'session '||v_id::text, v_id is not null);
end $$;


-- ============================================================================
-- PART 3 — session ownership and isolation
-- ============================================================================
do $$
declare v_ok boolean := false; v_err text;
begin
  begin
    perform verify.become(verify.uid('P1'));
    insert into sessions (auth_uid) values (verify.uid('P1'));
    v_ok := true;
  exception when others then v_err := SQLSTATE||': '||SQLERRM;
  end;
  perform verify.unbecome();
  perform verify.assert('sessions','P1 inserts its OWN sessions row directly (auth_uid = auth.uid())',
    'INSERT succeeds', coalesce('ERROR '||v_err,'INSERT succeeded'), v_ok);
end $$;

do $$
declare v_ok boolean := false; v_err text;
begin
  begin
    perform verify.become(verify.uid('P1'));
    insert into sessions (auth_uid) values (verify.uid('P2'));
    v_err := 'INSERT unexpectedly succeeded';
  exception when others then v_ok := true; v_err := SQLSTATE||': '||SQLERRM;
  end;
  perform verify.unbecome();
  perform verify.assert('sessions','P1 CANNOT insert a sessions row claiming auth_uid = P2',
    'INSERT rejected by RLS', v_err, v_ok);
end $$;

do $$
declare v_cnt int;
begin
  perform verify.become(verify.uid('P1'));
  select count(*) into v_cnt from sessions where id = verify.sid('S2');
  perform verify.unbecome();
  perform verify.assert('sessions','P1 reads P2 session row S2 directly',
    '0 rows', v_cnt||' rows', v_cnt = 0);
end $$;

-- CHANGED BY 0004 (F7 fix): a participant may now see its OWN rows, and only those.
do $$
declare v_seen int; v_own int; v_total int; v_other int;
begin
  select count(*) into v_total from sessions;
  select count(*) into v_own from sessions where auth_uid = verify.uid('P1');
  perform verify.become(verify.uid('P1'));
  select count(*) into v_seen from sessions;
  select count(*) into v_other from sessions where auth_uid <> verify.uid('P1');
  perform verify.unbecome();
  perform verify.assert('sessions','P1 SELECT on sessions sees its own rows and no one else''s (table holds '||v_total||')',
    v_own||' own rows, 0 belonging to others',
    v_seen||' visible, '||v_other||' of them another participant''s',
    v_seen = v_own and v_other = 0);
end $$;

do $$
declare v_cnt int;
begin
  perform verify.become(verify.uid('P1'));
  with u as (update sessions set status='abandoned' where id = verify.sid('S2') returning 1)
  select count(*) into v_cnt from u;
  perform verify.unbecome();
  perform verify.assert('sessions','P1 UPDATEs P2 session S2 (set status=abandoned)',
    '0 rows affected', v_cnt||' rows affected', v_cnt = 0);
end $$;

do $$
declare v_cnt int; v_total int;
begin
  select count(*) into v_total from sessions;
  perform verify.become(verify.uid('R1'));
  select count(*) into v_cnt from sessions;
  perform verify.unbecome();
  perform verify.assert('sessions','Allowlisted researcher R1 SELECTs sessions',
    v_total||' rows (all)', v_cnt||' rows', v_cnt = v_total);
end $$;


-- ============================================================================
-- PART 4 — answer keys must never reach a participant, by ANY route
-- 0004 restored the base-table SELECT grant to `authenticated`, so RLS is now
-- the only thing separating participants from researchers. That makes the
-- base-table assertions MORE important, not less.
-- ============================================================================
do $$
declare v_txt text; v_cnt int; v_actual text; v_pass boolean := false;
begin
  begin
    perform verify.become(verify.uid('P1'));
    select count(*) into v_cnt from items;
    select correct_answer into v_txt from items where id = verify.uid('INUM1');
    v_actual := v_cnt||' item rows visible; correct_answer = '||coalesce(v_txt,'<none>');
    v_pass := v_cnt = 0 and v_txt is null;
  exception when others then v_pass := true; v_actual := SQLSTATE||': '||SQLERRM;
  end;
  perform verify.unbecome();
  perform verify.assert('answer_keys','participant SELECT items base table (grant restored by 0004; real correct_answer is 42)',
    '0 rows, no value leaked -- RLS must be the separator', v_actual, v_pass);
end $$;

do $$
declare v_b boolean; v_cnt int; v_actual text; v_pass boolean := false;
begin
  begin
    perform verify.become(verify.uid('P1'));
    select count(*) into v_cnt from item_options;
    select is_correct into v_b from item_options where item_id = verify.uid('IMCQ1') and option_key='A';
    v_actual := v_cnt||' option rows visible; is_correct = '||coalesce(v_b::text,'<none>');
    v_pass := v_cnt = 0 and v_b is null;
  exception when others then v_pass := true; v_actual := SQLSTATE||': '||SQLERRM;
  end;
  perform verify.unbecome();
  perform verify.assert('answer_keys','participant SELECT item_options base table (real is_correct is true)',
    '0 rows, no value leaked', v_actual, v_pass);
end $$;

do $$
declare v_txt text; v_blocked boolean := false; v_actual text;
begin
  begin
    perform verify.become_anon();
    select correct_answer into v_txt from items where id = verify.uid('INUM1');
    v_actual := 'LEAKED value = '||coalesce(v_txt,'<null>');
  exception when others then v_blocked := true; v_actual := SQLSTATE||': '||SQLERRM;
  end;
  perform verify.unbecome();
  perform verify.assert('answer_keys','anon SELECT items.correct_answer (base table)',
    'blocked', v_actual, v_blocked);
end $$;

-- F1 FIX: the participant read path must now WORK.
do $$
declare v_cnt int; v_actual text; v_pass boolean := false;
begin
  begin
    perform verify.become(verify.uid('P1'));
    select count(*) into v_cnt from public_items;
    v_actual := v_cnt||' rows returned'; v_pass := v_cnt = 6;
  exception when others then v_actual := SQLSTATE||': '||SQLERRM;
  end;
  perform verify.unbecome();
  perform verify.assert('answer_keys','F1 FIX: participant SELECT from public_items (6 active items)',
    '6 rows', v_actual, v_pass);
end $$;

do $$
declare v_cnt int; v_actual text; v_pass boolean := false;
begin
  begin
    perform verify.become(verify.uid('P1'));
    select count(*) into v_cnt from public_item_options;
    v_actual := v_cnt||' rows returned'; v_pass := v_cnt = 10;
  exception when others then v_actual := SQLSTATE||': '||SQLERRM;
  end;
  perform verify.unbecome();
  perform verify.assert('answer_keys','F1 FIX: participant SELECT from public_item_options (10 option rows)',
    '10 rows', v_actual, v_pass);
end $$;

do $$
declare v_cnt int; v_actual text; v_pass boolean := false;
begin
  begin
    perform verify.become_anon();
    select count(*) into v_cnt from public_items;
    v_actual := v_cnt||' rows returned'; v_pass := v_cnt = 6;
  exception when others then v_actual := SQLSTATE||': '||SQLERRM;
  end;
  perform verify.unbecome();
  perform verify.assert('answer_keys','F1 FIX: anon SELECT from public_items (pre-sign-in bootstrap)',
    '6 rows', v_actual, v_pass);
end $$;

do $$
declare v_has boolean;
begin
  select exists(select 1 from information_schema.columns
    where table_schema='public' and table_name='public_items' and column_name='correct_answer') into v_has;
  perform verify.assert('answer_keys','public_items view definition exposes correct_answer?',
    'no such column', case when v_has then 'column PRESENT' else 'column absent' end, not v_has);
  select exists(select 1 from information_schema.columns
    where table_schema='public' and table_name='public_item_options' and column_name='is_correct') into v_has;
  perform verify.assert('answer_keys','public_item_options view definition exposes is_correct?',
    'no such column', case when v_has then 'column PRESENT' else 'column absent' end, not v_has);
end $$;

-- Positive controls: researchers MUST be able to read the key to edit the bank.
do $$
declare v_txt text; v_actual text; v_pass boolean := false;
begin
  begin
    perform verify.become(verify.uid('R1'));
    select correct_answer into v_txt from items where id = verify.uid('INUM1');
    v_actual := coalesce(v_txt,'<null>'); v_pass := (v_txt = '42');
  exception when others then v_actual := SQLSTATE||': '||SQLERRM;
  end;
  perform verify.unbecome();
  perform verify.assert('answer_keys','F1 FIX / POSITIVE CONTROL: researcher SELECT items.correct_answer',
    '42 -- admin item-bank editor needs this', v_actual, v_pass);
end $$;

do $$
declare v_cnt int; v_actual text; v_pass boolean := false;
begin
  begin
    perform verify.become(verify.uid('R1'));
    select count(*) into v_cnt from items;
    v_actual := v_cnt||' rows'; v_pass := v_cnt = 6;
  exception when others then v_actual := SQLSTATE||': '||SQLERRM;
  end;
  perform verify.unbecome();
  perform verify.assert('answer_keys','F1 FIX / POSITIVE CONTROL: researcher SELECT count(*) from items',
    '6 rows', v_actual, v_pass);
end $$;

-- NEW after the 0004 column rename: does the participant read path still expose
-- the audio columns under the names the client will ask for?
do $$
declare v_base text; v_view text; v_pass boolean;
begin
  select coalesce(string_agg(column_name, ', ' order by ordinal_position),'(none)') into v_base
  from information_schema.columns
  where table_schema='public' and table_name='items' and column_name like '%audio%';
  select coalesce(string_agg(column_name, ', ' order by ordinal_position),'(none)') into v_view
  from information_schema.columns
  where table_schema='public' and table_name='public_items' and column_name like '%audio%';
  v_pass := v_base = v_view;
  perform verify.assert('answer_keys','public_items audio column names match the renamed base table',
    'view matches base: '||v_base, 'view exposes: '||v_view, v_pass);
end $$;


-- ============================================================================
-- PART 5 — export surfaces
-- ============================================================================
do $$
declare v_cnt int; v_blocked boolean := false; v_actual text;
begin
  begin
    perform verify.become_anon();
    select count(*) into v_cnt from ml_export_v1;
    v_actual := 'READABLE -- '||v_cnt||' rows';
  exception when others then v_blocked := true; v_actual := SQLSTATE||': '||SQLERRM;
  end;
  perform verify.unbecome();
  perform verify.assert('export','anon SELECT from ml_export_v1','blocked', v_actual, v_blocked);
end $$;

do $$
declare v_cnt int; v_safe boolean := false; v_actual text;
begin
  begin
    perform verify.become(verify.uid('P1'));
    select count(*) into v_cnt from ml_export_v1;
    v_actual := v_cnt||' rows'; v_safe := (v_cnt = 0);
  exception when others then v_safe := true; v_actual := SQLSTATE||': '||SQLERRM;
  end;
  perform verify.unbecome();
  perform verify.assert('export','authenticated participant SELECT from ml_export_v1',
    'blocked or 0 rows', v_actual, v_safe);
end $$;

-- F3 FIX
do $$
declare v_rls boolean;
begin
  select relrowsecurity into v_rls from pg_class c join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relname='ml_snapshots';
  perform verify.assert('export','F3 FIX: ml_snapshots has RLS enabled','RLS enabled',
    case when v_rls then 'enabled' else 'NOT ENABLED' end, v_rls);
end $$;

do $$
declare v_cnt int; v_actual text; v_safe boolean := false;
begin
  insert into ml_snapshots (anonymized_code, class_grade, item_code, is_correct)
  values ('SNAPSHOT-CANARY', 7, 'VT.MCQ1', true);
  begin
    perform verify.become_anon();
    select count(*) into v_cnt from ml_snapshots where anonymized_code='SNAPSHOT-CANARY';
    v_actual := 'READABLE -- '||v_cnt||' canary row(s) visible to anon'; v_safe := (v_cnt = 0);
  exception when others then v_safe := true; v_actual := SQLSTATE||': '||SQLERRM;
  end;
  perform verify.unbecome();
  perform verify.assert('export','F3 FIX: anon SELECT from ml_snapshots (holds the flattened export)',
    'blocked or 0 rows', v_actual, v_safe);
end $$;

do $$
declare v_ins boolean := false; v_del int := -1; v_actual text; v_safe boolean := false;
begin
  begin
    perform verify.become_anon();
    insert into ml_snapshots (anonymized_code, class_grade) values ('ANON-INJECTED', 6);
    v_ins := true;
    with d as (delete from ml_snapshots where anonymized_code='SNAPSHOT-CANARY' returning 1)
    select count(*) into v_del from d;
    perform verify.unbecome();
    raise exception using errcode='ZZ001', message='__UNDO__';
  exception when others then
    perform verify.unbecome();
    if SQLERRM <> '__UNDO__' then
      v_safe := true; v_actual := SQLSTATE||': '||SQLERRM;
    else
      v_actual := 'INSERT succeeded='||v_ins||'; DELETE removed '||v_del||' snapshot row(s)';
    end if;
  end;
  perform verify.assert('export','F3 FIX: anon INSERT/DELETE on ml_snapshots','blocked', v_actual, v_safe);
end $$;

-- A non-allowlisted authenticated user holds the grant but must fail RLS.
do $$
declare v_cnt int; v_ins text; v_safe boolean := false; v_actual text;
begin
  begin
    perform verify.become(verify.uid('UOUT'));
    select count(*) into v_cnt from ml_snapshots;
    begin
      insert into ml_snapshots (anonymized_code, class_grade) values ('UOUT-INJECTED', 6);
      v_ins := 'INSERT SUCCEEDED';
    exception when others then v_ins := 'INSERT '||SQLSTATE;
    end;
    v_actual := v_cnt||' rows visible; '||v_ins;
    v_safe := v_cnt = 0 and v_ins <> 'INSERT SUCCEEDED';
  exception when others then v_safe := true; v_actual := SQLSTATE||': '||SQLERRM;
  end;
  perform verify.unbecome();
  perform verify.assert('export','non-allowlisted authenticated user reads/writes ml_snapshots',
    '0 rows and INSERT rejected', v_actual, v_safe);
end $$;

delete from ml_snapshots;

-- F5 FIX
do $$
declare v_cols text; v_pass boolean;
begin
  select coalesce(string_agg(column_name,', ' order by ordinal_position),'(none)') into v_cols
  from information_schema.columns
  where table_schema='public' and table_name='ml_export_v1' and column_name like '%latenc%';
  v_pass := v_cols like '%from_first%' and v_cols like '%from_last%';
  perform verify.assert('export','F5 FIX: ml_export_v1 exposes BOTH latency anchors',
    'response_latency_from_first_ms and response_latency_from_last_ms', v_cols, v_pass);
end $$;

do $$
declare v_view text; v_snap text; v_pass boolean;
begin
  select coalesce(string_agg(column_name,',' order by column_name),'') into v_view
  from information_schema.columns where table_schema='public' and table_name='ml_export_v1';
  select coalesce(string_agg(column_name,',' order by column_name),'') into v_snap
  from information_schema.columns where table_schema='public' and table_name='ml_snapshots'
    and column_name not in ('id','snapshot_taken_at','snapshot_label');
  v_pass := v_view = v_snap;
  perform verify.assert('export','ml_snapshots columns match ml_export_v1 (snapshot insert must line up)',
    'identical column sets',
    case when v_pass then 'identical' else 'view=['||v_view||'] snapshot=['||v_snap||']' end, v_pass);
end $$;


-- ============================================================================
-- PART 6 — participant confidentiality
-- ============================================================================
do $$
declare v_cnt int; v_total int; v_safe boolean := false; v_actual text;
begin
  select count(*) into v_total from participants;
  begin
    perform verify.become(verify.uid('UOUT'));
    select count(*) into v_cnt from participants;
    v_actual := v_cnt||' rows visible'; v_safe := (v_cnt = 0);
  exception when others then v_safe := true; v_actual := SQLSTATE||': '||SQLERRM;
  end;
  perform verify.unbecome();
  perform verify.assert('participants','non-allowlisted authenticated user SELECT participants (table holds '||v_total||' rows)',
    '0 rows', v_actual, v_safe);
end $$;

do $$
declare v_cnt int; v_safe boolean := false; v_actual text;
begin
  begin
    perform verify.become_anon();
    select count(*) into v_cnt from participants;
    v_actual := v_cnt||' rows visible'; v_safe := (v_cnt = 0);
  exception when others then v_safe := true; v_actual := SQLSTATE||': '||SQLERRM;
  end;
  perform verify.unbecome();
  perform verify.assert('participants','anon SELECT participants','0 rows', v_actual, v_safe);
end $$;

do $$
declare v_cnt int; v_safe boolean := false; v_actual text;
begin
  begin
    perform verify.become(verify.uid('UOUT'));
    select count(*) into v_cnt from researchers;
    v_actual := v_cnt||' rows visible'; v_safe := (v_cnt = 0);
  exception when others then v_safe := true; v_actual := SQLSTATE||': '||SQLERRM;
  end;
  perform verify.unbecome();
  perform verify.assert('participants','non-allowlisted authenticated user SELECT researchers (allowlist has 1 row)',
    '0 rows', v_actual, v_safe);
end $$;

do $$
declare v_r int; v_a int; v_c int; v_safe boolean; v_actual text;
begin
  perform verify.become(verify.uid('UOUT'));
  select count(*) into v_r from responses;
  select count(*) into v_a from audio_recordings;
  select count(*) into v_c from consent_records;
  perform verify.unbecome();
  v_actual := 'responses='||v_r||', audio_recordings='||v_a||', consent_records='||v_c;
  v_safe := (v_r = 0 and v_a = 0 and v_c = 0);
  perform verify.assert('participants','non-allowlisted authenticated user SELECT responses/audio/consent',
    'all 0 rows', v_actual, v_safe);
end $$;


-- ============================================================================
-- PART 7 — submit_session(): happy path, server-side scoring, code linkage
-- ============================================================================
do $$
declare v_pid uuid; v_actual text; v_pass boolean := false; v_payload jsonb;
begin
  v_payload := jsonb_build_array(
    jsonb_build_object('item_id', verify.uid('IMCQ1')::text, 'selected_option_key','A',
      'input_modality','touch','viewport_width',390,'viewport_height',844,
      'stimulus_first_end_client_ts', 1000.5, 'stimulus_last_end_client_ts', 4200.25,
      'response_latency_from_first_ms', 3500.75, 'response_latency_from_last_ms', 301.0,
      'replay_count_stimulus', 1),
    jsonb_build_object('item_id', verify.uid('IMCQ2')::text, 'selected_option_key','C',
      'input_modality','touch','viewport_width',390,'viewport_height',844),
    jsonb_build_object('item_id', verify.uid('INUM1')::text, 'typed_value','42','input_modality','touch'),
    jsonb_build_object('item_id', verify.uid('INUM2')::text, 'typed_value','9','input_modality','touch'),
    jsonb_build_object('item_id', verify.uid('IAUD')::text, 'input_modality','touch',
      'audio_storage_path', verify.sid('S1')::text||'/aud-1.webm',
      'audio_mime_type','audio/webm;codecs=opus','audio_duration_ms',2400,'audio_file_size_bytes',31500)
  );
  begin
    perform verify.become(verify.uid('P1'));
    -- NOTE the deliberately hostile anonymized_code in the payload: the server
    -- must ignore it and use the session's assigned_code instead.
    select submit_session(verify.sid('S1'),
      jsonb_build_object('anonymized_code','ATTACKER-SUPPLIED','class_grade','7','age_months','151'),
      v_payload) into v_pid;
    v_actual := 'returned participant_id '||v_pid::text; v_pass := v_pid is not null;
  exception when others then v_actual := SQLSTATE||': '||SQLERRM;
  end;
  perform verify.unbecome();
  perform verify.assert('submit','submit_session() as owner P1 on its start_session() session',
    'returns a new participant uuid', v_actual, v_pass);
end $$;

-- TAMPER RESISTANCE: the code must come from the session, not the payload.
do $$
declare v_code text; v_expected text; v_pass boolean;
begin
  select p.anonymized_code into v_code
  from participants p join sessions s on s.participant_id = p.id
  where s.id = verify.sid('S1');
  select code into v_expected from verify.sess where k='S1';
  v_pass := v_code = v_expected and v_code <> 'ATTACKER-SUPPLIED';
  perform verify.assert('submit','TAMPER TEST: client sent anonymized_code=ATTACKER-SUPPLIED',
    'server uses the session assigned_code ('||coalesce(v_expected,'?')||')',
    'participants.anonymized_code = '||coalesce(v_code,'NULL'), v_pass);
end $$;

do $$
declare v jsonb;
begin
  select jsonb_object_agg(i.item_code, jsonb_build_object('is_correct', r.is_correct, 'scored_by', r.scored_by))
  into v from responses r join items i on i.id = r.item_id where r.session_id = verify.sid('S1');

  perform verify.assert('submit','MCQ_TAP correct answer (VT.MCQ1, chose A = the correct option)',
    'is_correct=true, scored_by=system',
    'is_correct='||coalesce((v->'VT.MCQ1'->>'is_correct'),'<none>')||', scored_by='||coalesce((v->'VT.MCQ1'->>'scored_by'),'<null>'),
    (v->'VT.MCQ1'->>'is_correct') = 'true' and (v->'VT.MCQ1'->>'scored_by') = 'system');

  perform verify.assert('submit','MCQ_TAP wrong answer (VT.MCQ2, chose C; A is correct)',
    'is_correct=false, scored_by=system',
    'is_correct='||coalesce((v->'VT.MCQ2'->>'is_correct'),'<none>')||', scored_by='||coalesce((v->'VT.MCQ2'->>'scored_by'),'<null>'),
    (v->'VT.MCQ2'->>'is_correct') = 'false' and (v->'VT.MCQ2'->>'scored_by') = 'system');

  perform verify.assert('submit','NUMERIC_KEYPAD correct (VT.NUM1, typed 42, key is 42)',
    'is_correct=true, scored_by=system',
    'is_correct='||coalesce((v->'VT.NUM1'->>'is_correct'),'<none>')||', scored_by='||coalesce((v->'VT.NUM1'->>'scored_by'),'<null>'),
    (v->'VT.NUM1'->>'is_correct') = 'true' and (v->'VT.NUM1'->>'scored_by') = 'system');

  perform verify.assert('submit','NUMERIC_KEYPAD wrong (VT.NUM2, typed 9, key is 5)',
    'is_correct=false, scored_by=system',
    'is_correct='||coalesce((v->'VT.NUM2'->>'is_correct'),'<none>')||', scored_by='||coalesce((v->'VT.NUM2'->>'scored_by'),'<null>'),
    (v->'VT.NUM2'->>'is_correct') = 'false' and (v->'VT.NUM2'->>'scored_by') = 'system');

  perform verify.assert('submit','AUDIO_RECORD human_rated item left unscored (VT.AUD1)',
    'is_correct=NULL, scored_by=NULL',
    'is_correct='||coalesce((v->'VT.AUD1'->>'is_correct'),'NULL')||', scored_by='||coalesce((v->'VT.AUD1'->>'scored_by'),'NULL'),
    (v->'VT.AUD1'->>'is_correct') is null and (v->'VT.AUD1'->>'scored_by') is null);
end $$;

do $$
declare v_status text; v_ended timestamptz; v_pid uuid; v_aud int;
        v_f double precision; v_l double precision;
begin
  select status, ended_at, participant_id into v_status, v_ended, v_pid from sessions where id = verify.sid('S1');
  select count(*) into v_aud from audio_recordings a join responses r on r.id=a.response_id
   where r.session_id = verify.sid('S1');
  select response_latency_from_first_ms, response_latency_from_last_ms into v_f, v_l
    from responses where session_id = verify.sid('S1') and item_id = verify.uid('IMCQ1');

  perform verify.assert('submit','session S1 finalised by RPC',
    'status=completed, ended_at set, participant linked',
    'status='||v_status||', ended_at='||coalesce(v_ended::text,'NULL')||', participant_id='||coalesce(v_pid::text,'NULL'),
    v_status='completed' and v_ended is not null and v_pid is not null);

  perform verify.assert('submit','audio_recordings row created from audio_storage_path',
    '1 row', v_aud||' row(s)', v_aud = 1);

  perform verify.assert('submit','dual latency anchors persisted (sent from_first=3500.75, from_last=301.0)',
    'from_first=3500.75, from_last=301',
    'from_first='||coalesce(v_f::text,'NULL')||', from_last='||coalesce(v_l::text,'NULL'),
    v_f = 3500.75 and v_l = 301.0);
end $$;


-- ============================================================================
-- PART 8 — submit_session(): rejection paths and atomicity
-- ============================================================================
do $$
declare v_pid uuid; v_actual text; v_pass boolean := false;
begin
  begin
    perform verify.become(verify.uid('P2'));
    select submit_session(verify.sid('S1'), jsonb_build_object('class_grade','7'),
      jsonb_build_array(jsonb_build_object('item_id', verify.uid('IMCQ1')::text,'selected_option_key','A'))) into v_pid;
    v_actual := 'ACCEPTED -- returned '||v_pid::text;
  exception when others then v_pass := true; v_actual := SQLSTATE||': '||SQLERRM;
  end;
  perform verify.unbecome();
  perform verify.assert('submit','submit_session() as NON-OWNER P2 on P1 session S1','rejected', v_actual, v_pass);
end $$;

do $$
declare v_pid uuid; v_actual text; v_pass boolean := false;
begin
  begin
    perform verify.become(verify.uid('P1'));
    select submit_session(verify.sid('S1'), jsonb_build_object('class_grade','7'),
      jsonb_build_array(jsonb_build_object('item_id', verify.uid('IMCQ1')::text,'selected_option_key','A'))) into v_pid;
    v_actual := 'ACCEPTED -- returned '||v_pid::text;
  exception when others then v_pass := true; v_actual := SQLSTATE||': '||SQLERRM;
  end;
  perform verify.unbecome();
  perform verify.assert('submit','submit_session() re-submitting already-completed session S1','rejected', v_actual, v_pass);
end $$;

do $$
declare v_pid uuid; v_actual text; v_pass boolean := false;
begin
  begin
    perform verify.become_anon();
    select submit_session(verify.sid('S2'), jsonb_build_object('class_grade','7'),
      jsonb_build_array(jsonb_build_object('item_id', verify.uid('IMCQ1')::text,'selected_option_key','A'))) into v_pid;
    v_actual := 'ACCEPTED -- returned '||v_pid::text;
  exception when others then v_pass := true; v_actual := SQLSTATE||': '||SQLERRM;
  end;
  perform verify.unbecome();
  perform verify.assert('submit','submit_session() as unauthenticated anon (auth.uid() is NULL)','rejected', v_actual, v_pass);
end $$;

-- NEW BEHAVIOUR IN 0004: a session created by direct INSERT has no assigned_code
-- and can therefore never be submitted. Documented, not worked around.
do $$
declare v_sid uuid; v_pid uuid; v_actual text; v_pass boolean := false;
begin
  perform verify.become(verify.uid('P2'));
  insert into sessions (auth_uid) values (verify.uid('P2')) returning id into v_sid;
  begin
    select submit_session(v_sid, jsonb_build_object('class_grade','7'),
      jsonb_build_array(jsonb_build_object('item_id', verify.uid('IMCQ1')::text,'selected_option_key','A'))) into v_pid;
    v_actual := 'ACCEPTED -- returned '||v_pid::text;
  exception when others then v_pass := true; v_actual := SQLSTATE||': '||SQLERRM;
  end;
  perform verify.unbecome();
  perform verify.assert('submit','submit_session() on a directly-INSERTed session (assigned_code NULL)',
    'rejected -- sessions must come from start_session()', v_actual, v_pass);
end $$;

do $$
declare v_pid uuid; v_err text; v_parts int; v_resp int; v_status text; v_actual text; v_before int;
begin
  select count(*) into v_before from participants;
  begin
    perform verify.become(verify.uid('P2'));
    select submit_session(verify.sid('S2'), jsonb_build_object('class_grade','8'),
      jsonb_build_array(
        jsonb_build_object('item_id', verify.uid('IMCQ1')::text,'selected_option_key','A'),
        jsonb_build_object('item_id','cccccccc-0000-4000-8000-00000000dead','selected_option_key','B')
      )) into v_pid;
    v_err := 'ACCEPTED (unexpected)';
  exception when others then v_err := SQLSTATE||': '||SQLERRM;
  end;
  perform verify.unbecome();
  select count(*) into v_parts from participants;
  select count(*) into v_resp  from responses where session_id = verify.sid('S2');
  select status into v_status from sessions where id = verify.sid('S2');
  v_actual := 'error='||v_err||' | new participants='||(v_parts - v_before)||', responses='||v_resp||', S2 status='||v_status;
  perform verify.assert('submit','ATOMICITY: submit with one unknown item_id rolls back completely',
    'rejected AND 0 new participants, 0 responses, S2 still in_progress', v_actual,
    v_parts = v_before and v_resp = 0 and v_status = 'in_progress' and v_err like '%Unknown item_id%');
end $$;


-- ============================================================================
-- PART 9 — audio rating propagation trigger (F4)
-- ============================================================================
do $$
declare v_aid uuid; v_rid uuid; v_upd int; v_ic boolean; v_sb text; v_err text; v_actual text;
begin
  select a.id, r.id into v_aid, v_rid
  from audio_recordings a join responses r on r.id = a.response_id
  where r.session_id = verify.sid('S1');

  begin
    perform verify.become(verify.uid('R1'));
    with u as (
      update audio_recordings
      set primary_rating = true,
          primary_rater_id = (select id from researchers where email='rater1@badsq-verify.test'),
          primary_rated_at = now(), rating_status = 'rated'
      where id = v_aid returning 1)
    select count(*) into v_upd from u;
  exception when others then v_err := SQLSTATE||': '||SQLERRM; v_upd := -1;
  end;
  perform verify.unbecome();

  select is_correct, scored_by into v_ic, v_sb from responses where id = v_rid;
  v_actual := 'audio rows updated='||v_upd||coalesce(' err='||v_err,'')
              ||' | responses.is_correct='||coalesce(v_ic::text,'NULL')
              ||', scored_by='||coalesce(v_sb,'NULL');
  perform verify.assert('rating_trigger','F4 FIX: trg_propagate_audio_rating fired by allowlisted rater R1',
    'responses.is_correct=true, scored_by=human', v_actual, v_ic is true and v_sb = 'human');
end $$;

do $$
declare v_aid uuid; v_rid uuid; v_ic boolean;
begin
  select a.id, r.id into v_aid, v_rid
  from audio_recordings a join responses r on r.id = a.response_id
  where r.session_id = verify.sid('S1');
  perform verify.become(verify.uid('R1'));
  update audio_recordings set primary_rating = false where id = v_aid;
  perform verify.unbecome();
  select is_correct into v_ic from responses where id = v_rid;
  perform verify.assert('rating_trigger','F4 FIX: rating flipped to false propagates too',
    'responses.is_correct=false', 'responses.is_correct='||coalesce(v_ic::text,'NULL'), v_ic is false);
end $$;

do $$
declare v_secdef boolean;
begin
  select prosecdef into v_secdef from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='propagate_audio_rating';
  perform verify.assert('rating_trigger','F4 FIX: propagate_audio_rating() runs with definer rights',
    'SECURITY DEFINER', case when v_secdef then 'SECURITY DEFINER' else 'SECURITY INVOKER' end, v_secdef);
end $$;

do $$
declare v_aid uuid; v_upd int; v_err text; v_pass boolean := false;
begin
  select a.id into v_aid from audio_recordings a join responses r on r.id=a.response_id
   where r.session_id = verify.sid('S1');
  begin
    perform verify.become(verify.uid('UOUT'));
    with u as (update audio_recordings set primary_rating = true where id = v_aid returning 1)
    select count(*) into v_upd from u;
    v_pass := (v_upd = 0); v_err := v_upd||' rows affected';
  exception when others then v_pass := true; v_err := SQLSTATE||': '||SQLERRM;
  end;
  perform verify.unbecome();
  perform verify.assert('rating_trigger','non-allowlisted user UPDATEs audio_recordings.primary_rating',
    '0 rows affected / rejected', v_err, v_pass);
end $$;


-- ============================================================================
-- PART 10 — storage policies
-- ============================================================================

-- F6 FIX: the legitimate upload must now SUCCEED.
do $$
declare v_ok boolean := false; v_actual text;
begin
  begin
    perform verify.become(verify.uid('P1'));
    insert into storage.objects (bucket_id, name, owner, owner_id)
    values ('badsq-audio', verify.sid('S4')::text||'/aud-own.webm', verify.uid('P1'), verify.uid('P1')::text);
    v_ok := true;
    perform verify.unbecome();
    raise exception using errcode='ZZ002', message='__UNDO__';
  exception when others then
    perform verify.unbecome();
    if SQLERRM <> '__UNDO__' then v_ok := false; v_actual := SQLSTATE||': '||SQLERRM; end if;
  end;
  perform verify.assert('storage','F6 FIX: P1 uploads to badsq-audio/<own in_progress session>/aud-own.webm',
    'INSERT succeeds', coalesce(v_actual,'INSERT succeeded'), v_ok);
end $$;

do $$
declare v_blocked boolean := false; v_actual text;
begin
  begin
    perform verify.become(verify.uid('P1'));
    insert into storage.objects (bucket_id, name, owner, owner_id)
    values ('badsq-audio', verify.sid('S2')::text||'/aud-steal.webm', verify.uid('P1'), verify.uid('P1')::text);
    v_actual := 'INSERT UNEXPECTEDLY SUCCEEDED';
    perform verify.unbecome();
    raise exception using errcode='ZZ003', message='__UNDO__';
  exception when others then
    perform verify.unbecome();
    if SQLERRM = '__UNDO__' then v_blocked := false;
    else v_blocked := true; v_actual := SQLSTATE||': '||SQLERRM; end if;
  end;
  perform verify.assert('storage','P1 uploads to badsq-audio/<P2 session>/aud-steal.webm',
    'INSERT rejected by RLS', v_actual, v_blocked);
end $$;

do $$
declare v_blocked boolean := false; v_actual text;
begin
  begin
    perform verify.become_anon();
    insert into storage.objects (bucket_id, name)
    values ('badsq-audio', verify.sid('S4')::text||'/aud-anon.webm');
    v_actual := 'INSERT UNEXPECTEDLY SUCCEEDED';
    perform verify.unbecome();
    raise exception using errcode='ZZ004', message='__UNDO__';
  exception when others then
    perform verify.unbecome();
    if SQLERRM = '__UNDO__' then v_blocked := false;
    else v_blocked := true; v_actual := SQLSTATE||': '||SQLERRM; end if;
  end;
  perform verify.assert('storage','unauthenticated anon uploads to badsq-audio',
    'INSERT rejected by RLS', v_actual, v_blocked);
end $$;

do $$
declare v_blocked boolean := false; v_actual text;
begin
  begin
    perform verify.become(verify.uid('P1'));
    insert into storage.objects (bucket_id, name, owner, owner_id)
    values ('badsq-audio', verify.sid('S1')::text||'/aud-late.webm', verify.uid('P1'), verify.uid('P1')::text);
    v_actual := 'INSERT SUCCEEDED';
    perform verify.unbecome();
    raise exception using errcode='ZZ005', message='__UNDO__';
  exception when others then
    perform verify.unbecome();
    if SQLERRM = '__UNDO__' then v_blocked := false;
    else v_blocked := true; v_actual := SQLSTATE||': '||SQLERRM; end if;
  end;
  perform verify.assert('storage','P1 uploads under its OWN but already-completed session',
    'rejected (upload must happen BEFORE submit_session)', v_actual, v_blocked);
end $$;

do $$
declare v_res int; v_part int; v_anon int; v_actual text;
begin
  begin
    insert into storage.objects (bucket_id, name, owner, owner_id)
    values ('badsq-audio', verify.sid('S4')::text||'/aud-read-probe.webm', verify.uid('P1'), verify.uid('P1')::text);
    perform verify.become(verify.uid('R1'));
    select count(*) into v_res from storage.objects where bucket_id='badsq-audio';
    perform verify.unbecome();
    perform verify.become(verify.uid('P1'));
    select count(*) into v_part from storage.objects where bucket_id='badsq-audio';
    perform verify.unbecome();
    perform verify.become_anon();
    select count(*) into v_anon from storage.objects where bucket_id='badsq-audio';
    perform verify.unbecome();
    raise exception using errcode='ZZ006', message='__UNDO__';
  exception when others then
    perform verify.unbecome();
    if SQLERRM <> '__UNDO__' then
      perform verify.assert('storage','read access to badsq-audio objects','researcher>0, participant=0, anon=0',
        SQLSTATE||': '||SQLERRM, false);
      return;
    end if;
  end;
  v_actual := 'researcher='||v_res||', participant='||v_part||', anon='||v_anon;
  perform verify.assert('storage','read access to badsq-audio recordings (1 probe object)',
    'researcher=1, participant=0, anon=0', v_actual, v_res = 1 and v_part = 0 and v_anon = 0);
end $$;

-- ---- item-audio bucket (NEW in 0004) ----
do $$
declare v_ok boolean := false; v_actual text;
begin
  begin
    perform verify.become(verify.uid('R1'));
    insert into storage.objects (bucket_id, name, owner, owner_id)
    values ('badsq-item-audio', 'instr/vt-mcq1.mp3', verify.uid('R1'), verify.uid('R1')::text);
    v_ok := true;
    perform verify.unbecome();
    raise exception using errcode='ZZ007', message='__UNDO__';
  exception when others then
    perform verify.unbecome();
    if SQLERRM <> '__UNDO__' then v_ok := false; v_actual := SQLSTATE||': '||SQLERRM; end if;
  end;
  perform verify.assert('item_audio','researcher with can_manage_items uploads item audio',
    'INSERT succeeds', coalesce(v_actual,'INSERT succeeded'), v_ok);
end $$;

do $$
declare v_blocked boolean := false; v_actual text;
begin
  begin
    perform verify.become(verify.uid('P1'));
    insert into storage.objects (bucket_id, name, owner, owner_id)
    values ('badsq-item-audio', 'instr/participant-forged.mp3', verify.uid('P1'), verify.uid('P1')::text);
    v_actual := 'INSERT UNEXPECTEDLY SUCCEEDED';
    perform verify.unbecome();
    raise exception using errcode='ZZ008', message='__UNDO__';
  exception when others then
    perform verify.unbecome();
    if SQLERRM = '__UNDO__' then v_blocked := false;
    else v_blocked := true; v_actual := SQLSTATE||': '||SQLERRM; end if;
  end;
  perform verify.assert('item_audio','participant uploads to badsq-item-audio',
    'INSERT rejected by RLS', v_actual, v_blocked);
end $$;

-- Read access to item audio: researcher yes; participant only while a session
-- is in_progress; anon never.
do $$
declare v_res int; v_live int; v_done int; v_anon int; v_actual text; v_pass boolean;
begin
  begin
    insert into storage.objects (bucket_id, name, owner, owner_id)
    values ('badsq-item-audio', 'instr/read-probe.mp3', verify.uid('R1'), verify.uid('R1')::text);

    perform verify.become(verify.uid('R1'));
    select count(*) into v_res from storage.objects where bucket_id='badsq-item-audio';
    perform verify.unbecome();
    -- P1 still has S4 in_progress
    perform verify.become(verify.uid('P1'));
    select count(*) into v_live from storage.objects where bucket_id='badsq-item-audio';
    perform verify.unbecome();
    -- UOUT has no session at all
    perform verify.become(verify.uid('UOUT'));
    select count(*) into v_done from storage.objects where bucket_id='badsq-item-audio';
    perform verify.unbecome();
    perform verify.become_anon();
    select count(*) into v_anon from storage.objects where bucket_id='badsq-item-audio';
    perform verify.unbecome();
    raise exception using errcode='ZZ009', message='__UNDO__';
  exception when others then
    perform verify.unbecome();
    if SQLERRM <> '__UNDO__' then
      perform verify.assert('item_audio','read access to badsq-item-audio','see expected',
        SQLSTATE||': '||SQLERRM, false);
      return;
    end if;
  end;
  v_actual := 'researcher='||v_res||', participant with in_progress session='||v_live
              ||', authenticated user with NO session='||v_done||', anon='||v_anon;
  v_pass := v_res = 1 and v_live = 1 and v_done = 0 and v_anon = 0;
  perform verify.assert('item_audio','read access to badsq-item-audio (1 probe object)',
    'researcher=1, live participant=1, no-session user=0, anon=0', v_actual, v_pass);
end $$;


-- ============================================================================
-- PART 11 — Unicode, item bank, consent linkage, hardening
-- ============================================================================
do $$
declare v_txt text; v_expected text := 'বাংলা শব্দ'; v_opt text;
begin
  select stimulus_text into v_txt from items where id = verify.uid('IMCQ1');
  select option_text into v_opt from item_options where item_id = verify.uid('ID4') and option_key='A';
  perform verify.assert('unicode','Bangla stimulus_text round-trips byte-identically',
    v_expected||' (chars=10, bytes=28)',
    coalesce(v_txt,'<null>')||' (chars='||coalesce(char_length(v_txt)::text,'-')||', bytes='||coalesce(octet_length(v_txt)::text,'-')||')',
    v_txt = v_expected);
  perform verify.assert('unicode','Bangla conjunct + vowel sign in option_text round-trips (হ্যাঁ)',
    'হ্যাঁ', coalesce(v_opt,'<null>'), v_opt = 'হ্যাঁ');
  perform verify.assert('unicode','database encoding',
    'UTF8', (select pg_encoding_to_char(encoding) from pg_database where datname=current_database()),
    (select pg_encoding_to_char(encoding) from pg_database where datname=current_database()) = 'UTF8');
end $$;

do $$
declare v_dup int; v_blank int;
begin
  select count(*) into v_dup from (
    select item_id, option_text from item_options group by item_id, option_text having count(*) > 1) d;
  perform verify.assert('item_bank','duplicate option_text within an item (design doc section 6 check)',
    '0', v_dup||' duplicate group(s)', v_dup = 0);
  select count(*) into v_blank from item_options where trim(option_text) = '';
  perform verify.assert('item_bank','blank option_text (design doc section 6 companion check)',
    '0', v_blank||' blank option(s)', v_blank = 0);
end $$;

do $$
declare v_n int; v_codes text;
begin
  select count(*), coalesce(string_agg(item_code||' (domain '||domain||', active='||active||')', ', '),'-')
  into v_n, v_codes from items where is_stimulus_replayable is null;
  perform verify.assert('item_bank','items with is_stimulus_replayable NULL are present and ACTIVE',
    'flagged for the admin-UI activation guard', v_n||' item(s): '||v_codes, v_n > 0);
end $$;

-- Consent linkage (NEW in 0004)
do $$
declare v_nullable text; v_hascol boolean; v_ok boolean;
begin
  select is_nullable into v_nullable from information_schema.columns
   where table_schema='public' and table_name='consent_records' and column_name='participant_id';
  select exists(select 1 from information_schema.columns
   where table_schema='public' and table_name='consent_records' and column_name='assigned_code') into v_hascol;
  perform verify.assert('consent','consent_records can be digitized before the participant row exists',
    'participant_id nullable AND assigned_code column present',
    'participant_id is_nullable='||coalesce(v_nullable,'?')||', assigned_code present='||v_hascol,
    v_nullable = 'YES' and v_hascol);

  -- A consent form digitized against a code, before submit.
  insert into consent_records (assigned_code, consent_given, consent_date,
                               q2_extra_primary_support, q3_family_history)
  values ((select code from verify.sess where k='S4'), true, current_date, 'yes', 'not_sure');

  select exists(
    select 1 from consent_records c join sessions s on s.assigned_code = c.assigned_code
    where c.assigned_code = (select code from verify.sess where k='S4')) into v_ok;
  perform verify.assert('consent','a consent row joins to its session via assigned_code',
    'join resolves', case when v_ok then 'join resolved' else 'NO MATCH' end, v_ok);
end $$;

-- Is the paper-form join key protected by referential integrity?
do $$
declare v_fk int; v_uq int;
begin
  select count(*) into v_fk from information_schema.table_constraints tc
   join information_schema.key_column_usage k on k.constraint_name = tc.constraint_name
   where tc.table_schema='public' and tc.table_name='consent_records'
     and tc.constraint_type='FOREIGN KEY' and k.column_name='assigned_code';
  select count(*) into v_uq from pg_indexes
   where schemaname='public' and tablename='consent_records' and indexdef like '%UNIQUE%assigned_code%';
  perform verify.assert('consent','consent_records.assigned_code has referential integrity / uniqueness',
    'FK to sessions.assigned_code and/or a UNIQUE constraint',
    v_fk||' FK constraint(s), '||v_uq||' unique index(es)', v_fk > 0 or v_uq > 0);
end $$;

do $$
declare v_bad text; v_n int;
begin
  select count(*), coalesce(string_agg(p.proname, ', ' order by p.proname), '-')
  into v_n, v_bad
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.prosecdef
    and not exists (select 1 from unnest(coalesce(p.proconfig,'{}')) c where c like 'search_path=%');
  perform verify.assert('hardening','SECURITY DEFINER functions in public with no pinned search_path',
    '0 functions', v_n||': '||v_bad, v_n = 0);
end $$;

do $$
declare v_inv int; v_list text;
begin
  select count(*), coalesce(string_agg(c.relname, ', ' order by c.relname), '-')
  into v_inv, v_list
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname='public' and c.relkind='v'
    and not coalesce((select option_value::boolean from pg_options_to_table(c.reloptions)
                      where option_name='security_invoker'), false);
  perform verify.assert('hardening','views running with OWNER privileges (bypass RLS by design)',
    'public_items, public_item_options only -- documented in 0004',
    v_inv||': '||v_list, v_list = 'public_item_options, public_items');
end $$;


-- ============================================================================
-- RESULTS
-- ============================================================================
select id, section, assertion, expected, actual, pass from verify.results order by id;

select section,
       count(*) as total,
       count(*) filter (where pass) as passed,
       count(*) filter (where not pass) as failed
from verify.results group by section
union all
select 'TOTAL', count(*), count(*) filter (where pass), count(*) filter (where not pass)
from verify.results
order by 1;


-- ============================================================================
-- PART 12 — teardown (run separately when finished inspecting results)
-- ============================================================================
-- delete from audio_recordings where response_id in (
--   select r.id from responses r join sessions s on s.id = r.session_id
--   where s.auth_uid in (select v from verify.ids where k in ('P1','P2')));
-- delete from responses where session_id in (
--   select id from sessions where auth_uid in (select v from verify.ids where k in ('P1','P2')));
-- delete from consent_records where assigned_code like 'BADSQ-%';
-- update sessions set participant_id = null
--   where auth_uid in (select v from verify.ids where k in ('P1','P2'));
-- delete from participants where created_by_auth_uid in (select v from verify.ids where k in ('P1','P2'));
-- delete from sessions where auth_uid in (select v from verify.ids where k in ('P1','P2'));
-- delete from item_options where item_id in (select v from verify.ids where k like 'I%');
-- delete from items where id in (select v from verify.ids where k like 'I%');
-- delete from researchers where email like '%@badsq-verify.test';
-- delete from auth.users where id in (select v from verify.ids where k in ('P1','P2','UOUT','R1'));
-- drop schema verify cascade;
