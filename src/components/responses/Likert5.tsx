/**
 * LIKERT_5 — a 5-point self-report scale. Backed by item_options like the
 * other choice formats (option_key '1'..'5', option_text the scale label), but
 * rendered horizontally rather than as a vertical list — a self-report scale
 * reads as a scale, not a menu.
 *
 * There is deliberately no "correct" styling anywhere in this component (or
 * any response component): the client never receives is_correct, and even for
 * auto-scored formats no visual feedback is given during the test.
 */

import OptionGrid from './OptionGrid';
import type { ChoiceProps } from './types';

export default function Likert5({ options, disabled, value, hasAnswered, onFirstInteraction, onChange }: ChoiceProps) {
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
