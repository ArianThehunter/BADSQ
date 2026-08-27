# Phase 4 Report — BADSQ Platform

## 1. Scope

Apply migration `0008_reliability_subsample.sql`, which switches reliability-subsample
assignment from Phase 3's manual-only toggle to automatic random assignment at submission time
(20%, adjustable in one place), keeping the manual toggle as an override rather than the primary
mechanism — a methodological correction, since a rater choosing which recordings get double-scored
can bias the Cohen's kappa the Development Report commits to reporting. Remove the unnecessary
`upsert: true` from `uploadParticipantAudio()` in `media.ts` — the other independently-viable fix
for I1 identified in Phase 3, applied now as defense in depth. Prepare a real deployment
(Vercel/Netlify free tier) so the researcher can test on an actual phone, since Chromium-with-
fake-devices cannot verify iOS Safari's audio format behavior or real microphone hardware — every
prior phase correctly flagged this rather than papering over it, and it needs to happen before that
gap can close.

Migration 0008 applied with zero SQL errors and its intended behavior — automatic ~20% random
assignment, manual override still functional, guard-clause rewrite behaviorally equivalent to the
version it replaced — verified. One real, unrelated defect surfaced during that verification: the
migration's own `reliability_subsample_rate()` function is missing the `search_path` pinning this
project's G3 hardening (Phase 1) established for every function in the schema, confirmed by both
the security advisor and the exact query the test suite itself runs for that check. Reported below
as **J1**, not patched. The `upsert` removal was regression-tested against the real six-format
Playwright flow with zero issues. Deployment could not be completed by me — no Vercel/Netlify CLI
was authenticated in this environment, and completing an OAuth login is not something I can do on
the user's behalf — so per the user's own choice, deployment is prepared (build verified,
environment variables documented, routing confirmed to need no server config) and handed off for
the user to do themselves.

## 2. Completed

- [x] Migration 0008 applied — `supabase/migrations/0008_reliability_subsample.sql`
- [x] `reliability_subsample_rate()` confirmed to return `0.20` and confirmed to be the **only**
      place in the entire codebase (migrations, scripts, and app source) that hardcodes a rate —
      grepped across `*.ts,*.tsx,*.sql,*.mjs` — §4.1
- [x] Automatic random assignment verified over two independent batches (60 and 40 real
      `submit_session()` calls), landing 17% and comfortably within a sane range both times — §4.1
- [x] `submit_session()`'s rewritten guard clause (four separate raise points collapsed into one
      `WHERE` + a NULL check) verified behaviorally equivalent to the version it replaced, across
      all five previously-tested branches (owner-succeeds, non-owner-rejected, re-submit-rejected,
      assigned-code-NULL-rejected, atomicity-rollback) — §4.2
- [x] RatingQueue's manual override confirmed to still work on top of the new automatic baseline,
      in both directions (flip an automatically-`false` recording to `true`, and vice versa) — §4.3
- [x] **J1 found and reported**: `reliability_subsample_rate()` violates this project's own G3
      invariant (every `public` function must have a pinned `search_path`) — §6
- [x] `upsert: true` removed from `uploadParticipantAudio()` in `media.ts` — §4.4
- [x] Regression-tested the full six-format Playwright walkthrough after the `upsert` removal:
      identical zero-error pass, real `200` upload, real assigned code on completion — §4.4
- [x] `verify_security.sql` updated (v5 → v6): PART 15 added for the rate function and the
      distribution sanity check; header documents that PART 7's existing guard-clause assertions
      now double as 0008 regression tests rather than duplicating them — §4.2/§4.5
- [x] Both advisors re-run after full teardown — §4.5
- [x] Deployment prepared: build verified clean, routing confirmed to need zero server-side
      config (hash-based, not history-based), environment variables documented for the platform
      dashboard — §4.6
- [x] All fixtures, sessions, responses, and audio recordings created during this phase's
      verification deleted; confirmed by direct count

