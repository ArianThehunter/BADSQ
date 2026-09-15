# Documentation Notes

Written alongside `TECHNICAL_DOCUMENTATION.md` and `RESEARCH_DOCUMENTATION.md`, 2026-09-15.

This is the honest margin of the documentation set: what could not be documented, where the code
and the design documents disagree, every place a rationale was recorded as absent rather than
invented, and the things found while writing that look like real problems.

---

## 0. Status update — 2026-09-16

This file was written on 2026-09-15. A three-device pilot (Android/Chrome, iPhone/Safari,
Windows/Edge) and a review of the two exported CSVs closed most of §4 and **corrected one finding
that was simply wrong**. Current status of everything recorded below:

| § | Finding | Status |
|---|---|---|
| 4.1 | Consent records have no uniqueness constraint; a second row silently doubles every response row in both exports | **Closed** — partial unique index (0025). The same hazard existed on the new answer-key join and is constrained too |
| 4.2 | `verify_security.sql` asserts the pre-0010/0012 contracts | **Still open.** Needs rewriting; it fails for correct reasons, which is the worst state for a suite |
| 4.3 | View-drift gate reports 72 failures and is effectively off | **Closed** — allowlist regenerated to 75 reviewed entries; zero unexplained drift |
| 4.4 | Cohen's kappa cannot be computed; no second-rater interface | **Closed** — blind second-rating pass (0026), distinct-rater CHECK, both verdicts in the export |
| 4.5 | Audio-deletion commitment has no implementation | **Closed** — 90-day retention implemented (0027), deletion performed from HealthView through the Storage API. Manual by design; nothing runs on a schedule |
| 4.6 | 29 items with determinate answers have no answer key | **WRONG — retracted.** See below |
| 4.7 | Contaminated pilot data in 3.2 and SR (option-order defect) | **Moot** — all pilot data deleted before real collection |
| 4.8 | 29 stuck sessions, 3 orphaned audio objects, `.env.example` | Sessions and objects cleared. The `.env.example` claim was also wrong and was retracted on 2026-09-15 — it holds proper placeholders |
| 4.9 | `maxAudioPlays()` domain hardcoding; intentional SECURITY DEFINER views; fixed item order | Unchanged, all still true |

### Retraction of §4.6

The claim that 29 items with determinate answers had no recorded answer key was **incorrect**. It
came from checking only `items.correct_answer` and missing that the choice formats (2.2, 2.5, 3.1,
4.1, 4.2) store their key in `item_options.is_correct`. Every item with a determinate answer has
always had one; only 3.2 and the SR block have none, which is correct because they are self-report.

What was genuinely missing — and what made the original observation *feel* right — is that
**neither key reached the export**, so the CSV could not be scored without going back to the
database. That is fixed in 0025, which adds `correct_answer`, `correct_option_key`,
`correct_option_text` and `selected_option_text`.

### Found since, and fixed

- **`performance.now()` restarts on page reload**, so a participant who resumed carried smaller
  timestamps in the second half of their session than the first. Visible in the pilot: one
  participant ran 1455 wall-clock seconds with a maximum `response_client_ts` of 750 s. Latencies
  were unaffected but any elapsed-time derivation broke silently. `client_time_origin_ms` added.
- **A stimulus anchor could move after the answer**, producing a −1665 ms latency on recomputation
  in one pilot row. Anchors now freeze once answered.
- **`selection_change_count` was a phantom column** — present since 0007, never written, exported
  as a constant 0 on every response ever collected. Now actually counted.
- **`ml_export_v1` / `ml_snapshots`** dropped as dead, superseded schema.

---

## 1. What could not be documented, and why

### 1.1 The Development Report is missing — this is the largest gap

`BADSQ_Technical_Design_Draft_v1.md` defers its entire research substance to a document it calls
the **Development Report**, citing it by section number five times (§3.2, §3.6, §10.1–10.2,
§10.3, §10.4). **That document is not in this repository.** It is not among the tracked files and
no copy exists anywhere in the working tree.

Everything below therefore has no documented basis and was left blank rather than filled in:

| Deferred to | What is missing |
|---|---|
| §3.2 | Why free-text keyboard entry was ruled out (the "keyboard-confound rationale") |
| §3.6 | The z-scoring-by-device-cohort method, and the device-type confound analysis |
| §10.1–10.2 | The definition of the criterion groups — i.e. the actual classification rule |
| §10.3 | The 10th-percentile domain-threshold rule |
| §10.4 | The two-or-more-domain flagging rule and its false-positive rate |

