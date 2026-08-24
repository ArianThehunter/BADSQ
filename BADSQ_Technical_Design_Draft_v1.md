# BADSQ Platform — Technical Design Draft v1

**Status: draft for discussion, not final.** This is a starting point to react to and edit together, not a locked schema.

---

## 1. Open design decisions to resolve first

These affect columns below, so worth settling before implementation starts:

1. **Stimulus replayability per item type.** Instructions/demos: always replayable (Design Principle 1). Domain 3 span/non-word-recall stimuli: must be single-presentation (standard span-task methodology — replay would invalidate the measure). Domains 2 and 5 stimuli (Elision, Blending, Pseudoword Judgment, Spoonerisms, Jumbled-reading): undecided — replay could let repeated exposure substitute for genuine processing.
2. **What "typed" answers refers to.** If it's digit entry via the on-screen NUMERIC_KEYPAD (Domain 3), no conflict with Section 3.2's keyboard-confound rationale. If it's free-text Bangla script entry, that reopens a decision the Development Report made deliberately — confirm before building the input component.

The schema below has columns to hold either resolution without redesign.

---

## 2. Latency measurement — reference implementation

**Clock:** `performance.now()` for all interval math (monotonic, sub-ms, immune to clock adjustments). `Date.now()` / server timestamps only for wall-clock record-keeping (session start/end), never for RT calculation.

**Anchor points, by response format:**

| Response format | t0 (stimulus end) | t1 (response) |
|---|---|---|
| MCQ_TAP / BINARY_TAP / TRI_TAP | instruction/stimulus audio `ended` event | first `pointerdown` on an option |
| NUMERIC_KEYPAD | instruction/stimulus audio `ended` event | first `pointerdown` on a keypad digit |
| LIKERT_5 | instruction/stimulus audio `ended` event | first `pointerdown` on a scale point |
| AUDIO_RECORD | instruction/stimulus audio `ended` event | `pointerdown` on record button (= *response-initiation latency*; recording duration is tracked separately as metadata, not latency) |

