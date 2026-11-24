// FreeNova Top 15 — in-game MOTD renderer.
// GoldSrc's MOTD is an IE-era HTML control: table layout only, no CSS vars,
// flex or grid. Radii, gradients and shadows are progressive enhancement and
// fall back to solid panels on old MSHTML. Same markup renders in the browser
// preview at 620px, so the preview matches what players see in game.
import { SORT_FIELDS, TORNADO_WEAPONS, weaponById, xpColorOf } from "./theme.js"
import { stateQuery } from "./query.js"
import { flagImg, isMotdCompact } from "../ui.js"

const RANK_NAMES = [
  "Unranked", "Silver I", "Silver II", "Silver III", "Silver IV", "Silver Elite",
  "Silver Elite Master", "Gold Nova I", "Gold Nova II", "Gold Nova III",
  "Gold Nova Master", "Master Guardian", "Master Guardian II",
  "Master Guardian Elite", "Distinguished Master Guardian", "Legendary Eagle",
  "Legendary Eagle Master", "Supreme Master First Class", "Global Elite"
]

// Level tile colour = rank tier. Keeps the level readable while the tier
// colour carries progression (the same idea as the RSU rank crests).
const TIERS = [
  { max: 4, cls: "t1" },
  { max: 8, cls: "t2" },
  { max: 12, cls: "t3" },
  { max: 15, cls: "t4" },
  { max: 18, cls: "t5" },
  { max: 19, cls: "t6" }
]

function esc(s) {
  return String(s == null ? "" : s)
    .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;").replace(/'/g, "&#39;")
}
function fmt(n) {
  return String(n == null ? 0 : n).replace(/\B(?=(\d{3})+(?!\d))/g, ",")
}
// rgba() parses from IE9 up; old MSHTML drops the declaration and keeps the
// preceding solid colour. #RRGGBBAA is never used.
function alpha(hex, a2) {
  const r = parseInt(hex.slice(1, 3), 16)
  const g = parseInt(hex.slice(3, 5), 16)
  const b = parseInt(hex.slice(5, 7), 16)
  const a = Math.round(parseInt(a2, 16) / 255 * 1000) / 1000
  return `rgba(${r},${g},${b},${a})`
}
function rankId(r) { return Math.min(Math.max(Number(r && r.rank_id != null ? r.rank_id : r) || 1, 1), 19) }
function rankName(r) { return RANK_NAMES[rankId(r) - 1] }
function rankFile(r) { return `/ranks/rank_${String(rankId(r)).padStart(2, "0")}.png` }
function tierOf(r) { const id = rankId(r); return (TIERS.find(t => id <= t.max) || TIERS[0]).cls }
function kdOf(r) {
  const k = Number(r.kills) || 0
  const d = Number(r.deaths) || 0
  if (!k && !d) return "—"
  return (d ? k / d : k).toFixed(2)
}
function hsOf(r) {
  const k = Number(r.kills) || 0
  if (!k) return "—"
  return (Number(r.headshots) * 100 / k).toFixed(1)
}
function isOn(r, now) { return now - (Number(r.last_seen) || 0) < 900 }
function ago(sec) {
  const s = Math.max(0, Number(sec) || 0)
  if (s < 45) return s + "s"
  if (s < 3600) return Math.floor(s / 60) + "m"
  if (s < 86400) return Math.floor(s / 3600) + "h"
  return Math.floor(s / 86400) + "d"
}

