/**
 * Shared rendering for every "tap one of N stored options" response format —
 * MCQ_TAP, BINARY_TAP, TRI_TAP, LIKERT_5 all differ only in option count and
 * layout, not in interaction logic, so the logic lives once here. Each format
 * gets its own file (per the brief) as a thin wrapper — real behaviour, not a
 * copy-pasted duplicate, and no premature abstraction beyond what four
 * genuinely-identical formats already call for.
 *
 * Latency contract (see design doc section 2): the FIRST pointerdown on any
 * option is the response-latency anchor t1, captured once via
 * `onFirstInteraction`. Every interaction after that only changes which
 * option is selected — per "editable before advance" — it does NOT re-arm the
 * latency measurement. Re-timing on every tap would destroy the very thing
 * this instrument measures: the student's first reaction.
 */

import type { MouseEvent, PointerEvent } from 'react';
import { isKeyboardClick } from './types';

export type OptionItem = { option_key: string; option_text: string };

export default function OptionGrid({
  options,
  disabled,
  value,
  hasAnswered,
  onFirstInteraction,
  onChange,
  layout = 'list',
}: {
  options: OptionItem[];
  disabled: boolean;
  value: string | null;
  hasAnswered: boolean;
  onFirstInteraction: (pointerType: string) => void;
  onChange: (optionKey: string) => void;
  layout?: 'list' | 'scale';
}) {
  function activate(key: string, modality: string) {
    if (disabled) return;
    if (!hasAnswered) onFirstInteraction(modality);
    onChange(key);
  }

  function handlePointerDown(e: PointerEvent<HTMLButtonElement>, key: string) {
    activate(key, e.pointerType || 'unknown');
  }

  // Keyboard activation (Enter/Space) never fires onPointerDown -- see
  // isKeyboardClick's doc comment. Guarded so a real mouse/touch tap, which
  // fires both pointerdown and a following click, doesn't double-activate.
  function handleClick(e: MouseEvent<HTMLButtonElement>, key: string) {
    if (!isKeyboardClick(e)) return;
    activate(key, 'keyboard');
  }

  return (
    <div className={`option-grid option-grid-${layout}`} role="group">
      {options.map((o) => (
        <button
          key={o.option_key}
          type="button"
          className={`option-button${value === o.option_key ? ' selected' : ''}`}
          disabled={disabled}
          aria-pressed={value === o.option_key}
          lang="bn"
          onPointerDown={(e) => handlePointerDown(e, o.option_key)}
          onClick={(e) => handleClick(e, o.option_key)}
        >
          {o.option_text}
        </button>
      ))}
    </div>
  );
}
