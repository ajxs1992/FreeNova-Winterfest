// FreeNova web panel — game registration API (freenova_registration.sma -> panel).
//
// Contract, read from cstrike/addons/amxmodx/scripting/freenova_registration.sma:
//   POST /api/game/v1/register   (cvar default path L97; raw HTTP request built L857-862)
//     Headers sent by the plugin:
//       X-FreeNova-Server-ID   (L861, from freenova_reg_server_id, default "freenova-public-1")
//       X-FreeNova-Timestamp   (L861, unix seconds, same value as body.timestamp L816-817)
//       X-FreeNova-Nonce       (L862, "%08x%08x" -> 16 lowercase hex chars, L838-839)
//       X-FreeNova-Signature   (L862)
//     Signature (comment L837, implementation L846-850):
//       SHA256(secret + ":POST:" + path + ":" + timestamp + ":" + nonce + ":" + BODY)
//     *** THE BODY IS SIGNED RAW HERE. ***
//     The stats push (/api/v1/server/stats, sync.js L3-4/L94-95) instead signs
//     hex(sha256(body)). Two different formulas exist on purpose — do NOT mix them.
//     Request JSON (L808-833):
//       { protocol_version: 1, request_id: "fn-reg-<systime>-<slot>-<rand>",
//         server_id, timestamp, player: { auth_provider: "steam", auth_id },
//         registration: { username, email, password } }
//     Response handling (L1016-1129): the plugin reads until the peer closes the
//     connection, splits headers from body at \r\n\r\n, and parses the body as a
//     JSON OBJECT: { success: bool, code: string, message?: string } (L1063-1117).
//     The HTTP STATUS LINE IS IGNORED for POST — body fields drive player feedback.
//     We still return accurate statuses for operators/curl. Keep the JSON body
//     well under ~1024 bytes (plugin buffer, L1051).
//     Known error codes the plugin maps to friendly player text (L1081-1113):
//       USERNAME_TAKEN, EMAIL_TAKEN, GAME_ACCOUNT_ALREADY_LINKED, RATE_LIMITED,
//       PASSWORD_TOO_SHORT, INVALID_USERNAME, INVALID_EMAIL,
//       REGISTRATION_DISABLED, FLARUM_UNAVAILABLE; unknown codes fall back to
//       "message" (L1116-1119).
//   GET /api/game/v1/health   (cvar default L102; probe request built L183-185)
//     The probe carries NO auth header and NO body — health is unauthenticated
//     by design (confirmed at L183-185: only Host / User-Agent / Connection).
//     Any 2xx status line -> FORUM_UP (ProbeFinish L282-296). Registration
//     features hard-require FORUM_UP (Cmd_Register L391-399).
//
// Rate limiting: the plugin self-limits re-attempts to 15 s per player (cvar
// freenova_reg_ratelimit, checked L777-785). The panel does not add a second
// limiter; it makes retries/duplicates IDEMPOTENT instead: a second POST for a
// steamid that already has a pending row (or the same request_id) re-returns
// the recorded row and never inserts twice.
//
// Password handling: validated (8-72 chars, matching plugin-side checks L671/L678)
// then DISCARDED — the panel never persists forum passwords. The pending row
// carries identity + username + email only; a future provisioning consumer must
// complete account creation through a flow that does not store the plaintext.

// handleRegister / handleRegHealth are exported at their definitions below.
export { REGISTER_PATH, HEALTH_PATH, EXPECTED_SERVER_ID }

const REGISTER_PATH = "/api/game/v1/register"
const HEALTH_PATH = "/api/game/v1/health"
// Exact server identity accepted (task contract; plugin default at L98, and
// fnweb_server_id in amxx.cfg uses the same id). Unknown ids are rejected —
// docs/panel-ingest-api.md L94-95: "Never accept an unknown server-id".
const EXPECTED_SERVER_ID = "freenova-public-1"
// Replay window, same posture as the stats push (sync.js L89-92, docs L44-45).
const TS_WINDOW = 300
// Largest registration body accepted; a real one is < 4 KB.
const MAX_REG_BODY_BYTES = 2 * 1024 * 1024

function json(obj, status) {
  return new Response(JSON.stringify(obj), { status, headers: { "content-type": "application/json" } })
}

async function sha256Hex(bytes) {
  const digest = await crypto.subtle.digest("SHA-256", bytes)
  return [...new Uint8Array(digest)].map(b => b.toString(16).padStart(2, "0")).join("")
}

// Same constant-time pattern as sync.js L32-37 (re-implemented locally so
// sync.js stays untouched — it does not export this helper).
function timingSafeEqual(a, b) {
  if (a.length !== b.length) return false
  let diff = 0
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i)
  return diff === 0
}

// REG_SECRET resolution: server_local.mjs loads all of relay/relay.env into
// process.env (server_local.mjs L20-30) but its env object does not forward
// REG_SECRET, so fall back to process.env the same way ADMIN_PASSWORD is fed
// (server_local.mjs L70). An explicit env.REG_SECRET ("" included) always wins
// so fail-closed behaviour is testable and a Worker deployment can't be
// silently rescued by a process-level value.
function regSecret(env) {
  if (env && env.REG_SECRET != null) return String(env.REG_SECRET)
  try { return process.env.REG_SECRET || "" } catch { return "" } // no `process` in Workers
}

