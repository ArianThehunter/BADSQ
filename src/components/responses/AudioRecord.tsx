/**
 * AUDIO_RECORD — record -> playback -> re-record-before-advance.
 *
 * Latency: per the design doc, t1 for this format is the pointerdown on the
 * RECORD button ("response-initiation latency"). That is captured once, via
 * onFirstInteraction, exactly like every other format — pressing "record"
 * again for a re-take does not re-arm it. Recording DURATION is tracked
 * separately as metadata (duration_ms), never as latency.
 *
 * MIME type is detected per-device via MediaRecorder.isTypeSupported()
 * (src/lib/media.ts) rather than assumed — Chrome/Android typically produce
 * WebM/Opus, Safari/iOS produce MP4/AAC.
 */

import { useEffect, useRef, useState } from 'react';
import type { KeyboardEvent, MouseEvent, PointerEvent } from 'react';
import { pickSupportedAudioMimeType } from '../../lib/media';
import type { AudioProps } from './types';
import { isKeyboardClick } from './types';

type Phase = 'idle' | 'requesting' | 'recording' | 'recorded' | 'error';

export default function AudioRecord({
  disabled,
  hasAnswered,
  onFirstInteraction,
  blob,
  mimeType,
  onRecorded,
}: AudioProps) {
  const [phase, setPhase] = useState<Phase>(blob ? 'recorded' : 'idle');
  const [error, setError] = useState<string | null>(null);
  const [previewUrl, setPreviewUrl] = useState<string | null>(null);

  const recorderRef = useRef<MediaRecorder | null>(null);
  const streamRef = useRef<MediaStream | null>(null);
  const chunksRef = useRef<Blob[]>([]);
  const startedAtRef = useRef<number>(0);

  useEffect(() => {
    // (oxlint flags this as react/set-state-in-effect; accepted — this effect
    // exists to synchronize an external resource (an object URL) with the
    // `blob` prop, which is exactly what the rule's own guidance recommends
    // effects for. There is no render-time value to derive this from instead.)
    if (!blob) {
      setPreviewUrl(null);
      return;
    }
    const url = URL.createObjectURL(blob);
    setPreviewUrl(url);
    return () => URL.revokeObjectURL(url);
  }, [blob]);

  useEffect(() => {
    return () => {
      streamRef.current?.getTracks().forEach((t) => t.stop());
    };
  }, []);

  async function startRecording(modality: string) {
    if (disabled || phase === 'requesting' || phase === 'recording') return;
    if (!hasAnswered) onFirstInteraction(modality);

    setError(null);
    setPhase('requesting');
    try {
      // Microphone access requires a secure context (HTTPS, or localhost for
      // dev). On a plain http://<lan-ip> deployment — the most likely mistake
      // when field-testing on a phone against a laptop's dev server —
      // `navigator.mediaDevices` is undefined entirely, which otherwise throws
      // an unhelpful "Cannot read properties of undefined" here.
      if (!navigator.mediaDevices?.getUserMedia) {
        throw new Error(
          'Microphone access is unavailable. This usually means the page was not opened over ' +
            'HTTPS (or localhost) — check the address bar shows a secure connection.',
        );
      }
      const type = pickSupportedAudioMimeType();
      if (!type) {
        throw new Error('This device does not report support for any audio recording format.');
      }
      let stream: MediaStream;
      try {
        stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      } catch (mediaErr) {
        const name = mediaErr instanceof DOMException ? mediaErr.name : '';
        if (name === 'NotAllowedError' || name === 'PermissionDeniedError') {
          throw new Error('Microphone permission was denied. Allow microphone access for this site and try again.');
        }
        if (name === 'NotFoundError' || name === 'DevicesNotFoundError') {
          throw new Error('No microphone was found on this device.');
        }
        throw mediaErr;
      }
      streamRef.current = stream;
      const recorder = new MediaRecorder(stream, { mimeType: type });
      chunksRef.current = [];
      recorder.ondataavailable = (ev) => {
        if (ev.data.size > 0) chunksRef.current.push(ev.data);
      };
      recorder.onstop = () => {
        const durationMs = Math.round(performance.now() - startedAtRef.current);
        const finalBlob = new Blob(chunksRef.current, { type });
        streamRef.current?.getTracks().forEach((t) => t.stop());
        streamRef.current = null;
        setPhase('recorded');
        onRecorded(finalBlob, type, durationMs);
      };
      recorderRef.current = recorder;
      startedAtRef.current = performance.now();
      recorder.start();
      setPhase('recording');
    } catch (err) {
      setPhase('error');
      setError(err instanceof Error ? err.message : String(err));
    }
  }

  function stopRecording() {
    recorderRef.current?.stop();
  }

  function handlePointerDown(e: PointerEvent<HTMLButtonElement>) {
    void startRecording(e.pointerType || 'unknown');
  }

  // Timed on keydown, not the resulting click -- see OptionGrid's module doc
  // comment for why (click-on-keyup vs pointerdown is a real latency bias).
  // The Stop button isn't latency-critical (recording duration is tracked
  // separately, not as response latency), but keydown is used there too for
  // consistent, immediate keyboard behaviour.
  function handleKeyDown(e: KeyboardEvent<HTMLButtonElement>) {
    if (e.key !== 'Enter' && e.key !== ' ' && e.key !== 'Spacebar') return;
    e.preventDefault();
    void startRecording('keyboard');
  }

  function handleStopKeyDown(e: KeyboardEvent<HTMLButtonElement>) {
    if (e.key !== 'Enter' && e.key !== ' ' && e.key !== 'Spacebar') return;
    e.preventDefault();
    stopRecording();
  }

  // Backstop only -- see OptionGrid's module doc comment.
  function handleClick(e: MouseEvent<HTMLButtonElement>) {
    if (!isKeyboardClick(e)) return;
    void startRecording('keyboard');
  }

  function handleStopClick(e: MouseEvent<HTMLButtonElement>) {
    if (!isKeyboardClick(e)) return;
    stopRecording();
  }

  return (
    <div className="audio-record">
      {phase === 'idle' || phase === 'requesting' ? (
        <button
          type="button"
          className="record-button"
          disabled={disabled || phase === 'requesting'}
          onPointerDown={handlePointerDown}
          onKeyDown={handleKeyDown}
          onClick={handleClick}
        >
          {phase === 'requesting' ? 'Starting…' : '● Record'}
        </button>
      ) : phase === 'recording' ? (
        <button
          type="button"
          className="record-button recording"
          onPointerDown={stopRecording}
          onKeyDown={handleStopKeyDown}
          onClick={handleStopClick}
        >
          ■ Stop
        </button>
      ) : (
        <div className="record-result">
          {previewUrl && <audio controls src={previewUrl} />}
          <button
            type="button"
            className="rerecord-button"
            disabled={disabled}
            onPointerDown={handlePointerDown}
            onKeyDown={handleKeyDown}
            onClick={handleClick}
          >
            ● Record again
          </button>
        </div>
      )}
      {error && <p className="error small">{error}</p>}
      {mimeType && phase === 'recorded' && (
        <p className="muted small">format: {mimeType}</p>
      )}
    </div>
  );
}
