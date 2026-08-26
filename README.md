# BADSQ Platform

Data-collection instrument for a dyslexia screening study with 12–14 year old participants
in Bangladesh. Vite + React + TypeScript client, Supabase (Postgres + Storage + Auth) backend.

**Current phase: 1 — researcher auth + Item Bank Editor.** The participant test flow
(TestRunner) is Phase 2+ and is not built yet.

Read the reports in order: [PHASE_0_REPORT.md](PHASE_0_REPORT.md) found seven defects (F1–F7) in
migrations 0001–0003; [MIGRATION_0004_REPORT.md](MIGRATION_0004_REPORT.md) fixed those and found
ten more (G1–G10); [PHASE_1_REPORT.md](PHASE_1_REPORT.md) fixes seven of those (migration 0005),
adds a self-testing release gate against the view-column-drift defect class that had recurred
twice, and builds researcher magic-link auth plus the Item Bank Editor. **One known gap remains
(H1): the two trigger functions' `EXECUTE` privilege was revoked from `anon`/`authenticated` but
not from `PUBLIC`, which those roles still inherit from — not remotely exploitable (PostgREST
does not expose trigger-returning functions as RPCs at all), but not the fix as specified either.**

## Privacy posture

This app handles data from minors. There are deliberately **no analytics, no telemetry, and
no third-party scripts or asset requests** of any kind. The Bangla webfont is self-hosted
(see [public/fonts/README.md](public/fonts/README.md)) rather than loaded from Google Fonts,
so no participant IP address is ever disclosed to a third party. Keep it that way.

## Setup

```bash
npm install
cp .env.example .env        # then fill in your project URL and publishable key
npm run dev
```

`.env` is gitignored. Never put a `service_role` / secret key in it — Vite inlines every
`VITE_*` variable into the client bundle.

Beyond that, three dashboard steps are **not** automatable and are still outstanding:

1. **Authentication → Providers → enable Anonymous Sign-ins.** Participant sessions depend
   on it. Currently disabled; `signInAnonymously()` returns
   `422 anonymous_provider_disabled`.
2. Configure magic-link email auth for researcher login.
3. Pre-populate the `researchers` allowlist with your team's real emails before anyone tries
   to log into the admin panel.

## Migrations

`supabase/migrations/` holds five files, applied in order:

| File | Contents |
|---|---|
| `0001_schema.sql` | Tables, versioned item bank, rating-propagation trigger, `ml_export_v1` |
| `0002_rls_policies.sql` | Row-Level Security for anonymous participants and allowlisted researchers |
| `0003_phase0_fixes.sql` | Circular-FK removal, dual latency anchors, answer-key views, storage bucket + policies, atomic `submit_session()` RPC, indexes |
| `0004_phase0_defect_fixes.sql` | Fixes F1–F7; adds the item-audio bucket, server-issued participant codes (`start_session()`), and paper-consent linkage |
| `0005_hardening.sql` | Fixes G1–G3, G6–G8 and a NULL-answer-key scoring hazard; adds referential integrity to the paper-consent join key |

All five apply cleanly against Postgres 17.6. Apply with `supabase migration up`, or paste
each file into the SQL editor in order.

### Participant codes

Sessions are opened with the `start_session()` RPC, never by inserting a `sessions` row directly.
It returns a `BADSQ-XXXX-XXXX` code (alphabet excludes I/O/0/1 because it is hand-transcribed)
which the supervising teacher writes onto the paper consent form. `submit_session()` takes the
code from the session row and **ignores any code in the client payload** — that is verified by a
tamper assertion in the suite.

## Verification

Three checks, all re-runnable, covering different layers:

```bash
node scripts/verify-security.mjs     # real HTTP as the anon role (29 assertions)
```

```
scripts/verify_security.sql          # RLS/policy layer via role impersonation (65 assertions)
```

```
scripts/check_view_drift.sql         # standing release gate: every view's output columns must
                                      # resolve to a real base column, or be explicitly allowlisted
```

Run the SQL suite as `postgres` in the Supabase SQL editor. It rebuilds its own fixtures,
writes results to `verify.results`, and tears down cleanly. Latest recorded outcome after
migration 0005: **65 assertions, 63 passed, 2 failed** and **29 HTTP assertions, 28 passed,
1 failed** — every failure is catalogued in [PHASE_1_REPORT.md](PHASE_1_REPORT.md). Run
`check_view_drift.sql` before every deploy — it is what stands between a future base-column
rename and a third silent recurrence of the defect that broke `ml_export_v1` (0003) and then
`public_items` (0004).

## Scripts

| Command | What it does |
|---|---|
| `npm run dev` | Vite dev server |
| `npm run build` | `tsc -b` then production build |
| `npm run typecheck` | Types only |
| `npm run lint` | oxlint |
| `npm run verify:rls` | HTTP-level security suite |

## Layout

```
src/
  lib/supabaseClient.ts        Supabase client, env config, anonymous + magic-link auth helpers
  lib/itemBank.ts              Item bank data access: versioning, audio upload/signing
  lib/itemValidation.ts        Pure activation-guard logic (no I/O)
  lib/localDraft.ts            IndexedDB resume draft            (Phase 2+, stub)
  components/TestRunner.tsx    Item sequencer                    (Phase 2+, stub)
  components/responses/        The six response formats          (Phase 2+, stubs)
  admin/AuthGate.tsx           Magic-link sign-in + allowlist resolution
  admin/AdminShell.tsx         Identity banner, sign out, nav
  admin/ItemBankEditor.tsx     List/filter/create/edit/soft-delete, versioning, audio upload
  admin/{ParticipantsView,RatingQueue,HealthView}.tsx   Phase 2+, stubs
  admin.css                    Plain CSS for the admin panel — no component library
  types/database.types.ts      Generated from the live schema
public/fonts/                  Self-hosted Unicode Bangla font
scripts/                       Verification suites + the view-drift release gate
supabase/migrations/           0001, 0002, 0003, 0004, 0005
```