// Player-facing codes the plugin understands (L1081-1113). Everything else
// falls back to our message text, which the plugin prints verbatim (L1116-1119).
function fail(code, message, status) {
  return json({ success: false, code, message }, status)
}

function validSteamid(s) {
  return typeof s === "string" && /^STEAM_[0-9]:[0-9]:\d+$/.test(s) // same rule as sync.js L41-43
}

const REG_DDL = [
  `CREATE TABLE IF NOT EXISTS reg_requests (
      request_id TEXT PRIMARY KEY,
      server_id  TEXT NOT NULL,
      steamid    TEXT NOT NULL,
      provider   TEXT NOT NULL DEFAULT 'steam',
      username   TEXT NOT NULL,
      email      TEXT NOT NULL,
      status     TEXT NOT NULL DEFAULT 'pending',
      created_at INTEGER NOT NULL DEFAULT 0)`,
  `CREATE INDEX IF NOT EXISTS idx_reg_requests_steamid ON reg_requests (steamid)`
]

// Idempotent, code-applied DDL (same posture as ensureOpsTables in sync.js
// L535-595): schema.sql is out of this change's scope, so the table is created
// on demand with CREATE TABLE IF NOT EXISTS. Safe to run on every request.
async function ensureRegTable(env) {
  await env.DB.batch(REG_DDL.map(sql => env.DB.prepare(sql)))
}

// Unauthenticated liveness. The plugin maps a 2xx status line to FORUM_UP
// (L282-296) and never inspects this body, so keep it small and secret-free.
export async function handleRegHealth(_request, env) {
  return json({
    ok: true,
    service: "freenova-panel",
    endpoint: "game-registration",
    reg_configured: !!regSecret(env), // operator hint only — no secret material
    time: Math.floor(Date.now() / 1000)
  }, 200)
}

async function verifyRegisterAuth(request, env, path, rawBody) {
  const secret = regSecret(env)
  // Fail-closed, same posture as sync.js L153: no secret configured -> 503,
  // never "accept everything". The plugin treats this like REGISTRATION_DISABLED.
  if (!secret)
    return { ok: false, response: fail("REGISTRATION_DISABLED", "registration secret not configured on panel", 503) }

  const ts = request.headers.get("X-FreeNova-Timestamp") || ""
  const nonce = request.headers.get("X-FreeNova-Nonce") || ""
  const sig = request.headers.get("X-FreeNova-Signature") || ""
  const serverId = request.headers.get("X-FreeNova-Server-ID") || ""

  if (!sig || !ts)
    return { ok: false, response: fail("UNAUTHORIZED", "missing signature or timestamp", 401) }
  if (!nonce || nonce.length > 64 || /[^\w.-]/.test(nonce)) // sync.js L98 style
    return { ok: false, response: fail("UNAUTHORIZED", "bad nonce", 401) }
  const tsNum = parseInt(ts, 10)
  const now = Math.floor(Date.now() / 1000)
  if (!tsNum || Math.abs(now - tsNum) > TS_WINDOW)
    return { ok: false, response: fail("UNAUTHORIZED", "timestamp outside replay window", 401) }

  // Signature is computed over the RAW body bytes exactly as the plugin signs
  // them (L846-850): prefix ASCII + raw body bytes, hashed byte-for-byte.
  const enc = new TextEncoder()
  const prefix = enc.encode(`${secret}:POST:${path}:${ts}:${nonce}:`)
  const signed = new Uint8Array(prefix.length + rawBody.length)
  signed.set(prefix)
  signed.set(rawBody, prefix.length)
  const expected = await sha256Hex(signed)
  if (!timingSafeEqual(expected, sig.toLowerCase()))
    return { ok: false, response: fail("UNAUTHORIZED", "invalid signature", 401) }

  // Authenticated — now authorize the server identity (docs L94-95).
  if (serverId !== EXPECTED_SERVER_ID)
    return { ok: false, response: fail("UNKNOWN_SERVER", "unknown server_id", 403) }

  return { ok: true, now }
}

