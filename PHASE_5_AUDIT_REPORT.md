# Phase 5 Audit Report — BADSQ Platform

## 1. Scope

Independent second-reviewer verification and completion audit of the BADSQ (Bangla Adolescent Dyslexia Screening Questionnaire) platform. The brief required:

1. **Reading & Reviewing Full History**: Inspect migrations 0001–0008, `PHASE_0_REPORT.md` through `PHASE_4_REPORT.md`, `README.md`, and all security verification scripts before making changes.
2. **Re-deriving & Re-running Verification Suites**: Independently execute the HTTP security suite (`verify-security.mjs`), the standing view column drift release gate (`check_view_drift.sql`), and the full SQL security suite (`verify_security.sql`) against the live Supabase instance.
3. **Adversarial Pass & Secret Scan**: Perform a comprehensive, full-patch git history secret scan (`git log -p`) across all commits, re-probe advisors, and investigate potential schema/policy blind spots.
4. **Live Verification of Previously Untested Paths**: Live browser-driven execution of:
   - Path A: The same-device resume-after-interruption prompt, draft persistence in IndexedDB, and clean reset on "No, new student".
   - Path B: Stimulus replay, dual latency anchor calculation (`stimulus_first_end_client_ts`, `stimulus_last_end_client_ts`, `response_latency_from_first_ms`, `response_latency_from_last_ms`), and submission into `responses`/`ml_export_v1`.
5. **Fix Unambiguous Defect J1**: Author and apply migration `0009_j1_fix.sql` adding `set search_path = public` to `reliability_subsample_rate()`, restoring search_path hygiene across all public functions.
6. **Deployment & Tooling Readiness Check**: Validate production bundle build, typecheck, linting, and document exact deployment status.
7. **Document Findings & Open Questions**: Produce this report adhering to the standard 10-section structure.

---

## 2. Completed

- [x] **Full-History Git Secret Scan Completed** — Scanned all 15 commits across git history (`git log -p`); **0 committed secrets or `.env` files found** (§4.3).
- [x] **Design Documents Verified** — Confirmed that `BADSQ_Question_Paper.md`, `BADSQ_Instrument_Development_Report.md`, and `BADSQ_Parental_Consent.md` are **not committed to the repository** (§3, §9).
- [x] **HTTP Security Suite Re-derived & Passed** — `node scripts/verify-security.mjs` executed against live project; **30 / 30 assertions passed** (§4.1).
- [x] **View Drift Release Gate Re-derived & Passed** — `scripts/check_view_drift.sql` executed; **0 DRIFT rows, 1 ALLOWLISTED alias (`ml_export_v1.response_id`)** (§4.1).
- [x] **Discrepancy in Prior Reporting Discovered** — Discovered that `PHASE_4_REPORT.md` reported partial execution (only 7 assertions across Parts 1, 7, and 15) while claiming in `README.md` that all 84 had passed. Running the full suite immediately caught J1 via PART 12's assertion 61 (§4.2, §6.1).
- [x] **Defect J1 Fixed via Migration 0009** — Applied `supabase/migrations/0009_j1_fix.sql`; `reliability_subsample_rate()` now has `set search_path = public` (§6.2).
- [x] **Full SQL Security Suite Re-run Post-0009** — `scripts/verify_security.sql` executed in full across all 15 parts; **84 / 84 assertions passed, 0 failed** (§4.2).
- [x] **Database Advisors Re-probed** — `function_search_path_mutable` warning cleared; 2 intentional `security_definer_view` ERRORs and standard anon access WARNs confirmed (§4.4).
- [x] **Live Testing of Same-Device Resume Flow** — Driven via Edge Chromium (Playwright). Interruption, IndexedDB draft restoration, "Yes, continue", and "No, new student" reset verified live (§4.5).
- [x] **Live Testing of Stimulus Replay & Dual Latency Anchors** — Real browser execution verified that stimulus replay updates $T_2$, computes distinct $T_1$/$T_2$ anchors, and writes correct latency values to `responses` and `ml_export_v1` (§4.6).
- [x] **Production Build, Typecheck, and Linting Verified** — `npm run build`, `npm run typecheck`, and `npm run lint` all pass cleanly with 0 errors and 5 accepted lint warnings (§4.7).
- [x] **Database Fixtures Torn Down** — All test participants, responses, sessions, items, and storage objects removed; tables confirmed clean (§4.8).

