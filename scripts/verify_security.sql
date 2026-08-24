-- ============================================================================
-- BADSQ Platform — Phase 0 security verification suite
--
-- Proves the RLS / privilege model actually holds. Run as `postgres` (Supabase
-- SQL editor, or the MCP execute_sql tool). Re-runnable: PART 1 rebuilds all
-- fixtures from scratch.
--
-- METHOD NOTE. Assertions that need a caller identity use the same mechanism
-- PostgREST and storage-api use internally:
--     set_config('role', 'authenticated', true)
--     set_config('request.jwt.claims', '{"sub":"<uid>","role":"authenticated"}', true)
-- so auth.uid() resolves exactly as it does for a real API request. This is a
-- faithful test of the POLICY. It is not a test of the HTTP transport; the
-- anon-role HTTP path is covered separately by scripts/verify-security.mjs.
--
-- Why impersonation rather than real JWTs: minting a participant JWT needs
-- either Anonymous Sign-ins enabled on the project or the JWT signing secret.
-- Neither was available in the Phase 0 environment. See PHASE_0_REPORT.md.
--
-- Fixture identities:
--   P1    participant browser session 1  (anonymous auth user)
--   P2    participant browser session 2  (anonymous auth user)
--   UOUT  authenticated user NOT on the researchers allowlist
--   R1    authenticated user ON the allowlist, can_rate = can_manage_items = true
--
-- Read results with:
--   select * from verify.results order by id;
-- Tear down with PART 10.
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
  ('S1',    'a0000000-0000-4000-8000-000000000001'),
  ('S2',    'a0000000-0000-4000-8000-000000000002'),
  ('S4',    'a0000000-0000-4000-8000-000000000004'),
  ('IMCQ1', 'b0000000-0000-4000-8000-000000000001'),
  ('IMCQ2', 'b0000000-0000-4000-8000-000000000002'),
  ('INUM1', 'b0000000-0000-4000-8000-000000000003'),
  ('INUM2', 'b0000000-0000-4000-8000-000000000004'),
  ('IAUD',  'b0000000-0000-4000-8000-000000000005'),
  ('ID4',   'b0000000-0000-4000-8000-000000000006');

create or replace function verify.uid(p_k text) returns uuid
language sql stable as $fn$ select v from verify.ids where k = p_k $fn$;

create or replace function verify.assert(
  p_section text, p_assertion text, p_expected text, p_actual text, p_pass boolean
) returns void language sql as $fn$
  insert into verify.results (section, assertion, expected, actual, pass)
  values (p_section, p_assertion, p_expected, p_actual, p_pass);
$fn$;

-- Become a given API identity (mirrors PostgREST's per-request setup).
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

-- The impersonated roles must be able to reach these helpers.
grant usage on schema verify to anon, authenticated;
grant select, insert on verify.results to anon, authenticated;
grant usage, select on sequence verify.results_id_seq to anon, authenticated;
grant select on verify.ids to anon, authenticated;
grant execute on all functions in schema verify to anon, authenticated;

-- ---- clean any prior run's data (children first) ----
delete from audio_recordings where response_id in (
  select r.id from responses r where r.session_id in (select v from verify.ids where k like 'S%'));
delete from responses where session_id in (select v from verify.ids where k like 'S%');
-- NOTE: storage.objects rows are NOT cleaned here. Supabase installs a
-- BEFORE DELETE trigger (storage.protect_delete) that rejects direct SQL
-- deletion even for `postgres`. The storage assertions in PART 8 therefore use a
-- do-and-undo pattern (nested PL/pgSQL block + forced rollback) so no row persists.
delete from sessions where id in (select v from verify.ids where k like 'S%');
delete from sessions where auth_uid in (select v from verify.ids where k in ('P1','P2'));
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
                   is_instruction_replayable, is_stimulus_replayable, correct_answer,
                   scoring_mode, is_practice, is_scored, display_order, active) values
  (verify.uid('IMCQ1'),'VT.MCQ1',1,'2','2.1 Elision','MCQ_TAP','বাংলা শব্দ', true, true, null,'auto',false,true,10,true),
  (verify.uid('IMCQ2'),'VT.MCQ2',1,'2','2.1 Elision','MCQ_TAP','দ্বিতীয় প্রশ্ন', true, true, null,'auto',false,true,20,true),
  (verify.uid('INUM1'),'VT.NUM1',1,'3','3.1 Digit span','NUMERIC_KEYPAD',null, true, false,'42','auto',false,true,30,true),
  (verify.uid('INUM2'),'VT.NUM2',1,'3','3.1 Digit span','NUMERIC_KEYPAD',null, true, false,'5','auto',false,true,40,true),
  (verify.uid('IAUD'), 'VT.AUD1',1,'5','5.2 Spoonerisms','AUDIO_RECORD',null, true, true, null,'human_rated',false,true,50,true),
  -- Domain 4 replayability is still undecided, so this one stays NULL on purpose.
  (verify.uid('ID4'),  'VT.D4',  1,'4','4.1 Rhyme','MCQ_TAP','ছন্দ', true, null, null,'auto',false,true,60,true);

