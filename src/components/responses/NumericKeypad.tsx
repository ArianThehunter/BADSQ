/**
 * NUMERIC_KEYPAD — digit entry via an ON-SCREEN keypad only.
 *
 * Deliberately never renders a native <input>: a real text field would summon
 * the device's system keyboard, reopening the exact typing-skill confound the
 * design doc's keyboard-confound rationale (section 3.2) rules out. The
 * "display" below is a read-only span, not an editable field.
 */

import type { MouseEvent, PointerEvent } from 'react';
import type { TypedProps } from './types';
import { isKeyboardClick } from './types';

const KEYS = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '⌫', '0', 'C'];

export default function NumericKeypad({
  disabled,
  value,
  hasAnswered,
  onFirstInteraction,
  onChange,
}: TypedProps) {
  function press(key: string, modality: string) {
    if (disabled) return;
    if (!hasAnswered) onFirstInteraction(modality);

    const current = value ?? '';
    if (key === '⌫') {
      onChange(current.slice(0, -1));
    } else if (key === 'C') {
      onChange('');
    } else {
      onChange(current + key);
    }
  }

  function handlePointerDown(e: PointerEvent<HTMLButtonElement>, key: string) {
    press(key, e.pointerType || 'unknown');
  }

  // Keyboard support is Tab-to-focus-a-key + Enter/Space, deliberately NOT
  // free typing on a physical keyboard -- see the module doc comment on why a
  // native <input> is avoided here. This keeps "select one on-screen key at a
  // time" as the only interaction model regardless of input device.
  function handleClick(e: MouseEvent<HTMLButtonElement>, key: string) {
    if (!isKeyboardClick(e)) return;
    press(key, 'keyboard');
  }

  return (
    <div className="numeric-keypad">
      <div className="numeric-display" aria-live="polite" aria-label="Typed digits">
        {value && value.length > 0 ? value : <span className="numeric-placeholder">—</span>}
      </div>
      <div className="numeric-keys">
        {KEYS.map((k) => (
          <button
            key={k}
            type="button"
            className="numeric-key"
            disabled={disabled}
            onPointerDown={(e) => handlePointerDown(e, k)}
            onClick={(e) => handleClick(e, k)}
          >
            {k}
          </button>
        ))}
      </div>
    </div>
  );
}
