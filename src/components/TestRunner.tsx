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
  hasRealAnswer,
  type LocalDraft,
  type ResponseDraft,
  type BackgroundInfo,
  type ConsentAnswers,
} from '../lib/localDraft';
import type { PublicItem, PublicItemOption, ResponseProps } from './responses/types';
import { isKeyboardClick } from './responses/types';
import McqTap from './responses/McqTap';
import BinaryTap from './responses/BinaryTap';
import TriTap from './responses/TriTap';
import Likert5 from './responses/Likert5';
import NumericKeypad from './responses/NumericKeypad';
import AudioRecord from './responses/AudioRecord';
import FlashJudgment from './responses/FlashJudgment';
import LetterSpan from './responses/LetterSpan';
import './testrunner.css';

type Phase =
  | 'loading'
  | 'no-items'
  | 'resume-prompt'
  | 'onboarding'
  | 'background-info'
  | 'consent-questions'
  | 'pre-test-intro'
  | 'domain-intro'
  | 'running'
  | 'ready-to-submit'
  | 'submitting'
  | 'submit-error'
  | 'complete';

/** Shown once at a *domain* transition (not every subdomain change), always
 * the same four lines regardless of how the participant has answered so far
 * -- there is no real-time scoring to react to (see the no-inline-scoring
 * architecture), and the paper calls for encouragement independent of
 * performance. Domains are numbered 1-5 after the renumbering in migration
 * 0016; index 0 (entering domain 1) never gets one, since there is nothing
 * to encourage yet. */
const ENCOURAGEMENT_LINES = [
  'তুমি খুব ভালো করছ! এভাবেই চালিয়ে যাও।',
  'অর্ধেকের বেশি হয়ে গেছে, দারুণ করছ!',
  'তুমি খুব মনোযোগ দিয়ে করছ।',
  'প্রায় শেষের দিকে চলে এসেছ, খুব ভালো করছ!',
];

/** A student may play an item's instruction or stimulus audio at most this many
 * times total, counting the first (now manually-triggered) play itself -- audio
 * never autoplays on load. Does NOT apply to the once-per-domain/subdomain
 * intro audio, which stays freely repeatable. Domain 1 (Short-term Memory --
 * Digit/Letter Span) is a memory-span task and gets a stricter override:
 * exactly one play, no replay at all -- see maxAudioPlays().
 *
 * NOTE: domain numbering was revised (migration 0016) so Short-term Memory
 * is domain '1', not the original '3' -- this check MUST stay in sync with
 * whichever domain currently holds that content, or the one-play rule
 * silently applies to the wrong domain. */
const MAX_ITEM_AUDIO_PLAYS = 3;

function maxAudioPlays(item: PublicItem): number {
  return item.domain === '1' ? 1 : MAX_ITEM_AUDIO_PLAYS;
}

/**
 * A demo/orientation item -- item_code's final segment (after the last ".")
 * is exactly "0" (e.g. "1.2.0", "4.1.0"), never merely a string ending in the
 * character "0" -- that would also wrongly match a real item like "4.1.10".
 * These walk the participant through how to answer a subtask (their own
 * written/audio instructions guide them to the right answer) and are never
 * submitted to the server at all -- see handleSubmit's filter below. This is
 * the single source of truth for demo-item behavior; is_practice in the
 * database is set alongside it for the Item Bank Editor's own display, but
 * this naming convention is authoritative at runtime.
 */
function isDemoItem(item: PublicItem): boolean {
  return item.item_code.split('.').pop() === '0';
}

/**
 * Wraps a click handler so it only runs for keyboard-triggered clicks (Enter/
 * Space on a focused button) -- see isKeyboardClick's doc comment. Pair with
 * onPointerDown on the same button so mouse/touch and keyboard both work
 * without double-firing on a real tap.
 */
function onKeyboardActivate(handler: () => void) {
  return (e: { detail: number }) => {
    if (isKeyboardClick(e)) handler();
  };
}

/**
 * `item` supplies whether instruction/stimulus audio exist at all -- an item
 * with none gets NULL replay counts ("not applicable"), not 0 ("had audio,
 * replayed zero times"). See migration 0011.
 */
