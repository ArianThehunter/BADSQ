# BADSQ — Research Documentation

**Bangla Dyslexia Screening Questionnaire, digital administration platform**

Audience: an independent researcher evaluating, replicating, or extending this instrument. No
technical knowledge of the software is assumed. Where a claim depends on an implementation
detail, this document states the behaviour, not the code.

---

## 0. Status of this document, and how to read its claims

This documentation was written by reading the repository that builds and runs the instrument:
the database migrations (0001–0027), the participant-facing application source, the researcher
admin panel, the two verification suites, the five phase reports, and
`BADSQ_Technical_Design_Draft_v1.md`. Where the code and the design draft disagree, **the code
is treated as the truth** and the divergence is stated.

Claims are marked:

- **[verified]** — read directly from the live database or from executable code, or observed in
  an actual test run.
- **[inferred]** — deduced from reading code, not observed running.
- **[reported]** — taken from a phase report or design document, not independently re-checked.
- **[not documented]** — the repository does not record a rationale. No rationale has been
  invented in its place.

Two things this document deliberately does **not** do:

1. It does not reconstruct citations or theoretical justifications from outside the repository.
   §2 is incomplete for exactly this reason, and says so.
2. It does not present the instrument as finished or validated. §9 is the honest section, and
   it is long.

Counts in this document were taken from the live production database, item-bank figures on
**2026-09-15** and re-checked on **2026-09-16**. The item bank is editable by researchers through
the admin panel, so counts can change; the queries that produce them are trivial to re-run.

**Revised 2026-09-16**, after a three-device pilot (Android/Chrome, iPhone/Safari, Windows/Edge)
and a review of the exported files. Four things changed materially: the export now carries the
answer key and option text (§7), a blind second-rating path now exists so inter-rater agreement
is collectable (§4.6), audio retention is now deletion at 90 days (§6.5), and one earlier claim
about missing answer keys was **wrong and is corrected in §4.4**.

---

## 1. The instrument

### 1.1 What it screens for

BADSQ is a **screening instrument for dyslexia-type reading, spelling and writing difficulty**
in Bangla-medium schoolchildren. It administers a battery of short tasks in Bangla, entirely by
audio and touch, and records raw responses and response latencies for later analysis.

**It is a screener, not a diagnostic instrument.** Nothing the platform produces constitutes a
diagnosis, a classification of an individual child, or a clinical finding. Concretely, and
**[verified]** against the running system:

- The platform **computes no score of any kind**. Since migration `0012_stop_all_inline_scoring`,
  no response is marked correct or incorrect at submission time, for any response format. The
  `is_correct` column exists and is written `NULL` for every response.
- The two tables intended to hold derived results — `domain_score_results` and
  `criterion_classification` — exist in the schema and are **empty and never written to by any
  code path**. They are placeholders for a downstream analysis that has not been built.
- No threshold, cut-off, percentile or classification rule is implemented anywhere in the
  software.
- The participant is never shown a result, a score, or any feedback about performance. The
  completion screen shows a screening code and nothing else.

The only judgement the platform records at all is a **human rater's verdict on spoken audio
responses** (§4.5), entered afterwards by a researcher, and expressed as correct / incorrect /
unclear — not as a score.

The instrument therefore delivers a **dataset**, and the research contribution — deriving domain
scores, norms, thresholds, weights, and any classification model — is downstream work that this
platform does not perform and does not constrain.

### 1.2 Target population

**[verified]** from the item bank and the intake screens:

- Bangla-medium school students, **classes 6, 7 and 8** — the class question offers exactly these
  three and no other option, so a participant outside them cannot be enrolled.
- Nominally **12–14 years old** (stated in the repository README). Age is asked as a free
  numeric entry in years, not constrained to 12–14, so the enrolled range can exceed the
  nominal one.
- Additional intake variables collected from the child: **gender** (boy / girl / prefer not to
  say) and **home area** (urban / rural). Both are self-reported, single-tap, and have no
  "unknown" branch other than the gender opt-out.

