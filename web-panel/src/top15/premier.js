// Premier leaderboard — MOTD-first, table layout, no card-in-card chrome.
// Hierarchy: compact header → slim live strip → champion feature → runners-up
// → dense board. Gold/silver/bronze are reserved for the top three; emerald is
// only live/active/sort state.
import { SORT_FIELDS, weaponById } from "./theme.js"
import { stateQuery } from "./query.js"
import { flagImg, isMotdCompact } from "../ui.js"
import { esc, fmt, alpha, rankName, rankFile, kdOf, hsOf, isOn, ago } from "./render.js"

function sortedTabs(c) {
  const keys = ["xp", "kills", "kd", "hs", "wins", "rank"]
  let out = keys.map(k => {
    const f = SORT_FIELDS[k]
    if (!f) return ""
    const active = c.sort === k
    const def = f.dirDefault || "desc"
    const next = active ? (c.dir === "desc" ? "asc" : "desc") : def
    return `<a class='${active ? "on" : ""}' href='/top15?${stateQuery(c, { sort: k, dir: next, page: 1 })}'>${esc(f.label)}${active ? (c.dir === "asc" ? " ↑" : " ↓") : ""}</a>`
  }).join("")
  if (c.sort === "weapon") {
    const w = weaponById(c.weapon)
    out += `<a class='on' href='/top15?${stateQuery(c, { sort: "weapon", dir: c.dir === "desc" ? "asc" : "desc", page: 1 })}'>${esc(w.short || w.name)} ${c.dir === "asc" ? "↑" : "↓"}</a>`
  }
  return out
}

function headerLink(c, key, label, cls) {
  const active = c.sort === key
  const def = (SORT_FIELDS[key] && SORT_FIELDS[key].dirDefault) || "desc"
  const next = active ? (c.dir === "desc" ? "asc" : "desc") : def
  const arrow = active ? (c.dir === "asc" ? " ↑" : " ↓") : ""
  return `<th class='${cls || ""}${active ? " on" : ""}'><a href='/top15?${stateQuery(c, { sort: key, dir: next, page: 1 })}'>${esc(label)}${arrow}</a></th>`
}

function weaponHeader(c, wpn) {
  const active = c.sort === "weapon"
  const def = (SORT_FIELDS.weapon && SORT_FIELDS.weapon.dirDefault) || "desc"
  const next = active ? (c.dir === "desc" ? "asc" : "desc") : def
  const arrow = active ? (c.dir === "asc" ? " ↑" : " ↓") : ""
  return `<th class='${active ? "on" : ""}'><a href='/top15?${stateQuery(c, { sort: "weapon", dir: next, page: 1 })}' title='${esc(wpn.name)} kills'><img src='${wpn.img}' width='13' height='13' style='vertical-align:-3px;margin-right:3px' alt=''>${esc(wpn.short || wpn.name)}${arrow}</a></th>`
}

