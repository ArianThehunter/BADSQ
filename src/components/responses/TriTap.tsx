/**
 * TRI_TAP — a three-option choice. Backed by the same item_options rows as
 * MCQ_TAP/BINARY_TAP; only the intended option count differs.
 */

import OptionGrid from './OptionGrid';
import type { ChoiceProps } from './types';

export default function TriTap({ options, disabled, value, hasAnswered, onFirstInteraction, onChange }: ChoiceProps) {
  return (
    <OptionGrid
      options={options}
      disabled={disabled}
      value={value}
      hasAnswered={hasAnswered}
      onFirstInteraction={onFirstInteraction}
      onChange={onChange}
      layout="list"
    />
  );
}
