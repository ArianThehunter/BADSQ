# BADSQ Platform — Technical Documentation

For a developer inheriting this codebase with no prior context.

**Scope and epistemic rules for this document.** It describes what the system *does*, established
by reading the code, the migrations, and by querying the live database on 2026-09-15 — not what
any design document says it should do. Where code and design diverge, the code is documented and
the divergence is flagged. Where a reason for a decision could not be recovered from the
repository, this document says **"rationale not documented in the repository"** rather than
supplying a plausible one. Claims are marked **[verified]** (observed directly), **[inferred]**
(read from code but not executed), or **[reported]** (taken from a phase report, not re-confirmed
here).

---

## 1. System overview

BADSQ is a data-collection instrument for a dyslexia-risk screening study of 12–14 year olds
(school classes 6–8) in Bangladesh. It is two applications behind one bundle:

- a **participant flow** — a Bangla-language, audio-first screening battery a child completes once;
- a **researcher admin panel** — item-bank authoring, audio review, participant roster, exports.

It is a research instrument, not a clinical product. The system deliberately performs **no scoring
of participant answers** (§9); it collects raw responses and timing for offline analysis.

### 1.1 Stack

| Layer | Choice | Recoverable rationale |
|---|---|---|
| Build | Vite | Rationale not documented in the repository. |
| UI | React 19 + TypeScript | Rationale not documented in the repository. |
| Backend | Supabase (Postgres 17.6, Auth, Storage) | Rationale not documented in the repository; the design draft §5b evaluates Supabase tiers, assuming it as given. |
| Styling | Plain CSS, no component library | Stated in `README.md` §Layout ("no component library") as a deliberate choice; **reason** not documented. |
| Lint | oxlint | Rationale not documented in the repository. |
| Font | Self-hosted Noto Sans Bengali | **Documented**: `README.md` §Privacy posture — self-hosted "rather than loaded from Google Fonts, so no participant IP address is ever disclosed to a third party." |

**Documented, load-bearing constraint:** the project forbids analytics, telemetry, and third-party
scripts or asset requests of any kind, because it handles data from minors (`README.md` §Privacy
posture). `src/lib/supabaseClient.ts` repeats this in its module docstring: "The only network
destination is the Supabase project below." Preserve this.

### 1.2 Architecture

```
Browser (static SPA, hash-routed)
 ├── Participant flow ──┐
 └── Admin panel ───────┤
                        │ supabase-js (publishable/anon key, shipped in bundle)
                        ▼
        ┌────────────────────────────────────────────┐
        │ Supabase                                   │
        │  Auth   — anonymous sign-in (participants) │
        │           email+password (researchers)     │
        │  Postgres — RLS on every table; SECURITY   │
        │           DEFINER RPCs for privileged ops  │
        │  Storage — badsq-audio (participant voice) │
        │            badsq-item-audio (item stimuli) │
        └────────────────────────────────────────────┘
```

There is **no application server**. The client talks to Supabase directly; all authorization is
Postgres RLS plus a small number of `SECURITY DEFINER` functions. Static hosting only (Vercel or
Netlify); `vercel.json` / `netlify.toml` set response headers and nothing else.

**Critical property:** during a participant's test, **nothing is written to the database** except
the single `sessions` row created at the start. Every answer lives in IndexedDB until one atomic
submit. See §7.9.

---

## 2. Data model

Captured from the live database on 2026-09-15 **[verified]**. Types are as `information_schema`
reports them.

### 2.1 `researchers` — the allowlist

| Column | Type | Null | Default | Purpose |
|---|---|---|---|---|
| `id` | uuid | NO | `gen_random_uuid()` | PK; referenced as the rater/editor identity. |
| `email` | text | NO | — | UNIQUE. Pre-provisioned before the person ever logs in. |
| `user_id` | uuid | YES | — | FK → `auth.users(id)`. NULL until first login; filled by trigger (§4.4). |
| `can_rate` | boolean | NO | `true` | Gates the rating queue and `audio_recordings` UPDATE. |
| `can_manage_items` | boolean | NO | `false` | Gates item-bank writes. Default `false` — rating is the common case. |
| `added_at` | timestamptz | NO | `now()` | — |

This table *is* the authorization root: `is_researcher()`, `can_rate()` and `can_manage_items()`
all resolve against it, and every researcher-facing RLS policy calls one of them.

### 2.2 `participants`

| Column | Type | Null | Default | Purpose |
|---|---|---|---|---|
| `id` | uuid | NO | `gen_random_uuid()` | PK. |
| `anonymized_code` | text | NO | — | UNIQUE. The `BADSQ-XXXX-XXXX` code; the only participant identifier. Copied from `sessions.assigned_code` at submit. |
| `class_grade` | smallint | NO | — | CHECK ∈ (6,7,8). |
| `age_months` | integer | YES | — | **Dead column.** 0 of 231 rows populated **[verified]**. Superseded by `age_years`. Retained; not written by any code path. |
| `school_id` | uuid | YES | — | Unused; no FK, no writer. Multi-site placeholder from the design draft. |
| `created_by_auth_uid` | uuid | YES | `auth.uid()` | Ties the row to the anonymous session that created it; used by `participants_insert_own`. |
| `created_at` | timestamptz | NO | `now()` | — |
| `age_years` | smallint | YES | — | Added migration 0011. What the background-info screen actually collects. |
| `gender` | text | YES | — | Added 0011. `'boy' \| 'girl' \| 'prefer_not_to_say'` **[inferred from `localDraft.ts`]**; no DB CHECK constraint. |
| `home_area` | text | YES | — | Added 0011. `'urban' \| 'rural'` **[inferred]**; no DB CHECK constraint. |

Rows are created **only at submit**, inside `submit_session()`.

### 2.3 `consent_records`

Holds the three parent-answered biographical questions from the paper form.

| Column | Type | Null | Purpose |
|---|---|---|---|
| `id` | uuid | NO | PK. |
| `participant_id` | uuid | YES | FK → `participants(id)`. Nullable so a paper form can be digitized before/without a matching session. |
| `consent_given` | boolean | NO | — |
| `consent_date` | date | NO | — |
| `q1_doctor_eval` / `q1_school_eval` / `q1_not_sure` | boolean | YES | Q1's mutually-exclusive sub-options, stored as three booleans. |
| `q2_extra_primary_support` | text | YES | CHECK ∈ (`yes`,`no`,`not_sure`). |
| `q3_family_history` | text | YES | CHECK ∈ (`yes`,`no`,`not_sure`). |
| `digitized_at` | timestamptz | YES | — |
| `digitized_by` | uuid | YES | FK → `researchers(id)`. |
| `paper_form_scan_ref` | text | YES | Storage path of a scan, if any. |
| `assigned_code` | text | YES | Added 0004. FK → `sessions(assigned_code)` (added 0005 for G2). The paper↔digital join key. |

**Divergence from design [flagged]:** the design draft placed Q1–Q3 on the paper form only. The
shipped system *also* asks the child the same three questions in-app (`TestRunner.tsx` phase
`consent-questions`), and `submit_session()` writes those child-given answers into this same table
via its `p_consent` argument. So a `consent_records` row may originate from the **child**, not the
parent. Nothing in the schema distinguishes the two sources. This is a data-provenance hazard —
see `DOCUMENTATION_NOTES.md`.

### 2.4 `items` — versioned item bank

| Column | Type | Null | Default | Purpose |
|---|---|---|---|---|
| `id` | uuid | NO | `gen_random_uuid()` | PK. Responses reference the exact version shown. |
| `item_code` | text | NO | — | e.g. `2.1.1`. UNIQUE with `version`. A trailing `.0` segment means a demo item (§7.4). |
| `version` | integer | NO | `1` | Incremented by `save_item_version()`. |
| `domain` | text | NO | — | `'1'`–`'5'` or `'criterion'`. |
| `subdomain` | text | YES | — | e.g. `2.1 Elision`. NULL for criterion items. |
| `response_format` | text | NO | — | CHECK ∈ MCQ_TAP, BINARY_TAP, TRI_TAP, NUMERIC_KEYPAD, LIKERT_5, AUDIO_RECORD, FLASH_JUDGMENT, LETTER_SPAN. The last two added in 0013. |
| `instruction_audio_path` | text | YES | — | Key in `badsq-item-audio`. Renamed from `_url` in 0004 (defect G1). |
| `stimulus_audio_path` | text | YES | — | Same. |
| `stimulus_text` | text | YES | — | On-screen text. For audio items this is a short task reminder, **not** the stimulus content **[verified]** — e.g. `1.1.1` reads "সংখ্যাগুলো শুনো এবং লেখ।", not the digits. |
| `is_instruction_replayable` | boolean | NO | `true` | Per-item gate on the instruction replay button. |
| `is_stimulus_replayable` | boolean | YES | — | NULL = undecided; blocks activation (§8.3). |
| `correct_answer` | text | YES | — | Typed/spoken reference answer. Never sent to participants except for demo items (§4.3). |
| `scoring_mode` | text | NO | — | CHECK ∈ (`auto`,`human_rated`). Metadata only — nothing scores live (§9). |
| `is_practice` | boolean | NO | `false` | DB-side demo flag. **Runtime authority is the `.0` item code**, not this column (§7.4). |
| `is_scored` | boolean | NO | `true` | Whether an answer key is expected. Drives one activation blocker. |
| `display_order` | integer | YES | — | Sequencing within a domain. Rebuilt in 0019. |
| `active` | boolean | NO | `true` | Soft delete / version retirement. |
| `edited_by` | uuid | YES | — | FK → `researchers(id)`. |
| `created_at` | timestamptz | NO | `now()` | — |