---

## 3. Not completed / deferred

- [ ] **Missing Research Design Documents**: `BADSQ_Question_Paper.md`, `BADSQ_Instrument_Development_Report.md`, and `BADSQ_Parental_Consent.md` remain uncommitted. As instructed, no assumptions were made about their content, and they are formally requested from the researcher (§9.1).
- [ ] **Cloud Static Hosting Deployment**: Neither Vercel CLI nor Netlify CLI has an authenticated token in this local development environment. Deployment is fully prepared (static bundle in `dist/`, hash routing, `.env.example`), awaiting platform import by the researcher (§4.7, §9.2).
- [ ] **Physical iOS / Android Audio Hardware Testing**: The client audio pipeline was tested in Chromium with simulated media devices. Testing on real physical iOS Safari (MP4/AAC) and Android Chrome (WebM/Opus) hardware remains deferred to the researcher during field deployment (§4.6, §9.3).
- [ ] **Leaked Password Protection in Supabase Dashboard**: Remains disabled in dashboard settings (dashboard-only toggle, unchanged since Phase 3; §4.4).

---

## 4. Verification Results

### 4.1 HTTP Security Suite & View Drift Gate

```
node scripts/verify-security.mjs
```
- **Result**: **30 assertions run, 30 passed, 0 failed.**
- Verified: `anon` role is rejected on direct access to `items.correct_answer` (401), `item_options.is_correct` (401), `ml_export_v1` (401), `ml_snapshots` (401), direct `sessions` INSERT (401), direct `start_session()` without JWT (400), and `save_item_version()` (401).
- Verified: Public read paths `public_items` (200) and `public_item_options` (200) return without exposing answer keys.

```sql
scripts/check_view_drift.sql
```
- **Result**: **0 DRIFT rows, 1 ALLOWLISTED alias (`ml_export_v1.response_id`).**
- Release gate self-test verified catching deliberate column drift.

---

### 4.2 Full SQL Security Suite (`scripts/verify_security.sql`)

Executed across all 15 parts against the live Supabase database (`gfxdhqkxetuoetzzrxxq.supabase.co`):

| Section | Total Assertions | Passed | Failed |
|---|:---:|:---:|:---:|
| `answer_keys` | 9 | 9 | 0 |
| `consent` | 4 | 4 | 0 |
| `export` | 4 | 4 | 0 |
| `h1_fix` | 2 | 2 | 0 |
| `hardening` | 5 | 5 | 0 |
| `i1_fix` | 5 | 5 | 0 |
| `item_audio` | 2 | 2 | 0 |
| `item_bank` | 3 | 3 | 0 |
| `participants` | 2 | 2 | 0 |
| `rating_trigger` | 2 | 2 | 0 |
| `reliability_subsample` | 2 | 2 | 0 |
| `save_item_version` | 6 | 6 | 0 |
| `sessions` | 6 | 6 | 0 |
| `sessions_policy` | 2 | 2 | 0 |
| `start_session` | 5 | 5 | 0 |
| `storage` | 4 | 4 | 0 |
| `submit` | 16 | 16 | 0 |
| `unicode` | 2 | 2 | 0 |
| `view_drift_gate` | 3 | 3 | 0 |
| **TOTAL** | **84** | **84** | **0** |

*Note on Assertion 61 (G3 search_path)*: Prior to applying migration 0009, Assertion 61 failed because `reliability_subsample_rate()` lacked `search_path=public`. Post-0009, Assertion 61 passes with 0 unpinned functions.

---

### 4.3 Git History Secret Scan

