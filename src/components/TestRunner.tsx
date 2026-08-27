/**
 * TestRunner — the participant test flow. One item per screen, audio-first,
 * lock-on-advance, IndexedDB draft with a same-device resume guard, and a
 * single atomic submit at the end.
 *
 * Nothing touches the database before Submit except the `sessions` row
 * `start_session()` creates at the very beginning (the approved minimal ping)
 * — every response lives only in IndexedDB until then.
 *
 * SCOPE NOTE: the schema (0001) supports a full per-item attempt history
 * (`attempt_number`, `is_superseded`) for "preserve every edit before
 * advance, not just the final one". This build submits exactly one row per
 * item — the answer as it stood at the moment of advance — not the full
 * edit history. That is a deliberate scope trim; see PHASE_2_REPORT.md.
 */

import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { supabase, startSession } from '../lib/supabaseClient';
import { uploadParticipantAudio, signedItemAudioUrl } from '../lib/media';
import {
  loadDraft,
  saveDraft,
  clearDraft,
  newEmptyDraft,
  allAnswered,
  type LocalDraft,
  type ResponseDraft,
} from '../lib/localDraft';
import type { PublicItem, PublicItemOption, ResponseProps } from './responses/types';
import McqTap from './responses/McqTap';
import BinaryTap from './responses/BinaryTap';
import TriTap from './responses/TriTap';
import Likert5 from './responses/Likert5';
import NumericKeypad from './responses/NumericKeypad';
import AudioRecord from './responses/AudioRecord';
import './testrunner.css';

type Phase =
  | 'loading'
  | 'resume-prompt'
  | 'intake'
  | 'running'
  | 'ready-to-submit'
  | 'submitting'
  | 'submit-error'
  | 'complete';

function emptyResponseDraft(itemId: string): ResponseDraft {
  return {
    itemId,
    responseClientId: crypto.randomUUID(),
    selectedOptionKey: null,
    typedValue: null,
    audioBlob: null,
    audioMimeType: null,
    audioDurationMs: null,
    stimulusFirstEndClientTs: null,
    stimulusLastEndClientTs: null,
    responseClientTs: null,
    responseLatencyFromFirstMs: null,
    responseLatencyFromLastMs: null,
    inputModality: null,
    viewportWidth: null,
    viewportHeight: null,
    replayCountInstruction: 0,
    replayCountStimulus: 0,
    technicalRetryCount: 0,
    hasAnswered: false,
  };
}

/**
 * Speak a short prompt aloud via the browser's built-in speech synthesis, with
 * a graceful no-throw fallback. NOTE (see PHASE_2_REPORT.md): this is NOT a
 * pre-recorded human voice like the item stimuli — it is on-device TTS, tried
 * with a Bangla voice first. Bangla TTS availability varies a great deal by
 * device and OS, especially on the low-end Android hardware this study
 * anticipates, so the on-screen text is always shown as well and the flow
 * never depends on the audio actually being heard.
 */
function speak(text: string) {
  try {
    if (typeof window === 'undefined' || !window.speechSynthesis) return;
    const utter = new SpeechSynthesisUtterance(text);
    const voices = window.speechSynthesis.getVoices();
    const bnVoice = voices.find((v) => v.lang?.toLowerCase().startsWith('bn'));
    if (bnVoice) utter.voice = bnVoice;
    utter.lang = bnVoice?.lang || 'bn-BD';
    window.speechSynthesis.cancel();
    window.speechSynthesis.speak(utter);
  } catch {
    // Speech synthesis is a nice-to-have here, never a requirement.
  }
}