function css(t) {
  return `*{margin:0;padding:0;}
html,body{background-color:${t.bg};color:${t.text};font-family:${t.font};font-size:12px;line-height:1.35;}
body{background-image:radial-gradient(620px 280px at 50% -160px,${alpha(t.primary, "10")},transparent 70%);background-repeat:no-repeat;}
a{color:${t.primary};text-decoration:none;}
a:hover{color:${t.secondary};}
img{border:0;vertical-align:middle;}
.wrap{width:620px;max-width:100%;margin:0 auto;padding:0 6px 14px;box-sizing:border-box;}
.muted{color:${t.muted};}

/* top bar */
.top{width:100%;border-collapse:collapse;border-bottom:1px solid ${t.border};}
.top td{padding:8px 0;vertical-align:middle;}
.mark{display:inline-block;width:26px;height:26px;line-height:24px;border:1px solid ${t.border};border-radius:6px;text-align:center;background-color:${t.surface};margin-right:7px;}
.mark img{width:18px;height:18px;}
.word{font-size:12px;font-weight:900;letter-spacing:1.8px;color:${t.text};}
.word i{font-style:normal;color:${t.primary};}
.net{font-size:6.5px;letter-spacing:1.4px;color:${t.muted};margin-left:5px;}
.livebar{text-align:right;font-family:Consolas,'Courier New',monospace;font-size:8px;letter-spacing:.5px;color:${t.muted};white-space:nowrap;}
.livebar b{color:${t.text};font-weight:600;}
.livebar .sep{color:${t.border};margin:0 4px;}
.state.live{color:${t.primary};font-weight:700;letter-spacing:1px;}
.state.stale{color:#f5c451;font-weight:700;letter-spacing:1px;}
.state.off{color:${t.offline};font-weight:700;letter-spacing:1px;}
.dot{display:inline-block;width:5px;height:5px;border-radius:99px;background-color:${t.online};margin-right:4px;vertical-align:1px;}
.dot.stale{background-color:#f5c451;}
.dot.off{background-color:${t.offline};}

/* page head */
.head{width:100%;border-collapse:collapse;margin:10px 0 2px;}
.head td{padding:0;vertical-align:bottom;}
.kick{font-size:7px;letter-spacing:1.9px;text-transform:uppercase;color:${t.primary};}
.h1{font-size:24px;line-height:1;font-weight:800;letter-spacing:-.4px;color:${t.text};margin-top:2px;}
.hmeta{text-align:right;font-size:8px;color:${t.muted};white-space:nowrap;}
.hmeta b{font-family:Consolas,'Courier New',monospace;font-size:13px;color:${t.text};}
.hmeta .stale{color:#f5c451;}

/* champion */
.champ{width:100%;border-collapse:collapse;margin-top:8px;background-color:${t.surface};background-image:linear-gradient(90deg,${alpha("#f5c451", "12")},transparent 62%);border-top:1px solid ${alpha("#f5c451", "4d")};border-bottom:1px solid ${alpha("#f5c451", "4d")};}
.champ td{padding:10px 6px;vertical-align:middle;}
.ccrest{width:68px;padding-left:2px !important;}
.ccrest img{width:62px;height:62px;}
.clabel{font-size:6.5px;letter-spacing:2px;text-transform:uppercase;color:#f5c451;font-weight:700;}
.cplace{display:inline-block;width:15px;height:15px;line-height:15px;border-radius:50%;background-color:#f5c451;color:#171204;text-align:center;font-family:Consolas,'Courier New',monospace;font-size:9px;font-weight:800;margin-right:5px;vertical-align:1px;}
.cmedal{width:16px;height:16px;margin-left:5px;vertical-align:-3px;}
.cname{font-size:21px;font-weight:700;color:${t.text};line-height:1.08;margin-top:1px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;}
.cname .flag{margin-right:4px;}
.cname a{color:inherit;}
.crank{font-size:8px;color:${t.muted};margin-top:3px;letter-spacing:.2px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;}
.cyou{display:inline-block;background-color:#f5c451;color:#171204;font-size:6px;font-weight:900;letter-spacing:.4px;padding:0 3px;border-radius:2px;margin-left:4px;vertical-align:2px;}
.cxp{text-align:right;white-space:nowrap;padding-left:8px !important;}
.cxp b{display:block;font-family:Consolas,'Courier New',monospace;font-size:24px;line-height:1;font-weight:800;color:#f5c451;letter-spacing:-1px;}
.cxp span{display:block;font-size:6.5px;letter-spacing:1.6px;color:${t.muted};margin-top:2px;}
.cstats{width:146px;padding-left:9px !important;border-left:1px solid ${alpha("#f5c451", "26")};}
.cstat{width:100%;border-collapse:collapse;}
.cstat td{padding:1px 0;vertical-align:top;text-align:left;}
.cstat span{display:block;font-size:6.5px;letter-spacing:1px;text-transform:uppercase;color:${t.muted};}
.cstat b{display:block;font-family:Consolas,'Courier New',monospace;font-size:11px;font-weight:600;color:${t.text};}

/* runners-up */
.runner{width:100%;border-collapse:collapse;border-bottom:1px solid ${t.border};}
.runner td{width:50%;padding:7px 6px;vertical-align:middle;}
.runner td+td{border-left:1px solid ${t.border};}
.runner td.r2{border-top:2px solid ${alpha("#c9d6d2", "b3")};}
.runner td.r3{border-top:2px solid ${alpha("#d08a54", "bf")};}
.rplace{display:inline-block;width:20px;height:20px;line-height:20px;border-radius:50%;font-family:Consolas,'Courier New',monospace;font-size:11px;font-weight:800;text-align:center;vertical-align:middle;margin-right:5px;}
.r2 .rplace{background-color:#c9d6d2;color:#101a16;}
.r3 .rplace{background-color:#d08a54;color:#211003;}
.rcrest{width:26px;height:26px;margin-right:6px;}
.rname{font-size:12.5px;font-weight:600;color:${t.text};}
.rname a{color:inherit;}
.rxp{font-family:Consolas,'Courier New',monospace;font-size:12.5px;font-weight:700;color:${t.text};margin-left:6px;}
.rmeta{display:block;margin-left:51px;font-size:8px;color:${t.muted};margin-top:1px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;}

/* controls */
.tools{width:100%;border-collapse:collapse;margin-top:10px;border-bottom:1px solid ${t.border};}
.tools td{padding:0 0 6px;vertical-align:bottom;}
.tlabel{font-size:7.5px;letter-spacing:1.4px;text-transform:uppercase;color:${t.muted};white-space:nowrap;}
.tlabel b{font-family:Consolas,'Courier New',monospace;font-size:9px;color:${t.text};margin-left:3px;}
.tools .right{text-align:right;white-space:nowrap;}
.search input{border:1px solid ${t.border};background-color:${t.surface};border-radius:3px;color:${t.text};font-family:${t.font};font-size:10.5px;padding:4px 7px;width:120px;}
.search input:focus{outline:0;border-color:${t.primary};}
.search button{background:transparent;border:1px solid ${t.primary};border-radius:3px;color:${t.primary};font-family:${t.font};font-size:7px;letter-spacing:1px;text-transform:uppercase;cursor:pointer;padding:3px 7px;margin-left:3px;}
.search button:hover{background-color:${t.primary};color:#04110e;}
.search .clr{font-size:7px;color:${t.muted};margin-left:3px;}
.weapon{display:inline-block;margin-left:7px;}
.weapon select{border:1px solid ${t.border};background-color:${t.surface};border-radius:3px;color:${t.text};font-family:${t.font};font-size:10px;padding:3px 4px;max-width:104px;}
.weapon .lab{font-size:6.5px;letter-spacing:1px;color:${t.muted};text-transform:uppercase;margin-right:2px;}
.sorts{padding:7px 0 0;border-bottom:1px solid ${t.border};}
.sorts a{display:inline-block;font-size:8.5px;letter-spacing:.9px;text-transform:uppercase;color:#b6c9c0;padding:0 10px 4px 0;border-bottom:2px solid transparent;}
.sorts a.on{color:${t.primary};border-bottom-color:${t.primary};}
.sorts a:hover{color:${t.text};}
.whint{padding:4px 0 0;font-size:7px;color:#9cb3a9;letter-spacing:.2px;}

/* board */
.board{width:100%;border-collapse:collapse;table-layout:fixed;}
.board th{font-size:7.5px;letter-spacing:1px;text-transform:uppercase;color:${t.muted};font-weight:600;text-align:right;padding:5px 4px;border-bottom:1px solid ${t.border};white-space:nowrap;}
.board th.l{text-align:left;}
.board th.c{text-align:center;}
.board th a{color:${t.muted};}
.board th.on a{color:${t.primary};}
.board td{padding:4px;border-bottom:1px solid ${alpha(t.border, "b3")};height:36px;font-size:11px;color:${t.text};text-align:right;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;vertical-align:middle;}
.board td.l{text-align:left;}
.board td.c{text-align:center;}
.board tr.row{cursor:pointer;}
.board tr.row:hover td{background-color:${t.surface};}
.board tr.you td{background-color:${alpha(t.primary, "08")};}
.board tr.you td:first-child{border-left:2px solid ${t.primary};}
.idx{font-family:Consolas,'Courier New',monospace;font-size:10px;color:${t.muted};}
.pname{font-size:12.5px;font-weight:600;color:${t.text};line-height:1.2;}
.pname:hover{color:${t.primary};}
.plvl{font-size:7px;color:${t.muted};margin-left:4px;letter-spacing:.2px;}
.vip{display:inline-block;font-size:6.5px;letter-spacing:.5px;text-transform:uppercase;color:#9fb3aa;border:1px solid #2a3f37;border-radius:2px;padding:0 3px;margin-left:4px;vertical-align:1px;}
.vip.v2{color:#f5c451;border-color:${alpha("#f5c451", "59")};}
.vip.v3{color:#b18cff;border-color:${alpha("#b18cff", "66")};}
.pmedal{width:15px;height:15px;margin-left:4px;vertical-align:-2px;}
.ytag{display:inline-block;background-color:${t.primary};color:#04110e;font-size:6px;font-weight:900;letter-spacing:.4px;padding:0 3px;border-radius:2px;margin-left:4px;vertical-align:1px;}
.pdot{display:inline-block;width:5px;height:5px;border-radius:99px;background-color:${t.online};margin-left:4px;vertical-align:1px;}
.sub{display:block;font-size:8.5px;line-height:1.2;color:${t.muted};margin-top:1px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;}
.xp{font-family:Consolas,'Courier New',monospace;font-size:12px;font-weight:700;color:${t.text};}
.wcol{font-family:Consolas,'Courier New',monospace;font-size:10px;color:${t.muted};}
.crest{width:22px;height:22px;}
.empty{text-align:center;padding:22px 4px;color:${t.muted};font-size:10px;}

/* footer */
.pager{width:100%;border-collapse:collapse;margin-top:8px;}
.pager td{padding:0;font-size:8px;color:${t.muted};letter-spacing:.3px;}
.pager .r{text-align:right;}
.pager a{font-family:Consolas,'Courier New',monospace;font-size:10px;padding:0 5px;color:${t.primary};}
.foot{width:100%;border-collapse:collapse;margin-top:8px;padding-top:6px;border-top:1px solid ${t.border};}
.foot td{font-size:6.5px;letter-spacing:1px;text-transform:uppercase;color:${t.muted};padding:0;}
.foot .r{text-align:right;}
.foot .cr{letter-spacing:0;text-transform:none;}

/* readability pass */
html,body{font-size:14px;}
.word{font-size:13px;}
.net{font-size:7.5px;}
.livebar{font-size:9px;}
.kick{font-size:8.5px;}
.hmeta{font-size:9px;}
.hmeta b{font-size:14px;}
.clabel{font-size:7.5px;}
.crank{font-size:9.5px;}
.cstat span{font-size:7.5px;}
.cstat b{font-size:12.5px;}
.rname{font-size:14px;}
.rxp{font-size:14px;}
.rxp em{font-style:normal;font-size:7px;letter-spacing:.4px;color:${t.muted};margin-left:2px;text-transform:uppercase;}
.rmeta{font-size:9.5px;}
.tlabel{font-size:8.5px;}
.tlabel b{font-size:10px;}
.sorts a{font-size:9.5px;}
.whint{font-size:8.5px;}
.board th{font-size:8.5px;}
.board td{font-size:12.5px;height:40px;}
.idx{font-size:11px;}
.pname{font-size:14px;}
.plvl{font-size:8px;}
.sub{font-size:10px;}
.xp{font-size:13px;}
.wcol{font-size:11px;}
.pager td{font-size:9px;}
.pager a{font-size:11px;}
.foot td{font-size:7.5px;}
`
}

