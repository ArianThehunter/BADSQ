# Accessibility Conformance Statement — BADSQ Participant Interface

**Standard:** Web Content Accessibility Guidelines (WCAG) 2.2, Level AA
**Subject:** the participant-facing interface (landing page and test flow). The researcher admin
panel is **not** covered by this statement.
**Date of assessment:** 2026-09-16
**Repository state:** commit `124ebe8` and later

---

## Conformance claim

> The BADSQ participant interface conforms to **WCAG 2.2 Level AA**, with one stated exception:
> **SC 1.2.1 Audio-only (Prerecorded)**, which cannot be satisfied without invalidating what the
> instrument measures. Functional hearing is an explicit eligibility criterion for participation.

This is a *partial* conformance claim. It should be quoted with the exception attached; quoting
the first clause alone would misrepresent the instrument.

---

## How this was assessed, and what that supports

| Method | Covers | Performed by |
|---|---|---|
| Source review of all participant-facing components and stylesheets | Semantics, keyboard operability, focus handling, language marking, target sizing | Static analysis |
| Arithmetic computation of every foreground/background pair from declared values, per the WCAG relative-luminance formula (including alpha-composited tints) | 1.4.3, 1.4.11 | Computed, not sampled |
| Direct query of the live item bank (93 active items) | 1.2.1 — audio/text coverage | Database query |
| Parsing of the WOFF2 font binary | Bengali shaping support | Binary inspection |
| **Manual browser testing at 320 px and with text-spacing overrides applied** | **1.4.10, 1.4.12** | **Researcher, 2026-09-16** |

**Limits of this assessment, stated so they are not overread:** no screen reader was run, and no
assistive technology was tested. Conclusions about screen-reader behaviour are inferred from
markup, not observed. 1.4.10 and 1.4.12 were confirmed by the researcher in a browser; every other
conclusion rests on source analysis or computation.

---

## 1. The exception: SC 1.2.1 Audio-only (Prerecorded) — Level A — **NOT MET**

**57 of the 93 active items deliver their content as audio and as audio only.** The on-screen text
states the *task*, never the *content*:

| Item | On-screen text | Exists only in the recording |
|---|---|---|
| 1.1.1 | "সংখ্যাগুলো শুনো এবং লেখ।" | the digit span `492` |
| 1.3.1 | "অক্ষরগুলো শুনো এবং লেখ।" | the letter span `খতগ` |
| 2.1.1 | "শব্দটি থেকে একটি অংশ বাদ দিয়ে বাকিটা বলো।" | the word `সংস্কার` |
| 3.1.1 | "মিল রয়েছে?" | the rhyme pair |
| 5.1.1 | "শব্দ দুটোর প্রথম ধ্বনি অদল-বদল করে…" | the words `বন মই` |

A further 8 demonstration items carry audio and no text at all. The item content lives in
`items.correct_answer`, which the `public_items` view deliberately withholds from the participant's
browser.

**Why a transcript is not a remedy.** Printing the digits converts a listening-span task into a
reading task; showing the rhyme pair converts a phonological judgement into an orthographic one.
For roughly 40 of the 57 items, conforming to 1.2.1 and measuring the intended construct are
mutually exclusive.

**Resolution adopted: a documented exclusion criterion.** Functional hearing is a participation
requirement. Deaf and hard-of-hearing children are outside the population this instrument can
assess, and this is recorded in `RESEARCH_DOCUMENTATION.md` §1.2 (eligibility), §6.4 (ethics
consequences) and §9.8 (why it cannot be designed away). The requirement is **not screened for** —
enrolment relies on the supervising adult.

**Worth stating alongside it:** the audio-first design was *itself* an accessibility decision. It
removes reading ability as a confound, which is the correct choice for a dyslexia screener and
directly benefits the population under study. It helps one group and excludes another, and an
honest report gives both halves.

---

## 2. Criteria assessed — WCAG 2.0 / 2.1