function css(t) {
  return `*{margin:0;padding:0;}
html,body{background-color:${t.bg};color:${t.text};font-family:${t.font};font-size:${t.fontSize}px;line-height:1.3;}
body{background-color:${t.bg};background-image:radial-gradient(680px 300px at 50% -140px,${alpha(t.primary, "18")},transparent 70%),radial-gradient(440px 300px at 100% 0%,${alpha(t.secondary, "0d")},transparent 70%);background-repeat:no-repeat;border-top:1px solid ${alpha(t.primary, "59")};}
a{color:${t.primary};text-decoration:none;}
a:hover{color:${t.secondary};}
img{border:0;vertical-align:middle;}
.wrap{width:620px;max-width:100%;margin:0 auto;padding:7px 6px 14px;box-sizing:border-box;}

/* top bar + page head */
.top2{width:100%;border-collapse:collapse;border-bottom:1px solid ${t.border};margin-bottom:0;}
.top2 td{padding:0 0 8px;vertical-align:middle;}
.brand2{display:inline-block;color:${t.text};}
.brand2:hover{color:${t.text};}
.brand2 .mark{display:inline-block;width:32px;height:32px;line-height:30px;border:1px solid ${t.border};border-radius:9px;background-color:${t.rowEven};text-align:center;vertical-align:middle;margin-right:8px;}
.brand2 .mark img{width:23px;height:23px;}
.brand2 .bn{display:inline-block;vertical-align:middle;line-height:1.1;}
.brand2 .bn b{display:block;font-size:13px;letter-spacing:1.6px;font-weight:900;color:${t.text};}
.brand2 .bn b i{font-style:normal;color:${t.primary};}
.brand2 .bn span{display:block;font-size:6.5px;letter-spacing:1.7px;color:${t.muted};margin-top:2px;}
.topright{text-align:right;white-space:nowrap;}
.back2{display:inline-block;border:1px solid ${t.border};background-color:${t.rowEven};border-radius:99px;padding:3px 8px;font-size:7.5px;letter-spacing:.8px;text-transform:uppercase;color:${t.muted};margin-right:4px;}
.back2:hover{color:${t.primary};border-color:${t.primary};}
.live2{display:inline-block;border:1px solid ${alpha(t.online, "59")};background-color:${alpha(t.online, "10")};border-radius:99px;padding:3px 8px;font-size:7.5px;font-weight:700;letter-spacing:.7px;text-transform:uppercase;color:${t.online};}
.live2.off{border-color:${t.border};background-color:transparent;color:${t.offline};}
.live2.stale{border-color:${alpha("#f5c451", "73")};background-color:${alpha("#f5c451", "12")};color:#f5c451;}
.pagehead{padding:10px 1px 10px;}
.ph-k{font-size:7.5px;letter-spacing:2px;text-transform:uppercase;color:${t.primary};}
.ph-t{font-size:31px;line-height:1;font-weight:900;letter-spacing:1.4px;text-transform:uppercase;color:${t.text};margin-top:2px;}
.ph-t .cur{color:${t.primary};}
.ph-s{font-size:8.5px;color:${t.muted};margin-top:5px;letter-spacing:.2px;}
.kpis{width:100%;border-collapse:separate;margin:0 0 6px;}
.kpis td{background-color:${t.surface};border:1px solid ${t.border};border-radius:10px;padding:7px 9px;width:25%;vertical-align:middle;}
.kpis .k{display:block;font-size:6.8px;letter-spacing:1.2px;text-transform:uppercase;color:${t.muted};margin-bottom:2px;}
.kpis .v{display:block;font-family:Consolas,'Courier New',monospace;font-size:11.5px;font-weight:700;color:${t.text};white-space:nowrap;overflow:hidden;text-overflow:ellipsis;}
.kpis .v.p{color:${t.primary};}

/* hub grid */
.grid{width:100%;border-collapse:collapse;}
.grid td{width:50%;padding:0 2px 4px 0;vertical-align:top;text-align:left;}
.grid td.r{padding:0 0 4px 2px;}
.pcard3{display:block;background-color:${t.surface};border:1px solid ${t.border};border-radius:12px;padding:9px;color:${t.text};text-align:left;}
.pcard3:hover{border-color:${t.primary};color:${t.text};}
.pcode{display:inline-block;width:30px;height:30px;line-height:30px;border:1px solid;border-radius:8px;text-align:center;font-family:Consolas,'Courier New',monospace;font-size:12px;font-weight:800;vertical-align:middle;margin-right:8px;}
.pinfo{display:inline-block;vertical-align:middle;width:72%;}
.pinfo b{display:block;font-size:12px;color:${t.text};line-height:1.2;}
.pinfo small{display:block;font-size:7.5px;color:${t.muted};margin-top:2px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;}
.parr{float:right;color:${t.muted};font-size:14px;line-height:30px;}

/* achievements */
.ach-grid{width:100%;border-collapse:separate;}
.ach-grid td{width:25%;vertical-align:top;padding:0;}
.ach-card{background-color:${t.surface};border:1px solid ${t.border};border-radius:10px;padding:8px 5px;text-align:center;min-height:150px;}
.ach-card img{display:block;margin:0 auto 5px;}
.ach-title{font-size:8.5px;font-weight:800;color:${t.text};line-height:1.2;min-height:21px;}
.ach-meta{font-size:6px;letter-spacing:.6px;text-transform:uppercase;color:${t.muted};margin-top:2px;}
.ach-prog{font-size:7px;color:${t.muted};margin-top:2px;}
.ach-rar{display:inline-block;font-size:5.8px;letter-spacing:.5px;text-transform:uppercase;border:1px solid;border-radius:3px;padding:0 3px;margin-top:3px;}

/* achievements 2 */
.ach-hero{width:100%;border-collapse:collapse;background-color:${t.surface};background-image:linear-gradient(90deg,${alpha(t.primary, "0d")},transparent 55%);border-left:3px solid ${t.primary};border-radius:0 10px 10px 0;margin-bottom:5px;}
.ach-hero td{padding:8px 9px;vertical-align:middle;}
.ach-hero-pct{width:98px;text-align:center;}
.ach-pct{font-family:Consolas,'Courier New',monospace;font-size:30px;line-height:1;font-weight:800;color:${t.primary};}
.ach-kicker{font-size:5.8px;letter-spacing:1.2px;text-transform:uppercase;color:${t.muted};font-weight:700;margin-top:2px;}
.ach-hero-mid{padding:0 10px !important;}
.ach-hero-title{font-size:12px;font-weight:800;color:${t.text};}
.ach-hero-bar{height:5px;background-color:${alpha(t.text, "13")};border-radius:99px;margin:5px 0 4px;overflow:hidden;}
.ach-hero-bar i{display:block;height:5px;background-color:${t.primary};background-image:linear-gradient(90deg,${t.primary},${t.secondary});border-radius:99px;}
.ach-hero-meta{font-size:6.5px;color:${t.muted};}
.ach-hero-latest{width:185px;border-left:1px solid ${t.border};}
.ach-latest{width:100%;border-collapse:collapse;}
.ach-latest td{vertical-align:middle;padding:0;}
.ach-latest-art{width:34px;}
.ach-latest-name{font-size:8px;font-weight:800;color:${t.text};line-height:1.15;}
.ach-latest-date{font-size:6px;color:${t.muted};margin-top:1px;}
.ach-latest-empty{font-size:7px;color:${t.muted};margin-top:3px;}
.ach-rarity{width:100%;border-collapse:separate;border-spacing:4px 0;margin:0 0 4px;}
.ach-rarity td{width:20%;background-color:${t.rowEven};border:1px solid ${t.border};border-radius:6px;padding:4px 5px;vertical-align:middle;}
.ach-rarity .k{display:block;font-size:5.5px;letter-spacing:.6px;text-transform:uppercase;font-weight:700;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;}
.ach-rarity .v{display:block;font-family:Consolas,'Courier New',monospace;font-size:8px;font-weight:700;color:${t.text};margin-top:1px;}
.ach-next{width:100%;border-collapse:collapse;}
.ach-next td{padding:4px 4px;border-bottom:1px solid ${alpha(t.border, "b3")};vertical-align:middle;}
.ach-next-art{width:36px;}
.ach-next-name{font-size:8px;font-weight:800;color:${t.text};line-height:1.15;}
.ach-next-meta{font-size:5.8px;letter-spacing:.3px;margin-top:1px;}
.ach-next-prog{width:30%;}
.ach-next-bar{height:3px;background-color:${alpha(t.text, "13")};border-radius:99px;margin-bottom:2px;overflow:hidden;}
.ach-next-bar i{display:block;height:3px;background-color:${t.primary};border-radius:99px;}
.ach-next-prog span{font-family:Consolas,'Courier New',monospace;font-size:6.5px;color:${t.muted};}
.ach-next-pct{width:9%;text-align:right;font-family:Consolas,'Courier New',monospace;font-size:8px;font-weight:700;color:${t.text};}
.ach-grid{width:100%;border-collapse:separate;table-layout:fixed;}
.ach-cell{width:33.33%;vertical-align:top;padding:0;}
.ach-tile{height:150px;background-color:${t.surface};border:1px solid ${t.border};border-top:2px solid ${t.primary};border-radius:9px;padding:6px 5px 4px;text-align:center;overflow:hidden;}
.ach-artwrap{height:68px;position:relative;line-height:66px;text-align:center;}
.ach-art{width:64px;height:64px;vertical-align:middle;}
.ach-check{position:absolute;right:7px;top:1px;width:16px;height:16px;line-height:15px;border-radius:99px;background-color:${t.primary};color:#04110e;font-size:9px;font-weight:900;text-align:center;}
.ach-name{font-size:8.5px;font-weight:800;color:${t.text};line-height:1.2;height:21px;overflow:hidden;}
.ach-cat{font-size:5.8px;letter-spacing:.3px;text-transform:uppercase;color:${t.muted};margin-top:1px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;}
.ach-tile-bar{height:3px;background-color:${alpha(t.text, "12")};border-radius:99px;margin:4px 0 3px;overflow:hidden;}
.ach-tile-bar i{display:block;height:3px;background-color:${t.primary};border-radius:99px;}
.ach-tile-foot{font-size:6px;color:${t.muted};line-height:1.2;overflow:hidden;}
.ach-tile-prog{float:left;max-width:62%;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;}
.ach-tile-foot .ach-rar{float:right;margin:0;padding:0 2px;font-size:5.2px;line-height:1.3;}
.ach-tile.locked .ach-name{color:${t.muted};}
.ach-tile.locked .ach-cat{color:${t.offline};}

/* battle pass track (restored vertical layout) */
.bp-progress{padding:8px 0;border-bottom:1px solid ${t.border};}
.track{width:100%;border-collapse:collapse;}
.trackhead td{font-size:7px;letter-spacing:1px;text-transform:uppercase;color:${t.muted};font-weight:600;padding:4px 0 5px;border-bottom:1px solid ${t.border};}
.trackhead td.r{text-align:right;padding-right:10px !important;}
.trackhead td.p{padding-left:10px !important;}
.trow td{border:0;padding:4px 0;vertical-align:middle;}
.trow.now td{background-color:${alpha("#f5c451", "09")};}
.rew{width:43%;font-size:8px;line-height:1.3;color:${t.text};}
.rew .rtxt{display:inline-block;vertical-align:middle;line-height:1.25;}
.rew .ricon{width:32px;height:32px;vertical-align:middle;margin:0 6px;}
.rew.locked .ricon{opacity:.3;filter:alpha(opacity=30);-webkit-filter:grayscale(1);filter:grayscale(1);}
.rew.free{text-align:right;padding-right:10px !important;}
.rew.premium{text-align:left;padding-left:10px !important;}
.rew.locked{color:${t.muted};}
.nodecell{width:44px;text-align:center;background-image:url('/i/spine.png');background-repeat:repeat-y;background-position:center top;}
.tnode{display:inline-block;width:30px;height:30px;line-height:28px;border:1px solid ${t.border};border-radius:50%;background-color:${t.bg};color:${t.muted};font-family:Consolas,'Courier New',monospace;font-size:9px;font-weight:700;text-align:center;}
.tnode.un{border-color:${alpha(t.primary, "73")};color:${t.primary};background-color:${alpha(t.primary, "0d")};}
.tnode.now{border-color:#f5c451;color:#f5c451;background-color:${alpha("#f5c451", "1a")};font-weight:800;}
.tnode.next{border-color:#f5c451;color:#f5c451;background-color:${alpha("#f5c451", "07")};}
.tracknav{width:100%;border-collapse:collapse;margin-top:2px;border-top:1px solid ${t.border};}
.tracknav td{padding:6px 0;font-size:7.5px;color:${t.muted};}
.tracknav a{font-size:7.5px;color:${t.primary};}
.tracknav .r{text-align:right;}
.bp-skill{width:100%;border-collapse:collapse;}
.bp-skill td{padding:5px 4px;border-bottom:1px solid ${alpha(t.border, "b3")};font-size:8px;color:${t.text};vertical-align:middle;}
.bp-skill .skn{width:34%;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;}
.bp-skill .st{width:13%;text-align:right;font-family:Consolas,'Courier New',monospace;color:${t.muted};white-space:nowrap;}
.bp-skill .gap{width:6%;border-bottom:0 !important;padding:0;}

/* competitive */
.pos.gold{color:#f5c451;font-weight:800;}
.pos.silver{color:#c9d6d2;font-weight:800;}
.pos.bronze{color:#d08a54;font-weight:800;}
.comp-gap{display:block;font-size:6px;color:${t.muted};margin-top:1px;white-space:nowrap;}
.comp-prizes{width:100%;border-collapse:collapse;}
.comp-prizes td{padding:4px 3px;border-bottom:1px solid ${alpha(t.border, "b3")};font-size:7.5px;vertical-align:middle;}
.comp-prizes .k{color:${t.muted};letter-spacing:.5px;text-transform:uppercase;white-space:nowrap;}
.comp-prizes .v{color:${t.text};font-family:Consolas,'Courier New',monospace;font-weight:700;text-align:right;white-space:nowrap;}
.comp-prizes .gap{width:12px;border-bottom:0;padding:0;}

/* VIP */
.vip-hero{width:100%;border-collapse:collapse;background-color:${t.surface};background-image:linear-gradient(90deg,${alpha(t.primary, "0b")},transparent 60%);border-left:3px solid ${t.border};border-radius:0 10px 10px 0;margin-bottom:5px;}
.vip-hero td{padding:8px 10px;vertical-align:middle;}
.vip-crestcol{width:66px;text-align:center;padding-right:2px !important;}
.vip-crest{width:58px;height:58px;}
.vip-tiersmall{width:18px;height:18px;vertical-align:-4px;margin-right:3px;}
.vip-kicker{font-size:6px;letter-spacing:1.4px;text-transform:uppercase;color:${t.muted};font-weight:700;}
.vip-name{font-size:24px;line-height:1.05;font-weight:900;letter-spacing:.5px;margin-top:2px;}
.vip-sub{font-size:7px;color:${t.muted};margin-top:2px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;}
.vip-expiry{font-size:9px;font-weight:800;color:${t.text};}
.vip-perksactive{font-size:6.5px;color:${t.muted};margin-top:2px;}
.vip-tierhead{margin-top:6px;padding:4px 0;border-top:1px solid ${t.border};font-size:7px;color:${t.muted};white-space:nowrap;overflow:hidden;}
.vip-tiername{font-weight:900;letter-spacing:.8px;text-transform:uppercase;font-size:8.5px;}
.vip-tierbonus{color:${t.text};margin-left:6px;font-size:7px;}
.vip-tierprice{float:right;color:${t.muted};font-size:6.5px;letter-spacing:.3px;margin-left:6px;}
.vip-perks{width:100%;border-collapse:collapse;}
.vip-perks td{padding:3px 4px;border-bottom:1px solid ${alpha(t.border, "b3")};font-size:7.5px;vertical-align:middle;}
.vip-perks .perk{width:38%;color:${t.text};}
.vip-perks .state{width:12%;text-align:right;font-size:5.8px;letter-spacing:.5px;color:${t.muted};}
.vip-perks .state.on{color:${t.primary};}
.vip-val{color:${t.primary};font-family:Consolas,'Courier New',monospace;font-size:6.5px;}
.vip-store{width:100%;border-collapse:collapse;}
.vip-store td{padding:4px;border-bottom:1px solid ${alpha(t.border, "b3")};font-size:8px;vertical-align:middle;}
.vip-store .v{font-family:Consolas,'Courier New',monospace;color:${t.muted};text-align:right;width:64px;}
.vip-store .r{text-align:right;width:54px;}

/* events */
.evt-hero{width:100%;border-collapse:collapse;background-color:${t.surface};border-left:3px solid ${t.primary};border-radius:0 10px 10px 0;margin-bottom:5px;}
.evt-hero td{padding:8px 9px;vertical-align:middle;}
.evt-hero .ic{width:52px;text-align:center;}
.evt-hero .name{font-size:15px;font-weight:800;color:${t.text};line-height:1.1;}
.evt-hero .desc{font-size:7px;color:${t.muted};margin-top:2px;}
.evt-hero .right{text-align:right;white-space:nowrap;}
.evt-hero .cd{font-size:6.5px;color:${t.muted};margin-top:2px;}
.evt-list{width:100%;border-collapse:collapse;}
.evt-list th{font-size:5.8px;letter-spacing:.8px;text-transform:uppercase;color:${t.muted};font-weight:600;text-align:left;padding:3px 4px;border-bottom:1px solid ${t.border};}
.evt-list th.ic{width:36px;}
.evt-list th.prog{width:30%;}
.evt-list th.state{width:10%;text-align:right;}
.evt-back{font-size:7px;margin-bottom:2px;}
.evt-back a{color:${t.primary};}
.evt-bar{height:5px;background-color:${alpha(t.text, "14")};border-radius:99px;margin:3px 0 2px;overflow:hidden;}
.evt-bar i{display:block;height:5px;background-color:${t.primary};background-image:linear-gradient(90deg,${t.primary},${t.secondary});border-radius:99px;}
.evt-list td{padding:6px 4px;border-bottom:1px solid ${alpha(t.border, "b3")};vertical-align:middle;}
.evt-list .ic{width:36px;}
.evt-list .ic img{width:28px;height:28px;}
.evt-list .name{font-size:9.5px;font-weight:800;color:${t.text};line-height:1.2;}
.evt-list .desc{font-size:7px;color:${t.muted};margin-top:1px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:260px;}
.evt-list .reward{font-size:6.3px;color:${t.primary};margin-top:1px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:260px;}
.evt-list .prog{width:27%;}
.evt-list .state{width:14%;text-align:right;font-size:5.8px;letter-spacing:.5px;text-transform:uppercase;color:${t.muted};white-space:nowrap;}
.evt-list .state .cd{display:block;font-size:5.5px;color:${t.primary};margin-top:1px;white-space:nowrap;}
.evt-list .state.on{color:${t.primary};}
.evt-history{width:100%;border-collapse:collapse;}
.evt-history td{padding:4px 3px;border-bottom:1px solid ${alpha(t.border, "b3")};font-size:7px;color:${t.text};vertical-align:middle;}
.evt-history .date{text-align:right;color:${t.muted};white-space:nowrap;}

/* achievements hall / records */
.hof-podium{width:100%;border-collapse:separate;border-spacing:4px;}
.hof-pod{width:33.33%;background-color:${t.surface};border:1px solid ${t.border};border-top:3px solid ${t.primary};border-radius:9px;padding:7px 5px;text-align:center;vertical-align:top;}
.hof-pod.vacant{background-color:${t.rowEven};}
.hof-place{font-size:6.5px;letter-spacing:1.2px;font-weight:900;text-transform:uppercase;}
.hof-crest{width:42px;height:42px;margin:3px auto 2px;display:block;}
.hof-name{font-size:9.5px;font-weight:800;color:${t.text};line-height:1.15;height:22px;overflow:hidden;}
.hof-meta{font-size:6.3px;color:${t.muted};margin-top:1px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;}
.hof-vacant{font-size:9px;font-weight:800;color:${t.muted};margin:13px 0 4px;letter-spacing:1px;}
.hof-leaders{width:100%;border-collapse:collapse;}
.hof-leaders th{font-size:6px;letter-spacing:.8px;text-transform:uppercase;color:${t.muted};font-weight:600;padding:4px;border-bottom:1px solid ${t.border};text-align:left;}
.hof-leaders th.c{text-align:center;}
.hof-leaders td{padding:5px 4px;border-bottom:1px solid ${alpha(t.border, "b3")};font-size:8px;vertical-align:middle;}
.hof-leaders td.c{text-align:center;width:8%;}
.hof-k{color:${t.muted};width:33%;letter-spacing:.3px;}
.hof-v{text-align:right;font-family:Consolas,'Courier New',monospace;color:${t.text};white-space:nowrap;}
.hof-leaders .hof-recent-art{width:24px;height:24px;vertical-align:middle;margin-right:4px;}
.hof-leaders a{color:${t.text};}
.rec-grouptitle{margin-top:7px !important;font-weight:800;letter-spacing:1.2px;}
.rec-list{width:100%;border-collapse:collapse;}
.rec-list td{padding:4px;border-bottom:1px solid ${alpha(t.border, "b3")};font-size:7.5px;vertical-align:middle;}
.rec-name{width:34%;color:${t.text};}
.rec-holder{width:34%;}
.rec-holder a{color:${t.text};}
.rec-val{text-align:right;font-family:Consolas,'Courier New',monospace;color:${t.muted};white-space:nowrap;}
.rec-list tr.pending td{color:${t.muted};}

/* missions */
.msn-list{width:100%;border-collapse:collapse;}
.msn-list td{padding:6px 4px;border-bottom:1px solid ${alpha(t.border, "b3")};vertical-align:middle;}
.msn-ic{width:40px;}
.msn-ic img{width:34px;height:34px;}
.msn-title{font-size:9.5px;font-weight:700;color:${t.text};line-height:1.2;}
.msn-desc{display:block;font-size:7.5px;color:${t.muted};margin-top:1px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:300px;}
.msn-prog{width:30%;}
.mbar{height:3px;background-color:${alpha(t.text, "0f")};border-radius:99px;margin-bottom:2px;overflow:hidden;}
.mbar i{display:block;height:3px;background-color:${t.primary};border-radius:99px;}
.msn-prog span{font-family:Consolas,'Courier New',monospace;font-size:7.5px;color:${t.muted};}
.msn-state{width:10%;text-align:right;font-size:6.5px;letter-spacing:.8px;text-transform:uppercase;color:${t.muted};}
.msn-row.done .msn-title{color:${t.primary};}
.msn-row.done .msn-state{color:${t.primary};}
.msn-row.tracker .mbar{display:none;}
.muted{color:${t.muted};} .c{text-align:center;} .r{text-align:right;} .nowrap{white-space:nowrap;}

/* ---------- header ---------- */
.hdr{width:100%;border-collapse:separate;border-spacing:0;background-color:${t.surface};background-image:linear-gradient(120deg,${alpha(t.primary, "10")},transparent 46%);border:1px solid ${t.border};border-radius:12px;margin-bottom:5px;}
.hdr td{padding:8px 9px;vertical-align:middle;}
.hlogo{width:46px;padding-right:1px !important;}
.logotile{width:38px;height:38px;background-color:${t.rowEven};background-image:linear-gradient(145deg,${alpha(t.primary, "1f")},transparent 70%);border:1px solid ${alpha(t.primary, "3d")};border-radius:10px;text-align:center;line-height:38px;}
.logotile img{width:27px;height:27px;}
.kick{font-size:7.5px;letter-spacing:2.1px;text-transform:uppercase;color:${t.muted};}
.title{font-size:26px;line-height:1.02;font-weight:900;letter-spacing:2px;color:${t.primary};text-transform:uppercase;margin-top:1px;}
.title .cur{color:${t.secondary};}
.hright{text-align:right;white-space:nowrap;}
.live{display:inline-block;background-color:${alpha(t.online, "12")};border:1px solid ${alpha(t.online, "59")};border-radius:99px;padding:2px 8px;font-size:7.5px;font-weight:800;letter-spacing:1.1px;color:${t.online};}
.live.off{background-color:transparent;border-color:${t.border};color:${t.offline};}
.dot{display:inline-block;width:6px;height:6px;background-color:${t.online};border-radius:99px;margin-right:4px;vertical-align:1px;}
.dot.stale{background-color:#f5c451;}
.dot.off{background-color:${t.offline};animation:none;}
.hsub{margin-top:4px;font-size:7.5px;letter-spacing:1.5px;color:${t.muted};}
.hsub b{color:${t.text};}

/* ---------- server strip ---------- */
.strip{width:100%;border-collapse:separate;border-spacing:0;background-color:${t.rowEven};border:1px solid ${t.border};border-radius:9px;margin-bottom:5px;}
.strip td{padding:5px 8px;border-left:1px solid ${t.border};vertical-align:middle;}
.strip td.first{border-left:0;}
.strip .k{display:block;font-size:7px;letter-spacing:1.3px;text-transform:uppercase;color:${t.muted};margin-bottom:1px;}
.strip .v{display:block;font-family:Consolas,'Courier New',monospace;font-size:11px;font-weight:700;color:${t.text};white-space:nowrap;overflow:hidden;text-overflow:ellipsis;}
.strip .v.p{color:${t.primary};}

/* ---------- podium ---------- */
.podium{width:100%;border-collapse:separate;margin:0 0 4px;}
.podium td{position:relative;background-color:${t.surface};background-image:linear-gradient(180deg,${t.surface},${t.rowEven});border:1px solid ${t.border};border-top-width:3px;border-radius:12px;padding:9px 7px;text-align:center;vertical-align:bottom;width:33%;}
.podium td.p1{border-color:#f5c451;background-color:#171407;background-image:linear-gradient(180deg,#1d1908,#0d120b);padding-top:11px;}
.podium td.p2{border-color:#c9d6d2;}
.podium td.p3{border-color:#d08a54;}
.ptop{width:100%;border-collapse:collapse;margin-bottom:1px;}
.ptop td{width:auto;position:static;padding:0;border:0;background:transparent;text-align:left;vertical-align:middle;}
.ptop td.r{text-align:right;}
.prank{font-size:8px;letter-spacing:1.3px;color:${t.muted};text-transform:uppercase;white-space:nowrap;}
.p1 .prank{color:#f5c451;font-weight:800;}
.p2 .prank{color:#c9d6d2;}
.p3 .prank{color:#d08a54;}
.pcrest{width:34px;height:34px;margin:3px 0 1px;}
.pname{font-size:12px;font-weight:800;color:${t.text};white-space:nowrap;overflow:hidden;text-overflow:ellipsis;margin-top:1px;}
.pname a{color:${t.text};}
.pname a:hover{color:${t.primary};}
.pxp{font-family:Consolas,'Courier New',monospace;font-size:16px;font-weight:800;color:${t.primary};margin-top:4px;line-height:1;}
.pxp .u{font-family:${t.font};font-size:7px;font-weight:700;letter-spacing:1px;color:${t.muted};margin-left:2px;}
.pbar{height:2px;background-color:${alpha(t.text, "0f")};border-radius:99px;margin:4px 8px 0;overflow:hidden;}
.pbar i{display:block;height:2px;border-radius:99px;}
.pmeta{font-size:8.5px;color:${t.muted};margin-top:4px;white-space:nowrap;}
.youtag{display:inline-block;background-color:${t.primary};color:#04110e;font-size:6.5px;font-weight:900;letter-spacing:.4px;padding:0 3px;border-radius:3px;margin-left:3px;vertical-align:1px;}

/* ---------- level tiles ---------- */
.lvl{display:inline-block;width:32px;height:32px;border:1px solid;border-radius:9px;text-align:center;vertical-align:middle;overflow:hidden;box-shadow:inset 0 1px 0 ${alpha(t.text, "0d")};}
.lvl i{display:block;font-style:normal;font-size:6.5px;line-height:1;letter-spacing:.5px;padding-top:5px;opacity:.7;}
.lvl b{display:block;font-family:Consolas,'Courier New',monospace;font-size:12.5px;line-height:1;font-weight:800;padding-top:1px;}
.lvl.t1{color:#a8beb6;border-color:#2d453d;background-color:#0c1714;}
.lvl.t2{color:${t.primary};border-color:#1d6a4a;background-color:#082018;}
.lvl.t3{color:${t.secondary};border-color:#155d60;background-color:#062022;}
.lvl.t4{color:#b18cff;border-color:#4a3577;background-color:#140c24;}
.lvl.t5{color:#f5c451;border-color:#6b5420;background-color:#1e1706;}
.lvl.t6{color:#ff5f6d;border-color:#7a2530;background-color:#22090c;}
.lvl-img{vertical-align:middle;border:0;}
.plvl{width:38px;height:38px;border-radius:10px;}
.plvl i{font-size:6.5px;padding-top:5px;}
.plvl b{font-size:14px;}

/* ---------- controls ---------- */
.panel{background-color:${t.surface};border:1px solid ${t.border};border-radius:12px;padding:8px;margin-bottom:6px;}
.tools{width:100%;border-collapse:collapse;}
.tools td{padding:0;vertical-align:middle;}
.inp{background-color:${t.bg};color:${t.searchColor};border:1px solid ${t.border};border-radius:7px;padding:4px 8px;font-family:${t.font};font-size:11.5px;height:24px;}
.inp:focus{border-color:${t.secondary};outline:0;}
.btn{background-color:${t.primary};color:#04110e;border:0;border-radius:7px;padding:4px 11px;font-family:${t.font};font-size:9px;font-weight:800;letter-spacing:.6px;text-transform:uppercase;cursor:pointer;}
.btn:hover{background-color:${t.secondary};}
.sel{background-color:${t.bg};color:${t.text};border:1px solid ${t.border};border-radius:7px;font-family:${t.font};font-size:10.5px;padding:2px 4px;height:25px;}
.clr{font-size:8.5px;color:${t.muted};margin-left:5px;}
.pills{margin-top:8px;padding-top:7px;border-top:1px solid ${alpha(t.border, "b3")};}
.pill{display:inline-block;border:1px solid ${t.border};background-color:${t.rowEven};color:${t.muted};padding:3px 9px;margin:0 3px 3px 0;font-size:8.5px;font-weight:700;letter-spacing:.6px;text-transform:uppercase;border-radius:6px;}
a.pill:hover{border-color:${t.secondary};color:${t.secondary};}
.pill.on{background-color:${t.primary};border-color:${t.primary};color:#04110e;}
.wlab{font-size:8px;letter-spacing:1.2px;text-transform:uppercase;color:${t.muted};margin-right:4px;}

/* ---------- roster ---------- */
.boardwrap{background-color:${t.rowEven};border:1px solid ${t.border};border-radius:12px;overflow:hidden;}
.board{width:100%;border-collapse:collapse;table-layout:fixed;}
.board th{background-color:${t.headerBg};border-bottom:1px solid ${t.border};padding:7px 4px;font-size:7.5px;font-weight:700;letter-spacing:1.1px;text-transform:uppercase;color:${t.muted};text-align:right;white-space:nowrap;}
.board th.l{text-align:left;}
.board th.c{text-align:center;}
.board th a{color:${t.muted};}
.board th a:hover{color:${t.primary};}
.board th.on a{color:${t.primary};}
.board td{padding:4px;border-bottom:1px solid ${alpha(t.border, "99")};font-size:11px;color:${t.text};text-align:right;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;vertical-align:middle;height:40px;}
.board td.l{text-align:left;}
.board td.c{text-align:center;}
.board tr{transition:background-color .12s ease;}
.board tr.odd td{background-color:${t.rowOdd};}
.board tr.even td{background-color:${t.rowEven};}
.board tr.you td{background-color:${t.youBg};}
.board.roster td{height:64px;}
.board.roster th{font-size:9px;padding:9px 4px;}
.board.roster .pos{font-size:13px;}
.board.roster .pname-cell{font-size:16px;}
.board.roster .pname-cell a{font-weight:700;}
.board.roster .psub{font-size:10px;margin-top:2px;}
.board.roster .roster-rank{font-size:11.5px;letter-spacing:.1px;}
.board.roster .xpnum{font-size:16px;}
.board tr:hover td{background-color:${t.surface};}
a{transition:color .12s ease;}
@keyframes fnpulse{0%{box-shadow:0 0 0 0 ${alpha(t.online, "59")};}70%{box-shadow:0 0 0 5px ${alpha(t.online, "00")};}100%{box-shadow:0 0 0 0 ${alpha(t.online, "00")};}}
.dot{animation:fnpulse 2.4s ease-out infinite;}
.board tr:last-child td{border-bottom:0;}
.pos{font-family:Consolas,'Courier New',monospace;font-weight:700;color:${t.muted};}
.pos.top{color:${t.primary};}
.pl{width:100%;border-collapse:collapse;}
.pl td{padding:0;border:0;background:transparent !important;height:auto;vertical-align:middle;text-align:left;}
.plv{width:40px;padding-right:8px !important;}
.flag{width:13px;height:10px;border:0;vertical-align:-1px;margin-right:3px;}
.on{color:${t.online};font-size:7px;margin-right:3px;}
.offdot{color:${t.offline};font-size:7px;margin-right:3px;}
.pname-cell{display:block;font-weight:700;font-size:12px;color:${t.text};white-space:nowrap;overflow:hidden;text-overflow:ellipsis;}
.pname-cell a{color:${t.text};}
.pname-cell a:hover{color:${t.primary};}
.psub{display:block;font-size:8px;color:${t.muted};white-space:nowrap;overflow:hidden;text-overflow:ellipsis;margin-top:1px;}
.xpcell{min-width:66px;}
.xpnum{font-family:Consolas,'Courier New',monospace;font-weight:700;line-height:1.1;}
.xpbar{height:2px;background-color:${alpha(t.text, "0f")};border-radius:99px;margin-top:3px;overflow:hidden;}
.xpbar i{display:block;height:2px;border-radius:99px;}
.wcol{color:${t.muted};font-family:Consolas,'Courier New',monospace;}
.rtile{display:inline-block;width:32px;height:32px;line-height:30px;border:1px solid ${t.border};border-radius:8px;background-color:${t.surface};text-align:center;box-shadow:inset 0 1px 0 ${alpha(t.text, "0d")};}
.rankimg{width:28px;height:28px;}

/* ---------- pager + footer ---------- */
.pager{width:100%;border-collapse:collapse;margin-top:6px;}
.pager td{padding:0;vertical-align:middle;}
.pcount{font-size:8px;letter-spacing:1px;text-transform:uppercase;color:${t.muted};}
.pnums{text-align:right;}
.pg{display:inline-block;min-width:16px;border:1px solid ${t.border};background-color:${t.surface};color:${t.pageColor};padding:2px 6px;margin-left:3px;font-size:9px;font-weight:800;text-align:center;border-radius:5px;}
a.pg:hover{border-color:${t.primary};color:${t.primary};}
.pg.on{background-color:${t.primary};border-color:${t.primary};color:#04110e;}
.pg.gap{border:0;background:transparent;color:${t.muted};}
.foot{width:100%;border-collapse:collapse;margin-top:7px;padding-top:5px;border-top:1px solid ${t.border};}
.foot td{padding-top:5px;font-size:7px;letter-spacing:1.1px;color:${t.muted};text-transform:uppercase;vertical-align:middle;}
.foot .r{text-align:right;}
.foot .cr{letter-spacing:0;text-transform:none;color:${t.faint || t.muted};}

/* ---------- profile / stats viewer ---------- */
.backrow{margin:0 0 5px;}
.back{display:inline-block;border:1px solid ${t.border};background-color:${t.surface};border-radius:5px;padding:3px 8px;font-size:7.5px;letter-spacing:1px;text-transform:uppercase;color:${t.muted};}
.back:hover{color:${t.primary};border-color:${t.primary};}
.idpanel{padding:10px;}
.idtable{width:100%;border-collapse:collapse;}
.idtable td{padding:0;border:0;vertical-align:middle;}
.idcrestcell{width:52px;text-align:center;}
.idcrestcell .bigcrest{width:42px;height:42px;}
.idcrestcell .rank-kicker{margin-bottom:1px;}
.lvl.bigtile{width:50px;height:50px;border-radius:12px;}
.lvl.bigtile i{font-size:7.5px;padding-top:8px;}
.lvl.bigtile b{font-size:18px;}
.pbig{font-size:17px;font-weight:800;color:${t.text};line-height:1.15;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;}
.pbig a{color:${t.text};}
.psmall{font-size:8px;color:${t.muted};margin-top:3px;letter-spacing:.3px;}
.pxpbig{font-family:Consolas,'Courier New',monospace;font-size:20px;font-weight:800;color:${t.primary};line-height:1;}
.pxpbig span{font-family:${t.font};font-size:7px;font-weight:700;letter-spacing:1px;color:${t.muted};margin-left:2px;}
.cols{width:100%;border-collapse:collapse;}
.cols td{vertical-align:top;padding:0;border:0;}
.cols .c1{padding-right:10px !important;border-right:1px solid ${t.border} !important;}
.cols .c2{padding:0 10px !important;border-right:1px solid ${t.border} !important;}
.cols .c3{padding-left:10px !important;}
.bigcrest{width:48px;height:48px;display:inline-block;vertical-align:middle;}
.crestbox{width:62px;height:62px;line-height:60px;border:1px solid ${t.border};border-radius:11px;background-color:${t.rowEven};text-align:center;margin-bottom:4px;}
.rank-kicker{font-size:5.5px;letter-spacing:1.4px;text-transform:uppercase;color:${t.muted};margin-bottom:2px;font-weight:700;}
.rankname{font-size:10px;font-weight:700;color:${t.text};line-height:1.2;}
.skillrow{font-size:8.5px;color:${t.muted};margin-top:4px;}
.medalrow{font-size:8.5px;color:${t.muted};margin-top:6px;}
.medalrow2{margin-top:3px;line-height:30px;white-space:nowrap;overflow:hidden;}
.medalrow2 img{width:28px;height:28px;vertical-align:middle;margin-right:3px;}
.medalrow2.single{line-height:66px;text-align:center;margin-top:2px;}
.medalrow2.single img{width:64px;height:64px;margin:0 auto;display:inline-block;vertical-align:middle;}
.medal-name{font-size:6px;letter-spacing:.5px;text-transform:uppercase;color:${t.muted};text-align:center;line-height:1.2;margin-top:1px;}
.c1head{width:100%;border-collapse:collapse;}
.c1head .sect{margin:0;}
.c1head a{font-size:6px;color:${t.primary};letter-spacing:.3px;}
.medalmore{font-size:7px;color:${t.muted};vertical-align:middle;}
.medal-count{font-size:7px;color:${t.muted};margin-top:1px;}
.medal-progress{height:3px;background-color:${alpha(t.text, "12")};border-radius:99px;margin:3px 0 2px;overflow:hidden;}
.medal-progress i{display:block;height:3px;background-color:${t.primary};border-radius:99px;}
.career{width:100%;border-collapse:collapse;background-color:${t.rowEven};border:1px solid ${t.border};border-radius:8px;margin-top:5px;}
.career td{padding:6px 8px;border-left:1px solid ${t.border};vertical-align:top;width:33%;}
.career td.first{border-left:0;}
.career .k{display:block;font-size:5.5px;letter-spacing:1px;text-transform:uppercase;color:${t.muted};font-weight:700;}
.career .v{display:block;font-size:10px;font-weight:800;color:${t.text};margin-top:1px;white-space:nowrap;}
.career .v.p{color:${t.primary};}
.career .sub{display:block;font-size:6.2px;color:${t.muted};margin-top:1px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;}
.career a{font-size:6px;color:${t.primary};letter-spacing:.3px;}
.medalrow img{margin-right:3px;vertical-align:-3px;}
.skill{display:inline-block;padding:1px 6px;border-radius:4px;font-family:Consolas,'Courier New',monospace;font-size:8.5px;font-weight:700;}
.statgrid{width:100%;border-collapse:collapse;}
.statgrid td{padding:4px 2px;border-bottom:1px solid ${alpha(t.border, "99")};vertical-align:middle;}
.statgrid tr:last-child td{border-bottom:0;}
.sk{display:block;font-size:7.5px;letter-spacing:.8px;text-transform:uppercase;color:${t.muted};}
.sv{display:block;font-family:Consolas,'Courier New',monospace;font-size:13px;font-weight:700;color:${t.text};line-height:1.2;}
.sect{font-size:8px;letter-spacing:1.2px;text-transform:uppercase;color:${t.muted};border-bottom:1px solid ${t.border};padding-bottom:3px;margin-bottom:4px;}
.wrow{width:100%;border-collapse:collapse;margin-bottom:3px;}
.wrow td{padding:1px 0;border:0;vertical-align:middle;}
.wbar{height:2px;background-color:${alpha(t.text, "11")};border-radius:99px;margin-top:2px;overflow:hidden;}
.wbar i{display:block;height:2px;background-color:${t.primary};border-radius:99px;}
.wicon{width:32px;}
.wtile{display:inline-block;width:28px;height:28px;line-height:26px;border:1px solid ${t.border};border-radius:7px;background-color:${t.rowEven};text-align:center;}
.wtile img{width:22px;height:22px;vertical-align:middle;}
.wname{font-size:9px;color:${t.text};white-space:nowrap;overflow:hidden;text-overflow:ellipsis;}
.wk{font-family:Consolas,'Courier New',monospace;font-size:10px;color:${t.primary};text-align:right;font-weight:700;}
.proghead{width:100%;border-collapse:collapse;margin-bottom:4px;}
.proghead td{padding:0;border:0;font-size:7.5px;letter-spacing:.7px;color:${t.muted};text-transform:uppercase;}
.progbar{height:4px;background-color:${alpha(t.text, "0f")};border-radius:99px;overflow:hidden;}
.progbar i{display:block;height:4px;background-color:${t.primary};border-radius:99px;}
.msg{padding:18px 10px;text-align:center;color:${t.muted};font-size:10px;line-height:1.6;}
.msg b{color:${t.text};}

/* readability pass — larger MOTD typography */
html,body{font-size:14px;}
.ph-k{font-size:9px;}
.ph-s{font-size:10px;}
.back2{font-size:8.5px;}
.live2{font-size:8.5px;}
.kpis .k{font-size:8px;}
.kpis .v{font-size:13px;}
.sect{font-size:9.5px;}
.pill{font-size:9.5px;padding:4px 10px;}
.wlab{font-size:9px;}
.inp,.sel{font-size:12px;height:27px;}
.btn{font-size:10px;}
.strip .k{font-size:8px;}
.strip .v{font-size:12.5px;}
.board th{font-size:8.5px;}
.board td{font-size:13px;height:44px;}
.pname-cell{font-size:14px;}
.psub{font-size:10px;}
.xpnum{font-size:14px;}
.pos{font-size:12px;}
.pcount{font-size:9px;}
.pg{font-size:10px;}
.foot td{font-size:7.5px;}
.msg{font-size:11px;}
.proghead td{font-size:9px;}
.ach-kicker{font-size:7px;}
.ach-pct{font-size:34px;}
.ach-hero-title{font-size:14px;}
.ach-hero-meta{font-size:8px;}
.ach-hero-latest{width:195px;}
.ach-latest-name{font-size:9.5px;}
.ach-latest-date{font-size:7px;}
.ach-rarity .k{font-size:6.8px;}
.ach-rarity .v{font-size:9px;}
.ach-next-name{font-size:10px;}
.ach-next-meta{font-size:7.2px;}
.ach-next-prog span{font-size:8px;}
.ach-next-pct{font-size:9.5px;}
.ach-tile{height:164px;}
.ach-name{font-size:10.5px;height:25px;}
.ach-cat{font-size:7px;}
.ach-tile-foot{font-size:7.2px;}
.ach-tile-foot .ach-rar{font-size:6.3px;}
.trackhead td{font-size:8.5px;}
.rew{font-size:10px;}
.tracknav td,.tracknav a{font-size:9px;}
.tnode{font-size:10.5px;}
.bp-skill td{font-size:9.5px;}
.comp-gap{font-size:7px;}
.comp-prizes td{font-size:9px;}
.vip-kicker{font-size:7px;}
.vip-sub{font-size:8.5px;}
.vip-expiry{font-size:10px;}
.vip-perksactive{font-size:8px;}
.vip-tierhead{font-size:8.5px;}
.vip-tiername{font-size:10px;}
.vip-tierbonus{font-size:8px;}
.vip-tierprice{font-size:7.5px;}
.vip-perks td{font-size:9px;}
.vip-perks .state{font-size:7px;}
.vip-val{font-size:7.5px;}
.vip-store td{font-size:9.5px;}
.evt-hero .name{font-size:17px;}
.evt-hero .desc{font-size:9px;}
.evt-hero .cd{font-size:8px;}
.evt-back{font-size:8.5px;}
.evt-list th{font-size:7px;}
.evt-list .name{font-size:12px;}
.evt-list .desc{font-size:8.5px;max-width:230px;}
.evt-list .reward{font-size:7.5px;max-width:230px;}
.evt-list .state{font-size:7px;}
.evt-list .state .cd{font-size:7px;}
.evt-history td{font-size:8.5px;}
.hof-place{font-size:8px;}
.hof-name{font-size:11px;}
.hof-meta{font-size:7.5px;}
.hof-leaders th{font-size:7px;}
.hof-leaders td{font-size:9.5px;}
.rec-list td{font-size:9px;}
.msn-title{font-size:11px;}
.msn-desc{font-size:9px;max-width:320px;}
.msn-prog span{font-size:8.5px;}
.msn-state{font-size:7.5px;}
.pbig{font-size:18px;}
.psmall{font-size:9px;}
.rankname{font-size:11px;}
.skillrow{font-size:9.5px;}
.medal-count{font-size:8px;}
.c1head a{font-size:7.5px;}
.medal-name{font-size:7px;}
.career .k{font-size:6.5px;}
.career .v{font-size:11px;}
.career .sub{font-size:7.5px;}
.career a{font-size:7px;}
.statgrid .sk{font-size:8.5px;}
.statgrid .sv{font-size:14px;}
.wname{font-size:10px;}
.wk{font-size:11px;}
.proghead td{font-size:9px;}
` 
}

