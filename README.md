# BADSQ Platform

Data-collection instrument for a dyslexia screening study with 12–14 year old participants
in Bangladesh. Vite + React + TypeScript client, Supabase (Postgres + Storage + Auth) backend.

**Status: ready for real data collection.** The instrument has been run end to end on three
real devices — Android/Chrome, iPhone/Safari and Windows/Edge — completing all 77 items with
audio recording, latency capture and atomic submission working on each. The database has been
cleared of pilot data.

Three documents describe the system in depth, and are more current than this file:

| Document | For |
|---|---|
| [TECHNICAL_DOCUMENTATION.md](TECHNICAL_DOCUMENTATION.md) | A developer inheriting the codebase |
| [RESEARCH_DOCUMENTATION.md](RESEARCH_DOCUMENTATION.md) | A researcher evaluating or replicating the instrument |
| [DOCUMENTATION_NOTES.md](DOCUMENTATION_NOTES.md) | What could not be documented, conflicts found, open problems |

The `PHASE_*.md` reports are a historical record of the build, not a description of the current
system. Where they disagree with the code, the code is correct.

## What the instrument does

93 active items: 77 presented to each participant (71 across five domains plus a 6-item
criterion self-report block) and 16 demonstration items whose responses are never stored.
Everything is delivered as pre-recorded Bangla audio; there is no free-text keyboard entry
anywhere, so reading and spelling ability never gate a response.

**The platform scores nothing.** Since migration `0012` no response is marked correct or
incorrect for any format — `responses.is_correct` is always NULL. The only judgement stored
anywhere is a researcher's verdict on a spoken recording, and that lives on the recording,
attributed to the rater. Scoring, norming and classification are downstream analysis that this
platform deliberately does not perform.

## Privacy posture

This app handles data from minors. There are deliberately **no analytics, no telemetry, and
no third-party scripts or asset requests** of any kind. The Bangla webfont is self-hosted
(see [public/fonts/README.md](public/fonts/README.md)) rather than loaded from Google Fonts,
so no participant IP address is ever disclosed to a third party. Keep it that way.

**Participant audio is destroyed 90 days after upload** (migration `0027`). The rating, the
latency and the item linkage survive — that is why `audio_recordings` is a separate table from
`responses`. Deletion is a manual action in the admin panel's Health view and **nothing runs on
a schedule**, so it will not happen unless someone does it. Put it in the project calendar.

## Setup

```bash
npm install
cp .env.example .env        # then fill in your project URL and publishable key
npm run dev
```

`.env` is gitignored. Never put a `service_role` / secret key in it — Vite inlines every
`VITE_*` variable into the client bundle.

Dashboard steps that are **not** automatable:

1. ~~Authentication → Providers → enable Anonymous Sign-ins.~~ **Done.**
2. Pre-populate the `researchers` allowlist with your team's real emails, and create their
   accounts directly in the dashboard (Authentication → Users → Add user). Two accounts are
   present and linked.
3. **Two rater accounts are required** if you intend to report inter-rater agreement — the
   second-rating queue only shows a rater recordings someone *else* rated, and a database
   constraint refuses a second rating from the same person.

## Migrations

`supabase/migrations/` holds 27 files, applied in order. The early ones are summarised; the
recent ones matter most for anyone reading the current schema.

