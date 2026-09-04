-- 0016: full renumbering + content revision per the latest question-paper
-- changelog. Domain administration order is now:
--   1 Short-term Memory (was domain 3: Digit/Letter Span)
--   2 Phonological Awareness (unchanged)
--   3 Rhyme and Confusion (was domain 4)
--   4 Spelling and Orthographic Processing (was domain 1)
--   5 Whole-word Processing (unchanged)
-- TestRunner/HealthView query items ordered by (domain, display_order) --
-- domain is a plain text column and '1'..'5' already sort correctly
-- lexically, so re-pointing the domain/item_code values is sufficient; no
-- display_order renumbering is needed (those values only order items WITHIN
-- a domain, never across domains).
--
-- IMPORTANT: src/components/TestRunner.tsx's maxAudioPlays() hardcodes
-- `item.domain === '3'` to give Short-term Memory its one-play-only rule.
-- That must be updated to '1' in the SAME deploy as this migration, or the
-- one-play rule would silently jump to Rhyme and Confusion instead.

-- ---- 1. renumber domains (2-step to avoid transient (item_code, version)
-- unique-constraint collisions from the 3-way rotation: old-1 -> new-4,
-- old-3 -> new-1, old-4 -> new-3) ---------------------------------------
update items set
  item_code = 'TMP_' || (case
    when item_code like '3.1.%' then regexp_replace(item_code, '^3\.1\.', '1.1.')
    when item_code like '3.2.%' then regexp_replace(item_code, '^3\.2\.', '1.2.')
    when item_code like '3.3.%' then regexp_replace(item_code, '^3\.3\.', '1.3.')
    when item_code like '3.4.%' then regexp_replace(item_code, '^3\.4\.', '1.4.')
    when item_code like '4.1.%' then regexp_replace(item_code, '^4\.1\.', '3.1.')
    when item_code like '4.2.%' then regexp_replace(item_code, '^4\.2\.', '3.2.')
    when item_code like '1.1.%' then regexp_replace(item_code, '^1\.1\.', '4.1.')
    when item_code like '1.2.%' then regexp_replace(item_code, '^1\.2\.', '4.2.')
  end),
  domain = case domain when '3' then '1' when '4' then '3' when '1' then '4' end,
  subdomain = case subdomain
    when '3.1 Digit Span Forward' then '1.1 Digit Span Forward'
    when '3.2 Digit Span Backward' then '1.2 Digit Span Backward'
    when '3.3 Letter Span Forward' then '1.3 Letter Span Forward'
    when '3.4 Letter Span Backward' then '1.4 Letter Span Backward'
    when '4.1 Rhyme Judgment' then '3.1 Rhyme Judgment'
    when '4.2 Confusion Self-report' then '3.2 Confusion Self-report'
    when '1.1 Multiple Choice' then '4.1 Multiple Choice'
    when '1.2 Flash Judgment' then '4.2 Flash Judgment'
  end
-- Scoped to the known new-style codes, NOT `domain in ('1','3','4')` --
-- legacy D-prefixed historical rows (D1.2, D3.F1, D4.9, etc., all already
-- inactive/superseded) also carry those domain values and would hit no CASE
-- branch above, turning their item_code to NULL. Left untouched here.
where item_code ~ '^(1\.1|1\.2|3\.1|3\.2|3\.3|3\.4|4\.1|4\.2)\.';

update items set item_code = substring(item_code from 5) where item_code like 'TMP\_%';

-- ---- 2. Domain 1 (new) Short-term Memory: new letter grid + graded spans -
-- Grid changes from শ স জ ন ণ ব ভ র to ক খ গ ঘ ত থ প ফ (code change in
-- LetterSpan.tsx, done alongside this migration). No existing audio is
-- attached to any Letter Span item (digit-span items do have real recorded
-- audio and are untouched here), so rewriting correct_answer is a clean
-- content change -- new stimulus audio matching these sequences still needs
-- to be recorded before this subdomain can go live for real participants.
update items set correct_answer = case item_code
  when '1.3.1' then 'খঘথ'
  when '1.3.2' then 'তকফগ'
  when '1.3.3' then 'ঘপখতক'
  when '1.3.4' then 'ফগথকঘপ'
  when '1.4.1' then 'গথফ'
  when '1.4.2' then 'কঘত'
  when '1.4.3' then 'থখপগ'
  when '1.4.4' then 'তফকঘখ'
  else correct_answer
end
where item_code like '1.3.%' or item_code like '1.4.%';

-- No-replay rule: is_stimulus_replayable was already false throughout this
-- content under its old domain number; confirm explicitly rather than rely
-- on inheritance from the pre-renumber state.
update items set is_stimulus_replayable = false, is_instruction_replayable = false
where domain = '1' and item_code ~ '^1\.[1-4]\.';

-- Practice trials for both backward sub-tasks (1.2 Digit Span Backward and
-- 1.4 Letter Span Backward) -- previously verbal-example-only, now a real
-- item the participant answers with immediate feedback (see public_items
-- view change + TestRunner PracticeFeedback in the accompanying code
-- change). display_order sits below the real items in the same subdomain so
-- it appears first. is_scored stays true so it carries a real answer key for
-- the feedback to check against -- it is never included in
-- full_export_v1 scoring interpretation questions since is_practice is
-- exported alongside it for researchers to filter out.
insert into items (item_code, version, domain, subdomain, response_format, scoring_mode, correct_answer,
  stimulus_text, is_instruction_replayable, is_stimulus_replayable, is_practice, is_scored, active, display_order)
