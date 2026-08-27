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
import type { PointerEvent } from 'react';
import { pickSupportedAudioMimeType } from '../../lib/media';
import type { AudioProps } from './types';

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

  async function startRecording(e: PointerEvent<HTMLButtonElement>) {
    if (disabled || phase === 'requesting' || phase === 'recording') return;
    if (!hasAnswered) onFirstInteraction(e.pointerType || 'unknown');

    setError(null);
    setPhase('requesting');
    try {
      const type = pickSupportedAudioMimeType();
      if (!type) {
        throw new Error('This device does not report support for any audio recording format.');
      }
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
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

  return (
    <div className="audio-record">
      {phase === 'idle' || phase === 'requesting' ? (
        <button
          type="button"
          className="record-button"
          disabled={disabled || phase === 'requesting'}
          onPointerDown={startRecording}
        >
          {phase === 'requesting' ? 'Starting…' : '● Record'}
        </button>
      ) : phase === 'recording' ? (
        <button type="button" className="record-button recording" onPointerDown={stopRecording}>
          ■ Stop
        </button>
      ) : (
        <div className="record-result">
          {previewUrl && <audio controls src={previewUrl} />}
          <button type="button" className="rerecord-button" disabled={disabled} onPointerDown={startRecording}>
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