function hsPct(r) {
  return hsOf(r) === "—" ? "—" : hsOf(r) + "%"
}

function metricOf(c, wpn) {
  switch (c.sort) {
    case "kills": return { key: "kills", label: "Kills", value: r => fmt(r.kills) }
    case "deaths": return { key: "deaths", label: "Deaths", value: r => fmt(r.deaths) }
    case "kd": return { key: "kd", label: "K/D", value: r => kdOf(r) }
    case "hs": return { key: "hs", label: "HS%", value: r => hsPct(r) }
    case "wins": return { key: "wins", label: "Wins", value: r => fmt(r.wins) }
    case "mvp": return { key: "mvp", label: "MVP", value: r => fmt(r.mvps) }
    case "rank": return { key: "rank", label: "Rank", value: r => fmt(r.rank_id) }
    case "level": return { key: "level", label: "Level", value: r => fmt(r.level) }
    case "acc": return { key: "acc", label: "ACC", value: r => Number(r.shots) > 0 ? (Number(r.hits) * 100 / Number(r.shots)).toFixed(1) + "%" : "—" }
    case "playtime": return {
      key: "playtime", label: "Time",
      value: r => {
        const m = Number(r.playtime_minutes) || 0
        if (!m) return "—"
        return m < 60 ? m + "m" : Math.floor(m / 60) + "h " + (m % 60) + "m"
      }
    }
    case "weapon": return { key: "weapon", label: wpn.short || wpn.name, value: r => fmt(r.wpn) }
    default: return { key: "xp", label: "XP", value: r => fmt(r.xp) }
  }
}

