# BADSQ Platform

Data-collection instrument for a dyslexia screening study with 12–14 year old participants
in Bangladesh. Vite + React + TypeScript client, Supabase (Postgres + Storage + Auth) backend.

**Current phase: 0 — scaffold, migrations, RLS verification.** The participant test flow is
Phase 1 and is not built yet. Read [PHASE_0_REPORT.md](PHASE_0_REPORT.md) first — it lists
four blocking findings that must be resolved before Phase 1 can begin.

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

`supabase/migrations/` holds three files, applied in order:

| File | Contents |
|---|---|
| `0001_schema.sql` | Tables, versioned item bank, rating-propagation trigger, `ml_export_v1` |
| `0002_rls_policies.sql` | Row-Level Security for anonymous participants and allowlisted researchers |
| `0003_phase0_fixes.sql` | Circular-FK removal, dual latency anchors, answer-key views, storage bucket + policies, atomic `submit_session()` RPC, indexes |

All three apply cleanly against Postgres 17.6. Apply with `supabase migration up`, or paste
each file into the SQL editor in order.

## Verification

Two suites, both re-runnable, covering different layers:

```bash
node scripts/verify-security.mjs     # real HTTP as the anon role (21 assertions)
```

```
scripts/verify_security.sql          # RLS/policy layer via role impersonation (58 assertions)
```

Run the SQL suite as `postgres` in the Supabase SQL editor. It rebuilds its own fixtures,
writes results to `verify.results`, and tears down cleanly. Latest recorded outcome:
**58 assertions, 43 passed, 15 failed** and **21 HTTP assertions, 15 passed, 6 failed** —
every failure is catalogued in [PHASE_0_REPORT.md](PHASE_0_REPORT.md).

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
  lib/supabaseClient.ts        Supabase client, env config, anonymous sign-in helper
  lib/localDraft.ts            IndexedDB resume draft            (Phase 1, stub)
  components/TestRunner.tsx    Item sequencer                    (Phase 1, stub)
  components/responses/        The six response formats          (Phase 1, stubs)
  admin/                       Participants, rating queue,
                               item-bank editor, health view     (Phase 2, stubs)
  types/database.types.ts      Generated from the live schema
public/fonts/                  Self-hosted Unicode Bangla font
scripts/                       Verification suites
supabase/migrations/           0001, 0002, 0003
```
