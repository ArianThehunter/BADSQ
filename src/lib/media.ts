/**
 * Shared audio-storage helpers, used by both the researcher Item Bank Editor
 * and the participant TestRunner.
 *
 * Two buckets, two different access patterns:
 *   - badsq-item-audio: the test CONTENT (instructions, stimuli). Private —
 *     item audio reveals what the screening actually asks, so it is never
 *     public. Readable by researchers, and by a participant with a live
 *     (`status = 'in_progress'`) session — see migration 0004's `item_audio_read`
 *     policy. Writable only by researchers with `can_manage_items`.
 *   - badsq-audio: participant RECORDINGS (their spoken answers). Writable only
 *     by the owning session, under its own folder, while `in_progress` — see
 *     migration 0003's `audio_upload_own_session` policy.
 * Both are private, so playback always goes through a short-lived signed URL,
 * never a public link.
 */

import { supabase, AUDIO_BUCKET } from './supabaseClient';

export const ITEM_AUDIO_BUCKET = 'badsq-item-audio';
export { AUDIO_BUCKET };

function fail(context: string, error: { message: string; code?: string } | null): never {
  throw new Error(`${context}: ${error?.code ? `${error.code} ` : ''}${error?.message ?? 'unknown error'}`);
}

/** Short-lived signed URL for a private storage object, in either bucket. */
export async function signedUrl(
  bucket: string,
  path: string,
  expiresInSeconds = 3600,
): Promise<string> {
  const { data, error } = await supabase.storage.from(bucket).createSignedUrl(path, expiresInSeconds);
  if (error || !data?.signedUrl) fail(`Could not sign URL for ${bucket}/${path}`, error);
  return data.signedUrl;
}

/** Convenience wrapper for item audio specifically (researcher + TestRunner use). */
export function signedItemAudioUrl(path: string, expiresInSeconds = 3600): Promise<string> {
  return signedUrl(ITEM_AUDIO_BUCKET, path, expiresInSeconds);
}

/**
 * Upload a researcher-authored item audio file. Returns the storage OBJECT
 * PATH (not a URL) — that path is what `items.instruction_audio_path` /
 * `stimulus_audio_path` store.
 */
export async function uploadItemAudio(
  file: File,
  itemCode: string,
  kind: 'instruction' | 'stimulus',
): Promise<string> {
  const safeCode = itemCode.trim().replace(/[^A-Za-z0-9._-]/g, '_') || 'untitled';
  const ext = (file.name.split('.').pop() || 'bin').toLowerCase().replace(/[^a-z0-9]/g, '');
  // Timestamped so re-uploading never silently overwrites an object a previous
  // item version still points at.
  const path = `${safeCode}/${kind}-${Date.now()}.${ext}`;

  const { error } = await supabase.storage
    .from(ITEM_AUDIO_BUCKET)
    .upload(path, file, { contentType: file.type || undefined, upsert: false });
  if (error) fail('Item audio upload failed', error);
  return path;
}

/**
 * Upload a participant's own recorded response audio, under their session's
 * folder — the path shape (`{session_id}/{response_client_id}.{ext}`) is fixed
 * by the storage policy (`audio_upload_own_session`), not a free choice.
 * `responseClientId` is generated client-side (see localDraft.ts) so the path
 * is stable across retries: a failed submit that is retried re-uploads to the
 * SAME path rather than accumulating orphaned blobs per attempt.
 */
/**
 * CHANGED IN PHASE 4: `upsert: true` removed (was I1's other viable fix,
 * independent of the badsq-audio SELECT policy — see PHASE_4_REPORT.md).
 * `responseClientId` is a fresh UUID per response, so this path can never
 * collide with an existing object; upsert semantics were never needed here.
 */
export async function uploadParticipantAudio(
  sessionId: string,
  responseClientId: string,
  blob: Blob,
  mimeType: string,
): Promise<string> {
  const ext = extensionForMimeType(mimeType);
  const path = `${sessionId}/${responseClientId}.${ext}`;
  const { error } = await supabase.storage
    .from(AUDIO_BUCKET)
    .upload(path, blob, { contentType: mimeType });
  if (error) fail('Recording upload failed', error);
  return path;
}

function extensionForMimeType(mimeType: string): string {
  const base = mimeType.split(';')[0].trim();
  if (base === 'audio/webm') return 'webm';
  if (base === 'audio/mp4') return 'm4a';
  if (base === 'audio/aac') return 'aac';
  if (base === 'audio/ogg') return 'ogg';
  if (base === 'audio/wav' || base === 'audio/x-wav') return 'wav';
  return 'bin';
}

/**
 * Pick a MediaRecorder MIME type this device actually supports, instead of
 * assuming one. Chrome/Android records WebM/Opus; Safari/iOS records MP4/AAC
 * and did not support WebM at all until very recently, if ever, depending on
 * OS version. Ordered by preference (smallest, best-supported-on-Chromium
 * first), but the FIRST one `isTypeSupported` accepts wins — never hard-coded.
 */
export function pickSupportedAudioMimeType(): string | null {
  if (typeof MediaRecorder === 'undefined') return null;
  const candidates = [
    'audio/webm;codecs=opus',
    'audio/webm',
    'audio/mp4;codecs=mp4a.40.2',
    'audio/mp4',
    'audio/aac',
    'audio/ogg;codecs=opus',
  ];
  for (const type of candidates) {
    try {
      if (MediaRecorder.isTypeSupported(type)) return type;
    } catch {
      // Some engines throw rather than return false for an unrecognised type.
    }
  }
  return null;
}