function emptyResponseDraft(item: PublicItem): ResponseDraft {
  return {
    itemId: item.id,
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
    replayCountInstruction: item.instruction_audio_path ? 0 : null,
    replayCountStimulus: item.stimulus_audio_path ? 0 : null,
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

const AGE_KEYS = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '⌫', '0', 'C'];

/**
 * Age entry for the background-info phase. Not a response component (no
 * onFirstInteraction/latency contract) since this screen is explicitly
 * excluded from time tracking -- a small inline keypad rather than reusing
 * NumericKeypad, which is built around the ResponseProps/latency contract
 * every real item uses.
 */
function AgeStep({ onSubmit }: { onSubmit: (age: number) => void }) {
  const [value, setValue] = useState('');

  function press(key: string) {
    if (key === '⌫') setValue((v) => v.slice(0, -1));
    else if (key === 'C') setValue('');
    else if (value.length < 2) setValue((v) => v + key);
  }

  const age = Number(value);
  const valid = value.length > 0 && age >= 5 && age <= 20;

  return (
    <>
      <h1 lang="bn">তোমার বয়স কত?</h1>
      <p className="muted small">What is your age, in years?</p>
      <div className="numeric-keypad">
        <div className="numeric-display" aria-live="polite" aria-label="Typed age">
          {value.length > 0 ? value : <span className="numeric-placeholder">—</span>}
        </div>
        <div className="numeric-keys">
          {AGE_KEYS.map((k) => (
            <button
              key={k}
              type="button"
              className="numeric-key"
              onPointerDown={() => press(k)}
              onClick={onKeyboardActivate(() => press(k))}
            >
              {k}
            </button>
          ))}
        </div>
      </div>
      <button
        type="button"
        className="big-choice-button primary"
        disabled={!valid}
        onPointerDown={() => valid && onSubmit(age)}
        onClick={onKeyboardActivate(() => valid && onSubmit(age))}
      >
        পরবর্তী (Next)
      </button>
    </>
  );
}

type DomainIntro = {
  domain: string;
  subdomain: string | null;
  intro_text: string;
  intro_audio_path: string | null;
};

export default function TestRunner() {
  const [phase, setPhase] = useState<Phase>('loading');
  const [error, setError] = useState<string | null>(null);
  const [items, setItems] = useState<PublicItem[]>([]);
  const [optionsByItem, setOptionsByItem] = useState<Record<string, PublicItemOption[]>>({});
  const [draft, setDraft] = useState<LocalDraft | null>(null);
  const draftRef = useRef<LocalDraft | null>(null);
  const introsRef = useRef<Map<string, DomainIntro>>(new Map());
  const [pendingIntroIndex, setPendingIntroIndex] = useState<number | null>(null);
  const [currentIntro, setCurrentIntro] = useState<DomainIntro | null>(null);
  const [currentEncouragement, setCurrentEncouragement] = useState<string | null>(null);

  // Scopes the pastel test-flow theme (testrunner.css) to <body> only while this
  // component is mounted, so the admin panel's plain palette is never affected.
  useEffect(() => {
    document.body.classList.add('badsq-test-mode');
    return () => document.body.classList.remove('badsq-test-mode');
  }, []);

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
          // Fixed presentation order, identical for every participant, taken
          // from item_options.display_order (migration 0023).
          //
          // Options used to be sorted by option_key and then shuffled for the
          // choice formats. Both are gone:
          //
          //   * The key sort silently broke when migration 0014 replaced
          //     A/B/C/D/E with semantic tokens — keys then sorted
          //     alphabetically by English word, which scrambled every ordered
          //     scale (the Likert-5 rendered সবসময় → প্রায়ই → খুব কম → কখনো না
          //     → মাঝে মাঝে). Order now lives in its own column because
          //     option_key can no longer carry it.
          //
          //   * The shuffle removed position bias, but it also put an
          //     unrecorded random component into response latency — the
          //     presented order was never stored, so that variance could not
          //     be modelled or even reconstructed downstream. Latency is a
          //     primary measure here, so that cost outweighs the benefit. The
          //     4.1 answer key was rebalanced to A:2/B:2/C:3/D:3 in migration
          //     0016, so a fixed order does not park the correct answer in one
          //     position.
          //
          // Ties and NULLs fall back to option_key so ordering is always total
          // and never depends on the order PostgREST happened to return rows.
          for (const list of Object.values(optionsMap)) {
            list.sort(
              (a, b) =>
                (a.display_order ?? 99) - (b.display_order ?? 99) ||
                a.option_key.localeCompare(b.option_key),
            );
          }
        }

        const { data: introRows, error: introErr } = await supabase
          .from('domain_intros')
          .select('domain, subdomain, intro_text, intro_audio_path');
        if (introErr) throw introErr;
        introsRef.current = new Map(
          ((introRows ?? []) as DomainIntro[]).map((i) => [`${i.domain}|${i.subdomain ?? ''}`, i]),
        );

        const existing = await loadDraft();

        if (cancelled) return;
        setItems(liveItems);
        setOptionsByItem(optionsMap);

        if (liveItems.length === 0) {
          setPhase('no-items');
          return;
        }

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
      setPhase('onboarding');
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  }

  function consentComplete(c: ConsentAnswers): boolean {
    return c.q1DoctorEval !== null && c.q2ExtraPrimarySupport !== null && c.q3FamilyHistory !== null;
  }

  async function handleResumeYes() {
    const d = draftRef.current;
    if (!d) return;
    if (!d.classGrade) {
      setPhase('background-info');
      return;
    }
    if (!consentComplete(d.consent)) {
      setPhase('consent-questions');
      return;
    }
    enterItemOrIntro(d.currentItemIndex);
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

  // ---------------------------------------------------- background info
  // No time tracking here, per instruction -- these are demographic/fairness
  // fields (see design doc), not test responses, so nothing about the timing
  // of answering them is recorded.
  const [bgStep, setBgStep] = useState<'age' | 'class' | 'gender' | 'home_area'>('age');

  function patchBackground(patch: Partial<BackgroundInfo>) {
    if (!draftRef.current) return;
    setAndPersistDraft({ ...draftRef.current, background: { ...draftRef.current.background, ...patch } });
  }

  function setAgeYears(age: number) {
    patchBackground({ ageYears: age });
    setBgStep('class');
  }

  function setClassGrade(grade: 6 | 7 | 8) {
    if (!draftRef.current) return;
    setAndPersistDraft({ ...draftRef.current, classGrade: grade });
    setBgStep('gender');
  }

  function setGender(gender: BackgroundInfo['gender']) {
    patchBackground({ gender });
    setBgStep('home_area');
  }

  function setHomeArea(homeArea: BackgroundInfo['homeArea']) {
    patchBackground({ homeArea });
    setPhase('consent-questions');
  }

  // ---------------------------------------------------- consent questions
  // Replicates the three family-history questions from the paper parental-
  // consent form -- the participant selects what their parent already marked
  // there. No time tracking, same reasoning as background info.
  const [consentStep, setConsentStep] = useState<'q1' | 'q2' | 'q3'>('q1');

  function patchConsent(patch: Partial<ConsentAnswers>) {
    if (!draftRef.current) return;
    setAndPersistDraft({ ...draftRef.current, consent: { ...draftRef.current.consent, ...patch } });
  }

  function setQ1(choice: 'doctor' | 'school' | 'no' | 'not_sure') {
    patchConsent({
      q1DoctorEval: choice === 'doctor',
      q1SchoolEval: choice === 'school',
      q1NotSure: choice === 'not_sure',
    });
    setConsentStep('q2');
  }

  function setQ2(value: ConsentAnswers['q2ExtraPrimarySupport']) {
    patchConsent({ q2ExtraPrimarySupport: value });
    setConsentStep('q3');
  }

  function setQ3(value: ConsentAnswers['q3FamilyHistory']) {
    patchConsent({ q3FamilyHistory: value });
    setPhase('pre-test-intro');
  }

  // ------------------------------------------------------------- running
  const currentIndex = draft?.currentItemIndex ?? 0;
  const currentItem = items[currentIndex] ?? null;

  /** Does the item at `index` start a new domain/subdomain group -- i.e. does
   * it need an intro screen before it? Index 0 always does (start of the
   * first group). Fixed, non-adaptive order, so this is a pure function of
   * position -- see design doc: no randomization of item/section order. */
  function needsIntroBefore(index: number): boolean {
    if (index <= 0 || index >= items.length) return index === 0 && items.length > 0;
    const cur = items[index];
    const prev = items[index - 1];
    return cur.domain !== prev.domain || cur.subdomain !== prev.subdomain;
  }

  function introFor(index: number): DomainIntro | undefined {
    const item = items[index];
    if (!item) return undefined;
    return (
      introsRef.current.get(`${item.domain}|${item.subdomain ?? ''}`) ??
      introsRef.current.get(`${item.domain}|`)
    );
  }

  /** True only at a *domain* boundary (not a subdomain-only change within the
   * same domain) -- encouragement lines are between-domain, per the paper. */
  function isNewDomain(index: number): boolean {
    if (index <= 0 || index >= items.length) return false;
    return items[index].domain !== items[index - 1].domain;
  }

  /** One of ENCOURAGEMENT_LINES, picked deterministically from the domain
   * number being entered (domains are '1'-'5' after migration 0016) -- never
   * from participant performance, and stable across a resumed session. */
  function encouragementFor(index: number): string | null {
    if (!isNewDomain(index)) return null;
    const domainNum = Number(items[index].domain);
    if (!Number.isFinite(domainNum)) return null;
    const i = ((domainNum - 2) % ENCOURAGEMENT_LINES.length + ENCOURAGEMENT_LINES.length) % ENCOURAGEMENT_LINES.length;
    return ENCOURAGEMENT_LINES[i];
  }

  /** Route to `index`'s item, via its domain/subdomain intro screen first if
   * one exists and hasn't been shown yet for this group, or an encouragement
   * line if this is a domain boundary (shown even where no domain_intros
   * content has been authored yet for that domain). */
  function enterItemOrIntro(index: number) {
    if (!draftRef.current) return;
    if (index >= items.length) {
      setPhase('ready-to-submit');
      return;
    }
    if (needsIntroBefore(index)) {
      const intro = introFor(index) ?? null;
      const encouragement = encouragementFor(index);
      if (intro || encouragement) {
        setCurrentIntro(intro);
        setCurrentEncouragement(encouragement);
        setPendingIntroIndex(index);
        setPhase('domain-intro');
        return;
      }
    }
    setAndPersistDraft({ ...draftRef.current, currentItemIndex: index });
    setPhase('running');
  }

  function handleIntroContinue() {
    if (!draftRef.current || pendingIntroIndex === null) return;
    setAndPersistDraft({ ...draftRef.current, currentItemIndex: pendingIntroIndex });
    setPendingIntroIndex(null);
    setCurrentIntro(null);
    setCurrentEncouragement(null);
    setPhase('running');
  }

  function updateCurrentResponse(patch: Partial<ResponseDraft>) {
    if (!draftRef.current || !currentItem) return;
    const prev = draftRef.current.responses[currentItem.id] ?? emptyResponseDraft(currentItem);
    const next: LocalDraft = {
      ...draftRef.current,
      responses: { ...draftRef.current.responses, [currentItem.id]: { ...prev, ...patch } },
    };
    setAndPersistDraft(next);
  }

  function handleFirstInteraction(pointerType: string) {
    if (!currentItem) return;
    const now = performance.now();
    const r = draftRef.current?.responses[currentItem.id] ?? emptyResponseDraft(currentItem);
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
    if (pointerType === 'touch' || pointerType === 'mouse' || pointerType === 'pen' || pointerType === 'keyboard') {
      return pointerType;
    }
    return 'unknown';
  }

  function goToNextItem() {
    if (!draftRef.current) return;
    enterItemOrIntro(draftRef.current.currentItemIndex + 1);
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
        // Demo/orientation items (item_code ending ".0") are never part of
        // the dataset -- the participant is guided through them by their own
        // written/audio instructions, not independently tested.
        if (isDemoItem(item)) continue;
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
        p_participant: {
          class_grade: String(d.classGrade),
          age_years: d.background.ageYears != null ? String(d.background.ageYears) : '',
          gender: d.background.gender ?? '',
          home_area: d.background.homeArea ?? '',
        },
        p_responses: responsesPayload,
        p_consent: {
          q1_doctor_eval: d.consent.q1DoctorEval,
          q1_school_eval: d.consent.q1SchoolEval,
          q1_not_sure: d.consent.q1NotSure,
          q2_extra_primary_support: d.consent.q2ExtraPrimarySupport,
          q3_family_history: d.consent.q3FamilyHistory,
        },
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

  if (phase === 'no-items') {
    return (
      <main className="runner-shell">
        <div className="tr-card">
          <h1 lang="bn">এখনো কোনো প্রশ্ন যোগ করা হয়নি</h1>
          <p className="muted small">
            No test items are configured yet. Please tell your teacher or the research team.
          </p>
        </div>
      </main>
    );
  }

  if (phase === 'resume-prompt') {
    return (
      <main className="runner-shell resume-prompt">
        <div className="tr-card">
          <h1 lang="bn">আপনি কি চালিয়ে যেতে চান?</h1>
          <p lang="bn">
            মনে হচ্ছে একটি অসম্পূর্ণ সেশন আছে। আপনি কি আগের সেশন চালিয়ে যেতে চান, নাকি এটি একজন ভিন্ন শিক্ষার্থী?
          </p>
          <p className="muted small">
            (Is this you continuing your earlier session, or a different student? A shared device
            never resumes automatically.)
          </p>
          <div className="big-choice-row">
            <button
              type="button"
              className="big-choice-button"
              onPointerDown={() => void handleResumeYes()}
              onClick={onKeyboardActivate(() => void handleResumeYes())}
            >
              হ্যাঁ, চালিয়ে যাব
            </button>
            <button
              type="button"
              className="big-choice-button"
              onPointerDown={() => void handleResumeNo()}
              onClick={onKeyboardActivate(() => void handleResumeNo())}
            >
              না, নতুন শিক্ষার্থী
            </button>
          </div>
        </div>
      </main>
    );
  }

  // Two written-instruction screens, both deliberately outside all timing:
  // no onFirstInteraction wiring, no latency capture, nothing recorded --
  // they exist only to be read. 'onboarding' runs before the background-info
  // questions; 'pre-test-intro' runs after those and the consent questions,
  // immediately before the first domain.
  if (phase === 'onboarding') {
    return (
      <main className="runner-shell">
        <div className="tr-card">
          <p lang="bn" className="stimulus-text">
            শুরু করার আগে তোমার সম্পর্কে কয়েকটা ছোট তথ্য জানতে চাই। এটা কোনো প্রশ্নের উত্তর না, শুধু তোমার বয়স,
            শ্রেণি, এবং তুমি কোথায় থাকো, এইটুকু জানলে হবে। তোমার বয়স কত, সংখ্যায় লিখো। তারপর তুমি কোন শ্রেণিতে
            পড়ো, আর তুমি ছেলে না মেয়ে, সেটা বলো, যদি বলতে না চাও তাহলে "বলতে চাই না"-তে চাপ দিতে পারো। সবশেষে
            তুমি শহরে থাকো না গ্রামে থাকো, সেটা বলো। এবার শুরু করি।
          </p>
          <button
            type="button"
            className="big-choice-button primary"
            onPointerDown={() => setPhase('background-info')}
            onClick={onKeyboardActivate(() => setPhase('background-info'))}
          >
            শুরু করি (Start)
          </button>
        </div>
      </main>
    );
  }

  if (phase === 'pre-test-intro') {
    return (
      <main className="runner-shell">
        <div className="tr-card">
          <p lang="bn" className="stimulus-text">
            হ্যালো! আজ আমরা কয়েকটা মজার খেলা খেলব। প্রথমে তোমার সম্পর্কে ছোট কয়েকটা প্রশ্ন, তারপর ৫টা ধাপের
            খেলা, আর সবশেষে নিজের সম্পর্কে আরও কয়েকটা ছোট প্রশ্ন। প্রতিটা ধাপ শুরুর আগে আমি তোমাকে বলে দেব কী
            করতে হবে, আর একটা ছোট প্র্যাকটিসও করতে পারবে। কোনো উত্তর ভুল হলে চিন্তার কিছু নেই, এটা পরীক্ষা না,
            শুধু তোমাকে বোঝার একটা উপায়। কোনো নির্দেশনা আবার শুনতে চাইলে বাটনে চাপ দিও। তৈরি? চলো শুরু করি।
          </p>
          <button
            type="button"
            className="big-choice-button primary"
            onPointerDown={() => enterItemOrIntro(0)}
            onClick={onKeyboardActivate(() => enterItemOrIntro(0))}
          >
            চলো শুরু করি (Continue)
          </button>
        </div>
      </main>
    );
  }

  if (phase === 'background-info') {
    return (
      <main className="runner-shell">
        <div className="tr-card">
          {bgStep === 'age' && (
            <AgeStep onSubmit={setAgeYears} />
          )}
          {bgStep === 'class' && (
            <>
              <h1 lang="bn">তোমার শ্রেণি কত?</h1>
              <p className="muted small">What class/grade are you in?</p>
              <div className="big-choice-row">
                {[6, 7, 8].map((g) => (
                  <button
                    key={g}
                    type="button"
                    className="big-choice-button"
                    onPointerDown={() => setClassGrade(g as 6 | 7 | 8)}
                    onClick={onKeyboardActivate(() => setClassGrade(g as 6 | 7 | 8))}
                  >
                    {g}
                  </button>
                ))}
              </div>
            </>
          )}
          {bgStep === 'gender' && (
            <>
              <h1 lang="bn">তুমি কি ছেলে, মেয়ে, নাকি বলতে চাও না?</h1>
              <p className="muted small">Are you a boy, a girl, or would you rather not say?</p>
              <div className="big-choice-row">
                <button
                  type="button"
                  className="big-choice-button"
                  onPointerDown={() => setGender('boy')}
                  onClick={onKeyboardActivate(() => setGender('boy'))}
                >
                  ছেলে
                </button>
                <button
                  type="button"
                  className="big-choice-button"
                  onPointerDown={() => setGender('girl')}
                  onClick={onKeyboardActivate(() => setGender('girl'))}
                >
                  মেয়ে
                </button>
                <button
                  type="button"
                  className="big-choice-button"
                  onPointerDown={() => setGender('prefer_not_to_say')}
                  onClick={onKeyboardActivate(() => setGender('prefer_not_to_say'))}
                >
                  বলতে চাই না
                </button>
              </div>
            </>
          )}
          {bgStep === 'home_area' && (
            <>
              <h1 lang="bn">তুমি কি শহরে থাকো, নাকি গ্রামে?</h1>
              <p className="muted small">Do you live in a city (urban) or a village (rural)?</p>
              <div className="big-choice-row">
                <button
                  type="button"
                  className="big-choice-button"
                  onPointerDown={() => setHomeArea('urban')}
                  onClick={onKeyboardActivate(() => setHomeArea('urban'))}
                >
                  শহর
                </button>
                <button
                  type="button"
                  className="big-choice-button"
                  onPointerDown={() => setHomeArea('rural')}
                  onClick={onKeyboardActivate(() => setHomeArea('rural'))}
                >
                  গ্রাম
                </button>
              </div>
            </>
          )}
        </div>
      </main>
    );
  }

  if (phase === 'consent-questions') {
    return (
      <main className="runner-shell">
        <div className="tr-card">
          {consentStep === 'q1' && (
            <>
              <h1 lang="bn">
                তোমার পড়া বা লেখায় সমস্যার জন্য কোনো ডাক্তার, মনোবিজ্ঞানী বা বিদ্যালয় কর্তৃক পরীক্ষা করানো হয়েছে?
              </h1>
              <p className="muted small">
                Has your parent told you whether any doctor, psychologist, or school ever tested you
                for a reading/writing difficulty? Pick what they marked on the paper form.
              </p>
              <div className="big-choice-row">
                <button type="button" className="big-choice-button" onPointerDown={() => setQ1('doctor')} onClick={onKeyboardActivate(() => setQ1('doctor'))}>
                  হ্যাঁ, ডাক্তার/মনোবিজ্ঞানী দ্বারা
                </button>
                <button type="button" className="big-choice-button" onPointerDown={() => setQ1('school')} onClick={onKeyboardActivate(() => setQ1('school'))}>
                  হ্যাঁ, বিদ্যালয় কর্তৃক
                </button>
                <button type="button" className="big-choice-button" onPointerDown={() => setQ1('no')} onClick={onKeyboardActivate(() => setQ1('no'))}>
                  না
                </button>
                <button type="button" className="big-choice-button" onPointerDown={() => setQ1('not_sure')} onClick={onKeyboardActivate(() => setQ1('not_sure'))}>
                  নিশ্চিত না
                </button>
              </div>
            </>
          )}
          {consentStep === 'q2' && (
            <>
              <h1 lang="bn">
                প্রাথমিক বিদ্যালয়ে (শ্রেণি ১-৫) থাকা অবস্থায় পড়া বা লেখায় সমস্যার জন্য তোমার কি অতিরিক্ত সাহায্য নিতে হয়েছিল?
              </h1>
              <p className="muted small">
                Did you need extra help while in primary school (classes 1-5) because of
                reading/writing difficulty? Pick what your parent marked.
              </p>
              <div className="big-choice-row">
                <button type="button" className="big-choice-button" onPointerDown={() => setQ2('yes')} onClick={onKeyboardActivate(() => setQ2('yes'))}>
                  হ্যাঁ
                </button>
                <button type="button" className="big-choice-button" onPointerDown={() => setQ2('no')} onClick={onKeyboardActivate(() => setQ2('no'))}>
                  না
                </button>
                <button type="button" className="big-choice-button" onPointerDown={() => setQ2('not_sure')} onClick={onKeyboardActivate(() => setQ2('not_sure'))}>
                  নিশ্চিত না
                </button>
              </div>
            </>
          )}
          {consentStep === 'q3' && (
            <>
              <h1 lang="bn">
                তোমার পরিবারে (মা, বাবা, ভাই অথবা বোন) কারো পড়তে, বানান বা লিখতে ডিসলেক্সিয়ার ধরনের সমস্যা আছে বা ছিল বলে চিহ্নিত হয়েছে?
              </h1>
              <p className="muted small">
                Has anyone in your family (mother, father, brother, or sister) been identified with a
                dyslexia-type difficulty? Pick what your parent marked.
              </p>
              <div className="big-choice-row">
                <button type="button" className="big-choice-button" onPointerDown={() => setQ3('yes')} onClick={onKeyboardActivate(() => setQ3('yes'))}>
                  হ্যাঁ
                </button>
                <button type="button" className="big-choice-button" onPointerDown={() => setQ3('no')} onClick={onKeyboardActivate(() => setQ3('no'))}>
                  না
                </button>
                <button type="button" className="big-choice-button" onPointerDown={() => setQ3('not_sure')} onClick={onKeyboardActivate(() => setQ3('not_sure'))}>
                  নিশ্চিত না
                </button>
              </div>
            </>
          )}
        </div>
      </main>
    );
  }

  if (phase === 'domain-intro' && (currentIntro || currentEncouragement)) {
    return (
      <main className="runner-shell">
        <div className="tr-card">
          {currentEncouragement && (
            <p lang="bn" className="encouragement-line">
              {currentEncouragement}
            </p>
          )}
          {currentIntro && (
            <p lang="bn" className="stimulus-text">
              {currentIntro.intro_text}
            </p>
          )}
          <button
            type="button"
            className="big-choice-button primary"
            onPointerDown={handleIntroContinue}
            onClick={onKeyboardActivate(handleIntroContinue)}
          >
            চলো শুরু করি (Continue)
          </button>
        </div>
      </main>
    );
  }

  if (phase === 'running' && currentItem && draft) {
    const response = draft.responses[currentItem.id] ?? emptyResponseDraft(currentItem);
    const progressPercent = Math.round(((currentIndex + 1) / items.length) * 100);
    return (
      <main className="runner-shell">
        <div className="progress-wrap">
          <div
            className="progress-track"
            role="progressbar"
            aria-valuenow={progressPercent}
            aria-valuemin={0}
            aria-valuemax={100}
          >
            <div className="progress-fill" style={{ width: `${progressPercent}%` }} />
          </div>
          <p className="progress-indicator">
            {currentIndex + 1} / {items.length}
          </p>
        </div>
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
        <div className="tr-card">
          <h1 lang="bn">সব প্রশ্নের উত্তর দেওয়া হয়েছে</h1>
          <p className="muted small">All items answered. Submit when ready.</p>
          <button
            type="button"
            className="big-choice-button primary"
            disabled={!readyToSubmit}
            onPointerDown={() => void handleSubmit()}
            onClick={onKeyboardActivate(() => void handleSubmit())}
          >
            জমা দিন (Submit)
          </button>
        </div>
      </main>
    );
  }

  if (phase === 'submitting') {
    return (
      <main className="runner-shell">
        <div className="tr-card">
          <p className="muted" lang="bn">
            জমা দেওয়া হচ্ছে…
          </p>
        </div>
      </main>
    );
  }

  if (phase === 'submit-error') {
    return (
      <main className="runner-shell">
        <div className="tr-card">
          <h1>Not yet submitted</h1>
          <p className="error">
            Something went wrong sending your answers: {error}. Your answers are still saved on
            this device — nothing has been lost. Try again.
          </p>
          <button
            type="button"
            className="big-choice-button primary"
            onPointerDown={() => void handleSubmit()}
            onClick={onKeyboardActivate(() => void handleSubmit())}
          >
            Try submitting again
          </button>
        </div>
      </main>
    );
  }

  if (phase === 'complete' && draft) {
    return (
      <main className="runner-shell complete-screen">
        <div className="tr-card">
          <h1 lang="bn">🎉 ধন্যবাদ!</h1>
          <p lang="bn" className="stimulus-text">
            সব শেষ। তুমি খুব ভালো করেছ। অংশগ্রহণ করার জন্য অনেক ধন্যবাদ।
          </p>
          <p className="muted small">Thank you — your answers have been submitted.</p>
          <p>Please tell your teacher this code so it can be written on your form:</p>
          <p className="assigned-code">{draft.assignedCode}</p>
          <a href="#/" className="big-choice-button primary home-link">
            হোমে ফিরে যাও (Return home)
          </a>
        </div>
      </main>
    );
  }

  // Defensive fallback: every real phase is handled above, so reaching here means
  // an unexpected state combination (e.g. 'running' with no current item). Show
  // something actionable instead of a blank screen.
  return (
    <main className="runner-shell">
      <div className="tr-card">
        <h1>Something went wrong</h1>
        <p className="muted small">
          The test could not continue from here. Please tell your teacher, or reload the page.
        </p>
      </div>
    </main>
  );
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

  const maxPlays = maxAudioPlays(item);
  const notYetPlayed = disabled && (hasInstruction || hasStimulus);

  function markStimulusEnded() {
    const now = performance.now();
    onPatch({
      stimulusFirstEndClientTs: response.stimulusFirstEndClientTs ?? now,
      stimulusLastEndClientTs: now,
    });
  }

  function handleInstructionEnded() {
    setInstructionDone(true);
    if (!hasStimulus) {
      markStimulusEnded();
      return;
    }
    // Chains straight into the stimulus, same as before -- but now that a
    // play here counts against the stimulus's own budget too (every actual
    // playback counts, not just explicit replay-button presses), only chain
    // if that budget isn't already exhausted from independent stimulus-only
    // replays. The very first play always has budget, so items always unlock.
    if ((response.replayCountStimulus ?? 0) < maxPlays) {
      onPatch({ replayCountStimulus: (response.replayCountStimulus ?? 0) + 1 });
      stimulusRef.current?.play().catch(() => {});
    }
  }

  function handleStimulusEnded() {
    markStimulusEnded();
  }

  // Every actual playback counts toward the cap, including the first --
  // audio never autoplays (see notYetPlayed/playFirst below), so there is no
  // more implicit free play to reserve budget for. Domain 3 gets maxPlays = 1
  // via maxAudioPlays(); every other domain gets MAX_ITEM_AUDIO_PLAYS (3).
  const instructionReplaysLeft = hasInstruction && (response.replayCountInstruction ?? 0) < maxPlays;
  const stimulusReplaysLeft = hasStimulus && (response.replayCountStimulus ?? 0) < maxPlays;

  /** The one manually-triggered first play, covering both instruction and
   * (via handleInstructionEnded's chain) stimulus audio in one action. */
  function playFirst() {
    if (hasInstruction) {
      onPatch({ replayCountInstruction: (response.replayCountInstruction ?? 0) + 1 });
      instructionRef.current?.play().catch(() => {});
    } else if (hasStimulus) {
      onPatch({ replayCountStimulus: (response.replayCountStimulus ?? 0) + 1 });
      stimulusRef.current?.play().catch(() => {});
    }
  }

  function replayInstruction() {
    if (!instructionReplaysLeft) return;
    onPatch({ replayCountInstruction: (response.replayCountInstruction ?? 0) + 1 });
    instructionRef.current?.play().catch(() => {});
  }

  function replayStimulus() {
    if (!stimulusReplaysLeft) return;
    onPatch({ replayCountStimulus: (response.replayCountStimulus ?? 0) + 1 });
    stimulusRef.current?.play().catch(() => {});
  }

  const canAdvance = response.hasAnswered && hasRealAnswer(response);

  // Demo items (item_code ending ".0" -- see isDemoItem) get an immediate
  // right/wrong reveal before advancing -- real items never do, and never
  // carry an answer key the client can see at all (practice_correct_answer
  // is NULL for every non-demo item). The "Next" press does double duty:
  // first press reveals feedback, second press actually advances.
  const isDemo = isDemoItem(item);
  const [practiceRevealed, setPracticeRevealed] = useState(false);
  useEffect(() => {
    setPracticeRevealed(false);
  }, [item.id]);

  // Three kinds of demo item, because "was that right?" isn't answerable the
  // same way for all of them:
  //   - a tapped/typed answer with a key -> compare and say right/wrong
  //   - AUDIO_RECORD -> we cannot judge speech, so just show the expected
  //     answer as a neutral reference next to what they recorded
  //   - no answer key at all (self-report demos like 3.2.0) -> nothing to
  //     check, so skip the reveal step entirely and just advance
  const demoAnswer = isDemo ? item.practice_correct_answer : null;
  const demoIsAudio = item.response_format === 'AUDIO_RECORD';
  const demoChecks = isDemo && demoAnswer != null && !demoIsAudio;
  const practiceCorrect = demoChecks
    ? (response.typedValue ?? response.selectedOptionKey ?? '').trim() === demoAnswer.trim()
    : null;
  const demoRevealPending = isDemo && demoAnswer != null && !practiceRevealed;

  /**
   * The ONLY route from one item to the next.
   *
   * The button's `disabled` attribute is a visual affordance, not a guarantee:
   * a fast double-tap can land a second pointerdown in the window before React
   * has re-rendered the freshly-mounted next item's button as disabled, which
   * skipped an item outright. So the rule is enforced here, in logic, and the
   * advance is made idempotent per item — `advancedRef` lives on an ItemScreen
   * that is keyed by item id, so it resets on its own for each new item and
   * one item can never advance twice.
   */
  const advancedRef = useRef(false);

  function handleNext() {
    if (!canAdvance || advancedRef.current) return;
    if (demoRevealPending) {
      setPracticeRevealed(true);
      return;
    }
    advancedRef.current = true;
    onAdvance();
  }

  const sharedProps: ResponseProps = {
    item,
    options,
    disabled,
    hasAnswered: response.hasAnswered,
    onFirstInteraction,
  };

  return (
    <div className="item-screen">
      {/* FLASH_JUDGMENT manages its own display of stimulus_text (shown briefly,
          then hidden before the response buttons appear) -- showing it here
          too would defeat the whole point of the format. */}
      {item.stimulus_text && item.response_format !== 'FLASH_JUDGMENT' && (
        <p lang="bn" className="stimulus-text">
          {item.stimulus_text}
        </p>
      )}

      {instructionSignedUrl && (
        <audio ref={instructionRef} src={instructionSignedUrl} onEnded={handleInstructionEnded} />
      )}
      {stimulusSignedUrl && (
        <audio ref={stimulusRef} src={stimulusSignedUrl} onEnded={handleStimulusEnded} />
      )}

      {notYetPlayed && (
        <div className="replay-row">
          <button
            type="button"
            className="replay-button primary"
            onPointerDown={playFirst}
            onClick={onKeyboardActivate(playFirst)}
          >
            🔊 অডিও শুনুন (Play audio)
          </button>
        </div>
      )}

      <div className="replay-row">
        {!disabled && hasInstruction && item.is_instruction_replayable && instructionDone && instructionReplaysLeft && (
          <button
            type="button"
            className="replay-button"
            onPointerDown={replayInstruction}
            onClick={onKeyboardActivate(replayInstruction)}
          >
            🔊 নির্দেশনা আবার শুনুন
          </button>
        )}
        {hasStimulus &&
          item.is_stimulus_replayable === true &&
          response.stimulusFirstEndClientTs != null &&
          stimulusReplaysLeft && (
            <button
              type="button"
              className="replay-button"
              onPointerDown={replayStimulus}
              onClick={onKeyboardActivate(replayStimulus)}
            >
              🔊 আবার শুনুন
            </button>
          )}
      </div>

      <div className={disabled ? 'response-area disabled' : 'response-area'}>
        {renderResponseComponent(item, response, sharedProps, onPatch)}
      </div>

      {isDemo && practiceRevealed && demoAnswer != null && (
        <div
          className={
            !demoChecks
              ? 'practice-feedback neutral'
              : practiceCorrect
                ? 'practice-feedback correct'
                : 'practice-feedback incorrect'
          }
        >
          {!demoChecks ? (
            <p lang="bn">
              প্রত্যাশিত উত্তর ছিল: <strong>{demoAnswer}</strong>
            </p>
          ) : practiceCorrect ? (
            <p lang="bn">✓ সঠিক হয়েছে!</p>
          ) : (
            <p lang="bn">
              এটি ঠিক হয়নি। সঠিক উত্তর ছিল: <strong>{demoAnswer}</strong>
            </p>
          )}
        </div>
      )}

      <button
        type="button"
        className="next-button"
        disabled={!canAdvance}
        onPointerDown={handleNext}
        onClick={onKeyboardActivate(handleNext)}
      >
        {demoRevealPending ? 'উত্তর দেখুন (Check)' : 'পরবর্তী (Next)'}
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
    case 'FLASH_JUDGMENT':
      return (
        <FlashJudgment
          {...shared}
          value={response.selectedOptionKey}
          onChange={(k) => onPatch({ selectedOptionKey: k })}
        />
      );
    case 'LETTER_SPAN':
      return (
        <LetterSpan {...shared} value={response.typedValue} onChange={(v) => onPatch({ typedValue: v })} />
      );
    default:
      return <p className="error">Unknown response format: {item.response_format}</p>;
  }
}