function champion(r, c, now, medalMap, metric) {
  const me = c.steamid && r.steamid === c.steamid
  const name = r.name || r.steamid || "Unknown"
  const rank = rankName(r)
  const on = isOn(r, now)
  const medal = medalMap && medalMap[r.steamid]
    ? String(medalMap[r.steamid]).replace(/[^a-z0-9_]/gi, "")
    : ""
  return `<table class='champ' cellspacing='0' cellpadding='0'><tr>
    <td class='ccrest'><img src='${rankFile(r)}' width='62' height='62' alt='${esc(rank)}' title='${esc(rank)}'></td>
    <td>
      <div class='clabel'><span class='cplace'>1</span>Champion · Season 1</div>
      <div class='cname'>${flagImg(r.cc, 15, 11)}<a href='/profile?steamid=${encodeURIComponent(r.steamid || "")}' style='color:inherit;'>${esc(name)}</a>${me ? "<span class='cyou'>YOU</span>" : ""}${medal ? `<img class='cmedal' src='/medals/fn_${medal}.png' width='16' height='16' alt='' title='Latest medal' onerror='this.style.display="none"'>` : ""}</div>
      <div class='crank'>${esc(rank)} · Level ${Number(r.level) || 1} · ${on ? "online" : "last seen " + esc(ago(now - (Number(r.last_seen) || 0)))}</div>
    </td>
    <td class='cxp'><b>${metric.value(r)}</b><span>${metric.label}</span></td>
    <td class='cstats'>
      <table class='cstat' cellspacing='0' cellpadding='0'>
        <tr><td><span>K/D</span><b>${kdOf(r)}</b></td><td><span>HS</span><b>${hsPct(r)}</b></td></tr>
        <tr><td><span>Wins</span><b>${fmt(r.wins)}</b></td><td><span>MVP</span><b>${fmt(r.mvps)}</b></td></tr>
      </table>
    </td>
  </tr></table>`
}

