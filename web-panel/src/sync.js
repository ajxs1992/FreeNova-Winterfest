// FreeNova web panel — sync API (game -> panel push, panel -> game actions).
//
// Push auth (game HMAC; body is hashed first so AMXX 2k buffers cannot truncate):
//   X-FreeNova-Signature = SHA256(secret + ":POST:" + path + ":" + ts + ":" + nonce + ":" + hex(sha256(body)))
//   X-FreeNova-Timestamp within +-300 s of Worker time (replay window).
//
// Web -> game actions (purchases, equips, tags, claims):
//   INTENTIONAL: inbound actions are NOT HMAC-signed like the game POST.
//   The browser cannot hold fnweb_secret. Instead:
//     1. GET queueing requires action token
//        t = SHA256(secret + ":act:" + steamid + ":" + unixDay)
//        unixDay = get_systime()/86400 (AMXX) / Math.floor(Date.now()/86400000)
//        A leaked MOTD URL dies at the next UTC day boundary.
//     2. The game is the spender: it re-checks coins/inventory before apply.
//     3. HMAC covers only POST /api/v1/server/stats (and admin-call).
//   Do not redesign this into a second HMAC on GET — GoldSrc MOTD cannot
//   send signed headers.

export { handleSync }

import { esc, fmt, num } from "./ui.js"

function json(obj, status) {
  return new Response(JSON.stringify(obj), { status, headers: { "content-type": "application/json" } })
}

async function sha256Hex(text) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text))
  return [...new Uint8Array(digest)].map(b => b.toString(16).padStart(2, "0")).join("")
}

function timingSafeEqual(a, b) {
  if (a.length !== b.length) return false
  let diff = 0
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i)
  return diff === 0
}

// Identity the game is allowed to push for. "PENDING" (unauthenticated
// clients) is excluded so nobody can create shadow rows.
function validSteamid(s) {
  return typeof s === "string" && /^STEAM_[0-9]:[0-9]:\d+$/.test(s)
}

export async function actionToken(secret, steamid, dayShift) {
  // Unix-day (UTC), matching AMXX get_systime()/86400. Local calendar dates
  // from format_time vs toISOString() disagreed around midnight.
  const unixDay = Math.floor(Date.now() / 86400000) + (dayShift || 0)
  return sha256Hex(`${secret}:act:${steamid}:${unixDay}`)
}

export async function checkActionToken(secret, steamid, token) {
  if (!secret || !token || typeof token !== "string") return false
  const today = await actionToken(secret, steamid, 0)
  const yesterday = await actionToken(secret, steamid, -1)
  const t = token.toLowerCase()
  return timingSafeEqual(t, today) || timingSafeEqual(t, yesterday)
}

// LOCAL-TRUST ONLY — minting the exact inverse of checkActionToken (today's
// unixDay) panel-side means "whoever can render this page may queue an action
// for this steamid". That is only acceptable when the panel is reachable from
// the LAN/loopback and the MOTD is the only client, which is what the original
// design assumed. REVIEW.md §3.8/§8.6: this comment said so and nothing
// enforced it, while wrangler.toml binds a production D1 - so
// `?steamid=<victim>&act=claim_event:7` queued actions for anyone, with no
// session, no token and no signature.
//
// The gate is explicit and default-OFF:
//   FN_LOCAL_TRUST=1       the runner's env (server_local.mjs) or a Worker
//                          [vars] entry: panel-side minting enabled.
//   unset / anything else  no panel-side minting. Pages fall back to game-minted
//                          ?t= links and say so when asked to act without one.
// Do not set it on a deployment reachable from the internet.
export function localTrustEnabled(env) {
  const v = String((env && env.FN_LOCAL_TRUST) || "").trim().toLowerCase()
  return v === "1" || v === "true" || v === "yes" || v === "on"
}

// What the panels print when an action is requested on a deployment that does
// not mint tokens, instead of silently doing nothing.
export const NO_MINT_MSG = "Action links are not available on this deployment - open the panel from the game server."

export async function mintActionToken(env, steamid) {
  if (!localTrustEnabled(env)) return ""
  const secret = env && env.SYNC_SECRET
  if (!secret || !validSteamid(steamid)) return ""
  return actionToken(secret, steamid, 0)
}

// Largest body either HMAC endpoint will buffer. The local runner already caps
// the socket read (PANEL_MAX_BODY_BYTES, 2 MiB); the Worker used to rely on
// Cloudflare's own limit and still buffered the whole body *before* checking
// the signature, so an unauthenticated 500 MB POST was materialised in memory
// (REVIEW.md §4.1 H3). A full 32-player stats push is ~100 KB.
const MAX_BODY_BYTES = 2 * 1024 * 1024

function tooLarge() {
  return { ok: false, response: json({ ok: false, error: "payload too large" }, 413) }
}

// Rejects an over-size body from the declared length when there is one, and
// again from the buffered text (a chunked request has no content-length).
function bodyTooLarge(request, text) {
  const declared = Number(request.headers.get("content-length") || 0)
  if (Number.isFinite(declared) && declared > MAX_BODY_BYTES) return true
  return typeof text === "string" && text.length > MAX_BODY_BYTES
}

async function verifyGamePost(request, env, path) {
  if (!env.SYNC_SECRET)
    return { ok: false, response: json({ ok: false, error: "sync secret not configured" }, 401) }

  const declared = Number(request.headers.get("content-length") || 0)
  if (Number.isFinite(declared) && declared > MAX_BODY_BYTES) return tooLarge()

  const body = await request.text()
  if (bodyTooLarge(request, body)) return tooLarge()
  const ts = request.headers.get("X-FreeNova-Timestamp") || ""
  const nonce = request.headers.get("X-FreeNova-Nonce") || ""
  const sig = request.headers.get("X-FreeNova-Signature") || ""
  const serverId = request.headers.get("X-FreeNova-Server-ID") || "unknown"

  if (!sig)
    return { ok: false, response: json({ ok: false, error: "missing signature" }, 401) }
  if (!ts)
    return { ok: false, response: json({ ok: false, error: "missing timestamp" }, 401) }

  const now = Math.floor(Date.now() / 1000)
  const tsNum = parseInt(ts, 10)
  if (!tsNum || Math.abs(now - tsNum) > 300)
    return { ok: false, response: json({ ok: false, error: "timestamp outside replay window" }, 401) }

  const bodyHash = await sha256Hex(body)
  const expected = await sha256Hex(`${env.SYNC_SECRET}:POST:${path}:${ts}:${nonce}:${bodyHash}`)
  if (!timingSafeEqual(expected, sig.toLowerCase()))
    return { ok: false, response: json({ ok: false, error: "invalid signature" }, 401) }
  if (!nonce || nonce.length > 64 || /[^\w.-]/.test(nonce))
    return { ok: false, response: json({ ok: false, error: "bad nonce" }, 401) }
    try {
    // Single-statement replay guard: the INSERT is the claim, so two concurrent
    // replays of the same signed request cannot both pass a check-then-insert
    // window. DO NOTHING (not DO UPDATE) so the winner is the only writer and
    // meta.changes tells us whether this request owns the nonce.
    const claim = await env.DB.prepare(
      `INSERT INTO meta (key, value) VALUES (?1, ?2) ON CONFLICT(key) DO NOTHING`
    ).bind("nonce:" + nonce, String(now)).run()
    const owned = claim && claim.meta ? Number(claim.meta.changes || 0) : 1
    if (owned !== 1) return { ok: false, response: json({ ok: false, error: "replayed nonce" }, 401) }
  } catch {
    return { ok: false, response: json({ ok: false, error: "nonce store unavailable" }, 401) }
  }
  try {
    await env.DB.prepare(
      `DELETE FROM meta WHERE key LIKE 'nonce:%' AND CAST(value AS INTEGER) < ?1`
    ).bind(now - 600).run()
  } catch {}
  return { ok: true, body, serverId, now }
}

