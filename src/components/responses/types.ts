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
  /** Only ever non-null when is_practice is true -- see public_items view
   * (migration 0017). Real items never expose their answer key here. */
  practice_correct_answer: string | null;
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

/**
 * True when a `click` event was synthesized by keyboard activation (Enter/Space
 * on a focused button) rather than an actual mouse/touch press. Per the UI
 * Events spec, a click dispatched as a button's default activation behavior
 * (not from a real pointer click) carries `detail === 0`.
 *
 * Every interactive control here uses `onPointerDown` for the primary
 * interaction, deliberately — it fires at the moment of physical contact,
 * which is what makes this instrument's response-latency measurement
 * meaningful. `onPointerDown` never fires for keyboard activation, though
 * (there is no "pointer" involved), so keyboard-only participants would
 * otherwise be unable to operate the test at all. Pairing `onPointerDown` with
 * `onClick` gated by this check adds keyboard support without double-firing
 * for mouse/touch, where the browser dispatches both pointerdown AND a
 * subsequent (non-keyboard) click for the same tap.
 */
export function isKeyboardClick(e: { detail: number }): boolean {
  return e.detail === 0;
}