### 2.5 `item_options`

| Column | Type | Null | Default | Purpose |
|---|---|---|---|---|
| `id` | uuid | NO | `gen_random_uuid()` | PK. |
| `item_id` | uuid | NO | — | FK → `items(id)`. UNIQUE with `option_key`. |
| `option_key` | text | NO | — | The value stored in `responses.selected_option_key`. |
| `option_text` | text | NO | — | Bangla label shown. |
| `is_correct` | boolean | NO | `false` | Ground-truth answer key. **Never exposed to participants** (§4.3). |
| `display_order` | smallint | YES | — | Added 0023. **Authoritative presentation order.** |

**`option_key` is semantic, not positional.** Migration 0014 replaced `A/B/C/D` with English
tokens (`correct`/`wrong`, `match`/`no_match`, `yes`/`no`, `never`…`always`, `yes`/`little`/`no`)
for fixed-vocabulary domains so exports aggregate across items without decoding Bangla. Domains
4.1 and 2.5 keep `A/B/C/D` because their options are item-specific words with no shared vocabulary
**[verified]**.

**This directly caused a production defect** — see §11.3.

### 2.6 `sessions`

| Column | Type | Null | Default | Purpose |
|---|---|---|---|---|
| `id` | uuid | NO | `gen_random_uuid()` | PK. Also the storage folder name for that session's audio. |
| `auth_uid` | uuid | NO | `auth.uid()` | Owning anonymous identity. The entire participant security model keys off this. |
| `participant_id` | uuid | YES | — | FK → `participants(id)`. NULL until submit. |
| `session_part` | smallint | NO | `1` | Vestigial (two-sitting split, never implemented). |
| `started_at` | timestamptz | NO | `now()` | — |
| `ended_at` | timestamptz | YES | — | Set at submit. |
| `status` | text | NO | `'in_progress'` | CHECK ∈ (`in_progress`,`completed`,`abandoned`). **Nothing ever sets `abandoned`** **[verified]** — see §10.11. |
| `assigned_code` | text | YES | — | Server-issued `BADSQ-XXXX-XXXX`. Referenced by `consent_records.assigned_code`. |

### 2.7 `responses`

One row per item per session, written only by `submit_session()`.

| Column | Type | Null | Default | Purpose |
|---|---|---|---|---|
| `id` | uuid | NO | `gen_random_uuid()` | PK. |
| `session_id` | uuid | NO | — | FK → `sessions(id)`. |
| `item_id` | uuid | NO | — | FK → `items(id)` — the exact version shown. |
| `attempt_number` | smallint | NO | `1` | Always 1 in practice (§7.8). |
| `is_superseded` | boolean | NO | `false` | Always false in practice. Export filters on it. |
| `submitted_at` | timestamptz | NO | `now()` | **Not per-item timing** — every row in a session shares one value (§7.7). |
| `stimulus_first_end_client_ts` | double precision | YES | — | Anchor A (§7.6). |
| `stimulus_last_end_client_ts` | double precision | YES | — | Anchor B (§7.6). |
| `response_client_ts` | double precision | YES | — | `performance.now()` at first interaction. |
| `response_latency_from_first_ms` | double precision | YES | — | `response_client_ts − first_end`. |
| `response_latency_from_last_ms` | double precision | YES | — | `response_client_ts − last_end`. |
| `input_modality` | text | YES | — | CHECK ∈ touch, mouse, pen, keyboard, unknown. |
| `viewport_width` / `_height` | integer | YES | — | Captured at first interaction. |
| `selected_option_key` | text | YES | — | For choice formats. |
| `typed_value` | text | YES | — | For keypad/letter-grid formats. |
| `is_correct` | boolean | YES | — | **Always NULL** since migration 0012 (§9). |
| `scored_by` | text | YES | — | **Always NULL** since 0012. CHECK ∈ (system, human). |
| `replay_count_instruction` | integer | YES | — | Nullable since 0011: NULL = "item has no instruction audio", 0 = "had audio, played zero times". |
| `replay_count_stimulus` | integer | YES | — | Same semantics. |
| `technical_retry_count` | integer | NO | `0` | Never written by the client **[verified]**. |
| `raw_client_event_log` | jsonb | YES | — | Never written by the client **[verified]**. |
| `selection_change_count` | integer | NO | `0` | Added 0007. |

**Note `responses` has no `participant_id`.** The design draft had one ("denormalized for query
convenience"); the shipped schema routes through `session_id`. Divergence, deliberate — migration
0003 removed a circular FK (`README.md` migration table) **[reported]**.

### 2.8 `audio_recordings`

| Column | Type | Null | Default | Purpose |
|---|---|---|---|---|
| `id` | uuid | NO | `gen_random_uuid()` | PK. |
| `response_id` | uuid | NO | — | FK → `responses(id)`, UNIQUE. One recording per response. |
| `storage_path` | text | NO | — | `<session_id>/<response_client_id>.<ext>` in `badsq-audio`. |
| `mime_type` | text | YES | — | Detected per device, not assumed (§7.10). |
| `duration_ms` | integer | YES | — | Metadata, **not** a latency measure. |
| `file_size_bytes` | bigint | YES | — | — |
| `uploaded_at` | timestamptz | NO | `now()` | — |
| `rating_status` | text | NO | `'pending'` | CHECK ∈ pending, rated, flagged_unclear, needs_second_rater. Only `pending`/`rated` used. |
| `is_reliability_subsample` | boolean | NO | `false` | Set randomly at submit (§8.6). |
| `primary_rating` | boolean | YES | — | Two-state projection of `primary_verdict`. |
| `primary_rater_id` | uuid | YES | — | FK → `researchers(id)`. |
| `primary_rated_at` | timestamptz | YES | — | — |
| `secondary_rating` / `_rater_id` / `_rated_at` | — | YES | — | Written by the blind second-rating pass (0026). CHECK: `secondary_rater_id <> primary_rater_id`. |
| `secondary_verdict` | text | YES | — | Added 0026. CHECK ∈ (`correct`,`incorrect`,`unclear`). The authoritative second verdict. |
| ~~`agreement`~~ | — | — | — | **Dropped in 0026.** It compared two booleans that are both NULL when a recording is unrated *or* unclear, so an entirely unrated pair evaluated `true`. Compute agreement from the two verdict columns instead. |
| `scheduled_deletion_at` | timestamptz | YES | `now() + 90 days` | Added as a default in 0027. When the audio must be destroyed. |
| `deleted_at` | timestamptz | YES | — | Stamped only when the Storage API confirms the file was removed. NULL = the file still exists. |
| `notes` | text | YES | — | Added 0010. Free-text reviewer note. |
| `primary_verdict` | text | YES | — | Added 0021. CHECK ∈ (`correct`,`incorrect`,`unclear`). **Authoritative verdict.** |

### 2.9 `domain_intros`

Per-subdomain instruction screens. **All 17 rows are currently `active = false`** (migration 0024)
**[verified]** — the instruction is now carried by each subdomain's demo-item audio. Text is
preserved; restore with `update domain_intros set active = true;`.

`intro_audio_path` exists but **is never played** — `TestRunner.tsx` selects it and renders only
`intro_text` **[verified]**. Dead column.

### 2.10 Analysis tables — all empty and unwritten

`domain_score_results` and `criterion_classification` are created by 0001, carry RLS,
and **no code reads or writes any of them** **[verified: 0 rows; no references in `src/`]**. They
are placeholders for offline analysis. A maintainer should not assume a pipeline exists.

### 2.11 Views

| View | security_invoker | Purpose |
|---|---|---|
| `public_items` | **off** (definer) | Participant-facing item read path. §3.2. |
| `public_item_options` | **off** (definer) | Participant-facing options. §3.2. |
| `full_export_v1` | **true** | Response-level CSV export. **49 columns** after 0025/0026 — now carries the answer key (`correct_answer`, `correct_option_key`, `correct_option_text`), `selected_option_text`, `is_scored`, `client_time_origin_ms` and both audio verdicts. |
| `participant_summary_v1` | **true** | Aggregates, one row per participant (0022). The *exported* summary is wider: `downloadParticipantSummaryCsv()` pivots per-item answers, option text, verdicts and latencies onto each row client-side, so an edited item bank changes the columns without a migration. |
| ~~`ml_export_v1`~~ | — | **Dropped in 0025**, with `ml_snapshots`. Superseded by `full_export_v1`, referenced by no application code, and still exposing the retired `is_correct`/`scored_by` — a second, staler export view invites analysing the wrong one. |

### 2.12 Entity relationships

```
auth.users ──(trigger link_researcher_on_signup)──► researchers
                                                      │ id
                        ┌─────────────────────────────┼──────────────┐
                        ▼ digitized_by                ▼ edited_by    ▼ primary_rater_id
                  consent_records                   items       audio_recordings
                        │ participant_id              │ id             │ response_id (UNIQUE)
                        │ assigned_code ──┐           │                │
                        ▼                 │           ▼                ▼
                  participants            │      item_options      responses
                        ▲ id              │       (item_id)        (item_id, session_id)
                        │ participant_id  │                             ▲
                     sessions ◄───────────┘ assigned_code               │ session_id
                        │ auth_uid → (anonymous identity)               │
                        └───────────────────────────────────────────────┘

participants ◄── domain_score_results, criterion_classification   [both empty, unwritten]
domain_intros — standalone, no FK except edited_by → researchers
```

---

## 3. Security model

### 3.1 Two identities, one Postgres role — the central fact

Supabase anonymous sign-in issues a JWT with `role = authenticated`. Researchers signing in with
email+password get **the same `role = authenticated`**. A participant and a researcher are
therefore *indistinguishable at the Postgres role level*.

**Consequence:** separation cannot use `GRANT`/`REVOKE`, because any grant to `authenticated`
reaches both. It must be expressed as **row-level predicates** — which is why every table has RLS
and every researcher policy calls `is_researcher()`.

This is documented reasoning, verified in `MIGRATION_0004_REPORT.md` §G4: "Supabase anonymous
sign-in issues `role=authenticated`, so participants and researchers genuinely are the same
Postgres role, and no role-level or grant-level separation is available." **[reported, and
consistent with the live policy set — verified]**