Executed full-history patch scan (`git log -p`) across all 15 commits:
- Regex checks for:
  - Supabase Service Role Keys (`eyJ...`)
  - Supabase Personal Access Tokens (`sbp_...`)
  - Database Passwords & Connection URIs
  - Private Keys (`BEGIN PRIVATE KEY`)
- **Outcome**: **0 secrets found in git history.**
- Only `.env.example` placeholder strings and documentation references were present. No `.env` file was ever committed.

---

### 4.4 Database Advisors (Post-0009)

1. **Security Advisor**:
   - `security_definer_view` (2 ERROR): On `public_items` and `public_item_options`. Documented, intentional design allowing anonymous students to read active items while withholding answer keys.
   - `function_search_path_mutable` (0 WARN): Cleared by migration 0009.
   - `auth_leaked_password_protection` (1 WARN): Dashboard policy setting.
   - `anon_security_definer_function_executable` & `authenticated_security_definer_function_executable` (12 WARN): Intended RPC functions (`start_session`, `submit_session`, `is_researcher`, etc.).
2. **Performance Advisor**:
   - 9 INFO: Unindexed foreign keys on low-cardinality research tables.
   - 5 WARN: `multiple_permissive_policies` on `item_options` (due to `item_options_write_manager` using `FOR ALL`).

---

### 4.5 Live Verification: Same-Device Resume Flow (Path A)

Driven via Edge Chromium browser automation:
1. **Intake**: Grade 7 selected; session `4e9aef84-88c9-4f41-a6ef-4bcfe2e4acfb` opened with assigned code `BADSQ-ULB3-ZAH2`.
2. **Item 1 (MCQ_TAP)**: Option A clicked; advanced to Item 2.
3. **Item 2 (NUMERIC_KEYPAD)**: Keypad digits `4` and `2` typed.
4. **Draft Inspection**: IndexedDB store `'badsq-draft'` verified containing active responses and `currentItemIndex = 1`.
5. **Simulated Interruption**: Browser page reloaded.
6. **Resume Confirmation Screen**: Screen displayed Bangla text: *"আপনি কি চালিয়ে যেতে চান? মনে হচ্ছে একটি অসম্পূর্ণ সেশন আছে..."* with buttons *"হ্যাঁ, চালিয়ে যাব"* and *"না, নতুন শিক্ষার্থী"*.
7. **Option A Tested ("হ্যাঁ, চালিয়ে যাব")**: State restored to Item 2 (`2 / 3`), keypad input `42` intact, and allowed advancing to Item 3 (`3 / 3`).
8. **Option B Tested ("না, নতুন শিক্ষার্থী")**: On second reload, clicking *"না, নতুন শিক্ষার্থী"* completely cleared the IndexedDB draft and returned to a clean Intake screen with grade selection buttons.

---

### 4.6 Live Verification: Stimulus Replay & Dual Latency Anchors (Path B)

1. **Setup**: Item `FX.MCQ1` configured with `is_stimulus_replayable = true`, instruction audio, and stimulus audio.
2. **Playback & Replay Sequence**:
   - Initial playback finished at $T_1 = 1616.1$ ms (`stimulusFirstEndClientTs = 1616.1`, `stimulusLastEndClientTs = 1616.1`).
   - Stimulus replay button *"🔊 আবার শুনুন"* clicked.
   - Replay finished at $T_2 = 2539.9$ ms (`stimulusLastEndClientTs = 2539.9`, `stimulusFirstEndClientTs` preserved as $1616.1$).
   - Response option selected at $T_{\text{click}} = 2949.2$ ms.
3. **Calculated Latencies**:
   - `response_latency_from_first_ms` $= 2949.2 - 1616.1 = 1333.1$ ms
   - `response_latency_from_last_ms` $= 2949.2 - 2539.9 = 409.3$ ms
4. **Database Submission & Export Verification**:
   - `submit_session()` succeeded, returning assigned code `BADSQ-8URW-UUV5`.
   - Querying `responses` and `ml_export_v1` confirmed exact persistence of both latency anchors and audio recording metadata.

---

### 4.7 Production Build & Code Quality

