-- ============================================================================
-- BADSQ Platform — security verification suite (v4, post-migration 0006)
--
-- Run as `postgres` (Supabase SQL editor, or the MCP execute_sql tool).
-- Re-runnable: PART 1 rebuilds all fixtures from scratch.
--
-- v4 CHANGES vs v3 (post-0005). Migration 0006 changed one contract; everything
-- else is an ADDED assertion (PART 13), not a relaxed one:
--   * `sessions_select_own` and `sessions_select_researcher` were consolidated
--     into a single `sessions_select` policy. No assertion's EXPECTED outcome
--     changed as a result -- owners and researchers still read what they could
--     before, strangers still cannot -- only the policy name changed, which
--     PART 13 checks for directly (exactly one SELECT policy on sessions).
-- H1 (from the 0005 report) is fixed this migration: PUBLIC's EXECUTE grant on
-- propagate_audio_rating/link_researcher_on_signup is finally revoked, closing
-- the gap the 0005 revoke (targeted at anon/authenticated only) missed.
-- save_item_version() is new: an atomic RPC for item editing, replacing the
-- three-separate-statement saveNewVersion() the client used through Phase 1
-- (see PHASE_1_REPORT.md deviation 5.2 / open question 9.2).
--
-- METHOD NOTE. Assertions that need a caller identity use the same mechanism
-- PostgREST and storage-api use internally:
--     set_config('role', 'authenticated', true)
--     set_config('request.jwt.claims', '{"sub":"<uid>","role":"authenticated"}', true)
-- so auth.uid() resolves exactly as it does for a real API request. This is a
-- faithful test of the POLICY, not of the HTTP transport; the anon-role HTTP path
-- is covered separately by scripts/verify-security.mjs.
--
-- Fixture identities:
--   P1    participant browser session 1  (anonymous auth user)
--   P2    participant browser session 2  (anonymous auth user)
--   UOUT  authenticated user NOT on the researchers allowlist
--   R1    authenticated user ON the allowlist, can_rate = can_manage_items = true
--
-- Read results with:  select * from verify.results order by id;
-- ============================================================================


-- ============================================================================
-- PART 1 — fixtures and helpers
-- ============================================================================
drop schema if exists verify cascade;
create schema verify;

create table verify.results (
  id serial primary key, section text, assertion text, expected text, actual text, pass boolean
);
create table verify.ids (k text primary key, v uuid);
create table verify.sess (k text primary key, id uuid, code text);

insert into verify.ids (k, v) values
  ('P1','11111111-1111-4111-8111-111111111111'),
  ('P2','22222222-2222-4222-8222-222222222222'),
  ('UOUT','33333333-3333-4333-8333-333333333333'),
  ('R1','44444444-4444-4444-8444-444444444444'),
  ('RGONE','55555555-5555-4555-8555-555555555555'),
  ('IMCQ1','b0000000-0000-4000-8000-000000000001'),
  ('IMCQ2','b0000000-0000-4000-8000-000000000002'),
  ('INUM1','b0000000-0000-4000-8000-000000000003'),
  ('INUM2','b0000000-0000-4000-8000-000000000004'),
  ('IAUD','b0000000-0000-4000-8000-000000000005'),
  ('ID4','b0000000-0000-4000-8000-000000000006'),
  ('IMCQNK','b0000000-0000-4000-8000-000000000007'),
  ('INUMNK','b0000000-0000-4000-8000-000000000008'),
  ('IRETIRED','b0000000-0000-4000-8000-000000000009');

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
create or replace function verify.become(p_uid uuid) returns void language sql as $fn$
  select set_config('role','authenticated',true),
         set_config('request.jwt.claims',
           json_build_object('sub',p_uid::text,'role','authenticated','aud','authenticated')::text,true);
$fn$;
create or replace function verify.become_anon() returns void language sql as $fn$
  select set_config('role','anon',true), set_config('request.jwt.claims','{"role":"anon"}',true);
$fn$;
create or replace function verify.unbecome() returns void language sql as $fn$
  select set_config('role','postgres',true), set_config('request.jwt.claims','',true);
$fn$;

grant usage on schema verify to anon, authenticated;
grant select, insert on verify.results to anon, authenticated;
grant usage, select on sequence verify.results_id_seq to anon, authenticated;
grant select on verify.ids, verify.sess to anon, authenticated;
grant execute on all functions in schema verify to anon, authenticated;

-- ---- clean any prior run (children first) ----
delete from audio_recordings where response_id in (
  select r.id from responses r join sessions s on s.id = r.session_id
  where s.auth_uid in (select v from verify.ids where k in ('P1','P2')));
delete from responses where session_id in (
  select id from sessions where auth_uid in (select v from verify.ids where k in ('P1','P2')));
delete from consent_records where assigned_code like 'BADSQ-%' or assigned_code like 'VT-%';
update sessions set participant_id = null
  where auth_uid in (select v from verify.ids where k in ('P1','P2'));
delete from participants where created_by_auth_uid in (select v from verify.ids where k in ('P1','P2'));
delete from sessions where auth_uid in (select v from verify.ids where k in ('P1','P2'));
delete from item_options where item_id in (select v from verify.ids where k like 'I%');
delete from items where id in (select v from verify.ids where k like 'I%');
delete from researchers where email like '%@badsq-verify.test';
delete from auth.users where id in (select v from verify.ids where k in ('P1','P2','UOUT','R1','RGONE'));