insert into item_options (item_id, option_key, option_text, is_correct) values
  (verify.uid('IMCQ1'),'A','সঠিক উত্তর',true),(verify.uid('IMCQ1'),'B','ভুল ১',false),
  (verify.uid('IMCQ1'),'C','ভুল ২',false),(verify.uid('IMCQ1'),'D','ভুল ৩',false),
  (verify.uid('IMCQ2'),'A','সঠিক উত্তর',true),(verify.uid('IMCQ2'),'B','ভুল ১',false),
  (verify.uid('IMCQ2'),'C','ভুল ২',false),(verify.uid('IMCQ2'),'D','ভুল ৩',false),
  (verify.uid('ID4'),'A','হ্যাঁ',true),(verify.uid('ID4'),'B','না',false);

-- S2 belongs to the other participant; S4 is P1's storage-test session.
-- S1 is deliberately NOT created here — assertion 2.1 creates it as P1 through RLS.
insert into sessions (id, auth_uid, status) values
  (verify.uid('S2'), verify.uid('P2'), 'in_progress'),
  (verify.uid('S4'), verify.uid('P1'), 'in_progress');


-- ============================================================================
-- PART 2 — session ownership and isolation
-- ============================================================================
do $$
declare v_ok boolean := false; v_err text;
begin
  begin
    perform verify.become(verify.uid('P1'));
    insert into sessions (id, auth_uid, status) values (verify.uid('S1'), verify.uid('P1'), 'in_progress');
    v_ok := true;
  exception when others then v_err := SQLSTATE||': '||SQLERRM;
  end;
  perform verify.unbecome();
  perform verify.assert('sessions','P1 inserts its OWN sessions row (auth_uid = auth.uid())',
    'INSERT succeeds', coalesce('ERROR '||v_err,'INSERT succeeded'), v_ok);
end $$;

do $$
declare v_ok boolean := false; v_err text;
begin
  begin
    perform verify.become(verify.uid('P1'));
    insert into sessions (auth_uid, status) values (verify.uid('P2'), 'in_progress');
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
  select count(*) into v_cnt from sessions where id = verify.uid('S2');
  perform verify.unbecome();
  perform verify.assert('sessions','P1 reads P2 session row S2 directly',
    '0 rows', v_cnt||' rows', v_cnt = 0);
end $$;

-- Documents a side effect: participants cannot read their OWN session row either,
-- because sessions_select_researcher is the only SELECT policy.
do $$
declare v_cnt int; v_total int;
begin
  select count(*) into v_total from sessions;
  perform verify.become(verify.uid('P1'));
  select count(*) into v_cnt from sessions;
  perform verify.unbecome();
  perform verify.assert('sessions','P1 unrestricted SELECT on sessions (table really holds '||v_total||' rows)',
    '0 rows visible to participant', v_cnt||' rows visible', v_cnt = 0);
end $$;

do $$
declare v_cnt int;
begin
  perform verify.become(verify.uid('P1'));
  with u as (update sessions set status='abandoned' where id = verify.uid('S2') returning 1)
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
-- PART 3 — answer keys must never reach a participant, by ANY route
-- ============================================================================
do $$
declare v_txt text; v_blocked boolean := false; v_actual text;
begin
  begin
    perform verify.become(verify.uid('P1'));
    select correct_answer into v_txt from items where id = verify.uid('INUM1');
    v_actual := 'LEAKED value = '||coalesce(v_txt,'<null>');
  exception when others then v_blocked := true; v_actual := SQLSTATE||': '||SQLERRM;
  end;
  perform verify.unbecome();
  perform verify.assert('answer_keys','participant SELECT items.correct_answer (base table; real value is 42)',
    'blocked', v_actual, v_blocked);
