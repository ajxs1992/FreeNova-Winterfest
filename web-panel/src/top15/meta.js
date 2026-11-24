// Server snapshot for the MOTD header. Reads the same `meta` rows the game
// pushes every 30 s; never invents values.
const META_KEYS = [
  "server_online", "server_map", "server_players", "server_maxplayers",
  "server_hostname", "last_push"
]

export async function serverMeta(env, now) {
  const out = {
    online: false,
    map: "—",
    players: 0,
    maxplayers: 0,
    hostname: "FreeNova CS 1.6",
    lastPush: 0,
    ranked: 0,
    onlineNow: 0
  }
  try {
    const q = await env.DB.prepare(
      `SELECT key, value FROM meta WHERE key IN (${META_KEYS.map(k => `'${k}'`).join(",")})`
    ).all()
    for (const r of q.results || []) {
      const v = String(r.value == null ? "" : r.value)
      switch (r.key) {
        case "server_online": out.online = v === "1" || v === "true"; break
        case "server_map": out.map = v || "—"; break
        case "server_players": out.players = Number(v) || 0; break
        case "server_maxplayers": out.maxplayers = Number(v) || 0; break
        case "server_hostname": out.hostname = v || out.hostname; break
        case "last_push": out.lastPush = Number(v) || 0; break
      }
    }
  } catch {}
  try {
    const r = await env.DB.prepare("SELECT COUNT(*) AS n FROM players").first()
    out.ranked = Number(r && r.n) || 0
  } catch {}
  try {
    const r = await env.DB.prepare("SELECT COUNT(*) AS n FROM players WHERE last_seen > ?1")
      .bind(now - 900).first()
    out.onlineNow = Number(r && r.n) || 0
  } catch {}
  return out
}