| File | Contents |
|---|---|
| `0001`–`0009` | Base schema, RLS, defect fixes F1–J1, atomic `submit_session()`, item versioning, automatic reliability subsampling. See the phase reports. |
| `0010_stop_binary_audio_rating.sql` | Stops a human audio rating propagating into `responses.is_correct` |
| `0011_background_consent_intros_export.sql` | Background/consent capture, domain intros, `full_export_v1` |
| `0012_stop_all_inline_scoring.sql` | **No response is scored, for any format.** `is_correct` is always NULL |
| `0013`–`0015` | New response formats, audio-rating export, scoring scope, Domain 3 typed responses |
| `0016_domain_renumber_and_content_revision.sql` | **Domain renumbering** — Short-term Memory 3→1, Rhyme/Confusion 4→3, Spelling 1→4. Older documents use the old numbers |
| `0017`–`0020` | Practice answer key for demo items, Domain 1 intros, practice items, replayability normalisation |
| `0021_audio_verdict_unclear.sql` | Tri-state audio verdict: correct / incorrect / **unclear** |
| `0022_participant_summary_view.sql` | `participant_summary_v1` — one row per participant |
| `0023_option_display_order_and_export_cleanup.sql` | `item_options.display_order`; fixes a live defect that scrambled the 3.2 and SR scales |
| `0024_retire_subdomain_intro_screens.sql` | Retires 17 subdomain intro screens via `active` (text preserved) |
| `0025_export_completeness_and_timing_integrity.sql` | Answer key + option text in the export; `client_time_origin_ms`; one consent row per participant; one correct option per item; drops `ml_export_v1`/`ml_snapshots` |
| `0026_second_rater_path.sql` | `secondary_verdict`, distinct-rater constraint, drops the misleading `agreement` column |
| `0027_audio_retention_90_days.sql` | Audio destroyed 90 days after upload |

Apply with `supabase migration up`, or paste each file into the SQL editor in order.

### Participant codes

Sessions are opened with the `start_session()` RPC, never by inserting a `sessions` row directly.
It returns a `BADSQ-XXXX-XXXX` code (alphabet excludes I/O/0/1 because it is hand-transcribed)
which the supervising teacher writes onto the paper consent form. `submit_session()` takes the
code from the session row and **ignores any code in the client payload**.

### Resume, and why the window is short

A local draft in IndexedDB lets a participant resume on the same device after a crash, a reload,
or iOS Safari evicting the page. It expires after **3 minutes of inactivity** and then starts a
fresh session silently.

That is deliberately short. The identity re-check on the resume prompt asks for class and gender,
which cannot distinguish two students in a room that is one class and one gender — the common
case here. Expiry, not the check, is what stops a device handed to the next student from offering
them the previous student's session. The cost is real: an interruption lasting more than three
minutes loses the session and forces a full restart.

## Verification

```bash
node scripts/verify-security.mjs     # real HTTP as the anon role (30 assertions)
npm run typecheck && npm run lint && npm run build
```

```
scripts/check_view_drift.sql         # standing release gate — run before every deploy
```

**`check_view_drift.sql` is current and passing.** Every view output column must resolve to a
real base column or be explicitly allowlisted; the allowlist carries 75 reviewed entries and the
gate returns zero unexplained drift. It is what stands between a future base-column rename and a
third silent recurrence of the defect that broke `ml_export_v1` and then `public_items`.

**`scripts/verify_security.sql` (v7) was rewritten on 2026-09-16** against the contracts that
actually hold. It had been failing on every run for correct reasons — it still asserted that
responses are scored inline and that a human audio rating propagates into `responses.is_correct`,
both of which migrations `0012` and `0010` deliberately removed. A suite that always fails cannot
distinguish a real regression from its own backlog.

What changed, and why it is more than flipped expectations:

- **PART 7** now proves that *nothing* is scored for *any* format, and singles out the case where
  the participant's answer **matches** the key. A matching answer coming back NULL is the actual
  proof that no scoring path survives.
- **PART 8** asserts the inverse of what it used to: a human verdict **must not** touch the
  responses row.
- **PART 5** tested `ml_export_v1`/`ml_snapshots`, dropped in `0025`. Rewritten against the views
  that carry the data.
- **PART 12's** drift-gate mirror had one allowlist entry against 75 live aliases. Regenerated.
- **PART 16** is new: 18 assertions over migrations 0021–0027 — the `security_invoker` property
  that stops the export leaking across participants, the answer key and option text resolving
  through the view, the two row-doubling constraints, the second-rater rules, retention.
- **PART 17** is new: a **teardown**. Every earlier version cleaned up only at the *start* of a
  run and left its fixtures behind, so any database that had ever run the suite permanently held
  fixture participants and responses — rows indistinguishable from real data in both CSV exports.
  This README previously claimed it "tears down cleanly". It did not. It does now, and asserts it.