end $$;

do $$
declare v_b boolean; v_blocked boolean := false; v_actual text;
begin
  begin
    perform verify.become(verify.uid('P1'));
    select is_correct into v_b from item_options where item_id = verify.uid('IMCQ1') and option_key='A';
    v_actual := 'LEAKED value = '||coalesce(v_b::text,'<null>');
  exception when others then v_blocked := true; v_actual := SQLSTATE||': '||SQLERRM;
  end;
  perform verify.unbecome();
  perform verify.assert('answer_keys','participant SELECT item_options.is_correct (base table; real value is true)',
    'blocked', v_actual, v_blocked);
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

-- The other half of the requirement: participants must still be able to READ the
-- item bank through the sanitised views. Expected to FAIL — see finding F1.
do $$
declare v_cnt int; v_actual text; v_pass boolean := false;
begin
  begin
    perform verify.become(verify.uid('P1'));
    select count(*) into v_cnt from public_items;
    v_actual := v_cnt||' rows returned'; v_pass := v_cnt > 0;
  exception when others then v_actual := SQLSTATE||': '||SQLERRM; v_pass := false;
  end;
  perform verify.unbecome();
  perform verify.assert('answer_keys','participant SELECT from public_items view (intended read path; 6 active items exist)',
    '6 rows -- participants must be able to load the item bank', v_actual, v_pass);
end $$;

do $$
declare v_cnt int; v_actual text; v_pass boolean := false;
begin
  begin
    perform verify.become(verify.uid('P1'));
    select count(*) into v_cnt from public_item_options;
    v_actual := v_cnt||' rows returned'; v_pass := v_cnt > 0;
  exception when others then v_actual := SQLSTATE||': '||SQLERRM; v_pass := false;
  end;
  perform verify.unbecome();
  perform verify.assert('answer_keys','participant SELECT from public_item_options view (10 option rows exist)',
    '10 rows -- participants must be able to load options', v_actual, v_pass);
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
  exception when others then v_actual := SQLSTATE||': '||SQLERRM; v_pass := false;
  end;
  perform verify.unbecome();
  perform verify.assert('answer_keys','POSITIVE CONTROL: allowlisted researcher SELECT items.correct_answer',
    '42 -- admin item-bank editor needs this', v_actual, v_pass);
end $$;

do $$
declare v_cnt int; v_actual text; v_pass boolean := false;
begin
  begin
    perform verify.become(verify.uid('R1'));
    select count(*) into v_cnt from items;
    v_actual := v_cnt||' rows'; v_pass := v_cnt = 6;
  exception when others then v_actual := SQLSTATE||': '||SQLERRM; v_pass := false;
  end;
  perform verify.unbecome();
  perform verify.assert('answer_keys','POSITIVE CONTROL: allowlisted researcher SELECT count(*) from items',
    '6 rows', v_actual, v_pass);
end $$;


-- ============================================================================
-- PART 4 — export surfaces and participant confidentiality
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

-- ml_snapshots was created in 0001 but never had RLS enabled by 0002 or 0003.
do $$
declare v_rls boolean; v_cnt int; v_actual text; v_safe boolean := false;
begin
  select relrowsecurity into v_rls from pg_class c join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relname='ml_snapshots';
  perform verify.assert('export','ml_snapshots has RLS enabled?','RLS enabled',
    case when v_rls then 'enabled' else 'NOT ENABLED' end, v_rls);

  insert into ml_snapshots (anonymized_code, class_grade, item_code, is_correct)
  values ('SNAPSHOT-CANARY', 7, 'VT.MCQ1', true);

  begin
    perform verify.become_anon();
    select count(*) into v_cnt from ml_snapshots where anonymized_code='SNAPSHOT-CANARY';
    v_actual := 'READABLE -- '||v_cnt||' canary row(s) visible to anon';
    v_safe := (v_cnt = 0);
  exception when others then v_safe := true; v_actual := SQLSTATE||': '||SQLERRM;
  end;
  perform verify.unbecome();
  perform verify.assert('export','anon SELECT from ml_snapshots (holds the flattened export snapshot)',
    'blocked or 0 rows', v_actual, v_safe);
end $$;

