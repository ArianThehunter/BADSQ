# Migration 0004 Report — BADSQ Platform

Follow-up to [PHASE_0_REPORT.md](PHASE_0_REPORT.md). Same reporting format.

## 1. Scope

Apply migration `0004_phase0_defect_fixes.sql` — which fixes findings F1–F7 from the Phase 0
report and adds three new capabilities (an item-audio storage bucket, server-issued participant
codes, and paper-consent linkage) — then verify every fix against the assertion suite and report
failures rather than patching around them. Because 0004 changes two contracts (sessions are now
opened by `start_session()`, and `submit_session()` takes the participant code from the session
row rather than the client payload), the suite had to be updated to test the new intended
behaviour, and a new assertion added to prove the tamper resistance that change buys. As with
Phase 0, 0004 arrived untested against a live instance.

## 2. Completed

- [x] Migration 0004 applied to the live project, in order after 0001–0003 — `supabase/migrations/0004_phase0_defect_fixes.sql`
- [x] Verification suite rewritten for the new contracts, 58 → 73 assertions — `scripts/verify_security.sql`
- [x] HTTP suite extended for the 0004 surfaces, 21 → 25 assertions — `scripts/verify-security.mjs`
- [x] F1–F7 each re-verified against the live database — §4
- [x] New capabilities verified: `start_session()`, item-audio bucket, consent linkage — §4
- [x] Tamper-resistance assertion added and passing (client-supplied code is ignored) — §4
- [x] Security and performance advisors re-run — §4.3
- [x] TypeScript types regenerated from the changed schema — `src/types/database.types.ts`
- [x] `startSession()` client helper added — `src/lib/supabaseClient.ts`
- [x] Status page updated to surface the one remaining client-visible defect — `src/App.tsx`
- [x] All fixtures torn down; every table verified empty afterwards

## 3. Not completed / deferred

- [ ] **Anonymous Sign-ins still not enabled** — dashboard-only, unchanged from Phase 0. Still `422 anonymous_provider_disabled`.
- [ ] **End-to-end GoTrue signup not exercised** — see §6 under F2. The free-tier email rate limit (2/hour) was exhausted by the probes. F2 is verified at the database layer instead, which is where the defect was.
- [ ] **HTTP-level tests for authenticated identities** — same limitation as Phase 0. Real JWTs still require either Anonymous Sign-ins or the JWT signing secret.
- [ ] **`researchers` allowlist still empty**, project still on the **Free** plan — unchanged, both need a human.
- [ ] All Phase 1/2 components — still out of scope.

## 4. Verification results

**Migration 0004 applied with zero SQL errors.** Every finding below is a runtime or design
defect that only surfaced under test.

**Totals: 98 assertions, 93 passed, 5 failed.** Up from Phase 0's 79 assertions / 58 passed /
21 failed. All six database-layer blockers are fixed.

### 4.1 SQL suite — `scripts/verify_security.sql`, 73 assertions, 70 passed, 3 failed

Fix verification first — these are the assertions that failed in Phase 0 and were expected to
flip:

| Check | Expected | Actual | Pass/Fail |
|---|---|---|---|
| **F1** participant `SELECT` from `public_items` | 6 rows | 6 rows returned | **Pass (was Fail)** |
| **F1** participant `SELECT` from `public_item_options` | 10 rows | 10 rows returned | **Pass (was Fail)** |
| **F1** anon `SELECT` from `public_items` (pre-sign-in bootstrap) | 6 rows | 6 rows returned | **Pass (new)** |
| **F1** POSITIVE CONTROL: researcher reads `items.correct_answer` | `42` | `42` | **Pass (was Fail)** |
| **F1** POSITIVE CONTROL: researcher `count(*)` on `items` | 6 rows | 6 rows | **Pass (was Fail)** |
| **F3** `ml_snapshots` has RLS enabled | RLS enabled | enabled | **Pass (was Fail)** |
| **F3** anon `SELECT` from `ml_snapshots` | blocked or 0 rows | `42501: permission denied for table ml_snapshots` | **Pass (was Fail)** |
| **F3** anon `INSERT`/`DELETE` on `ml_snapshots` | blocked | `42501: permission denied for table ml_snapshots` | **Pass (was Fail)** |
| **F4** rating propagation by allowlisted rater R1 | `is_correct=true, scored_by=human` | audio rows updated=1, `is_correct=true, scored_by=human` | **Pass (was Fail)** |
| **F4** rating flipped to false propagates too | `is_correct=false` | `is_correct=false` | **Pass (new)** |
| **F4** `propagate_audio_rating()` has definer rights | SECURITY DEFINER | SECURITY DEFINER | **Pass (was Fail)** |
| **F5** `ml_export_v1` exposes both latency anchors | `…from_first_ms` and `…from_last_ms` | `response_latency_from_first_ms, response_latency_from_last_ms` | **Pass (was Fail)** |
| **F6** P1 uploads to `badsq-audio/<own in_progress session>/` | INSERT succeeds | INSERT succeeded | **Pass (was Fail)** |
| **F6** DIAGNOSTIC: policy `EXISTS` predicate as P1 | true | *(assertion retired — the predicate now resolves, proven by the upload succeeding)* | n/a |
| **F7** P1 sees its own sessions rows and no one else's | own rows only, 0 of another's | 3 visible, 0 another participant's | **Pass (was Fail)** |

The negative storage cases that passed *vacuously* in Phase 0 (because the policy denied
everything) now discriminate correctly, since the positive case succeeds:

| Check | Expected | Actual | Pass/Fail |
|---|---|---|---|
| P1 uploads to `badsq-audio/<P2's session>/` | rejected | `42501: new row violates row-level security policy for table "objects"` | Pass |
| Unauthenticated anon uploads to `badsq-audio` | rejected | `42501: new row violates row-level security policy` | Pass |
| P1 uploads under its own but **completed** session | rejected (upload before submit) | `42501: new row violates row-level security policy` | Pass |
| Read access to `badsq-audio` recordings (1 probe object) | researcher 1, participant 0, anon 0 | researcher=1, participant=0, anon=0 | Pass |

New capability: server-issued participant codes.

| Check | Expected | Actual | Pass/Fail |
|---|---|---|---|
| `start_session()` as P1 returns session id + code | both non-null | session + code returned | Pass |
| Session row created by `start_session()` | owned by P1, `in_progress`, code persisted | owner=true, status=in_progress, code persisted | Pass |
| Code format excludes ambiguous glyphs I/O/0/1 | `^BADSQ-[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}$` | matched | Pass |
| `start_session()` as unauthenticated anon | rejected | `P0001: start_session: no authenticated identity` | Pass |
| 25 consecutively issued codes are distinct | 25 distinct | 25 distinct of 25 | Pass |
| **TAMPER TEST** — client sent `anonymized_code=ATTACKER-SUPPLIED` | server uses the session's `assigned_code` | `participants.anonymized_code` = the session code, not the client's | **Pass** |
| `submit_session()` on a directly-INSERTed session (`assigned_code` NULL) | rejected | `P0001: Session not found, not owned by caller, or already submitted` | Pass |

New capability: item-audio bucket and consent linkage.

| Check | Expected | Actual | Pass/Fail |
|---|---|---|---|
| Researcher with `can_manage_items` uploads item audio | INSERT succeeds | INSERT succeeded | Pass |
| Participant uploads to `badsq-item-audio` | rejected | `42501: new row violates row-level security policy` | Pass |
| Read access to `badsq-item-audio` (1 probe object) | researcher 1, live participant 1, no-session user 0, anon 0 | researcher=1, participant with in_progress session=1, authenticated user with NO session=0, anon=0 | Pass |
| `consent_records` digitizable before the participant row exists | `participant_id` nullable + `assigned_code` present | `is_nullable=YES`, `assigned_code` present | Pass |
| A consent row joins to its session via `assigned_code` | join resolves | join resolved | Pass |
| `consent_records.assigned_code` has FK / uniqueness | FK and/or UNIQUE | **0 FK constraints, 0 unique indexes** | **Fail (G2)** |

