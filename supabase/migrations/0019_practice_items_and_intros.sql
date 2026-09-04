-- 0019: per-subdomain practice items + instruction screens, 2.3 format fix,
-- and a full display_order rebuild.
--
-- Architecture split, matching what already exists:
--   * The instruction PARAGRAPH for each subdomain -> domain_intros (shown at
--     the subdomain boundary, no time/latency tracking at all).
--   * The practice ATTEMPT -> an item whose code ends ".0" (is_practice), which
--     TestRunner never submits (see isDemoItem in TestRunner.tsx).
-- So the participant sees: instruction screen -> practice item -> real items.
--
-- All new practice items are created INACTIVE -- the researcher uploads the
-- stimulus audio and activates them afterward.

-- ---- 1. 2.3 Syllable Segmentation: back to a typed number ---------------
-- Migration 0014 moved this to AUDIO_RECORD along with the other Domain 2
-- subdomains. The revised questionnaire (and 2.3.0's own instruction text --
-- "নিচে নাম্বার-বাটন থাকবে, সঠিক সংখ্যায় চাপ দিও") makes clear the answer is a
-- syllable COUNT typed on the keypad, not a spoken response.
update items set response_format = 'NUMERIC_KEYPAD', scoring_mode = 'auto', is_scored = true
where item_code like '2.3.%';

-- ---- 2. practice items (inactive) --------------------------------------
insert into items (item_code, version, domain, subdomain, response_format, scoring_mode,
  correct_answer, stimulus_text, is_instruction_replayable, is_stimulus_replayable,
  is_practice, is_scored, active, display_order)
select v.item_code, 1, v.domain, v.subdomain, v.response_format, v.scoring_mode,
  v.correct_answer, v.stimulus_text, v.instr_replay, v.stim_replay, true, false, false, 0
