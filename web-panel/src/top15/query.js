import {
  SORT_FIELDS, PAGE_SIZE, parseSort, parseDir, parseWeapon, parsePage, parseQuery, weaponById
} from "./theme.js"

export function readContract(url) {
  const q = url.searchParams
  const sid = String(q.get("steamid") || "")
  return {
    steamid: /^STEAM_[0-9]:[0-9]:\d+$/.test(sid) ? sid : "",
    sort: parseSort(q.get("sort")),
    dir: parseDir(q.get("dir") || q.get("order")),
    weapon: q.has("w") || q.has("weapon") ? parseWeapon(q.get("w") || q.get("weapon")) : 17,
    q: parseQuery(q.get("q")),
    page: parsePage(q.get("page")),
    pageSize: PAGE_SIZE,
    compact: q.get("compact") === "1"
  }
}

export function stateQuery(c, extra) {
  const p = new URLSearchParams()
  if (c.steamid) p.set("steamid", c.steamid)
  p.set("sort", c.sort)
  p.set("dir", c.dir)
  p.set("w", String(c.weapon))
  if (c.q) p.set("q", c.q)
  p.set("page", String(c.page))
  if (c.compact) p.set("compact", "1")
  if (extra) {
    for (const [k, v] of Object.entries(extra)) {
      if (v == null || v === "") p.delete(k)
      else p.set(k, String(v))
    }
  }
  return p.toString()
}

export async function queryBoard(env, c) {
  const field = SORT_FIELDS[c.sort]
  const dirSql = c.dir === "asc" ? "ASC" : "DESC"
  const wpn = weaponById(c.weapon)
  const slot = wpn.slot
  const like = c.q ? `%${c.q.replace(/[%_]/g, "")}%` : ""
  const offset = (c.page - 1) * c.pageSize

  let join = "LEFT JOIN player_weapons w ON 1 = 0"
  const args = []
  if (slot >= 0) {
    args.push(slot)
    join = `LEFT JOIN player_weapons w ON w.steamid = p.steamid AND w.slot = ?${args.length}`
  }
  let where = ""
  if (c.q) {
    args.push(like)
    const n = args.length
    where = `WHERE (p.name LIKE ?${n} OR p.steamid LIKE ?${n})`
  }

  args.push(c.pageSize)
  const limN = args.length
  args.push(offset)
  const offN = args.length

  const countSql = `SELECT COUNT(*) AS n FROM players p ${join} ${where}`
  const listSql = `SELECT p.steamid, p.name, p.xp, p.kills, p.deaths, p.headshots,
      p.rank_id, p.last_seen, p.cc, COALESCE(w.kills, 0) AS wpn,
      p.level, p.wins, p.mvps, p.vip_tier, p.custom_tag
    FROM players p ${join} ${where}
    ORDER BY ${field.sql} ${dirSql}, p.xp DESC, p.steamid ASC
    LIMIT ?${limN} OFFSET ?${offN}`

  try {
    const t = await env.DB.prepare(countSql).bind(...args.slice(0, args.length - 2)).first()
    const q = await env.DB.prepare(listSql).bind(...args).all()
    return { rows: q.results || [], total: Number(t && t.n) || 0, error: false }
  } catch {
    return { rows: [], total: 0, error: true }
  }
}
