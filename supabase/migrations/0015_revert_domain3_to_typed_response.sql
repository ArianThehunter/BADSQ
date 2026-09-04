-- 0015: Domain 3 (Digit/Letter Span) reverts from AUDIO_RECORD back to typed/
-- tapped response. Migration 0014 moved it to AUDIO_RECORD along with 2.3,
-- reasoning it as a spoken-recall task like the phonological-awareness
-- domains -- the researcher has now clarified that was wrong for Domain 3
-- specifically: participants click/tap their answer (numeric keypad for
-- Digit Span, the letter grid for Letter Span), same as the original design.
-- 2.3 (Syllable Segmentation) stays AUDIO_RECORD -- this correction is scoped
-- to Domain 3 only. is_scored was never changed for Domain 3 in 0014 (it
-- wasn't on the no-scoring list), so it's already correctly `true` here --
-- only response_format and scoring_mode need reverting.
update items set response_format = 'NUMERIC_KEYPAD', scoring_mode = 'auto'
where item_code similar to '(3\.1|3\.2)\.%';

update items set response_format = 'LETTER_SPAN', scoring_mode = 'auto'
where item_code similar to '(3\.3|3\.4)\.%';