| SC | Level | Verdict | Notes |
|---|---|---|---|
| 1.1.1 Non-text Content | A | **Pass** | Decorative emoji carry `aria-hidden="true"`; no `<img>` in the participant flow |
| **1.2.1 Audio-only (Prerecorded)** | **A** | **NOT MET** | §1 above — stated exception |
| 1.3.1 Info and Relationships | A | **Pass** | `<main>` on every phase; one `<h1>` per screen; no skipped levels |
| 1.4.1 Use of Colour | A | **Pass** | Selection = border + background + `✓` glyph; feedback = colour + text |
| 1.4.3 Contrast (Minimum) | AA | **Pass** | Nine failures found and fixed; narrowest margin now **5.02:1** |
| 1.4.4 Resize Text | AA | **Pass** | `rem` sizing throughout; viewport meta imposes no `maximum-scale` |
| 1.4.10 Reflow | AA | **Pass** | Verified by researcher at 320 px, 2026-09-16 |
| 1.4.11 Non-text Contrast | AA | **Pass** | Focus indicator 6.70:1; selected-state border change 3.70:1 |
| 1.4.12 Text Spacing | AA | **Pass** | Verified by researcher with spacing overrides applied, 2026-09-16 |
| 2.1.1 Keyboard | A | **Pass** | Native `<button>`/`<a>` throughout; `pointerdown` paired with explicit keyboard handling |
| 2.1.2 No Keyboard Trap | A | **Pass** | No modals, no focus trapping |
| 2.2.1 Timing Adjustable | A | **Pass, by Essential exception** | The 1500 ms flash exposure *is* the measurement |
| 2.2.2 Pause, Stop, Hide | A | **Pass, by Essential exception** | Record pulse signals live capture |
| 2.3.1 Three Flashes | A | **Pass** | ≈0.71 Hz, far below 3 Hz |
| 2.4.2 Page Titled | A | **Pass** | Hash routing does not update the title — advisory only |
| 2.4.3 Focus Order | A | **Pass** | Single-column DOM order matches visual order |
| 2.4.4 Link Purpose | A | **Pass** | All link text self-describing |
| 2.4.6 Headings and Labels | AA | **Pass** | Advisory: item screens carry no heading (absence is not a failure) |
| 2.4.7 Focus Visible | AA | **Pass** | `:focus-visible` 3 px outline, 2 px offset, 6.70:1 |
| 3.1.1 Language of Page | A | **Pass** | `<html lang="bn">` |
| 3.1.2 Language of Parts | AA | **Pass** | 37 `lang` markers; zero unmarked English phrases remain |
| 3.3.1 Error Identification | A | **Pass, advisory** | Age validity is enforced by disabling Next without stating the accepted range |
| 3.3.2 Labels or Instructions | A | **Pass** | Every screen carries a question heading |
| 4.1.2 Name, Role, Value | A | **Pass, advisory** | `role="progressbar"` has no accessible name; `⌫` and `C` keys have no `aria-label` |

*4.1.1 Parsing was removed in WCAG 2.2 and is not assessed.*

---

## 3. Criteria new in WCAG 2.2

Three of the nine additions are **Level AAA** and do not bear on an AA claim. They are assessed
here for completeness and marked accordingly.

| SC | Level | Verdict | Basis |
|---|---|---|---|
| 2.4.11 Focus Not Obscured (Minimum) | **AA** | **Pass** | No `position: fixed` or `sticky` anywhere — structurally guaranteed |
| 2.4.12 Focus Not Obscured (Enhanced) | AAA | Pass | Same basis |
| 2.4.13 Focus Appearance | AAA | Pass | 3 px outline ≥ 2 px perimeter; 6.70:1 indicator contrast |
| 2.5.7 Dragging Movements | **AA** | **Pass** | No drag interaction exists; every action is a single tap, click or key press |
| 2.5.8 Target Size (Minimum) | **AA** | **Pass** | See §4 — all targets exceed 24 × 24 px by at least 2× |
| 3.2.6 Consistent Help | **A** | **Not applicable** | The participant flow provides no help mechanism; the SC applies only where one exists |
| 3.3.7 Redundant Entry | **A** | **Pass, by exception** | The resume identity re-check falls under the security exception — it prevents a shared classroom device handing one child's session to another |
| 3.3.8 Accessible Authentication (Min) | **AA** | **Pass** | Anonymous sign-in: no password, no puzzle, no cognitive function test |
| 3.3.9 Accessible Authentication (Enh) | AAA | Not applicable | No authentication step exists for participants |

**All six Level AA additions are met.**

---

## 4. Target size detail (SC 2.5.8)

Minimum is 24 × 24 CSS px. Measured from declared CSS:

| Control | Declared | Smallest computed |
|---|---|---|
| Numeric keypad key | `min-height: 3.25rem`, `min-width: 44px` | ≈78.7 × 52 px; ≈70.7 × 52 px at a 320 px viewport |
| Eight-letter grid (1.3 / 1.4) | same `.numeric-key` rule | identical |
| Option button (MCQ / binary / tri / Likert) | `min-height`/`min-width: 44px` | 44 px floor; 56 px in scale layout |
| Replay / audio buttons | `min-height: 44px` + global `min-width: 44px` | 44 px floor |
| Next / choice buttons | `min-height: 3.25rem` | 52 px |
| Record button | `min-height`/`min-width: 3.75rem` | 60 px |

The `System status` link on the landing page is 13 px inline text and is **exempt** under the
inline-target exception.

**Maintenance note:** `LetterSpan.tsx` applies `className="numeric-keys letter-keys"`, but **no
`.letter-keys` rule exists** in any stylesheet. The grid inherits `.numeric-keys` entirely. Sizing
is ample today, but anyone adding a `.letter-keys` rule — a 4-column layout, say — could shrink
these targets without realising the current geometry was inherited rather than chosen.

---

## 5. Bangla script rendering

Not a WCAG criterion, but material to a Bangla instrument.

**Shaping support confirmed by parsing the font binary.** `noto-sans-bengali-bengali.woff2`
(107,720 bytes, 20 tables) retains **`GSUB`** (conjunct formation), **`GPOS`** (matra and diacritic
positioning) and **`GDEF`** (glyph classification). The subset was not stripped of shaping data —
the usual failure mode for subsetted Indic webfonts. `unicode-range` correctly includes
**U+200C–200D** (ZWNJ/ZWJ, which control conjunct and half-form behaviour) and **U+25CC**, so a
malformed cluster renders visibly wrong rather than silently vanishing.

The font stack is `'Noto Sans Bengali', sans-serif` with **no system fallback ahead of it** — a
deliberate correctness measure, so legacy Bijoy/SutonnyMJ-encoded text fails visibly instead of
passing review.

**Smallest Bangla text: 0.8125 rem (13 px)** (`.small`). WCAG sets no minimum font size, so this is
not a conformance issue. It is, however, worth an empirical check with the target population:
complex conjuncts (ক্ষ, ঙ্ক্ষ, স্ত্র) compress vertically at small sizes, and orthographic
discrimination is the construct under measurement. **Not verified** — this requires visual
inspection at device pixel density, which was outside this assessment.

---

## 6. Remediation performed

Nine contrast failures were found by computing every colour pair, and fixed on 2026-09-16. Three
had been missed by an earlier hand assessment, including the most-used control in the instrument:

| Control | Before | After |
|---|---|---|
| Record button (all 17 spoken items) | **2.30:1** | 5.18:1 |
| Record button, gradient end / recording | 3.19:1 | 6.51:1 |
| Green Continue button | 2.77:1 / 3.78:1 | 5.02:1 / 7.25:1 |
| Practice feedback — correct | 2.43:1 | 6.23:1 |
| Practice feedback — incorrect | 2.79:1 | 5.70:1 |
| Audio-failure alert | 2.95:1 | 6.03:1 |
| Error text (test mode) | 3.96:1 | 6.54:1 |

Every tinted **background** was left unchanged; only ink and solid fills were darkened, so the
pastel design is preserved. `--tr-warm` (`#ff8a70`) is deliberately unchanged: it is used only by
the progress-fill gradient, which carries no text and sits beside a literal `n / 77` indicator, so
the graphic is not required to understand the content.

Language-of-parts remediation added 37 `lang` markers. Three `aria-label`s were English strings in
a Bangla document (one on an element explicitly marked `lang="bn"`) and were **translated** rather
than merely marked, so a Bangla screen reader announces Bangla. The audio-record controls and both
error screens, previously English-only, now lead in Bangla.

---

## 7. Summary

**Met:** all Level A and Level AA criteria assessed, and all six Level AA criteria new in WCAG 2.2.
**Not met:** SC 1.2.1 Audio-only (Prerecorded), Level A — by design, with a documented exclusion
criterion.
**Not verified:** screen-reader and assistive-technology behaviour; Bangla conjunct legibility at
13 px.