It also fixed a **destructive** line in PART 1: the cleanup did
`delete from consent_records where assigned_code like 'BADSQ-%'`. Every real participant code
starts with `BADSQ-`, so running the suite against a live database would have silently deleted
every real consent record.

**Verified state, 2026-09-16:** PARTS 1–8, 16 and 17 were executed against the live database —
**66 assertions, 66 passed, 0 failed** — and the teardown was confirmed to leave zero fixture
rows. PARTS 9–15 (storage, consent linkage, Unicode, hardening, migrations 0006–0008) are
unchanged v6 code apart from PART 12's regenerated allowlist and **were not re-executed in that
session**; run the file end to end in the SQL editor to confirm all 107. Record the result here
when you do — and do not carry an assertion count forward from an older report, which is how the
previous "84 assertions, 84 passed" claim outlived its truth.

## Deployment

Static SPA, zero server-side config — routing is hash-based (`#/admin`, `#/test`), so there is no
history-API rewrite rule to set up.

1. Import the repo into Vercel or Netlify. Framework preset: Vite. Build: `npm run build`.
   Output: `dist`.
2. In the platform dashboard (never in a committed file), set `VITE_SUPABASE_URL`,
   `VITE_SUPABASE_PUBLISHABLE_KEY`, and optionally `VITE_SUPABASE_AUDIO_BUCKET`.
3. `vercel.json` / `netlify.toml` set response headers appropriate to an app collecting data from
   minors: `X-Frame-Options: DENY`, `X-Content-Type-Options: nosniff`,
   `Referrer-Policy: no-referrer`, a `Permissions-Policy` allowing the microphone only for this
   origin, and HSTS.
4. **Microphone access requires HTTPS** (or `localhost`). Both platforms serve HTTPS by default.

## Data export

Two CSVs from the admin panel's Health view, over the same data at different grains:

- **Full export** — one row per response. Self-sufficient for analysis: participant background,
  consent answers, item metadata, the response, **the answer key** (`correct_answer` for typed
  and spoken items, `correct_option_key`/`correct_option_text` for choice formats), the option
  text the participant actually saw, both human audio verdicts, both latency anchors, and device
  context. Audio links in it expire after 30 days.
- **Participant summary** — one row per participant, wide. Demographics, session duration, audio
  verdict tallies, per-subdomain aggregates, and then every item's answer, option text, verdict
  and latency on that participant's own row, for visualisation.

Timing note for analysis: `*_client_ts` values come from `performance.now()`, which restarts at
zero on every page load. Add `client_time_origin_ms` to get absolute time. A change of that value
within one session means the participant reloaded.

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
  lib/supabaseClient.ts        Supabase client, anonymous + researcher password auth
  lib/itemBank.ts              Item bank access: versioning via save_item_version() RPC
  lib/itemValidation.ts        Pure activation-guard logic (no I/O)
  lib/media.ts                 Audio storage helpers: signed URLs, uploads, MIME detection
  lib/localDraft.ts            IndexedDB resume draft, staleness, singleton key
  lib/errors.ts                Error-message extraction (Supabase returns plain objects, not Errors)
  lib/adminData.ts             Admin data access: rating, participants, health, retention, exports
  components/TestRunner.tsx    Participant flow: intake, sequencing, audio gating, submit, resume
  components/testrunner.css    Plain CSS for the participant flow — no component library
  components/responses/        The eight response formats
  admin/AuthGate.tsx           Email + password sign-in + allowlist resolution
  admin/AdminShell.tsx         Identity banner, sign out, nav
  admin/ItemBankEditor.tsx     List/filter/create/edit/soft-delete, versioning, audio upload
  admin/RatingQueue.tsx        Audio rating, plus the blind second-rating pass
  admin/RecordingCard.tsx      One recording, in normal or blind mode
  admin/ParticipantsView.tsx   Participant roster and their recordings
  admin/HealthView.tsx         Operational counts, audio retention, CSV exports
  types/database.types.ts      Generated from the live schema — regenerate, never hand-edit
scripts/                       Verification suites, the view-drift gate, participant-data reset
supabase/migrations/           0001 … 0027
```