function discordPingParts(raw) {
  const ping = String(raw || "").trim()
  const role = ping.match(/^<@&(\d+)>$/)
  const user = ping.match(/^<@!?(\d+)>$/)
  const bare = ping.match(/^(\d{15,25})$/)
  const roleId = role ? role[1] : (bare ? bare[1] : "")
  const userId = (!roleId && user) ? user[1] : ""
  return {
    ping: roleId ? `<@&${roleId}>` : (userId ? `<@${userId}>` : ping),
    allowed_mentions: {
      parse: [],
      roles: roleId ? [roleId] : [],
      users: userId ? [userId] : []
    }
  }
}

// The signed string contains the request path, and the plugin signs whatever
// fnweb_path is set to (freenova_sync.sma:210). Deriving it from the request -
// normalised exactly as index.js routes it - means an operator who edits
// fnweb_path keeps a working signature instead of 401-ing every push.
function signedPath(request, fallback) {
  try {
    return new URL(request.url).pathname.replace(/\/+$/, "") || "/"
  } catch {
    return fallback
  }
}

export async function handleAdminCall(request, env) {
  const verified = await verifyGamePost(request, env, signedPath(request, "/api/v1/server/admin-call"))
  if (!verified.ok) return verified.response

  let payload
  try { payload = JSON.parse(verified.body) } catch { return json({ ok: false, error: "bad json" }, 400) }

  const steamid = String(payload.steamid || "")
  if (!validSteamid(steamid)) return json({ ok: false, error: "bad steamid" }, 400)
  const clean = s => String(s || "").replace(/@/g, "@\u200b").replace(/[`*_~|]/g, "").slice(0, 64)
  const name = clean(payload.name || "Unknown").slice(0, 32) || "Unknown"
  const message = clean(payload.message || "").slice(0, 180)
  const map = clean(payload.map || "").slice(0, 32)
  const hostname = clean(payload.hostname || "FreeNova").slice(0, 64)
  const players = num(payload.players)
  const humans = num(payload.humans)
  const maxplayers = num(payload.maxplayers) || 32

  const webhook = env.DISCORD_WEBHOOK_URL
  if (!webhook) return json({ ok: false, error: "webhook not configured" }, 503)

  const { ping, allowed_mentions } = discordPingParts(env.DISCORD_ADMIN_PING)
  const reason = message.trim() || "_No extra message — player used /admin without a reason._"
  const embed = {
    title: "Admin requested in-game",
    description: `**${name}** is asking for staff on **${hostname}**.`,
    color: 0xFFFFFF,
    fields: [
      { name: "Player", value: name, inline: true },
      { name: "SteamID", value: `\`${steamid}\``, inline: true },
      { name: "Map", value: map || "unknown", inline: true },
      { name: "Players", value: `${humans} humans · ${players}/${maxplayers} slots`, inline: true },
      { name: "Server", value: hostname, inline: false },
      { name: "Message", value: reason, inline: false }
    ],
    footer: { text: "FreeNova  •  /admin <reason>" },
    timestamp: new Date().toISOString()
  }

  const discordRes = await fetch(webhook, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      content: `${ping} A player needs an admin.`,
      username: "FreeNova",
      allowed_mentions,
      embeds: [embed]
    })
  })
  if (!discordRes.ok) {
    const t = await discordRes.text().catch(() => "")
    console.error("[calladmin] discord", discordRes.status, t.slice(0, 200))
    return json({ ok: false, error: "discord rejected the webhook" }, 502)
  }
  return json({ ok: true })
}

// How many times one action may be advertised to the game. 2 = the first
// dispatch plus one re-dispatch for a lost reply; see the comment at the queue.
const MAX_DISPATCH_ATTEMPTS = 2
// How long an action stays eligible for dispatch, in seconds.
const DISPATCH_WINDOW = 3600

