# BADSQ Platform

Data-collection instrument for a dyslexia screening study with 12–14 year old participants
in Bangladesh. Vite + React + TypeScript client, Supabase (Postgres + Storage + Auth) backend.

**Current phase: 3 — I1 fixed, researcher admin surfaces complete.** Researcher sign-in is now
email + password (no email delivery dependency). The full six-format participant flow, including
AUDIO_RECORD, works end to end. RatingQueue, ParticipantsView, and HealthView are built and
verified against a real signed-in researcher session.

Read the reports in order: [PHASE_0_REPORT.md](PHASE_0_REPORT.md) found seven defects (F1–F7) in
migrations 0001–0003; [MIGRATION_0004_REPORT.md](MIGRATION_0004_REPORT.md) fixed those and found
ten more (G1–G10); [PHASE_1_REPORT.md](PHASE_1_REPORT.md) fixes seven of those (migration 0005),
adds a self-testing release gate against the view-column-drift defect class that had recurred
twice, and builds researcher magic-link auth plus the Item Bank Editor; [PHASE_2_REPORT.md](PHASE_2_REPORT.md)
closes H1 and adds atomic item versioning (migration 0006), builds TestRunner and the six response
components, and — via genuine browser-driven testing, new that phase — finds **I1: participant
audio recordings cannot be submitted at all**; [PHASE_3_REPORT.md](PHASE_3_REPORT.md) replaces
magic-link auth with email+password, fixes I1 (migration 0007), resolves the Phase 2 curl
discrepancy (it was neither hypothesis — see the report), closes the verification suite's own
blind spot that let I1 through for two phases, and builds RatingQueue/ParticipantsView/HealthView
against a real researcher session for the first time — including one full record → submit → rate →
export pipeline run.

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

Beyond that, dashboard steps that are **not** automatable:

1. ~~Authentication → Providers → enable Anonymous Sign-ins.~~ **Done.**
2. ~~Configure magic-link email auth for researcher login.~~ **No longer needed** — Phase 3
   replaced magic-link with email + password (`Authentication → Users → Add user`), removing the
   one part of the login flow that email delivery had broken twice.
3. Pre-populate the `researchers` allowlist with your team's real emails, and create their accounts
   directly in the dashboard (Authentication → Users → Add user, with a real email + password).
   One real address is already present and account-linked.
4. ~~Fix I1 before enabling any AUDIO_RECORD item.~~ **Done** — migration 0007, verified in
   [PHASE_3_REPORT.md](PHASE_3_REPORT.md) §4.2.
5. Enable **Leaked Password Protection** (Authentication → Policies) — newly relevant now that
   researcher accounts have real passwords; see [PHASE_3_REPORT.md](PHASE_3_REPORT.md) §4.9/§9.4.

## Migrations

`supabase/migrations/` holds seven files, applied in order:

| File | Contents |
|---|---|
| `0001_schema.sql` | Tables, versioned item bank, rating-propagation trigger, `ml_export_v1` |
| `0002_rls_policies.sql` | Row-Level Security for anonymous participants and allowlisted researchers |
| `0003_phase0_fixes.sql` | Circular-FK removal, dual latency anchors, answer-key views, storage bucket + policies, atomic `submit_session()` RPC, indexes |
| `0004_phase0_defect_fixes.sql` | Fixes F1–F7; adds the item-audio bucket, server-issued participant codes (`start_session()`), and paper-consent linkage |
| `0005_hardening.sql` | Fixes G1–G3, G6–G8 and a NULL-answer-key scoring hazard; adds referential integrity to the paper-consent join key |
| `0006_versioning_and_h1.sql` | Closes H1 (PUBLIC grant on the trigger functions); adds atomic `save_item_version()`; consolidates `sessions`' two SELECT policies into one |
| `0007_i1_fix.sql` | Closes I1 (missing SELECT policy on `badsq-audio` broke every participant audio upload via `INSERT...RETURNING`); fixes both `auth_rls_initplan` warnings; adds `responses.selection_change_count` |

All seven apply cleanly against Postgres 17.6. Apply with `supabase migration up`, or paste
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
node scripts/verify-security.mjs     # real HTTP as the anon role (30 assertions)
```

```
scripts/verify_security.sql          # RLS/policy layer via role impersonation (82 assertions)
```

```
scripts/check_view_drift.sql         # standing release gate: every view's output columns must
                                      # resolve to a real base column, or be explicitly allowlisted
```

Run the SQL suite as `postgres` in the Supabase SQL editor. It rebuilds its own fixtures,
writes results to `verify.results`, and tears down cleanly. Latest recorded outcome after
migration 0007: **82 assertions, 82 passed** and **30 HTTP assertions, 30 passed**. Run
`check_view_drift.sql` before every deploy — it is what stands between a future base-column
rename and a third silent recurrence of the defect that broke `ml_export_v1` (0003) and then
`public_items` (0004).

**The SQL suite's storage checks were rewritten in Phase 3** specifically because they didn't
catch I1: they tested a bare `INSERT` where the real failure only shows up on `INSERT ...
RETURNING` (see [PHASE_2_REPORT.md](PHASE_2_REPORT.md) §6 and [PHASE_3_REPORT.md](PHASE_3_REPORT.md)
§4.5). Every storage assertion now uses `RETURNING`. `verify-security.mjs`'s storage checks were
left as-is — they only ever tested anon-key denial, never a signed-in participant's own upload, so
they never had this particular blind spot.

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
  lib/supabaseClient.ts        Supabase client, env config, anonymous + researcher password auth
  lib/itemBank.ts              Item bank data access: versioning via save_item_version() RPC
  lib/itemValidation.ts        Pure activation-guard logic (no I/O)
  lib/media.ts                 Shared audio-storage helpers: signed URLs, uploads, MIME detection
  lib/localDraft.ts            IndexedDB resume draft, keyed by session UUID
  lib/adminData.ts             Data access for RatingQueue / ParticipantsView / HealthView
  components/TestRunner.tsx    Participant flow orchestrator: intake, sequencing, submit, resume
  components/testrunner.css    Plain CSS for the participant flow — no component library
  components/responses/        The six response formats (MCQ/BINARY/TRI/LIKERT/NUMERIC/AUDIO)
  admin/AuthGate.tsx           Email + password sign-in + allowlist resolution
  admin/AdminShell.tsx         Identity banner, sign out, nav
  admin/ItemBankEditor.tsx     List/filter/create/edit/soft-delete, versioning, audio upload
  admin/RatingQueue.tsx        Human rating of AUDIO_RECORD responses
  admin/ParticipantsView.tsx   Read-only participant roster
  admin/HealthView.tsx         Operational summary counts
  admin.css                    Plain CSS for the admin panel — no component library
  types/database.types.ts      Generated from the live schema
public/fonts/                  Self-hosted Unicode Bangla font
scripts/                       Verification suites + the view-drift release gate
supabase/migrations/           0001, 0002, 0003, 0004, 0005, 0006, 0007
```
