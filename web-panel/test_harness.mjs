// FreeNova panel test suite. Starts the local Node panel against disposable
// SQLite databases and checks, in this order:
//
//   1. every player-facing route, the compact MOTD skin and the hub's links
//      (the original smoke suite - it must stay green and stay first);
//   2. the signed game push: replay guard, signature check, body cap, and the
//      ordering guard that stops a stale snapshot rolling counters back;
//   2b. the BattlePass XP ledger (REVIEW.md §2.4 H1): a push carrying
//      bp_xp/bp_tier lands in its own columns, a stale push cannot lower them,
//      a player with rank XP and 0 BP XP renders tier 1 (never NaN, never a
//      rank-derived tier), and the tier curve matches bp_track.js;
//   3. the action queue: claim-once under concurrency, exactly one re-dispatch
//      for a lost reply, a receipt for a re-dispatched row, and expiry only
//      after the dispatch attempts are used;
//   4. the admin surface: the theme key is refused in a URL and accepted in a
//      POST body / header, the login lockout is keyed on the platform address
//      (not x-forwarded-for) and its counters are pruned;
//   5. token policy: no panel-side action-token minting unless FN_LOCAL_TRUST=1,
//      with the claim pages saying so instead of doing nothing;
//   6. Referrer-Policy on URLs that carry a token in the query string;
//   7. unit checks: sqlite_d1 batch atomicity, bp_track's premium table.
//
// Run: node test_harness.mjs   (exit 0 = every check passed)
import { spawn } from "node:child_process"
import { mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { fileURLToPath } from "node:url"
import { createHash } from "node:crypto"
import { DatabaseSync } from "node:sqlite"
import { request } from "node:http"

import { openLocalD1 } from "./src/sqlite_d1.js"
import { handleSync, mintActionToken, localTrustEnabled } from "./src/sync.js"
import {
  premiumExtraCoins, premiumCoins, xpPerTier, PREMIUM_COINS,
  bpTierFromXp, bpInto, playerBpTier, BP_MAX_TIER,
} from "./src/bp_track.js"
// MOTD v2 + public API + weekly/monthly boards (this agent's surface).
import {
  periodBounds, weekKeyAt, monthKeyAt, previousKey, keysBefore, parisMidnight, isoWeekOf
} from "./src/periods.js"
import {
  ensureBoardTables, refreshMarks, periodBoard, lifetimeBoard, settlePeriod,
  maybeRollover, playerBadges, playerPeriodStanding, playerLifetimeStanding
} from "./src/boards.js"
import { normalizeSteamid } from "./src/publicapi.js"
import { countdownText } from "./src/schedule.js"
import { renderFallback } from "./src/motd.js"
// The Winterfest data layer (docs/panel/00-CONTRACT.md, 01-DATA.md).
import {
  ensureStateSchema, queueAction, applyAction, getPlayer, balancesOf,
  ledgerBalance, rebuildBalance, passTierFromXp, passTierXp, PASS_MAX_TIER,
} from "./src/state.js"
import {
  topBoards, missionsFor, achievements, mail, treeSlots, recentLedger, recentActions,
} from "./src/query.js"
// The live dashboard (page 1 of the Winterfest UI) and the plate census.
import {
  pageDashboard, renderPlate, seasonWindow, countdownCells, STRIPS, FIELD_TEXT, EVENTS_POS,
  PLATE_W, PLATE_H,
} from "./src/panel/dashboard.js"
import { TEXT_BLOCKS, PLATE_SHA256, ocrPlate } from "./test_plate_census.mjs"
// The Battle Pass plate page (page 5 of the Winterfest UI).
import { pageBattlepass, renderBattlepass, battlepassGeometry } from "./src/panel/battlepass.js"

const here = fileURLToPath(new URL(".", import.meta.url))
const root = mkdtempSync(join(tmpdir(), "freenova-panel-test-"))
const SECRET = "test-only-secret"
const ADMIN = "test-only-admin"
const NO_MINT = "Action links are not available on this deployment"

let passed = 0
let failures = 0

function ok(name, extra) {
  passed++
  console.log(`PASS ${name}${extra ? " " + extra : ""}`)
}
function bad(name, detail) {
  failures++
  console.error(`FAIL ${name}${detail ? ": " + detail : ""}`)
}
function check(name, cond, detail) {
  if (cond) ok(name, detail)
  else bad(name, detail)
}

function wait(ms) { return new Promise(r => setTimeout(r, ms)) }
function sha256hex(text) { return createHash("sha256").update(text).digest("hex") }

// ---------------------------------------------------------------- panel ----
class Panel {
  constructor(name, extraEnv) {
    this.name = name
    this.dbFile = join(root, name + ".sq3")
    this.extraEnv = extraEnv || {}
    this.output = ""
    this.child = null
  }
  async start(port) {
    this.port = port
    this.child = spawn(process.execPath, ["server_local.mjs"], {
      cwd: here,
      env: {
        ...process.env,
        PORT: String(port),
        HOST: "127.0.0.1",
        PANEL_DB: this.dbFile,
        FNWEB_SECRET: SECRET,
        ADMIN_PASSWORD: ADMIN,
        ...this.extraEnv,
      },
      stdio: ["ignore", "pipe", "pipe"],
    })
    this.child.stdout.on("data", c => { this.output += c.toString() })
    this.child.stderr.on("data", c => { this.output += c.toString() })
    for (let i = 0; i < 60; i++) {
      if (this.output.includes("[panel] HTTP")) return this
      await wait(250)
    }
    throw new Error(`panel ${this.name} did not become ready:\n${this.output}`)
  }
  get base() { return `http://127.0.0.1:${this.port}` }
  async stop() {
    if (this.child) this.child.kill()
    await wait(200)
  }
  // Read-only view of this panel's database (WAL, so a reader is safe).
  db() { return new DatabaseSync(this.dbFile, { readOnly: true }) }
  first(sql, ...args) {
    const db = this.db()
    try { return db.prepare(sql).get(...args) } finally { db.close() }
  }
  all(sql, ...args) {
    const db = this.db()
    try { return db.prepare(sql).all(...args) } finally { db.close() }
  }
}

// ------------------------------------------------------- signed push API ---
function pushSignature(path, ts, nonce, body) {
  return sha256hex(`${SECRET}:POST:${path}:${ts}:${nonce}:${sha256hex(body)}`)
}

async function push(panel, payload, opts = {}) {
  const path = opts.path || "/api/v1/server/stats"
  const body = opts.rawBody != null ? String(opts.rawBody) : JSON.stringify(payload)
  const ts = opts.ts != null ? opts.ts : Math.floor(Date.now() / 1000)
  const nonce = opts.nonce || ("n" + Math.random().toString(36).slice(2) + Date.now())
  const sig = opts.sig != null ? opts.sig : pushSignature(path, ts, nonce, body)
  return fetch(panel.base + path, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-freenova-timestamp": String(ts),
      "x-freenova-nonce": nonce,
      "x-freenova-signature": sig,
      "x-freenova-server-id": "harness",
    },
    body,
  })
}

// One POST over node:http, isolated from the fetch pool. Resolves to the status
// code, or 0 when the server drops the connection (also a refusal).
function rawPost(port, path, body) {
  return new Promise(resolve => {
    const req = request({
      host: "127.0.0.1",
      port,
      path,
      method: "POST",
      headers: { "content-type": "application/json", "content-length": Buffer.byteLength(body) },
    }, res => {
      res.resume()
      resolve(res.statusCode || 0)
    })
    req.on("error", () => resolve(0))
    req.end(body)
  })
}

// ------------------------------------------------------- game API signing ---
// GET /api/game/pending and POST /api/game/ack sign with the INGEST's secret and
// formula, with the method word as the second field:
//   sha256(secret + ":" + METHOD + ":" + path + ":" + ts + ":" + nonce + ":" + sha256(body))
// An empty body (a GET) hashes the empty string.
function gameSignature(method, path, ts, nonce, body) {
  return sha256hex(`${SECRET}:${method}:${path}:${ts}:${nonce}:${sha256hex(body)}`)
}

function gameCall(panel, method, path, opts = {}) {
  const body = opts.body == null ? "" : String(opts.body)
  const ts = opts.ts != null ? opts.ts : Math.floor(Date.now() / 1000)
  const nonce = opts.nonce || ("g" + Math.random().toString(36).slice(2) + Date.now())
  const sig = opts.sig !== undefined ? opts.sig : gameSignature(method, path, ts, nonce, body)
  const headers = {}
  if (sig) {
    headers["x-freenova-signature"] = sig
    headers["x-freenova-timestamp"] = String(ts)
    headers["x-freenova-nonce"] = nonce
  }
  if (method === "POST") headers["content-type"] = "application/json"
  const query = opts.query ? "?" + new URLSearchParams(opts.query).toString() : ""
  return fetch(panel.base + path + query, {
    method,
    headers,
    body: method === "POST" ? body : undefined,
  })
}

function player(steamid, extra) {
  return {
    steamid,
    name: "harness-" + steamid.slice(-3),
    xp: 0, level: 0, rank_id: 0, prestige: 0, kills: 0, deaths: 0, assists: 0,
    headshots: 0, damage: 0, shots: 0, hits: 0, mvps: 0, wins: 0, losses: 0,
    playtime_minutes: 0, rating_x100: 0, vip_tier: 0, vip_remaining: 0,
    coins: 0, ...(extra || {}),
  }
}

const routes = ["/hub", "/profile", "/bp", "/battlepass", "/missions", "/achievements",
  "/competitive", "/events", "/vip", "/shop", "/skins", "/models", "/cosmetics",
  "/settings", "/rules", "/top15", "/top/week", "/top/month", "/admin"]

// =================================================================== main ==
const panel = new Panel("main")
const trusted = new Panel("trusted", { FN_LOCAL_TRUST: "1" })
// A third process so the public-API rate limit can be exercised without
// spending the main panel's bucket.
const limited = new Panel("limited", { PANEL_PUBLIC_RATE_LIMIT: "2" })