async function handleSync(request, env) {
  const verified = await verifyGamePost(request, env, signedPath(request, "/api/v1/server/stats"))
  if (!verified.ok) return verified.response
  const body = verified.body
  const serverId = verified.serverId
  const now = verified.now

  let payload
  try { payload = JSON.parse(body) } catch { return json({ ok: false, error: "bad json" }, 400) }
  if (!payload || !Array.isArray(payload.players))
    return json({ ok: false, error: "bad payload" }, 400)

  await ensureOpsTables(env)

  const stmts = []
  const nowSec = now

  // Earned-date derive (2026-10-10): the game payload carries ach_unlocked
  // bitmask but no ap_unlocks array, so earned_at never fills. Detect 0->1
  // bit flips per push and record first-seen date (DO NOTHING preserves it).
  // Backfilled/unknown dates stay NULL-free: we only insert on observed flips.
  const ACH_BIT_META = {
    0: ["kills_100", 50], 1: ["kills_1000", 100], 2: ["kills_5000", 200],
    3: ["hs_100", 50], 4: ["hs_500", 100], 5: ["bomb_specialist", 100],
    6: ["defusal_angel", 100], 7: ["wins_100", 100], 8: ["level_25", 200],
    9: ["level_52", 400], 11: ["win_streak_10", 100], 12: ["coin_tycoon", 100],
    13: ["combat_medic", 100]
  }
  const pushIds = [...new Set(payload.players.map(p => p && p.steamid).filter(validSteamid))]
  let prevUnlocked = new Map()
  try {
    if (pushIds.length) {
      const placeholders = pushIds.map(() => "?").join(",")
      const rows = ((await env.DB.prepare(
        `SELECT steamid, ach_unlocked FROM players WHERE steamid IN (${placeholders})`
      ).bind(...pushIds).all()).results) || []
      for (const r of rows) prevUnlocked.set(r.steamid, r.ach_unlocked | 0)
    }
  } catch (e) { /* first push / table young — derive from zero */ }

  // Ordering guard (REVIEW.md §4.1 H1). The game retries a push when the relay
  // times out, and the retry can arrive after a newer snapshot: without this
  // WHERE, a late push wrote its older xp/coins/kills back over the newer row,
  // the event baselines rescored off the regressed values and every page showed
  // counters rolling backwards. Same idea as the catalog upsert below
  // (`excluded.version >= catalog.version`); last_seen is the per-row clock, so
  // equal timestamps still apply (a replay inside the same second is harmless).
  for (const p of payload.players) {
    if (!p || !validSteamid(p.steamid)) continue
    stmts.push(env.DB.prepare(
      `INSERT INTO players
        (steamid, name, xp, level, rank_id, prestige,
         kills, deaths, assists, headshots, damage, shots, hits, mvps, wins, losses,
         playtime_minutes, rating_x100, vip_tier, coins,
         bp_daily_kills, bp_daily_hs, bp_daily_plants, bp_daily_defuses, bp_daily_wins,
         bp_daily_streak, bp_daily_damage, bp_daily_survives, bp_daily_complete,
         bp_weekly_kills, bp_weekly_hs, bp_weekly_plants, bp_weekly_wins, bp_weekly_complete,
         comp_season, comp_points, comp_lifetime, comp_kills, comp_hs, comp_wins, comp_mvp,
         comp_msn_k, comp_msn_h, comp_msn_w, comp_msn_m, comp_msn_done,
          eq_spawn, eq_title, eq_death, eq_color, custom_tag, eq_model,
          bp_hp, bp_armor, bp_jumps, bp_sniper, bp_laststand, bp_chute, bp_premium, bp_milestone,
          vip_remaining, server_id, last_seen, cc,
          bp_xp, bp_tier)
       VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,
               ?21,?22,?23,?24,?25,?26,?27,?28,?29,?30,?31,?32,?33,?34,?35,
               ?36,?37,?38,?39,?40,?41,?42,?43,?44,?45,?46,?47,?48,?49,?50,?51,?52,
               ?53,?54,?55,?56,?57,?58,?59,?60,?61,?62,?63,?64,?65,?66)
       ON CONFLICT(steamid) DO UPDATE SET
         name=?2, xp=?3, level=?4, rank_id=?5, prestige=?6,
         kills=?7, deaths=?8, assists=?9, headshots=?10, damage=?11, shots=?12, hits=?13,
         mvps=?14, wins=?15, losses=?16, playtime_minutes=?17, rating_x100=?18,
         vip_tier=?19, coins=?20,
         bp_daily_kills=?21, bp_daily_hs=?22, bp_daily_plants=?23,
         bp_daily_defuses=?24, bp_daily_wins=?25, bp_daily_streak=?26,
         bp_daily_damage=?27, bp_daily_survives=?28, bp_daily_complete=?29,
         bp_weekly_kills=?30, bp_weekly_hs=?31, bp_weekly_plants=?32,
         bp_weekly_wins=?33, bp_weekly_complete=?34,
         comp_season=?35, comp_points=?36, comp_lifetime=?37, comp_kills=?38,
         comp_hs=?39, comp_wins=?40, comp_mvp=?41,
         comp_msn_k=?42, comp_msn_h=?43, comp_msn_w=?44, comp_msn_m=?45, comp_msn_done=?46,
         eq_spawn=?47, eq_title=?48, eq_death=?49, eq_color=?50, custom_tag=?51, eq_model=?52,
         bp_hp=?53, bp_armor=?54, bp_jumps=?55, bp_sniper=?56, bp_laststand=?57, bp_chute=?58,
         bp_premium=?59, bp_milestone=?60,
         vip_remaining=?61, server_id=?62, last_seen=?63, cc=?64,
         -- BattlePass XP/tier ledger (REVIEW.md §2.4 H1): the game's own BP
         -- counters, stored as sent. They ride the same last_seen guard, so a
         -- late push cannot roll BP XP back any more than rank xp.
         bp_xp=?65, bp_tier=?66
       WHERE excluded.last_seen >= players.last_seen`)
      .bind(
        p.steamid, str(p.name, 32), num(p.xp), num(p.level), num(p.rank_id), num(p.prestige),
        num(p.kills), num(p.deaths), num(p.assists), num(p.headshots), num(p.damage),
        num(p.shots), num(p.hits), num(p.mvps), num(p.wins), num(p.losses),
        num(p.playtime_minutes), num(p.rating_x100), num(p.vip_tier), num(p.coins),
        num(p.bp_daily_kills), num(p.bp_daily_hs), num(p.bp_daily_plants),
        num(p.bp_daily_defuses), num(p.bp_daily_wins),
        num(p.bp_daily_streak), num(p.bp_daily_damage), num(p.bp_daily_survives),
        num(p.bp_daily_complete),
        num(p.bp_weekly_kills), num(p.bp_weekly_hs), num(p.bp_weekly_plants),
        num(p.bp_weekly_wins), num(p.bp_weekly_complete),
        str(p.comp_season, 8), num(p.comp_points), num(p.comp_lifetime), num(p.comp_kills),
        num(p.comp_hs), num(p.comp_wins), num(p.comp_mvp),
        num(p.comp_msn_k), num(p.comp_msn_h), num(p.comp_msn_w), num(p.comp_msn_m),
        num(p.comp_msn_done),
        num(p.eq_spawn), num(p.eq_title), num(p.eq_death), num(p.eq_color),
        str(p.custom_tag, 48), str(p.eq_model, 48),
        num(p.bp_boosts && p.bp_boosts.hp),
        num(p.bp_boosts && p.bp_boosts.armor),
        num(p.bp_boosts && p.bp_boosts.jumps),
        num(p.bp_boosts && p.bp_boosts.sniper),
        num(p.bp_boosts && p.bp_boosts.laststand),
        num(p.bp_boosts && p.bp_boosts.chute),
        num(p.bp_boosts && p.bp_boosts.premium),
        num(p.bp_boosts && p.bp_boosts.milestone),
        num(p.vip_remaining),
        str(serverId, 48), pushClock(p.last_seen, nowSec), ccOf(p.cc),
        num(p.bp_xp), num(p.bp_tier)))

    // ---- the snapshot's own clock (docs/panel/01-DATA.md §11, page-driven) ----
    // Page-driven additions: players.hits_at (the snapshot that last stamped this
    // row) and this push's player count. Why: the push carries every player on the
    // server every `fnweb_interval`, so "stamped by the newest snapshot" IS
    // presence — but it cannot be read off last_seen alone, because last_seen is
    // also the ordering guard's clock (pushClock) and a re-pushed identical row
    // keeps its old timestamp, which made a memoised fit() decide offline. The
    // column carries the same stamp as last_seen and nothing else; the count is
    // written below from the same body. Both are additive and guarded.
    stmts.push(env.DB.prepare(
      `UPDATE players SET hits_at=?2 WHERE steamid=?1`)
      .bind(p.steamid, pushClock(p.last_seen, nowSec)))

    // per-weapon stats (top-slot array; absent = no update)
    if (Array.isArray(p.weapons)) {
      for (const w of p.weapons) {
        if (!w || !Number.isInteger(w.slot) || w.slot < 0 || w.slot > 22) continue
        stmts.push(env.DB.prepare(
          `INSERT INTO player_weapons (steamid, slot, kills, hs, damage)
           VALUES (?1,?2,?3,?4,?5)
           ON CONFLICT(steamid, slot) DO UPDATE SET kills=?3, hs=?4, damage=?5`)
          .bind(p.steamid, w.slot, num(w.kills), num(w.hs), num(w.damage)))
      }
    }

    // owned weapon skins (authoritative inventory snapshot)
    if (Array.isArray(p.skins)) {
      // full replace for this player: mark everything unowned, then insert truth
      stmts.push(env.DB.prepare(`DELETE FROM player_skins WHERE steamid = ?1`).bind(p.steamid))
      for (const s of p.skins) {
        if (!s || typeof s.grp !== "string" || !/^[a-z0-9_]{1,16}$/.test(s.grp)) continue
        if (!Number.isInteger(s.skin) || s.skin < 0 || s.skin > 63) continue
        stmts.push(env.DB.prepare(
          `INSERT INTO player_skins (steamid, grp, skin, equipped) VALUES (?1,?2,?3,?4)
           ON CONFLICT(steamid, grp, skin) DO UPDATE SET equipped=?4`)
          .bind(p.steamid, s.grp, s.skin, s.equipped ? 1 : 0))
      }
    }

    // player models owned / forced
    if (Array.isArray(p.models)) {
      stmts.push(env.DB.prepare(`DELETE FROM player_models WHERE steamid = ?1`).bind(p.steamid))
      for (const m of p.models) {
        if (!m || typeof m.model !== "string" || !/^[a-z0-9_]{1,32}$/.test(m.model)) continue
        stmts.push(env.DB.prepare(
          `INSERT INTO player_models (steamid, model, equipped, forced) VALUES (?1,?2,?3,?4)
           ON CONFLICT(steamid, model) DO UPDATE SET equipped=?3, forced=?4`)
          .bind(p.steamid, m.model, m.equipped ? 1 : 0, m.forced ? 1 : 0))
      }
    }

    const achPatch = []
    const achVals = []
    for (const col of ["ach_unlocked", "ach_kills", "ach_hs", "ach_plants", "ach_defuses", "ach_wins", "ach_revives", "ach_streak", "rerolls_left", "msn_st_d", "msn_st_b", "msn_st_w", "msn_st_v", "msn_vip_p"]) {
      if (p[col] == null || p[col] === "") continue
      achPatch.push(`${col}=?${achPatch.length + 2}`)
      achVals.push(num(p[col]))
    }
    if (p.msn_tg != null && p.msn_tg !== "") {
      achPatch.push(`msn_tg=?${achPatch.length + 2}`)
      achVals.push(str(p.msn_tg, 96))
    }
    if (achPatch.length) {
      stmts.push(env.DB.prepare(
        `UPDATE players SET ${achPatch.join(", ")} WHERE steamid = ?1`
      ).bind(p.steamid, ...achVals))
    }

    if (Array.isArray(p.maps)) {
      for (const m of p.maps) {
        if (!m || typeof m.map !== "string" || !/^[a-z0-9_]{1,32}$/i.test(m.map)) continue
        stmts.push(env.DB.prepare(
          `INSERT INTO player_maps (steamid, map_name, matches, wins, losses, kills, deaths, assists, headshots, damage, last_played)
           VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)
           ON CONFLICT(steamid, map_name) DO UPDATE SET
             matches=?3, wins=?4, losses=?5, kills=?6, deaths=?7, assists=?8, headshots=?9, damage=?10, last_played=?11`)
          .bind(p.steamid, m.map, num(m.matches), num(m.wins), num(m.losses),
            num(m.kills), num(m.deaths), num(m.assists), num(m.hs || m.headshots), num(m.damage), num(m.last_played)))
      }
    }

    // Derived earned dates: newly-set ach_unlocked bits get first-seen nowSec.
    // DO NOTHING keeps the original date on re-pushes (no fake refreshes).
    if (p.ach_unlocked != null) {
      const prev = prevUnlocked.get(p.steamid) || 0
      const cur = num(p.ach_unlocked) | 0
      const flipped = (cur & ~prev) | 0
      if (flipped) {
        for (const [bit, meta] of Object.entries(ACH_BIT_META)) {
          if (flipped & (1 << Number(bit))) {
            const [code, ap] = meta
            stmts.push(env.DB.prepare(
              `INSERT INTO ap_unlocks (steamid, code, ap, earned_at)
               VALUES (?1,?2,?3,?4)
               ON CONFLICT(steamid, code) DO NOTHING`)
              .bind(p.steamid, code, ap, nowSec))
          }
        }
      }
    }

    if (Array.isArray(p.ap_unlocks)) {
      for (const u of p.ap_unlocks) {
        if (!u || typeof u.code !== "string" || !/^[a-z0-9_]{1,32}$/i.test(u.code)) continue
        stmts.push(env.DB.prepare(
          `INSERT INTO ap_unlocks (steamid, code, ap, earned_at)
           VALUES (?1,?2,?3,?4)
           ON CONFLICT(steamid, code) DO UPDATE SET ap=?3, earned_at=?4`)
          .bind(p.steamid, u.code, num(u.ap), num(u.earned_at)))
      }
    }

    // skill stages (authoritative snapshot: skills{<id>: <stage>} as sent by
    // freenova_sync.sma). Full replace per player, same contract as skins:
    // the panel shows the owned stage on the store/battlepass pages instead
    // of pretending nothing is owned. Stage 0 = not owned, kept as truth.
    if (p.skills && typeof p.skills === "object") {
      stmts.push(env.DB.prepare(`DELETE FROM player_skills WHERE steamid = ?1`).bind(p.steamid))
      for (const [skill, stage] of Object.entries(p.skills)) {
        if (!/^[a-z0-9_]{1,24}$/.test(skill)) continue
        const n = Math.trunc(Number(stage))
        if (!Number.isFinite(n) || n < 0 || n > 9) continue
        stmts.push(env.DB.prepare(
          `INSERT INTO player_skills (steamid, skill, stage) VALUES (?1,?2,?3)
           ON CONFLICT(steamid, skill) DO UPDATE SET stage=?3`)
          .bind(p.steamid, skill, n))
      }
    }
  }

  // season history rows (pushed once per player per season)
  if (Array.isArray(payload.season_history)) {
    for (const h of payload.season_history) {
      if (!h || !validSteamid(h.steamid) || !/^\d{4}-\d{2}$/.test(h.season || "")) continue
      stmts.push(env.DB.prepare(
        `INSERT INTO comp_history (steamid, season, points, kills, hs, wins, mvp)
         VALUES (?1,?2,?3,?4,?5,?6,?7)
         ON CONFLICT(steamid, season) DO UPDATE SET
           points=?3, kills=?4, hs=?5, wins=?6, mvp=?7`)
        .bind(h.steamid, h.season, num(h.points), num(h.kills), num(h.hs), num(h.wins), num(h.mvp)))
    }
  }

  // catalogs (skins/models/cosmetics/reward_track definitions from the game)
  if (payload.catalogs && typeof payload.catalogs === "object") {
    for (const [key, cat] of Object.entries(payload.catalogs)) {
      if (!/^[a-z_]{1,24}$/.test(key)) continue
      const version = num(cat && cat.version)
      stmts.push(env.DB.prepare(
        `INSERT INTO catalog (key, version, json, updated_at) VALUES (?1,?2,?3,?4)
         ON CONFLICT(key) DO UPDATE SET version=?2, json=?3, updated_at=?4
         WHERE excluded.version >= catalog.version`)
        .bind(key, version, JSON.stringify(cat), nowSec))
    }
  }

  // results of previously dispatched actions
  if (Array.isArray(payload.action_results)) {
    for (const r of payload.action_results) {
      if (!r || !Number.isInteger(r.id)) continue
      const status = r.ok ? "done" : "failed"
      stmts.push(env.DB.prepare(
        `UPDATE actions SET status=?2, result=?3, closed_at=?4 WHERE id=?1 AND status='sent'`)
        .bind(r.id, status, str(r.result, 120), nowSec))
    }
  }

  // Game-finalized settlement receipts (event_results[]). The GAME already
  // paid winners through its own coins/VIP APIs before reporting; the panel
  // records the receipt, converges the event row, and audits — it must
  // NEVER queue srv_event_reward intents here (double-pay guard). Idempotent:
  // event_winners is INSERT OR IGNORE on (event_id, placement), so a re-sent
  // report converges instead of duplicating.
  if (Array.isArray(payload.event_results)) {
    for (const r of payload.event_results) {
      if (!r || !Number.isInteger(r.event_id) || r.event_id <= 0) continue
      const finalizedAt = Number.isInteger(r.finalized_at) && r.finalized_at > 0 ? r.finalized_at : nowSec
      let ev = null
      try {
        ev = await env.DB.prepare(
          `SELECT id, title, type, xp_mult, coins_mult, start_at, end_at FROM events WHERE id = ?1`).bind(r.event_id).first()
      } catch {}
      if (!ev) {
        stmts.push(env.DB.prepare(
          `INSERT INTO event_audit (ts, actor, action, entity, meta)
           VALUES (?1, 'game', 'settled-game-unknown', ?2, ?3)`)
          .bind(nowSec, `event:${r.event_id}`, `winners=0 unknown-event`))
        continue
      }
      // Early report: the event window is still open, nothing settles yet.
      if (num(ev.end_at) > nowSec) {
        stmts.push(env.DB.prepare(
          `INSERT INTO event_audit (ts, actor, action, entity, meta)
           VALUES (?1, 'game', 'settled-game-early', ?2, ?3)`)
          .bind(nowSec, `event:${ev.id}`, `winners=0 window-open`))
        continue
      }
      const winners = Array.isArray(r.winners) ? r.winners.slice(0, 8) : []
      let placed = 0, paidN = 0
      for (const w of winners) {
        if (!w || !validSteamid(w.steamid)) continue
        if (!Number.isInteger(w.placement) || w.placement < 1 || w.placement > 64) continue
        if (!Number.isInteger(w.score) || w.score < 0) continue
        placed++
        if (w.paid) paidN++
        stmts.push(env.DB.prepare(
          `INSERT OR IGNORE INTO event_winners (event_id, placement, steamid, score, issued_at)
           VALUES (?1, ?2, ?3, ?4, ?5)`)
          .bind(ev.id, w.placement, w.steamid, w.score, finalizedAt))
      }
      // Converge the event row to completed + history (receipt of a
      // game-side finalize; scheduler skips it because status is no longer
      // 'active', so no srv_event_clear is queued — the game finalized it).
      stmts.push(env.DB.prepare(
        `UPDATE events SET status='completed', error_msg='' WHERE id=?1 AND status IN ('active','scheduled')`)
        .bind(ev.id))
      stmts.push(env.DB.prepare(
        `INSERT INTO event_history (event_id, title, type, xp_mult, coins_mult, start_at, end_at, completed_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
         ON CONFLICT(event_id) DO NOTHING`)
        .bind(ev.id, str(ev.title, 80), str(ev.type, 32),
          Number(ev.xp_mult) || 1, Number(ev.coins_mult) || 1,
          num(ev.start_at), num(ev.end_at), finalizedAt))
      stmts.push(env.DB.prepare(
        `INSERT INTO event_audit (ts, actor, action, entity, meta)
         VALUES (?1, 'game', 'settled-game', ?2, ?3)`)
        .bind(nowSec, `event:${ev.id}`, `winners=${placed} paid=${paidN} finalized_at=${finalizedAt}`))
    }
  }

  const extraCols = [
    ["bp_hp", "INTEGER NOT NULL DEFAULT 0"],
    ["bp_armor", "INTEGER NOT NULL DEFAULT 0"],
    ["bp_jumps", "INTEGER NOT NULL DEFAULT 0"],
    ["bp_sniper", "INTEGER NOT NULL DEFAULT 0"],
    ["bp_laststand", "INTEGER NOT NULL DEFAULT 0"],
    ["bp_chute", "INTEGER NOT NULL DEFAULT 0"],
    ["bp_premium", "INTEGER NOT NULL DEFAULT 0"],
    ["bp_milestone", "INTEGER NOT NULL DEFAULT 0"],
    ["bp_xp", "INTEGER NOT NULL DEFAULT 0"],
    ["bp_tier", "INTEGER NOT NULL DEFAULT 0"],
    ["bp_season", "TEXT NOT NULL DEFAULT '1'"],
    ["bp_premium_season", "TEXT NOT NULL DEFAULT ''"],
    ["bp_ent_lane", "INTEGER NOT NULL DEFAULT 0"],
    ["bp_ent_order", "TEXT NOT NULL DEFAULT ''"],
    ["bp_ent_at", "INTEGER NOT NULL DEFAULT 0"],
    ["vip_remaining", "INTEGER NOT NULL DEFAULT 0"],
    ["ach_unlocked", "INTEGER"],
    ["ach_kills", "INTEGER"],
    ["ach_hs", "INTEGER"],
    ["ach_plants", "INTEGER"],
    ["ach_defuses", "INTEGER"],
    ["ach_wins", "INTEGER"],
    ["ach_revives", "INTEGER"],
    ["ach_streak", "INTEGER"],
    ["cc", "TEXT NOT NULL DEFAULT ''"]
  ]
  for (const [col, ddl] of extraCols) {
    try {
      await env.DB.prepare(`ALTER TABLE players ADD COLUMN ${col} ${ddl}`).run()
    } catch (e) {
      const msg = String(e && e.message || "").toLowerCase()
      if (!msg.includes("duplicate") && !msg.includes("exists")) {
        console.warn(`[sync] ALTER TABLE players ADD COLUMN ${col} unexpected error:`, e)
      }
    }
  }

  stmts.unshift(
    env.DB.prepare(
      `CREATE TABLE IF NOT EXISTS player_profile (
         steamid TEXT PRIMARY KEY,
         featured TEXT NOT NULL DEFAULT '',
         updated_at INTEGER NOT NULL DEFAULT 0)`),
    env.DB.prepare(
      `CREATE TABLE IF NOT EXISTS player_skills (
         steamid TEXT NOT NULL,
         skill   TEXT NOT NULL,
         stage   INTEGER NOT NULL DEFAULT 0,
         PRIMARY KEY (steamid, skill))`),
    env.DB.prepare(
      `CREATE TABLE IF NOT EXISTS player_maps (
         steamid TEXT NOT NULL,
         map_name TEXT NOT NULL,
         matches INTEGER NOT NULL DEFAULT 0,
         wins INTEGER NOT NULL DEFAULT 0,
         losses INTEGER NOT NULL DEFAULT 0,
         kills INTEGER NOT NULL DEFAULT 0,
         deaths INTEGER NOT NULL DEFAULT 0,
         assists INTEGER NOT NULL DEFAULT 0,
         headshots INTEGER NOT NULL DEFAULT 0,
         damage INTEGER NOT NULL DEFAULT 0,
         last_played INTEGER NOT NULL DEFAULT 0,
         PRIMARY KEY (steamid, map_name))`),
    env.DB.prepare(
      `CREATE TABLE IF NOT EXISTS ap_unlocks (
         steamid TEXT NOT NULL,
         code TEXT NOT NULL,
         ap INTEGER NOT NULL DEFAULT 0,
         earned_at INTEGER NOT NULL DEFAULT 0,
         PRIMARY KEY (steamid, code))`)
  )

  if (stmts.length) await env.DB.batch(stmts)

  await ensureOpsTables(env)
  await writeServerMeta(env, payload.server, nowSec, pushIds.length)
  await tickEventScheduler(env, nowSec)

  // ---- dispatch pending actions to the game (max 8 per push) ----
  // Claim, then advertise only what this request actually won. The UPDATE is the
  // claim and its changed-row count decides ownership: the previous code read a
  // batch of pending rows and then flipped all of them, so two overlapping pushes
  // (the normal case while the game retries after a relay timeout) both returned
  // the same ids and the game applied each action twice - double coins for
  // claim_bp and srv_event_reward.
  // Re-dispatch a 'sent' action once (REVIEW.md §4.2 M5). A row is 'sent' as
  // soon as the panel advertises it, so a push whose reply never reached the
  // game - the relay's 10 s timeout is the normal case - left the row waiting
  // for a result that could not come, and it was expired an hour later even
  // though the game may have applied it: the success was dropped and the
  // panels showed "expired". Handing the same row out a second time is safe
  // because the game-side grants are idempotent (freenova_sync.sma award ids
  // `wact#<action id>`, REVIEW §9b f138da2): a duplicate dispatch ACKs
  // "already applied" instead of paying twice.
  const { results: pending } = await env.DB.prepare(
    `SELECT id, steamid, type, arg, attempts FROM actions
     WHERE (status = 'pending' OR (status = 'sent' AND attempts < ?2))
       AND created_at > ?1
     ORDER BY created_at ASC LIMIT 8`).bind(nowSec - DISPATCH_WINDOW, MAX_DISPATCH_ATTEMPTS).all()
  const dispatched = []
  for (const a of pending) {
    // Compare-and-swap on the attempts counter we just read: that is the claim,
    // so two overlapping pushes cannot both win the same row (the pre-fix bug
    // was reading rows and then flipping them by id alone).
    const claim = await env.DB.prepare(
      `UPDATE actions SET status='sent', attempts=attempts+1
       WHERE id=?1 AND status IN ('pending','sent') AND attempts=?2`)
      .bind(a.id, a.attempts).run()
    // meta.changes is 1 for the winner of the race. A shim that returns no meta
    // keeps the pre-fix behaviour instead of silently dropping every action.
    const won = claim && claim.meta ? Number(claim.meta.changes || 0) : 1
    if (won === 1) dispatched.push(a)
  }
  // Expire what the game never picked up. A 'pending' row that was never
  // advertised is expired after the dispatch window; a 'sent' row is expired
  // only once it has used every dispatch attempt (one dropped reply must not
  // throw away a claim the game already paid), with a hard stop at two windows
  // so a row can never sit in 'sent' for ever.
  await env.DB.prepare(
    `UPDATE actions SET status='expired', closed_at=?1
     WHERE (status = 'pending' AND created_at < ?2)
        OR (status = 'sent' AND created_at < ?2 AND attempts >= ?3)
        OR (status = 'sent' AND created_at < ?4)`)
    .bind(nowSec, nowSec - DISPATCH_WINDOW, MAX_DISPATCH_ATTEMPTS, nowSec - 2 * DISPATCH_WINDOW).run()

  // ---- spec broadcast: active metric events for the game's offline ledger ----
  // Additive response field (freenova_sync.sma EvtIngestSpecs already parses
  // hRoot["events"]). The game can only settle events it has specs for, so
  // this is the upstream of the event_results receipts handled above. Bounded
  // to EVT_MAX_SPECS (8) game-side; entries fail soft, never fail the push.
  let evOut = []
  try {
    const { results: activeEvents } = await env.DB.prepare(
      `SELECT id, metric, target, scope, reward_coins, reward_viptier, reward_vipdays,
              min_score, start_at, end_at
       FROM events WHERE status = 'active' AND metric IS NOT NULL AND metric <> 'none'
       ORDER BY id ASC LIMIT 8`).all()
    evOut = (activeEvents || []).map(e => ({
      id: num(e.id), metric: str(e.metric, 16),
      target: num(e.target),
      scope: str(e.scope, 16) === "global" ? "global" : "individual",
      reward_coins: num(e.reward_coins), reward_viptier: num(e.reward_viptier),
      reward_vipdays: num(e.reward_vipdays), min_score: num(e.min_score),
      start_at: num(e.start_at), end_at: num(e.end_at)
    })).filter(e => e.id > 0 && e.end_at > e.start_at)
  } catch {}

  return json({
    ok: true,
    stored: payload.players.filter(p => validSteamid(p.steamid)).length,
    server_time: nowSec,
    events: evOut,
    actions: dispatched.map(a => ({ id: a.id, steamid: a.steamid, type: a.type, arg: a.arg, attempts: a.attempts }))
  })
}