Also undocumentable as a result: the derivation of the five-factor model, the provenance of each
subdomain's task, the literature behind the criterion, the mapping of the 46/17/15/14/8 % weights
onto specific domains, the Bangla translation and cultural-adaptation methodology, and ethics
approval status.

`RESEARCH_DOCUMENTATION.md` §2 is marked **INCOMPLETE** for this reason and states what a
replicating researcher must be given. It should not be treated as finished.

### 1.2 Things that cannot be documented because they do not exist yet

- **The classification rule.** `criterion_classification` is an empty table with suggestive column
  names (`item5_score`, `items6_10_sum`, `strong_count`, `weak_count`). No code writes to it. The
  mapping between those column names and the current SR.1–SR.6 item codes is not recorded
  anywhere, and given the domain renumbering it would be unsafe to guess.
- **The analysis pipeline.** `domain_score_results` is likewise empty and unwritten. No scoring,
  norming, thresholding or modelling code exists in the repository.
- **Real-device behaviour.** No iPhone, no Android phone, no real microphone has ever been used
  in any recorded test. Every claim about audio capture rests on headless Chromium with fake media
  devices. This is stated as such in both documents rather than described as "tested".
- **Session duration for real participants.** Only 7 completed sessions exist, all development or
  pilot runs, with a range of 1–90 minutes. Reported as an observation, explicitly not as an
  estimate.

### 1.3 Things deliberately not verified

- The Tamboer citations, the 46/17/15/14/8 % weights, and the 33/256/206-of-495 classification
  figures are reproduced as the design draft states them, **attributed to the draft**, and were
  not checked against the original sources. No citation was reconstructed from memory.
- The claim that the domain 1 single-presentation rule is "standard span-task methodology" appears
  in the design draft; it is reported as the project's stated reason, not asserted independently.

---

## 2. Where the code and the design documents conflict

In every case the code was documented as the truth, with the divergence noted.

| # | Design draft says | Live system does | Consequence |
|---|---|---|---|
| 1 | Domains numbered with Spelling as 1, Short-term Memory as 3, Rhyme/Confusion as 4 | Migration `0016` rotated them: Short-term Memory 1, Rhyme/Confusion 3, Spelling 4 | **The entire design draft's domain prose is stale.** Anyone reading it will attribute findings to the wrong domain. |
| 2 | Six response formats | Eight: `MCQ_TAP`, `BINARY_TAP`, `TRI_TAP`, `NUMERIC_KEYPAD`, `LIKERT_5`, `AUDIO_RECORD`, plus `LETTER_SPAN` and `FLASH_JUDGMENT` | Draft's format table is incomplete |
| 3 | `instruction_audio_url` / `stimulus_audio_url` | `instruction_audio_path` / `stimulus_audio_path` — storage paths, not URLs | Access is via short-lived signed links, not stored URLs |
| 4 | `responses.participant_id` denormalized | No such column; responses reach the participant via `session_id` | Any query written against the draft schema fails |
| 5 | `responses.audio_recording_id` FK to the recording | Reversed: `audio_recordings.response_id` | The circular FK in the draft was removed as defect F-series work |
| 6 | A single latency anchor (`stimulus_end_client_ts`) | Dual anchors and two derived latencies | Documented as an improvement, in `RESEARCH_DOCUMENTATION.md` §4.2 |
| 7 | A separate `raters` table with pseudonymous labels | One unified `researchers` allowlist with role flags | Raters are identified by researcher row, not by a pseudonym |
| 8 | Magic-link authentication for researchers | Email + password (Phase 3 replacement) | Draft's auth section is obsolete |
| 9 | Responses written immediately, "so an interrupted session doesn't lose data" | Nothing is written until a single atomic submit | The draft contradicts *itself* here — §5c describes the submit-all-at-once model the system actually implements. The inline comment in the schema block was never updated. |
| 10 | Inline scoring produces `is_correct` | Nothing is scored, for any format (migration `0012`) | Both `is_correct` and `scored_by` are always NULL |
| 11 | A human rating propagates into `responses.is_correct` | The propagation trigger was deliberately made a no-op (migration `0010`) | The rater's verdict lives only on the recording |
| 12 | `is_stimulus_replayable` for domains 2 and 5 "undecided" | Decided and set; domain 1 (then 3) is single-presentation, others replayable up to 3 | Open decision #1 in the draft is closed |
| 13 | Storage estimate assumes ~20 audio items/student | 17 audio items | Minor; capacity conclusion unchanged |

`README.md` is also stale in its own right: it states "Current phase: 4" and documents **nine**
migrations when **twenty-four** exist. Its verification section reports "84 assertions, 84
passed", which is no longer achievable (see §4.2 below).