function runner(r, pos, c, now, metric) {
  const cls = pos === 2 ? "r2" : "r3"
  const name = r.name || r.steamid || "Unknown"
  return `<td class='${cls}'>
    <span class='rplace'>${pos}</span><img class='rcrest' src='${rankFile(r)}' width='26' height='26' alt='' title='${esc(rankName(r))}'>
    <span class='rname'>${flagImg(r.cc, 13, 10)}<a href='/profile?steamid=${encodeURIComponent(r.steamid || "")}' style='color:inherit;'>${esc(name)}</a></span>
    <span class='rxp'>${metric.value(r)} <em>${esc(metric.label)}</em></span>
    <span class='rmeta'>${kdOf(r)} K/D · ${hsPct(r)} · ${fmt(r.wins)} wins</span>
  </td>`
}

function contextCols(c, wpn) {
  const out = []
  if (c.sort !== "kills") out.push({ key: "kills", label: "K", width: "7%", cell: r => fmt(r.kills) })
  if (c.sort !== "weapon") out.push({ key: "weapon", label: wpn.short || wpn.name, width: "8%", weapon: true, cell: r => fmt(r.wpn) })
  if (c.sort !== "kd") out.push({ key: "kd", label: "K/D", width: "9%", cell: r => kdOf(r) })
  if (c.sort !== "hs") out.push({ key: "hs", label: "HS%", width: "9%", cell: r => hsPct(r) })
  return out
}

