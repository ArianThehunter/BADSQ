# Phase 0 Report — BADSQ Platform

## 1. Scope

Phase 0 was to stand up the project and prove the database layer actually works — not to
redesign it. Concretely: scaffold a Vite + React + TypeScript client per the handoff
structure; apply migrations 0001, 0002 and 0003 in order against a live Postgres instance
and report any SQL failure verbatim rather than patching the schema to hide it; wire a
Supabase client from env vars with `.env` gitignored; generate TypeScript types from the
live schema; and then write and run a verification suite that proves the security model
holds in practice — anonymous session isolation, answer-key confidentiality by *every*
route including the base tables, export-view lockdown, allowlist enforcement, the
`submit_session()` RPC's ownership checks and server-side auto-scoring, the audio-rating
propagation trigger, and the storage upload policies — reporting real per-assertion
pass/fail with actual output rather than a bare "tests pass". Then run Supabase's own
security advisor, initialise git, and commit. Explicitly *not* in scope: any Phase 1
component (TestRunner, the six response inputs) or Phase 2 admin view.

Migration 0003 was written without ever being executed, and I was told to treat its
failures as findings to report rather than mistakes to hide. That framing turned out to
matter: 0003 applies without a single SQL error, but two of its eight fixes are
functionally self-defeating, and the suite is what exposed that.

## 2. Completed

- [x] Supabase project created and all three migrations applied in order — `supabase/migrations/0001_schema.sql`, `0002_rls_policies.sql`, `0003_phase0_fixes.sql`
- [x] Vite + React + TS scaffold per handoff structure — `package.json`, `vite.config.ts`, `tsconfig*.json`, `index.html`, `src/main.tsx`, `src/App.tsx`, `src/index.css`
- [x] Supabase client with env-var config + anonymous-session helper — `src/lib/supabaseClient.ts`
- [x] `.env.example` written; `.env` created and confirmed gitignored — `.env.example`, `.gitignore`
- [x] TypeScript types generated from the live schema — `src/types/database.types.ts`, `src/vite-env.d.ts`
- [x] SQL verification suite, 58 assertions, re-runnable, validated as a single end-to-end run — `scripts/verify_security.sql`
- [x] HTTP verification suite, 21 assertions, real transport as the `anon` role — `scripts/verify-security.mjs`
- [x] Supabase security **and** performance advisors run and catalogued — §4.3
- [x] Phase 1/2 files scaffolded as inert stubs, no implementation — `src/components/`, `src/admin/`, `src/lib/localDraft.ts`
- [x] Pinned self-hosted Unicode Bangla font + preload — `public/fonts/`, `index.html`, `src/index.css`
- [x] Bangla Unicode round-trip proven through the database — §4.1, assertions 50–52
- [x] git initialised with a `.gitignore` and committed — §10
- [x] Test fixtures fully torn down; every table verified empty afterwards

## 3. Not completed / deferred

- [ ] **Anonymous Sign-ins not enabled** — a dashboard-only setting (Authentication → Providers). No Management API token was available in this environment, and the MCP toolset exposes no auth-config tool. Participant sessions cannot work until a human flips it. Verified currently off: `422 anonymous_provider_disabled`.
- [ ] **Magic-link researcher auth not configured** — same reason (dashboard-only), plus it is blocked by finding **F2** regardless.
- [ ] **`researchers` allowlist not populated** — intentionally left empty. Real team emails are the researcher's to supply; I will not invent them.
- [ ] **Project is on the Free plan, not Pro** — the org (`ArianThehunter's Org`) is Free. The handoff requires Pro because the 7-day inactivity pause makes Free unusable for a live study. Creating the project cost $0. Upgrading is a billing decision and needs a human. **Blocks Phase 5, not Phase 1.**
- [ ] **No real-device audio testing** — Phase 4, and needs physical iOS/Android hardware.
- [ ] **HTTP-level tests for authenticated identities** — see §6 for why, and what I did instead.
- [ ] All Phase 1/2 components — out of scope by instruction; stubs only.

## 4. Verification results

Two suites at different layers. The SQL suite drives RLS policies through
`set_config('role', …)` + `set_config('request.jwt.claims', …)`, which is exactly the
mechanism PostgREST and storage-api use per request, so `auth.uid()` resolves as it does
for a real API call. The HTTP suite hits the real PostgREST / Storage / GoTrue endpoints
with only the publishable key — the posture of an attacker who has read the JS bundle.

**Totals: 79 assertions, 58 passed, 21 failed.** Every failure is real and attributable to
one of the seven findings in §6. Nothing was adjusted to make a failure disappear.

### 4.1 SQL suite — `scripts/verify_security.sql`, 58 assertions, 43 passed, 15 failed

