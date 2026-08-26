/**
 * Item activation guard.
 *
 * Pure functions, no I/O, so they can be reasoned about and tested directly.
 * The Item Bank Editor refuses to set active = true while any blocker applies.
 *
 * These are not stylistic checks. Each one corresponds to a way the instrument
 * has already been observed to fail, or to a decision that is still open:
 *
 *   REPLAYABILITY_UNDECIDED — Domain 4 (rhyme) stimulus replayability was never
 *     decided, unlike Domains 2/3/5. An item that goes live with the flag NULL
 *     leaves the TestRunner without an answer to "may this be replayed?", and
 *     the resulting behaviour would silently differ from the documented method.
 *
 *   NO_ANSWER_KEY — this is the client-side half of the migration 0005 scoring
 *     fix. A scored auto-graded item with no answer key used to mark EVERY
 *     student wrong, silently depressing a domain score. 0005 makes the server
 *     leave such responses unscored instead; this guard stops the item reaching
 *     participants in the first place.
 *
 *   DUPLICATE_OPTION_TEXT — three items in an earlier draft had
 *     character-identical options that visual proofreading missed. With Bangla
 *     conjuncts this is genuinely hard to see by eye, so it must be mechanical.
 *
 *   BLANK_OPTION_TEXT / TOO_FEW_OPTIONS — a choice item that cannot be answered.
 */

export type ResponseFormat =
  | 'MCQ_TAP'
  | 'BINARY_TAP'
  | 'TRI_TAP'
  | 'NUMERIC_KEYPAD'
  | 'LIKERT_5'
  | 'AUDIO_RECORD';

export type ScoringMode = 'auto' | 'human_rated';

export type DraftOption = {
  option_key: string;
  option_text: string;
  is_correct: boolean;
};

export type DraftItem = {
  item_code: string;
  domain: string;
  subdomain: string | null;
  response_format: ResponseFormat;
  scoring_mode: ScoringMode;
  correct_answer: string | null;
  stimulus_text: string | null;
  instruction_audio_path: string | null;
  stimulus_audio_path: string | null;
  is_instruction_replayable: boolean;
  is_stimulus_replayable: boolean | null;
  is_practice: boolean;
  is_scored: boolean;
  display_order: number | null;
  options: DraftOption[];
};

export type BlockerCode =
  | 'REPLAYABILITY_UNDECIDED'
  | 'NO_ANSWER_KEY'
  | 'DUPLICATE_OPTION_TEXT'
  | 'BLANK_OPTION_TEXT'
  | 'TOO_FEW_OPTIONS'
  | 'MISSING_ITEM_CODE'
  | 'MISSING_DOMAIN';

export type Blocker = { code: BlockerCode; message: string };

/** Formats where the participant chooses from a stored option list. */
export const CHOICE_FORMATS: ResponseFormat[] = ['MCQ_TAP', 'BINARY_TAP', 'TRI_TAP', 'LIKERT_5'];

/**
 * Formats that carry a right answer at all. TRI_TAP and LIKERT_5 are self-report
 * scales and have no correct response by design; AUDIO_RECORD is human-rated.
 */
export const SCORABLE_FORMATS: ResponseFormat[] = ['MCQ_TAP', 'BINARY_TAP', 'NUMERIC_KEYPAD'];

export const isChoiceFormat = (f: ResponseFormat) => CHOICE_FORMATS.includes(f);

/**
 * Normalise for comparison so two options that LOOK identical are treated as
 * identical. Bangla text can carry zero-width joiners (U+200C/U+200D) that are
 * invisible but change the bytes, so trimming alone is not enough — normalising
 * to NFC and stripping ZWJ/ZWNJ catches option pairs a proofreader would call
 * duplicates even though the database sees distinct strings.
 */
export function normaliseOptionText(s: string): string {
  // U+200B ZWSP, U+200C ZWNJ, U+200D ZWJ, U+FEFF BOM — all invisible.
  return s.normalize('NFC').replace(/[\u200B-\u200D\uFEFF]/g, '').trim();
}

/** Does this draft have a usable answer key, given its format? */
export function hasAnswerKey(item: DraftItem): boolean {
  if (isChoiceFormat(item.response_format)) {
    return item.options.some((o) => o.is_correct);
  }
  if (item.response_format === 'NUMERIC_KEYPAD') {
    return (item.correct_answer ?? '').trim().length > 0;
  }
  return false;
}

/**
 * Everything blocking `active = true`. Empty array means the item may go live.
 */
export function activationBlockers(item: DraftItem): Blocker[] {
  const blockers: Blocker[] = [];

  if (!item.item_code.trim()) {
    blockers.push({ code: 'MISSING_ITEM_CODE', message: 'Item code is required.' });
  }
  if (!item.domain.trim()) {
    blockers.push({ code: 'MISSING_DOMAIN', message: 'Domain is required.' });
  }

  if (item.is_stimulus_replayable === null) {
    blockers.push({
      code: 'REPLAYABILITY_UNDECIDED',
      message:
        'Stimulus replayability is undecided. Set it explicitly before activating — ' +
        'Domain 4 (rhyme) was never decided, and the TestRunner has no default for it.',
    });
  }

  // The client-side half of the 0005 scoring fix.
  const needsKey =
    item.is_scored &&
    item.scoring_mode === 'auto' &&
    SCORABLE_FORMATS.includes(item.response_format);

  if (needsKey && !hasAnswerKey(item)) {
    blockers.push({
      code: 'NO_ANSWER_KEY',
      message:
        item.response_format === 'NUMERIC_KEYPAD'
          ? 'This item is scored but has no correct answer. Responses would be left unscored.'
          : 'This item is scored but no option is marked correct. Responses would be left unscored.',
    });
  }

  if (isChoiceFormat(item.response_format)) {
    if (item.options.length < 2) {
      blockers.push({
        code: 'TOO_FEW_OPTIONS',
        message: `A ${item.response_format} item needs at least 2 options; this one has ${item.options.length}.`,
      });
    }

    const blank = item.options.filter((o) => normaliseOptionText(o.option_text).length === 0);
    if (blank.length > 0) {
      blockers.push({
        code: 'BLANK_OPTION_TEXT',
        message: `Blank option text: ${blank.map((o) => o.option_key).join(', ')}.`,
      });
    }

    const seen = new Map<string, string[]>();
    for (const o of item.options) {
      const key = normaliseOptionText(o.option_text);
      if (!key) continue;
      seen.set(key, [...(seen.get(key) ?? []), o.option_key]);
    }
    const dupes = [...seen.entries()].filter(([, keys]) => keys.length > 1);
    if (dupes.length > 0) {
      blockers.push({
        code: 'DUPLICATE_OPTION_TEXT',
        message:
          'Duplicate option text: ' +
          dupes.map(([text, keys]) => `${keys.join(' / ')} both read "${text}"`).join('; ') +
          '.',
      });
    }
  }

  return blockers;
}

/** Non-blocking advice — worth showing, but does not prevent activation. */
export function activationWarnings(item: DraftItem): string[] {
  const warnings: string[] = [];
  if (!item.instruction_audio_path) {
    warnings.push(
      'No instruction audio. This instrument is audio-first — every item should have spoken instructions.',
    );
  }
  if (item.response_format === 'AUDIO_RECORD' && item.scoring_mode !== 'human_rated') {
    warnings.push('AUDIO_RECORD items are normally scoring_mode = human_rated.');
  }
  if (isChoiceFormat(item.response_format) && item.options.filter((o) => o.is_correct).length > 1) {
    warnings.push('More than one option is marked correct; only the selected one is compared.');
  }
  return warnings;
}