select '1.2.0', 1, '1', '1.2 Digit Span Backward', 'NUMERIC_KEYPAD', 'auto', '21',
  null, false, false, true, true, true, (select min(display_order) - 1 from items where item_code like '1.2.%')
where not exists (select 1 from items where item_code = '1.2.0');

insert into items (item_code, version, domain, subdomain, response_format, scoring_mode, correct_answer,
  stimulus_text, is_instruction_replayable, is_stimulus_replayable, is_practice, is_scored, active, display_order)
select '1.4.0', 1, '1', '1.4 Letter Span Backward', 'LETTER_SPAN', 'auto', 'খক',
  null, false, false, true, true, true, (select min(display_order) - 1 from items where item_code like '1.4.%')
where not exists (select 1 from items where item_code = '1.4.0');

-- ---- 3. Domain 2 Phonological Awareness corrections -----------------
update item_options set option_text = 'মাছ' where item_id = (select id from items where item_code = '2.5.1' order by version desc limit 1) and option_key = 'A';
update item_options set option_text = 'জুতা' where item_id = (select id from items where item_code = '2.5.2' order by version desc limit 1) and option_key = 'A';
update item_options set option_text = 'বল' where item_id = (select id from items where item_code = '2.5.3' order by version desc limit 1) and option_key = 'B';

-- Answer key spread from A,A,B to C,D,A -- relabel option_key positions only
-- (never which option is_correct), same reasoning as the 4.1 rebalance
-- below: the on-screen position is shuffled per session regardless, so this
-- is a database bookkeeping change, not a participant-facing one. Each swap
-- goes via an unused 'TMP' key rather than a direct two-way UPDATE, because
-- item_options has a non-deferrable UNIQUE(item_id, option_key) constraint
-- that a direct A<->C swap can transiently violate mid-statement.
update item_options set option_key = 'TMP' where item_id = (select id from items where item_code = '2.5.1' order by version desc limit 1) and option_key = 'A';
update item_options set option_key = 'A' where item_id = (select id from items where item_code = '2.5.1' order by version desc limit 1) and option_key = 'C';
update item_options set option_key = 'C' where item_id = (select id from items where item_code = '2.5.1' order by version desc limit 1) and option_key = 'TMP';

update item_options set option_key = 'TMP' where item_id = (select id from items where item_code = '2.5.2' order by version desc limit 1) and option_key = 'A';
update item_options set option_key = 'A' where item_id = (select id from items where item_code = '2.5.2' order by version desc limit 1) and option_key = 'D';
update item_options set option_key = 'D' where item_id = (select id from items where item_code = '2.5.2' order by version desc limit 1) and option_key = 'TMP';

-- 2.5.3's correct option was already B; target is A, so swap A<->B.
update item_options set option_key = 'TMP' where item_id = (select id from items where item_code = '2.5.3' order by version desc limit 1) and option_key = 'A';
update item_options set option_key = 'A' where item_id = (select id from items where item_code = '2.5.3' order by version desc limit 1) and option_key = 'B';
update item_options set option_key = 'B' where item_id = (select id from items where item_code = '2.5.3' order by version desc limit 1) and option_key = 'TMP';

update items set correct_answer = '5' where item_code = '2.3.2';
update items set stimulus_text = 'অ + ভি + ধান' where item_code = '2.4.1';
update items set stimulus_text = 'নাক — ''ন'' এর জায়গায় ''ক'' বসালে কী হয়?' where item_code = '2.6.1';

-- ---- 4. Domain 4 (new) Spelling: answer-key rebalance + one option fix --
-- Rebalances the correct-option-letter distribution from A:3/B:1/C:3/D:3 to
-- A:2/B:2/C:3/D:3 by relabeling which position 4.1.10's correct option sits
-- at (A<->B) -- again a database bookkeeping change only: the runtime
-- shuffle already randomizes on-screen position every session regardless of
-- this label, and no option's text or correctness changes.
update item_options set option_key = 'TMP' where item_id = (select id from items where item_code = '4.1.10' order by version desc limit 1) and option_key = 'A';
update item_options set option_key = 'A' where item_id = (select id from items where item_code = '4.1.10' order by version desc limit 1) and option_key = 'B';
update item_options set option_key = 'B' where item_id = (select id from items where item_code = '4.1.10' order by version desc limit 1) and option_key = 'TMP';

update item_options set option_text = 'নমস্কার'
where item_id = (select id from items where item_code = '4.1.6' order by version desc limit 1) and option_key = 'C';

-- Flash items alternate correct/incorrect: current sequence is
-- C,W,C,W,W,C,C,W (4.2.1-4.2.8) -- swapping items 5 and 6 makes it strictly
-- alternate (C,W,C,W,C,W,C,W). Swapping display_order keeps both items'
-- content untouched.
update items set display_order = case item_code when '4.2.5' then 106 when '4.2.6' then 105 else display_order end
where item_code in ('4.2.5', '4.2.6');

-- ---- 5. Domain 5 Whole-word: item 4 replacement -----------------------
-- NOTE: only the correct/target sentence is updated here. The scrambled
-- stimulus_text this item shows on screen still needs a hand-authored jumble
-- (see the accompanying report -- I did not want to guess at a plausible
-- Bangla letter-scramble for new content without a native speaker's check).
update items set correct_answer = 'সকালবেলা শিক্ষকেরা ছাত্রদের পড়ান।'
where item_code = '5.2.4';