| Check | Expected | Actual | Pass/Fail |
|---|---|---|---|
| **Sessions (6/6 passed)** | | | |
| P1 inserts its OWN sessions row (`auth_uid = auth.uid()`) | INSERT succeeds | INSERT succeeded | Pass |
| P1 inserts a sessions row claiming `auth_uid = P2` | rejected by RLS | `42501: new row violates row-level security policy for table "sessions"` | Pass |
| P1 reads P2's session row S2 directly | 0 rows | 0 rows | Pass |
| P1 unrestricted `SELECT` on sessions (table holds 3 rows) | 0 rows visible | 0 rows visible | Pass |
| P1 `UPDATE`s P2's session S2 | 0 rows affected | 0 rows affected | Pass |
| Allowlisted researcher R1 `SELECT`s sessions | 3 rows (all) | 3 rows | Pass |
| **Answer keys (5/9 passed)** | | | |
| Participant `SELECT items.correct_answer` (base table, real value `42`) | blocked | `42501: permission denied for table items` | Pass |
| Participant `SELECT item_options.is_correct` (base table, real value `true`) | blocked | `42501: permission denied for table item_options` | Pass |
| `anon` `SELECT items.correct_answer` (base table) | blocked | `42501: permission denied for table items` | Pass |
| `public_items` view definition exposes `correct_answer`? | no such column | column absent | Pass |
| `public_item_options` view definition exposes `is_correct`? | no such column | column absent | Pass |
| Participant `SELECT` from `public_items` (intended read path, 6 active items) | 6 rows | `42501: permission denied for table items` | **Fail (F1)** |
| Participant `SELECT` from `public_item_options` (10 option rows) | 10 rows | `42501: permission denied for table item_options` | **Fail (F1)** |
| POSITIVE CONTROL: researcher `SELECT items.correct_answer` | `42` | `42501: permission denied for table items` | **Fail (F1)** |
| POSITIVE CONTROL: researcher `SELECT count(*) from items` | 6 rows | `42501: permission denied for table items` | **Fail (F1)** |
| **Export surfaces (2/6 passed)** | | | |
| `anon` `SELECT` from `ml_export_v1` | blocked | `42501: permission denied for view ml_export_v1` | Pass |
| Authenticated participant `SELECT` from `ml_export_v1` | blocked or 0 rows | `42501: permission denied for table items` | Pass |
| `ml_snapshots` has RLS enabled? | RLS enabled | **NOT ENABLED** | **Fail (F3)** |
| `anon` `SELECT` from `ml_snapshots` | blocked or 0 rows | **READABLE — 1 canary row visible to anon** | **Fail (F3)** |
| `anon` `INSERT`/`DELETE` on `ml_snapshots` | blocked | **INSERT succeeded; DELETE removed 1 real snapshot row** | **Fail (F3)** |
| `ml_export_v1` exposes both latency anchors after the 0003 rename | a `from_first` and a `from_last` column | only `response_latency_ms` | **Fail (F5)** |
| **Participant confidentiality (5/5 passed)** | | | |
| Non-allowlisted authenticated user `SELECT participants` | 0 rows | 0 rows visible | Pass |
| `anon` `SELECT participants` | 0 rows | 0 rows visible | Pass |
| Non-allowlisted user `SELECT researchers` (allowlist has 1 row) | 0 rows | 0 rows visible | Pass |
| Non-allowlisted user `SELECT` responses / audio / consent | all 0 rows | `responses=0, audio_recordings=0, consent_records=0` | Pass |
| RE-CHECK with a real participant row present (1 row) | non-allowlisted 0, anon 0, researcher 1 | non-allowlisted 0, anon 0, researcher 1 | Pass |
| **submit_session() (13/13 passed)** | | | |
| Called by owner P1 on in-progress session S1 | returns a participant uuid | returned `aad05c72-f2c8-4c1f-ae54-edd83c2f6cfc` | Pass |
| MCQ_TAP correct (VT.MCQ1, chose A = correct) | `is_correct=true, scored_by=system` | `is_correct=true, scored_by=system` | Pass |
| MCQ_TAP wrong (VT.MCQ2, chose C; A correct) | `is_correct=false, scored_by=system` | `is_correct=false, scored_by=system` | Pass |
| NUMERIC_KEYPAD correct (typed `42`, key `42`) | `is_correct=true, scored_by=system` | `is_correct=true, scored_by=system` | Pass |
| NUMERIC_KEYPAD wrong (typed `9`, key `5`) | `is_correct=false, scored_by=system` | `is_correct=false, scored_by=system` | Pass |
| AUDIO_RECORD `human_rated` item left unscored | `is_correct=NULL, scored_by=NULL` | `is_correct=NULL, scored_by=NULL` | Pass |
| Session S1 finalised | completed, `ended_at` set, participant linked | `status=completed, ended_at=2026-08-24 01:59:25.917364+00, participant=VT-P1-001` | Pass |
| `audio_recordings` row created from `audio_storage_path` | 1 row | 1 row | Pass |
| Dual latency anchors persisted (sent 3500.75 / 301.0) | `from_first=3500.75, from_last=301` | `from_first=3500.75, from_last=301` | Pass |
| Called by NON-OWNER P2 on P1's session S1 | rejected | `P0001: Session not found, not owned by caller, or already submitted` | Pass |
| Re-submitting already-completed session S1 | rejected | `P0001: Session not found, not owned by caller, or already submitted` | Pass |
| Called by unauthenticated `anon` (`auth.uid()` NULL) | rejected | `P0001: Session not found, not owned by caller, or already submitted` | Pass |
| ATOMICITY: payload with one unknown `item_id` | rejected, nothing written | `P0001: Unknown item_id: cccccccc-…-dead \| participants=0, responses=0, S2 status=in_progress` | Pass |
| **Rating trigger (2/4 passed)** | | | |
| `trg_propagate_audio_rating` fired by allowlisted rater R1 (`can_rate=true`) | `responses.is_correct=true, scored_by=human` | **audio rows updated=1, but `responses.is_correct=NULL, scored_by=NULL`** | **Fail (F4)** |
| DIAGNOSTIC: same trigger run as `postgres` (BYPASSRLS) | `is_correct=false, scored_by=human` | `is_correct=false, scored_by=human` | Pass |
| Policies present on `responses` (trigger needs an UPDATE path) | ≥1 UPDATE or ALL policy | `1 policy: responses_select_researcher(SELECT)` | **Fail (F4)** |
| Non-allowlisted user `UPDATE`s `audio_recordings.primary_rating` | 0 rows / rejected | 0 rows affected | Pass |
| **Storage (4/7 passed)** | | | |
| P1 uploads to `badsq-audio/<own in_progress session S4>/…` | INSERT succeeds | `42501: new row violates row-level security policy for table "objects"` | **Fail (F6)** |
| P1 uploads to `badsq-audio/<P2's session S2>/…` | rejected by RLS | `42501: new row violates row-level security policy` | Pass¹ |
| Unauthenticated `anon` uploads to `badsq-audio` | rejected by RLS | `42501: new row violates row-level security policy` | Pass¹ |
| P1 uploads under its own but already-**completed** session S1 | rejected | `42501: new row violates row-level security policy` | Pass¹ |
| Read access to `badsq-audio` objects (1 probe object) | researcher 1, participant 0, anon 0 | researcher=1, participant=0, anon=0 | Pass |
| DIAGNOSTIC: policy `EXISTS` predicate as P1 vs as `postgres` | true as P1 (row genuinely exists, owned by P1, in_progress) | **as P1 = false; as postgres = true** | **Fail (F6)** |
| `sessions` SELECT policies (needed by that predicate and by resume) | one letting a participant see its own row | `sessions_select_researcher [SELECT] using=is_researcher()` | **Fail (F6/F7)** |
| **Bangla Unicode (3/3 passed)** | | | |
| `stimulus_text` round-trips byte-identically | `বাংলা শব্দ` (10 chars, 28 bytes) | `বাংলা শব্দ` (chars=10, bytes=28) | Pass |
| Conjunct + vowel sign round-trips | `হ্যাঁ` | `হ্যাঁ` | Pass |
| Database encoding | UTF8 | UTF8 | Pass |
| **Item bank (3/3 passed)** | | | |
| Duplicate `option_text` within an item (design doc §6) | 0 | 0 duplicate groups | Pass |
| Blank `option_text` (design doc §6) | 0 | 0 blank options | Pass |
| Items with `is_stimulus_replayable` NULL present and ACTIVE | flagged for the activation guard | `1 item: VT.D4 (domain 4, active=true)` | Pass |
| **Hardening (0/2 passed)** | | | |
| SECURITY DEFINER functions in `public` with no pinned `search_path` | 0 | `4: can_manage_items, can_rate, is_researcher, link_researcher_on_signup` | **Fail (F2)** |
| `propagate_audio_rating()` runs with definer rights | SECURITY DEFINER | **SECURITY INVOKER (runs as caller)** | **Fail (F4)** |