do $$
declare v_ins boolean := false; v_del int := -1; v_actual text;
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
      perform verify.assert('export','anon INSERT/DELETE on ml_snapshots','blocked',
        SQLSTATE||': '||SQLERRM, true);
      return;
    end if;
  end;
  v_actual := 'INSERT succeeded='||v_ins||'; DELETE removed '||v_del||' real snapshot row(s) (rolled back by test)';
  perform verify.assert('export','anon INSERT/DELETE on ml_snapshots','blocked', v_actual, false);
end $$;

delete from ml_snapshots where anonymized_code in ('SNAPSHOT-CANARY','ANON-INJECTED');


-- ============================================================================
-- PART 5 — submit_session(): the happy path and server-side auto-scoring
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
      'audio_storage_path', verify.uid('S1')::text||'/aud-1.webm',
      'audio_mime_type','audio/webm;codecs=opus','audio_duration_ms',2400,'audio_file_size_bytes',31500)
  );
  begin
    perform verify.become(verify.uid('P1'));
    select submit_session(verify.uid('S1'),
      jsonb_build_object('anonymized_code','VT-P1-001','class_grade','7','age_months','151'),
      v_payload) into v_pid;
    v_actual := 'returned participant_id '||v_pid::text; v_pass := v_pid is not null;
  exception when others then v_actual := SQLSTATE||': '||SQLERRM; v_pass := false;
  end;
  perform verify.unbecome();
  perform verify.assert('submit','submit_session() as owner P1 on in_progress session S1',
    'returns a new participant uuid', v_actual, v_pass);
end $$;

do $$
declare v jsonb;
begin
  select jsonb_object_agg(i.item_code, jsonb_build_object('is_correct', r.is_correct, 'scored_by', r.scored_by))
  into v from responses r join items i on i.id = r.item_id where r.session_id = verify.uid('S1');

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
declare v_status text; v_ended timestamptz; v_pid uuid; v_code text; v_aud int;
        v_f double precision; v_l double precision;
begin
  select status, ended_at, participant_id into v_status, v_ended, v_pid from sessions where id = verify.uid('S1');
  select anonymized_code into v_code from participants where id = v_pid;
  select count(*) into v_aud from audio_recordings a join responses r on r.id=a.response_id
   where r.session_id = verify.uid('S1');
  select response_latency_from_first_ms, response_latency_from_last_ms into v_f, v_l
    from responses where session_id = verify.uid('S1') and item_id = verify.uid('IMCQ1');

  perform verify.assert('submit','session S1 finalised by RPC',
    'status=completed, ended_at set, participant linked',
    'status='||v_status||', ended_at='||coalesce(v_ended::text,'NULL')||', participant='||coalesce(v_code,'NULL'),
    v_status='completed' and v_ended is not null and v_code='VT-P1-001');

  perform verify.assert('submit','audio_recordings row created from audio_storage_path',
    '1 row', v_aud||' row(s)', v_aud = 1);

  perform verify.assert('submit','dual latency anchors persisted (sent from_first=3500.75, from_last=301.0)',
    'from_first=3500.75, from_last=301',
    'from_first='||coalesce(v_f::text,'NULL')||', from_last='||coalesce(v_l::text,'NULL'),
    v_f = 3500.75 and v_l = 301.0);
end $$;