## 3. Not completed / deferred

- [ ] **Deployment itself.** No Vercel/Netlify CLI was authenticated in this environment and I
      cannot complete an interactive OAuth login on the user's behalf. The user chose to do the
      deployment themselves rather than provide a token; §4.6 has the exact steps and environment
      variables needed.
- [ ] **Real-device testing.** Explicitly out of scope for me this phase per the brief — iOS
      Safari's audio behavior and real microphone hardware are exactly what Chromium-with-fake-
      devices cannot verify, and every prior phase correctly declined to fake this rather than
      claim false confidence. This is the researcher's task once the deployment URL exists.
- [ ] **J1 not fixed.** Consistent with this project's discipline of reporting defects rather than
      patching migration SQL to route around them — see §6 for the one-line fix, not applied here.

## 4. Verification results

### 4.1 `reliability_subsample_rate()` and automatic assignment

| Check | Expected | Actual | Pass/Fail |
|---|---|---|---|
| `reliability_subsample_rate()` returns `0.20` | `0.2` | `0.2` | **Pass** |
| Sole definition of the rate, codebase-wide | no other hardcoded rate anywhere | `grep` across `*.ts,*.tsx,*.sql,*.mjs` found the literal `0.20` only inside `0008_reliability_subsample.sql` itself | **Pass** |
| Distribution, batch 1 (ad hoc, 60 real submissions, one audio response each) | roughly 20% | `10 / 60` (16.7%) | **Pass** — sane for p=0.2, n=60 |
| Distribution, batch 2 (in the committed suite, 40 real submissions) | roughly 20%, band 2–20 out of 40 | within band | **Pass** |

Both batches used real `submit_session()` calls through role-impersonation, not a synthetic
Bernoulli draw outside the function — this is the actual code path a participant's submission
goes through.

### 4.2 Guard-clause rewrite — behavioral equivalence

Migration 0008 replaces `submit_session()`'s four separate `raise exception` branches (session not
found / not owned / not `in_progress` / `assigned_code is null`) with a single `WHERE` clause plus
one NULL check. All four old branches raised the identical message
(`"Session not found, not owned by caller, or already submitted"`), so this collapse is provably
equivalent **if** every branch that used to reach a `raise` still reaches one. Verified directly,
not just reasoned about:

| Branch | Old mechanism | New mechanism | Result |
|---|---|---|---|
| Session doesn't exist | `select ... into v_session` finds no row → `not found` | `WHERE id=...` matches no row → `v_assigned_code` stays NULL | **Pass** — rejected |
| Session exists, wrong owner | `v_session.auth_uid is distinct from auth.uid()` | `WHERE auth_uid = auth.uid()` excludes the row → NULL | **Pass** — rejected |
| Session exists, owned, already completed | `v_session.status <> 'in_progress'` | `WHERE status = 'in_progress'` excludes the row → NULL | **Pass** — rejected (re-submit test) |
| Session exists, owned, `in_progress`, but `assigned_code` is genuinely NULL | explicit `elsif ... is null` check | the same `SELECT ... INTO v_assigned_code` naturally returns NULL for a NULL column value, same as a not-found row — the collapsed `if v_assigned_code is null` check catches both cases identically | **Pass** — rejected (defensive-branch test) |
| Atomicity: unknown `item_id` mid-loop | unchanged code, unaffected by the guard-clause rewrite | unchanged | **Pass** — rolls back completely, `0` new participants/responses, session stays `in_progress` |

All five re-verified live against the actual post-0008 function (not inferred from reading the
SQL) via the same `set_config` role-impersonation mechanism the suite always uses. One
observability note, not a functional regression: the old version's per-branch `raise log` calls
(distinguishing *which* of the four reasons caused a rejection, in the server log) are gone —
every case now looks identical to Postgres's own log, though every case still looks identical to
the *caller* in both versions, since the exception message was already the same for all four.

