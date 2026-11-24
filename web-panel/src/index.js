// FreeNova Web Panel — Cloudflare Worker (D1-backed, server-rendered).
//
// Two authorities, and the split matters (docs/panel/00-CONTRACT.md):
//   * the GAME pushes signed snapshots (POST /api/v1/server/stats, "the ingest");
//     that is still the truth for rank XP/level and, until the ingest stops writing
//     it, for coins;
//   * the WINTERFEST PANEL owns its own state — coins it pays, gingerbread, spins,
//     pass XP/tier, the tree, inventory, entitlements and the ledger — and the game
//     reconciles to it. A page queues an action, src/state.js applies it, and the
//     game pulls the committed change from GET /api/game/pending and reports back
//     with POST /api/game/ack.
// Pages remain read-only over src/query.js; no page writes a state table.
import { handleSync, handleAdminCall, queueAction } from "./sync.js"
import { pendingActions, ackAction, validSteamid } from "./state.js"
import { handleRegister, handleRegHealth } from "./register.js"
import { handleAdmin } from "./admin.js"
import { pageProfile } from "./profile.js"
import { pageBattlePass } from "./battlepass.js"
import { pageMissions } from "./missions.js"
import { pageCompetitive } from "./competitive.js"
import { pageVip } from "./vip.js"
import { pageEvents } from "./events.js"
import { pageAchievements } from "./achievements.js"
import { pageTop15 as pageTop15Legacy } from "./top15/page.js"
import { pageStatsViewer } from "./top15/viewer.js"
import { pageMapEnd } from "./top15/mapend.js"
import { pageIcons } from "./icons.js"
import { page404, html, errorState, setMotdCompact } from "./ui.js"
import { pageHub } from "./hub.js"
import { pageGameSurface, pageSettings, pageRules } from "./gamepages.js"
import { handlePublicApi } from "./publicapi.js"
import { pageMotdV2 } from "./motd.js"
import { pageBoards } from "./boards_page.js"
import { pageDashboard } from "./panel/dashboard.js"
import { pageProfile as pageProfilePanel } from "./panel/profile.js"
import { pageRankstats } from "./panel/rankstats.js"
import { pageTop15 } from "./panel/top15.js"
import { pageShop } from "./panel/shop.js"
import { pageSpin } from "./panel/spin.js"
import { pageBattlepass, handleBattlepassPost } from "./panel/battlepass.js"
import { pageAdvent, handleAdventClaim } from "./panel/advent_page.js"
import { pageLevels } from "./panel/levels_page.js"
import { pageAdminPanel } from "./panel/admin_page.js"

export default {
  async fetch(request, env, ctx) {
    // One place adds the policy for pages that carry a token in their query
    // string (REVIEW.md §4.2 M3): a ?t= / ?k= / ?claim= URL must not leak
    // through Referer to flagcdn.com, Discord or any other third party.
    return withSafeReferrer(request, await routeRequest(request, env, ctx))
  }
}

function withSafeReferrer(request, res) {
  try {
    const url = new URL(request.url)
    const carries = TOKEN_QUERY.some(p => url.searchParams.has(p))
    if (!carries || !res || !res.headers || res.headers.has("referrer-policy")) return res
    const headers = new Headers(res.headers)
    headers.set("referrer-policy", "no-referrer")
    return new Response(res.body, { status: res.status, statusText: res.statusText, headers })
  } catch { return res }
}

const TOKEN_QUERY = ["t", "k", "claim", "act"]