from (values
  -- Domain 1: no replay at all (one play only), stimulus is audio-only
  ('1.1.0', '1', '1.1 Digit Span Forward',      'NUMERIC_KEYPAD', 'auto', '518',    null,                                                    false, false),
  ('1.3.0', '1', '1.3 Letter Span Forward',     'LETTER_SPAN',    'auto', 'কতপ',    null,                                                    false, false),
  -- Domain 2
  ('2.1.0', '2', '2.1 Elision',                 'AUDIO_RECORD', 'human_rated', 'বই',   '''বইমেলা'' থেকে মেলা বাদ দিলে কী থাকে?',            true, true),
  ('2.2.0', '2', '2.2 Pseudoword Judgment',     'BINARY_TAP',   'auto',        'match', 'মেঘ',                                              true, true),
  ('2.3.0', '2', '2.3 Syllable Segmentation',   'NUMERIC_KEYPAD','auto',       '3',     '''জানালা'' শব্দে কয়টি সিলেবল আছে?',                true, true),
  ('2.4.0', '2', '2.4 Blending',                'AUDIO_RECORD', 'human_rated', 'গোলাপ', 'গো + লা + প',                                      true, true),
  ('2.5.0', '2', '2.5 Onset/Coda Matching',     'MCQ_TAP',      'auto',        'A',     'কলম',                                              true, true),
  ('2.6.0', '2', '2.6 Substitution',            'AUDIO_RECORD', 'human_rated', 'মলম',   '''কলম'' শব্দের ''ক'' এর জায়গায় ''ম'' বসালে কী হয়?', true, true),
  -- Domain 3
  ('3.1.0', '3', '3.1 Rhyme Judgment',          'BINARY_TAP',   'auto',        'no',    'মাটি — পানি',                                       true, true),
  ('3.2.0', '3', '3.2 Confusion Self-report',   'LIKERT_5',     'auto',        null,    'আমি সকালে নাস্তা করতে পছন্দ করি',                   false, false),
  -- Domain 4: no stimulus audio by design (visual spelling / flashed word)
  ('4.1.0', '4', '4.1 Multiple Choice',         'MCQ_TAP',      'auto',        'A',     'কোনটি সঠিক বানান?',                                 true, false),
  ('4.2.0', '4', '4.2 Flash Judgment',          'FLASH_JUDGMENT','auto',       'correct','মেঘ',                                              true, false),
  -- Domain 5
  ('5.1.0', '5', '5.1 Spoonerisms',             'AUDIO_RECORD', 'human_rated', 'পাতি হাখি',                'হাতি — পাখি',                    true, true),
  ('5.2.0', '5', '5.2 Jumbled-sentence Reading','AUDIO_RECORD', 'human_rated', 'রাজধানীতে অনেক মানুষ থাকে।','রাধানীজতে অনেক মানুষ থাকে।',     true, false)
) as v(item_code, domain, subdomain, response_format, scoring_mode, correct_answer, stimulus_text, instr_replay, stim_replay)
where not exists (select 1 from items i where i.item_code = v.item_code);

-- ---- 3. options for the choice-format practice items --------------------
insert into item_options (item_id, option_key, option_text, is_correct)
select i.id, o.option_key, o.option_text, o.is_correct
from (values
  ('2.2.0', 'match',      'মিলে যায়',  true),
  ('2.2.0', 'no_match',   'মিলে না',   false),
  ('2.5.0', 'A',          'কালি',      true),
  ('2.5.0', 'B',          'মাটি',      false),
  ('2.5.0', 'C',          'নীল',       false),
  ('2.5.0', 'D',          'আপেল',      false),
  ('3.1.0', 'yes',        'হ্যাঁ',      false),
  ('3.1.0', 'no',         'না',        true),
  ('3.2.0', 'never',      'কখনো না',   false),
  ('3.2.0', 'hardly',     'খুব কম',    false),
  ('3.2.0', 'sometimes',  'মাঝে মাঝে', false),
  ('3.2.0', 'frequently', 'প্রায়ই',    false),
  ('3.2.0', 'always',     'সবসময়',    false),
  ('4.1.0', 'A',          'বই',        true),
  ('4.1.0', 'B',          'বুই',       false),
  ('4.1.0', 'C',          'ভুই',       false),
  ('4.1.0', 'D',          'বঈ',        false),
  ('4.2.0', 'correct',    'সঠিক',      true),
  ('4.2.0', 'wrong',      'ভুল',       false)
) as o(item_code, option_key, option_text, is_correct)
join items i on i.item_code = o.item_code
where not exists (
  select 1 from item_options x where x.item_id = i.id and x.option_key = o.option_key
);

-- ---- 4. instruction screens (domain_intros) ----------------------------
-- 1.1 and 1.3 replace the wording I drafted in migration 0018 with the
-- researcher's own text. 1.2/1.4 keep the 0018 wording -- no replacement was
-- supplied for those two.
update domain_intros set intro_text =
  'এই ধাপে তুমি কিছু সংখ্যা শুনবে, তারপর নাম্বার-বাটনে চাপ দিয়ে ঠিক সেই ক্রমে আবার লিখবে। প্রতিবার সংখ্যা একটু একটু করে বাড়বে, তাই শেষের দিকে একটু কঠিন লাগতে পারে, এটা স্বাভাবিক। মোট চারটা প্রশ্ন আসবে, সবগুলোই উত্তর দিতে হবে। প্র্যাকটিস করি।'
where domain = '1' and subdomain = '1.1 Digit Span Forward';

update domain_intros set intro_text =
  'এবার সংখ্যার বদলে অক্ষর দিয়ে একই খেলা খেলব। কয়েকটা অক্ষর শুনবে, তারপর স্ক্রিনে দেখানো অক্ষরগুলোর মধ্যে থেকে সেই ক্রমে চাপ দিয়ে লিখবে। এখানেও অক্ষরের সংখ্যা একটু একটু করে বাড়বে। প্র্যাকটিস করি।'
where domain = '1' and subdomain = '1.3 Letter Span Forward';

insert into domain_intros (domain, subdomain, intro_text, display_order, active)
select v.domain, v.subdomain, v.intro_text, v.display_order, true
from (values
  ('2', '2.1 Elision', 'এবার তুমি কথা বলে উত্তর দেবে। প্রথমে একটা শব্দ শুনবে, তারপর তোমাকে বলা হবে একটা অংশ বাদ দিয়ে বাকিটা জোরে বলতে। বাটনে চাপ দিয়ে কথা বলবে, তারপর আবার চাপ দিয়ে থামাবে। শুনে নিজের রেকর্ড শুনতে আর আবার বলতে পারবে। চলো প্র্যাকটিস করি।', 20),
  ('2', '2.2 Pseudoword Judgment', 'এবার তুমি একটা শব্দ শুনবে, আর স্ক্রিনে একটা বানান দেখবে। শুনে আর দেখে বলো, দুটো একই কিনা। যদি মিলে যায়, "মিলে যায়" বাটনে চাপ দিও, না মিলে "মিলে না" বাটনে চাপ দিও। প্র্যাকটিস করি।', 21),
  ('2', '2.3 Syllable Segmentation', 'এবার তুমি একটা শব্দে কয়টা অংশ (সিলেবল) আছে, সেটা বলবে। যেমন ''কলা'' শব্দে দুইটা অংশ আছে, ''ক'' আর ''লা''। নিচে নাম্বার-বাটন থাকবে, সঠিক সংখ্যায় চাপ দিও। প্র্যাকটিস করি।', 22),
  ('2', '2.4 Blending', 'এবার তুমি কয়েকটা টুকরো শুনে সেগুলো জোড়া দিয়ে একটা পুরো শব্দ জোরে বলবে, আগের মতোই বাটন দিয়ে। যেমন ''বই'' আর ''মেলা'' মিলিয়ে হয় ''বইমেলা''।', 23),
  ('2', '2.5 Onset/Coda Matching', 'এবার আবার অপশন বেছে নেওয়া, কিন্তু এবার শব্দের প্রথম বা শেষ ধ্বনি মিলিয়ে বলতে হবে। যেমন ''ফুল'' শব্দের প্রথম ধ্বনি ''ফ'', তাই ''ফসল'' শুরু হয় একই ধ্বনি দিয়ে। খেয়াল রেখো, শুধু প্রথম ধ্বনিটা মিলতে হবে, পুরো শুরুটা এক হতে হবে না।', 24),
  ('2', '2.6 Substitution', 'একটা শব্দে একটা ধ্বনি বদলে নতুন শব্দ তৈরি করতে হবে, আবার মাইক ব্যবহার করে। যেমন ''কলম'' শব্দের ''ক'' বদলে ''ব'' বসালে হয় ''বলম''।', 25),
  ('3', '3.1 Rhyme Judgment', 'এবার তুমি দুইটা শব্দ শুনবে বা দেখবে, আর বলবে সেগুলোর মিল (রাইম) আছে কিনা, মানে শব্দ দুইটার শেষটা একরকম শোনা যায় কিনা। যেমন ''রাত'' আর ''ভাত'', দুইটাই ''-আত'' দিয়ে শেষ, তাই এই দুইটার মিল আছে। মিল থাকলে "হ্যাঁ", না থাকলে "না" বাটনে চাপ দিও।', 30),
  ('3', '3.2 Confusion Self-report', 'এই অংশে কোনো সঠিক বা ভুল উত্তর নেই, শুধু তোমার নিজের অভিজ্ঞতার কথা বলো। প্রতিটা বাক্য শুনে বলো এটা তোমার সাথে কতবার ঘটে, কখনো না, খুব কম, মাঝে মাঝে, প্রায়ই, নাকি সবসময়। যেটা তোমার জন্য সত্যি, সেটাই চাপ দিও। প্র্যাকটিস করি।', 31),
  ('4', '4.1 Multiple Choice', 'এবার আমরা বানান নিয়ে খেলব। তুমি একটা প্রশ্ন দেখবে, আর চারটা অপশন, A, B, C, D, থাকবে। যেটা সঠিক মনে হয়, সেটাতে আঙুল দিয়ে চাপ দিও। চলো একটা প্র্যাকটিস করি।', 40),
  ('4', '4.2 Flash Judgment', 'এবার একটা শব্দ স্ক্রিনে কয়েক সেকেন্ডের জন্য দেখাবে, তারপর সেটা মিলিয়ে যাবে। ভালো করে পড়ো, কারণ একবারই দেখানো হবে। তারপর তোমাকে বলতে হবে বানানটা সঠিক ছিল না ভুল ছিল। "সঠিক" বা "ভুল" বাটনে চাপ দিও। প্র্যাকটিস করি।', 41),
  ('5', '5.1 Spoonerisms', 'এবার তুমি দুইটা শব্দ শুনবে, আর তাদের প্রথম ধ্বনি অদল-বদল করে নতুন দুইটা শব্দ জোরে বলবে। যেমন ''দল'' আর ''ঘর'' হয়ে যায় ''ঘল'' আর ''দর''। বুঝেছ? তাহলে শুরু করি।', 50),
  ('5', '5.2 Jumbled-sentence Reading', 'এখন তুমি একটা এলোমেলো করে লেখা বাক্য দেখবে, শব্দের মাঝের অক্ষরগুলো উল্টাপাল্টা করা আছে, কিন্তু প্রতিটা শব্দের শুরু আর শেষ ঠিক আছে। সেটা পড়ে বুঝে, সঠিক বাক্যটা জোরে বলবে। প্র্যাকটিস করি।', 51),
  -- SR gets an instruction screen only -- no practice attempt, per the brief.
  ('criterion', null, 'তুমি প্রায় শেষ করে ফেলেছ! এখন তোমাকে নিজের সম্পর্কে কয়েকটা প্রশ্ন জিজ্ঞাসা করব। এখানেও কোনো সঠিক বা ভুল উত্তর নেই, শুধু তোমার নিজের অভিজ্ঞতার কথা বলবে। প্রতিটা বাক্যের জন্য তিনটা অপশন থাকবে, যেটা তোমার জন্য সত্যি সেটাতে চাপ দিও।', 60)
) as v(domain, subdomain, intro_text, display_order)
where not exists (
  select 1 from domain_intros d
  where d.domain = v.domain and coalesce(d.subdomain, '') = coalesce(v.subdomain, '')
);

-- ---- 5. rebuild display_order so the sequence is strictly serial --------
-- Before this, order was inconsistent: 2.5 sorted BEFORE 2.1 inside Domain 2
-- (19-21 vs 109-112), and the practice items inserted in 0016 collided with
-- the last real item of the preceding subdomain (both at 126 and at 134),
-- making those pairs' relative order undefined. Rebuilt from item_code so
-- position is always domain -> subdomain -> item index, with ".0" practice
-- items first inside their subdomain (0 sorts before 1) and the criterion
-- block last. Spaced by 10 to leave room for future inserts.
with ranked as (
  select item_code,
    row_number() over (
      order by
        case when item_code like 'SR.%' then 9 else split_part(item_code, '.', 1)::int end,
        case when item_code like 'SR.%' then 0 else split_part(item_code, '.', 2)::int end,
        case when item_code like 'SR.%' then split_part(item_code, '.', 2)::int
             else split_part(item_code, '.', 3)::int end
    ) * 10 as new_order
  from (select distinct item_code from items
        where item_code ~ '^([0-9]+\.[0-9]+\.[0-9]+|SR\.[0-9]+)$') c
)
update items i set display_order = r.new_order
from ranked r where r.item_code = i.item_code;