function rowsHtml(rows, c, now, start, medalMap, metric, contexts) {
  let i = 0
  return rows.map(r => {
    i++
    const pos = start + i
    const me = c.steamid && r.steamid === c.steamid
    const on = isOn(r, now)
    const name = r.name || r.steamid || "Unknown"
    const rank = rankName(r)
    const url = "/profile?steamid=" + encodeURIComponent(r.steamid || "")
    const vip = Number(r.vip_tier) || 0
    const vipLabel = vip === 3 ? "VIP Elite" : vip === 2 ? "VIP+" : "VIP"
    const vipCls = vip === 3 ? " v3" : vip === 2 ? " v2" : " v1"
    const tag = r.custom_tag ? String(r.custom_tag).replace(/\s+/g, " ").trim().slice(0, 16) : ""
    const seenFull = on ? "Online now" : (Number(r.last_seen) ? "Last seen " + ago(now - Number(r.last_seen)) + " ago" : "No activity data")
    const medal = medalMap && medalMap[r.steamid]
      ? String(medalMap[r.steamid]).replace(/[^a-z0-9_]/gi, "")
      : ""
    return `<tr class='row${me ? " you" : ""}' onclick="location.href='${url}'">
      <td class='idx'>${pos}</td>
      <td class='l'>
        ${flagImg(r.cc, 13, 10)}<a class='pname' href='${url}'>${esc(name)}</a>${vip ? `<span class='vip${vipCls}' title='VIP tier ${vip}'>${vipLabel}</span>` : ""}${medal ? `<img class='pmedal' src='/medals/fn_${medal}.png' width='15' height='15' alt='' title='Latest medal' onerror='this.style.display="none"'>` : ""}${me ? "<span class='ytag'>YOU</span>" : ""}${on ? "<span class='pdot'></span>" : ""}
        <span class='sub' title='${esc(seenFull)}'>L${Number(r.level) || 1} · ${esc(rank)}${tag ? " · " + esc(tag) : ""} · ${on ? "online" : (Number(r.last_seen) ? "seen " + esc(ago(now - Number(r.last_seen))) : "—")}</span>
      </td>
      <td class='metric'><span class='xp'>${metric.value(r)}</span></td>
      ${contexts.map(cx => `<td${cx.weapon ? " class='wcol'" : ""}>${cx.cell(r)}</td>`).join("")}
      <td class='c'><img class='crest' src='${rankFile(r)}' width='22' height='22' alt='${esc(rank)}' title='${esc(rank)}'></td>
    </tr>`
  }).join("")
}

