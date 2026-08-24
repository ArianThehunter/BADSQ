# Self-hosted Bangla font

`noto-sans-bengali-*.woff2` — **Noto Sans Bengali**, from Google Fonts, licensed under the
SIL Open Font License 1.1 (<https://openfontlicense.org/>). Variable weight axis, so one
file per subset covers weights 400–600.

These files are committed and served from this app's own origin **on purpose**:

1. **Privacy.** The participants are 12–14 year olds. Loading a webfont from
   `fonts.gstatic.com` would disclose every participant's IP address to a third party on
   every page load. Self-hosting means the only network destination in the whole app is
   the project's own Supabase instance.
2. **Reliability.** The field administration protocol anticipates unreliable school
   internet. A stimulus caption that failed to render in Bangla because a CDN was
   unreachable would be a data-quality problem, not a cosmetic one.
3. **Correctness.** The source materials for this project have a known history of legacy
   non-Unicode Bangla encoding (Bijoy / SutonnyMJ-style, where the bytes are Latin code
   points that only *look* like Bangla in one specific font). Pinning an explicit Unicode
   Bangla face means correctly-rendering text is genuinely Unicode, and legacy-encoded
   text renders visibly wrong instead of silently passing review.

Subsets and their `unicode-range` values are declared in `src/index.css`, copied verbatim
from Google Fonts' own subset definitions. The Bengali subset is preloaded in
`index.html`; the Latin subsets are not.

To refresh: re-download the three woff2 files referenced by
`https://fonts.googleapis.com/css2?family=Noto+Sans+Bengali:wght@400;600&display=swap`
(request with a modern browser User-Agent, or the API serves ttf instead of woff2) and
keep the `unicode-range` blocks in `src/index.css` in sync.

| File | Subset | Size |
|---|---|---|
| `noto-sans-bengali-bengali.woff2` | Bengali (U+0980–09FE et al.) | 105 KB |
| `noto-sans-bengali-latin-ext.woff2` | Latin Extended | 13 KB |
| `noto-sans-bengali-latin.woff2` | Latin | 25 KB |
