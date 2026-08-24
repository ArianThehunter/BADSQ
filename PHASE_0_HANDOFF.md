# BADSQ Platform — Phase 0 Handoff

Two migration files are included:
- `supabase/migrations/0001_schema.sql` — all tables, the versioned item bank, the audio-rating→response propagation trigger, and the `ml_export_v1` view.
- `supabase/migrations/0002_rls_policies.sql` — Row-Level Security: anonymous participant sessions can only write their own data; researchers (allowlisted by email in the `researchers` table) can read everything and manage the item bank / ratings.

## Setup steps

1. Create a Supabase project on the **Pro plan** (not Free — the 7-day inactivity pause makes Free unusable for a live study; see prior cost analysis).
2. Install the Supabase CLI, then from your project folder:
   ```
   supabase init
   supabase link --project-ref <your-project-ref>
   supabase migration up   # or paste both files into the SQL editor, in order
   ```
3. In the Supabase dashboard → Authentication → Providers, **enable Anonymous Sign-ins**. This is what participant sessions use — no email/password.
4. Pre-populate the `researchers` table with your actual team's emails before anyone tries to log into the admin panel:
   ```sql
   insert into researchers (email, can_rate, can_manage_items) values
     ('researcher1@example.com', true, true),
     ('rater1@example.com', true, false);
   ```
5. Set up magic-link email auth for researcher login (separate from participants' anonymous auth).

## Frontend scaffold (recommended starting point)

Vite + React, not Next.js — this is a single-purpose client-rendered app with no SEO or server-rendering need, and Vite keeps the bundle and dev loop lightweight, matching the "keep it light" requirement.

```
badsq-platform/
  src/
    lib/supabaseClient.ts
    lib/localDraft.ts        # IndexedDB draft read/write for resume
    components/
      responses/             # MCQ_TAP, BINARY_TAP, TRI_TAP, NUMERIC_KEYPAD, LIKERT_5, AUDIO_RECORD
      TestRunner.tsx          # one-item-per-screen sequencer, lock-on-advance
    admin/
      ParticipantsView.tsx
      RatingQueue.tsx
      ItemBankEditor.tsx
      HealthView.tsx
  supabase/migrations/       # the two files above
```

## If handing this to Claude Code or Antigravity, a starting brief:

> Set up a Vite + React project per the structure in PHASE_0_HANDOFF.md. Apply the two Supabase migrations. Build the `TestRunner` component first: one item per screen, audio-first instructions with a replay control, `performance.now()`-based latency capture anchored to the audio `ended` event (not click-to-load), Pointer Events for input modality, lock-on-advance navigation with edit-before-advance, and an IndexedDB-backed local draft for same-device resume with an audio confirmation prompt before resuming (never silently resume — a shared device could belong to a different student). Nothing writes to Supabase until final submit, except the `sessions` row created at start with `status='in_progress'`. Test audio recording on both Chrome/Android and an actual iOS Safari device — they produce different formats (WebM/Opus vs. MP4/AAC) and the code must not assume one.

## Still open (don't lose track of these)

- Domain 4 (rhyme) stimulus replayability was never explicitly decided, unlike Domains 2/3/5 — needs a call before those items are marked `active` in the item bank.
- Everything on the pre-build checklist in the design doc that isn't purely technical (Unicode verification, the four-vs-five-indicators fix, ethics board confirmation) — none of it blocks Phase 0 engineering work, but none of it should be forgotten either.