¹ These three negative cases pass, but **vacuously** — the policy denies *every* upload,
including the legitimate one, so they are not evidence that it discriminates correctly.
Re-run them once F6 is fixed. Reporting them as unqualified passes would have been
misleading.

### 4.2 HTTP suite — `scripts/verify-security.mjs`, 21 assertions, 15 passed, 6 failed

| Check | Expected | Actual | Pass/Fail |
|---|---|---|---|
| `GET /rest/v1/items?select=correct_answer` | denied | `HTTP 401 · 42501 permission denied for table items` | Pass |
| `GET /rest/v1/item_options?select=is_correct` | denied | `HTTP 401 · 42501 permission denied for table item_options` | Pass |
| `GET /rest/v1/items?select=*` | denied | `HTTP 401 · 42501 permission denied for table items` | Pass |
| `GET /rest/v1/public_items?select=*,item_options(*)` (embed to reach the key) | no `is_correct` in response | `HTTP 401 · 42501 permission denied for table items` | Pass |
| `GET /rest/v1/public_items?select=correct_answer` | rejected | `HTTP 400 · 42703 column public_items.correct_answer does not exist` | Pass |
| `GET /rest/v1/ml_export_v1?select=*` | denied or 0 rows | `HTTP 401 · 42501 permission denied for view ml_export_v1` | Pass |
| `GET /rest/v1/participants?select=*` | denied or 0 rows | `HTTP 200, 0 rows` | Pass |
| `GET /rest/v1/responses?select=*` | denied or 0 rows | `HTTP 200, 0 rows` | Pass |
| `GET /rest/v1/sessions?select=*` | denied or 0 rows | `HTTP 200, 0 rows` | Pass |
| `GET /rest/v1/researchers?select=*` | denied or 0 rows | `HTTP 200, 0 rows` | Pass |
| `GET /rest/v1/consent_records?select=*` | denied or 0 rows | `HTTP 200, 0 rows` | Pass |
| `POST /rest/v1/sessions` (no user JWT) | denied | `HTTP 401 · 42501 new row violates row-level security policy for table "sessions"` | Pass |
| `POST /rest/v1/rpc/submit_session` for an unowned session | rejected | `HTTP 400 · P0001 Session not found, not owned by caller, or already submitted` | Pass |
| `POST /storage/v1/object/badsq-audio/<session>/anon.webm` | denied | `HTTP 400 · 403 Unauthorized, "new row violates row-level security policy"` | Pass |
| `POST /storage/v1/object/list/badsq-audio` | denied or empty | `HTTP 200, 0 rows` | Pass |
| `GET /rest/v1/public_items` (intended participant read path, 6 items) | HTTP 200, 6 rows | `HTTP 401 · 42501 permission denied for table items` | **Fail (F1)** |
| `GET /rest/v1/public_item_options` (intended read path, 10 rows) | HTTP 200, 10 rows | `HTTP 401 · 42501 permission denied for table item_options` | **Fail (F1)** |
| `POST /rest/v1/ml_snapshots` (inject a row) | denied | **`HTTP 201`** | **Fail (F3)** |
| `GET /rest/v1/ml_snapshots` (read the canary back) | denied or 0 rows | **`HTTP 200, 1 row` — full row body returned** | **Fail (F3)** |
| `DELETE /rest/v1/ml_snapshots` (destroy snapshot rows) | denied | **`HTTP 204`** | **Fail (F3)** |
| Anonymous sign-in enabled (handoff setup step 3) | HTTP 200 with access_token | `HTTP 422 · anonymous_provider_disabled` | **Fail (setup, §3)** |

