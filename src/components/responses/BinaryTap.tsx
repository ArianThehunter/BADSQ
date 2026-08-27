/**
 * BINARY_TAP — a two-option choice (e.g. yes/no). Backed by the same
 * item_options rows as MCQ_TAP; the format name only signals the intended
 * option count to the item author, so the rendering is identical.
 */

import OptionGrid from './OptionGrid';
import type { ChoiceProps } from './types';

export default function BinaryTap({ options, disabled, value, hasAnswered, onFirstInteraction, onChange }: ChoiceProps) {
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
