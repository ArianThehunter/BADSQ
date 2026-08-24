/**
 * IndexedDB-backed local draft for same-device resume — SCAFFOLD ONLY.
 *
 * Phase 1. Design constraints already decided (design doc section 5e), recorded
 * here so they are not lost:
 *   - Written after every response, keyed by the local session UUID.
 *   - On load, NEVER silently resume. Ask via audio whether this is the same
 *     student continuing, because a shared school device could hand Student A's
 *     in-progress test to Student B.
 *   - "New turn" discards the stale draft.
 *   - The draft is not cleared until the server confirms a fully successful
 *     submit_session() call.
 *   - Cross-device recovery is deliberately out of scope for v1.
 */

export type LocalDraft = Record<string, never>;

export async function loadDraft(): Promise<LocalDraft | null> {
  return null;
}

export async function saveDraft(_draft: LocalDraft): Promise<void> {
  // Phase 1.
}

export async function clearDraft(): Promise<void> {
  // Phase 1. Only ever call this after the server confirms a successful submit.
}