**Exclusion criterion — functional hearing is required.** 57 of the 93 active items deliver
their content as Bangla audio and as audio only: the on-screen text states the task ("listen to
the numbers and write them") but never the content, which exists solely in the recording. A
participant who cannot hear the audio cannot answer any of those items. Hearing is therefore a
**participation requirement**, and deaf or hard-of-hearing children are outside the population
this instrument can assess. See §6.4 for the ethics consequences and §9.8 for why this cannot be
remedied by adding transcripts.

No measure of general cognitive ability, hearing, vision, or first-language status is collected —
note that hearing is an eligibility requirement (above) but is **not screened for**, so
enrolment relies on the supervising adult knowing the child can hear the audio. The design
draft's own pre-build checklist flags the absence of a general cognitive ability measure as a
limitation to be stated; it is stated here in §9.

### 1.3 Structure — five domains plus a criterion block

**[verified]** live item bank, 2026-09-15. 93 active items total: 71 domain items, 6 criterion
items, and 16 demonstration items (one per subdomain, never analysed).

| Domain | Name | Subdomain | Items | Response format | Answer key (see §4.4) |
|---|---|---|---|---|---|
| 1 | Short-term Memory | 1.1 Digit Span Forward | 3 | on-screen numeric keypad | yes |
| | | 1.2 Digit Span Backward | 3 | on-screen numeric keypad | yes |
| | | 1.3 Letter Span Forward | 3 | on-screen Bangla letter grid | yes |
| | | 1.4 Letter Span Backward | 3 | on-screen Bangla letter grid | yes |
| 2 | Phonological Awareness | 2.1 Elision | 3 | **spoken, audio-recorded** | yes |
| | | 2.2 Pseudoword Judgment | 3 | binary tap (match / no match) | yes |
| | | 2.3 Syllable Segmentation | 2 | on-screen numeric keypad | yes |
| | | 2.4 Blending | 3 | **spoken, audio-recorded** | yes |
| | | 2.5 Onset/Coda Matching | 3 | 4-option multiple choice | yes (on the option) |
| | | 2.6 Substitution | 1 | **spoken, audio-recorded** | yes |
| 3 | Rhyme and Confusion | 3.1 Rhyme Judgment | 8 | binary tap (yes / no) | yes (on the option) |
| | | 3.2 Confusion Self-report | 8 | 5-point Likert | n/a (self-report) |
| 4 | Spelling and Orthographic Processing | 4.1 Multiple Choice | 10 | 4-option multiple choice | yes (on the option) |
| | | 4.2 Flash Judgment | 8 | binary tap after 1500 ms exposure | yes (on the option) |
| 5 | Whole-word Processing | 5.1 Spoonerisms | 5 | **spoken, audio-recorded** | yes |
| | | 5.2 Jumbled-sentence Reading | 5 | **spoken, audio-recorded** | yes |
| criterion | Self-report (SR) | — | 6 | 3-point tap (yes / a little / no) | n/a (self-report) |

Seventeen items are spoken and audio-recorded; these are the only items a human ever rates.

**Domain numbering changed.** Migration `0016_domain_renumber_and_content_revision` rotated three
domains: Short-term Memory moved from 3 to 1, Rhyme and Confusion from 4 to 3, and Spelling and
Orthographic Processing from 1 to 4. **Any earlier document, including the design draft in this
repository, uses the old numbering.** Item codes were rewritten to match, so the live item codes
(`1.1.1`, `4.2.3`, …) are unambiguous; only prose in older documents is affected.

**Item-count imbalance is real and unexplained.** Subdomain 2.6 Substitution has **one** scored
item; 2.3 has two; 3.1, 3.2 and 4.2 have eight each; 4.1 has ten. Whether this reflects a
deliberate weighting of subdomains or is simply where item writing stopped is
**[not documented]** in the repository. A one-item subdomain cannot support an internal
consistency estimate and should not be treated as a subscale.

### 1.4 Demonstration items

Every subdomain except the criterion block is preceded by one demonstration item — item codes
ending in `.0` (`1.1.0`, `4.2.0`, and so on). **[verified]**:

- All 16 demonstration items carry instruction audio.
- Demonstration responses are **never stored**. The submission routine skips every item whose
  code ends `.0`, so they reach neither the database nor the export and need no filtering during
  analysis. **[verified]** — each pilot participant produced exactly 77 response rows against 93
  active items.
- Demonstration items are the **only** items for which the correct answer is exposed to the
  participant's browser, so the demonstration can show the child what a right answer looks like.
  For every scored item, the answer key is withheld from the client entirely.
- **The criterion block has no demonstration item.** **[not documented]** whether this was
  deliberate; it is consistent with the block being self-report rather than a task.

---

## 2. Theoretical grounding — **INCOMPLETE**

> **This section cannot be completed from the material in this repository, and has deliberately
> not been filled in from memory or inference.**

The instrument's design draft (`BADSQ_Technical_Design_Draft_v1.md`) repeatedly defers its
theoretical content to a separate document it calls the **Development Report**, citing it by
section number in at least five places:

| Cited as | Content the design draft attributes to it |
|---|---|
| §3.2 | The rationale for avoiding free-text keyboard entry (the "keyboard-confound rationale") |
| §3.6 | Z-scoring by device cohort, and the device-type confound question |
| §10.1–10.2 | Definition of the criterion groups (and a correction: "five available indicators" → four) |
| §10.3 | Domain thresholds at the 10th percentile of the non-dyslexia-consistent group |
| §10.4 | The two-or-more-domain flagging rule and its false-positive rate |

**The Development Report is not in this repository.** It is not among the tracked files and no
copy was found. Consequently the following cannot be documented, and are not:

- the five-factor model's derivation, and why these five domains rather than others;
- which published instruments or tasks each subdomain was adapted from, and how;
- the literature underpinning the criterion-classification rule;
- the provenance and justification of the domain weights;
- the translation and cultural-adaptation methodology for Bangla;
- ethics approval status and the approving body.

### 2.1 What *can* be verified from the design draft

These are the only substantive research claims present in the repository. They are reproduced
here as they appear, attributed to the design draft, and **not independently checked against the
cited sources**:

- **Tamboer et al. (2014)**, and **Tamboer's 2019 PhD thesis**, are the stated source model. The
  design draft states that BADSQ uses "the same method type" of single-pass biographical
  classification.
- **A priori domain weights of 46 / 17 / 15 / 14 / 8 %** are described as "the Tamboer-effect-size
  weights", to be compared against weights re-derived from BADSQ's own data by logistic
  regression. The draft does **not** say which weight belongs to which domain, and — given the
  renumbering in §1.3 — any attempt to map them onto the current domain numbers would be
  guesswork. It is not attempted here.
- **Expected classification yield**: the draft reports that Tamboer's own single-pass
  biographical classification produced **33 dyslexia-consistent (6.7 %), 256
  non-dyslexia-consistent (51.7 %) and 206 unclassified (41.6 %) of 495** Dutch adults, *before*
  an iterative test-score-based refinement that BADSQ deliberately does not perform. The draft is
  explicit that this is "a planning heuristic to test against your own data, not a guarantee for
  Bangladeshi adolescents."
- **ITC (2017)** test-adaptation guidelines and **DSM-5** are named in the draft's pre-build
  checklist as standards the project intends to document itself against. The repository contains
  no such documentation.
- **Bosse et al. (2007)** appears in the draft's checklist as an **unresolved orphan reference** —
  flagged for "cite in-text or remove" and never resolved.

### 2.2 What a replicating researcher needs

To evaluate or replicate the instrument's construct validity, you need the Development Report, or
an equivalent account of: the five-factor derivation, the per-subdomain task provenance, the
criterion rule and its literature, and the adaptation methodology. **Treat §2 as an open
deliverable, not as a gap in this documentation.** The platform can be described completely; the
theory behind the item set cannot be, from here.

---

## 3. Administration

### 3.1 What the participant experiences

**[verified]** by reading the participant application, and **[reported]** from the phase reports
for the browser-driven parts.

The whole session runs in a web browser on a phone, tablet or laptop, in Bangla, and is designed
to be completable by a child working alone once a supervising adult has started it.

**Order of events:**

1. **Landing.** The child opens the study URL and starts a session. The platform issues a
   screening code of the form `BADSQ-XXXX-XXXX` at this moment, server-side. The alphabet
   excludes the characters I, O, 0 and 1 because the code is transcribed by hand onto the paper
   consent form.
2. **Microphone permission** is requested here, at the start — before any task — so that a
   refusal surfaces immediately rather than fifteen minutes in, at the first spoken item.
3. **Background questions**, one per screen, single tap or short numeric entry: age in years,
   class (6/7/8), gender, urban/rural.
4. **Three consent-linked questions** (Q1 prior evaluation, Q2 extra help in primary school,
   Q3 family history). See §5.2 — these are *not* asked of the child as self-report; the child is
   instructed on screen to enter what their parent marked on the paper form.
5. **The task battery**, in fixed order: domain 1 → 2 → 3 → 4 → 5 → criterion block, and within
   each domain the subdomains in fixed numeric order, each preceded by its demonstration item.
   **Items are never shuffled or randomised.** Option order within an item is also fixed.
6. **Completion screen**, showing the screening code.

There is **no timer, no countdown, and no forced pacing** anywhere except the 1500 ms word
exposure in subdomain 4.2. The child advances each item themselves.

### 3.2 Audio-first administration, and the confound it avoids

Every instruction and every task stimulus is delivered as **pre-recorded Bangla audio**, played
by the child pressing a play button. Audio **never autoplays** — the child initiates every clip.

Where an item has both an instruction clip and a stimulus clip, the platform **enforces the
order**: the stimulus play button is disabled until the instruction clip has finished at least
once. **[verified]** in the application logic.

**The confound this avoids** is the central methodological commitment of the administration
design: *if instructions were delivered as written text, then reading ability would gate
performance on every task, including the tasks that are not measuring reading.* A child with the
difficulty the instrument screens for would be disadvantaged on a memory-span item not because
their span is short but because they could not read the instruction. Audio delivery removes
reading from the instruction path.

The same reasoning drives the response formats: **no free-text keyboard entry exists anywhere in
the instrument.** Numeric answers are entered on an on-screen keypad; letter-span answers on an
on-screen Bangla letter grid; everything else is a tap or a spoken recording. Spelling ability
therefore never mediates a response. (The design draft attributes this decision to Development
Report §3.2, which is unavailable — see §2.)

Text on screen is used only as a *redundant* caption alongside audio, or as the content of items
where reading the stimulus **is** the task (subdomains 4.1, 4.2, 5.2) or where the item is a
self-report statement (3.2, SR).

### 3.3 Replay limits

**[verified]** from the application:

| Where | Instruction audio | Stimulus audio |
|---|---|---|
| Domain 1 (Short-term Memory) | **1 play, no replay** | **1 play, no replay** |
| All other domains | up to 3 plays | up to 3 plays (subject to the item's own replay flag) |

Domain 1's single-presentation rule is methodological: a span task in which the stimulus can be
replayed measures something other than span. It is applied to the *instruction* clip as well as
the stimulus clip; this was an explicit decision by the principal researcher during development,
not an oversight.

The replay budgets for instruction and stimulus are **separate counters** — using all three
instruction plays does not consume stimulus plays.

**Replay counts are recorded per response and exported** (`replay_count_instruction`,
`replay_count_stimulus`). They are usable as a covariate: a child who replays every stimulus
three times is behaving differently from one who replays none.

**Caveat on how the limit is applied**: the one-play rule is applied by domain number in the
application, not by a per-item property in the item bank. If domains are renumbered again, that
rule must be moved in the same deployment or it will silently attach to the wrong domain. This is
recorded in the technical documentation as known fragility; it is mentioned here because it is a
threat to *administration fidelity*, not just to code tidiness.

### 3.4 Audio recording

For the 17 spoken items, the child presses record, speaks, and stops. They may re-record before
advancing; only the final take is uploaded. **[verified]**: audio playback and recording are
mutually exclusive — the platform will not let a clip play while recording, or recording start
while a clip plays, specifically so that the stimulus audio is not captured in the child's own
recording and mistaken for the child's answer.

If a clip fails to load or play, the platform **fails loudly**: a bilingual on-screen warning
appears and the failure is retained in the session record, so a supervising researcher can notice
and intervene rather than the child silently answering an item they never heard.

### 3.5 Advancing, and the absence of a back button

The child cannot advance until the current item has a real answer. An answer that was typed and
then cleared does not count as answered. **[verified]**: the advance control is disabled by both
the interface *and* an independent logic guard, because a fast double-tap could previously outrun
the interface state and skip an item — a defect found and fixed during development (see the
technical documentation's defect history).

**Once advanced, an item is locked.** There is no back navigation and no revisiting. An answer
can be changed freely *before* advancing, and the number of changes is recorded
(`selection_change_count`).

### 3.6 Interruption and resume

A local draft of the in-progress session is kept in the browser, written after every response. If
the page is reloaded or the browser crashes, the child can resume on the same device from where
they stopped.

**[verified]**, and methodologically important: on finding a saved draft, the platform **asks
whether this is the same person continuing**, and offers a "new participant" option that discards
the draft. This exists specifically to stop a shared school computer from handing Student A's
part-finished test to Student B. It relies on the answer being given honestly by whoever is at
the device.

Cross-device resume does not exist. A session abandoned on one device cannot be continued on
another.

### 3.7 Duration

**[not documented]** — the repository contains no target or estimated duration, and no timing
pilot has been recorded.

**Empirically**, from the 7 completed sessions in the production database as of 2026-09-15:
mean **24.2 minutes**, range **1 to 90 minutes**. These are development and pilot sessions, not
participants recruited under the study protocol; at least the 1-minute session is certainly a
developer test. **This is not a duration estimate for the real instrument** and should not be
cited as one. A timing pilot on real participants is still needed.

There are also **29 sessions stuck in `in_progress`**, some open for more than 400 hours. These
are abandoned sessions, not participants — they contribute no data, because the platform writes
nothing until final submission (§6.1). They are a housekeeping matter, but they also mean
**completion rate cannot be read off the session table naively**.

### 3.8 Assumed administration conditions

The instrument's design assumes, but does not enforce:

- **A quiet enough environment to hear audio and to be recorded.** No headphone check, no ambient
  noise check, and no playback volume check exists. Audio quality is only assessed
  retrospectively by the human rater, who can mark a recording *unclear*.
- **A working microphone and granted permission.** Permission is requested at the start, so a
  refusal is visible early, but nothing prevents proceeding without it; the spoken items would
  then have no recording.
- **A reasonably stable internet connection at submission time.** During the test itself the
  connection is irrelevant — nothing is transmitted. At submission, the entire session uploads at
  once (§6.1); a failure there is the one point where a whole session can be lost.
  **There is no offline detection or offline queueing** in the platform.
- **Adult supervision at session start**, to transcribe the screening code onto the paper consent
  form and to explain the task. The instrument does not verify that this happened.

---

## 4. Measurement

### 4.1 What is captured per response

**[verified]** from the response schema and the export view. For every item the child answers:

| Captured | Meaning |
|---|---|
| The answer itself | The selected option key, the typed digits/letters, or the audio recording |
| Two latencies | See §4.2 |
| Input modality | `touch`, `mouse`, `pen`, `keyboard`, or `unknown` — see §4.3 |
| Viewport width and height | Screen size in CSS pixels at the moment of response |
| Instruction replays | Count of instruction-audio plays for that item |
| Stimulus replays | Count of stimulus-audio plays for that item |
| Technical retries | Forced replays caused by a load/playback failure, kept **separate** from voluntary replays |
| Selection changes | How many times the answer was changed before advancing |
| Attempt number / superseded flag | Preserves the full attempt history rather than overwriting |
| Submitted-at timestamp | Wall clock, per response |

Session start and end wall-clock times are recorded on the session row.

### 4.2 Latency — what it means here, and the dual-anchor design

Latency is measured **in the browser**, not from server receipt. Server timestamps would
incorporate network round-trip variance — school wifi versus mobile data — which has nothing to
do with the child. The browser computes the interval and transmits the number.

The clock used is the browser's **monotonic high-resolution timer**, not wall-clock time, so a
clock adjustment mid-session cannot corrupt an interval.

**The dual anchor.** Because most items allow the stimulus to be replayed up to three times,
there is no single defensible "stimulus end" moment. The platform therefore records **two**:

- `stimulus_first_end_client_ts` — when the stimulus finished on its **first** play;
- `stimulus_last_end_client_ts` — when it finished on its **last** play before the response.

and derives **two latencies** from the same response moment:

- `response_latency_from_first_ms` — time since first exposure. Includes all replay time, so it
  is a measure of *total time-to-decision including re-listening*.
- `response_latency_from_last_ms` — time since the most recent hearing. Excludes replay time, so
  it is closer to a conventional *decision latency*.

**The analytic choice this preserves is yours, not the platform's.** On an item replayed twice,
those two numbers differ by seconds, and which one is the right dependent variable depends on
what you are modelling. The platform refuses to decide, and exports both. On items with no replay
— all of Domain 1 — they are identical by construction.

**The response anchor** is the moment the child first commits: the first press on an option, on a
keypad digit, or on the record button. For spoken items this is therefore
**response-initiation latency** — how long until they started speaking — **not** how long they
spoke. Recording duration is captured separately, as metadata, and is not a latency.

### 4.3 Device variation, and within-cohort normalization

Response latency on a touchscreen is not commensurable with response latency on a mouse. The
platform's answer is to **record the input modality per response** and leave normalization to
analysis.

**[verified]**, two details that matter methodologically:

- Modality is taken from the browser's pointer-event type (`touch` / `mouse` / `pen`), **not** by
  parsing the User-Agent string. Modern browsers deliberately no longer expose reliable device
  detail in the User-Agent, so User-Agent-based device inference would be both wrong and silently
  wrong. It is recorded per *response*, not per session, so a child who switches from touch to a
  connected mouse mid-session is recorded accurately.
- **Keyboard activation is timed on key-down, not on the synthesized click.** A browser fires the
  synthetic click for a Space-key press on key-*up*, which would have added the child's key-hold
  duration to every keyboard-entered latency — a systematic, modality-specific bias. Timing on
  key-down removes it.

**The intended analytic treatment is z-scoring within device cohort** — the design draft states
this explicitly, attributing it to Development Report §3.6, and states equally explicitly that it
is "a downstream step on this export, not baked into the raw data." The platform performs no
normalization. The raw milliseconds and the modality are exported; the cohort correction is yours
to apply.

**The residual risk is not eliminated, only made analysable.** Within the `touch` cohort, a cheap
low-refresh-rate phone and a flagship tablet are not the same instrument. The platform exports
viewport dimensions, which is a weak proxy for device class and nothing more. If device class is
confounded with the outcome — for instance if school and home devices differ systematically by
socioeconomic status, which in this population is plausible — that confound survives cohort
z-scoring. **The design draft itself flags testing this "with real data" as an open item** and it
has not been tested.

### 4.4 Machine-checkable versus human-rated

**No response is machine-scored.** This is a deliberate change, made during development
(migration `0012_stop_all_inline_scoring`) at the principal researcher's instruction: the
platform collects raw data and does not judge it.

What the item bank still holds is an **answer key**, on every one of the 63 presented items that
has a determinate answer. It is stored in two places depending on the response format, which is
worth knowing because it is easy to look in one place and conclude it is missing:

| Where the key lives | Which items |
|---|---|
| `items.correct_answer` | Typed and spoken formats — the digit and letter spans (1.1–1.4), syllable segmentation (2.3), and every audio-recorded item (2.1, 2.4, 2.6, 5.1, 5.2) |
| `item_options.is_correct` | Choice formats — 2.2, 2.5, 3.1, 4.1, 4.2 |

The 14 items with **no key** are subdomain 3.2 (8 items) and the criterion block (6 items), which
is correct: both are self-report and have no right answer.

**No key is ever applied to a participant response by this platform.** Keys are used only to show
the right answer during a demonstration item, to give the human rater a reference, and — since
2026-09-16 — to populate the export so that scoring can be done downstream (§7).

> **Correction.** An earlier revision of this document stated that 29 items with determinate
> answers had no recorded key. That was wrong: it had only checked `items.correct_answer` and
> missed that the choice formats carry theirs in `item_options.is_correct`. The keys existed
> throughout; what was genuinely missing was their appearance in the export, which is now fixed.

### 4.5 Human rating of spoken responses

The 17 spoken items produce audio recordings, reviewed afterwards by a researcher in the admin
panel. **[verified]** behaviour:

- The rater listens and records a verdict of **correct**, **incorrect**, or **unclear**. The
  third state is not a synonym for "not yet rated" — it is a substantive verdict meaning the
  recording cannot be judged (inaudible, empty, wrong content, background noise). It is distinct
  in the database and in the export from an unreviewed recording.
- A rater may also leave free-text notes on a recording.
- **An already-reviewed recording can be changed to any other verdict**, including back to
  unreviewed. Ratings are not one-way.
- The rater's verdict is stored on the recording. **It is not written into the response row as a
  correctness score.** Until migration `0010`, a database trigger propagated the rating into
  `responses.is_correct`; that propagation was **deliberately disabled** so that the responses
  table holds only raw participant data and the rater's judgement stays clearly attributed to the
  rater. The trigger still exists but is a no-op.

### 4.6 Reliability subsample — and why automatic assignment matters

A random subsample of audio recordings is flagged for **double rating**, to support a Cohen's
kappa inter-rater agreement estimate.

**[verified]**: the flag is assigned **automatically and randomly at submission time**, at a rate
of **20 %**, by the database — before any rater has heard anything.

**This is the methodologically load-bearing part.** In the original implementation the
reliability subsample was chosen by a rater from the queue. That is not a valid basis for
Cohen's kappa: a rater picking which recordings to double-rate will, consciously or not, pick
unrepresentative ones — the clear ones, or the ambiguous ones — and the resulting agreement
coefficient describes that self-selected subset, not the corpus. Because the selection is now
made by the database at submission, before anyone has listened, the subsample is a genuine random
sample of recordings and kappa computed on it is interpretable. This was fixed deliberately
(migration `0008`) and is documented as a phase deliverable.

**The second rating is collected blind** (migration `0026`, 2026-09-16). Earlier revisions of
this document recorded that no second-rater interface existed and that kappa was therefore
uncomputable; that gap has been closed.

The admin panel has a second-rating queue showing a rater only those recordings that are in the
subsample, have already been rated, were rated by **someone else**, and have not yet been
second-rated. The distinct-rater rule is also a database constraint, not just a filter — a
coefficient of agreement between a person and themselves is not agreement.

**The blinding is deliberate and load-bearing.** The query behind that queue does not retrieve the
first rater's verdict, their notes, or the participant's code, and the interface hides the note
editor and the subsample toggle. A second rater who can see the first judgement is anchored by it,
and the resulting coefficient then measures compliance with a colleague rather than agreement
about the audio.

Both verdicts reach the export as `audio_review_verdict` and `audio_second_verdict`, over the same
three categories. **The platform does not compute agreement** — that is an analysis step, and
three-category agreement is yours to compute from those two columns.

One consequence to plan around: audio is destroyed 90 days after upload (§6.5), so **both rating
passes must be completed within 90 days of a participant's session.** A recording deleted before
it is rated is data lost permanently, because the rating is the only thing that outlives the file.

---

## 5. Criterion classification

### 5.1 The biographical indicators

BADSQ's criterion — the thing domain performance is eventually to be validated against — is a
**biographical self- and parent-report classification**, in the tradition the design draft
attributes to Tamboer et al. (2014). It is *not* a prior diagnosis, and *not* a test score.

Nine indicators are collected, in two separate places.

**From the parent, via the paper consent form (3 indicators):**

| | Question | Response options |
|---|---|---|
| Q1 | Has a doctor/psychologist, or the school, ever evaluated the child for reading/writing difficulty? | by doctor / by school / no / not sure |
| Q2 | Did the child need extra help in primary school (classes 1–5) for reading or writing difficulty? | yes / no / not sure |
| Q3 | Has anyone in the immediate family (mother, father, brother, sister) been identified with a dyslexia-type difficulty? | yes / no / not sure |

**From the child, as digital self-report (6 indicators, items SR.1–SR.6):**

| | Statement (translated; presented in Bangla) | Response options |
|---|---|---|
| SR.1 | Compared with other students, do you have much more difficulty with reading, spelling and writing? | yes, I have this problem / maybe / no |
| SR.2 | As a young child, I had difficulty reading. | yes / a little / no |
| SR.3 | As a young child, I had difficulty spelling. | yes / a little / no |
| SR.4 | Currently, I have difficulty reading. | yes / a little / no |
| SR.5 | Currently, I have difficulty spelling. | yes / a little / no |
| SR.6 | Currently, I have difficulty writing (sentences or paragraphs). | yes / a little / no |

The six SR items follow a childhood/current × reading/spelling/writing structure. The precise
mapping onto the source instrument's items is **[not documented]** in this repository (see §2).

### 5.2 The parent/child split — and an important caveat about how Q1–Q3 are collected

The intended split is: **parent answers the biographical history on paper; child answers their
own current and remembered experience digitally.** That split is sound — a 13-year-old is not a
reliable informant on whether they were formally evaluated at age 7, and a parent is not a
reliable informant on how hard their child currently finds spelling.

**But the implementation does not preserve it.** **[verified]** by reading both the participant
application and the submission procedure:

Q1, Q2 and Q3 are presented **on screen to the child**, who is instructed — in the on-screen
English subtitle — to *"Pick what your parent marked"* on the paper form. The child's taps are
written directly into the consent record at submission. The database columns intended to record
researcher transcription of the paper form (`digitized_at`, `digitized_by`,
`paper_form_scan_ref`) are left empty on this path.

Consequences the researcher must plan around:

1. **Q1–Q3 as stored are the child's transcription of the parent's answers**, mediated by the
   child's reading of a paper form and their understanding of the question. They are not
   parent-authored data in the strict sense.
2. **There is no field distinguishing a child-transcribed consent record from a
   researcher-transcribed one.** A researcher who later enters the paper form properly creates a
   *second* consent record for the same participant, and nothing in the schema prevents it —
   there is no uniqueness constraint on participant. Because the export joins responses to
   consent records, **a second consent record duplicates every response row for that participant
   in the export.** This is a live data-integrity hazard, not a hypothetical one.
3. **Only 5 consent records exist for 7 participants** in the current pilot data, so the path is
   already producing partial coverage.

The clean remedy is a decision for the research team: either treat the child-entered Q1–Q3 as the
canonical source and stop maintaining a second path, or add a provenance field and a uniqueness
rule. Neither has been done.

### 5.3 Why Domain 3.2 self-report is separate from the criterion self-report

Subdomain **3.2 Confusion Self-report** (8 Likert-5 items) and the **criterion SR block** (6
tri-state items) are both self-report, both answered by the child, and both unscored. They are
nonetheless kept structurally separate, and must stay separate in analysis.

**3.2 is a predictor. SR is the criterion.** 3.2 asks about a specific perceptual/processing
phenomenon — confusing similar letters and words — and is one of the five domains whose z-scores
are eventually to be regressed onto the criterion. SR asks the child to characterise their
overall reading/spelling/writing difficulty, and is part of what defines the criterion groups.

Collapsing them, or including 3.2 items in the criterion, would **circularly validate self-report
against self-report**. The instrument's structure prevents this by keeping them in different
domains, with different response formats and different item codes, and by placing the SR block
last. Any analysis must maintain that separation.

Note that this separation is structural, not statistical: 3.2 and SR are both self-report from the
same informant in the same sitting, and a child who believes they have a reading problem may
answer both accordingly. **Shared method variance between Domain 3.2 and the criterion is a real
and unaddressed threat to the validity of Domain 3.2's contribution**, and should be examined
empirically — for instance by checking whether Domain 3.2 predicts the criterion appreciably
better than Domains 1, 2, 4 and 5 do, which would be a warning sign rather than a success.

### 5.4 Linkage: the screening code

The child is anonymous. The link between the digital session and the paper consent form is the
**screening code** (`BADSQ-XXXX-XXXX`):

- issued by the server **at session start**, not generated by the browser;
- shown to the child on the **completion screen** (why it appears at the end rather than the
  start is **[not documented]**);
- transcribed by hand onto the paper consent form by the supervising adult;
- the sole join key between the paper record and the digital record.

The alphabet excludes I, O, 0 and 1 precisely because of that hand transcription. The platform
**ignores any code sent by the browser at submission** and uses the one it issued, so a tampered
or mistyped client-side code cannot corrupt the linkage — this is verified by an explicit test in
the security suite.

**The obvious operational risk remains**: if the code is not transcribed, or is transcribed
wrongly, the paper consent form and the digital session cannot be matched, and because the
digital session carries no identifying information there is **no fallback way to match them**.
Losing the code loses the linkage permanently.

### 5.5 The classification rule

**[not documented] and not implemented.** The classification rule — how Q1–Q3 and SR.1–SR.6 map
onto *dyslexia-consistent*, *non-dyslexia-consistent* and *unclassified* — lives in Development
Report §10.1–10.2, which is not in this repository.

What exists is the **shape** of the intended rule, readable from the empty
`criterion_classification` table: separate scores for Q2 and Q3, a separate score for "item 5", a
summed score over "items 6–10", and counts of *strong* and *weak* indicators, feeding a three-way
classification with a recorded rule version. The design draft also carries a correction against
the report — "five available indicators → four" — implying the rule as originally written
over-counted its inputs.

**This table is empty and no code writes to it.** Classification is downstream analysis work that
has not been done. The mapping between the table's column names (`item5_score`, `items6_10_sum`)
and the current SR item codes is **[not documented]** and, given the renumbering history, should
not be assumed.

### 5.6 Expected unclassified proportion

The only basis in the repository is the Tamboer figure quoted in §2.1: **41.6 % unclassified**
(206 of 495) under single-pass biographical classification in Dutch adults, with 6.7 %
dyslexia-consistent and 51.7 % non-dyslexia-consistent.

The design draft's own framing should be carried forward verbatim into any planning: this is
**"a planning heuristic to test against your own data, not a guarantee for Bangladeshi
adolescents."** The population differs in age, language, orthography, educational system and
diagnostic infrastructure. In particular, the base rate of *formal prior evaluation* (Q1) is
likely far lower in Bangladesh than in the Netherlands, which would push the unclassified
proportion **up**, not down.

**Practical implication for recruitment**: plan the sample around the number of cleanly
classified cases needed for the analysis, not the raw participant count. At the Tamboer
proportions, a target of 100 dyslexia-consistent cases implies roughly 1,500 participants — and
that ratio is the optimistic reading.

---

## 6. Data handling and ethics

### 6.1 The anonymity model, and what it costs

**Nothing identifying is collected.** No name, no date of birth, no school name, no contact
detail, no device identifier, no IP-derived location. The participant record consists of: the
screening code, class, age in years, gender, and urban/rural.

**The platform writes nothing during the test.** All answers, latencies and audio accumulate in
the browser, and the entire session is transmitted in a **single atomic submission** at the end.
Before that submission completes, no participant data exists on the server at all. (The only
exception is a bare session-start row, holding a timestamp and the issued code and no responses —
this is what the 29 abandoned `in_progress` rows are.)

Two consequences follow directly, and both are real costs:

1. **An abandoned session contributes nothing.** A child who closes the tab three-quarters of the
   way through leaves no partial data. This was chosen deliberately — the design draft calls it
   "the opposite trade-off from the write-through model", chosen "for anonymity/simplicity", and
   flags that it "reopens the incomplete-data risk Tamboer et al. (2014) warned about." **Missing
   data in this study will be missing *whole sessions*, not missing items**, which is a different
   and in some ways worse missingness pattern to model.
2. **Withdrawal after submission is effectively impossible.** Once submitted, the data carries no
   identifier the child or parent could use to point at their own record — except the screening
   code, if it was transcribed onto their paper form and they kept a note of it. The design draft
   lists this as an unresolved checklist item: *"Decide post-submission withdrawal policy given
   full anonymity (state as pre-submission-only, or issue a private non-identifying receipt
   code)."* **[verified]** that no withdrawal mechanism exists in the platform. **The consent
   documentation must state honestly whether withdrawal is possible after submission and, if so,
   by what route.** This is an open ethics item, not a documentation gap.

### 6.2 Consent

Consent is **parental, on paper**, linked to the digital session by the screening code. The
digital record stores only the flag that consent was given and the date, plus the three
biographical answers (§5.2). The paper forms themselves are held outside the platform; the schema
has a field for a scan reference but it is unused.

Formal ethics board / IRB approval status is **[not documented]** in the repository. The design
draft lists "Confirm formal ethics board / IRB approval status" as an unticked pre-build
checklist item.

### 6.3 Storage, residency and access

- Data is held in a managed PostgreSQL database and object store (Supabase), in the
  **`ap-south-1` (Mumbai) region**. Data residency is therefore **India**, not Bangladesh.
  **[verified]** from the project configuration. Whether that satisfies the study's ethics
  approval and any applicable data-protection expectation is a question for the research team;
  the repository does not address it.
- Access is restricted to an **explicit allowlist of researcher email addresses** held in the
  database. A researcher account that is not on the allowlist can sign in but sees nothing. There
  are two permission flags — rate audio, and manage the item bank.
- A participant's browser session can read the item bank (minus answer keys) and write its own
  session; it cannot read any other participant's data. This is enforced by database-level
  row-security rules, not by the application, and is covered by an automated security test suite.
- **There are deliberately no analytics, no telemetry, and no third-party scripts or asset
  requests of any kind** in the participant application, on the explicit grounds that it handles
  data from minors. The Bangla webfont is self-hosted rather than loaded from a font CDN, so no
  participant's IP address is disclosed to a third party. **[verified]**, and it should be
  preserved through any future change.

### 6.4 Hearing as an eligibility requirement

The instrument cannot be administered to a deaf or hard-of-hearing child (§1.2). This has three
consequences that belong in study documentation rather than in code:

1. **Ethics application** — participation requires functional hearing, and this should be
   recorded as a stated inclusion/exclusion criterion rather than left implicit.
2. **Parental consent form** — parents should know the requirement before enrolling, so that a
   child is not brought to a session they cannot complete.
3. **Limitations and any conformance statement** — the instrument does not meet WCAG 2.2
   Success Criterion 1.2.1 (Audio-only, Prerecorded), and cannot without invalidating what it
   measures (§9.8). Any accessibility claim must state this exception rather than omit it.

This is a documented boundary of the instrument, not a defect awaiting a fix. It is worth stating
plainly that the audio-first design was **itself** an accessibility decision — it removes reading
ability as a confound, which is the correct choice for a dyslexia screener and directly benefits
the population under study. It helps one group and excludes another, and both halves of that
trade-off should be reported.

### 6.5 Audio retention — 90 days

Audio recordings of children's voices are the most sensitive data the study holds.

**Participant audio is destroyed 90 days after upload.** The schema was built for this from the
start: `audio_recordings` is a separate table from `responses` precisely so a recording can be
destroyed while the rating, the latency and the item linkage survive it. Every recording carries
the date its audio must go.

This policy has moved twice and the record should say so plainly. The original design committed
to deletion after the study but never implemented it — `scheduled_deletion_at` and `deleted_at`
existed from migration `0001` and were written by no code. Retention was then changed to
indefinite during development. It has now been set to **90 days from upload** by decision of the
principal researcher (migration `0027`, 2026-09-16), and this time it is implemented.

What that means in practice, stated precisely:

- The **audio file** is destroyed. The **row** is kept forever — the human verdict, the response
  latency and the item it answers are the research data and outlive the recording by design.
- Deletion is performed from the admin panel, through the Storage API. It is **not** automatic:
  nothing runs on a schedule, so it happens only when a researcher does it. This is a deliberate
  choice — destroying a child's voice recording should be an act someone performs — but it means
  the commitment depends on the procedure being followed, and it belongs in the project calendar.
- Exported audio links expire after **30 days**, deliberately shorter than the recording's life so
  a link can never outlive the file.

**The operational consequence is significant and easy to under-estimate.** Both rating passes —
the primary verdict and, for the reliability subsample, the independent second rating — must be
finished within 90 days of a participant's session. A recording deleted before it is rated is
data lost permanently, because the rating is the only thing that survives the file. The admin
panel warns specifically about recordings falling due that are still unrated or still missing
their second rating.

**The consent form must match.** Whatever parents sign has to state 90-day deletion of audio and
indefinite retention of the derived data. That reconciliation is a research-team task; the
platform now behaves as described, but the repository does not contain the consent form and
cannot confirm the two agree.

---

## 7. Data output

### 7.1 Two exports

The admin panel produces two CSV files.

**`full_export_v1` — one row per response.** The analysis-grade file. Each row carries the
participant's demographics and consent answers, the item's identity and format, the answer, both
latencies, the device context, the replay and retry counts, the audio metadata and rating
verdict, the reliability-subsample flag, and the session timestamps. The unit of analysis is the
response.

Because participant-level fields are repeated on every row, this file is **long-format and
redundant by design** — that redundancy is what makes it directly usable for per-item modelling.

**`participant_summary_v1` — one row per participant.** A rollup: demographics, consent answers,
session duration, total responses, audio verdict counts (correct / incorrect / unclear /
unreviewed), overall mean latency, total replays, dominant input modality, and then per-subdomain
counts of items answered, mean latency and replay totals for all 16 subdomains plus the SR block.
The unit of analysis is the participant.

Neither file contains identifying information.

### 7.2 Field meanings worth stating explicitly

- **`anonymized_code`** — the screening code. The join key to the paper consent form, and the
  only link between the two records.
- **`selected_option_key`** — the **English semantic token** of the chosen option, not the Bangla
  text the child saw. Values are things like `yes`, `no`, `little`, `match`, `no_match`,
  `correct`, `wrong`, and for the Likert scale `never` / `hardly` / `sometimes` / `frequently` /
  `always`. This was done deliberately so the export is analysable without Bangla text handling.
  **Exception**: for subdomains **2.5** and **4.1** the option keys are bare `A`/`B`/`C`/`D` and
  carry no meaning on their own — see §7.3.
- **`typed_value`** — the digits or letters entered on the on-screen keypad/grid, as a string.
- **`is_correct` / `scored_by`** — present in the database, always `NULL`. Nothing is machine
  scored. Do not read these columns as data.
- **`audio_review_verdict`** — the human rater's verdict: correct, incorrect, unclear, or
  unreviewed. `audio_marked_correct` is the boolean form and is `NULL` for unclear and
  unreviewed, so the two must be read together.
- **`is_reliability_subsample`** — the randomly assigned double-rating flag (§4.6).
- **`response_latency_from_first_ms` / `response_latency_from_last_ms`** — the two latencies of
  §4.2. Choose one deliberately; do not average them.
- **`is_superseded`** — an answer that was replaced before advancing. Filter to
  `is_superseded = false` for the current answer; the superseded rows are the change history.
- **`technical_retry_count`** — forced replays after a playback failure. Non-zero values flag
  responses given under degraded administration conditions and are worth inspecting before
  analysis.

### 7.3 What the export contains, and the one thing it does not

Two gaps recorded in earlier revisions of this document have been closed (migration `0025`,
2026-09-16). The response-level file now carries:

- **The answer key** — `correct_answer` for typed and spoken items, `correct_option_key` and
  `correct_option_text` for the choice formats. Every item with a determinate answer has one, so
  the file can be scored without returning to the database or the question paper.
- **The option text the participant actually saw** (`selected_option_text`). This matters most
  for subdomains 2.5 and 4.1, whose option keys are bare `A`–`D`: those 13 items' responses were
  previously uninterpretable from the CSV alone, because nothing recorded what `B` was.
- **`is_scored`**, so analysis-excluded items filter without a join.

Still not in the file, by design:

- **The audio itself.** A CSV is text. The export carries each recording's storage path and a
  signed link, which expires after **30 days** — deliberately shorter than the 90-day life of the
  recording, so a link can never outlive the file it points at. Fresh links can be regenerated by
  re-exporting.

### 7.4 Unit of analysis and the derived layer

The exports stop at the response and the participant. Everything past that — domain raw scores,
z-scores within device cohort, thresholds, criterion classification, domain weights, and any
model — is **downstream analysis that this platform does not perform**. The two database tables
that would hold those results exist and are empty.

This is a deliberate boundary and a defensible one: the raw data is preserved unmodified and
every analytic decision stays visible in the analysis code rather than being silently baked into
the collection instrument. It does mean **the analysis pipeline is entirely unbuilt**, and the
instrument's outputs have never been run end-to-end into a result.

---

## 8. Replication

### 8.1 What is language-specific

The following would have to be rebuilt from scratch for another language, and cannot be ported:

- **Every stimulus.** All item content is Bangla: the digit and letter span sequences, the
  pseudowords, the rhyme pairs, the spelling distractors, the spoonerisms, the jumbled sentences.
- **Every audio recording.** All instruction and stimulus audio is recorded Bangla speech.
- **The letter grid** in subdomains 1.3/1.4 is a Bangla letter set.
- **The orthographic manipulations** in Domain 4 — which letter confusions and which misspellings
  are plausible — are specific to the Bangla script and to how Bangla is taught.
- **Subdomain 2.3's syllable counts** depend on Bangla syllabification.
- **The 1500 ms flash exposure** in 4.2 was set for Bangla words at this age. It is not a
  transferable constant.

### 8.2 What is structural and portable

- The **five-domain architecture** and the separation of a predictor set from a biographical
  criterion.
- The **audio-first, no-keyboard administration model** and its rationale (§3.2) — this transfers
  to any language and is arguably the instrument's most portable design contribution.
- The **dual-anchor latency design** (§4.2) and the decision to export both anchors rather than
  choose.
- The **per-response input-modality capture** and within-cohort normalization strategy (§4.3).
- The **fixed, never-randomised item and option order** — chosen so that order is not a nuisance
  variable in downstream modelling.
- The **single-presentation rule for span tasks** and separate replay budgets elsewhere (§3.3).
- The **random, pre-rating assignment of the reliability subsample** (§4.6).
- The **atomic single-submission, nothing-stored-until-complete** data flow (§6.1), with its
  stated trade-off.
- The **screening-code linkage** between an anonymous digital session and a paper consent form.

The software itself is open in this repository and is not Bangla-specific in its structure — item
content, audio and option text are all data, not code. The three genuinely hard-coded
language/domain assumptions are the flash duration, the Domain 1 one-play rule, and the letter
grid contents.

### 8.3 What a replicator must supply that this repository does not

The Development Report (§2), the classification rule (§5.5), and the analysis pipeline (§7.4).
The answer key is present in the item bank and now in the export (§4.4), so a replicator does not
need to reconstruct it.

---

## 9. Limitations

This section is deliberately unsoftened. Everything below is verified against the repository or
the live database.

### 9.1 The population and language gap from the source model

The instrument's stated theoretical parent is Tamboer's work on **Dutch adults**. BADSQ targets
**Bangladeshi adolescents aged 12–14, in Bangla**. That is a gap in age, language, orthography
(alphabetic Latin versus Brahmic abugida), educational system, and the diagnostic infrastructure
that biographical indicators depend on — a question like "were you formally evaluated?" carries a
different base rate and a different meaning in a system where such evaluation is rare.

**No empirical bridge between the two has been established or attempted.** The domain weights,
the expected classification proportions, and the criterion structure are all inherited, and the
design draft is explicit that the inherited figures are planning heuristics only. The instrument
is, at this point, a **structurally faithful adaptation with no evidence that the adaptation
holds**.

### 9.2 Nothing about this instrument has been psychometrically validated

To be concrete about what has not been done:

- No reliability estimate of any kind — no Cronbach's alpha, no test-retest, no split-half.
- No inter-rater reliability. The sampling for it is correct; the second-rating mechanism does
  not exist (§4.6).
- No item analysis: no difficulty or discrimination indices, no floor/ceiling check, no
  distractor analysis.
- No factor analysis. **The five-domain structure is an assumption carried over from the source
  model, not a finding from this data.**
- No norms, no thresholds, no cut-offs.
- No criterion validity, sensitivity, specificity, or predictive value — the criterion
  classification has never been computed even once.
- No convergent or discriminant validity against any existing measure.
- No formal a priori sample-size or power justification (listed as an unticked item in the design
  draft's own checklist).

The instrument has been administered to **7 completed sessions**, which are development and pilot
runs, not recruited participants.

### 9.3 Known contaminated pilot data

**[verified]**: a defect in the ordering of Likert and tri-state response options was live during
part of the pilot. Option order was derived from an internal key rather than from an explicit
display order, and when the option keys were changed to English semantic tokens (migration
`0014`), the 5-point Likert scale in subdomain **3.2** and the tri-state scale in the **SR**
criterion block rendered in a scrambled order — for one scale, in the sequence
always → frequently → hardly → never → sometimes.

The defect was found and fixed (migration `0023` added an explicit display order). **Any 3.2 or
SR responses collected before that fix are not interpretable and must be discarded.** This
affects existing pilot data.

### 9.4 The criterion pathway is incomplete end to end

- The classification rule is undocumented and unimplemented (§5.5).
- Q1–Q3 are collected as a child's transcription of a parent's paper answers, with no provenance
  field and a duplicate-record hazard that silently multiplies response rows in the export (§5.2).
- Consent records exist for only 5 of 7 pilot participants.
- Domain 3.2 and the criterion share method variance and informant (§5.3).

### 9.5 Untested paths

The repository's own verification is honest about its blind spots, and they are worth restating
for a research audience:

- **Automated browser testing is done in headless Chromium with fake media devices.** Not "tested
  on devices" — a simulated browser with a synthetic microphone. That remains true of the
  automated suites.
- **The instrument has now been run manually end to end on three real devices** (2026-09-16):
  Android/Chrome, **iPhone/Safari**, and Windows/Edge. Each completed all 77 items with audio
  recording, latency capture and atomic submission working, and the recordings played back in the
  rating queue. This closes the largest previously-untested path — iOS records in a different
  container and codec from Chrome, and that had never been exercised on real hardware. It is
  **three sessions by one adult tester**, not a usability pilot with children.
- **Real microphone hardware is still not used in any automated test**, so a regression there
  would only be caught by another manual run.
- ~~The security verification suite is stale.~~ **Closed (2026-09-16).** It had asserted the
  pre-`0010`/`0012` contracts — that a human rating propagates into the response row, and that
  responses are scored inline — so it failed on every run for correct reasons. Rewritten to assert
  what actually holds, plus 18 new assertions over the export's access control, the answer key,
  the second-rating rules and retention. Running it also exposed two defects **in the suite
  itself**: its cleanup would have deleted every real consent record (it matched on the
  `BADSQ-` prefix that every real participant code carries), and it left its own fixture
  participants behind in the database, where they were indistinguishable from real data in both
  CSV exports. Both fixed. 66 of its 107 assertions have been executed against the live database
  and all passed; the remainder are unchanged and await one full run.
- ~~The release gate reports 72 failures.~~ **Closed.** Its allowlist had one entry against 72
  live legitimate aliases, so it failed wholesale and could not distinguish a real regression from
  its own backlog. Regenerated against the schema; it now passes with zero unexplained drift.

### 9.6 Device and environment constraints

- **No offline handling.** If connectivity fails at the single submission point, the entire
  session can be lost. There is no queue, no retry-later, and no offline detection.
- **No control over audio environment.** No headphone check, no volume check, no noise check.
  Poor listening conditions are invisible in the data except indirectly, through a rater marking
  a recording unclear.
- **Device class is uncontrolled and possibly confounded.** Within-modality z-scoring (§4.3) does
  not correct for device quality, and device quality may correlate with socioeconomic status in
  this population — which would make it a confound with the outcome, not just noise.
- **A shared-device mix-up is prevented only by an honest answer** to the resume prompt (§3.6).
- **Session duration is unknown for real participants** (§3.7), so fatigue effects across a
  77-item battery are unquantified. Later domains — 4 and 5, and the criterion block last of all —
  are the most exposed to fatigue, and **the item order is fixed**, so fatigue is perfectly
  confounded with domain.

### 9.7 Objections a reviewer will raise, stated in advance

- **"Your criterion is self-report validated against self-report."** Domain 3.2 is child
  self-report and the criterion is child self-report from the same sitting (§5.3). Expect this
  and address it empirically.
- **"You have no measure of general cognitive ability,"** so a low domain score cannot be
  distinguished from generally low performance. The design draft flags this itself and it remains
  true.
- **"Your criterion base rate is inherited from a different population."** §9.1.
- **"You have no evidence your five domains are five domains."** §9.2 — the structure has never
  been tested on this data.
- **"Fatigue is confounded with domain"** because item order is fixed and never counterbalanced.
  The fixed order was chosen deliberately to keep order out of the model; the cost is that
  position and domain cannot be separated.
- **"1500 ms is an arbitrary exposure."** The value was set by instruction during development and
  its empirical basis is **[not documented]**.
- **"One item cannot be a subscale."** Subdomain 2.6 has one scored item (§1.3).
- **"Your criterion base rate and domain weights are inherited, not estimated here."** §9.1 —
  expect to have to justify using them at all before you have your own data.
- **"How do you know a child heard the stimulus?"** You do not, directly. You know how many times
  they played it and whether playback failed.
- **"Your instrument is unusable by deaf participants."** Correct, and stated rather than
  defended: hearing is an explicit eligibility requirement (§1.2, §6.4) and the reason it cannot
  be designed away is set out in §9.8.

### 9.8 Hearing requirement, and why it cannot be designed away

The instrument delivers 57 of its 93 active items as audio only. This excludes deaf and
hard-of-hearing participants absolutely — not partially, not with difficulty, but completely:
there is no item among those 57 they could answer.

**The obvious remedy does not work.** Displaying a transcript would defeat the measurement. Printing
the digit string on screen converts a listening-span task into a reading task; showing the rhyme
pair converts a phonological judgement into an orthographic one. For roughly 40 of the 57 items,
conforming to WCAG 1.2.1 and measuring the intended construct are **mutually exclusive**. The
remaining items — where the audio is only an instruction and the content is already on screen —
could carry transcripts, but fixing a subset would leave the instrument unusable anyway.

Three options existed. They are recorded here so the choice is visible rather than implied:

| Option | Consequence |
|---|---|
| Add transcripts throughout | Destroys construct validity for ~40 items. Rejected. |
| **Document a hearing requirement and exclude the population** | The instrument stays valid; the excluded group is named openly. **Chosen.** |
| Build a separate non-audio parallel form | A different instrument requiring its own validation and norms. A future study, not a remedy. |

Audio-based cognitive instruments commonly carry a hearing requirement, so this is a conventional
position — but it must be **stated**, not assumed. A conformance claim for this instrument reads:
*WCAG 2.2 Level AA is met except SC 1.2.1, which cannot be satisfied without invalidating the
construct; the affected population is an explicit exclusion criterion.*

### 9.9 Summary of open items before data collection

Still open, and all of them research-team decisions rather than software work:

1. **Recover or write the Development Report** (§2). Without it the instrument's theoretical
   grounding, the criterion rule and the domain weights cannot be documented at all.
2. **Make the consent form match the system** (§6.5): 90-day deletion of audio, indefinite
   retention of the derived data. The repository does not contain the form and cannot check.
3. **Decide and state the post-submission withdrawal policy** (§6.1). Full anonymity means there
   is currently no route to withdraw after submitting.
4. **Fix the consent-record provenance question** (§5.2) — Q1–Q3 are entered by the child
   transcribing the parent's paper form, and nothing records which source a row came from. The
   duplicate-row hazard itself is closed.
5. **Confirm and record ethics approval** (§6.2).
6. **Run a timing and fatigue pilot** (§3.7). Session duration for real participants is still
   unknown, and item order is fixed so fatigue is confounded with domain.

Closed since the previous revision: the export now carries the answer key and option text; a
blind second-rating path exists so inter-rater agreement is collectable; audio retention is
implemented and audio is destroyed 90 days after upload; the security verification suite has been
rewritten against the contracts that actually hold; the consent-record and answer-key row-doubling hazards are constrained; the
view-drift release gate passes again; and the iOS audio path has now been exercised on real
hardware (§9.5). Pilot data collected before the option-order fix has been deleted along with the
rest of the pilot set.

---

*Companion documents in this repository: `TECHNICAL_DOCUMENTATION.md` (implementation, for a
developer inheriting the system) and `DOCUMENTATION_NOTES.md` (what could not be documented, and
why).*
