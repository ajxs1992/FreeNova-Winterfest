// Local FreeNova panel — HTTP + SQLite next to HLDS. No Cloudflare.
// GoldSrc MOTD loads plain HTTP only (http://<lan-ip>:8080) - no TLS on this path.
import { createServer } from "node:http"
import { readFileSync, existsSync, mkdirSync, statSync } from "node:fs"
import { extname, join, normalize, resolve, dirname } from "node:path"
import { fileURLToPath } from "node:url"
import os from "node:os"
import { openLocalD1, migratePlayers } from "./src/sqlite_d1.js"
import worker from "./src/index.js"

const here = dirname(fileURLToPath(import.meta.url))
const HLDS_DATA = "C:/Users/conts/Desktop/.,/Server CS 1.6/cstrike/addons/amxmodx/data/sqlite3"
const SPACE_DATA = join(here, "data")
// PANEL_DB lets a dev run against a local snapshot instead of the live tree.
const DB_OVERRIDE = process.env.PANEL_DB || ""
const dataDir = DB_OVERRIDE ? dirname(resolve(DB_OVERRIDE)) : (existsSync(HLDS_DATA) ? HLDS_DATA : SPACE_DATA)
mkdirSync(dataDir, { recursive: true })
const dbFile = DB_OVERRIDE ? resolve(DB_OVERRIDE) : join(dataDir, "freenova_panel.sq3")
const schemaFile = join(here, "schema.sql")
const seedFile = join(here, "seed_catalogs.sql")
const shopSeedFile = join(here, "seed_shop_catalog.sql")
const assetsDir = join(here, "assets")
const SECRET_FILE = join(here, "relay", "relay.env")
if (existsSync(SECRET_FILE)) {
  for (const line of readFileSync(SECRET_FILE, "utf8").split(/\r?\n/)) {
    const t = line.trim()
    if (!t || t.startsWith("#")) continue
    const eq = t.indexOf("=")
    if (eq < 1) continue
    const k = t.slice(0, eq).trim()
    const v = t.slice(eq + 1).trim()
    if (k && process.env[k] == null) process.env[k] = v
  }
}

const secret = process.env.FNWEB_SECRET || process.env.SYNC_SECRET || ""
const PORT = Number(process.env.PORT || 8080)
const HOST = process.env.HOST || "0.0.0.0"

const MIME = {
  ".html": "text/html; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".gif": "image/gif",
  ".svg": "image/svg+xml",
  ".ico": "image/x-icon",
  ".woff2": "font/woff2"
}

const DB = openLocalD1(dbFile)
if (existsSync(schemaFile)) DB.raw.exec(readFileSync(schemaFile, "utf8"))
try { migratePlayers(DB.raw) } catch (e) { console.error("[panel] players migrate:", e.message) }
if (existsSync(seedFile)) {
  try { DB.raw.exec(readFileSync(seedFile, "utf8")) }
  catch (e) { console.error("[panel] catalog seed skipped:", e.message) }
}
// The shop shelf (page-driven addition, docs/panel/01-DATA.md §11). Its own file
// because the catalogue seed above is the game's and is version-guarded; this one
// is `ON CONFLICT DO NOTHING`, so a boot never overwrites a price.
if (existsSync(shopSeedFile)) {
  try { DB.raw.exec(readFileSync(shopSeedFile, "utf8")) }
  catch (e) { console.error("[panel] shop catalogue seed skipped:", e.message) }
}

function assetResponse(pathname) {
  const rel = pathname.replace(/^\/+/, "")
  const fp = resolve(join(assetsDir, rel))
  if (!fp.startsWith(resolve(assetsDir))) return null
  if (!existsSync(fp) || !statSync(fp).isFile()) return null
  const body = readFileSync(fp)
  return new Response(body, { headers: { "content-type": MIME[extname(fp).toLowerCase()] || "application/octet-stream" } })
}

const env = {
  DB,
  SYNC_SECRET: secret,
  ADMIN_PASSWORD: process.env.ADMIN_PASSWORD || "",
  ADMIN_STEAMIDS: process.env.ADMIN_STEAMIDS || "STEAM_0:0:683671116",
  // Panel-side action-token minting is opt-in (see src/sync.js
  // localTrustEnabled). Set FN_LOCAL_TRUST=1 only for a LAN/loopback deploy
  // whose MOTD is the only client; a public deployment must leave it unset and
  // rely on game-minted ?t= links.
  FN_LOCAL_TRUST: process.env.FN_LOCAL_TRUST || "",
  // v2 design rebuild: dev mode / a pinned default player for the local
  // instance. Loopback requests already count as dev; WF_DEV=1 forces it for a
  // LAN box, and WF_DEFAULT_STEAMID names the player an anonymous visit shows.
  WF_DEV: process.env.WF_DEV || "",
  WF_DEFAULT_STEAMID: process.env.WF_DEFAULT_STEAMID || "",
  WF_NOW: process.env.WF_NOW || "",
  DISCORD_WEBHOOK_URL: process.env.DISCORD_WEBHOOK_URL || "",
  DISCORD_ADMIN_PING: process.env.DISCORD_ADMIN_PING || "<@&1476343004640837772>",
  ASSETS: {
    async fetch(request) {
      const url = new URL(request.url)
      const res = assetResponse(url.pathname)
      return res || new Response("not found", { status: 404 })
    }
  }
}