function headerLink(c, field, label, cls) {
  const active = c.sort === field
  const f = SORT_FIELDS[field]
  const def = (f && f.dirDefault) || "desc"
  const next = active ? (c.dir === "desc" ? "asc" : "desc") : def
  const arrow = active ? (c.dir === "asc" ? " ↑" : " ↓") : ""
  const href = `/top15?${stateQuery(c, { sort: field, dir: next, page: 1 })}`
  return `<th class='${cls || ""}${active ? " on" : ""}'><a href='${href}'>${esc(label)}${arrow}</a></th>`
}

function sortPills(c) {
  const keys = ["xp", "kills", "kd", "hs", "wins", "rank", "level"]
  return `<div class='pills'>${keys.map(k => {
    const f = SORT_FIELDS[k]
    if (!f) return ""
    const active = c.sort === k
    const def = f.dirDefault || "desc"
    const next = active ? (c.dir === "desc" ? "asc" : "desc") : def
    return `<a class='pill${active ? " on" : ""}' href='/top15?${stateQuery(c, { sort: k, dir: next, page: 1 })}'>${esc(f.label)}${active ? (c.dir === "asc" ? " ↑" : " ↓") : ""}</a>`
  }).join("")}</div>`
}

function levelTile(r, size) {
  const lvl = Math.max(1, Number(r.level) || 1)
  const px = size === "lg" ? 50 : size === "roster" ? 48 : size === "md" ? 38 : 34
  if (lvl <= 100) {
    return `<img class='lvl-img' src='/i/lvl_${String(lvl).padStart(3, "0")}.png?v=4' width='${px}' height='${px}' alt='Level ${lvl}' title='Level ${lvl} · ${esc(rankName(r))}'>`
  }
  const big = size === "lg" || size === "md"
  return `<span class='lvl ${tierOf(r)}${big ? " plvl" : ""}' title='Level ${lvl} · ${esc(rankName(r))}'><i>LVL</i><b>${lvl}</b></span>`
}