---

## 3. Every place "rationale not documented" was written

Collected here so the researcher can decide which are worth recording properly. None of these
were filled in with a plausible-sounding invention.

**In `TECHNICAL_DOCUMENTATION.md`:**

1. Why Vite was chosen as the build tool.
2. Why React was chosen as the UI framework.
3. Why Supabase was chosen as the backend.
4. Why oxlint was chosen over ESLint.
5. Why no component library is used (the decision is visible in the code; the reason is not
   recorded).
6. Why the screening code is shown at the completion screen rather than at session start.

**In `RESEARCH_DOCUMENTATION.md`:**

7. The item-count imbalance across subdomains — 1 item in 2.6, 2 in 2.3, 8 in three subdomains,
   10 in 4.1. Deliberate weighting or simply where item writing stopped is not recorded.
8. Why the criterion block has no demonstration item.
9. The empirical basis for the **1500 ms** flash exposure in subdomain 4.2 (the value was set by
   instruction during development; the earlier value was 2000 ms, also unexplained).
10. Which of the 46/17/15/14/8 % weights belongs to which domain.
11. How SR.1–SR.6 map onto the source instrument's items.
12. The mapping between `criterion_classification`'s column names and the current SR item codes.
13. Target or expected session duration.

Two further rationales were **found and are documented**, so they are listed here only to be
clear they are not gaps: the reason Domain 1 is single-presentation (span-task validity) and the
reason the reliability subsample is assigned randomly at submission rather than chosen by a rater
(Cohen's kappa validity). Both are recorded in the phase reports.

---

## 4. Things found while writing that look like real problems

Ordered roughly by how much they should worry the researcher.

### 4.1 The consent-record duplication hazard — data integrity, live

**[verified]** Q1/Q2/Q3 are asked on screen to the *child*, who is told to enter what their
parent marked on the paper form. Those answers are written straight into `consent_records` at
submission, leaving `digitized_at` / `digitized_by` / `paper_form_scan_ref` empty.

There is **no uniqueness constraint on `consent_records.participant_id`**. If a researcher later
transcribes the paper form properly, that creates a *second* row for the same participant. Both
export views (`full_export_v1` and `participant_summary_v1`) join responses to consent records
with a plain `LEFT JOIN`, so **a second consent row silently doubles every response row for that
participant in the export** — and in `participant_summary_v1`, doubles every aggregate.

This would be easy to miss: the export would simply report twice as many responses for one
participant, with no error anywhere.

There is also no field recording whether a consent row came from the child or from a researcher,
so the two cannot be distinguished after the fact except by inferring from `digitized_at` being
NULL.

Currently 5 consent rows for 7 participants — so the path is already partially covered, not
broken, but not consistently exercised either.

### 4.2 The verification suite is stale and now asserts the opposite of the intended behaviour

`scripts/verify_security.sql` (1,436 lines, 15 parts) was written against pre-`0010` behaviour.
Part 8 still asserts:

> rating by allowlisted rater propagates to responses — `is_correct=true, scored_by=human`

That propagation was **deliberately removed** by migration `0010`. The assertion must now fail,
and it fails for a *correct* reason. Part 7's inline-scoring assertions are in the same position
after migration `0012`.

This is the worst state for a test suite: a run produces failures, the failures are expected, and
so a *real* failure among them would be indistinguishable. The README's claim of "84 assertions,
84 passed" is no longer reproducible.

### 4.3 The view-drift release gate reports 72 failures and is effectively switched off

`scripts/check_view_drift.sql` is the standing release gate built specifically because the
export-view column-drift defect had already recurred twice (`ml_export_v1` in 0003, then
`public_items` in 0004). It resolves every view's output columns back to a real base column via
`pg_depend` and flags anything that does not resolve unless allowlisted.

Its allowlist contains **one** entry. A live run returns **72 DRIFT rows**:
`participant_summary_v1` 63, `full_export_v1` 8, `public_items` 1. All 72 appear to be legitimate
deliberate aliases introduced by migrations 0011, 0017 and 0022 and never added to the allowlist.

The gate is therefore failing wholesale, which means **it can no longer distinguish a real
column-drift regression from its own backlog** — the exact defect class it was built to prevent.
Fixing it is mechanical: add the 72 aliases to the allowlist with reasons.

### 4.4 Cohen's kappa cannot currently be computed

The reliability subsample is being assigned correctly — randomly, automatically, at 20 %, at
submission time, before any rater has listened. The database has `secondary_rating`,
`secondary_rater_id`, `secondary_rated_at` and a generated `agreement` column.

**But there is no second-rater interface.** `RatingQueue.tsx` and `RecordingCard.tsx` write only
the primary rating; the string `secondary_rating` appears nowhere in `src/` except the generated
type definitions. The sampling half of the design is finished and the collection half was never
built. As things stand the double-rating flags accumulate and no second ratings are collected.

### 4.5 The audio-retention commitment has no implementation

The schema's own comment says `audio_recordings` is separated from `responses` "so a recording
can be deleted post-study (per the parental consent commitment) while the derived `is_correct`
score persists." The table carries `scheduled_deletion_at` and `deleted_at` for exactly that.

**Neither column is ever written by any code.** There is no deletion job, no admin control, no
documented procedure. Meanwhile the retention policy was changed during development to indefinite
retention, and the 90-day expiry on signed audio links was removed.

Whichever policy is correct, the consent form parents sign and the system's actual behaviour must
match. Right now the schema encodes one policy, the operational decision is the opposite, and
neither is implemented.

### 4.6 29 items with a determinate right answer have no answer key

Subdomains **2.5** (3 items), **3.1** (8), **4.1** (10) and **4.2** (8) have a correct answer in
the source question paper and **no `correct_answer` recorded in the item bank**. Because nothing
is machine-scored this causes no runtime problem — but it means those 29 items cannot be scored
from the database or from the export at all, without going back to the paper.

Compounding it: **the answer key is not in `full_export_v1`.** Adding it was identified as a
worthwhile small change during development and was never done. And for subdomains 2.5 and 4.1 the
option keys are bare `A`–`D`, and option *text* is not exported either — so those 13 items'
responses are uninterpretable from the CSV alone.

### 4.7 Contaminated pilot data in subdomain 3.2 and the SR block

Before migration `0023`, option display order was derived from the option key by string sort.
When migration `0014` replaced `A`/`B`/`C`/`D` keys with English semantic tokens, the sort order
became meaningless: the 5-point Likert scale in 3.2 rendered as
always → frequently → hardly → never → sometimes, and the SR tri-state scale was similarly
scrambled.

The defect is fixed. **The responses collected while it was live are not recoverable** — the
child selected a position on a scale whose order was wrong, and there is no way to reconstruct
intent. Any 3.2 or SR data from before `0023` must be discarded.

### 4.8 Operational debris

- **29 sessions stuck in `in_progress`**, some open 400+ hours. Harmless (they hold no responses)
  but they make completion-rate queries wrong if read naively, and they will accumulate.
- **3 orphaned audio objects** in the `badsq-audio` bucket with no `audio_recordings` row
  pointing at them (**[verified]** by query against `storage.objects`). Almost certainly failed
  or abandoned uploads from development. Harmless, but they are children's voice recordings
  sitting outside the record-keeping that governs the rest, and they should be cleared.

### 4.9 Structural fragility worth knowing about

- **`maxAudioPlays()` hardcodes `item.domain === '1'`** to apply the single-presentation rule.
  Migration `0016`'s own header warns that this must change in the same deploy as any renumbering
  or the rule silently attaches to the wrong domain. It is a *methodological* rule enforced in
  application code rather than as an item-bank property. A renumbering would not fail loudly; it
  would quietly invalidate Domain 1's measurement.
- **Two Supabase linter ERRORs on `public_items` / `public_item_options` are intentional** —
  those views are `SECURITY DEFINER` specifically to hide answer keys from participants. They must
  not be "fixed". Conversely, `security_invoker = true` on `full_export_v1` and
  `participant_summary_v1` is load-bearing: without it those views would run as their creator and
  leak every participant's data to any authenticated session, including a participant's own
  anonymous session. Both facts are documented in `TECHNICAL_DOCUMENTATION.md` §3.2.
- **Item order is fixed and never counterbalanced**, by deliberate instruction (to keep order out
  of downstream models). The cost — fatigue perfectly confounded with domain, with the criterion
  block last — is documented in `RESEARCH_DOCUMENTATION.md` §9.6 but has not been discussed
  anywhere in the repository.

---

## 5. Two places where I would want the researcher's judgement

1. **Whether Q1–Q3 should be collected from the child at all** (§4.1). The methodological
   intention — parent answers history, child answers experience — is sound, and the
   implementation quietly collapses it. This is a research-design question, not a bug to fix
   unilaterally.

2. **Which retention policy is real** (§4.5). The consent form is the binding document and it is
   not in this repository. Everything downstream — whether to build deletion, what to tell an
   ethics board, how long signed links should live — follows from it.
