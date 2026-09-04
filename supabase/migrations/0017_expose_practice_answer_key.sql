-- 0017: Practice items (is_practice = true) need their answer key visible to
-- the participant-facing client for immediate feedback -- real items never
-- do (see src/components/responses/types.ts's module doc comment: "no
-- correct_answer or is_correct field to accidentally pass through").
-- Appending the column at the end preserves every existing consumer; it is
-- NULL for every non-practice item, so this is a strictly additive, safe
-- change -- no real item's answer key leaks.
create or replace view public_items as
select id, item_code, version, domain, subdomain, response_format, instruction_audio_path,
  stimulus_audio_path, stimulus_text, is_instruction_replayable, is_stimulus_replayable,
  is_practice, is_scored, display_order,
  case when is_practice then correct_answer else null end as practice_correct_answer
from items
where active = true;