**Why client-side, why Pointer Events, not User-Agent:**
- Server-receipt timestamps would bake in network RTT variance (school wifi vs. mobile data) that has nothing to do with the student. Compute the delta in-browser, transmit the number.
- Modern browsers (Chrome's User-Agent Reduction and equivalents) no longer expose reliable device detail in the UA string by design. Capture actual input modality per response via `PointerEvent.pointerType` (`'touch' | 'mouse' | 'pen'`), not by parsing headers.

```javascript
// t0
audioEl.addEventListener('ended', () => { stimulusEndTs = performance.now(); });

// t1 (tap-based items)
optionEl.addEventListener('pointerdown', (e) => {
  const latencyMs = performance.now() - stimulusEndTs;
  submitResponse({
    itemId,
    selectedOption: e.target.dataset.key,
    latencyMs,                 // pre-computed, authoritative value
    inputModality: e.pointerType,
    stimulusEndTs,
    responseTs: performance.now()  // raw values retained for audit only
  });
});
```

Precision note: these are untimed, self-paced screening items, not a speeded-RT battery — a few ms of render jitter won't move a Z-score computed within a device cohort. Getting the anchor points right matters more than sub-frame precision.

---

## 3. Proposed schema (PostgreSQL / Supabase)

```sql
-- ============================================================
-- Participants & consent
-- ============================================================
create table participants (
  id                uuid primary key default gen_random_uuid(),
  anonymized_code   text unique not null,        -- no PII
  class_grade       smallint not null check (class_grade in (6,7,8)),
  age_months        int,
  school_id         uuid,                        -- fk to schools if multi-site
  created_at        timestamptz not null default now()
);

create table consent_records (
  id                    uuid primary key default gen_random_uuid(),
  participant_id        uuid not null references participants(id),
  consent_given         boolean not null,
  consent_date          date not null,
  q1_doctor_eval        boolean,   -- Q1 sub-option: doctor/neuropsychologist
  q1_school_eval        boolean,   -- Q1 sub-option: school evaluation
  q1_not_sure           boolean,
  q2_extra_primary_support text check (q2_extra_primary_support in ('yes','no','not_sure')),
  q3_family_history        text check (q3_family_history in ('yes','no','not_sure')),
  digitized_at          timestamptz,
  paper_form_scan_ref   text       -- storage path, if scanned
);

-- ============================================================
-- Item bank (codebook) — versioned, so edits don't destroy history
-- ============================================================
create table items (
  id                    uuid primary key default gen_random_uuid(),
  item_code             text not null,           -- e.g. 'D1.1', 'C2', 'D2.14'
  version               int not null default 1,
  domain                text not null,           -- '1'..'5' or 'criterion'
  subdomain             text,                    -- e.g. '2.1 Elision'
  response_format       text not null check (response_format in
                         ('MCQ_TAP','BINARY_TAP','TRI_TAP','NUMERIC_KEYPAD','LIKERT_5','AUDIO_RECORD')),
  instruction_audio_url text,
  stimulus_audio_url    text,
  stimulus_text         text,                    -- optional caption only, never sole instruction
  is_instruction_replayable boolean not null default true,
  is_stimulus_replayable    boolean,             -- NULL = undecided, must be set before go-live
  correct_answer        text,                    -- for NUMERIC_KEYPAD / non-MCQ formats
  scoring_mode           text not null check (scoring_mode in ('auto','human_rated')),
  is_practice            boolean not null default false,
  is_scored              boolean not null default true,  -- false for criterion + practice items
  display_order          int,
  active                 boolean not null default true,
  unique (item_code, version)
);

-- Normalized options table — also doubles as a standing data-quality check:
-- run the query at the bottom of this file after every edit to the item bank.
create table item_options (
  id            uuid primary key default gen_random_uuid(),
  item_id       uuid not null references items(id),
  option_key    text not null,          -- 'A','B','C','D' or similar
  option_text   text not null,
  is_correct    boolean not null default false,
  unique (item_id, option_key)
);

-- ============================================================
-- Sessions
-- ============================================================
create table sessions (
  id              uuid primary key default gen_random_uuid(),
  participant_id  uuid not null references participants(id),
  session_part    smallint not null default 1,   -- 1 or 2, if split across sittings
  started_at      timestamptz not null default now(),
  ended_at        timestamptz,
  status          text not null default 'in_progress'
                  check (status in ('in_progress','completed','abandoned','resumed'))
);

-- ============================================================
-- Responses — one row per item attempt. Written immediately on submit,
-- not batched at session end, so an interrupted session doesn't lose data.
-- ============================================================
create table responses (
  id                      uuid primary key default gen_random_uuid(),
  session_id              uuid not null references sessions(id),
  participant_id          uuid not null references participants(id), -- denormalized for query convenience
  item_id                 uuid not null references items(id),
  attempt_number          smallint not null default 1,
  submitted_at            timestamptz not null default now(),

  -- timing (see Section 2 above)
  stimulus_end_client_ts  double precision,   -- performance.now() at t0
  response_client_ts      double precision,   -- performance.now() at t1
  response_latency_ms     double precision,   -- authoritative, computed client-side

  -- device / interaction context, captured per response, not per session
  input_modality          text check (input_modality in ('touch','mouse','pen','keyboard','unknown')),
  viewport_width          int,
  viewport_height         int,

  -- answer content
  selected_option_key     text,
  typed_value             text,
  audio_recording_id      uuid,               -- fk to audio_recordings, set after upload

  -- scoring
  is_correct              boolean,            -- NULL until human-rated, for AUDIO_RECORD items
  scored_by               text check (scored_by in ('system','human')),

  -- replay/retry tracking
  replay_count_instruction  int not null default 0,
  replay_count_stimulus     int not null default 0,
  technical_retry_count     int not null default 0,  -- forced replays due to load failure, kept separate from voluntary ones

  raw_client_event_log    jsonb   -- optional full interaction trace, for later HCI-side analysis
);

-- ============================================================
-- Audio recordings — separated from responses so a recording can be
-- deleted post-study (per the parental consent commitment) while the
-- derived is_correct score in `responses` persists.
-- ============================================================
create table raters (
  id          uuid primary key default gen_random_uuid(),
  label       text not null,     -- pseudonymous, e.g. "Rater 2"
  added_at    timestamptz not null default now()
);

create table audio_recordings (
  id                    uuid primary key default gen_random_uuid(),
  response_id           uuid not null unique references responses(id),
  storage_path          text not null,       -- Supabase Storage key
  duration_ms           int,                 -- metadata, NOT a latency measure
  file_size_bytes        bigint,
  uploaded_at           timestamptz not null default now(),

  rating_status         text not null default 'pending'
                        check (rating_status in ('pending','rated','flagged_unclear','needs_second_rater')),
  is_reliability_subsample boolean not null default false,  -- flagged for double-scoring (Cohen's kappa, Section 11)

  primary_rating        boolean,
  primary_rater_id      uuid references raters(id),
  primary_rated_at      timestamptz,

  secondary_rating      boolean,
  secondary_rater_id    uuid references raters(id),
  secondary_rated_at    timestamptz,
  agreement             boolean generated always as (primary_rating is not distinct from secondary_rating) stored,

  scheduled_deletion_at timestamptz,   -- populate once study end date is set
  deleted_at            timestamptz    -- audit that deletion actually happened
);

-- ============================================================
-- Scoring outputs
-- ============================================================
create table domain_score_results (
  id                    uuid primary key default gen_random_uuid(),
  participant_id        uuid not null references participants(id),
  session_id            uuid not null references sessions(id),
  domain                text not null,   -- '1'..'5'
  raw_score             numeric,
  z_score               numeric,          -- populated once pilot norms exist
  threshold_used         numeric,          -- 10th percentile of Non-dyslexia-consistent group (Section 10.3)
  flagged_deficit        boolean,
  scoring_method_version text not null,    -- track which rule version produced this, for reproducibility
  computed_at            timestamptz not null default now()
);

create table criterion_classification (
  participant_id       uuid primary key references participants(id),
  q2_score             smallint,
  q3_score             smallint,
  item5_score          smallint,
  items6_10_sum        smallint,
  strong_count         smallint,
  weak_count           smallint,
  classification       text check (classification in
                        ('dyslexia_consistent','non_dyslexia_consistent','unclassified')),
  rule_version          text not null,
  computed_at           timestamptz not null default now()
);
```

---

## 4. Example flattened export view (for CSV / ML pipeline)

```sql
create view ml_export_v1 as
select
  r.id                       as response_id,
  p.anonymized_code,
  p.class_grade,
  i.item_code,
  i.domain,
  i.response_format,
  r.response_latency_ms,
  r.input_modality,
  r.selected_option_key,
  r.typed_value,
  r.is_correct,
  r.scored_by,
  r.replay_count_instruction,
  r.replay_count_stimulus,
  r.submitted_at
from responses r
join participants p on p.id = r.participant_id
join items i on i.id = r.item_id;
```

Export with `COPY (select * from ml_export_v1) to STDOUT WITH CSV HEADER` or via Supabase's own export tooling. Z-scoring by device cohort (`input_modality`) happens as a downstream step on this export, per Section 3.6 of the Development Report — not baked into the raw data.

---

## 5a. Analysis pipeline at scale (~1000+ participants)

1. Automated QA pass (duplicate/blank options, per-item floor/ceiling pass rates, missing-data patterns, RT outliers) before any substantive analysis.
2. Reliability: Cronbach's alpha per domain; Cohen's kappa on the double-scored audio reliability subsample.
3. Build criterion groups per Section 10.1-10.2. **Calibration note**: Tamboer et al.'s (2014) own single-pass biographical classification (the same method type BADSQ uses — verified directly against Tamboer's 2019 PhD thesis) produced 33 dyslexic-consistent (6.7%), 256 non-dyslexic-consistent (51.7%), and 206 unclassified (41.6%) out of 495 — *before* their iterative test-score-based refinement, which BADSQ deliberately does not do. Plan recruitment around the number of cleanly-classified cases needed, not the raw participant count; treat this Dutch-adult figure as a planning heuristic to test against your own data, not a guarantee for Bangladeshi adolescents.
4. Compute domain thresholds (10th percentile within Non-dyslexia-consistent group, Section 10.3) and the empirical false-positive rate of the two-or-more-domain rule (Section 10.4).
5. Re-derive domain weights: logistic regression of classification (D-consistent vs. ND-consistent) on the five domain z-scores; compare against the a priori Tamboer-effect-size weights (46/17/15/14/8%).
6. Only then compare against Random Forest/XGBoost, via stratified k-fold CV given a likely small positive class. Report AUC-ROC, sensitivity, specificity, PPV/NPV — not raw accuracy, which is misleading under class imbalance.
7. Test the device-type confound question already flagged in Section 3.6, now with real data.
8. Decide data-sharing/publication policy before collection, not after — current parental consent covers this study only.