### 4.3 Supabase advisors

Run after teardown, so this is the schema's own posture with no test artefacts.

**Security — 1 ERROR, 15 WARN:**

| Level | Lint | Detail |
|---|---|---|
| **ERROR** | `rls_disabled_in_public` | `public.ml_snapshots` is public, but RLS has not been enabled — [remediation](https://supabase.com/docs/guides/database/database-linter?lint=0013_rls_disabled_in_public). Independently confirms **F3**. |
| WARN ×5 | `function_search_path_mutable` | `link_researcher_on_signup`, `propagate_audio_rating`, `is_researcher`, `can_manage_items`, `can_rate` — [remediation](https://supabase.com/docs/guides/database/database-linter?lint=0011_function_search_path_mutable). This is the mechanism behind **F2**. |
| WARN ×5 | `anon_security_definer_function_executable` | `can_manage_items`, `can_rate`, `is_researcher`, `link_researcher_on_signup`, `submit_session` callable by `anon` via `/rest/v1/rpc/…` — [remediation](https://supabase.com/docs/guides/database/database-linter?lint=0028_anon_security_definer_function_executable). `submit_session` is intentional; the other four are not, and `link_researcher_on_signup` is a *trigger* function reachable as a public RPC. |
| WARN ×5 | `authenticated_security_definer_function_executable` | Same five functions, `authenticated` role — [remediation](https://supabase.com/docs/guides/database/database-linter?lint=0029_authenticated_security_definer_function_executable). |

An additional `auth_leaked_password_protection` WARN appeared on the first advisor run but
not the second. It is irrelevant here — researchers use magic links, participants use
anonymous sign-in, so no password is ever set.

**Performance — 3 WARN, 11 INFO:**

| Level | Lint | Detail |
|---|---|---|
| WARN ×3 | `auth_rls_initplan` | `sessions_insert_own`, `sessions_update_own_in_progress`, `participants_insert_own` re-evaluate `auth.uid()` per row. Fix by wrapping as `(select auth.uid())`. Harmless now, matters at ~1000 participants. |
| WARN ×5 | `multiple_permissive_policies` | `items` and `item_options` each carry overlapping SELECT policies (`*_select_active_public` + `*_select_researcher`) across roles — a direct artefact of 0003 layering a public policy over the researcher one. Resolving **F1** should collapse these. |
| INFO ×9 | `unindexed_foreign_keys` | `audio_recordings.primary_rater_id`, `.secondary_rater_id`, `consent_records.digitized_by`, `.participant_id`, `domain_score_results.participant_id`, `.session_id`, `items.edited_by`, `researchers.user_id`, `sessions.participant_id`. |
| INFO ×2 | `unused_index` | `idx_audio_rating_status`, `idx_items_active_order` — expected; the project has had no real traffic. |

## 5. Deviations from the brief

1. **`supabase gen types typescript` was run via the Supabase MCP tool, not the CLI.** The
   Supabase CLI is not installed on this machine and installing it would not have helped —
   it needs a Management API access token to reach a hosted project, and none was
   available. The MCP `generate_typescript_types` tool performs the identical server-side
   generation. Output committed verbatim to `src/types/database.types.ts`, with a header
   comment giving the CLI command for future regeneration.
2. **Migrations live in `supabase/migrations/`; they arrived at the repo root.** The
   handoff describes them at `supabase/migrations/`, so I moved them there. Contents are
   byte-for-byte unmodified.
3. **`supabase init` / `supabase link` were not run** — no CLI. Migrations were applied via
   MCP `apply_migration`, which records them in Supabase's own migration history, so
   `supabase migration up` will recognise them once the CLI is set up.
4. **A new Supabase project was created** (`badsq-platform`, ref `gfxdhqkxetuoetzzrxxq`,
   region `ap-south-1`). No BADSQ project existed, and the org's two existing projects
   belong to unrelated apps, so applying this schema to either would have been wrong. Cost
   confirmed at **$0/month** before creating. Region choice explained in §7.
5. **Authenticated-identity assertions use SQL role impersonation, not real JWTs.** This is
   the one methodological compromise and it is forced, not chosen — see §6. Both the suite
   header and this report label which assertions used which method.
6. **The Bangla font is self-hosted rather than linked from Google Fonts.** The brief
   approved "pin an explicit Unicode Bangla font"; it did not specify delivery. A
   `fonts.gstatic.com` link would send every participant's IP to a third party, which sits
   badly against "no analytics, telemetry, or third-party scripts — this app handles data
   from minors", and would also fail on the unreliable school internet the design doc
   anticipates. 147 KB of woff2 committed under `public/fonts/`, OFL-1.1, provenance
   documented.
7. **`lucide-react` not added.** Took the brief's suggestion: no dependency. No icons are
   needed yet, so rather than commit six unused inline SVGs I recorded the decision and
   left it for Phase 1.
8. **`src/App.tsx` is a live status page rather than a placeholder.** It renders a Bangla
   pangram and actually attempts the participant read path, displaying the verbatim error.
   It is not a Phase 1 component and implements no test logic — it makes the F1 breakage
   visible on `npm run dev` instead of hiding behind a stub.

Nothing else. No migration SQL was altered.

## 6. Problems, errors, and blockers

**All three migrations applied with zero SQL errors.** Every finding below is a runtime or
privilege-model defect that only surfaced under test.

Ordered by severity. F1–F4 block Phase 1.

---

### F1 — BLOCKER. Migration 0003 FIX 3 makes the item bank unreadable by *everyone*

The security goal is met: no participant can reach `correct_answer` or `is_correct` by any
route I could construct — base table, sanitised view, PostgREST embedded join, or explicit
column select. But the fix over-shoots, and the item bank is now unreadable by participants
*and* researchers.

Two lines fight each other:

```sql
create view public_items with (security_invoker = on) as …   -- FIX 3
revoke select on items from anon, authenticated;             -- FIX 3, 20 lines later
```

`security_invoker = on` makes Postgres check the base table's **privileges** — not just its
RLS — against the *caller*. So revoking `SELECT on items` from the client roles also
disables the view that was supposed to replace it. Verbatim, over real HTTP:

```
GET /rest/v1/public_items
HTTP 401 {"code":"42501","hint":"Grant the required privileges to the current role with:
GRANT SELECT ON public.items TO anon;","message":"permission denied for table items"}
```

The second half is worse and was caught only by a positive control: **researchers are also
just `authenticated` users**, so the revoke strips them too. `items_select_researcher`, the
RLS policy 0003 adds in the same block, is unreachable — a researcher cannot read one row
of the item bank. That kills the Phase 2 `ItemBankEditor` before it is written, and it also
means the `items_select_active_public` policy 0003 adds is dead code.

Consequence: **Phase 1's TestRunner cannot load a single item.** The comment in 0003 above
the revoke is accurate about the risk it is defending against, but the chosen defence is
incompatible with `security_invoker = on`.

The two coherent designs — for the researcher to choose, not me — are either drop
`security_invoker` so the views run with owner privileges (the classic secure-view pattern,
which is what the revoke was written for), or keep `security_invoker` and re-grant
`SELECT on items` to the client roles, relying on the views plus column-level `GRANT` to
withhold the key columns. I did not implement either: the brief says report, don't patch.

### F2 — BLOCKER. The `auth.users` trigger from migration 0001 breaks *all* user creation

Nobody can authenticate at all — participants or researchers. Every signup fails:

```
POST /auth/v1/signup
HTTP 500 {"code":500,"error_code":"unexpected_failure","msg":"Database error saving new user"}
```

Root cause, isolated: `link_researcher_on_signup()` is `SECURITY DEFINER` with **no
`SET search_path`**, so it inherits the caller's. GoTrue connects as
`supabase_auth_admin`, whose role config is `search_path=auth`. The function's unqualified
reference to `researchers` (in `public`) therefore does not resolve. I reproduced the exact
failure by setting the same `search_path` and inserting into `auth.users`:

| `search_path` | Outcome |
|---|---|
| `auth` (what `supabase_auth_admin` uses) | `42P01: relation "researchers" does not exist` |
| `public` | SUCCEEDED |

The trigger's *logic* is fine — with a resolvable path it correctly linked the allowlist row
to the new user (fixture setup asserted `r1_linked_by_trigger = true`). Only the missing
`search_path` pin is wrong. Supabase's own advisor flags the same function under
`function_search_path_mutable`.

Note this is latent in **0001**, not 0003, and it would have bitten on the very first
magic-link login. It is invisible until a real user is created, which is why applying
migrations cleanly proves so little on its own.

### F3 — BLOCKER (data confidentiality + integrity). `ml_snapshots` is world-writable

`ml_snapshots` is created in 0001, omitted from the `enable row level security` list in
0002, and untouched by 0003. It has RLS **off** while `anon` holds full grants — and it is
in the PostgREST-exposed `public` schema. Proven over real HTTP with the publishable key
alone:

```
POST   /rest/v1/ml_snapshots   → HTTP 201   (injected a row)
GET    /rest/v1/ml_snapshots   → HTTP 200, 1 row, full body returned
DELETE /rest/v1/ml_snapshots   → HTTP 204   (deleted it)
```

This table is designed to hold *the whole flattened export* — every response, latency, and
score for every participant — snapshotted before each analysis run. As it stands, anyone
with the publicly-shipped key can read the entire dataset, inject fabricated rows into the
analysis input, or delete the snapshot. The confidentiality half is a participant-privacy
breach; the integrity half could silently corrupt published findings.

Supabase's security advisor independently raises this as its **only ERROR**.

Related, lower severity but the same root cause (Supabase's default grants were never
trimmed): `anon` and `authenticated` also hold `INSERT`/`UPDATE`/`DELETE`/`TRUNCATE` on
every table in `public`. RLS blocks the DML ones (verified: no policy ⇒ denied), but
**`TRUNCATE` is not subject to RLS at all**. It is not reachable through PostgREST, so this
is not remotely exploitable today — I am flagging it as a least-privilege gap that would
become serious if any pooler credential or SQL-injectable definer function ever appeared,
not as a live vulnerability.

### F4 — BLOCKER (silent data loss). Audio ratings never reach `responses`

The single most dangerous finding, because it fails **silently and looks like success**.

When a genuine allowlisted rater (`can_rate = true`) records a rating, the
`audio_recordings` UPDATE succeeds — **1 row affected**, the rating queue would show it
saved — but the propagation never happens:

```
audio rows updated=1 | responses.is_correct=NULL, scored_by=NULL
```

Diagnostic that isolates it: the identical update run as `postgres` (BYPASSRLS) *does*
propagate (`is_correct=false, scored_by=human`), so the trigger body is correct. The cause
is two schema facts combining:

1. `propagate_audio_rating()` is declared plain `language plpgsql` — **SECURITY INVOKER** —
   so its inner `update responses …` executes as the rater's `authenticated` role.
2. `responses` has exactly one policy: `responses_select_researcher(SELECT)`. There is no
   UPDATE policy, so RLS filters that inner update to **zero rows** — and an RLS-filtered
   UPDATE raises no error. It just does nothing.

Why this is severe rather than merely broken: `audio_recordings` rows carry
`scheduled_deletion_at`, and the parental-consent commitment is to delete recordings
post-study while the derived `is_correct` score persists in `responses`. If ratings are
collected under this defect, the scores would be silently absent *and* the source audio
deleted — the human rating work would be unrecoverable. The design doc's own rationale for
putting this in a trigger ("so it can never desync from the application") is exactly what
the RLS interaction defeats.

### F5 — `ml_export_v1` lost half the dual-anchor latency decision

0003 FIX 2 renamed the base columns, and Postgres auto-updated the view's *definition* —
but a view's **output** column name does not change on a base-column rename, and 0003 never
re-created the view. So:

- `ml_export_v1.response_latency_ms` still exists, now silently sourced from
  `response_latency_from_last_ms`.
- `response_latency_from_first_ms` — the anchor the researcher explicitly asked to record —
  **never reaches the export at all.**

The decision was "do not pick one, record both". The database records both correctly
(verified: `from_first=3500.75, from_last=301`), but the export surface exposes only one,
under a name that implies it is *the* latency. An analyst working from the export would
silently lose the first-ever-stimulus anchor and would not know it was missing.
`ml_snapshots.response_latency_ms` inherits the same ambiguity.

### F6 — BLOCKER. No participant can upload audio

The storage upload policy can never be satisfied. Its `WITH CHECK` contains:

```sql
exists (select 1 from sessions s where s.auth_uid = auth.uid()
        and s.status = 'in_progress' and (storage.foldername(name))[1] = s.id::text)
```

That subquery is evaluated as the caller, so `sessions` RLS applies — and participants have
no SELECT policy on `sessions` (see F7). The predicate is therefore always false. Same
class of bug as F4: a policy that reads a table the caller cannot see.

Proven, for a session row that genuinely exists, is owned by P1, and is `in_progress`:

| Evaluated as | Predicate |
|---|---|
| P1 (`authenticated`) | **false** |
| `postgres` (RLS bypassed) | true |

This is why the three negative storage assertions pass vacuously (§4.1 footnote): the policy
denies everyone. Every AUDIO_RECORD item — Domain 5 spoonerisms among them — is
uncollectable until fixed.

### F7 — Participants cannot read their own `sessions` row

`sessions_select_researcher` is the only SELECT policy on the table, so a participant sees
zero rows in `sessions` — including the one they just created. Verified: table held 3 rows,
P1 saw 0.

Two consequences. It is the mechanical cause of F6. And the design doc §5e resume flow uses
the `sessions` row as "the anchor the resume check needs" — which a participant cannot read.
Whether to add a `using (auth_uid = auth.uid())` SELECT policy is a real design decision
(it widens what a participant can see), so I am flagging rather than assuming.

---

### Things that worked, worth stating explicitly

`submit_session()` — the part of 0003 flagged as never executed — is **correct on all 13
assertions**. Ownership check, already-completed rejection, unauthenticated rejection,
MCQ_TAP right/wrong, NUMERIC_KEYPAD right/wrong, audio items left NULL for human rating,
`audio_recordings` row creation, session finalisation, and dual-anchor persistence all
behave as designed. I also added an atomicity test beyond the brief's minimum: a payload
with one bad `item_id` rolls back completely — no orphan participant, no partial responses,
session still `in_progress`. For an instrument whose whole submit model is "all or nothing",
that property was worth proving rather than assuming.

### Methodological limitation, stated plainly

Assertions needing an authenticated identity could not be driven over real HTTP. Minting a
participant or researcher JWT requires either Anonymous Sign-ins enabled (off, dashboard
only) or the JWT signing secret (not exposed; reading `vault.decrypted_secrets` was denied
by policy and I did not attempt to work around it). And F2 means email signup returns
HTTP 500 regardless.

So those assertions use `set_config('role', …)` + `set_config('request.jwt.claims', …)` —
the same mechanism PostgREST and storage-api apply per request, which makes `auth.uid()`
resolve identically. This faithfully tests the **policies**, which is what the brief asked
about. It does not test the HTTP transport, PostgREST's column handling, or storage-api's
own logic above the RLS layer. Where I could test the transport (the `anon` role) I did, and
the two suites agree everywhere they overlap. The gap is real and worth re-closing once
Anonymous Sign-ins is enabled — the same suite should be re-run against real JWTs.

One further caveat: the fixture identities have `is_anonymous = true` set on their
`auth.users` rows, matching production, and no policy in this schema reads that claim — so
behaviour is identical. I am noting it rather than leaving it implicit.

## 7. Decisions I made that weren't in the brief

1. **Created a new Supabase project rather than reusing an existing one.** Neither existing
   project is BADSQ; applying this schema to either would have damaged an unrelated app.
   Cost confirmed $0 first.
2. **Region `ap-south-1` (Mumbai)** — geographically closest option to Bangladesh, so the
   lowest RTT for school devices. This does **not** affect latency measurement (that is
   computed client-side from `performance.now()`, by design), but it does affect audio
   upload time and perceived responsiveness. Note the data-residency implication: participant
   data from minors will live in India, not Bangladesh. If the ethics approval or consent
   form constrains data location, say so and I will move it — it is cheap now and expensive
   after collection starts.
3. **Self-hosted the Bangla font instead of linking Google Fonts** — privacy and offline
   reliability. Reasoning in §5.6 and `public/fonts/README.md`.
4. **Deleted all verification fixtures after the run.** The six `VT.*` fixture items were
   created with `active = true`; had I left them, a real participant session would have been
   served fake items. Every table verified empty afterwards. The suite rebuilds its own
   fixtures, so this costs nothing in reproducibility.
5. **Added assertions beyond the stated minimum**: submit atomicity, Bangla Unicode
   round-trip (given the documented legacy-encoding history, this is a data-integrity check,
   not cosmetics), the design doc §6 item-bank quality queries, a `SECURITY DEFINER`
   `search_path` audit, and positive controls for the researcher role. **Three of the seven
   findings — F1's researcher half, F2, and F4 — were caught only by positive controls or by
   the diagnostics.** Testing only that the bad thing is blocked would have reported a clean
   pass on a database where nobody can log in and no rating is ever saved.
6. **Marked three storage assertions as vacuous passes** rather than counting them as
   genuine. They pass, but only because the policy denies everything.
7. **Made `App.tsx` a live status page** that surfaces the F1 failure on `npm run dev`.
8. **Added `verify.results` as a real table in a `verify` schema**, not temp tables, so
   results survive across statements and the researcher can inspect them in the SQL editor.
   Dropped at teardown.
9. **Set `detectSessionInUrl: false`** on the Supabase client — no OAuth redirect flow is
   used, so there is never a reason to parse tokens out of the URL.
10. **Added `referrer: no-referrer` and `robots: noindex, nofollow`** to `index.html`. A
    participant-facing instrument should not leak URLs or be indexed.
11. **Validated the consolidated `verify_security.sql` as a single end-to-end run** before
    committing it. I had developed it in pieces; shipping an unexecuted script would have
    repeated precisely the mistake 0003 made. It reproduces 58/43/15 exactly.
12. **Left `.env` populated locally** (gitignored) with the publishable key only. No secret
    key is anywhere in the repo, and `.env.example` warns that `VITE_*` vars are inlined into
    the client bundle.

## 8. Files created/modified

**Migrations** (moved from repo root, contents unmodified)
- `supabase/migrations/0001_schema.sql` — tables, versioned item bank, rating trigger, `ml_export_v1`
- `supabase/migrations/0002_rls_policies.sql` — RLS for participants and researchers
- `supabase/migrations/0003_phase0_fixes.sql` — the eight Phase 0 fixes

**Verification**
- `scripts/verify_security.sql` — 58-assertion RLS/policy suite, re-runnable, self-cleaning
- `scripts/verify-security.mjs` — 21-assertion HTTP suite as the `anon` role, zero dependencies

**Application**
- `src/lib/supabaseClient.ts` — client, env config, `ensureAnonymousSession()`
- `src/types/database.types.ts` — generated from the live schema
- `src/vite-env.d.ts` — typed `ImportMetaEnv`
- `src/App.tsx` — Phase 0 live status page
- `src/main.tsx` — React entry point
- `src/index.css` — self-hosted `@font-face` blocks, touch-target and Bangla line-height base

**Scaffold stubs — no implementation**
- `src/components/TestRunner.tsx`
- `src/components/responses/{McqTap,BinaryTap,TriTap,NumericKeypad,Likert5,AudioRecord}.tsx`
- `src/admin/{ParticipantsView,RatingQueue,ItemBankEditor,HealthView}.tsx`
- `src/lib/localDraft.ts` — records the §5e resume constraints so they are not lost

**Assets**
- `public/fonts/noto-sans-bengali-{bengali,latin-ext,latin}.woff2` — pinned Unicode Bangla, OFL-1.1
- `public/fonts/README.md` — provenance, licence, and why self-hosted

**Config / docs**
- `package.json`, `vite.config.ts`, `tsconfig.json`, `tsconfig.app.json`, `tsconfig.node.json`, `.oxlintrc.json`
- `index.html` — Bangla font preload, privacy meta, `lang="bn"`
- `.gitignore` — `.env` excluded, `.env.example` re-included
- `.env.example` — template with the no-secret-key warning
- `README.md` — setup, outstanding dashboard steps, verification commands
- `PHASE_0_REPORT.md` — this file

## 9. Open questions for the researcher

1. **F1 — which fix for the item bank?** Drop `security_invoker` from the two views (classic
   secure-view pattern, matches what the revoke was written for), or keep it and re-grant
   `SELECT on items` with column-level grants withholding the key? My recommendation is the
   former: fewer moving parts, and the answer key never becomes reachable by a policy edit.
2. **F7 — add a participant SELECT policy on `sessions`?** Required to fix F6 as written,
   and the §5e resume flow needs it. `using (auth_uid = auth.uid())` is the narrow version.
   Confirm this is acceptable, or F6 needs a different approach (e.g. making the storage
   policy's lookup a `SECURITY DEFINER` helper).
3. **Domain 4 replayability** — still unresolved, as flagged in the handoff. The verification
   confirms an `is_stimulus_replayable IS NULL` item can currently be `active = true`, so the
   guard has to live in the admin UI (scaffolded, Phase 2). Should the database also carry a
   `CHECK`/trigger preventing `active = true` while that flag is NULL? A DB-level guard cannot
   be bypassed by a future admin screen.
4. **F5 — recreate `ml_export_v1` with both anchors, and rename the existing column?**
   Renaming `response_latency_ms` is the clearer option but breaks any analysis script that
   already reads it. Nothing consumes it yet, so now is the cheap moment.
5. **Data residency (§7.2)** — participant data from Bangladeshi minors will be stored in
   Mumbai. Does the ethics approval or the parental consent form constrain where data may
   live? Cheap to change now.
6. **Free → Pro upgrade** — a billing decision. Free's 7-day inactivity pause makes it
   unusable for live collection. Needed before Phase 5, not before Phase 1.
7. **Should `submit_session()` reject responses referencing `active = false` items?** It
   currently accepts any existing `item_id`. Given versioning is deliberate (completed
   sessions reference the exact version shown), accepting retired versions is probably
   correct — but it is currently accidental rather than decided.
8. **`NUMERIC_KEYPAD` scoring edge case.** `submit_session()` scores via
   `typed_value IS NOT DISTINCT FROM correct_answer`, so an item with a NULL `correct_answer`
   and a skipped answer scores **true**. No such item exists yet; worth a guard before the
   real bank is loaded.
9. **Should `ml_snapshots` be in the `public` schema at all?** Enabling RLS fixes F3, but an
   analysis-only table arguably should not be exposed to PostgREST in the first place.

## 10. State of the repo

- **Branch:** `main`
- **Commit:** see §10 note below — hash recorded at commit time
- **Supabase project:** `badsq-platform`, ref `gfxdhqkxetuoetzzrxxq`, region `ap-south-1`, Postgres 17.6, Free plan
- **Migration state:** 0001, 0002, 0003 all applied. Database contains **no data** — all verification fixtures removed; the `badsq-audio` bucket exists and is empty.

**Does the app run?** Yes.

```bash
npm install
cp .env.example .env     # fill in URL + publishable key
npm run dev
```

`npm run build` completes clean (`tsc -b` + Vite, 402.59 kB JS / 114.95 kB gzip).
`npm run lint` and `npm run typecheck` both pass with no findings.

**What works end-to-end right now, from a user's perspective?**

Honestly: **nothing a participant or researcher could use.** That is the correct state for
Phase 0 — no test flow was in scope — but it is worth being precise about how much of the
*backend* is also not usable yet:

Working and proven:
- The app builds, serves, and renders Bangla correctly from the pinned self-hosted Unicode font.
- The full schema, RLS policies, storage bucket, and the `submit_session()` RPC exist in a live database.
- `submit_session()` works completely: ownership enforcement, server-side auto-scoring for MCQ_TAP and NUMERIC_KEYPAD, audio items left for human rating, atomic all-or-nothing submission, dual latency anchors persisted.
- Participant session isolation holds. Answer keys are unreachable by participants through every route tested. `participants`, `responses`, `consent_records` and the researcher allowlist are invisible to non-allowlisted users and to `anon`. `ml_export_v1` is locked down.
- Both verification suites run on demand and report real per-assertion results.

Not working, and blocking Phase 1:
- **Nobody can log in at all** (F2) — every signup returns HTTP 500, and Anonymous Sign-ins is additionally still disabled in the dashboard.
- **The item bank cannot be read by anyone** (F1) — participants or researchers.
- **No participant can upload audio** (F6).
- **Human audio ratings would be silently discarded** (F4).
- **`ml_snapshots` is world-readable and world-writable** (F3).

So: the database layer has been proven — and what it proves is that four blocking defects
sit between here and a working Phase 1. All four are in the migration SQL and none were
patched, per the brief. F1, F4, F6 and F7 are one small migration's worth of work once the
two design questions in §9 are answered; F2 and F3 are unambiguous and need no decision
(pin `search_path`; enable RLS).