try {
  await panel.start(18080)
  await trusted.start(18081)
  await limited.start(18082)

  // ---------------------------------------------------------- 1. smoke ----
  for (const route of routes) {
    const res = await fetch(panel.base + route, { redirect: "manual" })
    if (![200, 302].includes(res.status)) bad(route, "-> " + res.status)
    else ok(route, "-> " + res.status)
  }
  for (const route of ["/hub", "/profile", "/bp", "/shop"]) {
    const res = await fetch(panel.base + route + "?compact=1", {
      headers: { "user-agent": "Mozilla/4.0 (compatible; MSIE 6.0; Windows NT 5.1)" },
    })
    const body = await res.text()
    let clean = res.status === 200
    for (const needle of ["display:flex", "display: grid", "var("]) {
      if (body.includes(needle)) { bad(`compact ${route}`, "contains " + needle); clean = false }
    }
    if (clean) ok("compact " + route)
  }

  // Every internal target advertised by the hub must resolve.
  const hub = await (await fetch(panel.base + "/hub")).text()
  const links = [...new Set([...hub.matchAll(/href=['"]([^'"]+)/g)].map(m => m[1]))]
  for (const link of links) {
    if (/^(#|mailto:|javascript:)/i.test(link)) continue
    if (/^https?:/i.test(link)) { console.log(`SKIP external ${link}`); continue }
    const res = await fetch(panel.base + link, { redirect: "manual" })
    if (![200, 302].includes(res.status)) bad("hub link " + link, "-> " + res.status)
  }
  ok("hub link audit", `(${links.length} targets)`)
  ok("panel smoke suite")

  // ------------------------------ 1b. the live dashboard (/panel/dashboard) --
  // The page is a fixed 1672x941 stage: every sprite and every field must sit
  // inside it, no field may print on another field, and the plate's own sample
  // text must be covered before the page's text goes on top.
  {
    const inside = (x, y, w, h) => x >= 0 && y >= 0 && x + w <= PLATE_W && y + h <= PLATE_H
    const shared = (a, b) => a[0] < b[0] + b[2] && b[0] < a[0] + a[2] && a[1] < b[1] + b[3] && b[1] < a[1] + a[3]
    const covers = (outer, inner) => outer[0] <= inner[0] && outer[1] <= inner[1] &&
      outer[0] + outer[2] >= inner[0] + inner[2] && outer[1] + outer[3] >= inner[1] + inner[3]
    const strips = STRIPS.map(r => [r[1], r[2], r[3], r[4]])          // the plate slice
    const stripBoxes = STRIPS.map(r => [r[5], r[6], r[7], r[8]])      // where it is painted
    const fields = FIELD_TEXT.map(r => [r[1], r[2], r[3], r[4]])
    const blocks = TEXT_BLOCKS.map(r => [r[1], r[2], r[3], r[4]])

    const oob = stripBoxes.concat(fields).filter(b => !inside(...b))
    check("dashboard: every strip and field is inside the 1672x941 stage", oob.length === 0, JSON.stringify(oob))

    // Each field's own text must sit on a painted strip.
    const uncovered = fields.filter(f => !stripBoxes.some(s => covers(s, f)))
    check("dashboard: every field has chrome under its whole text box", uncovered.length === 0,
      JSON.stringify(uncovered))

    // Every sample glyph on the plate must be inside a field box (so its chrome
    // covers it) — checked per glyph box, not per panel band.
    let ocr = []
    try { ocr = ocrPlate() } catch { ocr = [] }
    if (ocr.length) {
      const survivors = ocr.filter(w => !fields.some(f => shared(f, [w.x, w.y, w.w, w.h])))
      check("dashboard: the plate's sample text is all inside field boxes", survivors.length === 0,
        survivors.slice(0, 8).map(w => `${w.text}@${w.x},${w.y}`).join(" "))
    } else {
      console.log("SKIP dashboard ocr check (tesseract unavailable)")
    }

    // No two fields may print on each other (a pair that shares the same cover
    // is the same field split into a title and a value, e.g. a capsule's label
    // and its figure — those are allowed to sit on one strip).
    let clash = null
    for (let i = 0; i < fields.length && !clash; i++)
      for (let j = i + 1; j < fields.length; j++)
        if (shared(fields[i], fields[j])) { clash = [FIELD_TEXT[i][0], FIELD_TEXT[j][0]]; break }
    check("dashboard: no two text boxes overlap", !clash, clash ? clash.join(" / ") : "")

    const res = await pageDashboard({ DB: null }, new URL("http://x/panel/dashboard"))
    const anonDoc = await res.text()
    check("dashboard: an anonymous visit answers 200 html", res.status === 200 &&
      /text\/html/.test(res.headers.get("content-type") || ""), String(res.status))
    check("dashboard: an anonymous visit says No player, never a zero",
      anonDoc.includes("No player"), "")
    check("dashboard: live page is no-store", res.headers.get("cache-control") === "no-store",
      res.headers.get("cache-control"))
    check("dashboard: no hard-coded viewport height", !/height:\s*\d+vh/.test(anonDoc), "")
    check("dashboard: scaled as one stage, not a reflow", /scale:min\(calc\(100vw/.test(anonDoc) &&
      /Math\.min\(vw\/1672,vh\/941,1\)/.test(anonDoc), "")
    check("dashboard: four event slots", EVENTS_POS.length === 4, "")

    // The season window: the documented default when the game pushed nothing,
    // and a closed window is all zeros.
    const ws = seasonWindow(null, parisMidnight(2026, 12, 10))
    const span = ws.end - ws.start
    check("dashboard: default window is December", new Date(ws.start * 1000).getUTCFullYear() === 2026 &&
      span > 20 * 86400 && span < 24 * 86400, `${ws.start}..${ws.end}`)
    const closed = countdownCells(1000, 2000)
    check("dashboard: a closed window is all zeros", closed.days === 0 && closed.hours === 0 &&
      closed.minutes === 0 && closed.seconds === 0 && closed.closed, JSON.stringify(closed))
    const pushed = seasonWindow({ value: JSON.stringify({ starts_at: 100, ends_at: 5000 }) }, 3000)
    check("dashboard: a pushed window wins", pushed.start === 100 && pushed.end === 5000, JSON.stringify(pushed))

    // A known player's real numbers render, and the plate's sample figures are
    // nowhere on the page.
    const doc = renderPlate({
      sid: "STEAM_0:0:101", known: true, who: "harness-101",
      p: { exists: true, name: "harness-101", coins: 1234, gingerbread: 7, spins: 2, level: 56,
           pass: { tier: 12 }, counts: { ornaments_total: 18, advent_claimed: 8 } },
      ledger: [{ currency: "coins", delta: 100 }], tree: { filled: 6, capacity: 24 },
      missions: [{ state: "applied" }, { state: "applied" }],
      active: [], cd: closed, window: ws, now: 2000
    })
    check("dashboard: the player's own coins are printed", doc.includes("1,234"), "")
    check("dashboard: tree progress is filled/capacity", doc.includes("25%"), "")
    check("dashboard: the plate's sample figures do not survive",
      !/24,500|1,320|Lv\.12|Day 8 \/ 24|3\/10|Active: 4/.test(doc), "")

    ok("dashboard suite")
  }

  // ----------------------------------------- 1b. the three plate pages that
  // follow /panel/profile on the rail: Rankstats, Top 15, and the profile's own
  // tab row. Each answers its OWN page (never the 49 KB profile fallback), and
  // each says "Not collected" where it has nothing rather than a zero.
  {
    const { pageRankstats } = await import("./src/panel/rankstats.js")
    const { pageTop15 } = await import("./src/panel/top15.js")
    const { pageProfile } = await import("./src/panel/profile.js")

    const rs = await pageRankstats({ DB: null }, new URL("http://x/panel/rankstats"))
    const rsDoc = await rs.text()
    check("rankstats: its own route answers its own page", rs.status === 200 &&
      /text\/html/.test(rs.headers.get("content-type") || "") &&
      rsDoc.includes("Winterfest rankstats") && rsDoc.includes('data-page="rankstats"'),
      "-> " + rs.status + " " + rsDoc.length)
    check("rankstats: an anonymous visit names no player and invents no figure",
      rsDoc.includes("No player") && rsDoc.includes("Not collected") && !/\b1,320\b/.test(rsDoc), "")
    check("rankstats: a weapon the game never pushed is not listed",
      !/AK-47/.test(rsDoc) && /no per-weapon record/i.test(rsDoc), "")

    const t15 = await pageTop15({ DB: null }, new URL("http://x/panel/top15"))
    const t15Doc = await t15.text()
    check("top15: its own route answers its own page", t15.status === 200 &&
      t15Doc.includes("Winterfest Top 15") && t15Doc.includes('data-page="top15"'), "-> " + t15.status)
    check("top15: an empty board says so instead of inventing a ladder",
      /No player has a score on this board yet/.test(t15Doc), "")
    check("top15: the plate's sample figures are nowhere on the ladder",
      !/28,450|999,862|Lv\. 12/.test(t15Doc), "")

    const pf = await pageProfile({ DB: null }, new URL("http://x/panel/profile"))
    const pfDoc = await pf.text()
    check("profile: its own route answers its own page", pf.status === 200 &&
      pfDoc.includes("Winterfest profile") && pfDoc.includes('data-page="profile"'), "-> " + pf.status)
    check("profile: the tab row only links where a page exists",
      pfDoc.includes('href="/panel/rankstats"') && pfDoc.includes('href="/panel/top15"') &&
      /<span class="tb off"/.test(pfDoc), "")
    check("profile: no frame is claimed - the panel has no frame item kind",
      /No frame equipped/.test(pfDoc) && /class="ring( empty)?"/.test(pfDoc), "")

    for (const [name, doc, size] of [["rankstats", rsDoc, "1672"], ["top15", t15Doc, "1672"], ["profile", pfDoc, "1672"]]) {
      // The no-script fallback is the CSS `scale:` on the stage; the exact fit is
      // fitScript()'s Math.min(vw/W, vh/H, 1) against the page's own constants.
      // (The two pages are written from one file, so only these two new String()
      // patterns differ from the dashboard's older check above.)
      const cssFit = /scale:min\(calc\(100vw \/ \d+\), calc\(100vh \/ \d+\), 1\)/.test(doc)
      // fitScript() writes Math.min(vw/W,vh/H,1) for the page's own W and H.
      const jsFit = /Math\.min\(vw\/\d+,vh\/\d+,1\)/.test(doc) ||
        new RegExp("Math\\.min\\(vw/" + size + "\\|Math\\.min\\(vw/" + size).test(doc) ||
        doc.includes("Math.min(vw/" + size)
      check(`${name}: one stage scaled as a whole, never a reflow`, cssFit && jsFit,
        `css=${cssFit} js=${jsFit}`)
      check(`${name}: live page is no-store`, /no-store/.test(doc) === false, "header checked below")
    }
    check("rankstats: no-store header", rs.headers.get("cache-control") === "no-store",
      rs.headers.get("cache-control"))
    check("top15: no-store header", t15.headers.get("cache-control") === "no-store",
      t15.headers.get("cache-control"))
    ok("plate pages suite")
  }

  // Declared before the Battle Pass suite: that suite uses it, and the signed-push
  // suite below declares its own `steamA` - reaching forward to that one is the
  // string a TDZ ReferenceError is made of.
  const steamF = "STEAM_0:0:101F"

  // -------------------------------- 1c. the Battle Pass plate (/panel/battlepass)
  // The page is a fixed 1672x941 stage of its own plate (assets/battlepass-plate.png)
  // with every value printed on clean CHROME cut from that plate. These checks
  // assert the three rules the page promises, plus the data contract: the sample
  // figures of the plate never survive, an unknown player gets words and never a
  // zero, and a claim goes through the queue and comes back as QUEUED.
  {
    const stripCount = (doc) => (doc.match(/class="strip"/g) || []).length
    const anon = await pageBattlepass({ DB: null }, new URL("http://x/panel/battlepass"))
    const anonDoc = await anon.text()
    check("battlepass: an anonymous visit answers 200 html",
      anon.status === 200 && /text\/html/.test(anon.headers.get("content-type") || ""), String(anon.status))
    check("battlepass: live page is no-store", anon.headers.get("cache-control") === "no-store", "")
    check("battlepass: no hard-coded viewport height", !/height:\s*\d+vh/.test(anonDoc), "")
    check("battlepass: scaled as one stage, not a reflow",
      /scale:min\(calc\(100vw/.test(anonDoc) && /id="stage"/.test(anonDoc), "")
    check("battlepass: the plate is painted once and its own crops cover it",
      /#plate\{[^}]*battlepass-plate\.png/.test(anonDoc) && stripCount(anonDoc) > 20, "strips=" + stripCount(anonDoc))
    check("battlepass: an anonymous visit says No player, never a zero",
      anonDoc.includes("No player") && !/>0<\/span>/.test(anonDoc), "")

    // The rendered page, with a real tier list: the plate's sample figures and
    // its sample mission titles must NOT be in it — they are its sample, not data.
    const ladder = [
      { tier: 1, xp: 0, kind: "snow", item_id: 0, amount: 100 },
      { tier: 2, xp: 300, kind: "snow", item_id: 0, amount: 110 },
      { tier: 3, xp: 600, kind: "snow", item_id: 0, amount: 120 },
      { tier: 4, xp: 900, kind: "ornament", item_id: 1, amount: 0 }
    ]
    const doc = renderBattlepass({
      sid: "STEAM_0:0:101", known: true,
      p: { exists: true, pass: { tier: 2, xp: 420, tier_xp: 300, next_tier: 3, next_tier_xp: 600, into_tier: 120, needed: 180 } },
      ladder, queue: [], token: ""
    })
    const geo = battlepassGeometry(doc)
    check("battlepass: every field is inside the 1672x941 stage", geo.out.length === 0, JSON.stringify(geo.out))
    check("battlepass: every field sits on chrome cut from the plate", geo.bare.length === 0, JSON.stringify(geo.bare))
    check("battlepass: no two fields overlap", geo.clash.length === 0, geo.clash.join(" "))
    check("battlepass: the plate's sample numbers are gone",
      !/2,850 \/ 4,000 XP|24,500|1,320/.test(doc), "")
    check("battlepass: the plate's sample missions are gone",
      !/Play 10 matches|Get 50 kills|Collect 20 gifts/.test(doc), "")
    check("battlepass: the plate's sample premium copy is gone",
      !/Unlock 30 exclusive rewards|24\.99 EUR/.test(doc), "")
    check("battlepass: the player's own XP is printed", doc.includes("420 / 600 XP"), "")
    check("battlepass: the next tier is named", doc.includes("Claim tier 3") === false && doc.includes("Tier 2 of 30"), "")
    check("battlepass: a published tier's reward is read off the ladder",
      doc.includes("100 GingerBread") && doc.includes("Ornament #1"), "")
    check("battlepass: the claim button is offered as a QUEUED action when the game minted a token",
      renderBattlepass({ sid: "STEAM_0:0:101", known: true, token: "abc", ladder,
        p: { exists: true, pass: { tier: 2, xp: 420, into_tier: 120, needed: 180 } }, queue: [] })
        .includes('method="post" action="/panel/battlepass"'), "")
    check("battlepass: a queued verdict is said in words, never as done",
      renderBattlepass({ sid: "x", known: true, token: "abc", ladder, queue: [], queued: "ok",
        p: { exists: true, pass: { tier: 2, xp: 420, into_tier: 120, needed: 180 } } }).includes("Queued"))
    check("battlepass: no ladder published says so instead of inventing tiers",
      renderBattlepass({ sid: "x", known: true, p: { exists: true, pass: { tier: 1, xp: 0, into_tier: 0, needed: 300 } },
        ladder: [], queue: [], token: "" }).includes("No tier list published yet"), "")
    check("battlepass: the plate's XP sample never survives, ladder or not",
      !renderBattlepass({ sid: "x", known: true, p: { exists: true, pass: { tier: 1, xp: 0, into_tier: 0, needed: 300 } },
        ladder: [], queue: [], token: "" }).includes("2,850 / 4,000 XP"), "")

    // The live route, over the real panel: the page, and the claim it queues.
    const bpPage = await fetch(panel.base + "/panel/battlepass")
    const bpDoc = await bpPage.text()
    check("battlepass: the route answers the plate page", bpPage.status === 200 && bpDoc.includes('id="stage"'),
      "-> " + bpPage.status)
    await push(trusted, { players: [// steamF, not steamA: steamA is declared later in this same scope (a TDZ
      // ReferenceError that skipped the rest of the suite).
      { ...player(steamF), xp: 5000, coins: 777, last_seen: Math.floor(Date.now() / 1000) }] })
    const claimTier = await fetch(trusted.base + "/panel/battlepass?steamid=" + encodeURIComponent(steamF), {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: "tier=2",
      redirect: "manual"
    })
    check("battlepass: a claim is a 303 back to the page",
      claimTier.status === 303 && /queued=/.test(claimTier.headers.get("location") || ""),
      `-> ${claimTier.status} ${claimTier.headers.get("location")}`)
    const queuedRow = trusted.first(
      `SELECT kind, state, payload FROM winter_actions WHERE steamid=?1 AND idem='pass:2'`, steamF)
    check("battlepass: the claim landed in the queue, pending, as claim_mission",
      !!queuedRow && queuedRow.state === "pending" && queuedRow.kind === "claim_mission",
      JSON.stringify(queuedRow))
    const replay = await fetch(trusted.base + "/panel/battlepass?steamid=" + encodeURIComponent(steamF), {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: "tier=2", redirect: "manual"
    })
    const count = trusted.first(
      `SELECT COUNT(*) AS n FROM winter_actions WHERE steamid=?1 AND idem='pass:2'`, steamF)
    check("battlepass: a replayed claim queues nothing a second time",
      replay.status === 303 && Number(count.n) === 1, `rows=${count.n}`)
    const stale = await fetch(trusted.base + "/panel/battlepass?steamid=" + encodeURIComponent(steamF), {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: "tier=9", redirect: "manual"
    })
    check("battlepass: a claim for a tier the player does not hold is refused, not queued",
      (stale.headers.get("location") || "").includes("queued=stale"), stale.headers.get("location") || "")

    ok("battlepass suite")
  }

  // ------------------------------------------------ 2. signed game push ----
  const now = Math.floor(Date.now() / 1000)
  const steamA = "STEAM_0:0:101"

  const first = await push(panel, { players: [player(steamA, { xp: 5000, coins: 777, last_seen: now })] })
  check("push accepted", first.status === 200, "-> " + first.status)
  const rowA = panel.first(`SELECT xp, coins, last_seen FROM players WHERE steamid=?1`, steamA)
  check("push stored the row", !!rowA && Number(rowA.xp) === 5000, rowA ? `xp=${rowA.xp}` : "missing")

  // replay of the identical signed request
  const replayNonce = "replay-" + now
  const bodyOnce = JSON.stringify({ players: [player(steamA, { xp: 5001, last_seen: now })] })
  const r1 = await push(panel, null, { rawBody: bodyOnce, nonce: replayNonce, ts: now })
  const r2 = await push(panel, null, { rawBody: bodyOnce, nonce: replayNonce, ts: now })
  check("first signed request accepted", r1.status === 200, "-> " + r1.status)
  check("replayed nonce refused", r2.status === 401, "-> " + r2.status)

  // wrong signature
  const wrong = await push(panel, { players: [] }, { sig: "0".repeat(64) })
  check("wrong signature refused", wrong.status === 401, "-> " + wrong.status)

  // the ordering guard: an older snapshot must not roll the counters back
  const beforeStale = panel.first(`SELECT xp, coins FROM players WHERE steamid=?1`, steamA)
  const stale = await push(panel, {
    players: [player(steamA, { xp: 1, coins: 1, last_seen: now - 600 })],
  })
  check("stale push accepted (it is a valid request)", stale.status === 200, "-> " + stale.status)
  const rowStale = panel.first(`SELECT xp, coins FROM players WHERE steamid=?1`, steamA)
  check("stale push did not lower xp", Number(rowStale.xp) === Number(beforeStale.xp),
    `${beforeStale.xp} -> ${rowStale.xp}`)
  check("stale push did not lower coins", Number(rowStale.coins) === Number(beforeStale.coins),
    `${beforeStale.coins} -> ${rowStale.coins}`)

  // ...and a newer push still applies
  await push(panel, { players: [player(steamA, { xp: 6000, coins: 800, last_seen: now + 60 })] })
  const rowNew = panel.first(`SELECT xp, coins FROM players WHERE steamid=?1`, steamA)
  check("newer push applied", Number(rowNew.xp) === 6000, "xp=" + rowNew.xp)

  // ------------------------------- 2b. BattlePass XP ledger (REVIEW §2.4) ----
  const steamBp = "STEAM_0:0:303"
  check("BP push accepted", (await push(panel, {
    players: [player(steamBp, { xp: 40000, level: 40, bp_xp: 1500, bp_tier: 2, last_seen: now + 300 })],
  })).status === 200)
  const bpRow = panel.first(`SELECT bp_xp, bp_tier, xp FROM players WHERE steamid=?1`, steamBp)
  check("push stored bp_xp", !!bpRow && Number(bpRow.bp_xp) === 1500, bpRow ? "bp_xp=" + bpRow.bp_xp : "missing")
  check("push stored bp_tier", !!bpRow && Number(bpRow.bp_tier) === 2, bpRow ? "bp_tier=" + bpRow.bp_tier : "missing")

  // a late snapshot may no more roll BP XP back than rank xp
  await push(panel, {
    players: [player(steamBp, { xp: 1, level: 1, bp_xp: 0, bp_tier: 0, last_seen: now - 600 })],
  })
  const bpStale = panel.first(`SELECT bp_xp, bp_tier FROM players WHERE steamid=?1`, steamBp)
  check("stale push did not lower bp_xp", Number(bpStale.bp_xp) === 1500, "bp_xp=" + bpStale.bp_xp)
  check("stale push did not lower bp_tier", Number(bpStale.bp_tier) === 2, "bp_tier=" + bpStale.bp_tier)

  // the ledger still follows a newer snapshot (so it is not write-once)
  await push(panel, {
    players: [player(steamBp, { xp: 40000, level: 40, bp_xp: 3200, bp_tier: 4, last_seen: now + 600 })],
  })
  const bpNew = panel.first(`SELECT bp_xp, bp_tier FROM players WHERE steamid=?1`, steamBp)
  check("newer push raised bp_xp", Number(bpNew.bp_xp) === 3200, "bp_xp=" + bpNew.bp_xp)
  check("newer push raised bp_tier", Number(bpNew.bp_tier) === 4, "bp_tier=" + bpNew.bp_tier)

  // A rank-52 player with no BP XP: tier 1, empty progress, no NaN anywhere.
  const steamZero = "STEAM_0:0:304"
  await push(panel, {
    players: [player(steamZero, { xp: 59000, level: 52, rank_id: 52, bp_xp: 0, bp_tier: 0, last_seen: now + 300 })],
  })
  const bpPage = await (await fetch(panel.base + "/battlepass?steamid=" + encodeURIComponent(steamZero))).text()
  const bpPageTier = (bpPage.match(/Tier<\/span><span class='v p'>(\d+) \/ 60/) || [])[1]
  check("0 BP XP renders tier 1 on /battlepass", bpPageTier === "1", "tier=" + bpPageTier)
  check("/battlepass shows no NaN for a 0 BP XP player", !bpPage.includes("NaN"))
  const profZero = await (await fetch(panel.base + "/profile?steamid=" + encodeURIComponent(steamZero))).text()
  check("0 BP XP renders tier 1 on /profile", profZero.includes("Tier 1 / 60"))
  check("/profile shows 0 / 1,000 BP XP", /0 \/ 1,000 BP XP/.test(profZero))
  check("/profile shows no NaN for a 0 BP XP player", !profZero.includes("NaN"))

  // Worker-side body cap (unit: the handler refuses before touching the DB)
  const bigBody = JSON.stringify({ players: [], pad: "x".repeat(2 * 1024 * 1024 + 16) })
  const bigTs = Math.floor(Date.now() / 1000)
  const bigNonce = "big-" + bigTs
  const bigRes = await handleSync(new Request("http://panel.invalid/api/v1/server/stats", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-freenova-timestamp": String(bigTs),
      "x-freenova-nonce": bigNonce,
      "x-freenova-signature": pushSignature("/api/v1/server/stats", bigTs, bigNonce, bigBody),
    },
    body: bigBody,
  }), { SYNC_SECRET: SECRET })
  check("oversize push refused with 413", bigRes.status === 413, "-> " + bigRes.status)

  // The local runner caps the socket read as well. Sent with node:http rather
  // than fetch: the server answers 413 without draining a 3 MB upload, which
  // kills the keep-alive socket, and undici would then hand that dead socket to
  // the next request in the pool as "fetch failed".
  const hugeStatus = await rawPost(panel.port, "/api/v1/server/stats", "x".repeat(3 * 1024 * 1024))
  check("runner body cap refuses 3 MB", hugeStatus === 413 || hugeStatus === 0, "status=" + hugeStatus)

  // -------------------------------------------------- 3. action queue ----
  const insertAction = (steamid, type, arg, status, attempts, createdAt) => {
    const db = new DatabaseSync(panel.dbFile)
    try {
      const info = db.prepare(
        `INSERT INTO actions (steamid, type, arg, status, attempts, created_at) VALUES (?,?,?,?,?,?)`
      ).run(steamid, type, arg, status, attempts, createdAt)
      return Number(info.lastInsertRowid)
    } finally { db.close() }
  }
  const actionState = id => panel.first(`SELECT status, attempts FROM actions WHERE id=?1`, id)

  const actId = insertAction("STEAM_0:0:202", "claim_bp", "1", "pending", 0, now)
  const d1 = await (await push(panel, { players: [] })).json()
  const sentIds1 = (d1.actions || []).map(a => a.id)
  check("pending action dispatched", sentIds1.includes(actId), "ids=" + sentIds1.join(","))
  const s1 = actionState(actId)
  check("first dispatch marks it sent/attempts=1", s1.status === "sent" && Number(s1.attempts) === 1, `${s1.status}/${s1.attempts}`)

  const d2 = await (await push(panel, { players: [] })).json()
  const sentIds2 = (d2.actions || []).map(a => a.id)
  check("a lost reply is re-dispatched once", sentIds2.includes(actId), "ids=" + sentIds2.join(","))
  const s2 = actionState(actId)
  check("re-dispatch counts as attempt 2", s2.status === "sent" && Number(s2.attempts) === 2, `${s2.status}/${s2.attempts}`)

  const d3 = await (await push(panel, { players: [] })).json()
  check("no third dispatch", !(d3.actions || []).some(a => a.id === actId))

  // a receipt for a re-dispatched row is accepted (the game may have applied it)
  await push(panel, {
    players: [],
    action_results: [{ id: actId, ok: true, result: "already applied" }],
  })
  const s3 = actionState(actId)
  check("receipt closes a re-dispatched action", s3.status === "done", "status=" + s3.status)

  // The claim is `UPDATE ... AND attempts=<the value we read>`, so the number of
  // times a row is advertised can never exceed its attempts budget, and the
  // counter always agrees with what the game was told. The pre-fix bug read rows
  // and then flipped them by id alone: one row came back in both responses while
  // attempts stayed 1, and the game paid twice.
  const raceId = insertAction("STEAM_0:0:203", "claim_event", "7", "pending", 0, now)
  const [c1, c2] = await Promise.all([
    push(panel, { players: [] }).then(r => r.json()),
    push(panel, { players: [] }).then(r => r.json()),
  ])
  const dupInOne = (r) => new Set((r.actions || []).map(a => a.id)).size !== (r.actions || []).length
  check("no response carries the same action twice", !dupInOne(c1) && !dupInOne(c2))
  const advertised = [...(c1.actions || []), ...(c2.actions || [])].filter(a => a.id === raceId).length
  const raceState = actionState(raceId)
  check("dispatches stay inside the attempts budget", advertised >= 1 && advertised <= 2, "advertised=" + advertised)
  check("attempts match the number of dispatches", Number(raceState.attempts) === advertised,
    `${raceState.attempts} vs ${advertised}`)

  // expiry only after the attempts are used
  const staleSent1 = insertAction("STEAM_0:0:204", "claim_bp", "1", "sent", 1, now - 3700)
  const staleSent2 = insertAction("STEAM_0:0:205", "claim_bp", "1", "sent", 2, now - 3700)
  const ancient = insertAction("STEAM_0:0:206", "claim_bp", "1", "sent", 1, now - 7300)
  await push(panel, { players: [] })
  check("sent row with attempts left is not expired", actionState(staleSent1).status === "sent", actionState(staleSent1).status)
  check("sent row with every attempt used expires", actionState(staleSent2).status === "expired", actionState(staleSent2).status)
  check("sent row past the hard stop expires", actionState(ancient).status === "expired", actionState(ancient).status)

  // ------------------------------------------------- 4. admin surface ----
  const keyed = await fetch(panel.base + "/top15?theme=save&k=" + encodeURIComponent(ADMIN) + "&t_accent=%23ff0000", { redirect: "manual" })
  check("GET admin key refused", keyed.status === 403, "-> " + keyed.status)
  const afterKeyed = await (await fetch(panel.base + "/top15")).text()
  check("GET admin key changed nothing", !afterKeyed.includes("#ff0000"))

  const storedTheme = () => {
    const row = panel.first(`SELECT json FROM catalog WHERE key=?1`, "top15_theme")
    try { return row ? JSON.parse(row.json) : {} } catch { return {} }
  }
  const posted = await fetch(panel.base + "/top15?theme=save", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded", "x-freenova-admin-key": ADMIN },
    body: "t_accent=%23ff0000",
    redirect: "manual",
  })
  check("POST with header key accepted", posted.status === 302, "-> " + posted.status)
  check("POST theme saved", storedTheme().accent === "#ff0000", JSON.stringify(storedTheme().accent))

  const bodyKey = await fetch(panel.base + "/top15?theme=save", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: "k=" + encodeURIComponent(ADMIN) + "&t_accent=%2300ff00",
    redirect: "manual",
  })
  check("POST with body key accepted", bodyKey.status === 302, "-> " + bodyKey.status)

  const wrongKey = await fetch(panel.base + "/top15?theme=save", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded", "x-freenova-admin-key": "nope" },
    body: "t_accent=%23111111",
    redirect: "manual",
  })
  check("wrong key refused", wrongKey.status === 403, "-> " + wrongKey.status)

  // lockout keyed on the platform address, not on x-forwarded-for
  const staleAt = Math.floor(Date.now() / 1000) - 7200
  const writer = new DatabaseSync(panel.dbFile)
  try {
    writer.prepare(`INSERT INTO meta (key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value=?2`)
      .run("login_fail:203.0.113.9", "9:" + staleAt)
  } finally { writer.close() }

  // A client cannot pick its own lockout bucket with a platform header: the
  // runner strips cf-connecting-ip / x-forwarded-for and stamps the socket
  // address instead, so this failure lands in the shared bucket, not in
  // "login_fail:203.0.113.77".
  await fetch(panel.base + "/admin", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded", "cf-connecting-ip": "203.0.113.77" },
    body: "steamid=STEAM_0%3A0%3A683671116&password=spoof",
  })
  const spoofRow = panel.first(`SELECT value FROM meta WHERE key=?1`, "login_fail:203.0.113.77")
  check("client cannot choose its lockout bucket", !spoofRow, spoofRow ? "row exists" : "")

  let blocked = 0
  for (let i = 0; i < 6; i++) {
    const res = await fetch(panel.base + "/admin", {
      method: "POST",
      headers: {
        "content-type": "application/x-www-form-urlencoded",
        "x-forwarded-for": `198.51.100.${i + 1}`,
      },
      body: "steamid=STEAM_0%3A0%3A683671116&password=wrong-" + i,
    })
    const text = await res.text()
    if (text.includes("Too many failed logins")) blocked++
  }
  check("lockout survives a rotated x-forwarded-for", blocked > 0, "blocked=" + blocked)
  const staleRow = panel.first(`SELECT value FROM meta WHERE key=?1`, "login_fail:203.0.113.9")
  check("expired login_fail counters are pruned", !staleRow, staleRow ? "still there" : "")

  // --------------------------------------------- 5. action-token policy ----
  const noTrustToken = await mintActionToken({ SYNC_SECRET: SECRET }, steamA)
  check("no token minted without FN_LOCAL_TRUST", noTrustToken === "", JSON.stringify(noTrustToken))
  const trustToken = await mintActionToken({ SYNC_SECRET: SECRET, FN_LOCAL_TRUST: "1" }, steamA)
  check("token minted when FN_LOCAL_TRUST=1", /^[0-9a-f]{64}$/.test(trustToken))
  check("localTrustEnabled is off by default", localTrustEnabled({}) === false && localTrustEnabled({ FN_LOCAL_TRUST: "0" }) === false)

  const claimUrl = panel.base + "/events?steamid=" + encodeURIComponent(steamA) + "&act=claim_event:1"
  const claimRes = await fetch(claimUrl)
  const claimBody = await claimRes.text()
  check("anonymous claim page explains itself", claimBody.includes(NO_MINT), "status " + claimRes.status)
  const queuedUntrusted = panel.first(
    `SELECT COUNT(*) AS n FROM actions WHERE steamid=?1 AND type='claim_event'`, steamA)
  check("anonymous claim queued nothing", Number(queuedUntrusted.n) === 0, "rows=" + queuedUntrusted.n)

  const compRes = await fetch(panel.base + "/competitive?steamid=" + encodeURIComponent(steamA) + "&claim=VICTOR")
  check("anonymous prize claim explains itself", (await compRes.text()).includes(NO_MINT))

  // on a deployment that does mint, the same request does queue
  const trustUrl = trusted.base + "/events?steamid=" + encodeURIComponent(steamA) + "&act=claim_event:1"
  await fetch(trustUrl)
  const queuedTrusted = trusted.first(
    `SELECT COUNT(*) AS n FROM actions WHERE steamid=?1 AND type='claim_event'`, steamA)
  check("trusted deployment queues the claim", Number(queuedTrusted.n) === 1, "rows=" + queuedTrusted.n)

  // ------------------------------------------------ 6. referrer policy ----
  const withToken = await fetch(panel.base + "/events?steamid=" + encodeURIComponent(steamA) + "&t=" + trustToken)
  check("token URL sends no-referrer", withToken.headers.get("referrer-policy") === "no-referrer",
    String(withToken.headers.get("referrer-policy")))
  const withoutToken = await fetch(panel.base + "/events")
  check("plain page sends no referrer policy",
    !withoutToken.headers.get("referrer-policy"), String(withoutToken.headers.get("referrer-policy")))

  // ------------------------------------------------------- 7. unit checks ----
  const batchDb = join(root, "batch.sq3")
  const local = openLocalD1(batchDb)
  local.raw.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)")
  let threw = false
  try {
    await local.batch([
      local.prepare("INSERT INTO t (id, v) VALUES (1, 'a')"),
      local.prepare("INSERT INTO t (id, v) VALUES (2, 'b')"),
      local.prepare("INSERT INTO t (id, v) VALUES ('not-an-int', 'c')"),
    ])
  } catch { threw = true }
  const left = local.raw.prepare("SELECT COUNT(*) AS n FROM t").get()
  check("failing batch throws", threw)
  check("failing batch rolls back", Number(left.n) === 0, "rows=" + left.n)
  local.raw.close()

  const positive = Object.values(PREMIUM_COINS).filter(v => v > 0).length
  check("premium table covers most tiers", positive >= 30, positive + "/60 tiers")
  check("premiumExtraCoins(1) is the server value", premiumExtraCoins(1) === 150, String(premiumExtraCoins(1)))
  check("premiumExtraCoins(50) is the server value", premiumExtraCoins(50) === 1950, String(premiumExtraCoins(50)))
  check("premiumExtraCoins(4) is 0 (item tier)", premiumExtraCoins(4) === 0, String(premiumExtraCoins(4)))
  check("premiumExtraCoins out of range is 0", premiumExtraCoins(0) === 0 && premiumExtraCoins(61) === 0)
  check("premiumCoins matches the table", premiumCoins(50) === 1950, String(premiumCoins(50)))
  check("xpPerTier follows the track", xpPerTier({ xp_per_tier: 2500 }) === 2500)
  check("xpPerTier falls back to 1000", xpPerTier(null) === 1000, String(xpPerTier(null)))

  // BP tier curve (bp_track.js is the single source): tier 1 covers [0, need).
  check("bpTierFromXp(0) is tier 1", bpTierFromXp(0, 1000) === 1, String(bpTierFromXp(0, 1000)))
  check("bpTierFromXp(999) is tier 1", bpTierFromXp(999, 1000) === 1, String(bpTierFromXp(999, 1000)))
  check("bpTierFromXp(1000) is tier 2", bpTierFromXp(1000, 1000) === 2, String(bpTierFromXp(1000, 1000)))
  check("bpTierFromXp(1500) is tier 2", bpTierFromXp(1500, 1000) === 2, String(bpTierFromXp(1500, 1000)))
  check("bpTierFromXp(59000) is tier 60", bpTierFromXp(59000, 1000) === 60, String(bpTierFromXp(59000, 1000)))
  check("bpTierFromXp caps at tier 60", bpTierFromXp(999999, 1000) === BP_MAX_TIER, String(bpTierFromXp(999999, 1000)))
  check("bpTierFromXp survives null/undefined", bpTierFromXp(null, 1000) === 1 && bpTierFromXp(undefined, 1000) === 1)
  check("bpTierFromXp follows a non-default curve", bpTierFromXp(2500, 2500) === 2, String(bpTierFromXp(2500, 2500)))
  check("bpInto(1500, 1000) is 500", bpInto(1500, 1000) === 500, String(bpInto(1500, 1000)))
  check("bpInto(0) is 0", bpInto(0, 1000) === 0)
  check("playerBpTier prefers the stored tier", playerBpTier({ bp_xp: 0, bp_tier: 7 }, 1000) === 7)
  check("playerBpTier derives from bp_xp", playerBpTier({ bp_xp: 2000, bp_tier: 0 }, 1000) === 3, String(playerBpTier({ bp_xp: 2000, bp_tier: 0 }, 1000)))
  check("playerBpTier ignores rank xp/level",
    playerBpTier({ xp: 59000, level: 52, bp_xp: 0, bp_tier: 0 }, 1000) === 1,
    String(playerBpTier({ xp: 59000, level: 52, bp_xp: 0, bp_tier: 0 }, 1000)))

  // ============================================ 8. public JSON API =========
  // /api/public/* is unauthenticated and read-only: shape, 404s, and the
  // promise that it leaks no personal state.
  const jget = async (path) => {
    const res = await fetch(panel.base + path)
    let body = null
    try { body = await res.json() } catch {}
    return { res, body, headers: res.headers }
  }

  const st0 = await jget("/api/public/status")
  check("status 200", st0.res.status === 200, "-> " + st0.res.status)
  check("status is no-store", st0.headers.get("cache-control") === "no-store",
    String(st0.headers.get("cache-control")))
  check("status has server/events/updated",
    Boolean(st0.body && st0.body.server && st0.body.events && st0.body.updated))
  check("status keeps player count honest before a live push",
    st0.body.server.players === null || typeof st0.body.server.players === "number",
    "players=" + JSON.stringify(st0.body.server.players))

  // The game's own signed push is the only source of a live count.
  const liveTs = Math.floor(Date.now() / 1000)
  const livePush = await push(panel, {
    server: { map: "de_dust2", hostname: "Harness Server", players: 5, humans: 5, maxplayers: 32, hh: 0 },
    players: [],
  })
  check("server meta push accepted", livePush.status === 200, "-> " + livePush.status)
  const st1 = await jget("/api/public/status")
  check("status reports the pushed player count", st1.body.server.players === 5,
    "players=" + JSON.stringify(st1.body.server.players))
  check("status reports the slot count", st1.body.server.max === 32, "max=" + JSON.stringify(st1.body.server.max))
  check("status reports the pushed map", st1.body.server.map === "de_dust2", String(st1.body.server.map))
  check("status marks a fresh push live", st1.body.server.stale === false && st1.body.server.online === true,
    `stale=${st1.body.server.stale} online=${st1.body.server.online}`)

  // An old push must turn the count back into null, never into a stale number.
  const metaWriter = new DatabaseSync(panel.dbFile)
  try {
    metaWriter.prepare(`UPDATE meta SET value=?2 WHERE key=?1`).run("last_push", String(liveTs - 600))
  } finally { metaWriter.close() }
  const stOld = await jget("/api/public/status")
  check("a stale push reports players as null", stOld.body.server.players === null,
    "players=" + JSON.stringify(stOld.body.server.players))
  check("a stale push is flagged", stOld.body.server.stale === true, String(stOld.body.server.stale))
  await push(panel, { server: { map: "cs_office", hostname: "Harness Server", players: 3, humans: 3, maxplayers: 32 }, players: [] })

  const topAll = await jget("/api/public/top?period=all&limit=2")
  check("top all 200", topAll.res.status === 200, "-> " + topAll.res.status)
  check("top all honours limit", Array.isArray(topAll.body.rows) && topAll.body.rows.length === 2,
    "rows=" + (topAll.body.rows || []).length)
  check("top all is ordered by xp", topAll.body.rows[0].value >= topAll.body.rows[1].value,
    `${topAll.body.rows[0].value} >= ${topAll.body.rows[1].value}`)
  check("top rows carry name/value/metric/period",
    ["name", "value", "metric", "period"].every(k => k in topAll.body.rows[0]),
    Object.keys(topAll.body.rows[0]).join(","))

  const badPeriod = await jget("/api/public/top?period=decade")
  check("top rejects an unknown period with 400", badPeriod.res.status === 400, "-> " + badPeriod.res.status)
  check("top 400 explains the allowed periods",
    badPeriod.body && badPeriod.body.error === "bad_period" && Array.isArray(badPeriod.body.allowed),
    JSON.stringify(badPeriod.body && badPeriod.body.error))

  const killBoard = await jget("/api/public/top?period=all&metric=kills&limit=3")
  check("top supports metric=kills", killBoard.res.status === 200 && killBoard.body.metric === "kills" &&
    (killBoard.body.rows.length === 0 || killBoard.body.rows.every(r => r.metric === "kills")),
    `${killBoard.res.status} ${killBoard.body && killBoard.body.metric}`)

  const weekNow = Math.floor(Date.now() / 1000)
  const topWeek = await jget("/api/public/top?period=week&limit=5")
  check("top week 200", topWeek.res.status === 200, "-> " + topWeek.res.status)
  check("top week uses the Europe/Paris ISO week", topWeek.body.window.key === weekKeyAt(weekNow),
    `${topWeek.body.window.key} vs ${weekKeyAt(weekNow)}`)
  check("top week publishes its window bounds",
    topWeek.body.window.tz === "Europe/Paris" &&
    topWeek.body.window.start === periodBounds("week", weekNow).start &&
    topWeek.body.window.end === periodBounds("week", weekNow).end,
    JSON.stringify(topWeek.body.window))
  check("top week publishes coverage instead of pretending completeness",
    topWeek.body.coverage && typeof topWeek.body.coverage.complete === "boolean",
    JSON.stringify(topWeek.body.coverage))
  const topMonth = await jget("/api/public/top?period=month&limit=5")
  check("top month uses the calendar month", topMonth.body.window.key === monthKeyAt(weekNow),
    `${topMonth.body.window.key} vs ${monthKeyAt(weekNow)}`)

  // The website board and the API board must show the same window and the same
  // numbers: one boundary implementation, no second opinion.
  const siteWeek = await fetch(panel.base + "/top/week")
  const siteWeekBody = await siteWeek.text()
  check("the site has a weekly board", siteWeek.status === 200, "-> " + siteWeek.status)
  check("the site's weekly board names the same period key the API returns",
    siteWeekBody.includes(weekKeyAt(weekNow)), weekKeyAt(weekNow))
  const siteMonth = await fetch(panel.base + "/top/month")
  check("the site has a monthly board", siteMonth.status === 200, "-> " + siteMonth.status)
  const apiWeekRows = (await jget("/api/public/top?period=week&limit=15")).body.rows
  check("the site board and the API board agree row for row",
    apiWeekRows.every(r => siteWeekBody.includes(r.name || r.steamid)),
    apiWeekRows.map(r => r.name).join(","))

  const meApi = await jget("/api/public/player/0-0-101")
  check("player 200 for the packed form", meApi.res.status === 200, "-> " + meApi.res.status)
  check("player answers the canonical steamid", meApi.body.steamid === "STEAM_0:0:101", String(meApi.body.steamid))
  check("player carries the documented fields",
    ["name", "rank", "bp_tier", "bp_xp", "bp_next_xp", "coins", "playtime_minutes", "badges"].every(k => k in meApi.body),
    Object.keys(meApi.body).join(","))
  check("player leaks no personal state",
    !("last_seen" in meApi.body) && !("cc" in meApi.body) && !("server_id" in meApi.body) &&
    !JSON.stringify(meApi.body).includes("192.0.2."),
    Object.keys(meApi.body).join(","))
  const colonPlayer = await jget("/api/public/player/" + encodeURIComponent("STEAM_0:0:101"))
  check("player accepts the colon form", colonPlayer.res.status === 200 && colonPlayer.body.steamid === "STEAM_0:0:101",
    "-> " + colonPlayer.res.status)

  const missing = await jget("/api/public/player/0-0-9999999")
  check("unknown player 404", missing.res.status === 404, "-> " + missing.res.status)
  check("unknown player 404 shape", missing.body.error === "player_not_found" && missing.body.steamid === "STEAM_0:0:9999999",
    JSON.stringify(missing.body))
  const badSid = await jget("/api/public/player/not-a-steamid")
  check("malformed steamid 400", badSid.res.status === 400 && badSid.body.error === "bad_steamid",
    "-> " + badSid.res.status)
  check("normalizeSteamid round-trips both forms",
    normalizeSteamid("0-0-101") === "STEAM_0:0:101" &&
    normalizeSteamid("STEAM_0:0:101") === "STEAM_0:0:101" &&
    normalizeSteamid("nope") === "")

  // Events: the panel schedule. The detail column is added lazily on first
  // read, so an older replica gains it without a manual migration.
  const evEmpty = await jget("/api/public/events")
  check("events 200", evEmpty.res.status === 200, "-> " + evEmpty.res.status)
  check("events declares the panel as its source", evEmpty.body.source === "panel", String(evEmpty.body.source))
  const evWriter = new DatabaseSync(panel.dbFile)
  let evId = 0
  try {
    const info = evWriter.prepare(
      `INSERT INTO events (title, type, status, start_at, end_at, xp_mult, coins_mult)
       VALUES (?1,'xp_mult','active',?2,?3,2,1)`
    ).run("Harness Double XP", liveTs - 600, liveTs + 3600)
    evId = Number(info.lastInsertRowid)
  } finally { evWriter.close() }
  const evOne = await jget("/api/public/events")
  const rowEv = (evOne.body.events || []).find(e => e.title === "Harness Double XP")
  check("events lists an active event", Boolean(rowEv) && rowEv.state === "active",
    JSON.stringify(rowEv))
  check("events exposes title/starts_at/ends_at/detail/state",
    rowEv && ["title", "starts_at", "ends_at", "detail", "state"].every(k => k in rowEv),
    rowEv ? Object.keys(rowEv).join(",") : "missing")
  check("a live event appears in status.events.now",
    (await jget("/api/public/status")).body.events.now.some(e => e.title === "Harness Double XP"))
  const detailWriter = new DatabaseSync(panel.dbFile)
  let hasDetailCol = false
  try {
    hasDetailCol = detailWriter.prepare(`PRAGMA table_info(events)`).all().some(c => c.name === "detail")
    detailWriter.prepare(`UPDATE events SET detail=?2 WHERE id=?1`).run(evId, "2x XP on every kill.")
  } finally { detailWriter.close() }
  check("events.detail is added lazily to an older replica", hasDetailCol)

  const evList = await jget("/api/public/events")
  check("events 404s an unknown sub-path", (await jget("/api/public/nope")).res.status === 404)
  check("no public response leaks a secret", !JSON.stringify([st1.body, topAll.body, meApi.body, evList.body]).includes(SECRET))

  const counted = await fetch(limited.base + "/api/public/status")
  await fetch(limited.base + "/api/public/status")
  const overLimit = await fetch(limited.base + "/api/public/status")
  check("public API rate-limits a poll loop", counted.status === 200 && overLimit.status === 429,
    `${counted.status} then ${overLimit.status}`)
  const limitBody = await overLimit.json().catch(() => ({}))
  check("rate-limit answer is JSON", limitBody.error === "rate_limited", JSON.stringify(limitBody.error))

  // ================================================ 9. MOTD v2 pages =======
  const motdPages = [
    "/m/p/0-0-101.htm",
    "/m/i/0-0-101/daily.htm",
    "/m/i/0-0-101/weekly.htm",
    "/m/i/0-0-101/completed.htm",
    "/m/b/0-0-101/battlepass.htm",
    "/m/t/0-0-101/top15.htm",
    "/m/t/0-0-101/week.htm",
    "/m/t/0-0-101/month.htm",
    "/m/e/0-0-101/events.htm",
    "/m/p/0-0-9999999.htm",       // player the panel has never seen
    "/m/p/0-0-101",               // .htm optional
  ]
  const FORBIDDEN = ["<script", "<img", "<link", "<iframe", "display:flex", "display: flex",
    "display:grid", "display: grid", "var(", "NaN", "undefined", "&amp;middot;"]
  for (const p of motdPages) {
    const res = await fetch(panel.base + p)
    const body = await res.text()
    const badWords = FORBIDDEN.filter(w => body.includes(w))
    check(`motd ${p} renders`, res.status === 200, "-> " + res.status)
    check(`motd ${p} is a self-contained MSIE-safe document`, badWords.length === 0, badWords.join(","))
    check(`motd ${p} carries noindex + no-referrer`,
      res.headers.get("x-robots-tag") === "noindex" && res.headers.get("referrer-policy") === "no-referrer",
      `${res.headers.get("x-robots-tag")} / ${res.headers.get("referrer-policy")}`)
    check(`motd ${p} tells the player what to type`, body.includes("!missions"))
  }
  const profPage = await (await fetch(panel.base + "/m/p/0-0-101.htm")).text()
  check("motd header shows the player name", profPage.includes("harness-101"))
  check("motd header shows the BP tier and the coin balance",
    profPage.includes("TIER 1/60") && profPage.includes("coins"), "tier/coins strip present")

  // A player row with every counter at zero (the most common first impression).
  const steamFresh = "STEAM_0:0:909"
  await push(panel, { players: [player(steamFresh, { xp: 0, bp_xp: 0, bp_tier: 0, coins: 0, last_seen: Math.floor(Date.now() / 1000) })] })
  const freshPage = await (await fetch(panel.base + "/m/p/0-0-909.htm")).text()
  check("a zero-data player renders tier 1", freshPage.includes("TIER 1/60"))
  check("a zero-data player is unranked, not rank 0", freshPage.includes("Unranked"))
  check("a zero-data player page is free of NaN/undefined",
    !freshPage.includes("NaN") && !freshPage.includes("undefined"))
  const freshJson = await (await fetch(panel.base + "/api/public/player/0-0-909")).json()
  check("a zero-data player has rank null in the API", freshJson.rank === null, String(freshJson.rank))
  check("a zero-data player has tier 1 and 0 XP in the API",
    freshJson.bp_tier === 1 && freshJson.bp_xp === 0, `${freshJson.bp_tier} / ${freshJson.bp_xp}`)
  check("a zero-data player asks the next tier for a full bar",
    freshJson.bp_next_xp === freshJson.bp_tier_xp, `${freshJson.bp_next_xp} / ${freshJson.bp_tier_xp}`)

  // Badges reach the MOTD header and /api/public/player.
  const badgeWriter = new DatabaseSync(panel.dbFile)
  try {
    badgeWriter.prepare(
      `INSERT OR IGNORE INTO badges (steamid, kind, period, label, awarded_at) VALUES (?1,?2,?3,?4,?5)`
    ).run(steamA, "weekly_champion", "2026-W45", "Weekly #1 · Week 45 · 2026", liveTs)
  } finally { badgeWriter.close() }
  const badgedPage = await (await fetch(panel.base + "/m/p/0-0-101.htm")).text()
  check("a badge is drawn as text in the MOTD header", badgedPage.includes("Weekly #1"))
  const badgedApi = await (await fetch(panel.base + "/api/public/player/0-0-101")).json()
  check("a badge is exposed by /api/public/player",
    Array.isArray(badgedApi.badges) && badgedApi.badges.some(b => b.kind === "weekly_champion" && b.label.includes("Weekly #1")),
    JSON.stringify(badgedApi.badges))
  check("badges are text only (no client content)",
    badgedApi.badges.every(b => !/[<>]/.test(b.label) && Object.keys(b).sort().join(",") === "kind,label,period"),
    JSON.stringify(badgedApi.badges[0]))

  // Existing MOTD contract: the documented redirects and 404s still hold.
  const redirMissions = await fetch(panel.base + "/m/b/0-0-101/missions.htm", { redirect: "manual" })
  check("/m/b/*/missions still 302s to /m/i/", redirMissions.status === 302 &&
    redirMissions.headers.get("location") === "/m/i/0-0-101/daily.htm",
    `${redirMissions.status} ${redirMissions.headers.get("location")}`)
  const goneS = await fetch(panel.base + "/m/s/0-0-1/x.htm", { redirect: "manual" })
  check("/m/s/ is still 404", goneS.status === 404, "-> " + goneS.status)

  // The degradation path: no DB, no theme, no snapshot — still a useful page.
  const fb = renderFallback("test: database unavailable", { FN_PUBLIC_ADDR: "example.invalid:27015" })
  const fbBody = await fb.text()
  check("the static fallback is HTTP 200", fb.status === 200, "-> " + fb.status)
  check("the static fallback names the server", fbBody.includes("example.invalid:27015"))
  check("the static fallback tells the player what to type", fbBody.includes("!missions") && fbBody.includes("!bp"))
  check("the static fallback is self-contained",
    !/<script|<img|<link|<iframe/i.test(fbBody) && !fbBody.includes("var(") && !fbBody.includes("display:flex"),
    "no external resource")

  // ================================= 10. Europe/Paris period arithmetic ===
  const at = s => Math.floor(Date.parse(s) / 1000)
  const iso = s => new Date(s * 1000).toISOString()
  const w47 = periodBounds("week", at("2026-11-22T21:00:00Z"))
  check("week boundary is Monday 00:00 Europe/Paris", w47.key === "2026-W47" &&
    iso(w47.start) === "2026-11-15T23:00:00.000Z" && iso(w47.end) === "2026-11-22T23:00:00.000Z",
    `${w47.key} ${iso(w47.start)}..${iso(w47.end)}`)
  check("a Sunday 23:30 Paris instant is still the previous ISO week",
    weekKeyAt(at("2026-11-22T23:30:00Z")) === "2026-W48",
    weekKeyAt(at("2026-11-22T23:30:00Z")))
  check("DST start does not shift the week boundary",
    iso(periodBounds("week", at("2026-03-30T12:00:00Z")).start) === "2026-03-29T22:00:00.000Z",
    iso(periodBounds("week", at("2026-03-30T12:00:00Z")).start))
  check("DST end does not shift the week boundary",
    iso(periodBounds("week", at("2026-10-28T12:00:00Z")).start) === "2026-10-25T23:00:00.000Z",
    iso(periodBounds("week", at("2026-10-28T12:00:00Z")).start))
  check("ISO week-year edge (2026-12-31 is 2026-W53)",
    weekKeyAt(at("2026-12-31T23:30:00Z")) === "2026-W53" && weekKeyAt(at("2027-01-01T10:00:00Z")) === "2026-W53",
    `${weekKeyAt(at("2026-12-31T23:30:00Z"))} / ${weekKeyAt(at("2027-01-01T10:00:00Z"))}`)
  const nov = periodBounds("month", at("2026-11-30T23:30:00Z"))
  check("the month boundary is the 1st 00:00 Europe/Paris", nov.key === "2026-12" &&
    iso(nov.start) === "2026-11-30T23:00:00.000Z", `${nov.key} ${iso(nov.start)}`)
  check("a Paris November instant stays in November",
    monthKeyAt(at("2026-11-30T22:59:00Z")) === "2026-11" &&
    iso(periodBounds("month", at("2026-11-30T22:59:00Z")).end) === "2026-11-30T23:00:00.000Z",
    monthKeyAt(at("2026-11-30T22:59:00Z")))
  check("parisMidnight is DST-aware",
    iso(parisMidnight(2026, 3, 30)) === "2026-03-29T22:00:00.000Z" &&
    iso(parisMidnight(2026, 10, 26)) === "2026-10-25T23:00:00.000Z",
    `${iso(parisMidnight(2026, 3, 30))} / ${iso(parisMidnight(2026, 10, 26))}`)
  check("isoWeekOf follows the Thursday rule", isoWeekOf(2026, 1, 1).week === 1 && isoWeekOf(2025, 12, 29).year === 2026,
    JSON.stringify(isoWeekOf(2025, 12, 29)))
  check("previousKey walks back one period",
    previousKey("week", at("2026-11-22T21:00:00Z")) === "2026-W46" &&
    previousKey("month", at("2026-11-22T21:00:00Z")) === "2026-10",
    `${previousKey("week", at("2026-11-22T21:00:00Z"))} / ${previousKey("month", at("2026-11-22T21:00:00Z"))}`)
  check("keysBefore skips nothing across a year boundary",
    keysBefore("week", "2026-W01", at("2026-01-10T12:00:00Z"), 2).join(",") === "2025-W52,2025-W51",
    keysBefore("week", "2026-W01", at("2026-01-10T12:00:00Z"), 2).join(","))

  // ==================================== 11. boards, rollover, badges ======
  // A disposable database, so the rollover can be driven straight past a
  // boundary without waiting for a real Monday.
  const boardDb = join(root, "boards.sq3")
  const bd = openLocalD1(boardDb)
  // Minimal players table: the boards read steamid/name/xp(/kills) only.
  bd.raw.exec(`CREATE TABLE IF NOT EXISTS players (
    steamid TEXT PRIMARY KEY, name TEXT NOT NULL DEFAULT '', xp INTEGER NOT NULL DEFAULT 0,
    kills INTEGER NOT NULL DEFAULT 0, coins INTEGER NOT NULL DEFAULT 0,
    last_seen INTEGER NOT NULL DEFAULT 0)`)
  bd.raw.exec(`CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL DEFAULT '')`)
  const bEnv = { DB: bd }
  check("board tables are created on demand", await ensureBoardTables(bEnv) === true)
  const bNow = Math.floor(Date.now() / 1000)
  const bPrev = previousKey("week", bNow)
  const insPlayer = (sid, name, xp) => bd.raw.prepare(
    `INSERT INTO players (steamid, name, xp, coins, last_seen) VALUES (?,?,?,0,?)`
  ).run(sid, name, xp, bNow)
  insPlayer("STEAM_0:0:501", "alpha", 1000)
  insPlayer("STEAM_0:0:502", "bravo", 2000)
  insPlayer("STEAM_0:0:503", "charlie", 0)

  await refreshMarks(bEnv, bNow, { force: true })
  const baseRow = bd.raw.prepare(
    `SELECT base, last_value FROM board_marks WHERE period='week' AND metric='xp' AND steamid='STEAM_0:0:501'`
  ).get()
  check("the first read inside a period records the baseline", Number(baseRow.base) === 1000, JSON.stringify(baseRow))

  bd.raw.prepare(`UPDATE players SET xp=1400 WHERE steamid='STEAM_0:0:501'`).run()
  bd.raw.prepare(`UPDATE players SET xp=2100 WHERE steamid='STEAM_0:0:502'`).run()
  await refreshMarks(bEnv, bNow, { force: true })
  const wBoard = await periodBoard(bEnv, { period: "week", limit: 10, now: bNow })
  check("the weekly board shows the period delta, not lifetime xp",
    wBoard.rows[0].value === 400 && wBoard.rows[1].value === 100,
    JSON.stringify(wBoard.rows.map(r => [r.name, r.value])))
  check("a player with no progress this period is not listed",
    !wBoard.rows.some(r => r.steamid === "STEAM_0:0:503"), JSON.stringify(wBoard.rows.map(r => r.steamid)))
  check("the weekly board ranks by value", wBoard.rows[0].rank === 1 && wBoard.rows[0].name === "alpha",
    JSON.stringify(wBoard.rows[0]))
  check("the board reports its coverage honestly", wBoard.coverage.complete === false &&
    wBoard.coverage.observed_players === 3, JSON.stringify(wBoard.coverage))

  const stand = await playerPeriodStanding(bEnv, "STEAM_0:0:502", { period: "week", now: bNow })
  check("own weekly standing counts the gap to the player above",
    stand.rank === 2 && stand.behind === 300 && stand.ahead.name === "alpha", JSON.stringify(stand))
  const lifeStand = await playerLifetimeStanding(bEnv, { xp: 2100 })
  check("own lifetime standing is exact", lifeStand.rank === 1 && lifeStand.ahead === null, JSON.stringify(lifeStand))
  const zeroStand = await playerLifetimeStanding(bEnv, { xp: 0 })
  check("a player with 0 xp has no rank", zeroStand.rank === null, JSON.stringify(zeroStand))

  // Settle last week: a baseline recorded then, snapshotted after the boundary.
  const insMark = (sid, key, base, last, first) => bd.raw.prepare(
    `INSERT OR REPLACE INTO board_marks (period, period_key, steamid, metric, base, last_value, first_seen, seen_at)
     VALUES ('week', ?, ?, 'xp', ?, ?, ?, ?)`
  ).run(key, sid, base, last, first, first)
  const weekStart = periodBounds("week", bNow).start - 1
  insMark("STEAM_0:0:501", bPrev, 0, 5000, weekStart - 7 * 86400)
  insMark("STEAM_0:0:502", bPrev, 0, 3000, weekStart - 7 * 86400)
  insMark("STEAM_0:0:503", bPrev, 0, 1000, weekStart - 7 * 86400)

  const roll1 = await maybeRollover(bEnv, bNow)
  check("the first rollover only records where we are", roll1.settled.length === 0 &&
    bd.raw.prepare(`SELECT COUNT(*) AS n FROM board_history`).get().n === 0, JSON.stringify(roll1))

  bd.raw.prepare(`UPDATE meta SET value=?1 WHERE key='board_settled:week'`).run(bPrev)
  const roll2 = await maybeRollover(bEnv, bNow)
  const hist = bd.raw.prepare(`SELECT rank, steamid, name, value FROM board_history WHERE period='week' ORDER BY rank`).all()
  check("a finished week is snapshotted into board_history", hist.length === 3, JSON.stringify(hist))
  check("the snapshot keeps the winner in order", hist[0].steamid === "STEAM_0:0:501" && hist[0].value === 5000,
    JSON.stringify(hist[0]))
  check("rollover awards the weekly champion badge",
    bd.raw.prepare(`SELECT COUNT(*) AS n FROM badges WHERE kind='weekly_champion' AND period=?1`).get(bPrev).n === 1,
    bPrev)
  check("rollover awards top-3 badges for the podium",
    bd.raw.prepare(`SELECT COUNT(*) AS n FROM badges WHERE kind='weekly_top3' AND period=?1`).get(bPrev).n === 3)
  const roll3 = await maybeRollover(bEnv, bNow)
  check("a second rollover is a no-op (idempotent)", roll3.settled.length === 0 &&
    bd.raw.prepare(`SELECT COUNT(*) AS n FROM board_history`).get().n === 3, JSON.stringify(roll3))

  // Three weeks running for the same name.
  const wk2 = previousKey("week", weekStart - 1)
  const wk3 = previousKey("week", weekStart - 8 * 86400)
  for (const k of [wk2, wk3]) insMark("STEAM_0:0:501", k, 0, 1000, weekStart - 21 * 86400)
  for (const k of [wk2, wk3]) insMark("STEAM_0:0:502", k, 0, 500, weekStart - 21 * 86400)
  await settlePeriod(bEnv, "week", wk3, bNow)
  await settlePeriod(bEnv, "week", wk2, bNow)
  await settlePeriod(bEnv, "week", bPrev, bNow)
  check("top 3 three weeks running is awarded once per player",
    bd.raw.prepare(`SELECT COUNT(*) AS n FROM badges WHERE kind='weekly_streak3'`).get().n === 2 &&
    bd.raw.prepare(`SELECT COUNT(*) AS n FROM badges WHERE kind='weekly_streak3' AND steamid='STEAM_0:0:501'`).get().n === 1,
    JSON.stringify(bd.raw.prepare(`SELECT steamid, period FROM badges WHERE kind='weekly_streak3'`).all()))
  check("badges are readable per player",
    (await playerBadges(bEnv, "STEAM_0:0:501")).some(b => b.kind === "weekly_champion"))
  check("a player with no badges gets an empty list",
    (await playerBadges(bEnv, "STEAM_0:0:999")).length === 0)
  check("the lifetime board reads the players table",
    (await lifetimeBoard(bEnv, { limit: 5 })).rows[0].steamid === "STEAM_0:0:502",
    JSON.stringify((await lifetimeBoard(bEnv, { limit: 5 })).rows.map(r => [r.name, r.value])))
  check("countdown text is server-side plain text",
    countdownText({ state: "active", starts_at: 0, ends_at: bNow + 7200 }, bNow) === "ends in 2h",
    countdownText({ state: "active", starts_at: 0, ends_at: bNow + 7200 }, bNow))
  bd.raw.close()

  // ===================== 12. Winterfest data layer (the panel foundation) ======
  // docs/panel/00-CONTRACT.md §Layers. A disposable database, driven through exactly
  // the API the page layer and the game will call: queueAction → applyAction →
  // getPlayer, the ledger, the refusals, and the two game endpoints. A state table
  // is only touched directly where the test has to prove a guard (a hand-written
  // row, a legacy table).
  const sd = openLocalD1(join(root, "state.sq3"))
  // The base players table normally comes from schema.sql; openLocalD1 only
  // migrates it. Only the columns the layer reads are needed here.
  sd.raw.exec(`CREATE TABLE IF NOT EXISTS players (
      steamid TEXT PRIMARY KEY, name TEXT NOT NULL DEFAULT '', xp INTEGER NOT NULL DEFAULT 0,
      level INTEGER NOT NULL DEFAULT 1, kills INTEGER NOT NULL DEFAULT 0,
      coins INTEGER NOT NULL DEFAULT 0, last_seen INTEGER NOT NULL DEFAULT 0)`)
  const sEnv = { DB: sd }
  const SID = "STEAM_0:0:701"

  check("the state tables are created on demand", (await ensureStateSchema(sd)) === true)
  const sCols = sd.raw.prepare("PRAGMA table_info(winter_players)").all().map(r => r.name)
  check("winter_players has the columns the contract asks for",
    ["spins", "pass_xp", "pass_tier", "premium", "tree_level"].every(c => sCols.includes(c)),
    sCols.join(","))

  // A live table from before the contract: no spins/pass_xp/pass_tier/premium.
  const legacyFile = join(root, "legacy-winter.sq3")
  const legacy = openLocalD1(legacyFile)
  legacy.raw.exec(`CREATE TABLE winter_players (
      steamid TEXT PRIMARY KEY, season TEXT NOT NULL DEFAULT '',
      snowflakes INTEGER NOT NULL DEFAULT 0, gifts_found INTEGER NOT NULL DEFAULT 0,
      tree_style INTEGER NOT NULL DEFAULT 1, ornaments_total INTEGER NOT NULL DEFAULT 0,
      advent_claimed INTEGER NOT NULL DEFAULT 0, seen_at INTEGER NOT NULL DEFAULT 0)`)
  legacy.raw.prepare(`INSERT INTO winter_players (steamid, snowflakes) VALUES ('STEAM_0:0:702', 40)`).run()
  await ensureStateSchema(legacy)
  // A SECOND handle over the same file runs the migration again from scratch: the
  // PRAGMA guard, not a comment, is what stops "duplicate column name".
  const legacy2 = openLocalD1(legacyFile)
  let legacyOk = true
  let legacyErr = ""
  try { await ensureStateSchema(legacy2) } catch (e) { legacyOk = false; legacyErr = String(e && e.message) }
  const lCols = legacy2.raw.prepare("PRAGMA table_info(winter_players)").all().map(r => r.name)
  check("the guarded ALTER upgrades a live winter_players and is safe to run twice",
    legacyOk && lCols.includes("spins") && lCols.includes("pass_xp") &&
    lCols.includes("pass_tier") && lCols.includes("premium"), legacyErr || lCols.join(","))
  check("the guarded ALTER keeps the live row it upgraded",
    legacy2.raw.prepare(`SELECT snowflakes FROM winter_players WHERE steamid='STEAM_0:0:702'`).get().snowflakes === 40)
  legacy.raw.close()
  legacy2.raw.close()

  // ---------------------------------------------- queue → apply → balances ----
  const claim1 = await queueAction(sEnv.DB, {
    steamid: SID, kind: "claim_mission", payload: { mission: 12, coins: 100, gingerbread: 25 }, now: 1000,
  })
  check("queueAction inserts a pending row", claim1.created === true && claim1.action.state === "pending",
    JSON.stringify(claim1.action))
  const claimDup = await queueAction(sEnv.DB, {
    steamid: SID, kind: "claim_mission", payload: { mission: 12, coins: 100, gingerbread: 25 }, now: 1001,
  })
  check("double-queue returns the row that already exists",
    claimDup.created === false && claimDup.action.id === claim1.action.id,
    `${claimDup.created} / ${claimDup.action.id}`)
  check("the queue holds exactly one row after a double submit",
    sd.raw.prepare(`SELECT COUNT(*) AS n FROM winter_actions WHERE steamid=?1`).get(SID).n === 1)

  const applied1 = await applyAction(sEnv.DB, claim1.action.id, { now: 1100 })
  check("applyAction applies the claim and returns the new balances",
    applied1.ok && applied1.state === "applied" && applied1.balances.coins === 100 &&
    applied1.balances.gingerbread === 25, JSON.stringify(applied1))
  const p1 = await getPlayer(sEnv.DB, SID)
  check("the claim paid coins and gingerbread",
    p1.coins === 100 && p1.gingerbread === 25, `coins=${p1.coins} gingerbread=${p1.gingerbread}`)
  const led1 = sd.raw.prepare(
    `SELECT currency, delta, balance_after, reason, ref FROM winter_ledger WHERE steamid=?1 ORDER BY id`).all(SID)
  check("every currency change wrote a ledger row with balance_after",
    led1.length === 2 && led1[0].currency === "coins" && led1[0].balance_after === 100 &&
    led1[0].delta === 100 && led1[0].reason === "claim_mission" && led1[0].ref === "mission:12" &&
    led1[1].currency === "gingerbread" && led1[1].balance_after === 25, JSON.stringify(led1))

  const rebG = await rebuildBalance(sEnv.DB, SID, "gingerbread")
  check("a ledger balance rebuild reproduces the stored balance",
    rebG.stored === 25 && rebG.ledger === 25 && rebG.repaired === false, JSON.stringify(rebG))
  sd.raw.prepare(`UPDATE winter_players SET snowflakes=99 WHERE steamid=?1`).run(SID)
  const fixed = await rebuildBalance(sEnv.DB, SID, "gingerbread", { repair: true, now: 1200 })
  check("the ledger wins a disagreement and the repair puts the balance back",
    fixed.repaired === true && fixed.stored_before === 99 && fixed.ledger === 25 &&
    (await getPlayer(sEnv.DB, SID)).gingerbread === 25 &&
    (await ledgerBalance(sEnv.DB, SID, "gingerbread")) === 25, JSON.stringify(fixed))

  const ledgerCount = sd.raw.prepare(`SELECT COUNT(*) AS n FROM winter_ledger WHERE steamid=?1`).get(SID).n
  const retry = await applyAction(sEnv.DB, claim1.action.id, { now: 1300 })
  check("a retried claim pays once",
    retry.ok && retry.already === true &&
    sd.raw.prepare(`SELECT COUNT(*) AS n FROM winter_ledger WHERE steamid=?1`).get(SID).n === ledgerCount,
    JSON.stringify(retry))
  const reClaim = await queueAction(sEnv.DB, {
    steamid: SID, kind: "claim_mission", payload: { mission: 12, coins: 100, gingerbread: 25 },
  })
  check("a re-queued claim answers with the applied row instead of a new one",
    reClaim.created === false && reClaim.action.id === claim1.action.id && reClaim.action.state === "applied",
    JSON.stringify(reClaim.action))

  // ------------------------------------------------------------- refusals ----
  const bogus = sd.raw.prepare(
    `INSERT INTO winter_actions (steamid, kind, payload, state, idem, created_at)
     VALUES (?1, 'mystery', '{}', 'pending', 'mystery:1', 1400)`).run(SID)
  const beforeBogus = await balancesOf(sEnv.DB, SID)
  const bogusRes = await applyAction(sEnv.DB, Number(bogus.lastInsertRowid), { now: 1400 })
  const afterBogus = await balancesOf(sEnv.DB, SID)
  check("applying an unknown kind is refused and leaves the balances untouched",
    bogusRes.ok === false && bogusRes.state === "refused" && /unknown kind/.test(bogusRes.error) &&
    beforeBogus.coins === afterBogus.coins && beforeBogus.gingerbread === afterBogus.gingerbread,
    JSON.stringify(bogusRes))

  // A grant funds the shop tests; the derived idempotency key is a digest of it.
  const grant1 = await queueAction(sEnv.DB, {
    steamid: SID, kind: "grant", payload: { reason: "test", coins: 500, gingerbread: 100 },
  })
  const grant1a = await applyAction(sEnv.DB, grant1.action.id, { now: 1500 })
  check("a grant pays both currencies",
    grant1a.ok && grant1a.balances.coins === 600 && grant1a.balances.gingerbread === 125,
    JSON.stringify(grant1a.balances))

  const buy1 = await queueAction(sEnv.DB, {
    steamid: SID, kind: "buy",
    payload: { item: "ornament:12", item_kind: "ornament", price: { coins: 150, gingerbread: 50 } },
  })
  const buy1a = await applyAction(sEnv.DB, buy1.action.id, { now: 1600 })
  check("a buy debits both currencies and grants the item",
    buy1a.ok && buy1a.balances.coins === 450 && buy1a.balances.gingerbread === 75 &&
    (await getPlayer(sEnv.DB, SID)).counts.ornaments === 1, JSON.stringify(buy1a))

  // The transaction proof: the first debit (10 coins) must be rolled back when the
  // second currency cannot be paid, and nothing may be granted.
  const beforeShort = await balancesOf(sEnv.DB, SID)
  const buy2 = await queueAction(sEnv.DB, {
    steamid: SID, kind: "buy", payload: { item: "model:snowman", price: { coins: 10, gingerbread: 9999 } },
  })
  const buy2a = await applyAction(sEnv.DB, buy2.action.id, { now: 1700 })
  check("a buy that cannot pay its second currency writes nothing at all",
    buy2a.ok === false && /not enough gingerbread/.test(buy2a.error) &&
    buy2a.balances.coins === beforeShort.coins &&
    (await getPlayer(sEnv.DB, SID)).counts.inventory === 1, JSON.stringify(buy2a))

  // --------------------------------------------------------------- the tree ----
  const plant0 = await queueAction(sEnv.DB, {
    steamid: SID, kind: "plant_ornament", payload: { slot: 3, ornament: 5 },
  })
  const plant0a = await applyAction(sEnv.DB, plant0.action.id)
  check("planting an ornament the player does not own is refused",
    plant0a.ok === false && /not owned/.test(plant0a.error), JSON.stringify(plant0a))
  const plant1 = await queueAction(sEnv.DB, {
    steamid: SID, kind: "plant_ornament", payload: { slot: 3, ornament: 12 },
  })
  const plant1a = await applyAction(sEnv.DB, plant1.action.id, { now: 1800 })
  const tree1 = await treeSlots(sEnv.DB, SID)
  check("planting an owned ornament fills exactly that slot",
    plant1a.ok && tree1.slots.length === 24 && tree1.filled === 1 && tree1.slots[2].ornament === 12,
    JSON.stringify(tree1))
  const plant2 = await queueAction(sEnv.DB, {
    steamid: SID, kind: "plant_ornament", payload: { slot: 9, ornament: 12 },
  })
  const plant2a = await applyAction(sEnv.DB, plant2.action.id, { now: 1810 })
  const tree2 = await treeSlots(sEnv.DB, SID)
  check("moving an ornament empties the slot it came from (one slot per ornament)",
    plant2a.ok && tree2.filled === 1 && tree2.slots[8].ornament === 12 && tree2.slots[2].ornament === null,
    JSON.stringify(tree2))

  // ------------------------------------------------------------- the advent ----
  const advent1 = await queueAction(sEnv.DB, {
    steamid: SID, kind: "claim_advent", payload: { day: 3, gingerbread: 40 },
  })
  const advent1a = await applyAction(sEnv.DB, advent1.action.id, { now: 1900 })
  const advent2 = await queueAction(sEnv.DB, {
    steamid: SID, kind: "claim_advent", payload: { day: 3, gingerbread: 40 }, idem: "advent:3:retry",
  })
  const advent2a = await applyAction(sEnv.DB, advent2.action.id, { now: 1910 })
  check("a second claim of the same advent day is refused and pays nothing",
    advent1a.ok && advent2a.ok === false && /already claimed/.test(advent2a.error) &&
    (await getPlayer(sEnv.DB, SID)).gingerbread === advent1a.balances.gingerbread &&
    (await getPlayer(sEnv.DB, SID)).counts.advent_claimed === 1,
    `${JSON.stringify(advent2a.error)} gingerbread=${(await getPlayer(sEnv.DB, SID)).gingerbread}`)

  // ---------------------------------------- entitlements, pass, inventory ----
  const prem = await queueAction(sEnv.DB, {
    steamid: SID, kind: "grant",
    payload: { reason: "staff", product: "bp_premium_2026", pass_xp: 3400 },
  })
  const prema = await applyAction(sEnv.DB, prem.action.id, { now: 2000 })
  const pPrem = await getPlayer(sEnv.DB, SID)
  check("a premium grant sets the entitlement and the cached flag",
    prema.ok && pPrem.premium === 1 && pPrem.entitlements.includes("bp_premium_2026") &&
    sd.raw.prepare(`SELECT premium FROM winter_players WHERE steamid=?1`).get(SID).premium === 1,
    JSON.stringify(pPrem.entitlements))
  check("pass XP moves the tier on the documented curve",
    pPrem.pass.xp === 3400 && pPrem.pass.tier === 11 && pPrem.pass.next_tier === 12,
    JSON.stringify(pPrem.pass))
  check("the pass curve is the documented 300/700/1400 ladder",
    passTierXp(1) === 0 && passTierXp(10) === 2700 && passTierXp(11) === 3400 &&
    passTierXp(20) === 9700 && passTierXp(30) === 23700 &&
    passTierFromXp(0) === 1 && passTierFromXp(2700) === 10 && passTierFromXp(3399) === 10 &&
    passTierFromXp(3400) === 11 && passTierFromXp(999999) === PASS_MAX_TIER,
    `${passTierFromXp(3399)}/${passTierFromXp(3400)}`)

  const title1 = await queueAction(sEnv.DB, {
    steamid: SID, kind: "grant", payload: { reason: "title", item: "title:3", item_kind: "title" },
  })
  await applyAction(sEnv.DB, title1.action.id, { now: 2010 })
  const title2 = await queueAction(sEnv.DB, {
    steamid: SID, kind: "grant", payload: { reason: "title", item: "title:4", item_kind: "title" },
  })
  await applyAction(sEnv.DB, title2.action.id, { now: 2020 })
  const ach = await achievements(sEnv.DB, SID)
  check("achievements report the titles the panel granted",
    ach.length === 2 && ach.some(a => a.item === "title:3") && ach.every(a => a.equipped === false),
    JSON.stringify(ach))
  const eq1 = await queueAction(sEnv.DB, { steamid: SID, kind: "equip", payload: { item: "title:3" } })
  await applyAction(sEnv.DB, eq1.action.id, { now: 2030 })
  const eq2 = await queueAction(sEnv.DB, { steamid: SID, kind: "equip", payload: { item: "title:4" } })
  const eq2a = await applyAction(sEnv.DB, eq2.action.id, { now: 2040 })
  const equipped = sd.raw.prepare(`SELECT item FROM winter_inventory WHERE steamid=?1 AND equipped=1`).all(SID)
  check("equipping a second title clears the first (one equipped per kind)",
    eq2a.ok && equipped.length === 1 && equipped[0].item === "title:4", JSON.stringify(equipped))

  // ----------------------------------------------------- the read-only layer ----
  const boards = await topBoards(sEnv.DB, { limit: 5 })
  const gbBoard = boards.gingerbread || []
  check("the gingerbread board is read from winter_players",
    gbBoard.length >= 1 && gbBoard[0].steamid === SID &&
    gbBoard[0].value === (await getPlayer(sEnv.DB, SID)).gingerbread, JSON.stringify(gbBoard))
  const msns = await missionsFor(sEnv.DB, SID)
  check("the mission list reports the claim state of each mission",
    msns.some(m => m.mission === "12" && m.state === "applied"), JSON.stringify(msns))
  const led = await recentLedger(sEnv.DB, SID, { limit: 5 })
  check("recent ledger lines come back newest first with their balance",
    led.length === 5 && led[0].id > led[4].id && led[0].balance_after >= 0,
    JSON.stringify(led.map(r => r.id)))
  const acts = await recentActions(sEnv.DB, SID, { limit: 3 })
  check("recentActions reports the queue as a page shows it", acts.length === 3,
    JSON.stringify(acts.map(a => a.kind)))
  sd.raw.prepare(
    `INSERT INTO winter_mail (steamid, kind, title, body, created_at) VALUES (?1,'system','Advent','day 3',2050)`
  ).run(SID)
  const inbox = await mail(sEnv.DB, SID)
  check("the inbox lists the unread row and getPlayer counts it",
    inbox.length === 1 && inbox[0].unread === true && inbox[0].title === "Advent" &&
    (await getPlayer(sEnv.DB, SID)).counts.mail_unread === 1, JSON.stringify(inbox))
  const ghost = await getPlayer(sEnv.DB, "STEAM_0:0:799")
  check("a player the panel has never seen reports null, not a zero balance",
    ghost.exists === false && ghost.coins === null && ghost.level === null && ghost.gingerbread === 0,
    JSON.stringify(ghost))

  // The same apply through a D1-SHAPED handle (prepare + batch, no `raw`): the
  // local driver exposes both, so this exercises the batch branch a Cloudflare
  // deployment takes, including its refusal path.
  const d1shaped = { prepare: sd.prepare, batch: sd.batch }
  const D1SID = "STEAM_0:0:705"
  const dq = await queueAction(d1shaped, {
    steamid: D1SID, kind: "claim_mission", payload: { mission: 1, gingerbread: 7 },
  })
  const da = await applyAction(d1shaped, dq.action.id, { now: 3000 })
  check("the apply also works through a D1-shaped handle (no interactive transaction)",
    da.ok && da.balances.gingerbread === 7 &&
    (await ledgerBalance(sEnv.DB, D1SID, "gingerbread")) === 7, JSON.stringify(da))
  const dref = await queueAction(d1shaped, {
    steamid: D1SID, kind: "buy", payload: { item: "ornament:1", price: { gingerbread: 999 } },
  })
  const drefa = await applyAction(d1shaped, dref.action.id, { now: 3010 })
  check("a refusal through the batch path writes nothing",
    drefa.ok === false && drefa.state === "refused" &&
    (await balancesOf(sEnv.DB, D1SID)).gingerbread === 7, JSON.stringify(drefa))

  // --------------------------------------------------- the two game endpoints ----
  // The panel process's own database: the harness queues and applies through the
  // same functions the page layer will call, then talks to it over HTTP.
  const gsid = "STEAM_0:0:703"
  const pdb = openLocalD1(panel.dbFile)
  const gq = await queueAction(pdb, {
    steamid: gsid, kind: "claim_advent", payload: { day: 4, gingerbread: 10 },
  })
  const ga = await applyAction(pdb, gq.action.id, { now: Math.floor(Date.now() / 1000) })
  pdb.raw.close()
  check("the panel applied a queued advent claim for the pull tests",
    ga.ok && ga.balances.gingerbread === 10, JSON.stringify(ga))

  const unsigned = await gameCall(panel, "GET", "/api/game/pending", { query: { steamid: gsid }, sig: "" })
  check("the pull refuses an unsigned request", unsigned.status === 401, "-> " + unsigned.status)
  const wrongSig = await gameCall(panel, "GET", "/api/game/pending", {
    query: { steamid: gsid }, sig: "0".repeat(64),
  })
  check("the pull refuses a wrong signature", wrongSig.status === 401, "-> " + wrongSig.status)
  const staleTs = await gameCall(panel, "GET", "/api/game/pending", {
    query: { steamid: gsid }, ts: Math.floor(Date.now() / 1000) - 900,
  })
  check("the pull refuses a timestamp outside the replay window", staleTs.status === 401,
    "-> " + staleTs.status)

  const pull1 = await gameCall(panel, "GET", "/api/game/pending", { query: { steamid: gsid } })
  const pull1Body = await pull1.json()
  check("the signed pull returns the committed action with its verdict",
    pull1.status === 200 && pull1Body.ok === true && pull1Body.steamid === gsid &&
    pull1Body.actions.length === 1 && pull1Body.actions[0].id === gq.action.id &&
    pull1Body.actions[0].kind === "claim_advent" && pull1Body.actions[0].state === "applied" &&
    pull1Body.actions[0].payload.day === 4, JSON.stringify(pull1Body))

  const ackBody = JSON.stringify({ id: gq.action.id, state: "applied" })
  const ack1 = await gameCall(panel, "POST", "/api/game/ack", { body: ackBody })
  const ack1Body = await ack1.json()
  const ack2 = await gameCall(panel, "POST", "/api/game/ack", { body: ackBody })
  const ack2Body = await ack2.json()
  check("the ack is accepted once and is idempotent on replay",
    ack1.status === 200 && ack1Body.ok === true && ack1Body.already === false &&
    ack1Body.state === "applied" && ack2.status === 200 && ack2Body.ok === true &&
    ack2Body.already === true && ack2Body.game_acked_at === ack1Body.game_acked_at,
    `${JSON.stringify(ack1Body)} / ${JSON.stringify(ack2Body)}`)
  const pull2 = await (await gameCall(panel, "GET", "/api/game/pending", { query: { steamid: gsid } })).json()
  check("an acked action leaves the pull", pull2.actions.length === 0, JSON.stringify(pull2))
  const afterAck = openLocalD1(panel.dbFile)
  const gPlayer = await getPlayer(afterAck, gsid)
  afterAck.raw.close()
  check("the ack never pays a balance again", gPlayer.gingerbread === 10, String(gPlayer.gingerbread))
  const badAck = await gameCall(panel, "POST", "/api/game/ack", { body: JSON.stringify({ id: gq.action.id, state: "nonsense" }) })
  check("an ack with an unknown state is refused", badAck.status === 400, "-> " + badAck.status)

  // =============================================== 12. the shop (page 11) ====
  // /panel/shop is the first transactional page: a Buy is a POST that queues one
  // `buy` through queueAction and renders the row back as QUEUED. The checks here
  // are the ones the contract promises: one row per double submit, nothing queued
  // when the player cannot pay, and — after applyAction — one charge, one ledger
  // line, and the item in the inventory.
  {
    const { shopCatalog, ownedItems, actionsOfKind } = await import("./src/query.js")
    const shop = await import("./src/panel/shop.js")
    const sdb = openLocalD1(panel.dbFile)
    const SHELF = await shopCatalog(sdb)
    check("shop: the catalogue is seeded and every row is deliverable-shaped",
      SHELF.length >= 30 && SHELF.every(r =>
        (r.kind === "product" ? !!r.product : /^(ornament|title):/.test(r.item)) &&
        (r.price.coins > 0 || r.price.gingerbread > 0)),
      `${SHELF.length} rows`)
    check("shop: nothing on the shelf is a skin/model/badge/bundle (the game cannot grant them)",
      SHELF.every(r => ["ornament", "title", "product"].includes(r.kind)),
      [...new Set(SHELF.map(r => r.kind))].join(","))
    check("shop: the six collector titles and the thirty ornaments are all shelved",
      SHELF.filter(r => r.kind === "title").length === 6 && SHELF.filter(r => r.kind === "ornament").length === 30,
      `${SHELF.filter(r => r.kind === "title").length}/${SHELF.filter(r => r.kind === "ornament").length}`)

    // The page itself: 200, one fixed stage, no scrollbars, the plate as its pictures.
    const shopPage = await fetch(panel.base + "/panel/shop")
    const shopDoc = await shopPage.text()
    check("shop: answers 200 html", shopPage.status === 200 && /text\/html/.test(shopPage.headers.get("content-type") || ""),
      "-> " + shopPage.status)
    check("shop: the plate is the only picture source (plus generated product art)",
      shopDoc.includes("/plates/10-shop.png") && !/background-image:url\(\/(?!plates\/10-shop\.png)/.test(shopDoc),
      "")
    check("shop: one fixed stage, scaled by min(vw/W, vh/H), never a reflow",
      /width:1670px;height:941px/.test(shopDoc) && /Math\.min\(vw\/W,vh\/H,1\)/.test(shopDoc) &&
      /overflow:hidden/.test(shopDoc), "")
    check("shop: the cards the plate draws but this shop cannot sell say why",
      shopDoc.includes("Not available yet") && /cannot|no path|pull/i.test(shopDoc), "")

    // A player with a wallet: a known player row, coins and gingerbread granted
    // through the queue (never a direct write in the test either).
    const BSID = "STEAM_0:0:712"
    await push(panel, player(BSID, { xp: 500, coins: 900, kills: 0 }))
    const grantRow = await queueAction(sdb, {
      steamid: BSID, kind: "grant", payload: { reason: "test", gingerbread: 2000 }, idem: "grant:test-shop",
    })
    await applyAction(sdb, grantRow.action.id)

    // Offer A: an ornament the player can afford at one GB price (2 500 GB is too
    // dear, so the affordable one is a common ornament at 60 GB).
    const cheap = SHELF.find(r => r.kind === "ornament" && r.price.gingerbread > 0 && r.price.gingerbread <= 2000)

    // DOUBLE SUBMIT: two identical POSTs, one after the other, exactly what a
    // double-clicked Buy button does.
    const post = () => fetch(panel.base + "/panel/shop", {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ s: BSID, sku: cheap.sku }).toString(),
    })
    const r1 = await post()
    const doc1 = await r1.text()
    const r2 = await post()
    const doc2 = await r2.text()
    const day = shop.parisDay(Math.floor(Date.now() / 1000))
    const rows = (await actionsOfKind(sdb, BSID, "buy", { limit: 50 }))
      .filter(x => x.idem === shop.buyIdem(cheap.sku, day))
    check("shop: a double submit queues exactly ONE row", rows.length === 1,
      `${rows.length} rows for idem ${shop.buyIdem(cheap.sku, day)}`)
    check("shop: the idem key is buy:<sku>:<paris day>", rows[0] && rows[0].idem === `buy:${cheap.sku}:${day}`,
      rows[0] ? rows[0].idem : "no row")
    check("shop: the first POST says Queued and the second says it already exists",
      doc1.includes("Queued:") && /Already queued today/.test(doc2), "")
    check("shop: the page shows the row as queued, never as paid",
      doc1.includes("Queued") && !/chip paid[^>]*>Paid/.test(doc1), "")
    const before = await balancesOf(sdb, BSID)
    check("shop: nothing is charged while the row is pending", before.gingerbread === 2000,
      JSON.stringify(before))

    // The apply step (what the game's pull triggers) pays it exactly once.
    const a1 = await applyAction(sdb, rows[0].action_id)
    const a2 = await applyAction(sdb, rows[0].action_id)
    const afterApply = await balancesOf(sdb, BSID)
    const ledger = await recentLedger(sdb, BSID, { limit: 20 })
    const charges = ledger.filter(l => l.reason === "buy" && l.ref === `buy:${cheap.sku}`)
    const ownedAfter = await ownedItems(sdb, BSID)
    check("shop: applying the purchase pays it once", a1.ok && a1.state === "applied" &&
      afterApply.gingerbread === 2000 - cheap.price.gingerbread, JSON.stringify(afterApply))
    check("shop: a second apply changes nothing (already applied)", a2.already === true &&
      afterApply.gingerbread === 2000 - cheap.price.gingerbread, JSON.stringify(a2))
    check("shop: exactly ONE ledger line carries the charge", charges.length === 1,
      `${charges.length} ledger rows`)
    check("shop: the item is in the inventory afterwards", ownedAfter.items.some(i => i.item === cheap.item),
      JSON.stringify(ownedAfter.items.map(i => i.item)))

    // UNOWNED CARD / OWNED CARD: a second POST of the same sku is still one row,
    // and the page now prints Owned instead of a Buy button for that card.
    await post()
    const rows2 = (await actionsOfKind(sdb, BSID, "buy", { limit: 50 }))
      .filter(x => x.idem === shop.buyIdem(cheap.sku, day))
    const ownedDoc = await (await fetch(panel.base + `/panel/shop?steamid=${encodeURIComponent(BSID)}`)).text()
    check("shop: a third submit still leaves ONE row", rows2.length === 1, `${rows2.length} rows`)
    check("shop: the owned card says Owned on a GET", ownedDoc.includes("Owned"), "")
    check("shop: the invented plate prices are not printed as the page's own",
      !/2,500\s*GB/.test(ownedDoc) && !ownedDoc.includes("12,800") && !ownedDoc.includes("8,960"), "")

    // INSUFFICIENT CURRENCY: a title costs 2 500 GB, the player has the rest.
    const dear = SHELF.find(r => r.kind === "title")
    const affordableBefore = (await balancesOf(sdb, BSID)).gingerbread
    const r3 = await fetch(panel.base + "/panel/shop", {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ s: BSID, sku: dear.sku }).toString(),
    })
    const doc3 = await r3.text()
    const rows3 = (await actionsOfKind(sdb, BSID, "buy", { limit: 50 }))
      .filter(x => x.idem === shop.buyIdem(dear.sku, day))
    // The refusal happens at APPLY time (the queue only queues), so the page must
    // still say "queued" — and the apply must refuse, with the queue's own words.
    check("shop: an unaffordable purchase is never charged by the page itself",
      (await balancesOf(sdb, BSID)).gingerbread === affordableBefore, "")
    check("shop: the unaffordable buy queued ONE pending row (the queue cannot know the balance yet)",
      rows3.length === 1 && rows3[0].state === "pending", JSON.stringify(rows3.map(x => x.state)))
    const a3 = await applyAction(sdb, rows3[0].action_id)
    check("shop: the apply REFUSES it and writes nothing", a3.ok === false && a3.state === "refused" &&
      (await balancesOf(sdb, BSID)).gingerbread === affordableBefore, JSON.stringify(a3))
    check("shop: the refusal reason is the queue's own sentence, verbatim",
      /^not enough gingerbread \(have \d+, need \d+\)$/.test(a3.error), JSON.stringify(a3.error))
    const docRefused = await (await fetch(panel.base + `/panel/shop?steamid=${encodeURIComponent(BSID)}`)).text()
    check("shop: the page prints that refusal verbatim after the game/apply refused it",
      docRefused.includes(a3.error), a3.error)

    // A refusal the QUEUE itself makes (bad payload) is printed verbatim too.
    const badForm = new URLSearchParams({ s: BSID, sku: "ornament:999" }).toString()
    const r4 = await fetch(panel.base + "/panel/shop", {
      method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" }, body: badForm,
    })
    const doc4 = await r4.text()
    check("shop: an unknown sku is refused by the page verbatim and queues nothing",
      doc4.includes('the shelf has no product "ornament:999"') &&
      !(await actionsOfKind(sdb, BSID, "buy", { limit: 50 })).some(x => (x.payload || {}).item === "ornament:999"),
      "")

    // One ledger line per paid purchase, and only for it.
    const ledger2 = await recentLedger(sdb, BSID, { limit: 50 })
    check("shop: no purchase charged a balance it did not also record",
      ledger2.filter(l => l.reason === "buy").length === 1, `${ledger2.filter(l => l.reason === "buy").length} buy lines`)
    sdb.raw.close()
  }
  sd.raw.close()
} catch (e) {
  bad("suite", e && e.stack ? e.stack : String(e))
  console.error("--- panel output ---\n" + panel.output.split("\n").slice(-25).join("\n"))
  console.error("--- trusted output ---\n" + trusted.output.split("\n").slice(-25).join("\n"))
} finally {
  await panel.stop()
  await trusted.stop()
  await limited.stop()
  await wait(200)
  try { rmSync(root, { recursive: true, force: true }) } catch {}
}

if (failures) {
  console.error(`\nFAILURES: ${failures} (passed ${passed})`)
  process.exitCode = 1
} else {
  console.log(`PASS panel test suite (${passed} checks)`)
}
