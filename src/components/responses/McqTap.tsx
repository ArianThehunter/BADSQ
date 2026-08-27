/**
 * MCQ_TAP — participant taps one of the item's stored options.
 * Thin wrapper over OptionGrid; see that file for the interaction/latency contract.
 */

import OptionGrid from './OptionGrid';
import type { ChoiceProps } from './types';

export default function McqTap({ options, disabled, value, hasAnswered, onFirstInteraction, onChange }: ChoiceProps) {
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