function xpBar(xp, max, color) {
  const pct = Math.max(2, Math.min(100, (Number(xp) || 0) * 100 / (max || 1)))
  return `<div class='xpbar'><i style='width:${pct.toFixed(1)}%;background-color:${color}'></i></div>`
}

function podiumCard(r, pos, c, now, maxXp) {
  const me = c.steamid && r.steamid === c.steamid
  const on = isOn(r, now)
  const name = r.name || r.steamid || "Unknown"
  const cls = pos === 1 ? "p1" : pos === 2 ? "p2" : "p3"
  const xpCol = xpColorOf(r.xp)
  return `<td class='${cls}' valign='bottom'>
    <table class='ptop' cellspacing='0' cellpadding='0'><tr>
      <td class='prank'>#${pos}${pos === 1 ? " · champion" : ""}</td>
    </tr></table>
    <img class='pcrest' src='${rankFile(r)}' width='31' height='31' alt='${esc(rankName(r))}' title='${esc(rankName(r))}'>
    <div class='pname'><span class='${on ? "on" : "offdot"}'>●</span>${flagImg(r.cc, 13, 10)}<a href='/profile?steamid=${encodeURIComponent(r.steamid || "")}'>${esc(name)}</a>${me ? `<span class='youtag'>YOU</span>` : ""}</div>
    <div class='pxp' style='color:${xpCol}'>${fmt(r.xp)}<span class='u'>XP</span></div>
    ${xpBar(r.xp, maxXp, xpCol)}
    <div class='pmeta'>L${Number(r.level) || 1} · ${kdOf(r)} K/D · ${hsOf(r) === "—" ? "—" : hsOf(r) + "%"} HS · W ${fmt(r.wins)}</div>
  </td>`
}