Retained from Phase 0 and still passing — abbreviated, all 13 `submit_session` scoring and
atomicity assertions, all 6 session-isolation assertions, all 4 participant-confidentiality
assertions, all 3 Unicode assertions, all 3 item-bank assertions. Notably:

| Check | Expected | Actual | Pass/Fail |
|---|---|---|---|
| Participant `SELECT` on `items` base table (grant restored by 0004) | 0 rows, no value leaked | 0 item rows visible; `correct_answer = <none>` | Pass |
| Participant `SELECT` on `item_options` base table | 0 rows, no value leaked | 0 option rows visible; `is_correct = <none>` | Pass |
| anon `SELECT items.correct_answer` | blocked | `42501: permission denied for table items` | Pass |
| ATOMICITY: submit with one unknown `item_id` | rejected, nothing written | `P0001: Unknown item_id: …dead \| new participants=0, responses=0, S2 status=in_progress` | Pass |
| MCQ_TAP / NUMERIC_KEYPAD right and wrong auto-scoring | 4 assertions | all `scored_by=system`, correct booleans | Pass |
| Bangla `stimulus_text` round-trip | `বাংলা শব্দ` (10 chars, 28 bytes) | `বাংলা শব্দ` (chars=10, bytes=28) | Pass |

The three failures:

| Check | Expected | Actual | Pass/Fail |
|---|---|---|---|
| `public_items` audio column names match the renamed base table | view matches base: `instruction_audio_path, stimulus_audio_path` | view exposes: `instruction_audio_url, stimulus_audio_url` | **Fail (G1)** |
| `consent_records.assigned_code` has referential integrity / uniqueness | FK and/or UNIQUE | 0 FK constraint(s), 0 unique index(es) | **Fail (G2)** |
| SECURITY DEFINER functions with no pinned `search_path` | 0 functions | `3: can_manage_items, can_rate, is_researcher` | **Fail (G3)** |

### 4.2 HTTP suite — `scripts/verify-security.mjs`, 25 assertions, 23 passed, 2 failed

| Check | Expected | Actual | Pass/Fail |
|---|---|---|---|
| `GET /rest/v1/public_items` (participant read path) | HTTP 200, readable | `HTTP 200, 6 rows` | **Pass (was Fail)** |
| `GET /rest/v1/public_item_options` | HTTP 200, readable | `HTTP 200, 10 rows` | **Pass (was Fail)** |
| `POST /rest/v1/ml_snapshots` (inject a row) | denied | `HTTP 401 · 42501 permission denied for table ml_snapshots` | **Pass (was Fail)** |
| `GET /rest/v1/ml_snapshots` (read canary back) | denied or 0 rows | `HTTP 401 · 42501 permission denied` | **Pass (was Fail)** |
| `DELETE /rest/v1/ml_snapshots` | denied | `HTTP 401 · 42501 permission denied` | **Pass (was Fail)** |
| `GET /rest/v1/public_items?select=*` body contains no answer-key field | no `correct_answer` / `is_correct` | HTTP 200, 6 rows, neither field present | **Pass (new)** |
| `POST /rest/v1/rpc/start_session` (no user JWT) | rejected | `HTTP 400 · P0001 start_session: no authenticated identity` | **Pass (new)** |
| `POST /storage/v1/object/list/badsq-item-audio` as anon | denied or empty | `HTTP 200, 0 rows` | **Pass (new)** |
| `GET /rest/v1/items?select=correct_answer` | denied | `HTTP 401 · 42501 permission denied for table items` | Pass |
| `GET /rest/v1/item_options?select=is_correct` | denied | `HTTP 401 · 42501 permission denied for table item_options` | Pass |
| `GET /rest/v1/public_items?select=*,item_options(*)` (embed to reach key) | no `is_correct` | `HTTP 401 · 42501 permission denied for table item_options` | Pass |
| `GET /rest/v1/ml_export_v1?select=*` | denied or 0 rows | `HTTP 401 · 42501 permission denied for view ml_export_v1` | Pass |
| `POST /rest/v1/rpc/submit_session` for an unowned session | rejected | `HTTP 400 · P0001 Session not found, not owned by caller, or already submitted` | Pass |
| `POST /storage/v1/object/badsq-audio/<session>/anon.webm` | denied | `HTTP 400 · 403 Unauthorized, "new row violates row-level security policy"` | Pass |
| participants / responses / sessions / researchers / consent_records as anon | denied or 0 rows | `HTTP 200, 0 rows` each | Pass |
| `GET /rest/v1/public_items` selecting the renamed audio path columns | HTTP 200 | **`HTTP 400 · 42703 column public_items.instruction_audio_path does not exist`** | **Fail (G1)** |
| Anonymous sign-in enabled (handoff setup step 3) | HTTP 200 with access_token | `HTTP 422 · anonymous_provider_disabled` | **Fail (setup, §3)** |

