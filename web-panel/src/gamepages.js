// MOTD-safe landing pages for surfaces that are intentionally purchased or
// configured in game. The web never mutates coins, inventory or preferences.
import { loadTheme } from "./top15/store.js"
import { serverMeta } from "./top15/meta.js"
import { motdFrame, esc } from "./top15/render.js"

const SURFACES = {
  shop: {
    title: "Coin Shop",
    kicker: "Server-authoritative store",
    command: "/shop",
    note: "Purchases are validated and debited by battlepass_core on the game server. The web page is read-only.",
    catalogKey: "shop"
  },
  skins: {
    title: "Weapon Skins",
    kicker: "Ownership and preview",
    command: "/skins",
    note: "Equip and preview weapon skins in game. Ownership is stored by the server.",
    catalogKey: "skins"
  },
  models: {
    title: "Player Models",
    kicker: "Ownership and selection",
    command: "/models",
    note: "Player models are selected in game and validated against owned inventory.",
    catalogKey: "models"
  },
  cosmetics: {
    title: "Cosmetics",
    kicker: "Effects, titles and tags",
    command: "/cosmetics",
    note: "Cosmetic ownership is server-side; this page never unlocks or equips an item.",
    catalogKey: "cosmetics"
  }
}

function commandRow(label, command, note) {
  return `<tr><td class='k'>${esc(label)}</td><td><code>${esc(command)}</code><br><span class='muted'>${esc(note)}</span></td></tr>`
}

export async function pageGameSurface(env, url, kind) {
  const spec = SURFACES[kind] || SURFACES.shop
  const theme = await loadTheme(env)
  const meta = await serverMeta(env, Math.floor(Date.now() / 1000))
  let catalog = "not published yet"
  try {
    const row = await env.DB.prepare(`SELECT version, updated_at FROM catalog WHERE key = ?1`).bind(spec.catalogKey).first()
    if (row) catalog = `version ${row.version} - updated ${new Date(Number(row.updated_at) * 1000).toISOString().slice(0, 10)}`
  } catch {}

  const content = `<div class='panel'>
    <div class='h2'>${esc(spec.title)}</div>
    <p>${esc(spec.note)}</p>
    <table class='tbl' cellspacing='0' cellpadding='3'>
      ${commandRow("Open in game", spec.command, "The native menu is the authoritative interface.")}
      ${commandRow("Catalog", catalog, "Push is performed by freenova_sync; stale data is labeled.")}
      ${commandRow("Balance", "server-side coins", "No web purchase is accepted.")}
    </table>
    <p class='muted'>If the native menu is unavailable, use <code>/hub</code> in game or contact staff on Discord.</p>
  </div>`

  return motdFrame({
    theme, meta, title: spec.title, kicker: spec.kicker,
    sub: "Read-only web view - actions happen in game",
    backHref: "/hub", backLabel: "Hub",
    content
  })
}

export async function pageSettings(env) {
  const theme = await loadTheme(env)
  const meta = await serverMeta(env, Math.floor(Date.now() / 1000))
  const content = `<div class='panel'>
    <div class='h2'>Player Settings</div>
    <p>Preferences are stored per SteamID by <code>freenova_prefs</code>. They are not writable from this page.</p>
    <table class='tbl' cellspacing='0' cellpadding='3'>
      ${commandRow("HUD", "/hud", "Toggle the under-radar progression HUD.")}
      ${commandRow("Hub", "/hub or /menu", "Open the native navigation center.")}
      ${commandRow("Low performance", "/settings", "Open Settings and choose Low Performance Mode.")}
      ${commandRow("Language", "/settings", "Choose a loaded language dictionary from Settings.")}
    </table>
  </div>`
  return motdFrame({
    theme, meta, title: "Settings", kicker: "Client preferences",
    sub: "In-game controls, read-only web summary",
    backHref: "/hub", backLabel: "Hub", content
  })
}

export async function pageRules(env) {
  const theme = await loadTheme(env)
  const meta = await serverMeta(env, Math.floor(Date.now() / 1000))
  const content = `<div class='panel'>
    <div class='h2'>FreeNova Rules</div>
    <p>Play fairly, respect other players, and follow staff instructions. Cheating, exploiting, ban evasion, harassment and abuse of admin powers are not allowed.</p>
    <table class='tbl' cellspacing='0' cellpadding='3'>
      <tr><td class='k'>Support</td><td><a href='https://discord.gg/vuGaWjuX'>Discord</a></td></tr>
      <tr><td class='k'>Admin help</td><td>Use <code>/calladmin</code> in game for an active staff request.</td></tr>
      <tr><td class='k'>Bans</td><td>Bans and audit history are managed by AdvancedBans; appeal through staff.</td></tr>
    </table>
  </div>`
  return motdFrame({
    theme, meta, title: "Rules", kicker: "FreeNova Network",
    sub: "Community and server rules",
    backHref: "/hub", backLabel: "Hub", content
  })
}