function pageNumbers(cur, pages) {
  const out = []
  const push = n => out.push(n)
  if (pages <= 6) {
    for (let i = 1; i <= pages; i++) push(i)
    return out
  }
  push(1)
  if (cur > 3) push("…")
  for (let i = Math.max(2, cur - 1); i <= Math.min(pages - 1, cur + 1); i++) push(i)
  if (cur < pages - 2) push("…")
  push(pages)
  return out
}

function pager(c, total, cur, pages) {
  const nums = pageNumbers(cur, pages).map(n => n === "…"
    ? `<span class='pg gap'>…</span>`
    : n === cur ? `<span class='pg on'>${n}</span>`
      : `<a class='pg' href='/top15?${stateQuery(c, { page: n })}'>${n}</a>`).join("")
  return `<table class='pager' cellspacing='0' cellpadding='0'><tr>
    <td class='pcount'>${fmt(total)} ranked · page ${cur} / ${pages}</td>
    <td class='pnums'>
      ${cur > 1 ? `<a class='pg' href='/top15?${stateQuery(c, { page: cur - 1 })}'>‹</a>` : ""}
      ${nums}
      ${cur < pages ? `<a class='pg' href='/top15?${stateQuery(c, { page: cur + 1 })}'>›</a>` : ""}
    </td>
  </tr></table>`
}

