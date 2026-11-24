// FreeNova Admin Control Center — modern browser UI (not MOTD).
// Game remains the spender. Staff POSTs queue actions; HMAC stays on game POSTs.
import { ensureOpsTables } from "./sync.js"
import { ensureScheduleDetailColumn } from "./schedule.js"

const OWNER = "STEAM_0:0:683671116"
const OPS_STEAM = "STEAM_0:0:0"
const COOKIE = "fn_staff"
const SESSION_SEC = 12 * 3600
const ARG_BAD = /[\r\n<>&"]/
const MAPS = new Set([
  "de_dust2", "de_inferno", "de_nuke", "de_mirage", "de_cache", "de_cbble",
  "de_aztec", "de_train", "de_vertigo", "cs_assault", "cs_office", "cs_italy"
])
const STAFF_TYPES = new Set([
  "kick", "ban", "give_coins", "give_xp", "give_vip",
  "srv_map", "srv_event_apply", "srv_event_clear"
])
const EVENT_TYPES = new Set(["xp_mult", "coins_mult", "double_xp", "happy_hour", "community_goal"])
// Events settlement contract (sync.js eventLifetime/BASELINE_EXPR): only these
// metrics are measurable from a players row; "none" is the multiplier-only
// event. Display aliases pages.js already normalizes (eventMetricKey) are
// accepted and stored canonical so settlement never sees an unmapped metric.
const EVENT_METRICS = new Set(["none", "kills", "headshots", "wins", "mvps", "xp", "c4"])
const EVENT_METRIC_ALIAS = { hs: "headshots", plants: "c4", mvp: "mvps", boost: "none", multiplier: "none" }
// scope: "global" pays the whole board, "individual" pays the top 3 (sync.js).
const EVENT_SCOPES = new Set(["global", "individual"])
// Prize columns (event_winners / srv_event_reward slots). Frozen once an event
// leaves "scheduled": settlement reads them from the row it activated with, so
// staff may only change them before the game starts tracking.
const EVENT_AMOUNT_COLS = ["reward_coins", "reward_viptier", "reward_vipdays", "min_score"]

function json(obj, status) {
  return new Response(JSON.stringify(obj), { status, headers: { "content-type": "application/json" } })
}

function esc(s) {
  return String(s == null ? "" : s)
    .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;").replace(/'/g, "&#39;")
}

function timingSafeEqual(a, b) {
  if (a.length !== b.length) return false
  let diff = 0
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i)
  return diff === 0
}

async function sha256Hex(text) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text))
  return [...new Uint8Array(digest)].map(b => b.toString(16).padStart(2, "0")).join("")
}

function validSteamid(s) {
  return typeof s === "string" && /^STEAM_[0-9]:[0-9]:\d+$/.test(s)
}

function nowSec() { return Math.floor(Date.now() / 1000) }

// Platform-reported client address only. REVIEW.md §4.2 M2: trusting
// x-forwarded-for made the 5-attempt login lockout bypassable with one header,
// because on the local runner that header is whatever the client sends.
//   x-freenova-client-ip  set by server_local.mjs from req.socket.remoteAddress,
//                         and stripped from anything a client sends.
//   cf-connecting-ip      set by Cloudflare itself; Cloudflare overwrites a
//                         client-supplied value, so it cannot be spoofed there.
// Anything else (a bare x-forwarded-for, a missing header) is "unknown", which
// only means the shared bucket is used - never a bucket the caller chooses.
function clientIp(request) {
  // cf-connecting-ip first: Cloudflare sets it and overwrites anything the
  // client sent, so on the Worker it is the one trustworthy source. On the
  // local runner the header is stripped from client input (server_local.mjs) and
  // x-freenova-client-ip is stamped from the socket instead.
  const cf = request.headers.get("cf-connecting-ip")
  if (cf) return String(cf).split(",")[0].trim().slice(0, 64) || "unknown"
  const direct = request.headers.get("x-freenova-client-ip")
  if (direct) return String(direct).trim().slice(0, 64) || "unknown"
  return "unknown"
}

function isMotdUa(request) {
  const ua = request.headers.get("user-agent") || ""
  return /MSIE|Trident|Mozilla\/4\.0/i.test(ua)
}

function parseCookies(request) {
  const out = {}
  const raw = request.headers.get("cookie") || ""
  for (const part of raw.split(";")) {
    const i = part.indexOf("=")
    if (i < 1) continue
    // decodeURIComponent throws on a malformed escape ("%"), and one bad cookie
    // used to turn every /admin request into a 500.
    let v = part.slice(i + 1).trim()
    try { v = decodeURIComponent(v) } catch {}
    out[part.slice(0, i).trim()] = v
  }
  return out
}

function cookieHeader(value, maxAge, secure) {
  const bits = [
    `${COOKIE}=${encodeURIComponent(value)}`,
    "Path=/admin",
    "HttpOnly",
    "SameSite=Lax",
    `Max-Age=${maxAge}`
  ]
  if (secure) bits.push("Secure")
  return bits.join("; ")
}

function flagsFor(role, steamid) {
  if (steamid === OWNER) return "abcdefghijklmnopqrstuv"
  const r = String(role || "admin").toLowerCase()
  if (r === "owner" || r.length >= 10) return r.length >= 10 ? r : "abcdefghijklmnopqrstuv"
  if (r === "manager") return "a"
  if (r === "mod" || r === "moderator") return "ce"
  return "cdeijuv"
}

function hasFlag(flags, letter) {
  return String(flags || "").indexOf(letter) >= 0
}

function conflictGroup(type) {
  if (type === "coins_mult") return "coins"
  if (type === "community_goal") return "goal"
  return "xp"
}

async function csrfFor(secret, token) {
  return (await sha256Hex(`${secret || ""}:csrf:${token}`)).slice(0, 32)
}

async function signCookie(secret, steamid, exp) {
  const sig = await sha256Hex(`${secret}:staff:${steamid}:${exp}`)
  return `${steamid}|${exp}|${sig}`
}

async function readSession(request, env) {
  const raw = parseCookies(request)[COOKIE]
  if (!raw || !env.SYNC_SECRET) return null
  const parts = raw.split("|")
  if (parts.length !== 3) return null
  const [steamid, expStr, sig] = parts
  const exp = parseInt(expStr, 10)
  if (!validSteamid(steamid) || !exp || exp < nowSec()) return null
  const expected = await sha256Hex(`${env.SYNC_SECRET}:staff:${steamid}:${exp}`)
  if (!timingSafeEqual(sig.toLowerCase(), expected)) return null
  const row = await env.DB.prepare(
    `SELECT token, steamid, expires_at FROM admin_sessions WHERE token=?1`
  ).bind(expected).first()
  if (!row || Number(row.expires_at) < nowSec()) return null
  const staff = await env.DB.prepare(
    `SELECT steamid, name, role, enabled FROM staff WHERE steamid=?1`
  ).bind(steamid).first()
  if (!staff || Number(staff.enabled) === 0) return null
  return {
    steamid,
    name: staff.name || steamid,
    flags: flagsFor(staff.role, steamid),
    token: expected,
    csrf: await csrfFor(env.SYNC_SECRET, expected)
  }
}

