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
 *
 * DEVICE-BIAS NOTE: a keyboard activation (Enter/Space on a focused button)
 * is captured on `keydown`, not on the resulting `click`. A native button's
 * click for Space fires on `keyup` — i.e. after the full press-and-release —
 * while `pointerdown` (used for mouse/touch) fires at the moment of physical
 * contact. Timing keyboard responses off `click` would measure "time to
 * release" against "time to press" for other devices, inflating keyboard
 * latency by a full key hold duration for no reason related to the
 * student's actual reaction. `keydown` is the keyboard equivalent of
 * `pointerdown` — first physical contact — so that's what's timed here.
 * `preventDefault()` on the key we handle suppresses the later synthetic
 * click; `onClick` stays only as a defense-in-depth backstop (a browser that
 * still fires it just reselects the same, already-recorded option).
 */

import type { KeyboardEvent, MouseEvent, PointerEvent } from 'react';
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

  // See the module doc comment: keydown is the keyboard equivalent of
  // pointerdown for latency purposes, so this — not onClick — is where a
  // keyboard response is timed.
  function handleKeyDown(e: KeyboardEvent<HTMLButtonElement>, key: string) {
    if (e.key !== 'Enter' && e.key !== ' ' && e.key !== 'Spacebar') return;
    e.preventDefault();
    activate(key, 'keyboard');
  }

  // Backstop only, in case a browser's synthetic click wasn't suppressed by
  // the keydown preventDefault above -- see module doc comment.
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
          onKeyDown={(e) => handleKeyDown(e, o.option_key)}
          onClick={(e) => handleClick(e, o.option_key)}
        >
          {o.option_text}
        </button>
      ))}
    </div>
  );
}
