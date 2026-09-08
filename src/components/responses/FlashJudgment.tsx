/**
 * FLASH_JUDGMENT — Domain 1.2. A word (`item.stimulus_text`) shows for a fixed
 * exposure window, then disappears; only afterward do the সঠিক/ভুল buttons
 * appear. The student is judging from memory, not from the word sitting on
 * screen while they decide -- see the design doc's rationale for why the
 * word must actually vanish before the buttons exist, not just visually fade.
 *
 * This is the only response format with no audio at all (see item bank: no
 * instruction_audio_path/stimulus_audio_path), so the shared per-item audio
 * gating in TestRunner's ItemScreen (`disabled`) is already false immediately
 * on mount -- this component adds its OWN independent reveal timer on top of
 * that, and TestRunner skips rendering the persistent stimulus_text banner
 * for this format specifically, since this component controls when (and
 * whether) that text is visible.
 *
 * Latency contract: t1 is the first tap on সঠিক/ভুল, same as every other
 * format via onFirstInteraction -- the exposure window itself is not part of
 * the response-latency measurement.
 */

import { useEffect, useState } from 'react';
import OptionGrid from './OptionGrid';
import type { ChoiceProps } from './types';

/** Exposure window for the flashed word, for both the 4.2.0 demo and every
 * real 4.2 item. Reduced from 2000ms per the researcher's revision. */
export const FLASH_EXPOSURE_MS = 1500;

export default function FlashJudgment({
  item,
  options,
  disabled,
  hasAnswered,
  onFirstInteraction,
  value,
  onChange,
}: ChoiceProps) {
  const [revealed, setRevealed] = useState(false);

  useEffect(() => {
    // (oxlint flags this as react/set-state-in-effect; accepted -- this effect
    // synchronizes a timer-driven reveal state with a new item's identity,
    // which is exactly what effects are for. There's no render-time value to
    // derive "has the exposure window elapsed" from instead.)
    //
    // GATED ON `disabled`: the exposure must not start until the audio gate
    // is satisfied. 4.2 now carries instruction audio, and the word only shows
    // for FLASH_EXPOSURE_MS -- if the timer ran from mount, the exposure would
    // burn away while the child was still listening to the instruction, and
    // they would never see the word at all.
    if (disabled) {
      setRevealed(false);
      return;
    }
    setRevealed(false);
    const timer = setTimeout(() => setRevealed(true), FLASH_EXPOSURE_MS);
    return () => clearTimeout(timer);
  }, [item.id, disabled]);

  // Still gated: nothing shown yet, so the exposure hasn't been spent.
  if (disabled) return null;

  if (!revealed) {
    return (
      <div className="flash-word" lang="bn" aria-live="off">
        {item.stimulus_text}
      </div>
    );
  }

  return (
    <OptionGrid
      options={options}
      disabled={disabled}
      value={value}
      hasAnswered={hasAnswered}
      onFirstInteraction={onFirstInteraction}
      onChange={onChange}
      layout="scale"
    />
  );
}