insert into researchers (email, can_rate, can_manage_items) values ('rater1@badsq-verify.test', true, true);
insert into auth.users (id, instance_id, aud, role, email, is_anonymous, created_at, updated_at) values
  (verify.uid('P1'),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',null,true,now(),now()),
  (verify.uid('P2'),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',null,true,now(),now()),
  (verify.uid('UOUT'),'00000000-0000-0000-0000-000000000000','authenticated','authenticated','outsider@badsq-verify.test',false,now(),now()),
  (verify.uid('R1'),'00000000-0000-0000-0000-000000000000','authenticated','authenticated','rater1@badsq-verify.test',false,now(),now());

-- Item bank fixtures. Bangla stimulus_text doubles as a Unicode round-trip probe.
-- IMCQNK / INUMNK are the NULL-answer-key hazard: scored items with no key.
-- IRETIRED is an inactive version, to prove the definer views still filter.
insert into items (id, item_code, version, domain, subdomain, response_format, stimulus_text,
                   instruction_audio_path, stimulus_audio_path,
                   is_instruction_replayable, is_stimulus_replayable, correct_answer,
                   scoring_mode, is_practice, is_scored, display_order, active) values
  (verify.uid('IMCQ1'),'VT.MCQ1',1,'2','2.1 Elision','MCQ_TAP','বাংলা শব্দ','instr/vt-mcq1.mp3','stim/vt-mcq1.mp3',true,true,null,'auto',false,true,10,true),
  (verify.uid('IMCQ2'),'VT.MCQ2',1,'2','2.1 Elision','MCQ_TAP','দ্বিতীয় প্রশ্ন','instr/vt-mcq2.mp3',null,true,true,null,'auto',false,true,20,true),
  (verify.uid('INUM1'),'VT.NUM1',1,'3','3.1 Digit span','NUMERIC_KEYPAD',null,null,null,true,false,'42','auto',false,true,30,true),
  (verify.uid('INUM2'),'VT.NUM2',1,'3','3.1 Digit span','NUMERIC_KEYPAD',null,null,null,true,false,'5','auto',false,true,40,true),
  (verify.uid('IAUD'), 'VT.AUD1',1,'5','5.2 Spoonerisms','AUDIO_RECORD',null,null,null,true,true,null,'human_rated',false,true,50,true),
  (verify.uid('ID4'),  'VT.D4',  1,'4','4.1 Rhyme','MCQ_TAP','ছন্দ',null,null,true,null,null,'auto',false,true,60,true),
  (verify.uid('IMCQNK'),'VT.MCQNK',1,'2','2.1 Elision','MCQ_TAP','কী উত্তর',null,null,true,true,null,'auto',false,true,70,true),
  (verify.uid('INUMNK'),'VT.NUMNK',1,'3','3.1 Digit span','NUMERIC_KEYPAD',null,null,null,true,false,null,'auto',false,true,80,true),
  (verify.uid('IRETIRED'),'VT.MCQ1',2,'2','2.1 Elision','MCQ_TAP','পুরনো সংস্করণ',null,null,true,true,null,'auto',false,true,90,false);

insert into item_options (item_id, option_key, option_text, is_correct) values
  (verify.uid('IMCQ1'),'A','সঠিক উত্তর',true),(verify.uid('IMCQ1'),'B','ভুল ১',false),
  (verify.uid('IMCQ1'),'C','ভুল ২',false),(verify.uid('IMCQ1'),'D','ভুল ৩',false),
  (verify.uid('IMCQ2'),'A','সঠিক উত্তর',true),(verify.uid('IMCQ2'),'B','ভুল ১',false),
  (verify.uid('IMCQ2'),'C','ভুল ২',false),(verify.uid('IMCQ2'),'D','ভুল ৩',false),
  (verify.uid('ID4'),'A','হ্যাঁ',true),(verify.uid('ID4'),'B','না',false),
  -- deliberately NO correct option on IMCQNK
  (verify.uid('IMCQNK'),'A','বিকল্প ক',false),(verify.uid('IMCQNK'),'B','বিকল্প খ',false),
  (verify.uid('IRETIRED'),'A','পুরনো',true);


-- ============================================================================
-- PART 2 — start_session()
-- ============================================================================
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
  exception when others then perform verify.unbecome(); v_actual := SQLSTATE||': '||SQLERRM;
  end;
  perform verify.assert('start_session','start_session() as P1 still works after 0005 revoked direct INSERT',
    'returns session id + code', v_actual, v_pass);
end $$;

do $$
declare v_owner uuid; v_status text; v_code text; v_pass boolean;
begin
  select auth_uid, status, assigned_code into v_owner, v_status, v_code from sessions where id = verify.sid('S1');
  v_pass := v_owner = verify.uid('P1') and v_status='in_progress' and v_code = (select code from verify.sess where k='S1');
  perform verify.assert('start_session','session row created by start_session()',
    'owned by P1, in_progress, code persisted',
    'owner='||(v_owner=verify.uid('P1'))||', status='||coalesce(v_status,'NULL')||', code='||coalesce(v_code,'NULL'), v_pass);
end $$;

do $$
declare v_code text; v_pass boolean;
begin
  select code into v_code from verify.sess where k='S1';
  v_pass := v_code ~ '^BADSQ-[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}$';
  perform verify.assert('start_session','assigned_code excludes ambiguous glyphs I/O/0/1 (hand-transcribed)',
    'matches ^BADSQ-[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}$', coalesce(v_code,'NULL'), v_pass);
end $$;

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

do $$
declare v_id uuid; v_code text;
begin
  perform verify.become(verify.uid('P2'));
  select out_session_id, out_assigned_code into v_id, v_code from start_session();
  perform verify.unbecome();
  insert into verify.sess values ('S2', v_id, v_code);
  perform verify.become(verify.uid('P1'));
  select out_session_id, out_assigned_code into v_id, v_code from start_session();
  perform verify.unbecome();
  insert into verify.sess values ('S4', v_id, v_code);
  perform verify.assert('start_session','sessions issued for P2 and a second P1 session (fixtures)',
    'both created', 'S2 and S4 created', true);
end $$;


-- ============================================================================
-- PART 3 — G6: sessions are RPC-only now
-- ============================================================================
do $$
declare v_blocked boolean := false; v_actual text;
begin
  begin
    perform verify.become(verify.uid('P1'));
    insert into sessions (auth_uid) values (verify.uid('P1'));
    v_actual := 'INSERT UNEXPECTEDLY SUCCEEDED';
  exception when others then v_blocked := true; v_actual := SQLSTATE||': '||SQLERRM;
  end;
  perform verify.unbecome();
  perform verify.assert('sessions','G6 FIX: P1 INSERTs a sessions row directly',
    'rejected -- start_session() is the only entry point', v_actual, v_blocked);
end $$;

do $$
declare v_blocked boolean := false; v_actual text;
begin
  begin
    perform verify.become(verify.uid('P1'));
    update sessions set status='completed' where id = verify.sid('S4');
    v_actual := 'UPDATE UNEXPECTEDLY SUCCEEDED';
  exception when others then v_blocked := true; v_actual := SQLSTATE||': '||SQLERRM;
  end;
  perform verify.unbecome();
  perform verify.assert('sessions','G6 FIX: P1 marks its own session completed without submitting',
    'rejected -- would orphan the session with no participant row', v_actual, v_blocked);
end $$;

do $$
declare v_status text;
begin
  select status into v_status from sessions where id = verify.sid('S4');
  perform verify.assert('sessions','G6 FIX: session S4 status unchanged after the blocked UPDATE',
    'in_progress', coalesce(v_status,'NULL'), v_status = 'in_progress');
end $$;

do $$
declare v_cnt int;
begin
  perform verify.become(verify.uid('P1'));
  select count(*) into v_cnt from sessions where id = verify.sid('S2');
  perform verify.unbecome();
  perform verify.assert('sessions','P1 reads P2 session row directly','0 rows', v_cnt||' rows', v_cnt = 0);
end $$;

do $$
declare v_seen int; v_own int; v_other int; v_total int;
begin
  select count(*) into v_total from sessions;
  select count(*) into v_own from sessions where auth_uid = verify.uid('P1');
  perform verify.become(verify.uid('P1'));
  select count(*) into v_seen from sessions;
  select count(*) into v_other from sessions where auth_uid <> verify.uid('P1');
  perform verify.unbecome();
  perform verify.assert('sessions','P1 SELECT on sessions sees its own rows and no one else''s (table holds '||v_total||')',
    v_own||' own rows, 0 of another''s', v_seen||' visible, '||v_other||' another participant''s',
    v_seen = v_own and v_other = 0);
end $$;

do $$
declare v_cnt int; v_total int;
begin
  select count(*) into v_total from sessions;
  perform verify.become(verify.uid('R1'));
  select count(*) into v_cnt from sessions;
  perform verify.unbecome();
  perform verify.assert('sessions','Allowlisted researcher SELECTs all sessions',
    v_total||' rows', v_cnt||' rows', v_cnt = v_total);
end $$;


-- ============================================================================
-- PART 4 — answer keys, G1 audio columns, G4 re-probe of the recreated views
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
  perform verify.assert('answer_keys','participant SELECT items base table (real correct_answer is 42)',
    '0 rows, no value leaked', v_actual, v_pass);
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
  perform verify.assert('answer_keys','anon SELECT items.correct_answer','blocked', v_actual, v_blocked);
end $$;

-- G1 FIX: the participant view must expose the RENAMED audio columns.
do $$
declare v_base text; v_view text; v_pass boolean;
begin
  select coalesce(string_agg(column_name,', ' order by ordinal_position),'(none)') into v_base
  from information_schema.columns where table_schema='public' and table_name='items' and column_name like '%audio%';
  select coalesce(string_agg(column_name,', ' order by ordinal_position),'(none)') into v_view
  from information_schema.columns where table_schema='public' and table_name='public_items' and column_name like '%audio%';
  v_pass := v_base = v_view;
  perform verify.assert('answer_keys','G1 FIX: public_items audio column names match the renamed base table',
    'view matches base: '||v_base, 'view exposes: '||v_view, v_pass);
end $$;

do $$
declare v_path text; v_actual text; v_pass boolean := false;
begin
  begin
    perform verify.become(verify.uid('P1'));
    select instruction_audio_path into v_path from public_items where item_code='VT.MCQ1';
    v_actual := coalesce(v_path,'<null>'); v_pass := v_path = 'instr/vt-mcq1.mp3';
  exception when others then v_actual := SQLSTATE||': '||SQLERRM;
  end;
  perform verify.unbecome();
  perform verify.assert('answer_keys','G1 FIX: participant reads public_items.instruction_audio_path',
    'instr/vt-mcq1.mp3', v_actual, v_pass);
end $$;

-- G4 RE-PROBE: both views were dropped and recreated by 0005, so their security
-- properties must be re-established, not assumed to have carried over.
do $$
declare v_cnt int; v_retired int; v_actual text; v_pass boolean := false;
begin
  begin
    perform verify.become(verify.uid('P1'));
    select count(*) into v_cnt from public_items;
    select count(*) into v_retired from public_items where item_code='VT.MCQ1' and version=2;
    v_actual := v_cnt||' rows; retired v2 rows visible='||v_retired;
    v_pass := v_cnt = 8 and v_retired = 0;
  exception when others then v_actual := SQLSTATE||': '||SQLERRM;
  end;
  perform verify.unbecome();
  perform verify.assert('answer_keys','G4 RE-PROBE: recreated public_items still filters active=true (8 active, 1 retired)',
    '8 rows, 0 retired', v_actual, v_pass);
end $$;

do $$
declare v_cnt int; v_actual text; v_pass boolean := false;
begin
  begin
    perform verify.become(verify.uid('P1'));
    select count(*) into v_cnt from public_item_options;
    v_actual := v_cnt||' rows (12 belong to active items, 1 to the retired version)';
    v_pass := v_cnt = 12;
  exception when others then v_actual := SQLSTATE||': '||SQLERRM;
  end;
  perform verify.unbecome();
  perform verify.assert('answer_keys','G4 RE-PROBE: recreated public_item_options excludes options of retired items',
    '12 rows', v_actual, v_pass);
end $$;

do $$
declare v_bad text;
begin
  select coalesce(string_agg(table_name||'.'||column_name, ', '),'(none)') into v_bad
  from information_schema.columns
  where table_schema='public' and table_name in ('public_items','public_item_options')
    and column_name in ('correct_answer','is_correct');
  perform verify.assert('answer_keys','G4 RE-PROBE: recreated views expose no answer-key column',
    '(none)', v_bad, v_bad = '(none)');
end $$;

do $$
declare v_txt text; v_actual text; v_pass boolean := false;
begin
  begin
    perform verify.become(verify.uid('R1'));
    select correct_answer into v_txt from items where id = verify.uid('INUM1');
    v_actual := coalesce(v_txt,'<null>'); v_pass := v_txt = '42';
  exception when others then v_actual := SQLSTATE||': '||SQLERRM;
  end;
  perform verify.unbecome();
  perform verify.assert('answer_keys','POSITIVE CONTROL: researcher reads items.correct_answer',
    '42', v_actual, v_pass);
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
declare v_rls boolean; v_cnt int; v_actual text; v_safe boolean := false;
begin
  select relrowsecurity into v_rls from pg_class c join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relname='ml_snapshots';
  perform verify.assert('export','ml_snapshots has RLS enabled','RLS enabled',
    case when v_rls then 'enabled' else 'NOT ENABLED' end, v_rls);
  insert into ml_snapshots (anonymized_code, class_grade) values ('SNAPSHOT-CANARY', 7);
  begin
    perform verify.become_anon();
    select count(*) into v_cnt from ml_snapshots;
    v_actual := 'READABLE -- '||v_cnt||' rows'; v_safe := v_cnt = 0;
  exception when others then v_safe := true; v_actual := SQLSTATE||': '||SQLERRM;
  end;
  perform verify.unbecome();
  perform verify.assert('export','anon SELECT from ml_snapshots','blocked or 0 rows', v_actual, v_safe);
  delete from ml_snapshots;
end $$;

do $$
declare v_cols text; v_pass boolean;
begin
  select coalesce(string_agg(column_name,', ' order by ordinal_position),'(none)') into v_cols
  from information_schema.columns where table_schema='public' and table_name='ml_export_v1' and column_name like '%latenc%';
  v_pass := v_cols like '%from_first%' and v_cols like '%from_last%';
  perform verify.assert('export','ml_export_v1 exposes BOTH latency anchors',
    'from_first and from_last', v_cols, v_pass);
end $$;


-- ============================================================================
-- PART 6 — participant confidentiality
-- ============================================================================
do $$
declare v_p int; v_r int; v_a int; v_c int; v_res int; v_safe boolean; v_actual text;
begin
  perform verify.become(verify.uid('UOUT'));
  select count(*) into v_p from participants;
  select count(*) into v_r from responses;
  select count(*) into v_a from audio_recordings;
  select count(*) into v_c from consent_records;
  select count(*) into v_res from researchers;
  perform verify.unbecome();
  v_actual := 'participants='||v_p||', responses='||v_r||', audio='||v_a||', consent='||v_c||', researchers='||v_res;
  v_safe := v_p=0 and v_r=0 and v_a=0 and v_c=0 and v_res=0;
  perform verify.assert('participants','non-allowlisted authenticated user reads the protected tables',
    'all 0 rows', v_actual, v_safe);
end $$;

do $$
declare v_p int; v_safe boolean; v_actual text;
begin
  perform verify.become_anon();
  select count(*) into v_p from participants;
  perform verify.unbecome();
  perform verify.assert('participants','anon SELECT participants','0 rows', v_p||' rows visible', v_p = 0);
end $$;


-- ============================================================================
-- PART 7 — submit_session(), including the NULL-answer-key scoring hazard
-- ============================================================================
do $$
declare v_pid uuid; v_actual text; v_pass boolean := false; v_payload jsonb;
begin
  v_payload := jsonb_build_array(
    jsonb_build_object('item_id',verify.uid('IMCQ1')::text,'selected_option_key','A','input_modality','touch',
      'viewport_width',390,'viewport_height',844,'stimulus_first_end_client_ts',1000.5,
      'stimulus_last_end_client_ts',4200.25,'response_latency_from_first_ms',3500.75,
      'response_latency_from_last_ms',301.0,'replay_count_stimulus',1),
    jsonb_build_object('item_id',verify.uid('IMCQ2')::text,'selected_option_key','C','input_modality','touch'),
    jsonb_build_object('item_id',verify.uid('INUM1')::text,'typed_value','42','input_modality','touch'),
    jsonb_build_object('item_id',verify.uid('INUM2')::text,'typed_value','9','input_modality','touch'),
    -- the two NULL-answer-key hazard items
    jsonb_build_object('item_id',verify.uid('IMCQNK')::text,'selected_option_key','A','input_modality','touch'),
    jsonb_build_object('item_id',verify.uid('INUMNK')::text,'typed_value','7','input_modality','touch'),
    jsonb_build_object('item_id',verify.uid('IAUD')::text,'input_modality','touch',
      'audio_storage_path',verify.sid('S1')::text||'/aud-1.webm','audio_mime_type','audio/webm;codecs=opus',
      'audio_duration_ms',2400,'audio_file_size_bytes',31500));
  begin
    perform verify.become(verify.uid('P1'));
    select submit_session(verify.sid('S1'),
      jsonb_build_object('anonymized_code','ATTACKER-SUPPLIED','class_grade','7','age_months','151'),
      v_payload) into v_pid;
    v_actual := 'returned participant_id '||v_pid::text; v_pass := v_pid is not null;
  exception when others then v_actual := SQLSTATE||': '||SQLERRM;
  end;
  perform verify.unbecome();
  perform verify.assert('submit','submit_session() as owner P1','returns a participant uuid', v_actual, v_pass);
end $$;

do $$
declare v_code text; v_expected text; v_pass boolean;
begin
  select p.anonymized_code into v_code from participants p join sessions s on s.participant_id = p.id
   where s.id = verify.sid('S1');
  select code into v_expected from verify.sess where k='S1';
  v_pass := v_code = v_expected and v_code <> 'ATTACKER-SUPPLIED';
  perform verify.assert('submit','TAMPER TEST: client sent anonymized_code=ATTACKER-SUPPLIED',
    'server uses session assigned_code ('||coalesce(v_expected,'?')||')',
    'participants.anonymized_code = '||coalesce(v_code,'NULL'), v_pass);
end $$;

do $$
declare v jsonb;
begin
  select jsonb_object_agg(i.item_code, jsonb_build_object('is_correct',r.is_correct,'scored_by',r.scored_by))
  into v from responses r join items i on i.id=r.item_id where r.session_id = verify.sid('S1');

  perform verify.assert('submit','MCQ_TAP correct (VT.MCQ1, chose A = correct)','is_correct=true, scored_by=system',
    'is_correct='||coalesce((v->'VT.MCQ1'->>'is_correct'),'NULL')||', scored_by='||coalesce((v->'VT.MCQ1'->>'scored_by'),'NULL'),
    (v->'VT.MCQ1'->>'is_correct')='true' and (v->'VT.MCQ1'->>'scored_by')='system');

  perform verify.assert('submit','MCQ_TAP wrong (VT.MCQ2, chose C; A correct)','is_correct=false, scored_by=system',
    'is_correct='||coalesce((v->'VT.MCQ2'->>'is_correct'),'NULL')||', scored_by='||coalesce((v->'VT.MCQ2'->>'scored_by'),'NULL'),
    (v->'VT.MCQ2'->>'is_correct')='false' and (v->'VT.MCQ2'->>'scored_by')='system');

  perform verify.assert('submit','NUMERIC_KEYPAD correct (VT.NUM1, typed 42)','is_correct=true, scored_by=system',
    'is_correct='||coalesce((v->'VT.NUM1'->>'is_correct'),'NULL')||', scored_by='||coalesce((v->'VT.NUM1'->>'scored_by'),'NULL'),
    (v->'VT.NUM1'->>'is_correct')='true' and (v->'VT.NUM1'->>'scored_by')='system');

  perform verify.assert('submit','NUMERIC_KEYPAD wrong (VT.NUM2, typed 9, key 5)','is_correct=false, scored_by=system',
    'is_correct='||coalesce((v->'VT.NUM2'->>'is_correct'),'NULL')||', scored_by='||coalesce((v->'VT.NUM2'->>'scored_by'),'NULL'),
    (v->'VT.NUM2'->>'is_correct')='false' and (v->'VT.NUM2'->>'scored_by')='system');

  perform verify.assert('submit','AUDIO_RECORD human_rated left unscored (VT.AUD1)','is_correct=NULL, scored_by=NULL',
    'is_correct='||coalesce((v->'VT.AUD1'->>'is_correct'),'NULL')||', scored_by='||coalesce((v->'VT.AUD1'->>'scored_by'),'NULL'),
    (v->'VT.AUD1'->>'is_correct') is null and (v->'VT.AUD1'->>'scored_by') is null);

  -- THE HAZARD: before 0005 these marked every student WRONG.
  perform verify.assert('submit','SCORING HAZARD: scored MCQ with NO correct option flagged (VT.MCQNK)',
    'is_correct=NULL (not false) -- must not mark the student wrong',
    'is_correct='||coalesce((v->'VT.MCQNK'->>'is_correct'),'NULL')||', scored_by='||coalesce((v->'VT.MCQNK'->>'scored_by'),'NULL'),
    (v->'VT.MCQNK'->>'is_correct') is null and (v->'VT.MCQNK'->>'scored_by') is null);

  perform verify.assert('submit','SCORING HAZARD: scored NUMERIC_KEYPAD with NULL correct_answer (VT.NUMNK)',
    'is_correct=NULL (not false) -- must not mark the student wrong',
    'is_correct='||coalesce((v->'VT.NUMNK'->>'is_correct'),'NULL')||', scored_by='||coalesce((v->'VT.NUMNK'->>'scored_by'),'NULL'),
    (v->'VT.NUMNK'->>'is_correct') is null and (v->'VT.NUMNK'->>'scored_by') is null);
end $$;

do $$
declare v_status text; v_ended timestamptz; v_pid uuid; v_aud int; v_f double precision; v_l double precision;
begin
  select status, ended_at, participant_id into v_status, v_ended, v_pid from sessions where id = verify.sid('S1');
  select count(*) into v_aud from audio_recordings a join responses r on r.id=a.response_id where r.session_id = verify.sid('S1');
  select response_latency_from_first_ms, response_latency_from_last_ms into v_f, v_l
    from responses where session_id = verify.sid('S1') and item_id = verify.uid('IMCQ1');
  perform verify.assert('submit','session finalised by RPC','completed, ended_at set, participant linked',
    'status='||v_status||', ended_at='||coalesce(v_ended::text,'NULL')||', participant='||coalesce(v_pid::text,'NULL'),
    v_status='completed' and v_ended is not null and v_pid is not null);
  perform verify.assert('submit','audio_recordings row created','1 row', v_aud||' row(s)', v_aud=1);
  perform verify.assert('submit','dual latency anchors persisted','from_first=3500.75, from_last=301',
    'from_first='||coalesce(v_f::text,'NULL')||', from_last='||coalesce(v_l::text,'NULL'), v_f=3500.75 and v_l=301.0);
end $$;

do $$
declare v_pid uuid; v_actual text; v_pass boolean := false;
begin
  begin
    perform verify.become(verify.uid('P2'));
    select submit_session(verify.sid('S1'), jsonb_build_object('class_grade','7'), '[]'::jsonb) into v_pid;
    v_actual := 'ACCEPTED';
  exception when others then v_pass := true; v_actual := SQLSTATE||': '||SQLERRM;
  end;
  perform verify.unbecome();
  perform verify.assert('submit','submit_session() as NON-OWNER','rejected', v_actual, v_pass);
end $$;

do $$
declare v_pid uuid; v_actual text; v_pass boolean := false;
begin
  begin
    perform verify.become(verify.uid('P1'));
    select submit_session(verify.sid('S1'), jsonb_build_object('class_grade','7'), '[]'::jsonb) into v_pid;
    v_actual := 'ACCEPTED';
  exception when others then v_pass := true; v_actual := SQLSTATE||': '||SQLERRM;
  end;
  perform verify.unbecome();
  perform verify.assert('submit','submit_session() re-submitting a completed session','rejected', v_actual, v_pass);
end $$;

-- The assigned_code IS NULL branch is now unreachable through the client (G6
-- removed direct INSERT), so the row is created as postgres to exercise the
-- defensive branch that still exists in the function.
do $$
declare v_sid uuid; v_pid uuid; v_actual text; v_pass boolean := false;
begin
  insert into sessions (auth_uid, assigned_code) values (verify.uid('P2'), null) returning id into v_sid;
  begin
    perform verify.become(verify.uid('P2'));
    select submit_session(v_sid, jsonb_build_object('class_grade','7'), '[]'::jsonb) into v_pid;
    v_actual := 'ACCEPTED';
  exception when others then v_pass := true; v_actual := SQLSTATE||': '||SQLERRM;
  end;
  perform verify.unbecome();
  delete from sessions where id = v_sid;
  perform verify.assert('submit','submit_session() on a session with assigned_code NULL (defensive branch)',
    'rejected', v_actual, v_pass);
end $$;

do $$
declare v_pid uuid; v_err text; v_before int; v_after int; v_resp int; v_status text; v_actual text;
begin
  select count(*) into v_before from participants;
  begin
    perform verify.become(verify.uid('P2'));
    select submit_session(verify.sid('S2'), jsonb_build_object('class_grade','8'),
      jsonb_build_array(jsonb_build_object('item_id',verify.uid('IMCQ1')::text,'selected_option_key','A'),
                        jsonb_build_object('item_id','cccccccc-0000-4000-8000-00000000dead','selected_option_key','B'))) into v_pid;
    v_err := 'ACCEPTED (unexpected)';
  exception when others then v_err := SQLSTATE||': '||SQLERRM;
  end;
  perform verify.unbecome();
  select count(*) into v_after from participants;
  select count(*) into v_resp from responses where session_id = verify.sid('S2');
  select status into v_status from sessions where id = verify.sid('S2');
  v_actual := 'error='||v_err||' | new participants='||(v_after-v_before)||', responses='||v_resp||', status='||v_status;
  perform verify.assert('submit','ATOMICITY: unknown item_id rolls back completely',
    'rejected AND nothing written', v_actual,
    v_after=v_before and v_resp=0 and v_status='in_progress' and v_err like '%Unknown item_id%');
end $$;


-- ============================================================================
-- PART 8 — audio rating propagation
-- ============================================================================
do $$
declare v_aid uuid; v_rid uuid; v_upd int; v_ic boolean; v_sb text; v_actual text;
begin
  select a.id, r.id into v_aid, v_rid from audio_recordings a join responses r on r.id=a.response_id
   where r.session_id = verify.sid('S1');
  perform verify.become(verify.uid('R1'));
  with u as (update audio_recordings set primary_rating=true,
    primary_rater_id=(select id from researchers where email='rater1@badsq-verify.test'),
    primary_rated_at=now(), rating_status='rated' where id=v_aid returning 1)
  select count(*) into v_upd from u;
  perform verify.unbecome();
  select is_correct, scored_by into v_ic, v_sb from responses where id=v_rid;
  v_actual := 'audio rows updated='||v_upd||' | is_correct='||coalesce(v_ic::text,'NULL')||', scored_by='||coalesce(v_sb,'NULL');
  perform verify.assert('rating_trigger','rating by allowlisted rater propagates to responses',
    'is_correct=true, scored_by=human', v_actual, v_ic is true and v_sb='human');
end $$;

do $$
declare v_aid uuid; v_upd int; v_err text; v_pass boolean := false;
begin
  select a.id into v_aid from audio_recordings a join responses r on r.id=a.response_id where r.session_id = verify.sid('S1');
  begin
    perform verify.become(verify.uid('UOUT'));
    with u as (update audio_recordings set primary_rating=false where id=v_aid returning 1) select count(*) into v_upd from u;
    v_pass := v_upd = 0; v_err := v_upd||' rows affected';
  exception when others then v_pass := true; v_err := SQLSTATE||': '||SQLERRM;
  end;
  perform verify.unbecome();
  perform verify.assert('rating_trigger','non-allowlisted user writes a rating','0 rows / rejected', v_err, v_pass);
end $$;


-- ============================================================================
-- PART 9 — storage
-- ============================================================================
do $$
declare v_ok boolean := false; v_actual text;
begin
  begin
    perform verify.become(verify.uid('P1'));
    insert into storage.objects (bucket_id,name,owner,owner_id)
    values ('badsq-audio', verify.sid('S4')::text||'/aud-own.webm', verify.uid('P1'), verify.uid('P1')::text);
    v_ok := true; perform verify.unbecome();
    raise exception using errcode='ZZ002', message='__UNDO__';
  exception when others then
    perform verify.unbecome();
    if SQLERRM <> '__UNDO__' then v_ok := false; v_actual := SQLSTATE||': '||SQLERRM; end if;
  end;
  perform verify.assert('storage','P1 uploads to badsq-audio/<own in_progress session>/',
    'INSERT succeeds', coalesce(v_actual,'INSERT succeeded'), v_ok);
end $$;

do $$
declare v_blocked boolean := false; v_actual text;
begin
  begin
    perform verify.become(verify.uid('P1'));
    insert into storage.objects (bucket_id,name,owner,owner_id)
    values ('badsq-audio', verify.sid('S2')::text||'/steal.webm', verify.uid('P1'), verify.uid('P1')::text);
    v_actual := 'INSERT UNEXPECTEDLY SUCCEEDED'; perform verify.unbecome();
    raise exception using errcode='ZZ003', message='__UNDO__';
  exception when others then
    perform verify.unbecome();
    if SQLERRM='__UNDO__' then v_blocked := false; else v_blocked := true; v_actual := SQLSTATE||': '||SQLERRM; end if;
  end;
  perform verify.assert('storage','P1 uploads to another participant''s session folder','rejected', v_actual, v_blocked);
end $$;

do $$
declare v_ok boolean := false; v_actual text;
begin
  begin
    perform verify.become(verify.uid('R1'));
    insert into storage.objects (bucket_id,name,owner,owner_id)
    values ('badsq-item-audio','instr/vt-mcq1.mp3', verify.uid('R1'), verify.uid('R1')::text);
    v_ok := true; perform verify.unbecome();
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
    insert into storage.objects (bucket_id,name,owner,owner_id)
    values ('badsq-item-audio','instr/forged.mp3', verify.uid('P1'), verify.uid('P1')::text);
    v_actual := 'INSERT UNEXPECTEDLY SUCCEEDED'; perform verify.unbecome();
    raise exception using errcode='ZZ008', message='__UNDO__';
  exception when others then
    perform verify.unbecome();
    if SQLERRM='__UNDO__' then v_blocked := false; else v_blocked := true; v_actual := SQLSTATE||': '||SQLERRM; end if;
  end;
  perform verify.assert('item_audio','participant uploads to badsq-item-audio','rejected', v_actual, v_blocked);
end $$;


-- ============================================================================
-- PART 10 — G2: consent linkage integrity
-- ============================================================================
do $$
declare v_ok boolean := false; v_actual text; v_code text;
begin
  select code into v_code from verify.sess where k='S4';
  begin
    insert into consent_records (assigned_code, consent_given, consent_date, q2_extra_primary_support, q3_family_history)
    values (v_code, true, current_date, 'yes', 'not_sure');
    v_ok := true; v_actual := 'accepted for code '||v_code;
  exception when others then v_actual := SQLSTATE||': '||SQLERRM;
  end;
  perform verify.assert('consent','a consent row for a REAL session code is accepted','accepted', v_actual, v_ok);
end $$;

do $$
declare v_blocked boolean := false; v_actual text;
begin
  begin
    insert into consent_records (assigned_code, consent_given, consent_date)
    values ('BADSQ-ZZZZ-ZZZZ', true, current_date);
    v_actual := 'ACCEPTED -- orphan consent row created';
  exception when others then v_blocked := true; v_actual := SQLSTATE||': '||SQLERRM;
  end;
  perform verify.assert('consent','G2 FIX: consent row whose code matches NO session (transcription typo)',
    'rejected by FK', v_actual, v_blocked);
end $$;

do $$
declare v_blocked boolean := false; v_actual text; v_code text;
begin
  select code into v_code from verify.sess where k='S4';
  begin
    insert into consent_records (assigned_code, consent_given, consent_date)
    values (v_code, false, current_date);
    v_actual := 'ACCEPTED -- duplicate consent row created';
  exception when others then v_blocked := true; v_actual := SQLSTATE||': '||SQLERRM;
  end;
  perform verify.assert('consent','G2 FIX: a SECOND consent row claiming the same code',
    'rejected by UNIQUE', v_actual, v_blocked);
end $$;

do $$
declare v_ok boolean := false; v_actual text;
begin
  begin
    insert into consent_records (assigned_code, consent_given, consent_date)
    values (null, true, current_date);
    v_ok := true; v_actual := 'accepted (NULL codes still permitted)';
    delete from consent_records where assigned_code is null;
  exception when others then v_actual := SQLSTATE||': '||SQLERRM;
  end;
  perform verify.assert('consent','a consent row with NULL code is still permitted (partial unique index)',
    'accepted', v_actual, v_ok);
end $$;


-- ============================================================================
-- PART 11 — Unicode and item bank
-- ============================================================================
do $$
declare v_txt text; v_opt text;
begin
  select stimulus_text into v_txt from items where id = verify.uid('IMCQ1');
  select option_text into v_opt from item_options where item_id = verify.uid('ID4') and option_key='A';
  perform verify.assert('unicode','Bangla stimulus_text round-trips byte-identically','বাংলা শব্দ (chars=10, bytes=28)',
    coalesce(v_txt,'<null>')||' (chars='||coalesce(char_length(v_txt)::text,'-')||', bytes='||coalesce(octet_length(v_txt)::text,'-')||')',
    v_txt = 'বাংলা শব্দ');
  perform verify.assert('unicode','Bangla conjunct + vowel sign round-trips (হ্যাঁ)','হ্যাঁ', coalesce(v_opt,'<null>'), v_opt='হ্যাঁ');
end $$;

do $$
declare v_dup int; v_blank int;
begin
  select count(*) into v_dup from (select item_id, option_text from item_options group by item_id, option_text having count(*)>1) d;
  perform verify.assert('item_bank','duplicate option_text within an item (design doc section 6)','0', v_dup||' group(s)', v_dup=0);
  select count(*) into v_blank from item_options where trim(option_text)='';
  perform verify.assert('item_bank','blank option_text','0', v_blank||' option(s)', v_blank=0);
end $$;

do $$
declare v_n int;
begin
  select count(*) into v_n from items where is_stimulus_replayable is null;
  perform verify.assert('item_bank','items with is_stimulus_replayable NULL exist (admin activation guard subject)',
    'at least 1', v_n||' item(s)', v_n > 0);
end $$;


-- ============================================================================
-- PART 12 — hardening: G3, G5, G7, and the VIEW DRIFT RELEASE GATE
-- ============================================================================
do $$
declare v_bad text; v_n int;
begin
  select count(*), coalesce(string_agg(p.proname, ', ' order by p.proname),'-') into v_n, v_bad
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.prosecdef
    and not exists (select 1 from unnest(coalesce(p.proconfig,'{}')) c where c like 'search_path=%');
  perform verify.assert('hardening','G3 FIX: SECURITY DEFINER functions with no pinned search_path',
    '0 functions', v_n||': '||v_bad, v_n = 0);
end $$;

do $$
declare v_bad text; v_n int;
begin
  select count(*), coalesce(string_agg(p.proname, ', ' order by p.proname),'-') into v_n, v_bad
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public'
    and not exists (select 1 from unnest(coalesce(p.proconfig,'{}')) c where c like 'search_path=%');
  perform verify.assert('hardening','G3 FIX: ALL public functions have a pinned search_path (incl. non-definer)',
    '0 functions', v_n||': '||v_bad, v_n = 0);
end $$;

-- G5: the trigger functions should not be executable by client roles at all.
do $$
declare v_anon boolean; v_auth boolean; v_acl text;
begin
  select has_function_privilege('anon', p.oid, 'EXECUTE'),
         has_function_privilege('authenticated', p.oid, 'EXECUTE'),
         coalesce(array_to_string(p.proacl, ' '), '(default)')
  into v_anon, v_auth, v_acl
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='propagate_audio_rating';
  perform verify.assert('hardening','G5 FIX: propagate_audio_rating() not EXECUTEable by client roles',
    'anon=false, authenticated=false',
    'anon='||v_anon||', authenticated='||v_auth||' | acl: '||v_acl, not v_anon and not v_auth);
end $$;

do $$
declare v_anon boolean; v_auth boolean; v_acl text;
begin
  select has_function_privilege('anon', p.oid, 'EXECUTE'),
         has_function_privilege('authenticated', p.oid, 'EXECUTE'),
         coalesce(array_to_string(p.proacl, ' '), '(default)')
  into v_anon, v_auth, v_acl
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='link_researcher_on_signup';
  perform verify.assert('hardening','G5 FIX: link_researcher_on_signup() not EXECUTEable by client roles',
    'anon=false, authenticated=false',
    'anon='||v_anon||', authenticated='||v_auth||' | acl: '||v_acl, not v_anon and not v_auth);
end $$;

-- G7: deleting a departed researcher's auth account must null the link, not error.
do $$
declare v_err text; v_uid_after uuid; v_row_kept boolean; v_pass boolean := false; v_actual text;
begin
  insert into researchers (email, can_rate, can_manage_items) values ('gone@badsq-verify.test', true, false);
  insert into auth.users (id, instance_id, aud, role, email, is_anonymous, created_at, updated_at)
  values (verify.uid('RGONE'),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
          'gone@badsq-verify.test', false, now(), now());
  begin
    delete from auth.users where id = verify.uid('RGONE');
    select user_id, true into v_uid_after, v_row_kept from researchers where email='gone@badsq-verify.test';
    v_pass := v_uid_after is null and v_row_kept;
    v_actual := 'delete succeeded; allowlist row kept='||coalesce(v_row_kept::text,'false')
                ||', user_id='||coalesce(v_uid_after::text,'NULL');
  exception when others then v_actual := SQLSTATE||': '||SQLERRM;
  end;
  delete from researchers where email='gone@badsq-verify.test';
  perform verify.assert('hardening','G7 FIX: deleting a researcher''s auth account nulls researchers.user_id',
    'delete succeeds, allowlist row kept, user_id NULL', v_actual, v_pass);
end $$;

-- ---------------------------------------------------------------------------
-- VIEW DRIFT RELEASE GATE (see scripts/check_view_drift.sql for the standalone
-- query and the full rationale). Two assertions:
--   1. a SELF-TEST proving the gate catches a deliberately drifted view — a gate
--      that has never been shown to fail is not a gate;
--   2. the real check across public.
-- ---------------------------------------------------------------------------
create or replace function verify.view_drift()
returns table (view_name text, out_col text, verdict text)
language sql stable as $fn$
  with vcols as (
    select v.relname::text as view_name, a.attname::text as out_col, a.attnum
    from pg_class v
    join pg_namespace vn on vn.oid = v.relnamespace
    join pg_attribute a on a.attrelid = v.oid and a.attnum > 0 and not a.attisdropped
    where vn.nspname = 'public' and v.relkind = 'v'
  ),
  vdeps as (
    select distinct v.relname::text as view_name, ba.attname::text as base_col
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
  allowlist(view_name, out_col) as (
    values ('ml_export_v1','response_id')
  )
  select c.view_name, c.out_col,
         (case when al.out_col is not null then 'ALLOWLISTED' else 'DRIFT' end)::text
  from vcols c
  left join allowlist al on al.view_name = c.view_name and al.out_col = c.out_col
  where not exists (select 1 from vdeps d where d.view_name = c.view_name and d.base_col = c.out_col)
  order by 3, 1, c.attnum;
$fn$;

do $$
declare v_caught int; v_actual text;
begin
  -- Reproduce the exact G1 shape: alias a renamed base column back to its old name.
  create view drift_selftest as
    select id, item_code, instruction_audio_path as instruction_audio_url from items;
  select count(*) into v_caught from verify.view_drift()
   where view_name='drift_selftest' and out_col='instruction_audio_url' and verdict='DRIFT';
  drop view drift_selftest;
  v_actual := v_caught||' drift row(s) reported for the deliberately broken view';
  perform verify.assert('view_drift_gate','SELF-TEST: gate catches a view aliasing a renamed column (the G1/F5 shape)',
    '1 DRIFT row', v_actual, v_caught = 1);
end $$;

do $$
declare v_n int; v_list text;
begin
  select count(*), coalesce(string_agg(view_name||'.'||out_col, ', '),'-')
  into v_n, v_list from verify.view_drift() where verdict='DRIFT';
  perform verify.assert('view_drift_gate','RELEASE GATE: no view in public has a drifted output column',
    '0 DRIFT rows', v_n||': '||v_list, v_n = 0);
end $$;

do $$
declare v_n int; v_list text;
begin
  select count(*), coalesce(string_agg(view_name||'.'||out_col, ', '),'-')
  into v_n, v_list from verify.view_drift() where verdict='ALLOWLISTED';
  perform verify.assert('view_drift_gate','allowlisted intentional aliases are declared and reviewed',
    'ml_export_v1.response_id', v_list, v_list = 'ml_export_v1.response_id');
end $$;


-- ============================================================================
-- PART 13 — migration 0006: H1 (the PUBLIC-grant gap), save_item_version(),
-- and the consolidated sessions SELECT policy.
-- ============================================================================

-- H1 FIX: has_function_privilege for BOTH client roles must be false, and the
-- PUBLIC entry must be gone from the ACL entirely (that PUBLIC entry, not the
-- anon/authenticated grants, is what 0005's revoke missed).
do $$
declare v_anon boolean; v_auth boolean; v_acl text;
begin
  select has_function_privilege('anon', p.oid, 'EXECUTE'), has_function_privilege('authenticated', p.oid, 'EXECUTE'),
         coalesce(array_to_string(p.proacl,' '),'(default = PUBLIC)')
  into v_anon, v_auth, v_acl
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='propagate_audio_rating';
  perform verify.assert('h1_fix','H1 FIX: propagate_audio_rating() -- anon/authenticated EXECUTE and the PUBLIC grant',
    'anon=false, authenticated=false, no bare "=X/..." PUBLIC entry',
    'anon='||v_anon||', authenticated='||v_auth||' | acl: '||v_acl,
    not v_anon and not v_auth and v_acl not like '=X/%');
end $$;

do $$
declare v_anon boolean; v_auth boolean; v_acl text;
begin
  select has_function_privilege('anon', p.oid, 'EXECUTE'), has_function_privilege('authenticated', p.oid, 'EXECUTE'),
         coalesce(array_to_string(p.proacl,' '),'(default = PUBLIC)')
  into v_anon, v_auth, v_acl
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='link_researcher_on_signup';
  perform verify.assert('h1_fix','H1 FIX: link_researcher_on_signup() -- anon/authenticated EXECUTE and the PUBLIC grant',
    'anon=false, authenticated=false, no bare "=X/..." PUBLIC entry',
    'anon='||v_anon||', authenticated='||v_auth||' | acl: '||v_acl,
    not v_anon and not v_auth and v_acl not like '=X/%');
end $$;

-- save_item_version(): p_old_item_id = NULL creates version 1, inactive by default
do $$
declare v_id uuid; v_row items%rowtype; v_actual text; v_pass boolean := false;
begin
  begin
    perform verify.become(verify.uid('R1'));
    select save_item_version(null,
      jsonb_build_object('item_code','VT.SIV1','domain','2','response_format','MCQ_TAP','scoring_mode','auto',
                          'is_instruction_replayable',true,'is_stimulus_replayable',true,'stimulus_text','নতুন আইটেম'),
      jsonb_build_array(
        jsonb_build_object('option_key','A','option_text','সঠিক','is_correct',true),
        jsonb_build_object('option_key','B','option_text','ভুল','is_correct',false)
      )) into v_id;
    perform verify.unbecome();
    select * into v_row from items where id = v_id;
    v_actual := 'version='||v_row.version||', active='||v_row.active;
    v_pass := v_row.version = 1 and v_row.active = false;
  exception when others then perform verify.unbecome(); v_actual := SQLSTATE||': '||SQLERRM;
  end;
  perform verify.assert('save_item_version','p_old_item_id=NULL creates version 1, inactive by default',
    'version=1, active=false', v_actual, v_pass);
end $$;

-- superseding produces exactly one active version; options fully replaced
do $$
declare v_v1 uuid; v_v2 uuid; v_actual text; v_pass boolean := false;
begin
  select id into v_v1 from items where item_code='VT.SIV1' and version=1;
  begin
    perform verify.become(verify.uid('R1'));
    select save_item_version(v_v1,
      jsonb_build_object('item_code','VT.SIV1','domain','2','response_format','MCQ_TAP','scoring_mode','auto',
                          'is_instruction_replayable',true,'is_stimulus_replayable',true,
                          'stimulus_text','সংশোধিত আইটেম','active',true),
      jsonb_build_array(
        jsonb_build_object('option_key','A','option_text','নতুন সঠিক','is_correct',true),
        jsonb_build_object('option_key','B','option_text','নতুন ভুল ১','is_correct',false),
        jsonb_build_object('option_key','C','option_text','নতুন ভুল ২','is_correct',false)
      )) into v_v2;
    perform verify.unbecome();
    v_actual := 'active count='||(select count(*) from items where item_code='VT.SIV1' and active)
      ||', v1.active='||(select active from items where id=v_v1)
      ||', v2.active='||(select active from items where id=v_v2)
      ||', v2 options='||(select count(*) from item_options where item_id=v_v2)
      ||', v1 options untouched='||(select count(*) from item_options where item_id=v_v1);
    v_pass := (select count(*) from items where item_code='VT.SIV1' and active) = 1
      and (select active from items where id=v_v1) = false
      and (select active from items where id=v_v2) = true
      and (select count(*) from item_options where item_id=v_v2) = 3
      and (select count(*) from item_options where item_id=v_v1) = 2;
  exception when others then perform verify.unbecome(); v_actual := SQLSTATE||': '||SQLERRM;
  end;
  perform verify.assert('save_item_version','superseding: exactly 1 active version, old options untouched, new options fully replaced',
    '1 active (v2), v1 keeps its 2 options, v2 has its own 3', v_actual, v_pass);
end $$;

-- CRASH SHAPE: a deliberately failing option insert (duplicate option_key) must
-- roll back the WHOLE call -- no orphan new version, superseded item untouched.
do $$
declare v_v2 uuid; v_err text; v_pass boolean := false;
begin
  select id into v_v2 from items where item_code='VT.SIV1' and version=2;
  begin
    perform verify.become(verify.uid('R1'));
    perform save_item_version(v_v2,
      jsonb_build_object('item_code','VT.SIV1','domain','2','response_format','MCQ_TAP','scoring_mode','auto',
                          'is_instruction_replayable',true,'is_stimulus_replayable',true),
      jsonb_build_array(
        jsonb_build_object('option_key','A','option_text','x','is_correct',true),
        jsonb_build_object('option_key','A','option_text','duplicate key -- forces unique_violation mid-loop','is_correct',false)
      ));
    v_err := 'ACCEPTED (unexpected)';
  exception when others then v_pass := true; v_err := SQLSTATE||': '||SQLERRM;
  end;
  perform verify.unbecome();
  perform verify.assert('save_item_version','CRASH SHAPE: duplicate option_key mid-insert raises unique_violation',
    '23505', v_err, v_pass and v_err like '23505%');
end $$;

do $$
declare v_v2 uuid; v_versions int; v_v2_active boolean; v_v3_exists boolean;
begin
  select id into v_v2 from items where item_code='VT.SIV1' and version=2;
  select count(*) into v_versions from items where item_code='VT.SIV1';
  select active into v_v2_active from items where id=v_v2;
  select exists(select 1 from items where item_code='VT.SIV1' and version=3) into v_v3_exists;
  perform verify.assert('save_item_version','CRASH SHAPE: no orphan v3, v2 (being superseded) still active -- not flipped',
    '2 versions total, no v3, v2.active=true',
    v_versions||' versions, v3 exists='||v_v3_exists||', v2.active='||v_v2_active,
    v_versions = 2 and not v_v3_exists and v_v2_active = true);
end $$;

-- save_item_version() rejects a caller without can_manage_items (UOUT is
-- authenticated but not on the researchers allowlist at all)
do $$
declare v_id uuid; v_err text; v_pass boolean := false;
begin
  begin
    perform verify.become(verify.uid('UOUT'));
    select save_item_version(null,
      jsonb_build_object('item_code','VT.FORBIDDEN','domain','2','response_format','MCQ_TAP','scoring_mode','auto'),
      '[]'::jsonb) into v_id;
    v_err := 'ACCEPTED (unexpected) -- returned '||v_id::text;
  exception when others then v_pass := true; v_err := SQLSTATE||': '||SQLERRM;
  end;
  perform verify.unbecome();
  perform verify.assert('save_item_version','caller without can_manage_items is rejected',
    'rejected', v_err, v_pass);
end $$;

do $$
declare v_cnt int;
begin
  select count(*) into v_cnt from items where item_code='VT.FORBIDDEN';
  perform verify.assert('save_item_version','rejected call left no item row behind',
    '0 rows', v_cnt||' rows', v_cnt = 0);
end $$;

-- sessions now has exactly ONE SELECT policy, and owner/researcher/stranger
-- access all still resolve exactly as before the consolidation.
do $$
declare v_n int; v_list text;
begin
  select count(*), coalesce(string_agg(policyname||' ['||cmd||']', ', '),'-') into v_n, v_list
  from pg_policies where schemaname='public' and tablename='sessions' and cmd in ('SELECT','ALL');
  perform verify.assert('sessions_policy','sessions has exactly ONE SELECT policy (was 2 before 0006)',
    '1 policy: sessions_select', v_n||' policy(ies): '||v_list,
    v_n = 1 and v_list = 'sessions_select [SELECT]');
end $$;

do $$
declare v_sid uuid; v_own int; v_res int; v_stranger int;
begin
  perform verify.become(verify.uid('P1'));
  select out_session_id into v_sid from start_session();
  perform verify.unbecome();

  perform verify.become(verify.uid('P1'));
  select count(*) into v_own from sessions where id = v_sid;
  perform verify.unbecome();

  perform verify.become(verify.uid('R1'));
  select count(*) into v_res from sessions where id = v_sid;
  perform verify.unbecome();

  perform verify.become(verify.uid('UOUT'));
  select count(*) into v_stranger from sessions where id = v_sid;
  perform verify.unbecome();

  delete from sessions where id = v_sid;

  perform verify.assert('sessions_policy','consolidated policy: owner sees it, researcher sees it, stranger does not',
    'owner=1, researcher=1, stranger=0',
    'owner='||v_own||', researcher='||v_res||', stranger='||v_stranger,
    v_own = 1 and v_res = 1 and v_stranger = 0);
end $$;

-- Cleanup for this part's fixtures (items created via the RPC, not PART 1).
delete from item_options where item_id in (select id from items where item_code in ('VT.SIV1','VT.FORBIDDEN'));
delete from items where item_code in ('VT.SIV1','VT.FORBIDDEN');


-- ============================================================================
-- RESULTS
-- ============================================================================
select id, section, assertion, expected, actual, pass from verify.results order by id;

select section, count(*) as total,
       count(*) filter (where pass) as passed,
       count(*) filter (where not pass) as failed
from verify.results group by section
union all
select 'TOTAL', count(*), count(*) filter (where pass), count(*) filter (where not pass) from verify.results
order by 1;
