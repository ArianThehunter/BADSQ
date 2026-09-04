-- 0014: revised scoring scope + verbal-response domains + semantic option keys
--
-- Three changes, all driven by the researcher's revised design:
--
-- 1. Domains 1.1, 1.2, 2.2, 2.5, 4.1 are marked is_scored = false. They were
--    seeded as auto-scored (`is_scored = true, scoring_mode = 'auto'`), but
--    the design now treats them as raw-response-only, same as the
--    already-unscored 4.2 (Confusion Self-report) and criterion (SR.*)
--    domains. This is enforced client-side too: itemValidation.ts's
--    NO_ANSWER_KEY blocker only fires when `is_scored` is true, so these
--    items no longer need (or block activation on) a marked correct option.
--    Note this does NOT touch responses.is_correct, which migration 0012
--    already made NULL for every format unconditionally -- is_scored here is
--    purely an authoring-time signal for the Item Bank Editor.
--
-- 2. Domains 2.3, 3.1-3.4 (Syllable Segmentation, Digit/Letter Span) switch
--    from typed-response formats (NUMERIC_KEYPAD/LETTER_SPAN) to AUDIO_RECORD
--    with scoring_mode = 'human_rated': the participant speaks the answer
--    aloud rather than typing/tapping it, and a researcher rates the
--    recording later via the Rating Queue (already generic across domains,
--    no admin code change needed). `correct_answer` is left in place as the
--    reference sequence a rater checks the recording against.
--
-- 3. For the fixed-vocabulary choice domains (1.2, 2.2, 4.1, 4.2, criterion),
--    option_key moves from positional letters (A/B/C...) to semantic English
--    tokens shared across every item in that domain, so a CSV export can
--    aggregate response-pattern trends across items without decoding
--    per-item Bangla text or arbitrary letter positions. Existing response
--    rows (a handful of pre-launch test submissions) are relabelled in the
--    same statement so history stays consistent with the new vocabulary.

-- ---- 1. stop scoring these domains -------------------------------------
update items set is_scored = false
where item_code similar to '(1\.1|1\.2|2\.2|2\.5|4\.1)\.%';

-- ---- 2. verbal-response domains switch to AUDIO_RECORD -----------------
update items set response_format = 'AUDIO_RECORD', scoring_mode = 'human_rated'
where item_code similar to '(2\.3|3\.1|3\.2|3\.3|3\.4)\.%';

-- ---- 3. semantic option keys, with response backfill --------------------
-- 1.2 Flash Judgment: A(সঠিক)->correct, B(ভুল)->wrong
update responses set selected_option_key = case selected_option_key when 'A' then 'correct' when 'B' then 'wrong' end
where item_id in (select id from items where item_code like '1.2.%') and selected_option_key in ('A','B');
update item_options set option_key = case option_key when 'A' then 'correct' when 'B' then 'wrong' end
where item_id in (select id from items where item_code like '1.2.%');

-- 2.2 Pseudoword Judgment: A(মিলে যায়)->match, B(মিলে না)->no_match
update responses set selected_option_key = case selected_option_key when 'A' then 'match' when 'B' then 'no_match' end
where item_id in (select id from items where item_code like '2.2.%') and selected_option_key in ('A','B');
update item_options set option_key = case option_key when 'A' then 'match' when 'B' then 'no_match' end
where item_id in (select id from items where item_code like '2.2.%');

-- 4.1 Rhyme Judgment: A(হ্যাঁ)->yes, B(না)->no
update responses set selected_option_key = case selected_option_key when 'A' then 'yes' when 'B' then 'no' end
where item_id in (select id from items where item_code like '4.1.%') and selected_option_key in ('A','B');
update item_options set option_key = case option_key when 'A' then 'yes' when 'B' then 'no' end
where item_id in (select id from items where item_code like '4.1.%');

-- 4.2 Confusion Self-report: A..E -> never/hardly/sometimes/frequently/always
update responses set selected_option_key = case selected_option_key
  when 'A' then 'never' when 'B' then 'hardly' when 'C' then 'sometimes' when 'D' then 'frequently' when 'E' then 'always' end
where item_id in (select id from items where item_code like '4.2.%') and selected_option_key in ('A','B','C','D','E');
update item_options set option_key = case option_key
  when 'A' then 'never' when 'B' then 'hardly' when 'C' then 'sometimes' when 'D' then 'frequently' when 'E' then 'always' end
where item_id in (select id from items where item_code like '4.2.%');

-- criterion (SR.1-6): A(yes-ish)->yes, B(কিছুটা)->little, C(না)->no
update responses set selected_option_key = case selected_option_key when 'A' then 'yes' when 'B' then 'little' when 'C' then 'no' end
where item_id in (select id from items where item_code like 'SR.%') and selected_option_key in ('A','B','C');
update item_options set option_key = case option_key when 'A' then 'yes' when 'B' then 'little' when 'C' then 'no' end
where item_id in (select id from items where item_code like 'SR.%');