- `npm run build`: Output written to `dist/` (HTML: 1.99 kB, CSS: 9.84 kB, JS: 455.01 kB) in 208ms.
- `npm run typecheck`: TypeScript compilation passed with 0 errors.
- `npm run lint`: oxlint passed with 0 errors (5 accepted warnings for synchronous `setState` in external effect synchronization).

---

### 4.8 Fixture Teardown

All test data (`FX.%` items, sessions, responses, audio recordings, and anonymous auth users) were removed in dependency order. Final table counts confirmed:
- `items`: 0
- `item_options`: 0
- `sessions`: 0
- `participants`: 0
- `responses`: 0
- `audio_recordings`: 0
- `consent_records`: 0
- `researchers`: 1 (`arianthehunter@gmail.com`)

---

## 5. Deviations from the Brief

None. All directives in the audit brief were executed exactly as specified.

---

## 6. Problems, Errors, and Blockers

### 6.1 Discrepancy in Phase 4 Verification Reporting

- **Discovery**: In `PHASE_4_REPORT.md` §4.5, Claude reported running only Parts 1, 7, and 15 of `scripts/verify_security.sql`, but stated in `README.md` that all 84 assertions had passed.
- **Impact**: Because Part 12 was omitted during Phase 4's re-run, the failure of Assertion 61 (`"G3 FIX: ALL public functions have a pinned search_path"`) caused by defect J1 was obscured.
- **Resolution**: Identified during our full independent suite run; resolved by Migration 0009 and verified across all 15 parts.

### 6.2 Defect J1: `reliability_subsample_rate()` Missing `search_path`

- **Symptom**: Postgres security advisor flagged `function_search_path_mutable` on `reliability_subsample_rate()`; SQL suite Assertion 61 failed.
- **Root Cause**: Migration `0008_reliability_subsample.sql` defined the function without `set search_path = public`.
- **Fix**: Migration `0009_j1_fix.sql` added `set search_path = public`.

---

## 7. Decisions Made Beyond This Brief

1. **Edge Chromium Automation via Playwright-Core**: Used the local Edge Chromium installation with `playwright-core` in a temporary test driver to exercise live browser flows without downloading external browser binaries or bloating the project dependencies.
2. **Audio Element DOM Attachment**: Identified that headless audio elements (`<audio>` without `controls`) require `{ state: 'attached' }` rather than `{ state: 'visible' }` in Playwright automation.

---

## 8. Files Created / Modified

- `supabase/migrations/0009_j1_fix.sql` — [NEW] Adds pinned `search_path = public` to `reliability_subsample_rate()`.
- `README.md` — [MODIFY] Updated migration log table, Phase 5 status, and accurate 84/84 verification results.
- `PHASE_5_AUDIT_REPORT.md` — [NEW] This report.

---

## 9. Open Questions for the Researcher

1. **Design Documents**: Please provide `BADSQ_Question_Paper.md`, `BADSQ_Instrument_Development_Report.md`, and `BADSQ_Parental_Consent.md` if any subsequent phase requires validation against the psychometric specification.
2. **Static Hosting Deployment**: Please import the repository into Vercel or Netlify and supply the environment variables (`VITE_SUPABASE_URL`, `VITE_SUPABASE_PUBLISHABLE_KEY`, `VITE_SUPABASE_AUDIO_BUCKET`).
3. **Physical Device Testing**: Once deployed, please run a live screening session on a physical iPhone (Safari) and Android device (Chrome) to test real microphone hardware and iOS MP4/AAC recording.
4. **Leaked Password Protection**: Consider enabling *Leaked Password Protection* in the Supabase Dashboard under Authentication -> Policies.

---

## 10. State of the Repo

- **Branch**: `main`
- **Working Tree**: Clean
- **Migrations**: 0001 through 0009 applied and verified
- **Test Suites**:
  - `verify-security.mjs`: 30/30 passed
  - `check_view_drift.sql`: 0 drift rows
  - `verify_security.sql`: 84/84 passed
- **Build / Lint**: Passing with 0 errors