async function parseBody(request) {
  const ct = request.headers.get("content-type") || ""
  if (request.method === "GET" || request.method === "HEAD") return {}
  const text = await request.text()
  if (ct.includes("application/json")) {
    try { return JSON.parse(text) || {} } catch { return {} }
  }
  const params = new URLSearchParams(text)
  const out = {}
  for (const [k, v] of params) out[k] = v
  return out
}

function redirect(to, headers) {
  return new Response(null, { status: 302, headers: { location: to, ...(headers || {}) } })
}

function page(title, body, extraHeaders) {
  const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>FreeNova | ${esc(title)}</title>
<style>
:root{--bg:#0B1210;--panel:#121A18;--card:#1E2422;--line:#2A3532;--text:#E8EEEA;--muted:#8A9A94;--accent:#2EBF92;--gold:#C9A227;--bad:#C45C4A;--ok:#2EBF92}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--text);font:15px/1.45 system-ui,Segoe UI,sans-serif}
a{color:var(--accent);text-decoration:none}
a:hover{text-decoration:underline}
.shell{display:flex;min-height:100vh}
nav.side{width:220px;background:var(--panel);border-right:1px solid var(--line);padding:22px 16px;flex-shrink:0}
nav.side h1{margin:0 0 4px;font-size:13px;letter-spacing:.14em;color:var(--accent);text-transform:uppercase}
nav.side .sub{color:var(--muted);font-size:12px;margin-bottom:22px}
nav.side a{display:block;padding:8px 10px;border-radius:8px;color:var(--text);margin-bottom:4px}
nav.side a.on,nav.side a:hover{background:var(--card);text-decoration:none}
main{flex:1;padding:28px 32px;min-width:0}
h2{margin:0 0 16px;font-size:22px;font-weight:650}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(180px,1fr));gap:12px;margin-bottom:22px}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:16px}
.card .k{color:var(--muted);font-size:11px;letter-spacing:.08em;text-transform:uppercase}
.card .v{font-size:22px;margin-top:6px;font-weight:650}
.badge{display:inline-block;padding:2px 8px;border-radius:999px;font-size:11px;font-weight:700;background:#1a3;color:#d8ffe8}
.badge.off{background:#333;color:#bbb}
.badge.warn{background:#4a3a12;color:var(--gold)}
.badge.err{background:#4a2220;color:#f0b0a8}
table{width:100%;border-collapse:collapse;font-size:13px}
th,td{text-align:left;padding:8px 10px;border-bottom:1px solid var(--line)}
th{color:var(--muted);font-weight:600}
input,select,textarea,button{font:inherit}
input,select,textarea{width:100%;background:#0e1614;border:1px solid var(--line);color:var(--text);border-radius:8px;padding:8px 10px}
label{display:block;color:var(--muted);font-size:12px;margin:10px 0 4px}
.row{display:flex;gap:8px;flex-wrap:wrap;align-items:end}
.row>*{flex:1;min-width:120px}
button,.btn{background:var(--accent);color:#06281e;border:0;border-radius:8px;padding:8px 14px;font-weight:700;cursor:pointer}
button.ghost,.btn.ghost{background:transparent;color:var(--text);border:1px solid var(--line)}
button.danger{background:var(--bad);color:#fff}
.muted{color:var(--muted)}
.err{color:#f0b0a8}
.empty{padding:28px;text-align:center;color:var(--muted)}
form.inline{display:inline}
@media(max-width:800px){.shell{display:block}nav.side{width:auto;border-right:0;border-bottom:1px solid var(--line)}}
</style>
</head>
<body>${body}</body>
</html>`
  const headers = { "content-type": "text/html; charset=utf-8", "cache-control": "no-store", ...(extraHeaders || {}) }
  return new Response(html, { status: 200, headers })
}

function msiePage() {
  return page("Admin", `<main style="padding:48px;max-width:480px"><h2>FreeNova Admin</h2><p>Open this page in a current browser. The CS 1.6 MOTD engine cannot run the control center.</p></main>`)
}

function loginPage(env, err) {
  const configured = !!env.ADMIN_PASSWORD
  const body = `<main style="max-width:420px;margin:8vh auto;padding:24px">
  <div class="card">
    <div class="k">FreeNova</div>
    <h2>Admin Control Center</h2>
    ${configured
      ? `<p class="muted">Staff login. The game still owns every kick, ban, coin, and event apply.</p>
         ${err ? `<p class="err">${esc(err)}</p>` : ""}
         <form method="post" action="/admin/login">
           <label>SteamID</label>
           <input name="steamid" value="${esc(OWNER)}" autocomplete="username" required>
           <label>Password</label>
           <input name="password" type="password" autocomplete="current-password" required>
           <p><button type="submit">Sign in</button></p>
         </form>`
      : `<p class="err">Admin password is not configured. Set ADMIN_PASSWORD on the panel process. No default exists.</p>`}
  </div>
  </main>`
  return page("Admin", body)
}

function shell(session, section, inner) {
  const items = [
    ["overview", "Overview"],
    ["players", "Players"],
    ["catalog", "Catalog"],
    ["events", "Events"],
    ["logs", "Audit log"],
    ["diagnostics", "Diagnostics"]
  ]
  const nav = items.map(([id, label]) =>
    `<a href="/admin?s=${id}" class="${section === id ? "on" : ""}">${label}</a>`).join("")
  return `<div class="shell">
  <nav class="side">
    <h1>FreeNova</h1>
    <div class="sub">Admin Control Center</div>
    ${nav}
    <form method="post" action="/admin/logout" style="margin-top:24px">
      <input type="hidden" name="csrf" value="${esc(session.csrf)}">
      <button class="ghost" type="submit">Sign out</button>
    </form>
    <p class="muted" style="font-size:11px;margin-top:16px">${esc(session.name)}<br>${esc(session.steamid)}</p>
  </nav>
  <main>${inner}</main>
</div>`
}

async function metaMap(env) {
  const { results } = await env.DB.prepare(`SELECT key, value FROM meta`).all()
  const m = {}
  for (const r of results || []) m[r.key] = r.value
  return m
}

function card(k, v) {
  if (v == null || v === "") return ""
  return `<div class="card"><div class="k">${esc(k)}</div><div class="v">${esc(v)}</div></div>`
}

async function audit(env, actor, action, detail) {
  await env.DB.prepare(
    `INSERT INTO admin_audit (steamid, action, detail, created_at) VALUES (?1,?2,?3,?4)`
  ).bind(actor, action, String(detail || "").slice(0, 240), nowSec()).run()
}

async function queueStaffAction(env, steamid, type, arg) {
  if (!STAFF_TYPES.has(type)) return { ok: false, error: "unknown action" }
  if (typeof arg !== "string" || arg.length > 64 || ARG_BAD.test(arg))
    return { ok: false, error: "bad argument" }
  if (!validSteamid(steamid) && steamid !== OPS_STEAM)
    return { ok: false, error: "bad steamid" }
  const dup = await env.DB.prepare(
    `SELECT id FROM actions WHERE steamid=?1 AND type=?2 AND arg=?3 AND status IN ('pending','sent')`
  ).bind(steamid, type, arg).first()
  if (dup) return { ok: true, queued: dup.id, note: "already queued" }
  const res = await env.DB.prepare(
    `INSERT INTO actions (steamid, type, arg, status, created_at) VALUES (?1,?2,?3,'pending',?4)`
  ).bind(steamid, type, arg, nowSec()).run()
  return { ok: true, queued: res.meta && res.meta.last_row_id }
}

async function seedStaff(env) {
  const t = nowSec()
  await env.DB.prepare(
    `INSERT INTO staff (steamid, name, role, enabled, created_at)
     VALUES (?1,?2,'owner',1,?3)
     ON CONFLICT(steamid) DO NOTHING`
  ).bind(OWNER, "Owner", t).run()
  const extra = String(env.ADMIN_STEAMIDS || "").split(/[,\s]+/).filter(validSteamid)
  for (const sid of extra) {
    if (sid === OWNER) continue
    await env.DB.prepare(
      `INSERT INTO staff (steamid, name, role, enabled, created_at)
       VALUES (?1,?2,'owner',1,?3)
       ON CONFLICT(steamid) DO NOTHING`
    ).bind(sid, sid, t).run()
  }
}

export async function ensureAdminTables(env) {
  await ensureOpsTables(env)
  // events.detail is the player-facing blurb /api/public/events and /m/e/
  // publish. Adding it lazily keeps this migration safe on the live replica.
  await ensureScheduleDetailColumn(env)
  await seedStaff(env)
}

// Window (seconds) a login failure counts for; also the lifetime of a
// login_fail meta row.
const LOGIN_FAIL_WINDOW = 600

async function loginFailCount(env, ip) {
  const row = await env.DB.prepare(`SELECT value FROM meta WHERE key=?1`).bind("login_fail:" + ip).first()
  if (!row) return { n: 0, at: 0 }
  const [n, at] = String(row.value || "0:0").split(":").map(x => parseInt(x, 10) || 0)
  if (nowSec() - at > LOGIN_FAIL_WINDOW) return { n: 0, at: 0 }
  return { n, at }
}

async function bumpLoginFail(env, ip) {
  const cur = await loginFailCount(env, ip)
  const n = cur.n + 1
  const now = nowSec()
  await env.DB.prepare(
    `INSERT INTO meta (key, value) VALUES (?1,?2) ON CONFLICT(key) DO UPDATE SET value=?2`
  ).bind("login_fail:" + ip, `${n}:${now}`).run()
  // Expire the counters. Before this, every distinct address that ever failed a
  // login left a permanent meta row (REVIEW.md §4.2 M2) - the table grew for
  // ever and the "counters expire" behaviour only ever existed in the reader.
  // The timestamp is the part after the colon in "n:at".
  try {
    await env.DB.prepare(
      `DELETE FROM meta WHERE key LIKE 'login_fail:%'
         AND CAST(substr(value, instr(value, ':') + 1) AS INTEGER) < ?1`
    ).bind(now - LOGIN_FAIL_WINDOW).run()
  } catch {}
  return n
}

async function handleLogin(request, env) {
  const ip = clientIp(request)
  const fails = await loginFailCount(env, ip)
  if (fails.n >= 5)
    return loginPage(env, "Too many failed logins from this address. Wait 10 minutes.")
  const body = await parseBody(request)
  const password = String(body.password || "")
  const steamid = String(body.steamid || "").trim()
  if (!env.ADMIN_PASSWORD)
    return loginPage(env, "Admin password is not configured.")
  if (!validSteamid(steamid))
    return loginPage(env, "SteamID must look like STEAM_0:0:12345.")
  const pwOk = password.length === env.ADMIN_PASSWORD.length
    && timingSafeEqual(password, env.ADMIN_PASSWORD)
  const staff = await env.DB.prepare(
    `SELECT steamid, enabled FROM staff WHERE steamid=?1`
  ).bind(steamid).first()
  if (!pwOk || !staff || Number(staff.enabled) === 0) {
    await bumpLoginFail(env, ip)
    return loginPage(env, "SteamID or password is wrong, or this SteamID is not staff.")
  }
  const exp = nowSec() + SESSION_SEC
  const cookie = await signCookie(env.SYNC_SECRET, steamid, exp)
  const token = await sha256Hex(`${env.SYNC_SECRET}:staff:${steamid}:${exp}`)
  await env.DB.prepare(
    `INSERT INTO admin_sessions (token, steamid, created_at, expires_at) VALUES (?1,?2,?3,?4)
     ON CONFLICT(token) DO UPDATE SET expires_at=?4`
  ).bind(token, steamid, nowSec(), exp).run()
  await env.DB.prepare(`UPDATE staff SET last_login=?2 WHERE steamid=?1`).bind(steamid, nowSec()).run()
  // A successful login clears this address's counter, so a legitimate staff
  // member who mistyped twice does not carry it for the rest of the window.
  try { await env.DB.prepare(`DELETE FROM meta WHERE key=?1`).bind("login_fail:" + ip).run() } catch {}
  await audit(env, steamid, "LOGIN", ip)
  const secure = new URL(request.url).protocol === "https:"
  return redirect("/admin", { "set-cookie": cookieHeader(cookie, SESSION_SEC, secure) })
}

async function handleLogout(request, env, session) {
  if (session)
    await env.DB.prepare(`DELETE FROM admin_sessions WHERE token=?1`).bind(session.token).run()
  return redirect("/admin", { "set-cookie": cookieHeader("", 0, new URL(request.url).protocol === "https:") })
}

function needConfirm(type, arg) {
  if (type === "ban" || type === "srv_map" || type === "srv_event_clear") return true
  if (type === "give_vip") return true
  if (type === "give_coins") return Math.abs(parseInt(arg, 10) || 0) > 1000
  if (type === "give_xp") return Math.abs(parseInt(arg, 10) || 0) > 5000
  return false
}

function canRun(flags, type) {
  if (type === "kick") return hasFlag(flags, "c")
  if (type === "ban") return hasFlag(flags, "d")
  if (type === "give_coins" || type === "give_xp" || type === "give_vip") return hasFlag(flags, "a")
  if (type === "srv_map") return hasFlag(flags, "f")
  if (type === "srv_event_apply" || type === "srv_event_clear") return hasFlag(flags, "a")
  return false
}

function sanitizeArg(type, raw) {
  let arg = String(raw || "").trim()
  if (type === "kick") {
    arg = arg.replace(/[^\w .:-]/g, "").slice(0, 48) || "staff"
  } else if (type === "ban") {
    const [mins, ...rest] = arg.split(":")
    const minutes = Math.max(0, Math.min(525600, parseInt(mins, 10) || 0))
    const reason = rest.join(":").replace(/[^\w .:-]/g, "").slice(0, 40) || "staff"
    arg = `${minutes}:${reason}`
  } else if (type === "give_coins") {
    const n = Math.max(-50000, Math.min(50000, parseInt(arg, 10) || 0))
    const reason = "staff"
    arg = `${n}:${reason}`
  } else if (type === "give_xp") {
    const n = Math.max(0, Math.min(100000, parseInt(arg, 10) || 0))
    arg = String(n)
  } else if (type === "give_vip") {
    const [tierS, daysS] = arg.split(":")
    const tier = Math.max(0, Math.min(3, parseInt(tierS, 10) || 0))
    const days = Math.max(0, Math.min(365, parseInt(daysS, 10) || 0))
    arg = `${tier}:${days}`
  } else if (type === "srv_map") {
    arg = arg.toLowerCase()
    if (!MAPS.has(arg)) return { error: "Map is not on the whitelist." }
  }
  if (arg.length > 64 || ARG_BAD.test(arg)) return { error: "Argument rejected." }
  return { arg }
}

async function handleAction(env, session, body) {
  const type = String(body.type || body.action || "")
  if (!canRun(session.flags, type))
    return { status: 403, error: "You do not have permission for this action." }
  const target = type.startsWith("srv_") ? OPS_STEAM : String(body.steamid || "").trim()
  if (!type.startsWith("srv_") && !validSteamid(target))
    return { status: 400, error: "Target SteamID is invalid." }
  const cleaned = sanitizeArg(type, body.arg || body.reason || body.map || "")
  if (cleaned.error) return { status: 400, error: cleaned.error }
  if (needConfirm(type, cleaned.arg) && body.confirm !== "1")
    return { status: 400, error: "Confirm this dangerous action." }
  const queued = await queueStaffAction(env, target, type, cleaned.arg)
  if (!queued.ok) return { status: 400, error: queued.error }
  await audit(env, session.steamid, type.toUpperCase(), `${target} ${cleaned.arg}`)
  return { status: 200, ok: true, queued: queued.queued }
}

function catalogList(raw) {
  if (Array.isArray(raw)) return raw
  if (raw && Array.isArray(raw.achievements)) return raw.achievements
  return []
}

async function handleCatalogPost(env, session, body) {
  if (!hasFlag(session.flags, "a"))
    return { status: 403, error: "You do not have permission to edit catalogs." }
  const id = String(body.id || "").trim()
  if (!/^[a-z0-9_]{1,40}$/.test(id))
    return { status: 400, error: "Invalid catalog id." }
  const row = await env.DB.prepare(`SELECT json, version FROM catalog WHERE key='achievements'`).first()
  let parsed = {}
  try { parsed = row && row.json ? JSON.parse(row.json) : {} } catch { parsed = {} }
  const list = catalogList(parsed)
  const item = list.find(a => String(a.id) === id)
  if (!item) return { status: 404, error: "Achievement not found." }
  item.name = String(body.name || item.name || "").slice(0, 64)
  item.desc = String(body.desc || item.desc || "").slice(0, 180)
  const target = parseInt(body.target, 10)
  if (Number.isFinite(target) && target > 0) item.target = target
  const coins = parseInt(body.reward_coins, 10)
  if (Number.isFinite(coins) && coins >= 0) item.reward_coins = coins
  if (body.enabled === "0" || body.enabled === "1") item.enabled = Number(body.enabled)
  const json = JSON.stringify(Array.isArray(parsed) ? list : { ...parsed, achievements: list })
  await env.DB.prepare(
    `INSERT INTO catalog (key, version, json, updated_at) VALUES ('achievements', ?1, ?2, ?3)
     ON CONFLICT(key) DO UPDATE SET json=?2, version=catalog.version+1, updated_at=?3`
  ).bind((Number(row && row.version) || 0) + 1, json, nowSec()).run()
  await audit(env, session.steamid, "CATALOG_EDIT", id)
  return { status: 200, ok: true }
}

async function renderCatalog(env, session) {
  const row = await env.DB.prepare(`SELECT json FROM catalog WHERE key='achievements'`).first()
  let parsed = {}
  try { parsed = row && row.json ? JSON.parse(row.json) : {} } catch { parsed = {} }
  const list = catalogList(parsed)
  const rows = list.map(a => `<tr>
    <td><code>${esc(a.id)}</code></td>
    <td>${a.bit != null ? esc(a.bit) : "—"}</td>
    <td>
      <form method="post" action="/admin/catalog">
        <input type="hidden" name="csrf" value="${esc(session.csrf)}">
        <input type="hidden" name="id" value="${esc(a.id)}">
        <input name="name" value="${esc(a.name || "")}" maxlength="64">
        <input name="desc" value="${esc(a.desc || "")}" maxlength="180">
        <div class="row">
          <label>Target<input name="target" value="${esc(a.target || 0)}"></label>
          <label>Coins<input name="reward_coins" value="${esc(a.reward_coins || 0)}"></label>
          <label>Enabled<select name="enabled"><option value="1"${Number(a.enabled) !== 0 ? " selected" : ""}>on</option><option value="0"${Number(a.enabled) === 0 ? " selected" : ""}>off</option></select></label>
        </div>
        <p><button type="submit">Save</button> <span class="muted">id/bit locked</span></p>
      </form>
    </td>
  </tr>`).join("")
  return shell(session, "catalog", `<h2>Achievement catalog</h2>
    <p class="muted">Staff may edit name, description, target, coins, and enabled. id and bit cannot change. Game remains the spender.</p>
    <table><tr><th>id</th><th>bit</th><th>fields</th></tr>${rows || "<tr><td colspan='3' class='empty'>No catalog row yet. Wait for a game sync.</td></tr>"}</table>`)
}

async function handleEventPost(env, session, body) {
  if (!hasFlag(session.flags, "a"))
    return { status: 403, error: "You do not have permission to manage events." }
  const op = String(body.op || "create")
  const id = parseInt(body.id, 10) || 0
  if (op === "cancel" && id) {
    if (body.confirm !== "1")
      return { status: 400, error: "Confirm event cancellation." }
    // Cancel guard: only live lifecycle states may be rewritten as cancelled.
    // Completed/cancelled history is immutable from the panel (game settlement
    // owns the final state) — double-cancel must not re-fire srv_event_clear.
    const evRow = await env.DB.prepare(`SELECT status FROM events WHERE id=?1`).bind(id).first()
    const evSt = String((evRow && evRow.status) || "").toLowerCase()
    if (evSt !== "active" && evSt !== "scheduled")
      return { status: 400, error: "Only active or scheduled events can be cancelled." }
    await env.DB.prepare(`UPDATE events SET status='cancelled' WHERE id=?1`).bind(id).run()
    await queueStaffAction(env, OPS_STEAM, "srv_event_clear", String(id))
    await env.DB.prepare(
      `INSERT INTO event_history (event_id, title, type, xp_mult, coins_mult, start_at, end_at, completed_at)
       SELECT id, title, type, xp_mult, coins_mult, start_at, end_at, ?2 FROM events WHERE id=?1
       ON CONFLICT(event_id) DO NOTHING`
    ).bind(id, nowSec()).run()
    const { results: still } = await env.DB.prepare(
      `SELECT id, type, xp_mult, coins_mult FROM events WHERE status = 'active'`
    ).all()
    for (const ev of still || [])
      await queueStaffAction(env, OPS_STEAM, "srv_event_apply", `${ev.id}:${ev.xp_mult}:${ev.coins_mult}:${ev.type}`)
    await audit(env, session.steamid, "EVENT_STOPPED", String(id))
    return { status: 200, ok: true }
  }
  if (op === "extend" && id) {
    const extra = Math.max(60, parseInt(body.seconds, 10) || 3600)
    await env.DB.prepare(`UPDATE events SET end_at = end_at + ?2 WHERE id=?1 AND status='active'`).bind(id, extra).run()
    const ev = await env.DB.prepare(`SELECT * FROM events WHERE id=?1`).bind(id).first()
    if (ev)
      await queueStaffAction(env, OPS_STEAM, "srv_event_apply", `${ev.id}:${ev.xp_mult}:${ev.coins_mult}:${ev.type}`)
    await audit(env, session.steamid, "EVENT_EXTENDED", `${id}+${extra}`)
    return { status: 200, ok: true }
  }
  // op=edit: reshape the settlement contract (metric/target/scope/reward text)
  // while scheduled or active; change PRIZE AMOUNTS only while scheduled —
  // active settlement already baselined the payout contract, and completed /
  // cancelled history stays immutable (same rule as op=cancel). Multipliers,
  // type and window are NOT editable here: the game only re-reads them on a
  // new srv_event_apply, and active contract edits already reach the game via
  // the metric-event spec sync.js broadcasts on every snapshot push.
  if (op === "edit" && id) {
    const ev = await env.DB.prepare(`SELECT * FROM events WHERE id=?1`).bind(id).first()
    if (!ev) return { status: 400, error: "Unknown event id." }
    const st = String(ev.status || "").toLowerCase()
    if (st !== "scheduled" && st !== "active")
      return { status: 400, error: "Only scheduled or active events can be edited." }

    // Columns to write. Absent or blank form fields keep their stored value.
    const upd = new Map()
    const given = (k) => body[k] !== undefined && String(body[k]).trim() !== ""

    if (given("metric")) {
      const raw = String(body.metric).trim().toLowerCase()
      const metric = EVENT_METRIC_ALIAS[raw] || raw
      if (!EVENT_METRICS.has(metric)) return { status: 400, error: "Unknown event metric." }
      upd.set("metric", metric)
    }
    if (given("target")) {
      const target = Number(String(body.target).trim())
      if (!Number.isInteger(target) || target < 0)
        return { status: 400, error: "Target must be a whole number of 0 or more." }
      upd.set("target", target)
    }
    if (given("scope")) {
      const scope = String(body.scope).trim().toLowerCase()
      if (!EVENT_SCOPES.has(scope)) return { status: 400, error: "Unknown event scope." }
      upd.set("scope", scope)
    }
    if (body.reward !== undefined) { // "" is a valid (empty) prize line
      const reward = String(body.reward)
      if (/[\r\n\0<>]/.test(reward))
        return { status: 400, error: "Reward text cannot contain angle brackets or line breaks." }
      if (reward.length > 120)
        return { status: 400, error: "Reward text cannot exceed 120 characters." }
      upd.set("reward", reward)
    }
    // The public blurb the panel schedule publishes (MOTD + /api/public/events).
    // Same escaping rules as reward text: it is rendered into an MOTD page.
    if (body.detail !== undefined) {
      const detail = String(body.detail).replace(/\s+/g, " ").trim()
      if (/[\r\n\0<>]/.test(detail))
        return { status: 400, error: "Public blurb cannot contain angle brackets or line breaks." }
      if (detail.length > 160)
        return { status: 400, error: "Public blurb cannot exceed 160 characters." }
      upd.set("detail", detail)
    }
    // Prize amounts: parsed (and range-checked) even when the scheduled-only
    // gate below will reject them, so staff always see the field error first.
    const amounts = new Map()
    if (given("reward_coins")) {
      const n = Number(String(body.reward_coins).trim())
      if (!Number.isInteger(n) || n < 0 || n > 50000)
        return { status: 400, error: "Reward coins must be a whole number in 0-50000." }
      amounts.set("reward_coins", n)
    }
    if (given("reward_viptier")) {
      const n = Number(String(body.reward_viptier).trim())
      if (!Number.isInteger(n) || n < 0 || n > 3)
        return { status: 400, error: "Reward VIP tier must be a whole number in 0-3." }
      amounts.set("reward_viptier", n)
    }
    if (given("reward_vipdays")) {
      const n = Number(String(body.reward_vipdays).trim())
      if (!Number.isInteger(n) || n < 0 || n > 365)
        return { status: 400, error: "Reward VIP days must be a whole number in 0-365." }
      amounts.set("reward_vipdays", n)
    }
    if (given("min_score")) {
      const n = Number(String(body.min_score).trim())
      if (!Number.isInteger(n) || n < 0)
        return { status: 400, error: "Minimum score must be a whole number of 0 or more." }
      amounts.set("min_score", n)
    }
    // Only a real amount DELTA is gated: resubmitting the stored value on an
    // active event is a no-op, not a payout rewrite.
    const amountChanged = [...amounts].some(([col, val]) => Number(ev[col]) !== val)
    if (st !== "scheduled" && amountChanged)
      return { status: 400, error: "Prize amounts can only be edited while scheduled." }

    for (const [col, val] of amounts) upd.set(col, val)
    if (!upd.size) return { status: 400, error: "Nothing to update." }
    const cols = [], binds = []
    for (const [col, val] of upd) { binds.push(val); cols.push(`${col} = ?${binds.length}`) }
    binds.push(id)
    await env.DB.prepare(
      `UPDATE events SET ${cols.join(", ")} WHERE id = ?${binds.length}`
    ).bind(...binds).run()
    await audit(env, session.steamid, "EVENT_EDITED", `${id}:${[...upd.keys()].join(",")}`)
    return { status: 200, ok: true }
  }
  const title = String(body.title || body.name || "").trim().slice(0, 80)
  const type = String(body.type || "xp_mult")
  if (!title) return { status: 400, error: "Event name is required." }
  if (!EVENT_TYPES.has(type)) return { status: 400, error: "Unknown event type." }
  const detail = String(body.detail || "").replace(/\s+/g, " ").trim().slice(0, 160)
  if (/[\r\n\0<>]/.test(detail))
    return { status: 400, error: "Public blurb cannot contain angle brackets or line breaks." }
  const start = parseInt(body.start_at, 10) || Date.parse(body.start || "") / 1000 || nowSec()
  const end = parseInt(body.end_at, 10) || Date.parse(body.end || "") / 1000 || (start + 3600)
  if (!(end > start)) return { status: 400, error: "Event could not be created because its end time is before its start time." }
  // Multiplier step: the game only ever applies 0.5 steps (1.0, 1.5 … 5.0),
  // so snap whatever staff type to the nearest half (Math.round(x*2)/2) and
  // then clamp to the 1..5 window the create form advertises.
  const mult = (v) => Math.max(1, Math.min(5, Math.round((Number(v) || 1) * 2) / 2))
  const xp = mult(body.xp_mult)
  const coins = mult(body.coins_mult)
  const group = conflictGroup(type)
  const clash = await env.DB.prepare(
    `SELECT id, title FROM events WHERE status IN ('active','scheduled') AND conflict_group=?1 AND start_at < ?3 AND end_at > ?2`
  ).bind(group, start, end).first()
  if (clash)
    return { status: 400, error: `Conflicts with event #${clash.id} (${clash.title}). Same category cannot overlap.` }
  await env.DB.prepare(
    `INSERT INTO events (title, type, status, start_at, end_at, xp_mult, coins_mult, conflict_group, created_by, created_at, detail)
     VALUES (?1,?2,'scheduled',?3,?4,?5,?6,?7,?8,?9,?10)`
  ).bind(title, type, start, end, xp, coins, group, session.steamid, nowSec(), detail).run()
  await audit(env, session.steamid, "EVENT_CREATED", title)
  // TODO(push): when sync.js gains a `srv_event_schedule` action, the game can
  // pull this schedule instead of staff editing configs/freenova/events.ini by
  // hand. Until the plugin implements and validates that action, nothing here
  // writes to the game — the ini stays the source of truth for multipliers.
  return { status: 200, ok: true }
}

function fmtTime(unix) {
  const n = Number(unix) || 0
  if (!n) return "—"
  return new Date(n * 1000).toISOString().replace("T", " ").slice(0, 16) + " UTC"
}

async function renderOverview(env, session) {
  const meta = await metaMap(env)
  const online = await env.DB.prepare(
    `SELECT COUNT(*) AS n FROM players WHERE last_seen >= ?1`
  ).bind(nowSec() - 900).first()
  const active = await env.DB.prepare(
    `SELECT title, type, end_at, xp_mult FROM events WHERE status='active' ORDER BY id DESC LIMIT 1`
  ).first()
  const cards = [
    card("Players online", online && online.n != null ? String(online.n) : null),
    card("Map", meta.server_map),
    card("Hostname", meta.server_hostname),
    card("Slots", meta.server_players != null ? `${meta.server_humans || "?"} humans · ${meta.server_players}/${meta.server_maxplayers || "?"}` : null),
    card("Server", meta.server_online === "1" ? "Online" : (meta.last_push ? "Last seen" : null)),
    card("Last push", meta.last_push ? fmtTime(meta.last_push) : null),
    card("Happy hour", meta.happy_hour === "1" ? "On" : (meta.happy_hour === "0" ? "Off" : null)),
    card("Event XP", meta.event_xp && Number(meta.event_xp) > 1 ? `${meta.event_xp}x` : null),
    card("Event Coins", meta.event_coins && Number(meta.event_coins) > 1 ? `${meta.event_coins}x` : null),
    card("Active event", active ? `${active.title} (${active.xp_mult}x)` : "None")
  ].filter(Boolean).join("")
  const recent = ((await env.DB.prepare(
    `SELECT steamid, action, detail, created_at FROM admin_audit ORDER BY id DESC LIMIT 8`
  ).all()).results || [])
  const rows = recent.map(r => `<tr><td>${esc(fmtTime(r.created_at))}</td><td>${esc(r.steamid)}</td><td>${esc(r.action)}</td><td>${esc(r.detail)}</td></tr>`).join("")
  return shell(session, "overview", `
    <h2>Overview</h2>
    <div class="grid">${cards || `<div class="card empty">No live server snapshot yet. Waiting for the next HMAC push.</div>`}</div>
    <div class="card">
      <div class="k">Recent staff actions</div>
      ${rows ? `<table><tr><th>When</th><th>Staff</th><th>Action</th><th>Detail</th></tr>${rows}</table>` : `<p class="empty">No recent moderation actions.</p>`}
    </div>`)
}

function playerActions(session, p) {
  const csrf = esc(session.csrf)
  const sid = esc(p.steamid)
  const bits = []
  if (hasFlag(session.flags, "c"))
    bits.push(`<form class="inline" method="post" action="/admin/action">
      <input type="hidden" name="csrf" value="${csrf}">
      <input type="hidden" name="type" value="kick">
      <input type="hidden" name="steamid" value="${sid}">
      <input type="hidden" name="arg" value="staff">
      <button type="submit">Kick</button></form>`)
  if (hasFlag(session.flags, "d"))
    bits.push(`<form class="inline" method="post" action="/admin/action">
      <input type="hidden" name="csrf" value="${csrf}">
      <input type="hidden" name="type" value="ban">
      <input type="hidden" name="steamid" value="${sid}">
      <input type="hidden" name="arg" value="1440:staff">
      <input type="hidden" name="confirm" value="1">
      <button class="danger" type="submit">Ban 1d</button></form>`)
  if (hasFlag(session.flags, "a"))
    bits.push(`<form class="inline" method="post" action="/admin/action">
      <input type="hidden" name="csrf" value="${csrf}">
      <input type="hidden" name="type" value="give_coins">
      <input type="hidden" name="steamid" value="${sid}">
      <input name="arg" value="100" style="width:80px">
      <button type="submit">Coins</button></form>`)
  return bits.join(" ")
}

async function renderPlayers(env, session, url) {
  const q = (url.searchParams.get("q") || "").trim()
  const filter = url.searchParams.get("f") || "online"
  const pageNo = Math.max(1, parseInt(url.searchParams.get("p"), 10) || 1)
  const limit = 25
  const offset = (pageNo - 1) * limit
  const clauses = []
  const bind = []
  let i = 1
  if (filter === "online") { clauses.push(`last_seen >= ?${i++}`); bind.push(nowSec() - 900) }
  if (filter === "vip") clauses.push("vip_tier > 0")
  if (q) {
    clauses.push(`(name LIKE ?${i} OR steamid LIKE ?${i + 1})`)
    bind.push("%" + q.replace(/[%_]/g, "") + "%", "%" + q.replace(/[%_]/g, "") + "%")
    i += 2
  }
  const where = clauses.length ? "WHERE " + clauses.join(" AND ") : ""
  const { results } = await env.DB.prepare(
    `SELECT steamid, name, level, vip_tier, coins, xp, last_seen FROM players ${where}
     ORDER BY last_seen DESC LIMIT ${limit} OFFSET ${offset}`
  ).bind(...bind).all()
  const rows = (results || []).map(p => `<tr>
    <td>${esc(p.name)}</td><td><code>${esc(p.steamid)}</code></td>
    <td>${esc(p.level)}</td><td>${esc(p.vip_tier)}</td>
    <td>${esc(p.coins)}</td><td>${esc(p.xp)}</td>
    <td>${esc(fmtTime(p.last_seen))}</td>
    <td>${playerActions(session, p)}</td>
  </tr>`).join("")
  return shell(session, "players", `
    <h2>Players</h2>
    <form method="get" action="/admin" class="row" style="margin-bottom:16px">
      <input type="hidden" name="s" value="players">
      <div><label>Search</label><input name="q" value="${esc(q)}" placeholder="Name or SteamID"></div>
      <div><label>Filter</label>
        <select name="f">
          <option value="online"${filter === "online" ? " selected" : ""}>Online</option>
          <option value="all"${filter === "all" ? " selected" : ""}>All snapshots</option>
          <option value="vip"${filter === "vip" ? " selected" : ""}>VIP</option>
        </select>
      </div>
      <div><button type="submit">Apply</button></div>
    </form>
    <div class="card">${rows
      ? `<table><tr><th>Name</th><th>SteamID</th><th>Lvl</th><th>VIP</th><th>Coins</th><th>XP</th><th>Seen</th><th></th></tr>${rows}</table>`
      : `<p class="empty">No players found.</p>`}</div>`)
}

async function renderEvents(env, session, url, flash) {
  const tab = url.searchParams.get("tab") || "overview"
  const { results } = await env.DB.prepare(
    `SELECT * FROM events ORDER BY id DESC LIMIT 50`
  ).all()
  const list = results || []
  const active = list.filter(e => e.status === "active")
  const scheduled = list.filter(e => e.status === "scheduled")
  const hist = ((await env.DB.prepare(`SELECT * FROM event_history ORDER BY id DESC LIMIT 20`).all()).results) || []
  const csrf = esc(session.csrf)
  const tabs = ["overview", "active", "scheduled", "create", "history"].map(t =>
    `<a href="/admin?s=events&tab=${t}" class="${tab === t ? "on" : ""}" style="margin-right:10px">${t}</a>`).join("")
  let inner = ""
  if (tab === "create") {
    inner = `<div class="card"><form method="post" action="/admin/events">
      <input type="hidden" name="csrf" value="${csrf}">
      <input type="hidden" name="op" value="create">
      <label>Name</label><input name="title" required>
      <label>Public blurb (players see this on /api/public/events and the MOTD)</label>
      <input name="detail" maxlength="160" placeholder="What players get and when">
      <label>Type</label>
      <select name="type">
        <option value="xp_mult">XP multiplier</option>
        <option value="double_xp">Double XP</option>
        <option value="happy_hour">Happy hour</option>
        <option value="coins_mult">Coins multiplier</option>
        <option value="community_goal">Community goal</option>
      </select>
      <div class="row">
        <div><label>Start (UTC)</label><input type="datetime-local" name="start"></div>
        <div><label>End (UTC)</label><input type="datetime-local" name="end"></div>
      </div>
      <div class="row">
        <div><label>XP mult (1–5)</label><input name="xp_mult" value="2"></div>
        <div><label>Coins mult (1–5)</label><input name="coins_mult" value="1"></div>
      </div>
      <p><button type="submit">Create scheduled event</button></p>
      <p class="muted">The game applies multipliers on the next snapshot. Compatible XP events cannot overlap.</p>
      <p class="muted">The game server's <code>configs/freenova/events.ini</code> is still the source of truth for the
      multipliers it applies; this scheduler is the panel's own schedule, and it is what the MOTD and the bot read.</p>
    </form></div>`
  } else if (tab === "history") {
    inner = hist.length
      ? `<div class="card"><table><tr><th>ID</th><th>Title</th><th>Type</th><th>Ended</th></tr>${
        hist.map(h => `<tr><td>${esc(h.event_id)}</td><td>${esc(h.title)}</td><td>${esc(h.type)}</td><td>${esc(fmtTime(h.completed_at))}</td></tr>`).join("")
      }</table></div>`
      : `<div class="card empty">No event history.</div>`
  } else {
    const show = tab === "active" ? active : tab === "scheduled" ? scheduled : list
    inner = show.length ? `<div class="card"><table>
      <tr><th>ID</th><th>Title</th><th>Type</th><th>Status</th><th>Window</th><th>XP</th><th></th></tr>
      ${show.map(e => `<tr>
        <td>${esc(e.id)}</td><td>${esc(e.title)}${e.detail ? `<br><span class="muted">${esc(e.detail)}</span>` : ""}</td><td>${esc(e.type)}</td>
        <td><span class="badge ${e.status === "active" ? "" : e.status === "error" ? "err" : "off"}">${esc(e.status)}</span></td>
        <td>${esc(fmtTime(e.start_at))} → ${esc(fmtTime(e.end_at))}</td>
        <td>${esc(e.xp_mult)}x</td>
        <td>${e.status === "active" && hasFlag(session.flags, "a") ? `
          <form class="inline" method="post" action="/admin/events">
            <input type="hidden" name="csrf" value="${csrf}">
            <input type="hidden" name="op" value="extend">
            <input type="hidden" name="id" value="${esc(e.id)}">
            <input type="hidden" name="seconds" value="3600">
            <button class="ghost" type="submit">+1h</button>
          </form>
          <form class="inline" method="post" action="/admin/events">
            <input type="hidden" name="csrf" value="${csrf}">
            <input type="hidden" name="op" value="cancel">
            <input type="hidden" name="id" value="${esc(e.id)}">
            <input type="hidden" name="confirm" value="1">
            <button class="danger" type="submit">Cancel</button>
          </form>` : ""}</td>
      </tr>`).join("")}
    </table></div>` : `<div class="card empty">${tab === "active" ? "No active events." : tab === "scheduled" ? "No upcoming events." : "No events yet."}</div>`
  }
  return shell(session, "events", `
    <h2>Events</h2>
    ${flash ? `<p class="${flash.ok ? "muted" : "err"}">${esc(flash.msg)}</p>` : ""}
    <p>${tabs}</p>
    ${inner}`)
}

async function renderLogs(env, session, url) {
  const action = (url.searchParams.get("action") || "").trim()
  const actor = (url.searchParams.get("actor") || "").trim()
  const clauses = []
  const bind = []
  let i = 1
  if (action) { clauses.push(`action LIKE ?${i++}`); bind.push("%" + action.replace(/[%_]/g, "") + "%") }
  if (actor) { clauses.push(`steamid LIKE ?${i++}`); bind.push("%" + actor.replace(/[%_]/g, "") + "%") }
  const where = clauses.length ? "WHERE " + clauses.join(" AND ") : ""
  const { results } = await env.DB.prepare(
    `SELECT steamid, action, detail, created_at FROM admin_audit ${where} ORDER BY id DESC LIMIT 100`
  ).bind(...bind).all()
  const rows = (results || []).map(r => `<tr><td>${esc(fmtTime(r.created_at))}</td><td>${esc(r.steamid)}</td><td>${esc(r.action)}</td><td>${esc(r.detail)}</td></tr>`).join("")
  return shell(session, "logs", `
    <h2>Audit log</h2>
    <form method="get" action="/admin" class="row">
      <input type="hidden" name="s" value="logs">
      <div><label>Action</label><input name="action" value="${esc(action)}"></div>
      <div><label>Staff SteamID</label><input name="actor" value="${esc(actor)}"></div>
      <div><button type="submit">Filter</button></div>
    </form>
    <div class="card" style="margin-top:16px">${rows
      ? `<table><tr><th>When</th><th>Staff</th><th>Action</th><th>Detail</th></tr>${rows}</table>`
      : `<p class="empty">No audit rows match.</p>`}</div>`)
}

async function renderDiagnostics(env, session) {
  const meta = await metaMap(env)
  let dbOk = false
  try { dbOk = !!(await env.DB.prepare(`SELECT 1 AS ok`).first()) } catch {}
  const counts = await env.DB.prepare(
    `SELECT status, COUNT(*) AS n FROM events GROUP BY status`
  ).all().catch(() => ({ results: [] }))
  const keys = ["last_push", "server_online", "server_map", "server_hostname", "happy_hour", "event_xp", "event_coins"]
  const rows = keys.filter(k => meta[k] != null).map(k => `<tr><td>${esc(k)}</td><td>${esc(meta[k])}</td></tr>`).join("")
  const ev = (counts.results || []).map(r => `${r.status}:${r.n}`).join(" · ") || "none"
  return shell(session, "diagnostics", `
    <h2>Diagnostics</h2>
    <div class="grid">
      ${card("Database", dbOk ? "Reachable" : "Error")}
      ${card("Last HMAC push", meta.last_push ? fmtTime(meta.last_push) : "Unknown")}
      ${card("Event scheduler", ev)}
      ${card("AMXX / ReAPI", "Unknown")}
    </div>
    <div class="card">${rows ? `<table><tr><th>Meta</th><th>Value</th></tr>${rows}</table>` : `<p class="empty">No server meta yet.</p>`}
    <p class="muted">Plugin health is Unknown unless the game reports it. This page does not invent Healthy.</p>
    </div>`)
}

export async function handleAdmin(request, env) {
  const url = new URL(request.url)
  const path = url.pathname.replace(/\/+$/, "") || "/"
  await ensureAdminTables(env)

  if (isMotdUa(request))
    return msiePage()

  if (request.method === "POST" && (path === "/admin/login" || path === "/admin")) {
    const session = await readSession(request, env)
    if (session && path === "/admin") {
      // logged-in POST to /admin is not login
    } else {
      return handleLogin(request, env)
    }
  }

  const session = await readSession(request, env)

  if (request.method === "POST" && path === "/admin/logout") {
    const body = await parseBody(request)
    if (!session || body.csrf !== session.csrf)
      return new Response("forbidden", { status: 403 })
    return handleLogout(request, env, session)
  }

  if (request.method === "POST" && path === "/admin/action") {
    if (!session) return new Response("forbidden", { status: 403 })
    const body = await parseBody(request)
    if (!body.csrf || body.csrf !== session.csrf)
      return new Response("csrf required", { status: 403 })
    const result = await handleAction(env, session, body)
    if (result.status !== 200)
      return new Response(result.error || "error", { status: result.status })
    return redirect("/admin?s=players")
  }

  if (request.method === "POST" && path === "/admin/events") {
    if (!session) return new Response("forbidden", { status: 403 })
    const body = await parseBody(request)
    if (!body.csrf || body.csrf !== session.csrf)
      return new Response("csrf required", { status: 403 })
    const result = await handleEventPost(env, session, body)
    if (result.status !== 200)
      return page("Admin", shell(session, "events", `<h2>Events</h2><p class="err">${esc(result.error)}</p>`))
    return redirect("/admin?s=events")
  }

  if (request.method === "POST" && path === "/admin/catalog") {
    if (!session) return new Response("forbidden", { status: 403 })
    const body = await parseBody(request)
    if (!body.csrf || body.csrf !== session.csrf)
      return new Response("csrf required", { status: 403 })
    const result = await handleCatalogPost(env, session, body)
    if (result.status !== 200)
      return page("Admin", shell(session, "catalog", `<h2>Catalog</h2><p class="err">${esc(result.error)}</p>`))
    return redirect("/admin?s=catalog")
  }

  if (request.method !== "GET")
    return new Response("method not allowed", { status: 405 })

  if (!session)
    return loginPage(env)

  const section = (url.searchParams.get("s") || "overview").toLowerCase()
  if (section === "players") return page("Admin", await renderPlayers(env, session, url))
  if (section === "catalog") return page("Admin", await renderCatalog(env, session))
  if (section === "events") return page("Admin", await renderEvents(env, session, url))
  if (section === "logs") return page("Admin", await renderLogs(env, session, url))
  if (section === "diagnostics") return page("Admin", await renderDiagnostics(env, session))
  return page("Admin", await renderOverview(env, session))
}