### 4.3 Supabase advisors

Run after teardown.

**Security — 2 ERROR, 15 WARN** (Phase 0 was 1 ERROR, 15 WARN):

| Level | Lint | Detail |
|---|---|---|
| ~~ERROR~~ | `rls_disabled_in_public` | **Resolved.** `ml_snapshots` no longer flagged — F3 fixed. |
| **ERROR ×2** | `security_definer_view` | `public_items`, `public_item_options` — [remediation](https://supabase.com/docs/guides/database/database-linter?lint=0010_security_definer_view). **Intentional**, and 0004 says so explicitly. See G4 for why I agree, and what I checked before agreeing. |
| WARN ×4 | `function_search_path_mutable` | `generate_participant_code` (new in 0004), `is_researcher`, `can_manage_items`, `can_rate`. `link_researcher_on_signup` and `propagate_audio_rating` are **no longer listed** — 0004 pinned them. See G3. |
| WARN ×6 | `anon_security_definer_function_executable` | Now also includes `start_session` (intentional) and `propagate_audio_rating` (unintentional — see G5). |
| WARN ×6 | `authenticated_security_definer_function_executable` | Same six functions. |
| WARN | `auth_leaked_password_protection` | Irrelevant — magic link and anonymous sign-in only, no passwords. |

**Performance — 3 WARN, 11 INFO.** Unchanged in character from Phase 0: three
`auth_rls_initplan` warnings (now on `sessions_insert_own`, `sessions_update_own_in_progress`,
`sessions_select_own`, `participants_insert_own`), unindexed foreign keys, and unused indexes on
a project with no traffic. The `multiple_permissive_policies` warnings on `items` /
`item_options` are **gone** — 0004 dropped the overlapping public policies, as predicted.

Two new INFO-level items worth noting for later: `sessions.assigned_code` gained a unique index
(good), and `consent_records.assigned_code` has a plain index but no unique constraint (see G2).

## 5. Deviations from the brief

1. **The assertion suite was rewritten, not merely re-run.** The brief said to verify with "the
   existing assertion suite", but 0004 deliberately changed two contracts, so some Phase 0
   assertions no longer described intended behaviour:
   - Sessions now come from `start_session()`, so fixtures use the RPC instead of fixed UUIDs.
   - `submit_session()` ignores the client's `anonymized_code`, so the old assertion checking it
     equalled the payload value was inverted into a **tamper test** asserting it does *not*.
   - F7 deliberately lets a participant read its own session row, so "0 rows visible" became
     "own rows only, and none belonging to anyone else" — a stricter check, not a looser one.
   Every other assertion kept its original expectation. Assertions that were expected to fail
   before 0004 kept their expectation and now pass. I have flagged this prominently in the
   suite header so nobody mistakes a contract update for a relaxed test.
2. **F2 is verified at the database layer, not through GoTrue end-to-end.** Justified in §6.
3. Everything else as in the Phase 0 report; no migration SQL was altered.

## 6. Problems, errors, and blockers

Ordered by severity. Only G1 blocks Phase 1.

---

### G1 — BLOCKER for Phase 1 audio. The audio column rename never reached the participant view

0004 renamed the base columns:

```sql
alter table items rename column instruction_audio_url to instruction_audio_path;
alter table items rename column stimulus_audio_url   to stimulus_audio_path;
```

but never recreated `public_items`. Postgres rewrites a view's *definition* on a base-column
rename, but does **not** rename the view's *output* column. So:

| Relation | Audio columns |
|---|---|
| `items` (base) | `instruction_audio_path`, `stimulus_audio_path` |
| `public_items` (participant read path) | `instruction_audio_url`, `stimulus_audio_url` |

Verbatim, over real HTTP:

```
GET /rest/v1/public_items?select=item_code,instruction_audio_path,stimulus_audio_path
HTTP 400 {"code":"42703","message":"column public_items.instruction_audio_path does not exist"}
```

This is **the same class of defect as F5**, which 0004 was fixing at the time — F5 existed
because 0003 renamed latency columns without recreating `ml_export_v1`. 0004 correctly recreated
`ml_export_v1`, then reintroduced the identical bug on `public_items`. The generated TypeScript
types now encode the mismatch, so it is visible at compile time as well as runtime.

Consequence: TestRunner cannot resolve item audio, and this instrument is audio-first by design —
the participant hears every instruction and stimulus. The fix is a one-line `create or replace
view public_items` with the new column names. I have not applied it.

### G2 — Data integrity. The paper-consent join key has no referential integrity

`consent_records.assigned_code` is the join between the paper parental-consent form (which
carries criterion indicators Q1–Q3) and the anonymous digital session. 0004's own comment says
that without it "the Section 10.2 classification rule is uncomputable". But the column is a bare
`text` with only a non-unique index:

```
0 FK constraint(s), 0 unique index(es)
```

Two concrete failure modes, both silent:

- **A typo during digitization produces an orphan.** A code mistyped from paper simply never
  joins. The consent row exists, the session exists, and the participant is quietly dropped from
  the criterion-classified sample with no error anywhere. Given the code is *designed* to be
  hand-transcribed and read back by a different person, transcription error is expected, not
  hypothetical — that is exactly why the alphabet excludes I/O/0/1.
- **Nothing prevents two consent rows claiming the same code**, which would silently duplicate or
  conflict a participant's Q1–Q3 indicators.

Recruitment planning already assumes a large fraction of participants will be "unclassified"
(the design doc cites 41.6% in Tamboer et al.). Silent join failures would inflate that number
in a way indistinguishable from genuine unclassifiability, which is precisely the kind of error
that would not be noticed until analysis.

A FK to `sessions(assigned_code)` plus a UNIQUE constraint would make both failures loud. Whether
the FK is right depends on whether a consent form may be digitized before its session is opened —
if so, a UNIQUE constraint plus a periodic orphan-check query is the safer pairing. That is a
research-workflow decision, so I am flagging rather than choosing.

### G3 — Hardening. Three SECURITY DEFINER functions still have a mutable `search_path`

0004 pinned `search_path` on the two functions that were actively broken
(`link_researcher_on_signup`, `propagate_audio_rating`) but left the three RLS helper functions:

```
3: can_manage_items, can_rate, is_researcher
```

These are the functions **every RLS policy in the schema calls**. They work today because
PostgREST sets `search_path` to `public` for API requests. They would misbehave under any caller
whose `search_path` differs — which is exactly how F2 manifested. Supabase's advisor flags all
three, plus the new `generate_participant_code`. Low severity given the current call paths, but
it is the same latent defect class that produced a blocking outage once already in this schema.

### G4 — The two `security_definer_view` ERRORs are intentional, and I checked before agreeing

0004 says the advisor will raise these and instructs "Document it; do not fix it." I did not take
that on trust, because the whole point of the definer view is that it bypasses base-table RLS.
What I verified:

- Participants and anon read exactly the 6 active items and 10 options through the views. ✓
- Neither view exposes `correct_answer` or `is_correct` — checked in the view definition, in the
  HTTP response body, and by attempting a PostgREST embedded join. ✓
- Base tables give participants **0 rows** despite 0004 restoring their `SELECT` grant, so RLS is
  genuinely the separator. ✓
- **The view still filters `active = true`.** I probed this specifically, because a definer view
  bypassing RLS could plausibly bypass row filtering too: with one active and one retired version
  of the same `item_code`, anon saw exactly 1 row. Item versioning is respected. ✓

The reasoning in 0004 is also sound: Supabase anonymous sign-in issues `role=authenticated`, so
participants and researchers genuinely are the same Postgres role, and no role-level or
column-level GRANT can separate them. RLS plus a projecting view is the right mechanism. The
residual risk is inherent and worth stating: **any future row-level restriction added to `items`
will not apply to these views.** If item visibility ever becomes conditional (per-school,
per-cohort, staged rollout), that filter must be written into the view definition, not into a
policy.

### G5 — `propagate_audio_rating()` is now callable as a public RPC

Making it SECURITY DEFINER (correct, and how F4 was fixed) also exposed it at
`/rest/v1/rpc/propagate_audio_rating` to both `anon` and `authenticated`, per the advisor. It is
a trigger function, so a direct call fails — PostgreSQL rejects trigger functions invoked outside
trigger context — and it takes no arguments, so nothing can be smuggled in. Not exploitable, but
it is API surface that should not exist. `revoke execute on function propagate_audio_rating() from
anon, authenticated;` removes it. The same applies to `link_researcher_on_signup()`, which has
been publicly callable since 0001.

### G6 — Sessions created by direct INSERT are permanently unsubmittable

`sessions_insert_own` still permits a client to `INSERT` a session row directly, but such a row
has `assigned_code = NULL`, and `submit_session()` now rejects it:

```
P0001: Session not found, not owned by caller, or already submitted
```

So the direct-insert path silently produces a dead session that can accumulate responses in
IndexedDB and then fail at submit — the worst possible moment, after a child has completed the
whole battery. `start_session()` is now the only valid entry point, and the RLS policy should say
so. Either drop `sessions_insert_own`, or add `check (assigned_code is not null)` to it.

### G7 — Deleting a researcher's auth account is blocked by the allowlist FK

Encountered while cleaning up fixtures:

```
ERROR: 23503: update or delete on table "users" violates foreign key constraint
"researchers_user_id_fkey" on table "researchers"
DETAIL: Key (id)=(40b0db4b-…) is still referenced from table "researchers".
```

`researchers.user_id` has no `ON DELETE` action, so removing a departed rater's auth account
requires manually nulling `researchers.user_id` first. `on delete set null` would be the natural
behaviour and preserves the allowlist row. Operational, not urgent — but it will be hit the first
time someone leaves the project.

### G8 — Minor: `submit_session()`'s rejection message conflates four causes

One message covers "session does not exist", "not owned by caller", "already completed", and now
"has no assigned_code". That is right for the *client* (it should not learn which), but there is
no server-side distinction either, so a field failure cannot be diagnosed from logs. Worth a
`RAISE LOG` with the specific cause before the generic `RAISE EXCEPTION`.

### G9 — Minor: 0004 does redundant work on `ml_snapshots`

The F3 block enables RLS, sets grants and creates a policy on `ml_snapshots`; the F5 block then
does `drop table if exists ml_snapshots` and recreates it, discarding all of that and redoing it.
Harmless as executed, and the end state is correct — but a reader could reasonably think the F3
block is what protects the table. Worth noting that **the `drop table` destroys any existing
snapshot data**, which was safe here only because the table was empty. If 0004 were ever re-run
against a database with real snapshots, they would be silently lost.

### G10 — Negligible: code-generation race

`generate_participant_code()` checks uniqueness and `start_session()` inserts in a separate
statement, so two concurrent calls could in principle collide and raise a unique violation. With
32^8 ≈ 1.1×10^12 codes and ~1000 participants, the probability is vanishingly small, and the
unique constraint means a collision fails loudly rather than corrupting data. Noted for
completeness only.

---

### On F2, and why it is verified at the database layer

The Phase 0 diagnosis was precise: `link_researcher_on_signup()` was SECURITY DEFINER with no
`SET search_path`, and GoTrue connects as `supabase_auth_admin` whose role config is
`search_path=auth`, so the unqualified `researchers` reference did not resolve. I re-ran that
exact reproduction against the fixed function:

| Scenario | Before 0004 | After 0004 |
|---|---|---|
| Insert into `auth.users` with `search_path=auth` | `42P01: relation "researchers" does not exist` | **SUCCEEDED** |
| Allowlist auto-link under `search_path=auth` | (never reached) | **LINKED** |

Over HTTP the signup error also changed from `500 unexpected_failure / "Database error saving new
user"` to ordinary validation and rate-limit responses — the 500 is gone. I could not complete a
full GoTrue signup because the project's free-tier default SMTP allows ~2 emails/hour and the
domain probes consumed them (`429 over_email_send_rate_limit`); the rolled-back attempts left no
user rows. **Re-test end-to-end once custom SMTP is configured** — but the defect was in the
trigger, and the trigger is fixed under the precise condition that broke it.

## 7. Decisions I made that weren't in the brief

1. **Rewrote rather than relaxed the suite**, and labelled every changed expectation in the suite
   header. The distinction between "updated to match an intended contract change" and "weakened to
   hide a failure" is the whole integrity of a verification suite, so I made it explicit rather
   than leaving it to be inferred from a diff.
2. **Added the tamper test.** 0004's stated reason for moving the code server-side is that "the
   paper-form linkage cannot be tampered with". That claim deserved a test, so the payload now
   carries `anonymized_code='ATTACKER-SUPPLIED'` and the assertion proves the stored value is the
   session's code instead. Testing that a security property *holds under attack* is worth more
   than testing that the happy path works.
3. **Probed the definer views for row filtering** (G4) rather than accepting the migration's
   "do not fix it" note at face value. The note is correct; I verified it before agreeing.
4. **Retired the F6 diagnostic assertion.** It existed to prove *why* the storage upload failed.
   The upload now succeeds, so the diagnostic has no subject. Removing it is not hiding anything —
   the positive assertion it was diagnosing now passes.
5. **Left `.select()` requesting a non-existent column in `App.tsx`** so the G1 defect is visible
   on `npm run dev` rather than only in this report.
6. **Did not add the `startSession()` helper to any component** — Phase 1 is out of scope. It sits
   in `supabaseClient.ts` with the transcription workflow documented, ready to use.
7. **Deleted all fixtures again**, including the item-audio and recording storage objects, and
   verified every table empty. Fixture items are `active = true` and would otherwise be served to
   a real participant.
8. **Did not fix any of G1–G10.** Every one is a one-to-few-line change I could have made, and G1
   in particular is trivial. The brief said report, not patch, and G1's existence is itself the
   most useful signal in this report: the same defect class recurred inside the migration that was
   fixing it, which argues for a schema-level guard (§9.4) rather than another one-off correction.

## 8. Files created/modified

**Created**
- `supabase/migrations/0004_phase0_defect_fixes.sql` — the migration as supplied, verbatim
- `MIGRATION_0004_REPORT.md` — this file

**Modified**
- `scripts/verify_security.sql` — rewritten for the post-0004 contracts; 58 → 73 assertions
- `scripts/verify-security.mjs` — 4 new HTTP assertions for the 0004 surfaces; 21 → 25
- `src/types/database.types.ts` — regenerated; carries a header note about the G1 mismatch
- `src/lib/supabaseClient.ts` — added `startSession()` and the code-transcription workflow docs
- `src/App.tsx` — F1 checks now expected to pass; added a live G1 check
- `README.md` — updated migration table, assertion counts, and outstanding steps

## 9. Open questions for the researcher

1. **G2 — how should the consent join key be constrained?** A FK to `sessions(assigned_code)`
   makes orphans impossible but forbids digitizing a consent form before its session is opened.
   A UNIQUE constraint plus a scheduled orphan-check query allows either order. Which matches the
   real field workflow — are forms digitized before or after the child sits the test?
2. **G6 — drop `sessions_insert_own`, or constrain it?** Dropping it makes `start_session()` the
   sole entry point, which is cleaner. Constraining it to `assigned_code is not null` keeps the
   direct path available for a future batch/offline import. Any reason to keep the direct path?
3. **Should a participant be able to *resume* against their code?** F7 now lets a participant read
   their own session row, which is what §5e's resume anchor needed. But if a child's device is
   replaced mid-session, the code is on paper and the session is unreachable. Is code-based
   cross-device resume wanted, or is same-device still the deliberate scope?
4. **G1's recurrence suggests a process guard.** A rename-vs-view mismatch has now happened twice
   in three migrations, and both times it was invisible until something queried the view. A cheap
   guard: a standing assertion (already in the suite) that every view's column names match their
   base columns, run as part of the pre-deploy check. Should that become a release gate?
5. **Item audio access is granted to any participant with an `in_progress` session** — the policy
   does not scope reads to the items in that session. Any authenticated participant can therefore
   enumerate and download the entire item-audio bucket, which is the full test content. Acceptable
   for a supervised in-school administration; worth a decision before any unsupervised use.
6. Carried forward, unchanged from the Phase 0 report: Domain 4 replayability, data residency
   (Mumbai), the Free → Pro upgrade, `submit_session()` accepting retired item versions, and the
   `NUMERIC_KEYPAD` NULL-answer scoring edge case.

## 10. State of the repo

- **Branch:** `main`
- **Supabase project:** `badsq-platform`, ref `gfxdhqkxetuoetzzrxxq`, region `ap-south-1`, Postgres 17.6, Free plan
- **Migration state:** 0001, 0002, 0003, 0004 all applied. Database contains **no data** — all fixtures removed; `badsq-audio` and `badsq-item-audio` buckets exist and are empty.

**Does the app run?** Yes — `npm install`, `cp .env.example .env` (fill in), `npm run dev`.
`npm run build` completes clean (403.37 kB JS / 115.15 kB gzip); `npm run lint` and
`npm run typecheck` pass with no findings.

**What works end-to-end right now, from a user's perspective?**

Still nothing a participant or researcher could sit down and use — Phase 1 is unbuilt. But the
backend picture has changed substantially. Of the five blockers that closed the Phase 0 report,
**four are fixed and verified**:

| Phase 0 blocker | Status |
|---|---|
| F2 — nobody can log in at all | **Fixed** (DB layer verified; GoTrue end-to-end pending SMTP) |
| F1 — item bank unreadable by anyone | **Fixed** — participants, anon and researchers all read correctly |
| F3 — `ml_snapshots` world-readable/writable | **Fixed** — verified denied over real HTTP |
| F4 — audio ratings silently discarded | **Fixed** — propagation verified in both directions |
| F6 — no participant can upload audio | **Fixed** — and the negative cases now discriminate rather than passing vacuously |
| F5 — export lost an anchor / F7 — no own-session read | **Fixed** |

What still stands between here and a working Phase 1:

- **G1** — item audio is unreachable through the participant view. One `create or replace view`.
- **Anonymous Sign-ins** — still disabled in the dashboard; a human must enable it.
- **G2** — the paper-consent join key needs a constraint before real consent forms are digitized.

G3, G5–G10 are hardening and operational items that do not block Phase 1.