async function routeRequest(request, env, ctx) {
    const url = new URL(request.url)
    const path = url.pathname.replace(/\/+$/, "") || "/"

    try {
      // Admin Control Center is session-auth, not game HMAC. Must run before
      // the GET-only gate so staff POSTs are not 405'd. Do not put this on
      // verifyGamePost and do not add an MOTD short-code for /admin.
      if (path === "/admin" || path.startsWith("/admin/"))
        return await handleAdmin(request, env)

      if (request.method === "POST" && path === "/api/v1/server/stats")
        return await handleSync(request, env)
      // ^ THE INGEST. Unchanged on purpose. One thing to know before editing it:
      //   its players upsert still writes `coins` (and rank xp/level) straight from
      //   the game snapshot, and the Winterfest panel now pays coins through the
      //   ledger (src/state.js). The two do not fight — the snapshot simply wins at
      //   the next push — but the overlap is deliberate and documented in
      //   docs/panel/01-DATA.md ("what the panel owns vs what the ingest still
      //   overwrites"). Do NOT start writing winter_players, winter_inventory,
      //   winter_entitlements or winter_ledger from the ingest: src/state.js is the
      //   only writer of panel state, and a second one would break the ledger.
      if (request.method === "POST" && path === "/api/v1/server/admin-call")
        return await handleAdminCall(request, env)
      // Game registration (freenova_registration.sma). POST is HMAC-signed with
      // REG_SECRET (raw-body formula — see src/register.js header); health is
      // unauthenticated and a 2xx there flips the plugin to FORUM_UP.
      if (request.method === "POST" && path === "/api/game/v1/register")
        return await handleRegister(request, env)
      if (request.method === "GET" && path === "/api/game/v1/health")
        return await handleRegHealth(request, env)

      // The Winterfest shop (page 11) is POST-aware: a Buy submits a form back to
      // the same route, so it is dispatched BEFORE the GET-only gate below.
      if (path === "/panel/shop")
        return await pageShop(env, url, request)
      // The Spin Wheel (page 12). POST = one spin, so it is dispatched here too.
      if (path === "/panel/spin")
        return await pageSpin(env, url, request)

      // The Winterfest action pump (contract §Layers). Same SECRET as the ingest,
      // same signature formula with the method word swapped; the POST goes here so
      // it is routed before the GET-only gate below.
      if (request.method === "GET" && path === "/api/game/pending")
        return await handleGamePending(request, env, url)
      if (request.method === "POST" && path === "/api/game/ack")
        return await handleGameAck(request, env)

      // Top-15 theme editor: POST only, so the staff key never rides in a URL
      // (REVIEW.md §4.1 H2). Routed before the GET-only gate for that reason.
      if (request.method === "POST" && (path === "/top15" || path === "/top"))
        return await pageTop15Legacy(env, url, request)

      if (request.method !== "GET")
        return new Response("method not allowed", { status: 405 })

      // Public read-only JSON (docs/PUBLIC-API.md). No session, no secret, no
      // token: additive to every route above and below. Dispatched after the
      // method gate so a POST to it stays a plain 405.
      if (path === "/api/public" || path.startsWith("/api/public/"))
        return await handlePublicApi(request, env, url)

      // GoldSrc MOTD: short path only (HTTP -102 if the URL is too long).
      //   /m/b/0-0-123456.htm   optional tab: /m/a/0-0-123456/hof.htm
      const SHORT = { p: "/profile", b: "/battlepass", t: "/top", i: "/missions", a: "/achievements", v: "/vip", e: "/events", r: "/tournament" }
      const gone = () => {
        const res = page404()
        return new Response(res.body, { status: 404, headers: res.headers })
      }
      const stampMotdSid = (minted) => {
        // Non-enumerable instance field. Callers cannot set this via query string.
        Object.defineProperty(url, "_fnMotdSid", { value: minted, enumerable: false, writable: false, configurable: false })
      }
      let motdPath = path.match(/^\/m\/([pbtisavoer])\/(\d+-\d+-\d+)(?:\/([a-z0-9_-]+))?(?:\.html?)?$/i)
      if (motdPath) {
        const minted = "STEAM_" + motdPath[2].replace(/-/g, ":")
        url.searchParams.set("steamid", minted)
        stampMotdSid(minted)
        const code = motdPath[1].toLowerCase()
        const extra = motdPath[3] ? motdPath[3].toLowerCase() : ""
        if (code === "s" || code === "o")
          return gone()
        // /m/b/*/missions (or daily/weekly/completed) → 302 to Missions product
        if (code === "b" && /^(missions|daily|weekly|completed)$/.test(extra)) {
          const dest = motdPath[2]
            ? `/m/i/${motdPath[2]}/${extra === "missions" ? "daily" : extra}.htm`
            : "/missions"
          return new Response(null, { status: 302, headers: { location: dest } })
        }
        // MOTD v2 (src/motd.js): p / i / e / b / t are the five player-facing
        // pages the game opens. They are one self-contained document each
        // (inline CSS, no script, no images) and carry X-Robots-Tag +
        // Referrer-Policy. The remaining codes keep the legacy rewrite below.
        const V2 = { p: "p", i: "i", e: "e", b: "b", t: "t" }
        if (V2[code]) {
          setMotdCompact(true)
          if (extra) url.searchParams.set("tab", extra)
          return await pageMotdV2(env, url, {
            code: V2[code],
            steamid: minted,
            tab: extra,
            page: /^\d+$/.test(extra) ? Number(extra) : 0
          })
        }
        if (/^\d+$/.test(extra)) url.searchParams.set("from", extra)
        else if (extra) url.searchParams.set("tab", extra)
        // Restored top15 module reads ?steamid= for the own-row highlight;
        // the stamp stays authoritative (steamidOf prefers _fnMotdSid).
        if (minted) url.searchParams.set("steamid", minted)
        url.pathname = SHORT[code] || "/profile"
      } else {
        // Dashes (packed, what /m/ uses) and colons (the documented long form)
        // are both accepted: the authid is re-packed below anyway, so a link
        // written as /u/STEAM_0:0:1 used to 404 while /u/STEAM_0-0-1 worked.
        motdPath = path.match(/^\/u\/(STEAM_[0-9][-:][0-9][-:]\d+)(?:\/([a-z0-9_-]+))?(?:\/k\/([a-fA-F0-9]{16,64}))?$/i)
        if (motdPath) {
          const minted = "STEAM_" + motdPath[1].slice(6).replace(/-/g, ":")
          url.searchParams.set("steamid", minted)
          stampMotdSid(minted)
          if (motdPath[3]) url.searchParams.set("t", motdPath[3].toLowerCase())
          const slug = (motdPath[2] || "profile").toLowerCase()
          if (/^(store|shop|skins|cosmetics|models)$/.test(slug))
            return gone()
          const pages = {
            profile: "/profile", battlepass: "/battlepass", bp: "/battlepass", pass: "/battlepass",
            missions: "/missions", top: "/top", tournament: "/tournament",
            achievements: "/achievements", events: "/events", vip: "/vip"
          }
          url.pathname = pages[slug] || "/profile"
        }
      }

      // The LIVE Winterfest dashboard (docs/panel/03-DASHBOARD.md). A route of
      // its own, never /dashboard: that URL belongs to the approved plate
      // document the game is sent. It is answered BEFORE the /panel alias table
      // below (which is what the in-game /panel command opens), so /panel/dashboard
      // is this page and every other /panel path keeps its alias.
      // The Winterfest pages that paint the owner's plate whole
      // (docs/design/PAGE-KIT.md): one route each, answered before the /panel
      // alias table so the alias can never shadow them.
      if (path === "/panel/advent")
        return await pageAdvent(env, url)
      if (request.method === "POST" && path === "/panel/advent/claim")
        return await handleAdventClaim(request, env)
      if (path === "/panel/levels")
        return await pageLevels(env, url)
      if (path === "/panel/admin")
        return await pageAdminPanel(request, env, url)
      if (path === "/panel/dashboard")
        return await pageDashboard(env, url)
      // /panel is the Winterfest UI's own front door: page 1, the dashboard.
      // (It used to alias to the plain profile view; the dashboard is the shell
      // contract's page and the navigation's Dashboard entry points here too.)
      if (path === "/panel" || path === "/panel/")
        return await pageDashboard(env, url)
      // The rebuilt profile (/panel/profile, docs/design/refs/winterfest/
      // 02-profile.png). Answered before the alias table for the same reason as
      // the dashboard above: /panel/profile is the PLAIN id-lookup view, not this page.
      if (path === "/panel/profile")
        return await pageProfilePanel(env, url)
      // The plate's statistics and ladder pages. Same rule as above: their own
      // routes, answered before the /panel alias table so the alias cannot shadow
      // them (the alias would send both to the plain id-lookup view).
      if (path === "/panel/rankstats")
        return await pageRankstats(env, url)
      if (path === "/panel/top15")
        return await pageTop15(env, url)
      // The Battle Pass plate page (docs/panel/05-BATTLEPASS.md). Its claim is a
      // FORM POST, routed here so it is not 405'd by the GET-only gate below.
      if (path === "/panel/battlepass") {
        if (request.method === "POST") return await handleBattlepassPost(env, url, request)
        return await pageBattlepass(env, url)
      }
      if (path === "/panel" || path.startsWith("/panel/")) {
        const rest = path.replace(/^\/panel\/?/, "")
        const alias = {
          "": "/profile",
          profile: "/profile",
          top: "/top",
          battlepass: "/battlepass",
          bp: "/battlepass",
          missions: "/missions",
          achievements: "/achievements",
          tournament: "/tournament",
          vip: "/vip",
          events: "/events"
        }
        // An unknown /panel/<page> is a 404. Falling back to the profile page made
        // every unbuilt route look finished with a 200 (user rule, 2026-11-24).
        if (!(rest in alias))
          return new Response("not found", { status: 404, headers: { "content-type": "text/plain" } })
        url.pathname = alias[rest]
      }

      const route = (url.pathname.replace(/\/+$/, "") || "/")

      // CS 1.6 MOTD is MSIE 6 / Mozilla/4. It cannot use var()/flex/Google Fonts.
      const ua = request.headers.get("user-agent") || ""
      const compactQ = url.searchParams.get("compact") === "1"
      // Short /m/ + /u/ rewrites are pure URL shortening — the compact skin is
      // chosen by the rendering engine, not by the path. Legacy GoldSrc MOTD
      // (MSIE/Trident/Mozilla/4.0) or an explicit ?compact=1 get the compact
      // skin; modern in-game browsers hitting the same short URLs get the full
      // preview UI.
      const looksLikeMotd = compactQ || /MSIE|Trident|Mozilla\/4\.0/i.test(ua)
      setMotdCompact(looksLikeMotd)
      if (looksLikeMotd && url.searchParams.get("compact") !== "1")
        url.searchParams.set("compact", "1")

      // /assets/* - the live Winterfest page's own font
      // (/assets/fonts/Nunito-Variable.ttf). The asset binding is rooted at
      // ./assets, so the prefix is stripped for the lookup; a miss falls through
      // to the routes below and ends as a 404. Nothing else is served this way.
      if (env.ASSETS && path.startsWith("/assets/")) {
        const assetUrl = new URL(request.url)
        assetUrl.pathname = path.slice("/assets".length) || "/"
        const res = await env.ASSETS.fetch(new Request(assetUrl, { method: "GET", headers: request.headers }))
        if (res && res.status !== 404) {
          // A font must be announced as a font, whatever the runner guesses
          // (server_local says application/octet-stream; cf. font/ttf).
          const headers = new Headers(res.headers)
          if (path.startsWith("/assets/fonts/")) headers.set("content-type", "font/ttf")
          headers.set("cache-control", "public, max-age=86400")
          return new Response(res.body, { status: 200, headers })
        }
      }
      // Rank emblems, processed medals, badges, /i icons from ./assets
      if (env.ASSETS && (path === "/logo.png" || path.startsWith("/ranks/") || path.startsWith("/badges/") || path.startsWith("/medals/") || path.startsWith("/i/") || path.startsWith("/missions/") || path.startsWith("/bp/") || path.startsWith("/plates/") || path === "/dashboard.png")) {
        const res = await env.ASSETS.fetch(request)
        if (res && res.status !== 404) return res
      }

      const view = (url.searchParams.get("view") || url.searchParams.get("tab") || "").toLowerCase()
      if ((route === "/" || route === "/battlepass.php" || route === "/rsu.php") && view) {
        if (view === "store" || view === "shop" || view === "skins" || view === "cosmetics" || view === "models")
          return gone()
        if (view === "top" || view === "top15" || view === "leaderboard" || view === "rankings" || view === "mapend")
          return await pageTop15Legacy(env, url, request)
        if (view === "player" || view === "rankstats" || view === "profile" || view === "statsme" || view === "rank")
          return await pageProfile(env, url)
        if (view === "bp" || view === "battlepass")
          return await pageBattlePass(env, url)
        if (view === "missions")
          return await pageMissions(env, url)
        if (view === "tournament" || view === "ctop" || view === "competitive")
          return await pageCompetitive(env, url)
        if (view === "records" || view === "achievements" || view === "hof" || view === "halloffame")
          return await pageAchievements(env, url)
        if (view === "events")
          return await pageEvents(env, url)
        if (view === "vip")
          return await pageVip(env, url)
      }

      switch (route) {
        case "/":
        case "/hub":
        case "/home":
          return pageHub(env, url)
        case "/top":
        case "/top15":
        case "/leaderboard":
        case "/rankings":
        case "/top/xp":
        case "/top/level":
        case "/top/kills":
        case "/top/kd":
        case "/top/headshots":
        case "/top/mvps":
        case "/top/wins":
        case "/top/playtime":
        case "/top/rating":  return await pageTop15Legacy(env, url, request)
        // Weekly / monthly boards: one boundary implementation with
        // /api/public/top and the MOTD top tabs (src/periods.js + boards.js).
        case "/top/week":    return await pageBoards(env, url, "week")
        case "/top/month":   return await pageBoards(env, url, "month")
        case "/mapend":      return await pageMapEnd(env, url)
        case "/profile":
        case "/rankstats":
        case "/statsme":
        case "/rank":        return await pageProfile(env, url)
        case "/battlepass":
        case "/bp":          return await pageBattlePass(env, url)
        case "/missions":    return await pageMissions(env, url)
        case "/tournament":
        case "/competitive":
        case "/ctop":        return await pageCompetitive(env, url)
        case "/achievements":
        case "/records":
        case "/hof":
        case "/halloffame":  return await pageAchievements(env, url)
        // Read-only web landing pages. Purchases and equipping remain in game.
        case "/store":
        case "/shop":        return await pageGameSurface(env, url, "shop")
        case "/skins":       return await pageGameSurface(env, url, "skins")
        case "/models":      return await pageGameSurface(env, url, "models")
        case "/cosmetics":   return await pageGameSurface(env, url, "cosmetics")
        case "/settings":    return await pageSettings(env, url)
        case "/rules":       return await pageRules(env, url)
        // The Winterfest dashboard MOTD: the owner's plate, no data, no script.
        // The document is the static ./assets/dashboard.html, and that .html URL
        // is the one the game is sent (<base>/dashboard.html - a GoldSrc MOTD
        // needs a file extension, see freenova_web.inc). These cases exist so the
        // same page also answers the extension-free /dashboard a person types in
        // a browser. Both serve the one file, so the two cannot drift apart.
        case "/dashboard":
        case "/winter/dashboard": {
          if (!env.ASSETS) return page404()
          const assetUrl = new URL(request.url)
          assetUrl.pathname = "/dashboard.html"
          assetUrl.search = ""
          const res = await env.ASSETS.fetch(new Request(assetUrl, { method: "GET", headers: request.headers }))
          return (res && res.status !== 404) ? res : page404()
        }
        case "/discord":     return new Response(null, { status: 302, headers: { location: "https://discord.gg/vuGaWjuX" } })
        case "/events":      return await pageEvents(env, url)
        case "/vip":         return await pageVip(env, url)
        case "/statsviewer":
        case "/stats":       return await pageStatsViewer(env, url)
        case "/icons":       return await pageIcons(env, url)
        case "/compare": {
          const sid = url.searchParams.get("steamid") || url.searchParams.get("a") || ""
          const loc = sid ? `/profile?steamid=${encodeURIComponent(sid)}` : "/profile"
          return new Response(null, { status: 302, headers: { location: loc } })
        }
        case "/search":      return await pageTop15Legacy(env, url, request)
        case "/battlepass.php":
        case "/rsu.php":     return await pageTop15Legacy(env, url, request)
        case "/favicon.ico": return new Response(null, { status: 204 })
        default:             return page404()
      }
    } catch (e) {
      // players get a clean unavailable state; the error goes to Worker logs
      console.error("panel error:", e && e.stack ? e.stack : String(e))
      return errorState("ERROR", "home", "the panel (internal error — logged)")
    }
}