export default function TestRunner() {
  const [phase, setPhase] = useState<Phase>('loading');
  const [error, setError] = useState<string | null>(null);
  const [items, setItems] = useState<PublicItem[]>([]);
  const [optionsByItem, setOptionsByItem] = useState<Record<string, PublicItemOption[]>>({});
  const [draft, setDraft] = useState<LocalDraft | null>(null);
  const draftRef = useRef<LocalDraft | null>(null);

  const setAndPersistDraft = useCallback((next: LocalDraft) => {
    draftRef.current = next;
    setDraft(next);
    void saveDraft(next);
  }, []);

  // ---------------------------------------------------------------- load
  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const { data: itemRows, error: itemErr } = await supabase
          .from('public_items')
          .select('*')
          .order('domain', { ascending: true })
          .order('display_order', { ascending: true, nullsFirst: false });
        if (itemErr) throw itemErr;
        const liveItems = (itemRows ?? []) as PublicItem[];

        const ids = liveItems.map((i) => i.id);
        const optionsMap: Record<string, PublicItemOption[]> = {};
        if (ids.length > 0) {
          const { data: optRows, error: optErr } = await supabase
            .from('public_item_options')
            .select('*')
            .in('item_id', ids);
          if (optErr) throw optErr;
          for (const o of (optRows ?? []) as PublicItemOption[]) {
            (optionsMap[o.item_id] ??= []).push(o);
          }
          for (const list of Object.values(optionsMap)) {
            list.sort((a, b) => a.option_key.localeCompare(b.option_key));
          }
        }

        const existing = await loadDraft();

        if (cancelled) return;
        setItems(liveItems);
        setOptionsByItem(optionsMap);

        if (existing && Object.keys(existing.responses).length > 0) {
          draftRef.current = existing;
          setDraft(existing);
          setPhase('resume-prompt');
        } else {
          await beginFreshSession();
        }
      } catch (e) {
        if (!cancelled) {
          setError(e instanceof Error ? e.message : String(e));
          setPhase('loading');
        }
      }
    })();
    return () => {
      cancelled = true;
    };
    // Intentionally empty: this effect runs once, on mount, to load the item
    // bank and resolve any existing draft. beginFreshSession/handleResume* are
    // re-created each render but are only ever invoked from user interaction
    // after this effect has settled, not from the effect itself re-running.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  async function beginFreshSession() {
    try {
      const { sessionId, assignedCode } = await startSession();
      const fresh = newEmptyDraft(sessionId, assignedCode);
      setAndPersistDraft(fresh);
      setPhase('intake');
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  }

  async function handleResumeYes() {
    setPhase(draftRef.current?.classGrade ? 'running' : 'intake');
  }

  async function handleResumeNo() {
    await clearDraft();
    await beginFreshSession();
  }

  useEffect(() => {
    if (phase === 'resume-prompt') {
      speak('আপনি কি আপনার আগের সেশন চালিয়ে যেতে চান, নাকি এটি একজন ভিন্ন শিক্ষার্থী?');
    }
  }, [phase]);

  // ------------------------------------------------------------- intake
  function setClassGrade(grade: 6 | 7 | 8) {
    if (!draftRef.current) return;
    setAndPersistDraft({ ...draftRef.current, classGrade: grade });
    setPhase('running');
  }

  // ------------------------------------------------------------- running
  const currentIndex = draft?.currentItemIndex ?? 0;
  const currentItem = items[currentIndex] ?? null;

  function updateCurrentResponse(patch: Partial<ResponseDraft>) {
    if (!draftRef.current || !currentItem) return;
    const prev = draftRef.current.responses[currentItem.id] ?? emptyResponseDraft(currentItem.id);
    const next: LocalDraft = {
      ...draftRef.current,
      responses: { ...draftRef.current.responses, [currentItem.id]: { ...prev, ...patch } },
    };
    setAndPersistDraft(next);
  }

  function handleFirstInteraction(pointerType: string) {
    if (!currentItem) return;
    const now = performance.now();
    const r = draftRef.current?.responses[currentItem.id] ?? emptyResponseDraft(currentItem.id);
    updateCurrentResponse({
      hasAnswered: true,
      responseClientTs: now,
      inputModality: normaliseModality(pointerType),
      viewportWidth: window.innerWidth,
      viewportHeight: window.innerHeight,
      responseLatencyFromFirstMs: r.stimulusFirstEndClientTs != null ? now - r.stimulusFirstEndClientTs : null,
      responseLatencyFromLastMs: r.stimulusLastEndClientTs != null ? now - r.stimulusLastEndClientTs : null,
    });
  }

  function normaliseModality(pointerType: string): ResponseDraft['inputModality'] {
    if (pointerType === 'touch' || pointerType === 'mouse' || pointerType === 'pen') return pointerType;
    return 'unknown';
  }

  function goToNextItem() {
    if (!draftRef.current) return;
    const nextIndex = draftRef.current.currentItemIndex + 1;
    setAndPersistDraft({ ...draftRef.current, currentItemIndex: nextIndex });
    if (nextIndex >= items.length) setPhase('ready-to-submit');
  }

  // ------------------------------------------------------------- submit
  async function handleSubmit() {
    if (!draftRef.current) return;
    setPhase('submitting');
    setError(null);
    try {
      const d = draftRef.current;
      const responsesPayload = [];
      for (const item of items) {
        const r = d.responses[item.id];
        if (!r) continue;

        let audioStoragePath: string | null = null;
        if (r.audioBlob && r.audioMimeType) {
          audioStoragePath = await uploadParticipantAudio(d.sessionId, r.responseClientId, r.audioBlob, r.audioMimeType);
        }

        responsesPayload.push({
          item_id: item.id,
          attempt_number: 1,
          is_superseded: false,
          selected_option_key: r.selectedOptionKey,
          typed_value: r.typedValue,
          stimulus_first_end_client_ts: r.stimulusFirstEndClientTs,
          stimulus_last_end_client_ts: r.stimulusLastEndClientTs,
          response_client_ts: r.responseClientTs,
          response_latency_from_first_ms: r.responseLatencyFromFirstMs,
          response_latency_from_last_ms: r.responseLatencyFromLastMs,
          input_modality: r.inputModality,
          viewport_width: r.viewportWidth,
          viewport_height: r.viewportHeight,
          replay_count_instruction: r.replayCountInstruction,
          replay_count_stimulus: r.replayCountStimulus,
          technical_retry_count: r.technicalRetryCount,
          ...(audioStoragePath
            ? {
                audio_storage_path: audioStoragePath,
                audio_mime_type: r.audioMimeType,
                audio_duration_ms: r.audioDurationMs,
                audio_file_size_bytes: r.audioBlob?.size ?? null,
              }
            : {}),
        });
      }

      const { error: rpcErr } = await supabase.rpc('submit_session', {
        p_session_id: d.sessionId,
        // anonymized_code is deliberately NOT sent — submit_session() takes it
        // from the session row and ignores any client-supplied value.
        p_participant: { class_grade: String(d.classGrade) },
        p_responses: responsesPayload,
      });
      if (rpcErr) throw rpcErr;

      await clearDraft();
      setPhase('complete');
    } catch (e) {
      // Deliberately do NOT clear the draft on failure -- see module doc.
      setError(e instanceof Error ? e.message : String(e));
      setPhase('submit-error');
    }
  }

  const allItemIds = useMemo(() => items.map((i) => i.id), [items]);
  const readyToSubmit = draft ? allAnswered(draft, allItemIds) : false;

  // ------------------------------------------------------------- render
  if (phase === 'loading') {
    return (
      <main className="runner-shell">
        {error ? <p className="error">Could not load the test: {error}</p> : <p className="muted">Loading…</p>}
      </main>
    );
  }

  if (phase === 'resume-prompt') {
    return (
      <main className="runner-shell resume-prompt">
        <h1 lang="bn">আপনি কি চালিয়ে যেতে চান?</h1>
        <p lang="bn">
          মনে হচ্ছে একটি অসম্পূর্ণ সেশন আছে। আপনি কি আগের সেশন চালিয়ে যেতে চান, নাকি এটি একজন ভিন্ন শিক্ষার্থী?
        </p>
        <p className="muted small">
          (Is this you continuing your earlier session, or a different student? A shared device
          never resumes automatically.)
        </p>
        <div className="big-choice-row">
          <button type="button" className="big-choice-button" onPointerDown={() => void handleResumeYes()}>
            হ্যাঁ, চালিয়ে যাব
          </button>
          <button type="button" className="big-choice-button" onPointerDown={() => void handleResumeNo()}>
            না, নতুন শিক্ষার্থী
          </button>
        </div>
      </main>
    );
  }

  if (phase === 'intake') {
    return (
      <main className="runner-shell">
        <h1 lang="bn">তোমার শ্রেণি কত?</h1>
        <p className="muted small">What class/grade are you in?</p>
        <div className="big-choice-row">
          {[6, 7, 8].map((g) => (
            <button key={g} type="button" className="big-choice-button" onPointerDown={() => setClassGrade(g as 6 | 7 | 8)}>
              {g}
            </button>
          ))}
        </div>
      </main>
    );
  }

  if (phase === 'running' && currentItem && draft) {
    const response = draft.responses[currentItem.id] ?? emptyResponseDraft(currentItem.id);
    return (
      <main className="runner-shell">
        <p className="progress-indicator">
          {currentIndex + 1} / {items.length}
        </p>
        <ItemScreen
          key={currentItem.id}
          item={currentItem}
          options={optionsByItem[currentItem.id] ?? []}
          response={response}
          onPatch={updateCurrentResponse}
          onFirstInteraction={handleFirstInteraction}
          onAdvance={goToNextItem}
        />
      </main>
    );
  }

  if (phase === 'ready-to-submit') {
    return (
      <main className="runner-shell">
        <h1 lang="bn">সব প্রশ্নের উত্তর দেওয়া হয়েছে</h1>
        <p className="muted small">All items answered. Submit when ready.</p>
        <button type="button" className="big-choice-button primary" disabled={!readyToSubmit} onPointerDown={() => void handleSubmit()}>
          জমা দিন (Submit)
        </button>
      </main>
    );
  }

  if (phase === 'submitting') {
    return (
      <main className="runner-shell">
        <p className="muted" lang="bn">
          জমা দেওয়া হচ্ছে…
        </p>
      </main>
    );
  }

  if (phase === 'submit-error') {
    return (
      <main className="runner-shell">
        <h1>Not yet submitted</h1>
        <p className="error">
          Something went wrong sending your answers: {error}. Your answers are still saved on
          this device — nothing has been lost. Try again.
        </p>
        <button type="button" className="big-choice-button primary" onPointerDown={() => void handleSubmit()}>
          Try submitting again
        </button>
      </main>
    );
  }

  if (phase === 'complete' && draft) {
    return (
      <main className="runner-shell complete-screen">
        <h1 lang="bn">ধন্যবাদ!</h1>
        <p className="muted small">Thank you — your answers have been submitted.</p>
        <p>Please tell your teacher this code so it can be written on your form:</p>
        <p className="assigned-code">{draft.assignedCode}</p>
      </main>
    );
  }

  return null;
}

