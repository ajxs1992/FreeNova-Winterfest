// Public hub — the directory of every MOTD panel, in the new shell.
import { loadTheme } from "./top15/store.js"
import { serverMeta } from "./top15/meta.js"
import { motdFrame, esc } from "./top15/render.js"

const PRODUCTS = [
  ["P", "Profile", "profile", "Rank, XP, K/D and career stats", "#7dd3fc"],
  ["T", "Top 15", "top15", "The server leaderboard", "#fbbf24"],
  ["B", "Battle Pass", "battlepass", "Season track · free and premium", "#e8c547"],
  ["I", "Missions", "missions", "Daily and weekly contracts", "#36DEAB"],
  ["A", "Achievements", "achievements", "Medals, records and hall of fame", "#c084fc"],
  ["R", "Competitive", "tournament", "Season standings and points", "#f07178"],
  ["V", "VIP", "vip", "Membership tiers and perks", "#e8c547"],
  ["E", "Events", "events", "Live server events", "#2EBF92"],
  ["S", "Coin Shop", "shop", "Skills, equipment and store offers", "#e8c547"],
  ["K", "Weapon Skins", "skins", "Preview ownership and equip in game", "#7dd3fc"],
  ["M", "Player Models", "models", "Model ownership and selection", "#c084fc"],
  ["C", "Cosmetics", "cosmetics", "Spawn effects, titles and tags", "#36DEAB"],
  ["G", "Settings", "settings", "HUD, language and low-performance mode", "#9aa4b2"],
  ["U", "Rules", "rules", "Community and server rules", "#f07178"],
  ["D", "Discord", "https://discord.gg/vuGaWjuX", "Official community invite", "#7289da"],
  ["Z", "Admin Panel", "admin", "Staff only - session protected", "#e8c547"]
]

export async function pageHub(env, url) {
  const theme = await loadTheme(env)
  const now = Math.floor(Date.now() / 1000)
  const meta = await serverMeta(env, now)
  let rows = []
  for (let i = 0; i < PRODUCTS.length; i += 2) rows.push([PRODUCTS[i], PRODUCTS[i + 1]])

  const card = p => p
    ? `<a class='pcard3' href='${/^https?:/i.test(p[2]) ? p[2] : "/" + p[2]}'>
        <span class='pcode' style='color:${p[4]};border-color:${p[4]}'>${p[0]}</span>
        <span class='pinfo'><b>${esc(p[1])}</b><small>${esc(p[3])}</small></span>
        <span class='parr'>›</span>
      </a>`
    : ""

  const grid = `<table class='grid' cellspacing='0' cellpadding='0'>${rows.map(r =>
    `<tr><td>${card(r[0])}</td><td class='r'>${card(r[1])}</td></tr>`
  ).join("")}</table>
  <div class='panel' style='margin-top:2px;'>
    <span class='muted' style='font-size:8px;'>Tools:</span>
    <a href='/statsviewer' style='font-size:8px;'>Stats Viewer</a>
    <span class='muted' style='font-size:8px;'> · </span>
    <a href='/icons' style='font-size:8px;'>Icon Gallery</a>
  </div>`

  return motdFrame({
    theme,
    meta,
    title: "Panels",
    kicker: "FreeNova Network",
    sub: "Open a panel · every product is also available in game",
    content: grid
  })
}