// ============================================================================
// The Winterfest action pump: the game's two calls (docs/panel/01-DATA.md).
//
//   GET  /api/game/pending?steamid=  → what this player's panel state has that the
//                                      game has not mirrored yet
//   POST /api/game/ack               → the game's report on one of those rows
//
// Auth is the ingest's: X-FreeNova-Signature over the SAME SYNC_SECRET, with the
// method word as the second field, so one secret and one implementation of the
// formula cover the whole game-facing surface:
//
//   sha256(secret + ":" + METHOD + ":" + path + ":" + ts + ":" + nonce + ":" + hex(sha256(body)))
//
// For a GET the body is empty, so the last field is the constant hash of "":
// e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
//
// The signature covers the PATH, not the query string (the steamid rides in the
// query, like every other panel read). X-FreeNova-Timestamp must be within ±300 s
// of this process's clock. The ack additionally requires a nonce of the usual shape;
// it is not consumed from the `meta` nonce store because the ack is idempotent by
// construction (src/state.js ackAction: the UPDATE is the claim), so a replay can
// only ever return the verdict the first call stored.
// ============================================================================

const GAME_API_MAX_BODY = 64 * 1024

function json(obj, status) {
  return new Response(JSON.stringify(obj), {
    status: status || 200,
    headers: { "content-type": "application/json", "cache-control": "no-store" }
  })
}

