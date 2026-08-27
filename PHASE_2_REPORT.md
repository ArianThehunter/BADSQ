# Phase 2 Report — BADSQ Platform

## 1. Scope

Push the repo to GitHub (as before). Apply migration `0006_versioning_and_h1.sql` — which closes
H1 (the PUBLIC-grant gap from 0005) and adds `save_item_version()`, an atomic RPC replacing Phase
1's three-statement item-editing sequence — and verify it independently. Build TestRunner and the
six participant response components (MCQ_TAP, BINARY_TAP, TRI_TAP, NUMERIC_KEYPAD, LIKERT_5,
AUDIO_RECORD), gated on Anonymous Sign-ins being enabled in the dashboard (it was — confirmed
before any TestRunner code was written). Create test fixtures across all six formats and exercise
the runner end-to-end, including — new this phase — genuine browser-driven verification with
Playwright/Chromium, not just HTTP- or SQL-level checks. Explicitly out of scope: ParticipantsView,
RatingQueue, HealthView.

Migration 0006 arrived untested, as every prior migration has. It applied with zero SQL errors and
every specified behaviour verified correct, including a genuine crash-shape rollback test. The
TestRunner build is functionally complete against the brief and passed a full real-browser
walkthrough for five of six response formats. The sixth, AUDIO_RECORD, surfaced a real, previously
undetected, universally-blocking defect in a bucket policy that predates this phase — reported in
full below as **I1**, not patched around.

## 2. Completed