// Queue a web-originated action. Exported for the store/model pages.
export async function queueAction(env, steamid, type, arg, token) {
  if (!validSteamid(steamid)) return { ok: false, error: "bad steamid" }
  if (!await checkActionToken(env.SYNC_SECRET, steamid, token))
    return { ok: false, error: "invalid or expired session token — reopen the panel from the game" }
  const TYPES = new Set(["buy_skin", "equip_skin", "buy_model", "equip_model", "unequip_model", "set_tag", "unequip_tag", "claim_bp", "buy_skill", "claim_tournament", "claim_mission", "reroll_mission", "claim_mission_all", "claim_event"])
  if (!TYPES.has(type)) return { ok: false, error: "unknown action" }
  if (typeof arg !== "string" || arg.length > 64 || /[\r\n<>&"]/.test(arg))
    return { ok: false, error: "bad argument" }

  // idempotency: one pending action per (player, type, arg)
  const dup = await env.DB.prepare(
    `SELECT id FROM actions WHERE steamid=?1 AND type=?2 AND arg=?3 AND status IN ('pending','sent')`)
    .bind(steamid, type, arg).first()
  if (dup) return { ok: true, queued: dup.id, note: "already queued" }

  const res = await env.DB.prepare(
    `INSERT INTO actions (steamid, type, arg, status, created_at) VALUES (?1,?2,?3,'pending',?4)`)
    .bind(steamid, type, arg, Math.floor(Date.now() / 1000)).run()
  return { ok: true, queued: res.meta && res.meta.last_row_id }
}

// Player-facing status line for a queued action (shown after Purchase/Equip click).
export async function actionStatusLine(env, steamid) {
  const row = await env.DB.prepare(
    `SELECT type, arg, status, result, closed_at, created_at FROM actions
     WHERE steamid=?1 ORDER BY created_at DESC LIMIT 1`).bind(steamid).first()
  if (!row) return ""
  if (row.status === "done") return `<span class='green'>Request processed: ${esc(row.result || "OK")}</span>`
  if (row.status === "failed") return `<span class='err'>Request failed: ${esc(row.result || "rejected by server")}</span>`
  if (row.status === "pending" || row.status === "sent")
    return `<span class='muted'>Request queued &mdash; the game server will process it within ~1 minute.</span>`
  return `<span class='muted'>Last request: ${esc(row.type)} (${esc(row.status)})</span>`
}

export async function saveFeatured(env, steamid, csv, token, ownershipIds) {
  if (!validSteamid(steamid)) return { ok: false, error: "bad steamid" }
  if (!await checkActionToken(env.SYNC_SECRET, steamid, token))
    return { ok: false, error: "invalid or expired session token" }
  const owned = new Set(ownershipIds || [])
  const clean = String(csv || "").split(",").map(s => s.trim()).filter(id => owned.has(id)).slice(0, 5)
  await env.DB.prepare(
    `INSERT INTO player_profile (steamid, featured, updated_at) VALUES (?1,?2,?3)
     ON CONFLICT(steamid) DO UPDATE SET featured=?2, updated_at=?3`)
    .bind(steamid, clean.join(","), Math.floor(Date.now() / 1000)).run()
  return { ok: true, featured: clean }
}

// The clock a players row is ordered by. freenova_sync.sma sends one
// `last_seen` per push (the snapshot time); a body without it - an older plugin
// or a hand-rolled probe - falls back to the panel's arrival time, which is the
// old behaviour. REVIEW.md §4.1 H1: with only the arrival clock the
// `excluded.last_seen >= players.last_seen` guard on the upsert could never
// distinguish a stale snapshot from a new one.
function pushClock(sent, now) {
  const t = Math.trunc(num(sent))
  // Reject nonsense: a zero/missing value means "use arrival time", and a
  // clock more than an hour off the panel's is not trusted to order rows.
  if (!Number.isFinite(t) || t <= 0 || Math.abs(t - now) > 3600) return now
  return t
}

function str(v, max) { return String(v == null ? "" : v).slice(0, max || 64) }
function ccOf(v) { return String(v || "").toLowerCase().replace(/[^a-z]/g, "").slice(0, 2) }

const OPS_STEAM = "STEAM_0:0:0"
const OPS_ARG_BAD = /[\r\n<>&"]/

function metaUpsert(env, key, value) {
  return env.DB.prepare(
    `INSERT INTO meta (key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = ?2`
  ).bind(key, String(value))
}

export async function ensureOpsTables(env) {
  const ddl = [
    `CREATE TABLE IF NOT EXISTS staff (
        steamid     TEXT PRIMARY KEY,
        name        TEXT NOT NULL DEFAULT '',
        pin_hash    TEXT NOT NULL DEFAULT '',
        role        TEXT NOT NULL DEFAULT 'admin',
        enabled     INTEGER NOT NULL DEFAULT 1,
        created_at  INTEGER NOT NULL DEFAULT 0,
        last_login  INTEGER NOT NULL DEFAULT 0)`,
    `CREATE INDEX IF NOT EXISTS idx_staff_steamid ON staff (steamid)`,
    `CREATE TABLE IF NOT EXISTS admin_sessions (
        token       TEXT PRIMARY KEY,
        steamid     TEXT NOT NULL,
        created_at  INTEGER NOT NULL DEFAULT 0,
        expires_at  INTEGER NOT NULL DEFAULT 0)`,
    `CREATE TABLE IF NOT EXISTS admin_audit (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        steamid     TEXT NOT NULL DEFAULT '',
        action      TEXT NOT NULL DEFAULT '',
        detail      TEXT NOT NULL DEFAULT '',
        created_at  INTEGER NOT NULL DEFAULT 0)`,
    `CREATE INDEX IF NOT EXISTS idx_admin_audit_created ON admin_audit (created_at DESC)`,
    `CREATE TABLE IF NOT EXISTS events (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        title           TEXT NOT NULL DEFAULT '',
        type            TEXT NOT NULL DEFAULT 'event',
        status          TEXT NOT NULL DEFAULT 'scheduled',
        start_at        INTEGER NOT NULL DEFAULT 0,
        end_at          INTEGER NOT NULL DEFAULT 0,
        xp_mult         REAL NOT NULL DEFAULT 1,
        coins_mult      REAL NOT NULL DEFAULT 1,
        conflict_group  TEXT NOT NULL DEFAULT '',
        error_msg       TEXT NOT NULL DEFAULT '',
        created_by      TEXT NOT NULL DEFAULT '',
        created_at      INTEGER NOT NULL DEFAULT 0,
        metric          TEXT DEFAULT 'none',
        target          INTEGER DEFAULT 0,
        scope           TEXT DEFAULT 'global',
        reward          TEXT DEFAULT '')`,
    `CREATE INDEX IF NOT EXISTS idx_events_status_start ON events (status, start_at)`,
    `CREATE TABLE IF NOT EXISTS event_history (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        event_id        INTEGER NOT NULL UNIQUE,
        title           TEXT NOT NULL DEFAULT '',
        type            TEXT NOT NULL DEFAULT '',
        xp_mult         REAL NOT NULL DEFAULT 1,
        coins_mult      REAL NOT NULL DEFAULT 1,
        start_at        INTEGER NOT NULL DEFAULT 0,
        end_at          INTEGER NOT NULL DEFAULT 0,
        completed_at    INTEGER NOT NULL DEFAULT 0)`,
    // Game-settlement receipts (event_results[] ingest in handleSync). Matches
    // schema.sql; kept here so an older deployed DB converges without a manual
    // migration. INSERT OR IGNORE on (event_id, placement) = convergence.
    `CREATE TABLE IF NOT EXISTS event_winners (
        event_id        INTEGER NOT NULL,
        placement       INTEGER NOT NULL,
        steamid         TEXT NOT NULL,
        score           INTEGER NOT NULL DEFAULT 0,
        reward_coins    INTEGER NOT NULL DEFAULT 0,
        reward_viptier  INTEGER NOT NULL DEFAULT 0,
        reward_vipdays  INTEGER NOT NULL DEFAULT 0,
        issued_at       INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (event_id, placement))`,
    `CREATE INDEX IF NOT EXISTS idx_winners_event ON event_winners (event_id)`,
    // Event baselines (2026-10-10): snapshot of player counters at event
    // activation, so individual-scope scoring counts only progress made while
    // the event was live. Same convergence posture as the other tables here.
    `CREATE TABLE IF NOT EXISTS event_baselines (
        event_id        INTEGER NOT NULL,
        steamid         TEXT NOT NULL,
        metric          TEXT NOT NULL,
        baseline        INTEGER NOT NULL DEFAULT 0,
        taken_at        INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (event_id, steamid, metric))`,
    `CREATE TABLE IF NOT EXISTS event_audit (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        ts              INTEGER NOT NULL DEFAULT 0,
        actor           TEXT NOT NULL DEFAULT '',
        action          TEXT NOT NULL DEFAULT '',
        entity          TEXT NOT NULL DEFAULT '',
        meta            TEXT NOT NULL DEFAULT '')`
  ]
  await env.DB.batch(ddl.map(sql => env.DB.prepare(sql)))
  for (const sql of [
    `ALTER TABLE players ADD COLUMN rerolls_left INTEGER`,
    `ALTER TABLE players ADD COLUMN msn_st_d INTEGER`,
    `ALTER TABLE players ADD COLUMN msn_st_b INTEGER`,
    `ALTER TABLE players ADD COLUMN msn_st_w INTEGER`,
    `ALTER TABLE players ADD COLUMN msn_st_v INTEGER`,
    `ALTER TABLE players ADD COLUMN msn_vip_p INTEGER`,
    `ALTER TABLE players ADD COLUMN msn_tg TEXT`,
    // events data contract (schema.sql has it; a deployed pre-contract DB
    // converges here instead of failing the spec broadcast SELECT).
    `ALTER TABLE events ADD COLUMN metric TEXT DEFAULT 'none'`,
    `ALTER TABLE events ADD COLUMN target INTEGER DEFAULT 0`,
    `ALTER TABLE events ADD COLUMN scope TEXT DEFAULT 'global'`,
    `ALTER TABLE events ADD COLUMN reward TEXT DEFAULT ''`,
    `ALTER TABLE events ADD COLUMN reward_coins INTEGER DEFAULT 0`,
    `ALTER TABLE events ADD COLUMN reward_viptier INTEGER DEFAULT 0`,
    `ALTER TABLE events ADD COLUMN reward_vipdays INTEGER DEFAULT 0`,
    `ALTER TABLE events ADD COLUMN min_score INTEGER DEFAULT 0`
  ]) {
    try { await env.DB.prepare(sql).run() } catch {}
  }
}

async function writeServerMeta(env, server, nowSec, counted) {
  const rows = [metaUpsert(env, "last_push", nowSec), metaUpsert(env, "server_online", "1")]
  // How many rows this snapshot stamped (page-driven, docs/panel/01-DATA.md §11):
  // the panel's "Players on server" cell and nothing else reads it, and it can
  // never claim more than the push actually carried.
  if (Number.isFinite(counted)) rows.push(metaUpsert(env, "server_counted", counted))
  if (server && typeof server === "object") {
    const hh = Number(server.hh)
    rows.push(
      metaUpsert(env, "server_map", str(server.map, 48)),
      metaUpsert(env, "server_hostname", str(server.hostname, 64)),
      metaUpsert(env, "server_players", num(server.players)),
      metaUpsert(env, "server_humans", num(server.humans)),
      metaUpsert(env, "server_maxplayers", num(server.maxplayers)),
      metaUpsert(env, "server_uptime", num(server.uptime)),
      metaUpsert(env, "server_round", num(server.round)),
      metaUpsert(env, "happy_hour", Number.isFinite(hh) && hh > 1 ? "1" : "0"),
      // xp/coins multipliers are floats (sync.sma:547 sends %.2f). num() is
      // parseInt, which turned a 1.5x event into 1x on the admin pages.
      metaUpsert(env, "event_xp",    multNum(server.event_xp)),
      metaUpsert(env, "event_coins", multNum(server.event_coins))
    )
  }
  await env.DB.batch(rows)
}

function validOpsArg(arg) {
  return typeof arg === "string" && arg.length > 0 && arg.length <= 64 && !OPS_ARG_BAD.test(arg)
}

// Reward arg grammar (game ParseColonParts splits exactly 4 pieces):
// `eventid:coins:viptier:vipdays`, winner rides the action steamid column.
// SteamIDs contain colons and must NEVER appear inside the arg.
async function queueOpsAction(env, type, arg, nowSec, owner) {
  if (type !== "srv_event_apply" && type !== "srv_event_clear" && type !== "srv_event_reward") return
  const who = owner || OPS_STEAM
  if (!validOpsArg(arg)) return
  const dup = await env.DB.prepare(
    `SELECT id FROM actions WHERE steamid=?1 AND type=?2 AND arg=?3 AND status IN ('pending','sent')`
  ).bind(who, type, arg).first()
  if (dup) return
  await env.DB.prepare(
    `INSERT INTO actions (steamid, type, arg, status, created_at) VALUES (?1,?2,?3,'pending',?4)`
  ).bind(who, type, arg, nowSec).run()
}

// xp_mult/coins_mult are REAL (1.0-5.0, 0.5 steps) but num() is parseInt and
// would turn 1.5 into 1 in the game arg and in event_history. These keep the
// arg shape (`id:xp:coins:kind`) and integer rendering ("2") byte-identical
// while passing half-step fractions through to the game (it parses floats).
function multStr(v) { const n = Number(v); return Number.isFinite(n) ? String(n) : "0" }
function multNum(v) { const n = Number(v); return Number.isFinite(n) ? n : 0 }

function applyArg(ev) {
  const kind = String(ev.type || "event").replace(/[\r\n<>&":]/g, "").slice(0, 24) || "event"
  const arg = `${num(ev.id)}:${multStr(ev.xp_mult)}:${multStr(ev.coins_mult)}:${kind}`
  return arg.length <= 64 ? arg : arg.slice(0, 64)
}

// ---------- events settlement: baselines, standings, winners, rewards ----------
// Lifetime value for an event metric from a players row. c4 uses achievement
// lifetime counters (ach_plants/ach_defuses), never resetting daily columns.
function eventLifetime(row, metric) {
  switch (String(metric || "")) {
    case "kills": return num(row.kills)
    case "headshots": return num(row.headshots)
    case "wins": return num(row.wins)
    case "mvps": return num(row.mvps)
    case "xp": return num(row.xp)
    case "c4": return num(row.ach_plants) + num(row.ach_defuses)
    default: return null
  }
}
const BASELINE_EXPR = {
  kills: "kills", headshots: "headshots", wins: "wins", mvps: "mvps", xp: "xp",
  c4: "(IFNULL(ach_plants,0)+IFNULL(ach_defuses,0))"
}
async function gameAudit(env, action, entity) {
  try {
    await env.DB.prepare(
      `INSERT INTO event_audit (ts, actor, action, entity, meta) VALUES (?1,'sync',?2,?3,'')`
    ).bind(Math.floor(Date.now() / 1000), String(action).slice(0, 32), String(entity).slice(0, 64)).run()
  } catch {}
}
async function eventAudit(env, action, entity, meta, nowSec) {
  try {
    await env.DB.prepare(
      `INSERT INTO event_audit (ts, actor, action, entity, meta) VALUES (?1,'scheduler',?2,?3,?4)`
    ).bind(nowSec, String(action).slice(0, 32), String(entity).slice(0, 64), String(meta || "").slice(0, 200)).run()
  } catch {}
}
// Ensure window baselines for an active metric event (late joiners included).
// INSERT OR IGNORE: never overwrite, never credit pre-event activity.
async function ensureBaselines(env, ev, nowSec) {
  const expr = BASELINE_EXPR[String(ev.metric || "")]
  if (!expr) return
  try {
    await env.DB.prepare(
      `INSERT OR IGNORE INTO event_baselines (event_id, steamid, metric, baseline, taken_at)
       SELECT ?1, steamid, ?2, ${expr}, ?3 FROM players`
    ).bind(num(ev.id), String(ev.metric), nowSec).run()
  } catch {}
}
// Finalize one ended metric event: standings -> winners -> reward intents.
// Idempotent: winners INSERT OR IGNORE; reward queue dedups on pending/sent.
async function settleEvent(env, ev, nowSec) {
  const metric = String(ev.metric || "")
  if (!metric || metric === "none") {
    await eventAudit(env, "settled-mult-only", `event:${ev.id}`, ev.title, nowSec)
    return
  }
  const late = nowSec - num(ev.end_at) > 3600
  let pros = []
  try {
    pros = ((await env.DB.prepare(`SELECT * FROM players`).all()).results) || []
  } catch { pros = [] }
  let resets = 0, missing = 0
  const scored = []
  for (const p of pros) {
    let base = null
    try {
      const b = await env.DB.prepare(
        `SELECT baseline FROM event_baselines WHERE event_id=?1 AND steamid=?2 AND metric=?3`
      ).bind(ev.id, p.steamid, metric).first()
      base = b ? num(b.baseline) : null
    } catch { base = null }
    if (base == null) { missing++; continue }
    let cur = eventLifetime(p, metric)
    if (cur == null) continue
    if (cur < base) {
      // Counter reset/restart/overflow: re-baseline, never go negative.
      try {
        await env.DB.prepare(
          `UPDATE event_baselines SET baseline=?1, taken_at=?2 WHERE event_id=?3 AND steamid=?4 AND metric=?5`
        ).bind(cur, nowSec, ev.id, p.steamid, metric).run()
      } catch {}
      resets++
      continue
    }
    const progress = cur - base
    const floor = Math.max(1, num(ev.min_score))
    if (progress >= floor) scored.push({ steamid: p.steamid, name: p.name, progress })
  }
  scored.sort((a, b) => b.progress - a.progress || (a.steamid < b.steamid ? -1 : 1))
  const scope = String(ev.scope || "individual")
  const paid = scope === "global" ? scored : scored.slice(0, 3)
  const coins = Math.max(0, Math.min(50000, num(ev.reward_coins)))
  const vtier = Math.max(0, Math.min(3, num(ev.reward_viptier)))
  const vdays = Math.max(0, Math.min(365, num(ev.reward_vipdays)))
  let n = 0
  for (let i = 0; i < paid.length; i++) {
    const w = paid[i]
    const placement = i + 1
    const pay = (scope === "global" || placement === 1) && (coins > 0 || (vtier > 0 && vdays > 0))
    try {
      await env.DB.prepare(
        `INSERT OR IGNORE INTO event_winners (event_id, placement, steamid, score, reward_coins, reward_viptier, reward_vipdays, issued_at)
         VALUES (?1,?2,?3,?4,?5,?6,?7,?8)`
      ).bind(ev.id, placement, w.steamid, w.progress,
        pay ? coins : 0, pay ? vtier : 0, pay ? vdays : 0, nowSec).run()
    } catch {}
    if (pay) {
      await queueOpsAction(env, "srv_event_reward",
        `${num(ev.id)}:${coins}:${vtier}:${vdays}`, nowSec, w.steamid)
      n++
    }
  }
  await eventAudit(env, "settled", `event:${ev.id}`,
    `winners=${paid.length} paid=${n} missing=${missing} resets=${resets}${late ? " LATE" : ""}`, nowSec)
}

async function tickEventScheduler(env, nowSec) {
  // Complete expired actives first so a following scheduled row can take the group.
  const { results: ending } = await env.DB.prepare(
    `SELECT id, title, type, xp_mult, coins_mult, start_at, end_at, metric, target, scope, reward, reward_coins, reward_viptier, reward_vipdays, min_score
     FROM events WHERE status = 'active' AND end_at <= ?1`
  ).bind(nowSec).all()
  // Stale-scheduled rows whose window passed without activation: complete
  // without winners (no baselines exist, so nobody can be credited).
  try {
    const stale = ((await env.DB.prepare(
      `SELECT id, title FROM events WHERE status = 'scheduled' AND end_at <= ?1`
    ).bind(nowSec).all()).results) || []
    for (const st of stale) {
      await env.DB.prepare(`UPDATE events SET status='completed' WHERE id=?1 AND status='scheduled'`).bind(st.id).run()
      await eventAudit(env, "never-activated", `event:${st.id}`, st.title, nowSec)
    }
  } catch {}
  for (const ev of ending || []) {
    await settleEvent(env, ev, nowSec)
    await env.DB.prepare(`UPDATE events SET status='completed' WHERE id=?1 AND status='active'`).bind(ev.id).run()
    await env.DB.prepare(
      `INSERT INTO event_history (event_id, title, type, xp_mult, coins_mult, start_at, end_at, completed_at)
       VALUES (?1,?2,?3,?4,?5,?6,?7,?8)
       ON CONFLICT(event_id) DO NOTHING`
    ).bind(ev.id, str(ev.title, 80), str(ev.type, 32), multNum(ev.xp_mult), multNum(ev.coins_mult),
      num(ev.start_at), num(ev.end_at), nowSec).run()
    await queueOpsAction(env, "srv_event_clear", String(ev.id), nowSec)
  }

  // srv_event_clear zeros all game multipliers. Re-apply any event that is
  // still active so a finished XP event cannot wipe a live coins event.
  if ((ending || []).length) {
    const { results: still } = await env.DB.prepare(
      `SELECT id, type, xp_mult, coins_mult FROM events WHERE status = 'active'`
    ).all()
    for (const ev of still || [])
      await queueOpsAction(env, "srv_event_apply", applyArg(ev), nowSec)
  }

  const { results: activeRows } = await env.DB.prepare(
    `SELECT id, conflict_group FROM events WHERE status = 'active'`
  ).all()
  const activeByGroup = new Map()
  for (const a of activeRows || []) {
    const g = String(a.conflict_group || "")
    if (g && !activeByGroup.has(g)) activeByGroup.set(g, a.id)
  }

  const { results: due } = await env.DB.prepare(
    `SELECT id, type, xp_mult, coins_mult, conflict_group, metric
     FROM events WHERE status = 'scheduled' AND start_at <= ?1 AND end_at > ?1
     ORDER BY start_at ASC, id ASC`
  ).bind(nowSec).all()
  // Late joiners: top up baselines for every active metric event each tick.
  try {
    const act = ((await env.DB.prepare(
      `SELECT id, metric FROM events WHERE status = 'active'`
    ).all()).results) || []
    for (const a of act) await ensureBaselines(env, a, nowSec)
  } catch {}
  for (const ev of due || []) {
    const g = String(ev.conflict_group || "")
    if (g && activeByGroup.has(g)) {
      const other = activeByGroup.get(g)
      await env.DB.prepare(
        `UPDATE events SET status='error', error_msg=?2 WHERE id=?1 AND status='scheduled'`
      ).bind(ev.id, `conflict with active event ${other}`).run()
      continue
    }
    await env.DB.prepare(
      `UPDATE events SET status='active', error_msg='' WHERE id=?1 AND status='scheduled'`
    ).bind(ev.id).run()
    await ensureBaselines(env, ev, nowSec)
    if (g) activeByGroup.set(g, ev.id)
    await queueOpsAction(env, "srv_event_apply", applyArg(ev), nowSec)
  }
}
