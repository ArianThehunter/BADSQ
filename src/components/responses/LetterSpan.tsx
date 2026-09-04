/**
 * LETTER_SPAN — Domain 3.3/3.4. Bangla has no single-keystroke way to type a
 * letter the way a digit can be typed, so students tap letters in order from
 * a small fixed on-screen grid instead of a keyboard, mirroring
 * NUMERIC_KEYPAD's on-screen-only approach and for the same reason (see that
 * component's doc comment): this must stay a "tap one thing at a time"
 * interaction, not typing.
 *
 * The eight grid letters (ক খ গ ঘ ত থ প ফ) are fixed by the design doc,
 * chosen for being pairwise confusable (ক/খ, গ/ঘ, ত/থ, প/ফ -- unaspirated vs.
 * aspirated stop pairs) -- not configurable per item. Revised from the
 * original শ স জ ন ণ ব ভ র grid per the question-paper changelog.
 */

import type { KeyboardEvent, MouseEvent } from 'react';
import type { TypedProps } from './types';
import { isKeyboardClick } from './types';

const LETTER_GRID = ['ক', 'খ', 'গ', 'ঘ', 'ত', 'থ', 'প', 'ফ'];

export default function LetterSpan({
  disabled,
  value,
  hasAnswered,
  onFirstInteraction,
  onChange,
}: TypedProps) {
  function press(letter: string, modality: string) {
    if (disabled) return;
    if (!hasAnswered) onFirstInteraction(modality);
    onChange((value ?? '') + letter);
  }

  function clear(modality: string) {
    if (disabled) return;
    if (!hasAnswered) onFirstInteraction(modality);
    onChange('');
  }

  function backspace(modality: string) {
    if (disabled) return;
    if (!hasAnswered) onFirstInteraction(modality);
    onChange((value ?? '').slice(0, -1));
  }

  function handlePointerDown(action: (modality: string) => void, pointerType: string) {
    action(pointerType || 'unknown');
  }

  // Timed on keydown, not the resulting click -- see OptionGrid's module doc
  // comment for why (click-on-keyup vs pointerdown is a real latency bias).
  function handleKeyDown(e: KeyboardEvent<HTMLButtonElement>, action: (modality: string) => void) {
    if (e.key !== 'Enter' && e.key !== ' ' && e.key !== 'Spacebar') return;
    e.preventDefault();
    action('keyboard');
  }

  // Backstop only -- see OptionGrid's module doc comment.
  function handleClick(e: MouseEvent<HTMLButtonElement>, action: (modality: string) => void) {
    if (!isKeyboardClick(e)) return;
    action('keyboard');
  }

  const shown = (value ?? '').split('').join('-');

  return (
    <div className="numeric-keypad">
      <div className="numeric-display" aria-live="polite" aria-label="Tapped letters" lang="bn">
        {shown.length > 0 ? shown : <span className="numeric-placeholder">—</span>}
      </div>
      <div className="numeric-keys letter-keys">
        {LETTER_GRID.map((letter) => (
          <button
            key={letter}
            type="button"
            className="numeric-key"
            lang="bn"
            disabled={disabled}
            onPointerDown={(e) => handlePointerDown((m) => press(letter, m), e.pointerType)}
            onKeyDown={(e) => handleKeyDown(e, (m) => press(letter, m))}
            onClick={(e) => handleClick(e, (m) => press(letter, m))}
          >
            {letter}
          </button>
        ))}
        <button
          type="button"
          className="numeric-key"
          disabled={disabled}
          onPointerDown={(e) => handlePointerDown(backspace, e.pointerType)}
          onKeyDown={(e) => handleKeyDown(e, backspace)}
          onClick={(e) => handleClick(e, backspace)}
        >
          ⌫
        </button>
        <button
          type="button"
          className="numeric-key"
          disabled={disabled}
          onPointerDown={(e) => handlePointerDown(clear, e.pointerType)}
          onKeyDown={(e) => handleKeyDown(e, clear)}
          onClick={(e) => handleClick(e, clear)}
        >
          C
        </button>
      </div>
    </div>
  );
}