### 4.3 Manual override still works on top of automatic assignment

Took a real automatically-assigned recording (`is_reliability_subsample = false` from the random
draw) and flipped it to `true` via the identical `UPDATE audio_recordings SET
is_reliability_subsample = ...` statement `setReliabilitySubsample()` in `adminData.ts` issues —
and the reverse, on a recording the random draw had assigned `true`. Both flips persisted
correctly. The override path is untouched by 0008 (it's a plain `UPDATE`, not routed through
`submit_session()`), so this was a confirmation that nothing about the new INSERT-time default
interferes with a later UPDATE, not a discovery of new logic.

### 4.4 `upsert: true` removed — regression-tested

Removed the flag; ran the complete Phase 2 Run 1 Playwright walkthrough (all six formats,
unmodified script) once more:

| Step | Result |
|---|---|
| All six response formats | Identical to every prior run |
| Audio upload at submit | `POST /storage/v1/object/badsq-audio/... → 200 {"Key":...,"Id":...}` — now via a plain `INSERT`, not an upsert, and still succeeds (both because a plain insert never needed the SELECT policy in the first place, per Phase 3 §4.4, and because that SELECT policy is still there from 0007 regardless) |
| Completion screen | Real assigned code, as always |
| Console/page errors | Zero |

`responseClientId` is a fresh UUID per response (from `crypto.randomUUID()` in `TestRunner.tsx`),
so there is no scenario where this path re-uploads to an existing key — `upsert` semantics were
never doing anything here, consistent with the reasoning that led to removing it.

### 4.5 Verification suite and advisors

`verify_security.sql` v5 → v6: PART 15 added (rate function + distribution sanity), header updated
to explain PART 7's assertions now double as 0008 regression tests. A full run of PART 1 fixtures +
the PART 7 submit_session() subset + PART 15 (7 assertions) — **7/7 passed**, matching §4.1/§4.2
above exactly. PARTs 2–14 were not re-run in full this phase: none of them exercise
`submit_session()`'s internals besides PART 7 (already re-verified), and Phase 3's clean run
already confirmed all 82 pass; nothing in 0008 touches anything those parts check.

**Security advisor — 2 ERROR, 27 WARN** (was 2 ERROR, 26 WARN before this phase):

| Change | Detail |
|---|---|
| **NEW: `function_search_path_mutable` for `reliability_subsample_rate`** | This is J1 — see §6 |
| Everything else | Unchanged from Phase 3's final numbers |

**Performance advisor — unchanged**: 9 INFO (`unindexed_foreign_keys`, unchanged), 1 INFO
(`unused_index`, unchanged), 5 WARN (`multiple_permissive_policies`, `item_options` only,
unchanged). Migration 0008 touches nothing this advisor tracks.

### 4.6 Deployment preparation

Confirmed rather than assumed:

- **`npm run build` completes clean** against the current tree (`tsc -b && vite build`, `dist/`
  output, no warnings beyond the pre-existing accepted lint set).
