/**
 * Shared prop contract for all six response components, so TestRunner can
 * render whichever one an item's response_format calls for polymorphically.
 *
 * None of these ever receive an answer key. `PublicItem`/`PublicItemOption`
 * are the sanitised shapes served by the `public_items`/`public_item_options`
 * views — there is no `correct_answer` or `is_correct` field to accidentally
 * pass through.
 */

export type PublicItem = {
  id: string;
  item_code: string;
  domain: string;
  subdomain: string | null;
  response_format: string;
  instruction_audio_path: string | null;
  stimulus_audio_path: string | null;
  stimulus_text: string | null;
  is_instruction_replayable: boolean;
  is_stimulus_replayable: boolean | null;
  is_practice: boolean;
  is_scored: boolean;
  display_order: number | null;
};

export type PublicItemOption = {
  id: string;
  item_id: string;
  option_key: string;
  option_text: string;
};

/**
 * Common props every response component accepts. `value`/`typedValue`/
 * `audioBlob` are read back from the in-progress draft so a student can leave
 * an item and return to it before advancing (this build always shows one item
 * per screen with no back-navigation, but the draft still round-trips through
 * these props on every re-render).
 */
export type ResponseProps = {
  item: PublicItem;
  options: PublicItemOption[];
  /** True until the relevant stimulus/instruction audio has ended at least once. */
  disabled: boolean;
  /** True once the first interaction has been recorded (freezes timing, not the value). */
  hasAnswered: boolean;
  onFirstInteraction: (pointerType: string) => void;
};

export type ChoiceProps = ResponseProps & {
  value: string | null;
  onChange: (optionKey: string) => void;
};

export type TypedProps = ResponseProps & {
  value: string | null;
  onChange: (typedValue: string) => void;
};

export type AudioProps = ResponseProps & {
  blob: Blob | null;
  mimeType: string | null;
  durationMs: number | null;
  onRecorded: (blob: Blob, mimeType: string, durationMs: number) => void;
};
