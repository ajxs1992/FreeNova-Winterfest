import { readContract, queryBoard, stateQuery } from "./query.js"
import { loadTheme, saveTheme, resetTheme } from "./store.js"
import { renderPremier } from "./premier.js"
import { isMotdCompact } from "../ui.js"
import { DEFAULT_THEME, normalizeTheme } from "./theme.js"
import { serverMeta } from "./meta.js"

// Staff key for the theme editor. REVIEW.md §4.1 H2 / §8.7: this used to be
// `GET /top15?theme=save&k=<ADMIN_PASSWORD>` — a live credential in URLs, in
// access logs, in Referer headers and in browser history, compared with `===`.
// The key is now only read from a POST body field `k` or the
// `X-FreeNova-Admin-Key` header, compared in constant time, and a `k` in the
// query string is never accepted (it is ignored, which also means an old
// bookmarked URL simply does nothing instead of leaking the password again).
const KEY_HEADER = "x-freenova-admin-key"

function timingSafeEqualStr(a, b) {
  const x = String(a == null ? "" : a)
  const y = String(b == null ? "" : b)
  if (!x || x.length !== y.length) return false
  let diff = 0
  for (let i = 0; i < x.length; i++) diff |= x.charCodeAt(i) ^ y.charCodeAt(i)
  return diff === 0
}

async function formFields(request) {
  if (!request || request.method !== "POST") return null
  let body
  try { body = await request.text() } catch { return null }
  if (!body) return {}
  const ct = String(request.headers.get("content-type") || "").toLowerCase()
  if (ct.includes("application/json")) {
    try { const o = JSON.parse(body); return o && typeof o === "object" ? o : {} } catch { return {} }
  }
  const out = {}
  for (const [k, v] of new URLSearchParams(body)) out[k] = v
  return out
}

async function staffOk(request, fields, env) {
  const secret = String((env && (env.ADMIN_PASSWORD || env.SYNC_SECRET)) || "")
  if (!secret) return false
  const headerKey = request ? (request.headers.get(KEY_HEADER) || "") : ""
  const bodyKey = fields && typeof fields.k === "string" ? fields.k : ""
  return timingSafeEqualStr(headerKey, secret) || timingSafeEqualStr(bodyKey, secret)
}

export async function pageTop15(env, url, request) {
  const c = readContract(url)
  // MOTD short path (/m/t/...) and legacy UAs set the global compact flag but
  // carry no ?compact=1 - honor it so GoldSrc always gets the MOTD skin.
  if (!c.compact && isMotdCompact()) c.compact = true
  // Theme writes are POST-only: the staff key must travel in a body or a
  // header, never in the URL. The theme fields (t_<name>) may come from the
  // body too; a query-string copy is honoured only for the *values*, which are
  // not secret and are hex-validated by normalizeTheme().
  const themeAction = String((url.searchParams.get("theme") || "")).toLowerCase()
  if (themeAction === "save" || themeAction === "reset") {
    const fields = await formFields(request)
    if (!await staffOk(request, fields, env)) {
      const msg = url.searchParams.has("k")
        ? "The admin key is no longer accepted in a URL. POST it in the body or send it as X-FreeNova-Admin-Key."
        : "Staff key required (POST with k=... or the X-FreeNova-Admin-Key header)."
      return new Response(
        `<html><body bgcolor='#111111' text='#e8e4dc'><p>${msg}</p></body></html>`,
        { status: 403, headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" } }
      )
    }
    if (themeAction === "reset") {
      await resetTheme(env)
    } else {
      const patch = {}
      for (const k of Object.keys(DEFAULT_THEME)) {
        const fromBody = fields && fields["t_" + k] != null ? String(fields["t_" + k]) : null
        const fromQuery = url.searchParams.get("t_" + k)
        const v = fromBody != null ? fromBody : fromQuery
        if (v != null) patch[k] = v
      }
      await saveTheme(env, normalizeTheme({ ...(await loadTheme(env)), ...patch }))
    }
    return new Response(null, { status: 302, headers: { location: "/top15?" + stateQuery(c) } })
  }

  const theme = await loadTheme(env)
  const board = await queryBoard(env, c)
  if (board.error) {
    return new Response("<html><body bgcolor='#111111' text='#e8e4dc'>Unable to load Top 15.</body></html>", {
      status: 200, headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" }
    })
  }
  const now = Math.floor(Date.now() / 1000)
  const medals = {}
  try {
    const m = await env.DB.prepare(
      `SELECT steamid, code FROM ap_unlocks ORDER BY earned_at DESC LIMIT 400`
    ).all()
    for (const row of m.results || []) {
      const sid = String(row.steamid || "")
      if (sid && !medals[sid]) medals[sid] = String(row.code || "").toLowerCase()
    }
  } catch {}
  const html = renderPremier({
    contract: c,
    rows: board.rows,
    total: board.total,
    theme,
    now,
    meta: await serverMeta(env, now),
    medals
  })
  return new Response(html, {
    status: 200,
    headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" }
  })
}