function weaponHeader(c, wpn) {
  const active = c.sort === "weapon"
  const def = (SORT_FIELDS.weapon && SORT_FIELDS.weapon.dirDefault) || "desc"
  const next = active ? (c.dir === "desc" ? "asc" : "desc") : def
  const arrow = active ? (c.dir === "asc" ? " ↑" : " ↓") : ""
  return `<th class='${active ? "on" : ""}'><a href='/top15?${stateQuery(c, { sort: "weapon", dir: next, page: 1 })}' title='${esc(wpn.name)} kills'><img src='${wpn.img}' width='14' height='14' style='vertical-align:-3px;margin-right:2px' alt=''>${esc(wpn.short || wpn.name)}${arrow}</a></th>`
}

export function motdFrame({ theme, title, kicker, sub, meta, content, backHref, backLabel }) {
  const MOTD = isMotdCompact()
  const fresh = meta && meta.lastPush && (Date.now() / 1000 - meta.lastPush) <= 90
  const live = Boolean(meta && meta.online && fresh)
  const stale = Boolean(meta && meta.online && !fresh)
  const state = live ? `${meta.players} online` : (stale ? "stale" : "offline")
  const stateCls = live ? "" : (stale ? " stale" : " off")
  const back = backHref
    ? `<a class='back2' href='${esc(backHref)}'>‹ ${esc(backLabel || "Back")}</a>`
    : ""
  const html = `<!DOCTYPE html><html><head><meta charset='utf-8'><title>FreeNova | ${esc(title)}</title>
  <meta name='viewport' content='width=620'>
  <link rel='icon' href='/i/logo_mark.png'><style>${css(theme)}</style></head>
  <body bgcolor='${theme.bg}' text='${theme.text}'><div class='wrap'${MOTD ? " style='width:auto;'" : ""}>
  <table class='top2' cellspacing='0' cellpadding='0'><tr>
    <td>
      <a class='brand2' href='/' aria-label='FreeNova home'>
        <span class='mark'><img src='/i/logo_mark.png' width='23' height='23' alt=''></span>
        <span class='bn'><b>FREE<i>NOVA</i></b><span>NETWORK · CS 1.6</span></span>
      </a>
    </td>
    <td class='topright'>
      ${back}
      <span class='live2${stateCls}'><span class='dot${stateCls.replace(" ", "")}'></span>${state}</span>
    </td>
  </tr></table>
  <div class='pagehead'>
    <div class='ph-k'>${esc(kicker || "Rank System")}</div>
    <div class='ph-t'>${esc(title)}<span class='cur'>_</span></div>
    <div class='ph-s'>${esc(sub || "")}</div>
  </div>
  ${content}
  <table class='foot' cellspacing='0' cellpadding='0'><tr>
    <td>FreeNova · CS 1.6 · <span class='cr'>Icons: game-icons.net</span></td>
    <td class='r'>Snapshot every 30s · ${fmt(meta ? meta.ranked : 0)} tracked</td>
  </tr></table>
  </div></body></html>`
  return new Response(html, {
    headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" }
  })
}