export function renderPremier({ contract: c, rows, total, theme, now, meta, medals }) {
  const MOTD = isMotdCompact()
  const wpn = weaponById(c.weapon)
  const medalMap = medals || {}
  const syncSec = meta && meta.lastPush ? Math.max(0, now - meta.lastPush) : null
  const stale = syncSec == null || syncSec > 90
  const live = Boolean(meta && meta.online && !stale)
  const state = live ? "LIVE" : (meta && meta.online ? "STALE" : "OFFLINE")
  const stateCls = live ? "live" : (meta && meta.online ? "stale" : "off")
  const sync = syncSec == null ? "no data" : ago(syncSec) + " ago"
  const syncTitle = meta && meta.lastPush
    ? `Last successful sync: ${sync} (${new Date(meta.lastPush * 1000).toISOString().slice(0, 16).replace("T", " ")} UTC)`
    : "No successful sync yet"
  const sortLabel = (SORT_FIELDS[c.sort] && SORT_FIELDS[c.sort].label) || c.sort
  const metric = metricOf(c, wpn)
  const contexts = contextCols(c, wpn)
  const weaponHint = c.sort === "weapon"
    ? `Ranking is by ${wpn.short || wpn.name} kills (weapon filter active).`
    : `Ranking by ${sortLabel}. Choose a weapon to switch the ranking to weapon kills.`
  const map = meta && meta.map ? meta.map : "—"
  const players = meta ? `${meta.players}/${meta.maxplayers || 32}` : "—"
  const ranked = meta ? meta.ranked : total

  const pages = Math.max(1, Math.ceil(total / c.pageSize))
  const cur = Math.min(c.page, pages)
  const start = (c.page - 1) * c.pageSize
  const top = c.page === 1 ? rows.slice(0, 3) : []
  const board = c.page === 1 ? rows.slice(3) : rows
  const offset = c.page === 1 ? start + 3 : start
  const rangeFrom = start + (top.length ? 4 : 1)
  const rangeTo = start + top.length + board.length
  const rangeLabel = board.length ? `Ranks ${rangeFrom}–${rangeTo} · Top 3 above` : (top.length ? "Top 3" : "Ranks")

  const topBlock = top.length ? `${champion(top[0], c, now, medalMap, metric)}
    ${top[1] ? `<table class='runner' cellspacing='0' cellpadding='0'><tr>${runner(top[1], 2, c, now, metric)}${top[2] ? runner(top[2], 3, c, now, metric) : "<td></td>"}</tr></table>` : ""}` : ""

  const table = `<table class='board' cellspacing='0' cellpadding='0'>
    <colgroup>
      <col style='width:6%'><col><col style='width:12%'>
      ${contexts.map(cx => `<col style='width:${cx.width}'>`).join("")}
      <col style='width:10%'>
    </colgroup>
    <thead><tr>
      <th class='c'>#</th>
      ${headerLink(c, "name", "Player", "l")}
      ${headerLink(c, metric.key, metric.label)}
      ${contexts.map(cx => cx.weapon ? weaponHeader(c, wpn) : headerLink(c, cx.key, cx.label)).join("")}
      ${headerLink(c, "rank", "Rank", "c")}
    </tr></thead>
    <tbody>${board.length ? rowsHtml(board, c, now, offset, medalMap, metric, contexts) : `<tr><td colspan='${4 + contexts.length}' class='empty'>${total ? (c.page === 1 && top.length >= total ? "All ranked players are on the podium." : "No players on this page.") : (c.q ? `No player matches “${esc(c.q)}”.` : "No ranked players yet.")}</td></tr>`}</tbody>
  </table>`

  const pager = `<table class='pager' cellspacing='0' cellpadding='0'><tr>
    <td>Page ${cur} / ${pages} <span class='muted'>·</span> ${fmt(total)} ranked</td>
    <td class='r'>${cur > 1 ? `<a href='/top15?${stateQuery(c, { page: cur - 1 })}'>‹</a>` : ""}${cur < pages ? `<a href='/top15?${stateQuery(c, { page: cur + 1 })}'>›</a>` : ""}</td>
  </tr></table>`

  const html = `<!DOCTYPE html><html><head><meta charset='utf-8'><title>FreeNova | Leaderboard</title>
  <meta name='viewport' content='width=620'>
  <link rel='icon' href='/i/logo_mark.png'><style>${css(theme)}</style></head>
  <body bgcolor='${theme.bg}' text='${theme.text}'><div class='wrap'${MOTD ? " style='width:auto;'" : ""}>
    <table class='top' cellspacing='0' cellpadding='0'><tr>
      <td><a href='/' style='color:${theme.text};'><span class='mark'><img src='/i/logo_mark.png' width='18' height='18' alt=''></span><span class='word'>FREE<i>NOVA</i></span><span class='net'>CS 1.6</span></a></td>
      <td class='livebar' title='${esc(syncTitle)}'><span class='dot ${stateCls}'></span><span class='state ${stateCls}' title='${esc(syncTitle)}'>${state}</span><span class='sep'>/</span><b>${esc(map)}</b><span class='sep'>/</span>${esc(players)}<span class='sep'>/</span>${esc(sync)}</td>
    </tr></table>

    <table class='head' cellspacing='0' cellpadding='0'><tr>
      <td><div class='kick'>Season 1 · Rank System</div><div class='h1'>Leaderboard</div></td>
      <td class='hmeta'><b>${fmt(ranked)}</b> ranked <span class='muted'>·</span> updated <span class='${stale ? "stale" : ""}' title='${esc(syncTitle)}'>${esc(sync)}</span></td>
    </tr></table>

    ${topBlock}

    <table class='tools' cellspacing='0' cellpadding='0'><tr>
      <td class='tlabel'>${esc(rangeLabel)}</td>
      <td class='right'>
        <form class='search' method='get' action='/top15' style='display:inline-block;'>
          ${c.steamid ? `<input type='hidden' name='steamid' value='${esc(c.steamid)}'>` : ""}
          <input type='hidden' name='sort' value='${esc(c.sort)}'>
          <input type='hidden' name='dir' value='${esc(c.dir)}'>
          <input type='hidden' name='w' value='${c.weapon}'>
          <input id='fn-q' type='text' name='q' value='${esc(c.q)}' size='10' placeholder='Search player'>
          <button type='submit'>Search</button>
          ${c.q ? `<a class='clr' href='/top15?${stateQuery(c, { q: "", page: 1 })}'>clear</a>` : ""}
        </form>
        <form class='weapon' method='get' action='/top15'>
          ${c.steamid ? `<input type='hidden' name='steamid' value='${esc(c.steamid)}'>` : ""}
          <input type='hidden' name='sort' value='weapon'>
          <input type='hidden' name='dir' value='desc'>
          <input type='hidden' name='q' value='${esc(c.q)}'>
          <span class='lab'>WPN</span>
          <select name='w' onchange='this.form.submit()'>
            ${Array.from({ length: 26 }, (_, id) => {
              const w = weaponById(id)
              return `<option value='${id}'${id === c.weapon ? " selected" : ""}>${esc(w.name)}</option>`
            }).join("")}
          </select>
        </form>
      </td>
    </tr></table>
    <div class='sorts'>${sortedTabs(c)}</div>
    <div class='whint'>${esc(weaponHint)}</div>

    ${table}
    ${pager}

    <table class='foot' cellspacing='0' cellpadding='0'><tr>
      <td>FreeNova · CS 1.6 · <span class='cr'>Icons: game-icons.net</span></td>
      <td class='r'>Snapshot every 30s · ${fmt(ranked)} tracked</td>
    </tr></table>
  </div><script type="text/javascript">(function(){var q=document.getElementById('fn-q');if(!q)return;document.onkeydown=function(e){e=e||window.event;var t=e.target||e.srcElement;var tag=t&&t.tagName?t.tagName:'';if(e.keyCode===191&&!/^(INPUT|TEXTAREA|SELECT)$/i.test(tag)){if(e.preventDefault)e.preventDefault();q.focus();}};})();</script></body></html>`
  return html
}