// Headers a client may not forge for this process. The panel's rate limiting
// and login lockout read the platform client address, so the runner supplies it
// from the socket and strips the ones a caller could otherwise choose
// (REVIEW.md §4.2 M2).
// cf-connecting-ip is Cloudflare's header; this process is not behind
// Cloudflare, so a client sending it is trying to pick its own rate-limit bucket.
const CLIENT_CONTROLLED_IP = ["x-forwarded-for", "x-freenova-client-ip", "cf-connecting-ip", "forwarded", "x-real-ip"]

function toWebRequest(req, bodyBuf) {
  const host = req.headers.host || `127.0.0.1:${PORT}`
  const url = `http://${host}${req.url}`
  const headers = new Headers()
  for (const [k, v] of Object.entries(req.headers)) {
    if (v == null) continue
    if (CLIENT_CONTROLLED_IP.includes(k.toLowerCase())) continue
    headers.set(k, Array.isArray(v) ? v.join(", ") : String(v))
  }
  const peer = (req.socket && req.socket.remoteAddress) || ""
  headers.set("x-freenova-client-ip", peer)
  const init = { method: req.method, headers }
  if (req.method !== "GET" && req.method !== "HEAD") init.body = bodyBuf
  return new Request(url, init)
}

async function readBody(req) {
  // Cap the deferred body: both HMAC endpoints buffer the whole payload before
  // verifying it, so an unauthenticated POST could otherwise materialise
  // hundreds of MB in memory. A full 32-slot stats push is well under 100 KB.
  const limit = Number(process.env.PANEL_MAX_BODY_BYTES || 2 * 1024 * 1024)
  const chunks = []
  let total = 0
  for await (const c of req) {
    total += c.length
    if (total > limit) {
      const err = new Error(`request body exceeds ${limit} bytes`)
      err.status = 413
      throw err
    }
    chunks.push(c)
  }
  return Buffer.concat(chunks)
}

const server = createServer(async (req, res) => {
  try {
    const url = new URL(req.url || "/", `http://${req.headers.host || "127.0.0.1"}`)
    const asset = assetResponse(url.pathname)
    if (asset && req.method === "GET") {
      const buf = Buffer.from(await asset.arrayBuffer())
      res.writeHead(asset.status, { "content-type": asset.headers.get("content-type") || "application/octet-stream" })
      res.end(buf)
      return
    }
    const bodyBuf = req.method === "GET" || req.method === "HEAD" ? Buffer.alloc(0) : await readBody(req)
    const webReq = toWebRequest(req, bodyBuf)
    const webRes = await worker.fetch(webReq, env, {})
    const out = Buffer.from(await webRes.arrayBuffer())
    const headers = {}
    webRes.headers.forEach((v, k) => { headers[k] = v })
    // We buffer the whole body, so framing must be ours. Copying the Worker's
    // headers verbatim let Node choose chunked transfer for HTTP/1.1 callers,
    // and freenova_registration.sma (which sends HTTP/1.1) has no chunked
    // decoder: it fed "5d\r\n{...}" straight into json_parse and told every
    // player "Malformed response from forum server" while the request had in
    // fact been stored. An explicit Content-Length makes the body unframed for
    // both consumers (sync.sma also validates that the byte count matches).
    delete headers["transfer-encoding"]
    headers["content-length"] = String(out.length)
    res.writeHead(webRes.status, headers)
    res.end(out)
  } catch (e) {
    if (e && e.status === 413) {
      res.writeHead(413, { "content-type": "text/plain" })
      res.end("payload too large")
      return
    }
    console.error("[panel]", e && e.stack ? e.stack : e)
    res.writeHead(500, { "content-type": "text/plain" })
    res.end("panel error")
  }
})

server.listen(PORT, HOST, () => {
  try {
    console.log(`[netinfo] hostname=${os.hostname()}`)
    for (const [name, addrs] of Object.entries(os.networkInterfaces())) {
      for (const a of addrs || []) {
        if (a && a.family === "IPv4") console.log(`[netinfo] iface ${name} ${a.address}${a.internal ? " (internal)" : ""}`)
      }
    }
  } catch (e) { console.log(`[netinfo] interfaces unavailable: ${e && e.message}`) }
  try {
    console.log(`[netinfo] hosts: ${readFileSync("/etc/hosts", "utf8").trim().split(/\n/).slice(0, 8).join(" | ")}`)
  } catch { console.log("[netinfo] hosts unreadable") }
  console.log(`[netinfo] env PORT=${PORT} HOST=${HOST}`)
  console.log(`[panel] SQLite ${dbFile}`)
  console.log(`[panel] HTTP http://127.0.0.1:${PORT}  (bind ${HOST})`)
  console.log("[panel] GoldSrc MOTD uses this HTTP URL — Cloudflare is not in the path")
  console.log(`[panel] Call-admin webhook ${env.DISCORD_WEBHOOK_URL ? "configured" : "MISSING"}`)
})