async function sha256Hex(text) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text))
  return [...new Uint8Array(digest)].map(b => b.toString(16).padStart(2, "0")).join("")
}

function timingSafeEqual(a, b) {
  if (typeof a !== "string" || typeof b !== "string" || a.length !== b.length) return false
  let diff = 0
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i)
  return diff === 0
}

async function verifyGameRequest(request, env, method) {
  if (!env || !env.SYNC_SECRET)
    return { ok: false, response: json({ ok: false, error: "sync secret not configured" }, 401) }
  const sig = request.headers.get("x-freenova-signature") || ""
  const ts = request.headers.get("x-freenova-timestamp") || ""
  const nonce = request.headers.get("x-freenova-nonce") || ""
  if (!sig) return { ok: false, response: json({ ok: false, error: "missing signature" }, 401) }
  if (!ts) return { ok: false, response: json({ ok: false, error: "missing timestamp" }, 401) }
  if (!nonce || nonce.length > 64 || /[^\w.-]/.test(nonce))
    return { ok: false, response: json({ ok: false, error: "bad nonce" }, 401) }

  const now = Math.floor(Date.now() / 1000)
  const tsNum = parseInt(ts, 10)
  if (!tsNum || Math.abs(now - tsNum) > 300)
    return { ok: false, response: json({ ok: false, error: "timestamp outside replay window" }, 401) }

  let body = ""
  if (method !== "GET") {
    const declared = Number(request.headers.get("content-length") || 0)
    if (Number.isFinite(declared) && declared > GAME_API_MAX_BODY)
      return { ok: false, response: json({ ok: false, error: "payload too large" }, 413) }
    body = await request.text()
    if (body.length > GAME_API_MAX_BODY)
      return { ok: false, response: json({ ok: false, error: "payload too large" }, 413) }
  }

  // The path the plugin signed: normalised exactly as this router normalises it.
  const path = new URL(request.url).pathname.replace(/\/+$/, "") || "/"
  const bodyHash = await sha256Hex(body)
  const expected = await sha256Hex(`${env.SYNC_SECRET}:${method}:${path}:${ts}:${nonce}:${bodyHash}`)
  if (!timingSafeEqual(expected, sig.toLowerCase()))
    return { ok: false, response: json({ ok: false, error: "invalid signature" }, 401) }
  return { ok: true, body }
}