- [x] Migration 0006 applied to the live project — `supabase/migrations/0006_versioning_and_h1.sql`
- [x] H1 verified fixed: `has_function_privilege` false for **both** `anon` and `authenticated` on both trigger functions, and the raw ACL no longer contains a bare PUBLIC (`=X/...`) entry — §4.1
- [x] `save_item_version()` verified: NULL-old-id → version 1 / inactive by default; supersede → exactly one active version, options fully replaced, in one transaction; a deliberately-failing option insert rolls back the *entire* call (no orphaned rows, superseded item's `active` flag untouched); rejects a caller without `can_manage_items` — §4.1
- [x] `sessions` confirmed down to exactly one SELECT policy; `multiple_permissive_policies` no longer lists `sessions` at all — §4.3
- [x] Both advisors re-run after full teardown — §4.3
- [x] `itemBank.ts` migrated off the old three-statement sequence onto `save_item_version()`, closing Phase 1's open question 9.2 — `src/lib/itemBank.ts`
- [x] TypeScript types regenerated, with the same class of by-hand nullability fix as Phase 1 (generator doesn't encode SQL parameter nullability) — `src/types/database.types.ts`
- [x] TestRunner: intake (class grade) → sequenced items → submit → completion screen showing the assigned code — `src/components/TestRunner.tsx`
- [x] All six response components — `src/components/responses/*`
- [x] Audio-first playback via signed URL, response controls disabled until `ended` fires
- [x] Dual latency anchors (first/last stimulus-end) via `performance.now()`, frozen at first interaction only
- [x] Input modality captured via Pointer Events (`pointerType`), not User-Agent sniffing
- [x] Replay: instruction always replayable; stimulus replayable only per `is_stimulus_replayable`, with **no control rendered at all** when false
- [x] Lock-on-advance; audio follows record → playback → re-record-before-advance
- [x] Local draft + resume via IndexedDB (`src/lib/localDraft.ts`), keyed by the session UUID; resume decision asked via speech synthesis + on-screen text, never silent
- [x] Screening code generated at session start, shown only on the closing screen (G2 workflow decision) — verified live, twice (once via real HTTP in an earlier pass, once via this phase's browser walkthrough)
- [x] Submit disabled until every item is answered
- [x] Submit order: audio upload(s) first, then `submit_session()`; on failure, draft is preserved and a "not yet submitted" state is shown with a retry button — verified live, because it actually failed (§6, I1) and behaved exactly as specified
- [x] Cross-platform MIME detection via `MediaRecorder.isTypeSupported()` — `src/lib/media.ts`
- [x] Touch targets ≥44px throughout — `src/components/testrunner.css`
- [x] Six fixture items, one per response format, with real Bangla stimulus/option text, created and fully torn down — §4.4
- [x] Genuine browser-driven, end-to-end verification of the entire participant flow via Playwright/Chromium — new this phase, not done in any prior phase — §4.4

## 3. Not completed / deferred

- [ ] **I1 — participant AUDIO_RECORD uploads cannot succeed against the live `badsq-audio` bucket policy**, for any participant, regardless of correct session/auth/path. Root-caused, not patched. See §6.
- [ ] **No real item audio.** Uploading to `badsq-item-audio` requires `can_manage_items()` — a real researcher session, still unavailable (no completed magic-link round trip, no service_role key, vault access denied by standing policy). Fixture items ship with **no** instruction/stimulus audio. TestRunner's audio-first gating, replay-button visibility against *real* audio, and dual-anchor latency relative to *real* playback timing were reasoned through by code review and a robustness fix (§7.6), not exercised against a real file.
- [ ] **No real iOS device tested.** Stated explicitly per the brief's own instruction, not left silently assumed. Cross-platform MIME detection was exercised only against Chromium's own `MediaRecorder.isTypeSupported()` reporting (WebM/Opus); Safari/iOS's MP4/AAC path is implemented (`src/lib/media.ts`) but unverified on a real device or in a real WebKit engine.
- [ ] **Real microphone hardware not exercised.** The browser test used Chromium's fake-device flag (`--use-fake-device-for-media-stream`), which drives the real `getUserMedia`/`MediaRecorder` code path against a synthetic media stream — a genuine test of the client code, not of a physical microphone.
- [ ] Only a **single row per item** is submitted (the value at advance time), not the full attempt-history the schema's `attempt_number`/`is_superseded` columns support — carried forward from Phase 1's equivalent note (then about editing history; the same trim now applies to response history). Deliberate scope trim, flagged as open question 9.4.
- [ ] ParticipantsView, RatingQueue, HealthView — out of scope by instruction.

## 4. Verification results

### 4.1 SQL suite — `scripts/verify_security.sql` (v4), 75 assertions, 75 passed

65 assertions carried over unchanged from Phase 1 (v3) all still pass, including the two that were
previously failing (H1) — their code did not change; the underlying grant did, so they now pass
without any test being weakened. **PART 13**, the 10 new assertions for this migration:

| Check | Expected | Actual | Pass/Fail |
|---|---|---|---|
| `propagate_audio_rating` EXECUTE — `anon` | `false` | `false` | **Pass** |
| `propagate_audio_rating` EXECUTE — `authenticated` | `false` | `false` | **Pass** |
| `propagate_audio_rating` raw ACL contains no bare PUBLIC entry | no `=X/` prefix | absent | **Pass — H1 closed** |
| `link_researcher_on_signup` EXECUTE — `anon` / `authenticated` / raw ACL | same three checks | same three results | **Pass — H1 closed** |
| `save_item_version(NULL, ...)` → new item | version 1, `active=false` by default | version 1, `active=false` | **Pass** |
| `save_item_version(<old id>, ...)` → supersede | exactly 1 active version, old inactive, options fully replaced | 1 active (new), old inactive, 0 stale options | **Pass** |
| CRASH-SHAPE: deliberately-failing option insert (duplicate `option_key`) rolls back the whole call | 0 orphaned item rows, superseded item's `active` flag unchanged | new item row absent entirely; old item still `active=true` | **Pass** |
| `save_item_version()` rejects a caller without `can_manage_items` | rejected | `save_item_version: caller lacks item-management permission` | **Pass** |
| `sessions` has exactly one SELECT policy | 1 | 1 (`sessions_select`) | **Pass** |
| `sessions_select` still enforces owner/researcher/stranger boundaries correctly | owner ✓, researcher ✓, stranger ✗ | owner ✓, researcher ✓, stranger ✗ | **Pass** |

(Table condensed from 10 individual assertion rows in `verify.results`; the two "same three checks"
rows above are each two separate assertions in the file.)

One test-setup bug of my own was caught and fixed during this pass, not a product defect: a
"non-researcher" fixture identity had been added to the `researchers` table with both permission
flags `false`, but `is_researcher()` checks only *presence* in the allowlist, not the flags — so it
correctly read as a researcher and the stranger-denial assertion failed on my own bad fixture. Fixed
by introducing a genuine non-allowlisted identity for that specific check.

### 4.2 HTTP suite — `scripts/verify-security.mjs`, 30 assertions, 30 passed

The one new assertion for this migration:

| Check | Expected | Actual | Pass/Fail |
|---|---|---|---|
| `POST /rest/v1/rpc/save_item_version` as anon | denied | `HTTP 400` (parameter/permission rejection before any row is touched) | **Pass** |

All 29 previously-passing assertions still pass, including — now genuinely, not conditionally —
"Anonymous sign-in enabled," since the precondition is real this phase.

**Known operational quirk, not a defect**: this suite creates one real anonymous `auth.users` row
each run (there is no anonymous-sign-in path that doesn't). It is not self-cleaning for that one
row; I removed it by hand after each run (`delete from auth.users where is_anonymous = true`),
scoped narrowly enough to never touch the real researcher account. Worth a follow-up if this suite
becomes part of CI.

### 4.3 Supabase advisors

Re-run after full fixture teardown; literal JSON re-queried immediately before writing these
numbers (not recalled from an earlier run — see Phase 1's own corrected mistake on this exact
point).

**Security — 2 ERROR, 25 WARN.**

| Level | Lint | Detail |
|---|---|---|
| ERROR ×2 | `security_definer_view` | `public_items`, `public_item_options` — unchanged, carried from 0004; still intentional. |
| WARN ×5 | `anon_security_definer_function_executable` | `can_manage_items`, `can_rate`, `is_researcher`, `start_session`, `submit_session`. **`save_item_version` is correctly absent from this list** — it is `authenticated`-only, matching the 0006 grant. |
| WARN ×6 | `authenticated_security_definer_function_executable` | Same five plus `save_item_version` itself (advisor flags any `SECURITY DEFINER` function callable by a signed-in role, which every participant now is — expected, not a regression). |
| WARN ×14 | `auth_allow_anonymous_sign_ins` | One entry per table with an anon-reachable policy (`sessions`, `item_options`, `items`, `storage.objects`, `participants`, `responses`, etc.), plus `auth.sessions` itself. **New this phase**, entirely as a consequence of Anonymous Sign-ins now being enabled — this is the advisor correctly noting a fact that was always going to be true the moment participants got real identities, not a new hole. Every table it lists already has RLS scoping that fact to "own session only," verified across both suites above.

No `function_search_path_mutable` warnings (still fully resolved, per Phase 1's G3 fix — re-confirmed, not assumed to have held).

**Performance — 9 INFO, 8 WARN.**

| Level | Lint | Detail |
|---|---|---|
| INFO ×9 | `unindexed_foreign_keys` | Unchanged count from Phase 1. Untouched by this migration. |
| INFO ×2 | `unused_index` | Same two as Phase 1, expected on a project with no real traffic. |
| WARN ×2 | `auth_rls_initplan` | `participants_insert_own` (carried over, unchanged) **plus a new entry for `sessions_select`** — the 0006-consolidated policy calls `auth.uid()` unwrapped, so it re-evaluates per row instead of once via `(select auth.uid())`. A performance nit, not a correctness issue; flagged as open question 9.5. |
| WARN ×5 | `multiple_permissive_policies` | **All five entries are now `item_options`** (one per role variant: `anon`, `authenticated`, `authenticator`, `dashboard_user`, `supabase_privileged_role`). **`sessions` has genuinely dropped out of this lint entirely** — direct confirmation, independent of the suite, that the single-policy consolidation worked. |

### 4.4 Real browser-driven verification (Playwright + Chromium, headless)

New methodology this phase. Every prior phase's "real" test bottomed out at either SQL-level role
impersonation or raw HTTP with curl/fetch — never the actual bundled client code running in an
actual browser, clicking actual buttons. Chromium was not available on this Windows host as
`chromium-cli`/`chromium`/`google-chrome`; installed via `npx playwright install chromium`
(~192 MB) and driven with a purpose-written Playwright script (kept in the session scratchpad, not
the repo) rather than a custom driver, per the `run` skill's fallback guidance.

**Run 1 — all six fixture items** (`FX2.MCQ1`, `FX2.BIN1`, `FX2.TRI1`, `FX4.LIK1`, `FX3.NUM1`,
`FX5.AUD1`), microphone permission granted via Chromium's fake-media-device flags:

| Step | Result |
|---|---|
| Initial load, `#/test` | Bangla intake screen renders correctly: "তোমার শ্রেণি কত?" + grade buttons 6/7/8 |
| Grade selection | Advances to item 1/6 |
| MCQ_TAP, BINARY_TAP, TRI_TAP | Each: Next disabled before an answer, enabled immediately after a tap; correct Bangla option text rendered |
| NUMERIC_KEYPAD | **No native `<input>` present in the DOM** (confirmed via selector count = 0) — digits entered via on-screen keys only, exactly as specified |
| LIKERT_5 | 5-point horizontal scale renders and responds correctly |
| AUDIO_RECORD | Record → (fake mic stream) → Stop → preview `<audio>` element appears, Next enables. **The client-side recording pipeline — `getUserMedia`, `MediaRecorder`, blob creation, preview, Next-unlock — works completely correctly.** |
| Submit | **Fails.** See I1, §6. Draft preserved, "Try submitting again" shown, zero data loss — the resilience requirement worked exactly because a real failure exercised it. |

Console: one `400` resource-load error (the failed upload itself). No other console or page
errors across the entire six-item run.

**Run 2 — five items, `FX5.AUD1` temporarily deactivated** (`active=false`, to isolate whether the
failure was specific to audio or systemic):

| Step | Result |
|---|---|
| Full walkthrough, 5/5 items | Identical to Run 1 minus the audio item |
| Submit | **Succeeds.** Completion screen renders: "ধন্যবাদ! Thank you — your answers have been submitted. Please tell your teacher this code so it can be written on your form: `BADSQ-886X-WFVW`" |
| Console | Zero errors, zero page errors |

This cleanly isolates I1 to the audio-upload step specifically — `submit_session()` itself, the
5-item payload shape, scoring, the screening-code display-only-at-the-end behaviour, and the
complete non-audio UI all work end-to-end in a real browser with zero defects found.

All fixtures, sessions, participants, responses, and the anonymous auth users created by both runs
were deleted afterward (§4.5). Screenshots (17 + 14 PNGs across both runs) were written to the
session scratchpad for my own inspection; they are not part of the repo and were not retained
beyond this session, consistent with "nothing fixture-related should be active = true when you're
done" extended to test artifacts generally.

### 4.5 Fixture teardown

Deleting the six fixture items initially failed on a foreign-key violation from `responses` —
because Run 2's submission genuinely succeeded and created real `responses`/`participants` rows
referencing them. Cleaned up in dependency order: `responses` → `sessions` → `participants` →
`item_options` → `items` → anonymous `auth.users`. Final state confirmed by direct count: `items`
matching `FX%` = 0, `sessions` = 0, `participants` = 0, `responses` = 0, `auth.users` with
`is_anonymous=true` = 0. `items` table overall = 0 rows. The real researcher row
(`arianthehunter@gmail.com`) untouched throughout, confirmed by name after every cleanup pass.

One pre-existing object could not be removed: `badsq-audio/98029b77.../e2e-test.webm`, leftover
debris from an ad hoc real-HTTP test in an earlier turn this phase, before this report's own
browser testing began. `storage.objects` has a `protect_delete` BEFORE DELETE trigger that blocks
even `postgres`-role SQL deletion; removing it requires a real researcher Storage session
(`audio_delete_researcher` is `is_researcher()`-gated), which remains unavailable. Not new fixture
leakage from this report's own testing — carried forward as an existing, already-understood
limitation.

## 5. Deviations from the brief

1. **Item audio-less items unlock immediately instead of deadlocking.** Not asked for explicitly,
   but necessary: without it, any item lacking both instruction and stimulus audio (every fixture
   item, since real audio upload is blocked) would never fire an `ended` event, and the
   disabled-until-audio-ends gate would never lift. See §7.6.
2. **Response history is one row per item, not the full attempt log the schema supports.** Same
   scope trim Phase 1 made for item-editing history, now extended to response submission. Flagged
   as open question 9.4, not silently decided.
3. Everything else built and verified as specified. No migration SQL was altered, and no client
   code was written to route around I1 rather than surface it (§6).

## 6. Problems, errors, and blockers

### I1 — participant audio uploads to `badsq-audio` cannot succeed, for any participant, under the current bucket policy

**Symptom**, found by the Run 1 browser walkthrough (§4.4): after recording, previewing, and
advancing past the AUDIO_RECORD item, Submit fails with:

```
Recording upload failed: AccessDenied new row violates row-level security policy
```

captured directly off the real network response (`400`, body
`{"statusCode":"403","error":"Unauthorized","message":"new row violates row-level security policy","code":"AccessDenied"}`)
for `POST /storage/v1/object/badsq-audio/<session-id>/<response-id>.webm`, sent with a real anon
JWT decoded to confirm `sub` matched the session's own `auth_uid` exactly.

**This looked, at first, exactly like a client bug or a stale/duplicate session** — the two most
likely explanations for "the policy should pass but doesn't." Both were ruled out with direct
evidence, not assumption:

- The `sessions` row for that exact `id`/`auth_uid` existed, `status='in_progress'` — confirmed by
  direct query.
- Evaluating the policy's own `WITH CHECK` boolean expression standalone, with the exact same
  `auth.uid()`/session/path values (via the same `set_config` role-impersonation the verification
  suite uses), returned `true`.
- Yet the actual `INSERT` — reproduced directly in SQL with the identical impersonated identity —
  still failed with the identical `42501` error.

**Root cause, isolated by bisection**: the *only* variable that flips the result is a `RETURNING`
clause on the `INSERT`.

```sql
-- succeeds
insert into storage.objects (bucket_id, name, owner_id, metadata) values (...);

-- fails: 42501 new row violates row-level security policy for table "objects"
insert into storage.objects (bucket_id, name, owner_id, metadata) values (...)
returning id;
```

Postgres RLS requires a row inserted via `INSERT ... RETURNING` to *also* satisfy an applicable
`SELECT` policy for that row to be returned to the client — and raises exactly this
"new row violates row-level security policy" error if none exists, even though the underlying
`WITH CHECK` (the actual insert) already passed. `badsq-audio` has an `INSERT` policy for
participants (`audio_upload_own_session`) but its **only** `SELECT` policy is
`audio_read_researcher`, scoped to `is_researcher()`. Participants have no `SELECT` policy on this
bucket at all — by original design (only researchers/raters should read participant recordings,
confirmed correct and unrelated to this bug: see Phase 1/2's `AudioRecord.tsx`, which already uses
local `Blob`/`createObjectURL` preview rather than round-tripping through Storage, precisely
because of this). Supabase Storage's object-upload endpoint returns the created object's metadata
in its response — which needs `RETURNING` — so **every** real participant audio upload through the
Storage HTTP API hits this, unconditionally, regardless of correct session, auth, or path. This is
not specific to my test fixtures or to the Playwright environment; it is a property of the live
bucket policy as it exists in the database right now.

**This is the same *shape* of defect as H1** (Phase 1's report), though not the same mechanism —
per the standing instruction to name this pattern explicitly when it recurs: a permission facet
that is *individually* correct (participants genuinely should not be able to read each other's or
researchers' recordings) interacts with an enforcement mechanism (RETURNING-visibility, not a
GRANT this time) that a bare boolean policy check does not exercise — so it passed every previous
round of adversarial verification, including this project's own SQL suite, because that suite (like
my own initial standalone check above) tests the `WITH CHECK` expression's truth value, never an
actual `INSERT ... RETURNING`. **This is now a documented gap in the verification methodology
itself**, not just in the schema: a policy's boolean condition being provably `true` is not
sufficient evidence that the real write path succeeds. I do not yet have a fix for the suite itself
in this report — flagged as open question 9.3.

**Not applied as a migration** — consistent with this project's discipline of reporting defects
rather than quietly patching around them, and because the fix's exact scope (session lifetime,
whether it should also finally close the "participant can't preview their own upload via signed
URL" gap noted in the same finding) is a design call for the researcher, not mine to make
unilaterally. Recommended minimal fix, for a future migration:

```sql
create policy audio_select_own_session on storage.objects
  for select using (
    bucket_id = 'badsq-audio'
    and exists (
      select 1 from sessions s
      where s.auth_uid = auth.uid()
        and (storage.foldername(objects.name))[1] = s.id::text
    )
  );
```

Mirrors the existing `audio_upload_own_session` INSERT policy exactly (I deliberately did not
require `status = 'in_progress'` here, since read-visibility of a just-uploaded row should not
depend on whether the session has since completed — the INSERT policy's own `in_progress`
restriction already governs whether a *new* upload can happen). This would also incidentally let a
participant sign a URL for their own recording — not required by the brief, and not something I'm
recommending as a goal, just noting it as a side effect for the researcher's design decision.

**Reconciling with an earlier claim.** An ad hoc real-HTTP curl chain run earlier this phase (before
this report's own browser testing) is recorded as having exercised a successful participant audio
upload, and left a real object (`badsq-audio/98029b77.../e2e-test.webm`, §4.5) as evidence. I cannot
fully reconcile that with today's finding — the bucket's policies have not changed since (migration
0006 touched only `items`/`sessions`), and I have now reproduced the failure twice, independently,
by two different methods (real browser network capture of the actual production code path, and raw
SQL with role impersonation). I am treating today's finding as authoritative because it is the more
rigorous and more completely reproduced of the two, but I want to be explicit that I have not
identified the exact reason the earlier attempt is recorded as succeeding, rather than silently
picking whichever result is more convenient. Worth a direct one-off retest if this discrepancy
matters to the researcher before I1 is fixed.

### On real item audio, iOS, and physical microphones

All three remain genuinely untested, for reasons already established in prior phases (researcher
session unavailable; no physical device access). Stated here again, plainly, per the brief's own
instruction not to let this pass silently as "should work." See §3.

### GitHub push

No secret in the diff — checked again this phase (`git diff` scanned for `service_role`,
`SUPABASE_SERVICE`, and JWT-shaped strings; none found). `.env` confirmed still untracked and
gitignored.

## 7. Decisions I made that weren't in the brief

1. **Installed Playwright + Chromium locally to drive a real browser**, rather than stopping at
   HTTP/SQL-level verification, because the brief's own emphasis this phase — "the actual thing a
   12-year-old uses" — is specifically about the real transport and the real UI, and I had the
   tooling available (no `chromium-cli` on this host, but `npx` was) to actually do it rather than
   reason about it. This is what surfaced I1; it would not have been found by either existing
   suite.
2. **Ran the six-item walkthrough twice** — once with all six formats (which found I1), once with
   AUDIO_RECORD deactivated (which proved everything else works). A single run finding a failure
   tells you less than two runs that isolate exactly what's broken and what isn't.
3. **Did not stop at "the policy's boolean check is true."** When the standalone `WITH CHECK`
   evaluation said `true` but the real `INSERT` still failed, the easy conclusions were "my test
   harness is wrong" or "this is a fluke" — I instead bisected the actual SQL statement clause by
   clause until I found the exact variable (`RETURNING`) that flips the result, because an
   unexplained discrepancy between "the rule says yes" and "the system says no" is exactly the
   shape of bug this project's whole verification methodology exists to catch.
4. **Proposed a specific fix for I1 without applying it.** Consistent with never editing migration
   SQL to route around a failure — but a report that says only "it's broken" is less useful than
   one that also says "here is the minimal, scoped fix, and here is what it would additionally
   enable, which is your call."
5. **Kept using `set_config` role impersonation for SQL-level diagnosis**, as every prior phase has,
   because it is the same mechanism PostgREST and storage-api use internally — but explicitly
   documented, in I1 itself, that this mechanism has a blind spot (RETURNING-visibility) that a real
   HTTP/browser test does not share. Both methods remain in the suite; neither alone is sufficient.
6. **Added an effect in `ItemScreen` that immediately unlocks any item with neither instruction nor
   stimulus audio.** Not asked for, but without it TestRunner would deadlock forever on every
   fixture item, since none carry real audio (I1's sibling limitation: item audio can't be uploaded
   without a researcher session either). This is a genuine robustness improvement surfaced by
   honestly hitting a real constraint rather than faking data around it.
7. **Screenshots and the Playwright driver script live in the session scratchpad, not the repo.**
   They are test-run artifacts, not source; keeping them out of the repository matches this
   project's standing discipline against committing test/fixture material.

## 8. Files created/modified

**Created**
- `supabase/migrations/0006_versioning_and_h1.sql` — the migration as supplied, verbatim
- `src/lib/media.ts` — shared audio-storage helpers (signed URL, item-audio upload, participant-audio upload, MIME detection), extracted out of `itemBank.ts`
- `src/components/responses/types.ts` — shared response-component prop contracts
- `src/components/responses/OptionGrid.tsx` — shared tap-one-of-N option component (MCQ/BINARY/TRI/LIKERT)
- `src/components/responses/McqTap.tsx`, `BinaryTap.tsx`, `TriTap.tsx`, `Likert5.tsx` — thin `OptionGrid` wrappers
- `src/components/responses/NumericKeypad.tsx` — on-screen-only digit entry, never a native `<input>`
- `src/components/responses/AudioRecord.tsx` — record → playback → re-record, device-aware MIME detection
- `src/components/TestRunner.tsx` — the participant flow orchestrator
- `src/components/testrunner.css` — plain CSS, 44px touch targets
- `PHASE_2_REPORT.md` — this file

**Modified**
- `scripts/verify_security.sql` — v3 → v4; +10 assertions (PART 13), 65 → 75
- `scripts/verify-security.mjs` — +1 assertion, 29 → 30
- `src/lib/itemBank.ts` — `createItem()`/`saveNewVersion()` migrated onto the atomic `save_item_version()` RPC; audio helpers now thin re-exports from `media.ts`
- `src/lib/localDraft.ts` — rewritten from a Phase 0/1 stub into a real IndexedDB-backed draft store
- `src/types/database.types.ts` — regenerated; one by-hand nullability fix (`save_item_version`'s `p_old_item_id`)
- `src/App.tsx` — hash router extended with a third branch, `#/test` → `TestRunner`

## 9. Open questions for the researcher

1. **I1 must be fixed before any real participant can complete a session containing an
   AUDIO_RECORD item.** This blocks Domain 5 (spoonerisms) entirely as currently scoped. Recommend
   the migration in §6, verified by re-running this phase's exact Run 1 browser walkthrough before
   considering it closed.
2. **The earlier-recorded "successful" real-HTTP audio upload (§6, reconciliation note) should be
   independently re-checked** — I could not explain the discrepancy from the evidence available to
   me this session, and I would rather flag an unresolved contradiction than quietly resolve it in
   whichever direction is more convenient.
3. **The SQL verification suite has a blind spot**: boolean `WITH CHECK` evaluation doesn't exercise
   RETURNING-visibility. Worth adding an actual `INSERT ... RETURNING` (not just the boolean
   expression) to every storage-policy assertion in `verify_security.sql` — I did not attempt this
   rewrite in this report, since the underlying bug (I1) needs a decision first.
4. **Response history**: same question as Phase 1's item-version history — should `submit_session()`
   start populating `attempt_number`/`is_superseded` for a re-answered item, or is one row per item
   the intended final behaviour? Not urgent while the runner has no interactive rewind, but worth
   settling before it does.
5. **`sessions_select`'s new `auth_rls_initplan` warning** (§4.3) — cheap to fix
   (`(select auth.uid())` instead of `auth.uid()`), not urgent at current traffic.
6. Carried forward unchanged: H1's SQL-level privilege note is now closed; Domain 4 replayability,
   data residency (Mumbai), and the Free → Pro upgrade remain open from earlier phases.

## 10. State of the repo

- **Branch:** `main`, pushed to `https://github.com/ArianThehunter/BADSQ`
- **Commit:** `8675733` — "Phase 2: migration 0006 (H1 fix + atomic item versioning), TestRunner and the six response components"
- **Supabase project:** `badsq-platform`, ref `gfxdhqkxetuoetzzrxxq`, region `ap-south-1`, Postgres 17.6, Free plan
- **Migration state:** 0001–0006 all applied. Database contains **no data** — every fixture, session, participant, response, and anonymous auth user created during this phase's verification and browser testing was deleted; confirmed by direct count. One piece of pre-existing, undeletable-by-SQL debris remains in `badsq-audio` from an earlier turn (§4.5) — not new, not fixture-created this pass, requires a researcher Storage session to remove.

**Does the app run?** Yes.

```bash
npm install
cp .env.example .env     # fill in URL + publishable key
npm run dev
```

`npm run build` completes clean. `npm run typecheck` passes with no errors. `npm run lint` reports
four warnings, all `react/set-state-in-effect` on synchronous `setState` calls inside effects that
synchronize with an external resource (three pre-existing from Phase 1, one new in
`AudioRecord.tsx` for the object-URL preview) — reviewed and accepted at each site, per the same
reasoning documented in Phase 1.

**What works end-to-end right now, from a user's perspective?**

- **A participant can complete the entire test flow for five of six response formats**, in a real
  browser, with zero console errors: intake, item sequencing, lock-on-advance, the on-screen-only
  numeric keypad, and a real submission that returns and displays the assigned screening code only
  at the end.
- **AUDIO_RECORD's client-side recording pipeline is fully correct** — record, stop, preview,
  re-record, Next-unlock all work — but a real recording **cannot currently be submitted**, for any
  participant, because of I1.
- **The item bank editor now edits atomically** via `save_item_version()`, closing Phase 1's open
  gap, with a genuine crash-shape rollback proven, not just reasoned about.
- **H1 is fully closed** at both the SQL-privilege and HTTP-attack-surface level.

Two real gaps remain open and are not hidden: **I1** (blocking, described in full above with a
proposed fix), and the still-unresolved discrepancy with an earlier real-HTTP test's recorded
result. Both are recorded with exactly what would close them.