### 3.2 Why `public_items` / `public_item_options` are SECURITY DEFINER

This is deliberate and load-bearing. Supabase's linter reports both as ERROR-level
`security_definer_view`; **these two errors are expected and must not be "fixed."**

**The problem.** Participants must read the item bank (stimulus text, audio paths, option labels)
but must never read `items.correct_answer` or `item_options.is_correct`. Given §3.1, a grant on
`items` reaches researchers and participants identically.

**The mechanism.** The views select only safe columns and filter `active = true`. Being
`SECURITY DEFINER` (i.e. `security_invoker = off`), they execute as their owner, so base-table RLS
on `items` does **not** apply to the view's internal read. Participants get zero rows querying
`items` directly, but the expected rows through the view — RLS is genuinely the separator.

**What it defends against.** Column-level leakage of the answer key by any route: direct base-table
select, PostgREST embedded join, or explicit column projection.

**What was actually verified** (`MIGRATION_0004_REPORT.md` §G4) **[reported]**:
- participants and `anon` read exactly the active items/options through the views;
- neither view exposes `correct_answer`/`is_correct` — checked in the definition, in the HTTP
  response body, and by attempting a PostgREST embedded join;
- base tables return **0 rows** to participants despite a restored `SELECT` grant;
- the view still honours `active = true`, probed specifically with one active and one retired
  version of the same `item_code` — anon saw exactly 1 row.

**F1 is why the alternative does not work.** Migration 0003 tried `security_invoker = on` plus
`revoke select on items from anon, authenticated`. Because `security_invoker` checks base-table
*privileges* against the caller, revoking the grant disabled the view too, and the item bank became
unreadable by everyone (HTTP 401, `42501`). See §11.1.

**Residual risk, stated plainly:**
1. The view owner's privileges are what execute. Anyone who can redefine the view can widen it, and
   the linter error is permanently present, so a *new* unintended definer view would not stand out.
2. `public_items` gained `practice_correct_answer` in migration 0017 — it **does** expose an answer
   key, deliberately, but only via `CASE WHEN is_practice THEN correct_answer ELSE NULL END`. The
   guarantee is now conditional, and its correctness depends on `is_practice` being accurate.
3. Protection is column-projection-based. Adding a column to the view without review reopens the
   hole the views exist to close. The view-drift gate (§11.4) does not check for this.

### 3.3 RLS policy set (live, verified)

All `public` policies are granted to role `{public}` — meaning they apply to every role, with the
predicate doing the work.

| Table | Policy | Cmd | Predicate | Defends |
|---|---|---|---|---|
| `researchers` | `researchers_select_researcher` | SELECT | `is_researcher()` | Allowlist not enumerable by participants. |
| `participants` | `participants_select_researcher` | SELECT | `is_researcher()` | Roster confidentiality. |
| `participants` | `participants_insert_own` | INSERT | `created_by_auth_uid = auth.uid()` | Legacy; `submit_session()` is DEFINER so it does not rely on this. |
| `sessions` | `sessions_select` | SELECT | `auth_uid = auth.uid() OR is_researcher()` | Participant reads only their own row. Consolidated from two policies in 0006. |
| `responses` | `responses_select_researcher` | SELECT | `is_researcher()` | **No INSERT/UPDATE policy exists** — writes are only possible through `submit_session()`. |
| `items` | `items_select_researcher` | SELECT | `is_researcher()` | Participants use the definer views instead. |
| `items` | `items_write_manager` | INSERT | `can_manage_items()` | — |
| `items` | `items_update_manager` | UPDATE | `can_manage_items()` | — |
| `item_options` | `item_options_select_researcher` | SELECT | `is_researcher()` | — |
| `item_options` | `item_options_write_manager` | ALL | `can_manage_items()` | Overlaps the SELECT policy — flagged by the performance linter, harmless. |
| `audio_recordings` | `audio_select_researcher` | SELECT | `is_researcher()` | — |
| `audio_recordings` | `audio_update_rater` | UPDATE | `can_rate()` | The rating write path. |
| `consent_records` | `consent_researcher_all` | ALL | `is_researcher()` | — |
| `domain_intros` | `domain_intros_select_all` | SELECT | `active = true OR is_researcher()` | Participants see only live intros. |
| `domain_intros` | `domain_intros_write_manager` / `_update_manager` | INSERT / UPDATE | `can_manage_items()` | — |
| `domain_score_results`, `criterion_classification` | `*_researcher_all` | ALL | `is_researcher()` | Closes F3. `ml_snapshots` carried the same policy until it was dropped in 0025. |

**Participants can write nothing directly.** No table grants a participant INSERT or UPDATE except
the legacy `participants_insert_own`. Every participant write goes through `start_session()` or
`submit_session()`.

### 3.4 Storage policies (live, verified)

**`badsq-audio`** — participant voice recordings:

| Policy | Cmd | Roles | Predicate |
|---|---|---|---|
| `audio_upload_own_session` | INSERT | anon, authenticated | bucket matches **and** a session exists with `auth_uid = auth.uid()`, `status='in_progress'`, and `foldername(name)[1] = session.id` |
| `audio_select_own_session` | SELECT | public | same session-ownership check, without the status condition |
| `audio_read_researcher` | SELECT | authenticated | `is_researcher()` |
| `audio_delete_researcher` | DELETE | authenticated | `is_researcher()` |

A participant may write **only into a folder named after a live session they own**, and read back
only their own. The SELECT policy's existence is not cosmetic — its absence *was* defect I1
(§11.2), because `INSERT ... RETURNING` requires it.

**`badsq-item-audio`** — researcher-uploaded stimuli:

| Policy | Cmd | Roles | Predicate |
|---|---|---|---|
| `item_audio_read` | SELECT | authenticated | `is_researcher() OR exists(session owned by caller, in_progress)` |
| `item_audio_write_manager` | INSERT | authenticated | `can_manage_items()` |
| `item_audio_update_manager` | UPDATE | authenticated | `can_manage_items()` |
| `item_audio_delete_manager` | DELETE | authenticated | `can_manage_items()` |

Note `item_audio_read` is granted to `authenticated` only, not `anon` — which works because
anonymous sign-in yields `authenticated` (§3.1). A participant can read item audio **only while
holding a live session**.

### 3.5 Functions (live, verified)

| Function | DEFINER | search_path | Executable by |
|---|---|---|---|
| `is_researcher()` | yes | `public` | PUBLIC, anon, authenticated |
| `can_rate()` | yes | `public` | PUBLIC, anon, authenticated |
| `can_manage_items()` | yes | `public` | PUBLIC, anon, authenticated |
| `generate_participant_code()` | no | `public` | PUBLIC, anon, authenticated |
| `reliability_subsample_rate()` | no | `public` | PUBLIC, anon, authenticated |
| `start_session()` | yes | `public` | PUBLIC, anon, authenticated |
| `submit_session(uuid,jsonb,jsonb,jsonb)` | yes | `public` | anon, authenticated |
| `save_item_version(uuid,jsonb,jsonb)` | yes | `public` | authenticated only |
| `link_researcher_on_signup()` | yes | `public` | postgres, service_role only |
| `propagate_audio_rating()` | **no** | `public` | postgres, service_role only |