/**
 * One item's screen: plays instruction (then stimulus, if any) audio, keeps
 * the response control disabled until the relevant "ended" event has fired at
 * least once, offers replay controls per the item's flags, and renders
 * whichever response component the item's format calls for.
 */
function ItemScreen({
  item,
  options,
  response,
  onPatch,
  onFirstInteraction,
  onAdvance,
}: {
  item: PublicItem;
  options: PublicItemOption[];
  response: ResponseDraft;
  onPatch: (patch: Partial<ResponseDraft>) => void;
  onFirstInteraction: (pointerType: string) => void;
  onAdvance: () => void;
}) {
  const instructionRef = useRef<HTMLAudioElement>(null);
  const stimulusRef = useRef<HTMLAudioElement>(null);
  const [instructionDone, setInstructionDone] = useState(false);
  const [instructionSignedUrl, setInstructionSignedUrl] = useState<string | null>(null);
  const [stimulusSignedUrl, setStimulusSignedUrl] = useState<string | null>(null);

  // The relevant "stimulus end" anchor is the stimulus audio if the item has
  // one, otherwise the instruction audio itself (see design doc section 2).
  const hasInstruction = !!item.instruction_audio_path;
  const hasStimulus = !!item.stimulus_audio_path;
  const disabled = response.stimulusFirstEndClientTs == null;

  useEffect(() => {
    let cancelled = false;
    (async () => {
      if (item.instruction_audio_path) {
        const url = await signedItemAudioUrl(item.instruction_audio_path).catch(() => null);
        if (!cancelled) setInstructionSignedUrl(url);
      }
      if (item.stimulus_audio_path) {
        const url = await signedItemAudioUrl(item.stimulus_audio_path).catch(() => null);
        if (!cancelled) setStimulusSignedUrl(url);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [item.id, item.instruction_audio_path, item.stimulus_audio_path]);

  // ROBUSTNESS: this instrument is audio-first by design, and every published
  // item is expected to carry instruction audio (the activation guard only
  // WARNS about a missing one, per src/lib/itemValidation.ts, so it is
  // possible in principle). Without this effect, an item with NEITHER
  // instruction nor stimulus audio would never fire an `ended` event and the
  // response controls would stay disabled forever. See PHASE_2_REPORT.md.
  useEffect(() => {
    if (!hasInstruction) {
      setInstructionDone(true);
      if (!hasStimulus) {
        const now = performance.now();
        onPatch({ stimulusFirstEndClientTs: now, stimulusLastEndClientTs: now });
      }
    }
    // Deliberately keyed on item.id only: this should run once when a NEW
    // item is shown, not on every onPatch-triggered re-render of the same item.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [item.id, hasInstruction, hasStimulus]);

  function markStimulusEnded() {
    const now = performance.now();
    onPatch({
      stimulusFirstEndClientTs: response.stimulusFirstEndClientTs ?? now,
      stimulusLastEndClientTs: now,
    });
  }

  function handleInstructionEnded() {
    setInstructionDone(true);
    if (!hasStimulus) markStimulusEnded();
    else stimulusRef.current?.play().catch(() => {});
  }

  function handleStimulusEnded() {
    markStimulusEnded();
  }

  function replayInstruction() {
    onPatch({ replayCountInstruction: response.replayCountInstruction + 1 });
    instructionRef.current?.play().catch(() => {});
  }

  function replayStimulus() {
    onPatch({ replayCountStimulus: response.replayCountStimulus + 1 });
    stimulusRef.current?.play().catch(() => {});
  }

  const canAdvance =
    response.hasAnswered &&
    (response.selectedOptionKey !== null || response.typedValue !== null || response.audioBlob !== null);

  const sharedProps: ResponseProps = {
    item,
    options,
    disabled,
    hasAnswered: response.hasAnswered,
    onFirstInteraction,
  };

  return (
    <div className="item-screen">
      {item.stimulus_text && (
        <p lang="bn" className="stimulus-text">
          {item.stimulus_text}
        </p>
      )}

      {instructionSignedUrl && (
        <audio ref={instructionRef} src={instructionSignedUrl} autoPlay onEnded={handleInstructionEnded} />
      )}
      {stimulusSignedUrl && (
        <audio
          ref={stimulusRef}
          src={stimulusSignedUrl}
          autoPlay={!hasInstruction}
          onEnded={handleStimulusEnded}
        />
      )}

      <div className="replay-row">
        {item.is_instruction_replayable && instructionDone && (
          <button type="button" className="replay-button" onPointerDown={replayInstruction}>
            🔊 নির্দেশনা আবার শুনুন
          </button>
        )}
        {hasStimulus && item.is_stimulus_replayable === true && response.stimulusFirstEndClientTs != null && (
          <button type="button" className="replay-button" onPointerDown={replayStimulus}>
            🔊 আবার শুনুন
          </button>
        )}
      </div>

      <div className={disabled ? 'response-area disabled' : 'response-area'}>
        {renderResponseComponent(item, response, sharedProps, onPatch)}
      </div>

      <button type="button" className="next-button" disabled={!canAdvance} onPointerDown={onAdvance}>
        পরবর্তী (Next)
      </button>
    </div>
  );
}

function renderResponseComponent(
  item: PublicItem,
  response: ResponseDraft,
  shared: ResponseProps,
  onPatch: (patch: Partial<ResponseDraft>) => void,
) {
  switch (item.response_format) {
    case 'MCQ_TAP':
      return (
        <McqTap {...shared} value={response.selectedOptionKey} onChange={(k) => onPatch({ selectedOptionKey: k })} />
      );
    case 'BINARY_TAP':
      return (
        <BinaryTap {...shared} value={response.selectedOptionKey} onChange={(k) => onPatch({ selectedOptionKey: k })} />
      );
    case 'TRI_TAP':
      return (
        <TriTap {...shared} value={response.selectedOptionKey} onChange={(k) => onPatch({ selectedOptionKey: k })} />
      );
    case 'LIKERT_5':
      return (
        <Likert5 {...shared} value={response.selectedOptionKey} onChange={(k) => onPatch({ selectedOptionKey: k })} />
      );
    case 'NUMERIC_KEYPAD':
      return (
        <NumericKeypad {...shared} value={response.typedValue} onChange={(v) => onPatch({ typedValue: v })} />
      );
    case 'AUDIO_RECORD':
      return (
        <AudioRecord
          {...shared}
          blob={response.audioBlob}
          mimeType={response.audioMimeType}
          durationMs={response.audioDurationMs}
          onRecorded={(blob, mimeType, durationMs) =>
            onPatch({ audioBlob: blob, audioMimeType: mimeType, audioDurationMs: durationMs })
          }
        />
      );
    default:
      return <p className="error">Unknown response format: {item.response_format}</p>;
  }
}