async function validatePayload(payload, now) {
  if (!payload || typeof payload !== "object" || Array.isArray(payload))
    return fail("BAD_REQUEST", "payload must be a JSON object", 400)
  if (payload.protocol_version !== 1)
    return fail("UNSUPPORTED_PROTOCOL", "protocol_version must be 1", 400)
  if (typeof payload.request_id !== "string" || !/^[\w.-]{1,64}$/.test(payload.request_id))
    return fail("BAD_REQUEST", "bad request_id", 400)
  if (payload.server_id !== EXPECTED_SERVER_ID)
    return fail("UNKNOWN_SERVER", "unknown server_id", 403)
  // Body timestamp: signed by the header signature; only sanity-checked here
  // (the ±300 s replay window was already enforced on the header value).
  if (typeof payload.timestamp !== "number" || !Number.isFinite(payload.timestamp))
    return fail("BAD_REQUEST", "bad timestamp", 400)

  const player = payload.player
  if (!player || typeof player !== "object"
    || player.auth_provider !== "steam"     // plugin always sends "steam" (L821)
    || !validSteamid(player.auth_id))       // plugin never sends PENDING/UNKNOWN (L798-802)
    return fail("BAD_REQUEST", "player.auth_provider/auth_id invalid", 400)

  const reg = payload.registration
  if (!reg || typeof reg !== "object")
    return fail("BAD_REQUEST", "registration object missing", 400)
  // Field rules mirror the plugin's own input checks: username 3-20 chars of
  // [A-Za-z0-9_.] (L606-623), email 6-60 chars containing @ and . (L644),
  // password 8-72 chars (L671/L678).
  if (typeof reg.username !== "string" || !/^[A-Za-z0-9_.]{3,20}$/.test(reg.username))
    return fail("INVALID_USERNAME", "letters, numbers, _ and . only, 3-20 chars", 400)
  if (typeof reg.email !== "string" || reg.email.length < 6 || reg.email.length > 60
    || !reg.email.includes("@") || !reg.email.includes(".") || /[\s<>"`,;\\]/.test(reg.email))
    return fail("INVALID_EMAIL", "invalid email address", 400)
  if (typeof reg.password !== "string" || reg.password.length < 8)
    return fail("PASSWORD_TOO_SHORT", "password must be at least 8 characters", 400)
  if (reg.password.length > 72)
    return fail("BAD_REQUEST", "password must be at most 72 characters", 400)

  return null
}

export async function handleRegister(request, env) {
  const path = new URL(request.url).pathname

  // Cap before buffering (REVIEW.md §4.1 H3): the raw body is read before the
  // signature is checked, so an unauthenticated caller could otherwise make the
  // Worker hold an arbitrary payload. Same 2 MiB bound as sync.js.
  const declared = Number(request.headers.get("content-length") || 0)
  if (Number.isFinite(declared) && declared > MAX_REG_BODY_BYTES)
    return fail("PAYLOAD_TOO_LARGE", "request body too large", 413)

  // Byte-exact body first: the signature covers the raw bytes the plugin sent.
  const rawBody = new Uint8Array(await request.arrayBuffer())
  if (rawBody.length > MAX_REG_BODY_BYTES)
    return fail("PAYLOAD_TOO_LARGE", "request body too large", 413)

  const auth = await verifyRegisterAuth(request, env, path, rawBody)
  if (!auth.ok) return auth.response

  // lenient decode (invalid UTF-8 -> replacement chars, which field validation
  // then rejects) — never re-encode before hashing (see verifyRegisterAuth).
  let payload
  try { payload = JSON.parse(new TextDecoder().decode(rawBody)) }
  catch { return fail("BAD_REQUEST", "malformed json", 400) }

  const invalid = await validatePayload(payload, auth.now)
  if (invalid) return invalid

  const { request_id: requestId, server_id: serverId } = payload
  const steamid = payload.player.auth_id
  const provider = payload.player.auth_provider
  const username = String(payload.registration.username).slice(0, 20)
  const email = String(payload.registration.email).slice(0, 60)
  // registration.password is validated above and deliberately NOT stored.

  try {
    await ensureRegTable(env)
    // Atomic duplicate guard: one PENDING row per steamid. The conditional
    // INSERT..SELECT..WHERE NOT EXISTS keeps concurrent double-submits from
    // inserting twice (single statement, no window between check and write);
    // ON CONFLICT(request_id) absorbs exact replays.
    await env.DB.prepare(
      `INSERT INTO reg_requests (request_id, server_id, steamid, provider, username, email, status, created_at)
       SELECT ?1, ?2, ?3, ?4, ?5, ?6, 'pending', ?7
       WHERE NOT EXISTS (SELECT 1 FROM reg_requests WHERE steamid = ?3 AND status = 'pending')
       ON CONFLICT(request_id) DO NOTHING`)
      .bind(requestId, serverId, steamid, provider, username, email, auth.now).run()

    let row = await env.DB.prepare(
      `SELECT request_id, status FROM reg_requests
       WHERE steamid = ?1 ORDER BY created_at ASC, request_id ASC LIMIT 1`)
      .bind(steamid).first()
    if (!row) // exact-replay path: our request_id row exists under another steamid's history
      row = await env.DB.prepare(
        `SELECT request_id, status FROM reg_requests WHERE request_id = ?1`)
        .bind(requestId).first()
    if (!row)
      return fail("INTERNAL", "registration could not be stored", 500)

    // Idempotent re-return: success either way (the plugin wipes the password
    // and shows the success banner on success:true — L1067-1077), but tell the
    // caller whether this POST recorded a NEW row or matched an existing one.
    return json({
      success: true,
      code: "OK",
      request_id: row.request_id,
      status: row.status,
      duplicate: row.request_id !== requestId
    }, 200)
  } catch (e) {
    console.error("[register] store failed:", e && e.message ? e.message : String(e))
    return fail("INTERNAL", "registration storage error", 500)
  }
}
