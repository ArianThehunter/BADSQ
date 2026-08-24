#!/usr/bin/env node
/**
 * BADSQ Platform — Phase 0 HTTP-level security verification.
 *
 * Exercises the REAL transport (PostgREST + Storage + GoTrue) as the
 * unauthenticated `anon` role, using only the publishable key that ships in
 * the browser bundle. This is the exact posture of an attacker who has read
 * the JS bundle.
 *
 * Scope note: assertions that need an authenticated identity (a participant's
 * anonymous session, a researcher) cannot run here, because minting a user JWT
 * requires either Anonymous Sign-ins enabled on the project or the JWT signing
 * secret. Those are covered by scripts/verify_security.sql, which drives the
 * same policies through role + request.jwt.claims impersonation.
 *
 *   node scripts/verify-security.mjs
 *
 * Exit code 0 if every assertion passed, 1 otherwise.
 */

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');

function loadEnv() {
  const out = {};
  try {
    for (const line of readFileSync(join(root, '.env'), 'utf8').split(/\r?\n/)) {
      const m = /^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/.exec(line);
      if (m) out[m[1]] = m[2].replace(/^["']|["']$/g, '');
    }
  } catch {
    console.error('Could not read .env — copy .env.example to .env first.');
    process.exit(2);
  }
  return out;
}

const env = loadEnv();
const URL_BASE = env.VITE_SUPABASE_URL;
const KEY = env.VITE_SUPABASE_PUBLISHABLE_KEY;
const BUCKET = env.VITE_SUPABASE_AUDIO_BUCKET || 'badsq-audio';
if (!URL_BASE || !KEY) {
  console.error('VITE_SUPABASE_URL and VITE_SUPABASE_PUBLISHABLE_KEY must be set in .env');
  process.exit(2);
}

const results = [];
function record(assertion, expected, actual, pass) {
  results.push({ assertion, expected, actual, pass });
  const tag = pass ? 'PASS' : 'FAIL';
  console.log(`[${tag}] ${assertion}`);
  console.log(`       expected: ${expected}`);
  console.log(`       actual:   ${actual}`);
}

/** Summarise an HTTP response into a single comparable line. */
async function probe(method, path, { body, headers } = {}) {
  const res = await fetch(`${URL_BASE}${path}`, {
    method,
    headers: {
      apikey: KEY,
      Authorization: `Bearer ${KEY}`,
      'Content-Type': 'application/json',
      ...headers,
    },
    body,
  });
  const text = await res.text();
  let parsed = null;
  try { parsed = JSON.parse(text); } catch { /* not json */ }
  return {
    status: res.status,
    text: text.length > 240 ? `${text.slice(0, 240)}…` : text,
    json: parsed,
    rowCount: Array.isArray(parsed) ? parsed.length : null,
  };
}

/** True when PostgREST/Storage refused the request outright. */
const isDenied = (r) =>
  r.status === 401 || r.status === 403 ||
  (r.json && (r.json.code === '42501' || r.json.code === 'PGRST301' ||
              /permission denied/i.test(r.json.message || '')));

const line = (r) =>
  `HTTP ${r.status}` +
  (r.rowCount !== null ? `, ${r.rowCount} row(s)` : '') +
  ` — ${r.text || '(empty body)'}`;

console.log('BADSQ Phase 0 — HTTP verification as the anon role');
console.log(`Project: ${URL_BASE}`);
console.log(`Key:     ${KEY.slice(0, 20)}… (publishable)`);
console.log('='.repeat(78));

// ---------------------------------------------------------------- answer keys
{
  const r = await probe('GET', '/rest/v1/items?select=correct_answer');
  record('anon GET /rest/v1/items?select=correct_answer (base table)',
    'denied', line(r), isDenied(r));
}
{
  const r = await probe('GET', '/rest/v1/item_options?select=is_correct');
  record('anon GET /rest/v1/item_options?select=is_correct (base table)',
    'denied', line(r), isDenied(r));
}
{
  const r = await probe('GET', '/rest/v1/items?select=*');
  record('anon GET /rest/v1/items?select=* (whole base table)',
    'denied', line(r), isDenied(r));
}
{
  // Try to reach the answer key by embedding through the permitted view.
  const r = await probe('GET', '/rest/v1/public_items?select=*,item_options(*)');
  const leaked = JSON.stringify(r.json || '').includes('is_correct');
  record('anon GET /rest/v1/public_items with an embedded item_options join',
    'no is_correct in response', line(r), !leaked);
}
{
  const r = await probe('GET', '/rest/v1/public_items?select=correct_answer');
  const leaked = r.status === 200 && /correct_answer/.test(JSON.stringify(r.json || ''))
    && Array.isArray(r.json);
  record('anon GET /rest/v1/public_items?select=correct_answer (column does not exist on the view)',
    'rejected, no value returned', line(r), !leaked);
}

// -------------------------------------------- participant-facing read path
// These two are the read path TestRunner will use. They assert only that the
// path is READABLE, not a row count — the number of active items depends on
// whether the item bank is populated, and this suite must give the same verdict
// whether or not verify_security.sql's fixtures happen to be loaded.
{
  const r = await probe('GET', '/rest/v1/public_items?select=item_code,domain,response_format');
  record('anon GET /rest/v1/public_items (INTENDED participant read path)',
    'HTTP 200 (readable; row count depends on the item bank)', line(r), r.status === 200);
}
{
  const r = await probe('GET', '/rest/v1/public_item_options?select=item_id,option_key,option_text');
  record('anon GET /rest/v1/public_item_options (INTENDED participant read path)',
    'HTTP 200 (readable; row count depends on the item bank)', line(r), r.status === 200);
}

// --------------------------------------------------------------- export paths
{
  const r = await probe('GET', '/rest/v1/ml_export_v1?select=*');
  record('anon GET /rest/v1/ml_export_v1', 'denied or 0 rows', line(r),
    isDenied(r) || r.rowCount === 0);
}
{
  // ml_snapshots is empty until an analysis run populates it, so an unfiltered
  // read proves nothing. Write a canary as anon, read it back as anon, then
  // delete it as anon — each step is its own assertion, and the sequence leaves
  // the table as it found it.
  const w = await probe('POST', '/rest/v1/ml_snapshots',
    { body: JSON.stringify({ anonymized_code: 'HTTP-ANON-CANARY', class_grade: 6 }) });
  const wrote = w.status === 201 || w.status === 200;
  record('anon POST /rest/v1/ml_snapshots (inject a row into the analysis snapshot)',
    'denied', line(w), !wrote);

  const r = await probe('GET', '/rest/v1/ml_snapshots?select=*&anonymized_code=eq.HTTP-ANON-CANARY');
  record('anon GET /rest/v1/ml_snapshots (read back the canary just written)',
    'denied or 0 rows', line(r), isDenied(r) || r.rowCount === 0);

  const d = await probe('DELETE', '/rest/v1/ml_snapshots?anonymized_code=eq.HTTP-ANON-CANARY');
  record('anon DELETE /rest/v1/ml_snapshots (destroy analysis snapshot rows)',
    'denied', line(d), d.status >= 400);

  if (wrote) {
    // Belt and braces: make sure the canary is gone even if DELETE was denied.
    const left = await probe('GET', '/rest/v1/ml_snapshots?select=id&anonymized_code=eq.HTTP-ANON-CANARY');
    if (left.rowCount) console.log(`       NOTE: ${left.rowCount} canary row(s) still present — remove manually.`);
  }
}

// --------------------------------------------------------- participant data
{
  const r = await probe('GET', '/rest/v1/participants?select=*');
  record('anon GET /rest/v1/participants', 'denied or 0 rows', line(r),
    isDenied(r) || r.rowCount === 0);
}
{
  const r = await probe('GET', '/rest/v1/responses?select=*');
  record('anon GET /rest/v1/responses', 'denied or 0 rows', line(r),
    isDenied(r) || r.rowCount === 0);
}
{
  const r = await probe('GET', '/rest/v1/sessions?select=*');
  record('anon GET /rest/v1/sessions', 'denied or 0 rows', line(r),
    isDenied(r) || r.rowCount === 0);
}
{
  const r = await probe('GET', '/rest/v1/researchers?select=*');
  record('anon GET /rest/v1/researchers (the allowlist itself)', 'denied or 0 rows', line(r),
    isDenied(r) || r.rowCount === 0);
}
{
  const r = await probe('GET', '/rest/v1/consent_records?select=*');
  record('anon GET /rest/v1/consent_records', 'denied or 0 rows', line(r),
    isDenied(r) || r.rowCount === 0);
}

// ----------------------------------------------------------------- writes
{
  const r = await probe('POST', '/rest/v1/sessions',
    { body: JSON.stringify({ status: 'in_progress' }) });
  record('anon POST /rest/v1/sessions (no user JWT, so auth.uid() is NULL)',
    'denied', line(r), !(r.status === 201 || r.status === 200));
}
{
  const r = await probe('POST', '/rest/v1/rpc/submit_session', {
    body: JSON.stringify({
      p_session_id: 'a0000000-0000-4000-8000-000000000002',
      p_participant: { anonymized_code: 'HTTP-ANON', class_grade: '7' },
      p_responses: [],
    }),
  });
  const ok = r.status >= 400;
  record('anon POST /rest/v1/rpc/submit_session for a session it does not own',
    'rejected', line(r), ok);
}

// ---------------------------------------------------------------- storage
{
  const r = await probe('POST', `/storage/v1/object/${BUCKET}/a0000000-0000-4000-8000-000000000004/anon.webm`,
    { body: 'not-real-audio', headers: { 'Content-Type': 'audio/webm' } });
  record(`anon upload to ${BUCKET}/<session>/anon.webm`,
    'denied', line(r), r.status >= 400);
}
{
  const r = await probe('POST', `/storage/v1/object/list/${BUCKET}`,
    { body: JSON.stringify({ prefix: '', limit: 100 }) });
  const listed = r.status === 200 && Array.isArray(r.json) && r.json.length > 0;
  record(`anon list objects in ${BUCKET}`, 'denied or empty', line(r), !listed);
}

// -------------------------------------------------------------------- auth
{
  const r = await probe('POST', '/auth/v1/signup', { body: JSON.stringify({}) });
  const enabled = r.status === 200;
  record('anonymous sign-in is enabled on the project (handoff setup step 3)',
    'HTTP 200 with an access_token', line(r), enabled);
}

// ------------------------------------------------------------------ summary
console.log('='.repeat(78));
const passed = results.filter((r) => r.pass).length;
const failed = results.length - passed;
console.log(`TOTAL ${results.length} assertions — ${passed} passed, ${failed} failed`);
if (failed) {
  console.log('\nFailed assertions:');
  for (const r of results.filter((x) => !x.pass)) console.log(`  - ${r.assertion}\n      got: ${r.actual}`);
}
process.exit(failed ? 1 : 0);
