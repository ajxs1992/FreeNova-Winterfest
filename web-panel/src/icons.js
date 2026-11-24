import { TORNADO_WEAPONS } from "./top15/theme.js"
import { html, esc } from "./ui.js"

function categoryOf(id) {
  if (id === 0 || id === 25) return "Equipment"
  if (id >= 1 && id <= 6) return "Pistols"
  if (id >= 7 && id <= 8) return "Shotguns"
  if (id >= 9 && id <= 13) return "Submachine Guns"
  if (id === 14) return "Machine Gun"
  return "Rifles"
}

const EXTRA = [
  { id: -2, name: "C4 Bomb", img: "/i/gun_c4.png", category: "Equipment" },
  { id: -1, name: "Flashbang", img: "/i/gun_flashbang.png", category: "Equipment" }
]

async function assetOk(env, path) {
  if (!env || !env.ASSETS) return "unknown (no asset binding)"
  try {
    const res = await env.ASSETS.fetch(new Request("https://x" + path))
    return res && res.status === 200 ? "ok" : "missing (" + (res && res.status) + ")"
  } catch {
    return "error"
  }
}

export async function pageIcons(env, url) {
  const sizes = [24, 32, 48, 64]
  const items = [...TORNADO_WEAPONS, ...EXTRA]
  let cards = ""
  for (const w of items) {
    const file = String(w.img || "").split("/").pop()
    const status = await assetOk(env, w.img)
    const row = sizes.map(s =>
      `<img src='${w.img}' height='${s}' alt='${esc(w.name)}' border='0'>`
    ).join(" ")
    cards += `<div class='card'><div class='h2'>${esc(w.name)}</div>
      <p class='muted small'>${esc(file)} · ${esc(categoryOf(w.id))} · status: ${esc(status)}</p>
      <div style='background:#04110e;padding:8px;margin-bottom:6px;'>${row}</div>
      <div style='background:#6b7280;padding:8px;'><img src='${w.img}' height='32' alt='${esc(w.name)}' border='0'> <span class='muted small'>mid-gray reference (white art needs dark surfaces)</span></div>
    </div>`
  }
  const body = `<div class='card'><div class='h2'>ICON GALLERY</div>
    <p class='muted'>All weapon + equipment icons at 24 / 32 / 48 / 64 px on dark, plus a mid-gray reference strip. White monochrome art is built for dark surfaces.</p></div>
    ${cards}`
  return html("ICON GALLERY", body, { product: "top" })
}