**Why DEFINER:** the three RLS helpers must read `researchers`, which participants cannot select —
if they ran as invoker they would return false for everyone. `start_session()` and
`submit_session()` must insert into tables with no participant INSERT policy.
`save_item_version()` performs a multi-table atomic write.

**Why `search_path` is pinned on every one:** because not pinning it caused a total outage. F2 —
`link_researcher_on_signup()` was DEFINER with no `SET search_path`, so it inherited GoTrue's
(`search_path=auth`), could not resolve `researchers` in `public`, and **every user signup failed
with HTTP 500**. Phase 1 then extended the pin to every function in `public` as an invariant, not
just DEFINER ones. J1 was a later violation of that same invariant (§11.2).

**Why the two trigger functions have restricted ACLs:** G5/H1. Making `propagate_audio_rating()`
DEFINER also exposed it at `/rest/v1/rpc/`. The fix required revoking from **PUBLIC**, not just
`anon, authenticated` — see §11.2 (H1).

### 3.6 Triggers

| Trigger | Table | Timing | Function | Status |
|---|---|---|---|---|
| `trg_link_researcher_on_signup` | `auth.users` | AFTER INSERT | `link_researcher_on_signup()` | Active. |
| `trg_propagate_audio_rating` | `audio_recordings` | AFTER UPDATE | `propagate_audio_rating()` | Active but the **function body is a no-op**. |

**Critical for maintainers:** `propagate_audio_rating()` was the subject of defect F4 and was made
DEFINER to fix it. Migration 0010 then **deliberately emptied it**. Its live body is **[verified]**:

```sql
begin
  -- Intentionally a no-op as of migration 0010 …
  return NEW;
end;
```

It is now SECURITY INVOKER again. **Ratings do not propagate to `responses.is_correct`.** Anyone
reading `PHASE_0_REPORT.md` §F4 in isolation will believe they do. See §9.

### 3.7 The allowlist ↔ signup trigger

1. A researcher's email is inserted into `researchers` **before** they have an account.
2. An admin creates the auth user (Dashboard → Authentication → Users → Add user).
3. `trg_link_researcher_on_signup` fires AFTER INSERT on `auth.users` and sets
   `researchers.user_id = NEW.id WHERE email = NEW.email AND user_id IS NULL`.
4. `is_researcher()` thereafter resolves `auth.uid()` → allowlist row.

**Known gap, documented in `supabaseClient.ts`** `loadResearcherProfile()`: the trigger fires only
on `auth.users` INSERT, so an address added to the allowlist **after** that person first signed in
stays unlinked, and they present as not-a-researcher. Manual fix: set `researchers.user_id` by hand.

**Operational trap (G7):** `researchers.user_id` has no `ON DELETE` action, so deleting a departed
researcher's auth account fails with FK violation `23503` until `user_id` is nulled first
**[reported]**.

---

## 4. Application architecture

### 4.1 Routing — hash-based, and why it matters

`src/App.tsx` reads `window.location.hash`. Routes: `#/` (landing), `#/test` (participant),
`#/admin/...` (researcher).

**Deployment consequence:** the server never sees a path other than `/`, so **no SPA rewrite rule
is needed** on Vercel or Netlify. `vercel.json` and `netlify.toml` therefore contain only security
headers — confirmed by reading both files **[verified]**. A maintainer migrating to history-based
routing must add rewrite rules or every deep link 404s.

### 4.2 Components

| File | Responsibility |
|---|---|
| `src/App.tsx` | Hash router. |
| `src/LandingPage.tsx` | Two entry cards (student / researcher). |
| `src/components/TestRunner.tsx` | **The entire participant flow** — ~1500 lines; phases, sequencing, audio gating, latency, draft, submit. |
| `src/components/responses/*.tsx` | One component per response format; `OptionGrid.tsx` is shared by all choice formats. |
| `src/admin/AuthGate.tsx` | Password sign-in + allowlist resolution. |
| `src/admin/AdminShell.tsx` | Identity banner, nav, Home link, sign out. |
| `src/admin/ItemBankEditor.tsx` | Item authoring + versioning + audio upload. |
| `src/admin/RatingQueue.tsx` | Audio review queue. |
| `src/admin/ParticipantsView.tsx` | Roster + per-participant recording drill-down. |
| `src/admin/RecordingCard.tsx` | Shared recording player + verdict control. |
| `src/admin/HealthView.tsx` | Counts + the two CSV exports. |

### 4.3 Data access layer

| File | Role |
|---|---|
| `src/lib/supabaseClient.ts` | Client construction, `ensureAnonymousSession()`, `signInResearcher()`, `startSession()`. |
| `src/lib/itemBank.ts` | Item CRUD via `save_item_version()`. |
| `src/lib/itemValidation.ts` | **Pure** activation-guard logic, no I/O — testable in isolation. |
| `src/lib/media.ts` | Signed URLs, uploads, MIME detection. |
| `src/lib/localDraft.ts` | IndexedDB draft; `hasRealAnswer()`/`allAnswered()` gating. |
| `src/lib/adminData.ts` | Admin queries and CSV generation. |
| `src/types/database.types.ts` | Generated types. **Hand-patched** — see §12.9. |

**Answer-key containment.** `src/components/responses/types.ts` documents the invariant: `PublicItem`
and `PublicItemOption` are the sanitised shapes from the definer views, and "there is no
`correct_answer` or `is_correct` field to accidentally pass through." Migration 0017 added the one
deliberate exception, `practice_correct_answer`, NULL for every non-demo item.

### 4.4 State management

No state library. `TestRunner` holds a `phase` state machine plus a `LocalDraft` mirrored into a
`draftRef` (for callbacks) and IndexedDB (for durability). `setAndPersistDraft()` writes all three
at once — this is the only correct way to mutate the draft.

---

## 5. Participant flow

Phases, in order: `loading` → `resume-prompt`? → `onboarding` → `background-info` →
`consent-questions` → `pre-test-intro` → (`domain-intro` ⇄ `running`)* → `ready-to-submit` →
`submitting` → `complete`. Plus terminal `no-items` and `submit-error`.

### 5.1 Session initiation and code issuance

`startSession()` → `ensureAnonymousSession()` (Supabase `signInAnonymously()`) → RPC
`start_session()`, which is DEFINER, requires `auth.uid()`, calls `generate_participant_code()`,
inserts the `sessions` row, and returns `(session_id, assigned_code)`.

The code alphabet excludes **I, O, 0, 1** because a teacher hand-transcribes it onto the paper form
and someone else reads it back (`README.md` §Participant codes).

**Direct `INSERT` into `sessions` is not a valid entry point** (G6): such a row has
`assigned_code = NULL` and `submit_session()` rejects it — producing a session that accumulates a
full battery in IndexedDB and then fails at the worst moment.

### 5.2 Item sequencing

Fetch `public_items` ordered by `domain`, then `display_order`. `domain` is text, but `'1'`–`'5'`
sort correctly lexically and `'criterion'` sorts after `'5'` (`'5'` = 0x35 < `'c'` = 0x63), so the
domain-level order is correct without extra work **[verified]**.

**Order is fixed. Nothing is randomized.** Options are sorted by
`(display_order, option_key)` — a total order that does not depend on row-return order.

**Option shuffling was removed** (see §11.3). Rationale, documented in migration 0023: shuffling
removed position bias but injected an *unrecorded* random component into response latency (the
presented order was never stored), making that variance unmodellable; position bias is instead
handled by balancing the answer key across positions (4.1 is deliberately A:2/B:2/C:3/D:3).

### 5.3 Audio-first gating

`disabled = response.stimulusFirstEndClientTs == null`. The response control is inert until audio
has **ended** at least once. Three cases:

1. **Instruction + stimulus** — two-step. "Play instructions" first; "Play question" is rendered
   disabled until the instruction's `ended` fires; the stimulus's `ended` opens the response.
2. **One clip only** — that clip's `ended` opens the response.
3. **No audio at all** — an effect sets both anchors to `performance.now()` at mount, unlocking
   immediately. Without this the item would be permanently locked (documented in
   `TestRunner.tsx` as a robustness measure referencing `PHASE_2_REPORT.md` deviation 1).

**Audio never autoplays.** Every first play is a deliberate button press. **Divergence from the
design draft [flagged]:** §2's reference implementation assumes an autoplaying element.

**Mutual exclusion:** a single `audioLocked` flag prevents two clips sounding together and
prevents recording during playback (and playback during recording) — the microphone would
otherwise capture the item's own audio through the speaker.