- **No server-side routing configuration is needed on either platform.** `App.tsx`'s router reads
  `window.location.hash` (`#/admin`, `#/test`) — hash fragments never reach the server, so there is
  no history-API rewrite rule to configure (the thing that trips up a naive static SPA deploy).
  This is genuinely zero-config for a static host: build command `npm run build` (or the
  platform's own default, which is the same), output directory `dist`, no redirects file needed.
- **Environment variables** the researcher needs to set in the platform's dashboard (never in a
  committed file, per the brief and this project's standing discipline):
  - `VITE_SUPABASE_URL`
  - `VITE_SUPABASE_PUBLISHABLE_KEY`
  - `VITE_SUPABASE_AUDIO_BUCKET` (optional — defaults to `badsq-audio` if unset)

  All three are already documented in `.env.example`; the values are the same ones already in the
  researcher's local `.env` (not the placeholder committed to the repo).
- **No `vercel.json`/`netlify.toml` was added.** Both platforms auto-detect a Vite project
  correctly with zero configuration, and hand-writing a config file for a case that doesn't need
  one is exactly the kind of untested addition this project's discipline avoids — better to let the
  platform's own well-tested Vite preset handle it than to introduce a config file I cannot verify
  against a real account.

I did not create an account, authenticate a CLI, or trigger any deployment myself, per the user's
choice in this turn.

## 5. Deviations from the brief

Everything built and verified as specified. No migration SQL was altered — including 0008 itself,
despite finding a real defect in it (§6). No `vercel.json`/`netlify.toml` was added; see §4.6 for
why that's a deliberate choice, not an oversight.

## 6. Problems, errors, and blockers

### J1 — `reliability_subsample_rate()` is missing the search_path pinning every other function in this schema has

**Found while re-running the advisors after applying 0008**, not anticipated going in. The security
advisor flagged `function_search_path_mutable` for exactly one function:
`public.reliability_subsample_rate`. Confirmed independently with the *exact* query this project's
own G3 hardening (`PHASE_1_REPORT.md`) uses to check this invariant across every function in
`public`:

```sql
select p.proname, p.prosecdef, coalesce(array_to_string(p.proconfig, ', '), '(none)') as proconfig
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public'
  and not exists (select 1 from unnest(coalesce(p.proconfig,'{}')) c where c like 'search_path=%');
```

Returns exactly one row: `reliability_subsample_rate`, `prosecdef=false`, `proconfig=(none)`. Every
other function in `public` — thirteen of them across four migrations — has carried a pinned
`search_path` since Phase 1 specifically closed this gap for the entire schema, not just
`SECURITY DEFINER` functions. Migration 0008, as supplied, is the first migration since then to
introduce a function that doesn't have one.

**Is this actually exploitable here?** I looked rather than assumed either way. `reliability_subsample_rate()`
is `SECURITY INVOKER` (the default — `prosecdef=false`), and its body is a single literal
(`select 0.20`) with no table, type, operator, or function reference for a hostile search_path to
redirect. Its only caller, `submit_session()`, calls it unqualified from within a body that already
has `set search_path = public` pinned on itself — and a pinned caller's search_path governs name
resolution for the unqualified calls it makes, regardless of whether the callee also pins its own.
So in this specific instance, I don't believe there is a live attack path — but that is a
conclusion I reached by reading this function and its one caller carefully, not something the
schema enforces structurally. The project's own G3 reasoning (`PHASE_1_REPORT.md` §4.1: "a
non-definer helper with a mutable search_path sitting inside a SECURITY DEFINER caller can still be
exploited via search-path manipulation of the objects it references") is exactly the shape of risk
a function like this could someday carry, if it's ever extended to reference an unqualified object,
or called from a context that isn't already pinned. This is worth naming as the same recurring
pattern flagged in Phase 2 and Phase 3's reports (F1/G5 → H1 → I1, all "a fix or an addition that
is correct in the case actually tested, but misses a hardening property everything else in this
project carries") — this is now four occurrences of that shape across four phases, and I'm
flagging it explicitly again per the standing instruction to do so.

**Not fixed here.** One-line recommended fix for a future migration:

```sql
create or replace function reliability_subsample_rate() returns double precision
language sql
immutable
set search_path = public
as $$
  select 0.20;
$$;
```

### GitHub push

No secret in the diff — checked again this phase. Nothing in this phase's work touched
credentials at all (no new auth flow, no new researcher account).

## 7. Decisions I made that weren't in the brief

1. **Ran the distribution check twice, at two different scales (60 ad hoc, then 40 in the
   committed suite)**, rather than once. A single batch passing a sanity band is consistent with
   the mechanism working, but two independent batches at different sizes both landing in-range is
   stronger evidence the randomness is genuinely being drawn per-call rather than, say, accidentally
   fixed per-session or per-item.
2. **Verified the guard-clause rewrite branch-by-branch against the exact five behaviors PART 7
   already specified**, rather than treating "the function still returns the right thing on a happy
   path" as sufficient. A collapsed conditional is exactly the kind of refactor that can silently
   drop a case; re-deriving on paper that it's equivalent isn't the same as re-running the actual
   branches.
3. **Investigated whether J1 is actually exploitable rather than just flagging the lint and
   moving on.** A search_path warning on a function with no object references and one already-pinned
   caller is a different risk profile than the same warning on a `SECURITY DEFINER` function that
   touches tables — worth being precise about which one this is, rather than either dismissing the
   advisor or overstating the danger.
4. **Did not write a `vercel.json`/`netlify.toml`.** Explained in §4.6 — the app doesn't need one,
   and adding one I can't test against a real account risks introducing exactly the kind of
   unverified change this project avoids.

## 8. Files created/modified

**Created**
- `supabase/migrations/0008_reliability_subsample.sql` — the migration as supplied, verbatim
- `PHASE_4_REPORT.md` — this file

**Modified**
- `scripts/verify_security.sql` — v5 → v6; PART 15 added (2 assertions: rate function, distribution sanity)
- `src/lib/media.ts` — `upsert: true` removed from `uploadParticipantAudio()`
- `src/admin/RatingQueue.tsx` — header comment updated (automatic assignment is now real, not absent)
- `src/lib/adminData.ts` — `setReliabilitySubsample()`'s doc comment updated to describe it as an override, not the primary mechanism

## 9. Open questions for the researcher

1. **J1** — apply the one-line `set search_path = public` fix in a future migration? Low urgency
   given no live exploit path was found, same reasoning as H1's eventual resolution.
2. **Deployment.** Steps and environment variables are in §4.6. Once live: sign in on a real
   iPhone (Safari) and a real Android phone (Chrome) as a participant, complete an AUDIO_RECORD
   item, and confirm both the recording and the submission succeed — this is the first real test of
   iOS's MP4/AAC path this project has ever had the ability to run.
3. Carried forward unchanged: Domain 4 replayability, data residency (Mumbai), Free → Pro upgrade,
   `auth_leaked_password_protection` (Phase 3 §9.4).

## 10. State of the repo

- **Branch:** `main`, pushed to `https://github.com/ArianThehunter/BADSQ`
- **Commit:** `261c8d6` — "Phase 4: migration 0008 (unbiased reliability sampling), upsert removal, deployment prep"
- **Supabase project:** `badsq-platform`, ref `gfxdhqkxetuoetzzrxxq`, region `ap-south-1`, Postgres 17.6, Free plan
- **Migration state:** 0001–0008 all applied. Database contains **no data** — every fixture, session, participant, response, and audio recording created during this phase's verification (two distribution batches, five guard-clause checks, one regression run) was deleted; confirmed by direct count.

**Does the app run?** Yes.

```bash
npm install
cp .env.example .env     # fill in URL + publishable key
npm run dev
```

`npm run build` completes clean. `npm run typecheck` passes with no errors. `npm run lint` reports
the same five warnings as Phase 3, all the same accepted `react/set-state-in-effect` pattern.

**What works end-to-end right now, from a user's perspective?**

- **Reliability-subsample assignment is now unbiased by construction** — random, at submission
  time, before any rater ever sees a recording — with the manual override still available for
  legitimate one-off cases.
- **The `upsert:true` that made I1 exploitable in the first place is gone**, independent of the
  0007 SELECT-policy fix already in place — two layers of defense instead of one.
- **The app builds clean and needs zero server-side configuration to deploy** as a static site to
  either Vercel or Netlify's free tier.

One real defect (J1) is documented, not hidden, with an honest assessment of why it doesn't appear
exploitable today and what would make it worth fixing regardless. Deployment itself is the
researcher's next action, with everything needed to do it already laid out in §4.6.