## 5b. Supabase storage capacity check

Free tier (500MB DB, 1GB file storage, pauses after 7 days inactivity) is not viable for a live study — the inactivity pause alone rules it out. **Use Pro ($25/month): 8GB database, 100GB file storage included.**

Estimated footprint at 1000 participants:
- Audio: ~20 audio items/student × 1000 ≈ 20,000 recordings, ~25,000 with re-records. At WebM/Opus ~32-64kbps, short spoken clips run ~20-50KB each → **~1.2GB baseline, ~3-5GB with generous safety margin.** ~3-5% of the included 100GB.
- Relational data: ~70-90 responses/student × 1000 ≈ 70-90K rows → well under 500MB, comfortably inside the 8GB Pro allocation (this alone would be tight against the *free* tier's 500MB cap — a second reason to skip it).

Not a limiting factor at this scale. Set MediaRecorder codec/bitrate explicitly rather than relying on browser defaults, and re-check actual usage against this estimate once real recordings start flowing.

## 5c. Anonymous, submit-all-at-once data flow

**Open decisions pending confirmation**: (1) whether the two-session split (recommended elsewhere in the Development Report) is still wanted, given it's hard to support without any login or server-side draft; (2) whether a minimal non-identifying "session started" timestamp ping is acceptable, to preserve completion-rate visibility.

Flow:
1. Client generates a session UUID locally (`crypto.randomUUID()`) — no DB write yet.
2. All responses (answers, latencies, audio blobs) accumulate client-side, backed by IndexedDB as a same-device crash/reload safety net.
3. "Submit" is disabled until every item has a recorded answer.
4. On submit: upload all audio blobs to Storage under the session UUID, then batch-insert the `sessions` row and all `responses` rows in one operation. Nothing exists in Supabase for a participant before this completes.

Trade-off: protects against mid-session data corruption/partial records, but an abandoned session (closed tab, never reaches submit) contributes zero data rather than partial data — the opposite trade-off from the write-through model discussed earlier. Chosen deliberately for anonymity/simplicity; flagged here since it reopens the incomplete-data risk Tamboer et al. (2014) warned about.

Auth model: participants use Supabase anonymous sign-in (no email/password) for the RLS identity needed during the session; researchers/raters use real magic-link accounts gated by a `researchers` allowlist table, enforced via RLS.

## 5d. Admin panel (researcher-facing)

- Auth: magic-link, gated by `researchers` table, RLS-enforced.
- Participants view: listed by `anonymized_code` only. Completion status, submission timestamp, optionally started-but-not-completed count (if the minimal ping above is approved).
- Rating queue: the audio-rating interface (Section on rating workflow above), as a tab in this same panel — no separate app.
- Health view: sessions completed (today/total), recordings pending rating, submission error log.

## 5e. Resume-after-interruption (same-device)

IndexedDB-backed draft, keyed by local session UUID, written after every response. On load, check for an incomplete draft; if found, ask via audio (never silently) whether this is the same person continuing or a new participant, before offering to resume — this specifically guards against a shared school computer silently handing Student A's in-progress test to Student B. Resume restores from IndexedDB; "new turn" discards the stale draft. Cross-device recovery is out of scope for this version (would require a resume code + server-side draft, a bigger change to the anonymous/no-login model) — revisit only if same-device coverage proves insufficient in piloting.

`sessions` row is now created at session start (status = `in_progress`), not at final submit, per the approved minimal session-start ping — this doubles as the anchor the resume check needs, at no extra schema cost.

## 5f. Item bank editing (admin panel)

Editing creates a new versioned row (`items.version` +1); the prior version is marked `active = false` but never deleted, since completed sessions reference the exact version they were shown. "Delete" = soft-delete (`active = false`) with no replacement. No draft/publish staging for v1 — edits are live for new sessions immediately, past sessions keep their original version untouched. Editable: stimulus/instruction audio & text, options + correct answer, `is_stimulus_replayable`, `is_instruction_replayable`, response format, scoring mode, practice/scored flags, domain/subdomain, display order.

## 5g. Pre-build checklist (consolidated across all prior reviews)

**Content / research**
- [ ] Native Bangla-literate Unicode verification pass — all three documents, including the parental consent form (in progress)
- [ ] Fix "five available indicators" → four (Development Report §10.2)
- [ ] Resolve orphan Bosse et al. (2007) reference (cite in-text or remove)
- [ ] Re-check D1.9 / D1.12 / D1.14 duplicate-option items (found via mechanical check)
- [ ] Document test-adaptation methodology against ITC (2017) guidelines
- [ ] Confirm formal ethics board / IRB approval status
- [ ] Decide post-submission withdrawal policy given full anonymity (state as pre-submission-only, or issue a private non-identifying receipt code)
- [ ] Add "no general cognitive ability measure" to Limitations (converges from DSM-5 criteria, Cruger video, Talamo)
- [ ] Formal a priori sample-size/power justification for recruitment target

**Engineering**
- [ ] iOS Safari audio format handling — `MediaRecorder.isTypeSupported()`, mixed-format rater playback UI, tested on a real iPhone
- [ ] Atomic submit: retry logic, local draft not cleared until server confirms full success
- [ ] Backup policy — verify Supabase Pro's actual current backup/PITR inclusion directly; maintain independent periodic export regardless
- [ ] RLS policies written and tested (anonymous participant scope, researcher/rater allowlist)
- [ ] Touch targets ≥24×24px minimum (WCAG 2.2 SC 2.5.8), 44×44px practical target

**Operational**
- [ ] Rater calibration session on a shared practice set before real rating begins
- [ ] Field administration protocol (who runs sessions, device provisioning, unreliable-internet handling)
- [ ] Small (10-20 student) usability pilot before the full data-collection run

## 6. Standing data-quality check (ties back to the item-bank review)

Run this after every edit to the item bank, before anything goes live — it mechanically catches things like the duplicate-option issue found in D1.14 during review:

```sql
select item_id, option_text, count(*)
from item_options
group by item_id, option_text
having count(*) > 1;
```

Also worth a companion check for blank options:

```sql
select item_id, option_key from item_options where trim(option_text) = '';
```