### 5.4 Latency measurement — dual anchor

`performance.now()` throughout (monotonic, immune to clock adjustment), per design §2.

| Anchor | Meaning |
|---|---|
| `stimulus_first_end_client_ts` | the **first** time the gating audio ended — before any replay |
| `stimulus_last_end_client_ts` | the **most recent** end, after all replays |

Both latencies are stored. **Why both:** F5 records the decision as "do not pick one, record both"
— and F5 exists precisely because an export silently dropped the `from_first` anchor. The analytic
choice (does a replay reset the clock?) is preserved for the analyst rather than baked in.

`t1` is the **first** interaction only; later changes to the answer do not re-arm it
(`OptionGrid.tsx`: "Re-timing on every tap would destroy the very thing this instrument
measures"). For `AUDIO_RECORD`, `t1` is pressing Record — response-*initiation* latency; recording
duration is separate metadata.

### 5.5 Input modality — Pointer Events, not User-Agent

`PointerEvent.pointerType` per response. Design §2 gives the reason: modern browsers (Chrome's
User-Agent Reduction) no longer expose reliable device detail in the UA string by design.

**Keyboard is timed on `keydown`, not the synthesized `click`.** A native button's click for Space
fires on *key-up*, so timing keyboard off `click` would have measured "time to release" against
"time to press" for pointers — inflating keyboard latency by a full key-hold. `preventDefault()`
suppresses the later click; the `onClick` handler survives only as a backstop
(`OptionGrid.tsx` module comment).

### 5.6 Replay behaviour

Two independent budgets per item, instruction and stimulus, each capped by `maxAudioPlays(item)`:
**1 for domain `'1'`, 3 otherwise**. Every actual playback counts, including the first.

Replay buttons additionally require the per-item flags `is_instruction_replayable` /
`is_stimulus_replayable`.

⚠️ **`maxAudioPlays()` hardcodes `item.domain === '1'`.** Migration 0016 renumbered domains
(Short-term Memory moved from `'3'` to `'1'`). If domains are renumbered again and this constant
is not updated in the same change, the one-play rule silently applies to the wrong domain.

### 5.7 Lock-on-advance

`handleNext()` is the only route between items. It returns early unless `canAdvance`, and an
`advancedRef` makes the advance idempotent per item. Both guards are load-bearing:

- `canAdvance` uses `hasRealAnswer()`, which treats empty/whitespace strings as unanswered —
  a bare `typedValue !== null` check counted "typed a digit then pressed clear" as answered;
- `advancedRef` exists because the button's `disabled` attribute is a *visual* affordance only:
  a fast double-tap could land a second `pointerdown` before React re-rendered the next item's
  button as disabled, skipping an item.

There is **no back navigation**.

### 5.8 IndexedDB draft and resume

`localDraft.ts` — database `badsq-draft`, store `draft`, written under a **singleton key**.
`setAndPersistDraft()` saves on every change.

**Singleton key consequence:** the draft is per browser origin, not per session. Two tabs of the
same browser will overwrite each other. One child per browser profile at a time.

On load, if a draft exists the app shows the **resume prompt** — "same person continuing, or a
different student?" — spoken aloud as well as displayed. Design §5e states the purpose: it guards
against a shared school computer silently handing Student A's in-progress test to Student B. "Yes"
resumes by progress (onboarding → background → consent → item index); "No" clears the draft and
starts a fresh session.

**Resume triggers on *any* saved draft**, not only one with answered items. Requiring answers meant
a refresh during onboarding/background/consent discarded everything **and** minted a second
`sessions` row — a significant contributor to the abandoned-session count (§10.11).

`currentItemIndex` is persisted **before** branching into a transition screen, so refreshing on a
between-domain screen resumes there rather than replaying the last finished item.

### 5.9 Submission sequence — ordering is load-bearing

`handleSubmit()`:

1. Iterate items in order. **Skip demo items** (`isDemoItem` — trailing `.0`).
2. For each response with an audio blob: `uploadParticipantAudio()` → `badsq-audio` at
   `<session_id>/<response_client_id>.<ext>`.
3. Build `responsesPayload` including the returned `audio_storage_path`.
4. One RPC: `submit_session(p_session_id, p_participant, p_responses, p_consent)`.
5. On success: `clearDraft()`, phase `complete`.
6. On any failure: **the draft is deliberately not cleared**; phase `submit-error` with retry.

**Why audio first:** the RPC needs the storage path to create `audio_recordings` rows in the same
transaction. **Why retry is safe:** `uploadParticipantAudio()` treats a duplicate-object error
(HTTP 409 / "already exists") as success, so a retry after partial upload does not fail forever.

**Atomicity:** `submit_session()` is one transaction — participant, consent, all responses, all
audio rows, session status. All or nothing.

### 5.10 Completion screen

Shows a thank-you and **the `assigned_code`**, with instructions to tell the teacher so it can be
written on the paper form.

**Why at the end rather than session start:** rationale not documented in the repository. The
observable consequence is that a session abandoned before submit never surfaces its code, so its
paper form cannot be linked — consistent with, but not evidence for, a deliberate choice.

---

## 6. Researcher flow

### 6.1 Authentication

`signInWithPassword()`. **Divergence from design [flagged]:** the design draft §5c/§5d specifies
magic-link. Phase 3 replaced it, and the reason *is* documented in `supabaseClient.ts`: outbound
email broke twice — an SMTP rate limit in Phase 1, then a "Failed to fetch" that turned out to be
the Supabase project auto-pausing after 7 days idle on the Free plan.

There is **no sign-up path, and none should be added** — accounts are created in the dashboard by a
human. Allowlist membership is *not* checked at sign-in and cannot be: `researchers` is readable
only by an already-allowlisted user. Authorization is decided afterwards by
`loadResearcherProfile()` and enforced for real by RLS.

### 6.2 Item Bank Editor and the versioning model

Editing calls `save_item_version(p_old_item_id, p_item, p_options)`, which inserts a **new** row
with `version + 1`, re-inserts the options, and sets the old row `active = false`.

**Why versions rather than in-place mutation:** completed sessions reference the exact `items.id`
they were shown. Mutating a row would retroactively change what a past participant saw. "Delete" is
always soft (`active = false`); rows are never removed (design §5f, and observable in the code).

Options are inserted with `WITH ORDINALITY` so the editor's on-screen array order becomes
`display_order` — added in 0023 so that re-editing an item cannot silently destroy option ordering.

### 6.3 Activation guards (`itemValidation.ts`)

An item cannot be set `active = true` while any blocker applies. Each has a documented reason:

| Blocker | Reason (from the source) |
|---|---|
| `REPLAYABILITY_UNDECIDED` | `is_stimulus_replayable` NULL leaves TestRunner with no answer to "may this be replayed?", and behaviour would silently differ from the documented method. |
| `NO_ANSWER_KEY` | Client half of the migration 0005 scoring fix: a scored auto-graded item with no key used to mark **every** student wrong, silently depressing a domain score. |
| `DUPLICATE_OPTION_TEXT` | Three items in an earlier draft had character-identical options that visual proofreading missed; with Bangla conjuncts this is genuinely hard to see by eye, so the check must be mechanical. Normalises NFC and strips ZWJ/ZWNJ/BOM. |
| `BLANK_OPTION_TEXT` / `TOO_FEW_OPTIONS` | A choice item that cannot be answered. |
| `MISSING_ITEM_CODE` / `MISSING_DOMAIN` | — |

Warnings (non-blocking): missing instruction audio; `AUDIO_RECORD` not `human_rated`; more than one
option marked correct.

### 6.4 Item audio upload and playback

Researchers upload to `badsq-item-audio` (`can_manage_items()`). Participants and researchers both
play via **signed URLs** (`signedItemAudioUrl`, 1-hour default) — the bucket is not public.

### 6.5 Rating queue

Loads every `audio_recordings` row with its item, reference answer, and participant. A reviewer
plays the clip and records `correct` / `incorrect` / **`unclear`**.

`submitAudioVerdict()` writes `primary_verdict`, keeps `primary_rating` in sync as a two-state
projection (`unclear` → NULL), stamps `primary_rater_id`/`primary_rated_at`, and sets
`rating_status = 'rated'`. Re-rating overwrites — the latest verdict is what is stored.

**How a rating propagates to `responses`: it does not.** See §3.6 and §9. The verdict reaches the
analyst only through the export column `audio_review_verdict`.

### 6.6 Reliability subsample

`is_reliability_subsample` is assigned **automatically and randomly at submission time** inside
`submit_session()`: `(random() < reliability_subsample_rate())`, currently `0.20`.

**Why automatic and random:** Phase 4 changed this from rater-chosen precisely so the Cohen's kappa
the study commits to reporting is not biased by which recordings a rater happened to pick
(`README.md` §Current phase). The RatingQueue checkbox is a manual **override** on that baseline,
not the assignment mechanism.

**The second-rater half now exists** (0026). `RatingQueue` has a second-rating pass listing only
recordings that are in the subsample, already primary-rated, rated by *someone else*, and not yet
second-rated. The distinct-rater rule is also a CHECK constraint, not just a query filter.

**The blinding is the point, and it lives in the query.** `listSecondRatingQueue()` deliberately
does not select `primary_verdict`, `primary_rating`, `notes` or participant identity, and
`RecordingCard`'s `mode="second"` hides the note editor and the subsample toggle. Those columns
are readable by the role, so the blinding is a property of what the code asks for — anyone
extending this must keep it that way, or the coefficient measures compliance with a colleague
rather than agreement about the audio.

Agreement itself is **not** computed here. Both verdicts reach `full_export_v1` as
`audio_review_verdict` and `audio_second_verdict`, over the same three categories, and
three-category agreement is an analysis step.

### 6.7 Admin views

- **ParticipantsView** — roster by `anonymized_code` only; grade, age (years), gender, session
  status, response count, recording count with a pending badge. Rows expand to play and rate that
  participant's recordings inline, reusing `RecordingCard`.
- **HealthView** — counts, plus both CSV exports (§9.3).
- **RatingQueue** — filtered card list with progress counters.

---

## 7. Scoring

### 7.1 Nothing is scored automatically. At all.

`submit_session()` inserts `is_correct = NULL, scored_by = NULL` for **every** response of
**every** format. The function's own comment states: "CHANGED IN 0012: no scoring here for any
format." **[verified in the live function body]**

History: 0001–0011 auto-scored MCQ/Binary/Numeric at submit; migration 0010 stopped it for
`AUDIO_RECORD`; **migration 0012 removed it for all formats** and backfilled existing rows to NULL.

`scoring_mode` and `is_scored` survive as *authoring metadata* — they drive the editor's
answer-key blocker and tell an analyst which items have a key worth using — **not** as live
behaviour.

### 7.2 Human rating

The only correctness judgment the system records is a researcher's verdict on an `AUDIO_RECORD`
clip, stored on `audio_recordings.primary_verdict`. It never touches `responses`.

### 7.3 Items lacking an answer key

They are left unscored rather than marked incorrect. The reason is documented in
`itemValidation.ts`: a scored auto-graded item with no key used to mark **every** student wrong,
silently depressing that domain's score. Migration 0005 made the server leave such responses
unscored; the activation blocker stops the item reaching participants in the first place. Since
0012 the server-side half is moot — nothing is scored — but the guard remains correct.

### 7.4 Export assembly

**`full_export_v1`** (`security_invoker = true`) — one row per response, 43 columns: participant
demographics, the three consent answers, item identity, the raw answer, audio metadata,
`audio_marked_correct` (boolean) and `audio_review_verdict` (tri-state), both latencies, both
anchors, modality, viewport, replay counts, session timestamps. Filters `is_superseded = false`.
`is_correct`, `scored_by` and `age_months` were **dropped** in 0023 as permanently-NULL columns.

**`participant_summary_v1`** (0022) — one row per participant: demographics, consent, session
minutes, totals, audio verdict tallies, then per-subdomain `answered` / `mean_latency_ms` /
`replays`. Summaries per subdomain rather than one column per item, so the column set survives
item-bank edits.

`downloadFullExportCsv()` additionally mints a **signed URL per recording**, valid for **30 days**
(`EXPORT_AUDIO_URL_EXPIRY_SECONDS`), reduced from a 10-year horizon when retention became 90-day
deletion (0027). A link must never outlive the file it points at, and a shorter window also limits
how long a leaked CSV remains a working bearer credential to a child's voice.

**`downloadParticipantSummaryCsv()` builds a wider file than the view.** It fetches the aggregates
from `participant_summary_v1` and pivots per-item answers, option text, audio verdicts and
latencies onto each participant's row client-side — driven by the items present in the data, so an
edited item bank changes the columns with no migration. It selects only the eight columns the
pivot reads rather than all 49, which matters at 1000 participants × 77 responses.

---

## 8. Failure modes

| # | Failure | Behaviour | Data lost? | Recovery |
|---|---|---|---|---|
| 8.1 | **Network lost mid-test** | No server writes happen during the test, so answers are safe. But each item fetches a signed audio URL; offline, that fails and the item stays locked behind the audio gate. There is **no automatic retry and no offline detection** (`navigator.onLine` is unused **[verified]**) — the child sees the audio-failure alert, which names the wrong cause. | No | Reload once connectivity returns; the draft resumes. |
| 8.2 | **Network lost at submit** | `catch` → phase `submit-error`, draft **not** cleared, "Try submitting again" button, error text shown. | No | Retry. Safe: duplicate uploads return 409 which is treated as success; the RPC is atomic. |
| 8.3 | **Audio uploaded but RPC fails** | Orphan objects in `badsq-audio` with no `audio_recordings` row. Retry re-uploads to the same deterministic path, hits 409, proceeds. | No | Retry. **Orphans are never cleaned up** — 3 such files exist from Aug 2026 **[verified]**, belonging to sessions that no longer exist. |
| 8.4 | **Tab/browser closed mid-session** | Draft persists in IndexedDB. | No | Reopen → resume prompt → continue. Even at the submit-error screen, resume lands back on `ready-to-submit`. |
| 8.5 | **Different student on a shared device** | Resume prompt asks explicitly, in Bangla and aloud. | Only if mis-answered | "No, new student" clears the draft and starts a fresh session. **This is a human safeguard, not a technical one** — tapping "Yes" appends Student B to Student A's draft. |
| 8.6 | **Two tabs, same browser** | The draft is a **singleton key**, so the tabs overwrite each other. | **Yes — silently** | Not detected, not guarded. Enforce one child per browser profile. |
| 8.7 | **Microphone denied/unavailable** | Permission is now requested up front on the onboarding screen, non-blocking. At an `AUDIO_RECORD` item, `AudioRecord.tsx` raises a specific message for `NotAllowedError`, `NotFoundError`, and for a non-HTTPS context (`navigator.mediaDevices` undefined). | Session cannot complete | With the hard no-skip gate, the child **cannot pass an audio item without recording**. Restart on a working device. |
| 8.8 | **Item audio fails to load** | Two detectors: the signed-URL fetch and the `<audio>` `onError`. Both surface a red alert naming the item code and the exact failing path, in Bangla for the child and English for the researcher. The item stays locked. | No | Fix the path in the Item Bank Editor. **Every active item's path currently resolves** **[verified]**. |
| 8.9 | **Unsupported audio codec** | `pickSupportedAudioMimeType()` probes `MediaRecorder.isTypeSupported()` rather than assuming; if nothing is supported it throws "This device does not report support for any audio recording format." | Session cannot complete | Different browser/device. **Never exercised on real iOS hardware** (§10.4). |
| 8.10 | **Supabase paused or unreachable** | Initial load `catch` → phase stays `loading` with "Could not load the test: {error}" — **English, technical, and participant-facing**. | No (nothing started) | Resume the project. Free-tier projects auto-pause after 7 days idle — this has bitten this project before (§6.1). |
| 8.11 | **RLS denial reaches a user** | Surfaces as a raw PostgREST error string in whichever screen triggered it. No friendly mapping exists. | No | Diagnose from the message. |
| 8.12 | **Double submission** | `submit_session()` requires `status = 'in_progress'`; a second call raises "Session not found, not owned by caller, or already submitted". | No | Expected and safe. **G8:** that one message conflates four distinct causes, and there is no server-side `RAISE LOG` distinguishing them, so a field failure cannot be diagnosed from logs. |
| 8.13 | **Session with NULL `assigned_code`** | Only possible via direct INSERT (G6). `submit_session()` rejects it — after a full battery has been completed. | **Yes, effectively** | Use `start_session()`. The `sessions_insert_own` policy that permits this was never removed. |
| 8.14 | **Item edited mid-session** | The participant keeps the version fetched at load; responses reference that `items.id`. The edit creates a new version and retires the old — the old row still exists, so the FK holds. | No | Working as designed. |
| 8.15 | **Storage quota exhausted** | Upload fails → `submit_session()` never runs → phase `submit-error`, draft retained. | No | Free space, retry. Design §5b estimates ~1.2 GB baseline / 3–5 GB with margin for 1000 participants. |

---

## 9. Defect history

Preserved so a maintainer does not reintroduce these. Details are **[reported]** from the phase
reports; current state is **[verified]** where noted.

### 9.1 F1–F7 (migrations 0001–0003, fixed by 0004)

| ID | Defect | Root cause | Fix |
|---|---|---|---|
| **F1** | Item bank unreadable by *everyone* (HTTP 401 `42501`). | `security_invoker = on` makes Postgres check base-table **privileges** against the caller, so `revoke select on items` disabled the replacement view too. | Views made SECURITY DEFINER (§3.2). |
| **F2** | **All** user creation failed, HTTP 500. | `link_researcher_on_signup()` DEFINER with no `SET search_path`; GoTrue connects as `supabase_auth_admin` with `search_path=auth`, so unqualified `researchers` did not resolve. Reproduced by setting the same path. | Pin `search_path`. Became a schema-wide invariant. |
| **F3** | `ml_snapshots` world-writable — the whole flattened export readable, injectable and deletable with the shipped key. | Created in 0001, omitted from 0002's RLS list, default grants never trimmed. Proven over HTTP: POST 201, GET 200, DELETE 204. | RLS + researcher-only policy. |
| **F4** | Audio ratings silently never reached `responses` — "1 row affected", looked like success. | `propagate_audio_rating()` was SECURITY INVOKER; `responses` had no UPDATE policy, so the inner update was RLS-filtered to zero rows — and an RLS-filtered UPDATE raises no error. | Made DEFINER. **Now moot: the function is a deliberate no-op (§3.6).** |
| **F5** | `ml_export_v1` silently lost the `from_first` latency anchor. | Renaming a base column rewrites a view's internal reference but does **not** rename its output column; the view was never recreated. | Recreate the view. Led to the drift gate (§9.4). |
| **F6** | No participant could upload audio. | The storage policy's subquery read `sessions`, which participants could not SELECT (F7) — so the predicate was always false. | Add the participant SELECT policy. |
| **F7** | Participants could not read their own `sessions` row. | Only a researcher SELECT policy existed. | `sessions_select` with `auth_uid = auth.uid() OR is_researcher()`. |

### 9.2 G1–G10 (found in 0004; G1–G3, G5–G8 fixed by 0005)

| ID | Defect | Status |
|---|---|---|
| **G1** | Audio column rename never reached `public_items` — client got `42703`. Second occurrence of the F5 class. | Fixed 0005. |
| **G2** | `consent_records.assigned_code` had no referential integrity; a typo during digitization silently orphaned a participant from the criterion sample. | Fixed 0005 (FK). |
| **G3** | Three RLS helper functions still had mutable `search_path` — the functions *every* policy calls. | Fixed 0005. |
| **G4** | The two `security_definer_view` ERRORs — **intentional**, independently verified rather than taken on trust (§3.2). | Not a defect. |
| **G5** | `propagate_audio_rating()` became publicly callable as an RPC when made DEFINER. | Attempted 0005 → **incomplete, became H1**. |
| **G6** | Sessions created by direct INSERT are permanently unsubmittable. | Partially addressed; the permissive policy remains (§8.13). |
| **G7** | Deleting a researcher's auth account blocked by FK (`23503`). | **Open** — operational. |
| **G8** | `submit_session()`'s rejection message conflates four causes, with no server-side logging. | **Open.** |
| **G9** | 0004 does redundant work on `ml_snapshots`; its `drop table` would destroy real snapshot data if re-run. | Noted. |
| **G10** | Theoretical code-generation race; ~1.1×10¹² codes, fails loudly on collision. | Negligible. |

### 9.3 H1, I1, J1

- **H1** — G5's fix revoked EXECUTE from `anon, authenticated`, but the grant they were actually
  using came from **PUBLIC** (`=X/postgres` in the ACL, no role name before the `=`). Revoking from
  roles individually does nothing when the privilege is inherited from PUBLIC. Fixed in 0006.

- **I1** — **participant audio could not be submitted at all.** Found only by a real browser
  walkthrough in Phase 2. The policy's `WITH CHECK` expression evaluated standalone returned
  `true`, and the session row was correct — yet the INSERT failed `42501`. Bisection isolated the
  single variable: **a `RETURNING` clause**. `INSERT` alone succeeded; `INSERT ... RETURNING`
  (which supabase-js uses) additionally requires a **SELECT** policy, which `badsq-audio` lacked.
  Fixed in 0007. Phase 4 additionally removed `upsert: true` as defence in depth.

- **J1** — `reliability_subsample_rate()`, added in 0008, was the first function since Phase 1 to
  ship without the pinned `search_path` the whole schema carries. Found by re-running advisors
  after 0008. Assessed as not currently exploitable (SECURITY INVOKER, body is a literal), fixed in
  0009 anyway to restore the invariant.

### 9.4 The recurring pattern, and the structural guard

Phase 4 names it explicitly: **F1/G5 → H1 → I1 → J1**, four occurrences across four phases of one
shape —

> "a fix or an addition that is correct in the case actually tested, but misses a hardening
> property everything else in this project carries."

The **view-column-drift release gate** (`scripts/check_view_drift.sql`) is the structural answer to
the F5/G1 instance. For every view in `public`, every output column must resolve to a real base
column the view actually depends on — read from `pg_depend`, not by parsing SQL — or be explicitly
allowlisted, "which turns a silent drift into a reviewed, documented decision." It self-tests
inside `verify_security.sql` by creating a deliberately drifted view: "A gate that has never been
shown to fail is not a gate."

Its stated limitation: it catches renames and typos, not a view whose output keeps a valid
base-column *name* while pointing at a different column of that name.

🔴 **The gate is currently non-functional.** Run live on 2026-09-15 it returns **72 DRIFT rows**
**[verified]** — `participant_summary_v1` 63, `full_export_v1` 8, `public_items` 1 — all legitimate
aliases introduced by migrations 0011, 0017 and 0022 and never added to the one-entry allowlist. A
real drift would be invisible in that noise. **Fix the allowlist before trusting this gate again.**

---

## 10. Verification

### 10.1 What exists

| Suite | Layer | Recorded result |
|---|---|---|
| `scripts/verify-security.mjs` | Real HTTP as `anon`, using only the shipped publishable key | 30 assertions, 30 passed **[reported, after 0009]** |
| `scripts/verify_security.sql` | RLS/policy layer via role + `request.jwt.claims` impersonation; 15 parts, rebuilds its own fixtures | 84 assertions, 84 passed **[reported, after 0009]** |
| `scripts/check_view_drift.sql` | Standing release gate | See §9.4 — currently 72 false positives **[verified]** |

Run: `node scripts/verify-security.mjs`; the SQL suites as `postgres` in the SQL editor.

There is **no unit or integration test suite** — no test runner, no test files **[verified]**.
`npm run lint` reports 8 warnings, all the accepted `react/set-state-in-effect` pattern.

### 10.2 The blind spot that was found and closed

The SQL suite's storage assertions were **rewritten in Phase 3 specifically because they did not
catch I1**: they tested a bare `INSERT`, where the real failure only appears on
`INSERT ... RETURNING`. Every storage assertion now uses `RETURNING`. This is the single most
instructive lesson in the repository — *test the statement shape the client actually sends.*

`verify-security.mjs`'s storage checks were left unchanged because they only ever tested anon-key
denial, never a signed-in participant's own upload, so they never had this blind spot.

### 10.3 The SQL suite was stale — rewritten as v7 (2026-09-16)

`scripts/verify_security.sql` had been failing on every run for **correct** reasons: written
before migrations `0010` and `0012`, it still asserted that responses are scored inline and that
a human audio rating propagates into `responses.is_correct`. Both were deliberately removed. A
suite that always fails cannot distinguish a real regression from its own backlog — the same trap
`check_view_drift.sql` was in.

Rewritten rather than patched:

| Part | Change |
|---|---|
| 7 | Four `scored_by = 'system'` assertions replaced by one block proving **nothing** is scored for **any** format — and singling out the case where the answer **matches** the key. A matching answer coming back NULL is the actual proof no scoring path survives. |
| 8 | Inverted: a human verdict **must not** touch the responses row. |
| 5 | Tested `ml_export_v1`/`ml_snapshots`, dropped in 0025. Rewritten against `full_export_v1` / `participant_summary_v1`. |
| 4 | Two assertions counted **every** row in `public_items` and expected 8 — true only while the item bank was empty. Scoped to fixtures. |
| 12 | Drift-gate mirror carried one allowlist entry against 75 live aliases. Regenerated. |
| 16 | **New.** 18 assertions over 0021–0027: `security_invoker`, the answer key resolving through the view, row-doubling constraints, second-rater rules, retention. |
| 17 | **New.** Teardown. |

Two defects in the suite itself, both found only by running it:

1. **It was destructive.** PART 1's cleanup did
   `delete from consent_records where assigned_code like 'BADSQ-%'`. Every real participant code
   starts with `BADSQ-`, so running the suite against a live database would have silently deleted
   every real consent record. Scoped to fixture identities.
2. **It never tore down.** It cleaned up at the *start* of a run and left fixtures behind at the
   end, so any database that had ever run it permanently held fixture participants, sessions and
   responses — rows indistinguishable from real data in both CSV exports. PART 17 now deletes them
   and asserts that it worked.

**Verified 2026-09-16 [verified]:** PARTS 1–8, 16, 17 executed against the live database —
**66 assertions, 66 passed, 0 failed**, teardown confirmed to leave zero fixture rows. PARTS 9–15
were **not re-executed in that session**; they are unchanged v6 code apart from PART 12's
regenerated allowlist. Run the file end to end to confirm all 107, and record the real number —
do not carry one forward from an older report.

### 10.4 What remains untested, and why

- **Real iOS Safari and real Android hardware.** All client audio testing was done in **Chromium
  with simulated/fake media devices** — Phase 5 states the checkbox for "Physical iOS / Android
  Audio Hardware Testing" is **unchecked** and deferred to field deployment. The MP4/AAC path has
  never run on real hardware.
- **Real microphone hardware** — same.
- **Browser automation** used local Edge Chromium via `playwright-core`.
- **Live-verified paths** **[reported, Phase 5]**: same-device resume (interruption, IndexedDB
  restore, "Yes, continue", "No, new student" reset) and stimulus replay with dual latency anchors.
- **Never exercised live:** the second-rater flow (does not exist), the analysis tables, the
  retention/deletion mechanism, and every change made after Phase 5 — including the two-step audio
  gate, the audio mutual-exclusion lock, the tri-state verdict, and both new export views. Those
  are **[inferred from code]** only, with build/typecheck/lint as the sole gate.

---

## 11. Operations

### 11.1 Setup

```bash
npm install
cp .env.example .env     # fill in URL + publishable key
npm run dev
```

| Variable | Purpose |
|---|---|
| `VITE_SUPABASE_URL` | Project URL. |
| `VITE_SUPABASE_PUBLISHABLE_KEY` | Publishable (anon) key. Ships in the bundle by design. |
| `VITE_SUPABASE_AUDIO_BUCKET` | Optional; defaults to `badsq-audio`. |

⚠️ **Never put a `service_role` key in `.env`** — Vite inlines every `VITE_*` variable into the
client bundle.

⚠️ **`.env.example` currently contains a real project ref and a real publishable key** and is
committed. The key is public by design, so this is not a credential leak, but the file is a
*template* and anyone cloning the repo silently targets production.

### 11.2 Migrations

Apply in order (`supabase migration up`, or paste into the SQL editor).

| # | What it does |
|---|---|
| 0001 | Tables, versioned item bank, rating trigger, `ml_export_v1`. |
| 0002 | RLS for participants and allowlisted researchers. |
| 0003 | Circular-FK removal, dual latency anchors, answer-key views, storage bucket + policies, atomic `submit_session()`, indexes. |
| 0004 | Fixes F1–F7; item-audio bucket; server-issued codes (`start_session()`); paper-consent linkage. |
| 0005 | Fixes G1–G3, G5–G8 and the NULL-answer-key scoring hazard; FK on the consent join key. |
| 0006 | Closes H1; atomic `save_item_version()`; consolidates `sessions`' SELECT policies. |
| 0007 | Closes I1 (missing SELECT policy broke `INSERT…RETURNING`); `auth_rls_initplan`; `selection_change_count`. |
| 0008 | Automatic random reliability subsample (20%) at submit. |
| 0009 | Closes J1 (`search_path` on `reliability_subsample_rate()`). |
| 0010 | `audio_recordings.notes`; **neuters `propagate_audio_rating()`**; backfills `scored_by='human'` → NULL. |
| 0011 | `age_years`/`gender`/`home_area`; `domain_intros`; nullable replay counts; `submit_session(p_consent)`; `full_export_v1` with `security_invoker = true`. |
| 0012 | **Removes all inline scoring** for every format. |
| 0013 | `FLASH_JUDGMENT`, `LETTER_SPAN`; `audio_marked_correct` in the export. |
| 0014 | `is_scored = false` for the raw-data-only domains; semantic `option_key` tokens; 2.3/3.1–3.4 → `AUDIO_RECORD`. |
| 0015 | Reverts Domain 3 to typed/tapped response. |
| 0016 | **Domain renumbering** (1↔4, 3↔4 rotation); letter grid; graded spans; content corrections. |
| 0017 | `public_items.practice_correct_answer` (demo items only). |
| 0018 | Domain 1 demo intros. |
| 0019 | Per-subdomain practice items + intros; 2.3 back to `NUMERIC_KEYPAD`; `display_order` rebuild. |
| 0020 | Normalises `is_instruction_replayable` drift on three items. |
| 0021 | `primary_verdict` tri-state; `audio_review_verdict` in the export. |
| 0022 | `participant_summary_v1`. |
| 0023 | `item_options.display_order` + backfill; `save_item_version` ordinality; drops three empty export columns. |
| 0024 | Retires all 17 subdomain intro screens (`active = false`, text preserved). |

⚠️ **`README.md` documents only 0001–0009** and describes the project as "Phase 4". It is stale by
fifteen migrations.

### 11.3 Dashboard settings that cannot be migrated

1. **Authentication → Providers → Anonymous Sign-ins: enabled.** Without it the participant flow
   cannot start; `ensureAnonymousSession()` raises a message saying exactly this.
2. **Researcher accounts**: Authentication → Users → Add user (real email + password). The email
   must already exist in `researchers`, or the linking trigger will not fire (§3.7).
3. **Leaked Password Protection** — currently **disabled**; flagged by the security advisor
   **[verified]**.
4. **Plan**: design §5b argues the Free tier is not viable for a live study — the 7-day inactivity
   pause alone rules it out — and recommends Pro. Current plan not verifiable from the repository.

### 11.4 Deployment

Static SPA. Build `npm run build`, output `dist`. Set the three env vars in the platform dashboard,
never in a committed file. `vercel.json` / `netlify.toml` add only headers: `X-Frame-Options: DENY`,
`X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`, a `Permissions-Policy` allowing
the microphone for this origin only while denying camera and geolocation, and HSTS.

**Microphone requires HTTPS** (or localhost) — a browser rule, not configurable. Testing a phone
against a laptop dev server over `http://<lan-ip>:5173` is the documented way to break it.

### 11.5 Exporting data

Admin → Health → two buttons: response-level and participant-level CSV. Both paginate at 1000 rows.
The response-level file mints a signed audio URL per recording.

### 11.6 Backup posture

No automated backup or independent export exists in this repository. Design §5g lists "verify
Supabase Pro's actual backup/PITR inclusion directly; maintain independent periodic export
regardless" as an **unchecked** pre-build item. **Nothing in the repo shows it was done.**

### 11.7 🔴 Audio retention and the consent commitment

The parental consent form commits to audio being "নিরাপদে সংরক্ষণ করা হবে" (stored securely) and not
shared outside the research team. The design draft and 0001 both describe `audio_recordings` being
separated from `responses` specifically "so a recording can be **deleted post-study** (per the
parental consent commitment) while the derived score persists."