-- ============================================================================
-- PART 6 — submit_session(): rejection paths and atomicity
-- ============================================================================
do $$
declare v_pid uuid; v_actual text; v_pass boolean := false;
begin
  begin
    perform verify.become(verify.uid('P2'));
    select submit_session(verify.uid('S1'),
      jsonb_build_object('anonymized_code','VT-HIJACK','class_grade','7'),
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
    select submit_session(verify.uid('S1'),
      jsonb_build_object('anonymized_code','VT-P1-DUP','class_grade','7'),
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
    select submit_session(verify.uid('S2'),
      jsonb_build_object('anonymized_code','VT-ANON','class_grade','7'),
      jsonb_build_array(jsonb_build_object('item_id', verify.uid('IMCQ1')::text,'selected_option_key','A'))) into v_pid;
    v_actual := 'ACCEPTED -- returned '||v_pid::text;
  exception when others then v_pass := true; v_actual := SQLSTATE||': '||SQLERRM;
  end;
  perform verify.unbecome();
  perform verify.assert('submit','submit_session() as unauthenticated anon (auth.uid() is NULL)','rejected', v_actual, v_pass);
end $$;

do $$
declare v_pid uuid; v_err text; v_parts int; v_resp int; v_status text; v_actual text;
begin
  begin
    perform verify.become(verify.uid('P2'));
    select submit_session(verify.uid('S2'),
      jsonb_build_object('anonymized_code','VT-P2-ATOMIC','class_grade','8'),
      jsonb_build_array(
        jsonb_build_object('item_id', verify.uid('IMCQ1')::text,'selected_option_key','A'),
        jsonb_build_object('item_id','cccccccc-0000-4000-8000-00000000dead','selected_option_key','B')
      )) into v_pid;
    v_err := 'ACCEPTED (unexpected)';
  exception when others then v_err := SQLSTATE||': '||SQLERRM;
  end;
  perform verify.unbecome();
  select count(*) into v_parts from participants where anonymized_code='VT-P2-ATOMIC';
  select count(*) into v_resp  from responses where session_id = verify.uid('S2');
  select status into v_status from sessions where id = verify.uid('S2');
  v_actual := 'error='||v_err||' | participants='||v_parts||', responses='||v_resp||', S2 status='||v_status;
  perform verify.assert('submit','ATOMICITY: submit with one unknown item_id rolls back completely',
    'rejected AND 0 participants, 0 responses, S2 still in_progress', v_actual,
    v_parts = 0 and v_resp = 0 and v_status = 'in_progress' and v_err like '%Unknown item_id%');
end $$;


-- ============================================================================
-- PART 7 — audio rating propagation trigger
-- ============================================================================
do $$
declare v_total int; v_uout int; v_anon int; v_res int;
begin
  select count(*) into v_total from participants;
  perform verify.become(verify.uid('UOUT'));
  select count(*) into v_uout from participants;
  perform verify.unbecome();
  perform verify.become_anon();
  select count(*) into v_anon from participants;
  perform verify.unbecome();
  perform verify.become(verify.uid('R1'));
  select count(*) into v_res from participants;
  perform verify.unbecome();
  perform verify.assert('participants','RE-CHECK with real data: participants table now holds '||v_total||' row(s)',
    'non-allowlisted=0, anon=0, researcher='||v_total,
    'non-allowlisted='||v_uout||', anon='||v_anon||', researcher='||v_res,
    v_uout = 0 and v_anon = 0 and v_res = v_total and v_total > 0);
end $$;

-- The production path: a real allowlisted rater sets primary_rating.
do $$
declare v_aid uuid; v_rid uuid; v_upd int; v_ic boolean; v_sb text; v_err text; v_actual text;
begin
  select a.id, r.id into v_aid, v_rid
  from audio_recordings a join responses r on r.id = a.response_id
  where r.session_id = verify.uid('S1');

  begin
    perform verify.become(verify.uid('R1'));
    with u as (
      update audio_recordings
      set primary_rating = true,
          primary_rater_id = (select id from researchers where email='rater1@badsq-verify.test'),
          primary_rated_at = now(),
          rating_status = 'rated'
      where id = v_aid returning 1)
    select count(*) into v_upd from u;
  exception when others then v_err := SQLSTATE||': '||SQLERRM; v_upd := -1;
  end;
  perform verify.unbecome();

  select is_correct, scored_by into v_ic, v_sb from responses where id = v_rid;
  v_actual := 'audio rows updated='||v_upd||coalesce(' err='||v_err,'')
              ||' | responses.is_correct='||coalesce(v_ic::text,'NULL')
              ||', scored_by='||coalesce(v_sb,'NULL');
  perform verify.assert('rating_trigger','trg_propagate_audio_rating fired by allowlisted rater R1 (can_rate=true)',
    'responses.is_correct=true, scored_by=human', v_actual, v_ic is true and v_sb = 'human');
end $$;

-- Diagnostic: the same trigger under a BYPASSRLS role, to isolate cause.
do $$
declare v_aid uuid; v_rid uuid; v_ic boolean; v_sb text;
begin
  select a.id, r.id into v_aid, v_rid
  from audio_recordings a join responses r on r.id = a.response_id
  where r.session_id = verify.uid('S1');
  update audio_recordings set primary_rating = false where id = v_aid;
  select is_correct, scored_by into v_ic, v_sb from responses where id = v_rid;
  perform verify.assert('rating_trigger','DIAGNOSTIC: same trigger run as postgres (BYPASSRLS)',
    'responses.is_correct=false, scored_by=human',
    'responses.is_correct='||coalesce(v_ic::text,'NULL')||', scored_by='||coalesce(v_sb,'NULL'),
    v_ic is false and v_sb = 'human');
end $$;

do $$
declare v_n int; v_list text;
begin
  select count(*), coalesce(string_agg(policyname||'('||cmd||')', ', '),'(none)')
  into v_n, v_list from pg_policies where schemaname='public' and tablename='responses';
  perform verify.assert('rating_trigger','policies present on responses (trigger needs an UPDATE path)',
    'at least one UPDATE (or ALL) policy', v_n||' policy(ies): '||v_list,
    exists(select 1 from pg_policies where schemaname='public' and tablename='responses' and cmd in ('UPDATE','ALL')));
end $$;

do $$
declare v_aid uuid; v_upd int; v_err text; v_pass boolean := false;
begin
  select a.id into v_aid from audio_recordings a join responses r on r.id=a.response_id
   where r.session_id = verify.uid('S1');
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
-- PART 8 — storage upload policies (badsq-audio)
--
-- These use direct INSERT on storage.objects, which is exactly what storage-api
-- does under the hood, so the RLS policy is exercised faithfully. The positive
-- case is wrapped in a do-and-undo block because storage.protect_delete makes
-- the row impossible to remove afterwards by SQL.
-- ============================================================================
do $$
declare v_ok boolean := false; v_actual text;
begin
  begin
    perform verify.become(verify.uid('P1'));
    insert into storage.objects (bucket_id, name, owner, owner_id)
    values ('badsq-audio', verify.uid('S4')::text||'/aud-own.webm', verify.uid('P1'), verify.uid('P1')::text);
    v_ok := true;
    perform verify.unbecome();
    raise exception using errcode='ZZ002', message='__UNDO__';
  exception when others then
    perform verify.unbecome();
    if SQLERRM <> '__UNDO__' then v_ok := false; v_actual := SQLSTATE||': '||SQLERRM; end if;
  end;
  perform verify.assert('storage','P1 uploads to badsq-audio/<own in_progress session S4>/aud-own.webm',
    'INSERT succeeds', coalesce(v_actual,'INSERT succeeded'), v_ok);
end $$;

do $$
declare v_blocked boolean := false; v_actual text;
begin
  begin
    perform verify.become(verify.uid('P1'));
    insert into storage.objects (bucket_id, name, owner, owner_id)
    values ('badsq-audio', verify.uid('S2')::text||'/aud-steal.webm', verify.uid('P1'), verify.uid('P1')::text);
    v_actual := 'INSERT UNEXPECTEDLY SUCCEEDED';
    perform verify.unbecome();
    raise exception using errcode='ZZ003', message='__UNDO__';
  exception when others then
    perform verify.unbecome();
    if SQLERRM = '__UNDO__' then v_blocked := false;
    else v_blocked := true; v_actual := SQLSTATE||': '||SQLERRM; end if;
  end;
  perform verify.assert('storage','P1 uploads to badsq-audio/<P2 session S2>/aud-steal.webm',
    'INSERT rejected by RLS', v_actual, v_blocked);
end $$;

do $$
declare v_blocked boolean := false; v_actual text;
begin
  begin
    perform verify.become_anon();
    insert into storage.objects (bucket_id, name)
    values ('badsq-audio', verify.uid('S4')::text||'/aud-anon.webm');
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
    values ('badsq-audio', verify.uid('S1')::text||'/aud-late.webm', verify.uid('P1'), verify.uid('P1')::text);
    v_actual := 'INSERT SUCCEEDED';
    perform verify.unbecome();
    raise exception using errcode='ZZ005', message='__UNDO__';
  exception when others then
    perform verify.unbecome();
    if SQLERRM = '__UNDO__' then v_blocked := false;
    else v_blocked := true; v_actual := SQLSTATE||': '||SQLERRM; end if;
  end;
  perform verify.assert('storage','P1 uploads under its OWN but already-completed session S1',
    'rejected (documents ordering constraint: upload BEFORE submit_session)', v_actual, v_blocked);
end $$;

do $$
declare v_res int; v_part int; v_anon int; v_actual text;
begin
  begin
    insert into storage.objects (bucket_id, name, owner, owner_id)
    values ('badsq-audio', verify.uid('S4')::text||'/aud-read-probe.webm', verify.uid('P1'), verify.uid('P1')::text);
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
  perform verify.assert('storage','read access to badsq-audio objects (1 probe object present)',
    'researcher=1, participant=0, anon=0', v_actual, v_res = 1 and v_part = 0 and v_anon = 0);
end $$;

-- Diagnostic for the upload policy: evaluate its own EXISTS predicate per role.
do $$
declare v_as_p1 boolean; v_as_pg boolean; v_name text;
begin
  v_name := verify.uid('S4')::text||'/aud-own.webm';
  perform verify.become(verify.uid('P1'));
  select exists (select 1 from sessions s
                 where s.auth_uid = auth.uid() and s.status = 'in_progress'
                   and (storage.foldername(v_name))[1] = s.id::text) into v_as_p1;
  perform verify.unbecome();
  select exists (select 1 from sessions s
                 where s.auth_uid = verify.uid('P1') and s.status = 'in_progress'
                   and (storage.foldername(v_name))[1] = s.id::text) into v_as_pg;
  perform verify.assert('storage',
    'DIAGNOSTIC: policy EXISTS predicate evaluated as P1 vs as postgres (row genuinely exists)',
    'true as P1 (row exists and is owned by P1)',
    'as P1 = '||v_as_p1||' | as postgres (RLS bypassed) = '||v_as_pg, v_as_p1 = v_as_pg);
end $$;

do $$
declare v_list text;
begin
  select coalesce(string_agg(policyname||' ['||cmd||'] using='||coalesce(qual,'-'), E'\n'), '(none)')
  into v_list from pg_policies
  where schemaname='public' and tablename='sessions' and cmd in ('SELECT','ALL');
  perform verify.assert('storage',
    'sessions SELECT policies (the storage policy subquery and the resume flow both need one)',
    'a policy allowing a participant to see its own session row', v_list,
    exists(select 1 from pg_policies where schemaname='public' and tablename='sessions'
           and cmd in ('SELECT','ALL') and qual like '%auth_uid%'));
end $$;


-- ============================================================================
-- PART 9 — Unicode integrity, item-bank quality, and hardening audit
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
  perform verify.assert('unicode','all Bangla fixture text is valid UTF-8 in a UTF8 database',
    'UTF8', (select pg_encoding_to_char(encoding) from pg_database where datname=current_database()),
    (select pg_encoding_to_char(encoding) from pg_database where datname=current_database()) = 'UTF8');
end $$;

-- Standing item-bank data-quality checks from design doc section 6.
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

do $$
declare v_cols text; v_has_first boolean;
begin
  select string_agg(column_name, ', ' order by ordinal_position) into v_cols
  from information_schema.columns where table_schema='public' and table_name='ml_export_v1';
  v_has_first := v_cols like '%from_first%';
  perform verify.assert('export','ml_export_v1 exposes BOTH latency anchors after the 0003 rename',
    'a from_first column and a from_last column',
    'latency-related columns present: '||
      coalesce((select string_agg(column_name,', ') from information_schema.columns
                where table_schema='public' and table_name='ml_export_v1' and column_name like '%latenc%'),'(none)'),
    v_has_first);
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
declare v_secdef boolean;
begin
  select prosecdef into v_secdef from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='propagate_audio_rating';
  perform verify.assert('hardening','propagate_audio_rating() runs with definer rights (needed to write responses under RLS)',
    'SECURITY DEFINER', case when v_secdef then 'SECURITY DEFINER' else 'SECURITY INVOKER (runs as caller)' end,
    v_secdef);
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
-- PART 10 — teardown (run separately when finished inspecting results)
--
-- Leaves behind: storage.objects rows cannot be removed by SQL
-- (storage.protect_delete). The suite avoids creating any that persist.
-- ============================================================================
-- delete from audio_recordings where response_id in (
--   select r.id from responses r where r.session_id in (select v from verify.ids where k like 'S%'));
-- delete from responses where session_id in (select v from verify.ids where k like 'S%');
-- delete from sessions where auth_uid in (select v from verify.ids where k in ('P1','P2'));
-- delete from participants where created_by_auth_uid in (select v from verify.ids where k in ('P1','P2'));
-- delete from item_options where item_id in (select v from verify.ids where k like 'I%');
-- delete from items where id in (select v from verify.ids where k like 'I%');
-- delete from researchers where email like '%@badsq-verify.test';
-- delete from auth.users where id in (select v from verify.ids where k in ('P1','P2','UOUT','R1'));
-- drop schema verify cascade;