export function renderTop15({ contract: c, rows, total, theme, now, meta }) {
  const wpn = weaponById(c.weapon)
  const ranked = meta ? meta.ranked : total
  const onlineNow = meta ? meta.onlineNow : rows.filter(r => isOn(r, now)).length
  const sync = meta && meta.lastPush ? ago(now - meta.lastPush) + " ago" : "—"
  const map = meta && meta.map ? meta.map : "—"
  const players = meta ? `${meta.players}/${meta.maxplayers || 32}` : "—"

  const pages = Math.max(1, Math.ceil(total / c.pageSize))
  const cur = Math.min(c.page, pages)
  const start = (c.page - 1) * c.pageSize
  const podiumRows = c.page === 1 ? rows.slice(0, 3) : []
  const boardRows = c.page === 1 ? rows.slice(3) : rows
  const offset = c.page === 1 ? start + 3 : start
  const maxXp = Math.max(1, ...rows.map(r => Number(r.xp) || 0))

  let podium = ""
  if (podiumRows.length) {
    const cards = []
    if (podiumRows[1]) cards.push(podiumCard(podiumRows[1], 2, c, now, maxXp))
    if (podiumRows[0]) cards.push(podiumCard(podiumRows[0], 1, c, now, maxXp))
    if (podiumRows[2]) cards.push(podiumCard(podiumRows[2], 3, c, now, maxXp))
    podium = `<table class='podium' cellspacing='4' cellpadding='0'><tr>${cards.join("")}</tr></table>`
  }

  let body = `<table class='kpis' cellspacing='4' cellpadding='0'><tr>
    <td><span class='k'>Map</span><span class='v'>${esc(map)}</span></td>
    <td><span class='k'>Players</span><span class='v p'>${esc(players)}</span></td>
    <td><span class='k'>Online</span><span class='v'>${fmt(onlineNow)}</span></td>
    <td><span class='k'>Synced</span><span class='v'>${esc(sync)}</span></td>
  </tr></table>

  ${podium}

  <div class='panel'>
    <table class='tools' cellspacing='0' cellpadding='0'><tr>
      <td width='55%'>
        <form method='get' action='/top15'>
          ${c.steamid ? `<input type='hidden' name='steamid' value='${esc(c.steamid)}'>` : ""}
          <input type='hidden' name='sort' value='${esc(c.sort)}'>
          <input type='hidden' name='dir' value='${esc(c.dir)}'>
          <input type='hidden' name='w' value='${c.weapon}'>
          <input class='inp' type='text' name='q' value='${esc(c.q)}' size='14' title='Search player' placeholder='Search player'>
          <input class='btn' type='submit' value='Search'>
          ${c.q ? `<a class='clr' href='/top15?${stateQuery(c, { q: "", page: 1 })}'>clear</a>` : ""}
        </form>
      </td>
      <td class='r'>
        <form method='get' action='/top15'>
          ${c.steamid ? `<input type='hidden' name='steamid' value='${esc(c.steamid)}'>` : ""}
          <input type='hidden' name='sort' value='${esc(c.sort)}'>
          <input type='hidden' name='dir' value='${esc(c.dir)}'>
          <input type='hidden' name='q' value='${esc(c.q)}'>
          <span class='wlab'>Weapon</span>
          <select class='sel' name='w' onchange='this.form.submit()'>
            ${TORNADO_WEAPONS.map(w => `<option value='${w.id}'${w.id === c.weapon ? " selected" : ""}>${esc(w.name)}</option>`).join("")}
          </select>
          <input class='btn' type='submit' value='Go'>
        </form>
      </td>
    </tr></table>
    ${sortPills(c)}
  </div>

  <div class='boardwrap'>
  <table class='board' cellspacing='0' cellpadding='0'>
    <colgroup>
      <col style='width:6%'><col style='width:34%'><col style='width:14%'>
      <col style='width:7%'><col style='width:10%'><col style='width:9%'>
      <col style='width:9%'><col style='width:11%'>
    </colgroup>
    <tr>
      <th class='c'>#</th>
      ${headerLink(c, "name", "Player", "l")}
      ${headerLink(c, "xp", "XP")}
      ${headerLink(c, "kills", "K")}
      ${weaponHeader(c, wpn)}
      ${headerLink(c, "kd", "K/D")}
      ${headerLink(c, "hs", "HS%")}
      ${headerLink(c, "rank", "Rank", "c")}
    </tr>`

  if (boardRows.length) {
    let i = 0
    for (const r of boardRows) {
      i++
      const pos = offset + i
      const me = c.steamid && r.steamid === c.steamid
      const on = isOn(r, now)
      const name = r.name || r.steamid || "Unknown"
      const cls = me ? "you" : (i % 2 ? "odd" : "even")
      const xpCol = xpColorOf(r.xp)
      body += `<tr class='${cls}'>
        <td class='c'><span class='pos${pos <= 3 ? " top" : ""}'>${pos}</span></td>
        <td class='l'>
          <table class='pl' cellspacing='0' cellpadding='0'><tr>
            <td class='plv'>${levelTile(r)}</td>
            <td>
              <span class='pname-cell'>${flagImg(r.cc, 13, 10)}<a href='/profile?steamid=${encodeURIComponent(r.steamid || "")}'>${esc(name)}</a>${me ? "<span class='youtag'>YOU</span>" : ""}</span>
              <span class='psub'><span class='${on ? "on" : "offdot"}'>●</span>${esc(rankName(r))}${on ? " · online" : ""}</span>
            </td>
          </tr></table>
        </td>
        <td class='xpcell'><div class='xpnum' style='color:${xpCol}'>${fmt(r.xp)}</div></td>
        <td>${fmt(r.kills)}</td>
        <td class='wcol'>${fmt(r.wpn)}</td>
        <td>${kdOf(r)}</td>
        <td>${hsOf(r) === "—" ? "—" : hsOf(r) + "%"}</td>
        <td class='c'><span class='rtile'><img class='rankimg' src='${rankFile(r)}' width='20' height='20' alt='${esc(rankName(r))}' title='${esc(rankName(r))}'></span></td>
      </tr>`
    }
  } else {
    const note = total === 0
      ? (c.q ? `No player matches “${esc(c.q)}”.` : "No ranked players yet.")
      : (c.page === 1 ? "All ranked players are on the podium." : "No players on this page.")
    body += `<tr><td colspan='8' class='c muted' style='padding:16px 4px;'>${note}</td></tr>`
  }
  body += `</table>
  </div>
  ${pager(c, total, cur, pages)}`

  return motdFrame({
    theme,
    title: "Leaderboard",
    kicker: "Rank System · Season 1",
    sub: `Live CS 1.6 rankings · ${fmt(ranked)} players · updated every 30s`,
    meta,
    content: body
  })
}

export { SORT_FIELDS }
export { esc, fmt, alpha, rankName, rankFile, tierOf, levelTile, xpBar, isOn, ago, kdOf, hsOf, css, RANK_NAMES, podiumCard }