async function handleGamePending(request, env, url) {
  const auth = await verifyGameRequest(request, env, "GET")
  if (!auth.ok) return auth.response
  const steamid = String(url.searchParams.get("steamid") || "")
  if (!validSteamid(steamid)) return json({ ok: false, error: "bad steamid" }, 400)
  try {
    const actions = await pendingActions(env.DB, steamid)
    return json({
      ok: true,
      steamid,
      season: "2026",
      server_time: Math.floor(Date.now() / 1000),
      count: actions.length,
      actions
    })
  } catch (e) {
    console.error("pending error:", e && e.stack ? e.stack : String(e))
    return json({ ok: false, error: "pending unavailable" }, 500)
  }
}

async function handleGameAck(request, env) {
  const auth = await verifyGameRequest(request, env, "POST")
  if (!auth.ok) return auth.response
  let body
  try { body = JSON.parse(auth.body) } catch { return json({ ok: false, error: "bad json" }, 400) }
  if (!body || typeof body !== "object") return json({ ok: false, error: "bad json" }, 400)
  try {
    const out = await ackAction(env.DB, { id: body.id, state: body.state, error: body.error })
    return json(out, out.ok ? 200 : 404)
  } catch (e) {
    if (e && e.name === "Refusal") return json({ ok: false, error: e.reason }, 400)
    console.error("ack error:", e && e.stack ? e.stack : String(e))
    return json({ ok: false, error: "ack unavailable" }, 500)
  }
}