**State of that mechanism: implemented as of 0027 (2026-09-16).** Audio is destroyed **90 days
after upload**.

- `scheduled_deletion_at` defaults to `uploaded_at + 90 days`; pre-existing rows were backfilled
  from their own upload time, not from the migration date.
- Deletion runs from **HealthView**, via `deleteExpiredAudio()`. It goes through the **Storage
  API**, not by deleting `storage.objects` rows — that is how this project produced orphaned blobs
  before, and an orphaned blob is a file a parent was told no longer exists.
- `deleted_at` is stamped **only** for rows whose file the API confirmed removed. A row marked
  deleted while its file survives would report the commitment as kept when it is not.
- The `audio_recordings` row is kept forever. The verdict, latency and item linkage are the
  research data and outlive the audio by design — which is the whole reason this table is separate
  from `responses`.

**It is deliberately manual, and nothing runs on a schedule.** `pg_cron` and `pg_net` are
available on the project but uninstalled; automating this would mean holding a privileged key
inside the database of a study collecting minors' data. So the commitment depends on someone
performing the step — it belongs in the project calendar, not only in code.

⚠️ **The operational hazard this creates:** a recording deleted before it is rated is data lost
permanently, and the reliability subsample now needs *two* passes, both inside 90 days. HealthView
warns specifically about recordings falling due that are still unrated or missing their second
rating.

The consent form itself is not in the repository, so the code cannot confirm the two agree —
matching the form to 90-day audio deletion plus indefinite retention of derived data remains a
researcher task.

### 11.8 Known operational debt

- **29 sessions stuck `in_progress`**, oldest open 431 hours **[verified]**. Nothing sets
  `abandoned`; no cleanup exists. Every session-level average degrades as these accumulate.
- **3 orphaned audio objects** in `badsq-audio` from sessions that no longer exist **[verified]** —
  unreferenced voice recordings of minors that no retention logic can reach.
- **`database.types.ts` is hand-patched.** It carries a manual fix (`save_item_version`'s
  `p_old_item_id` is nullable; the generator emits it as non-null) that regeneration will silently
  destroy. Re-apply it after every regeneration — the file's own header says so.
- **Unindexed foreign keys (10)** and overlapping SELECT policies on `item_options` — performance
  advisories, low impact **[verified]**.
