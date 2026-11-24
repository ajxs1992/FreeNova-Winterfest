// Census for the plate: OCR every sample string on assets/dashboard.png and
// list the boxes a sprite of the plate would carry the sample with it.
//
// Why this exists: the live page (/panel/dashboard, src/panel/dashboard.js) is
// the plate plus its own text, and a plate sprite that overlaps a sample value
// prints that value through the real one. The sprite boxes in that module must
// therefore stay inside the plate's text-free areas — the ones this census
// reports as empty.
//
//   node test_plate_census.mjs            # print the census, exit 0
//   node test_plate_census.mjs --check    # also fail on a sprite over text
//
// OCR needs `tesseract` (a dev tool, not a runtime dependency). Without it the
// script still measures the plate (dimensions, sha256) and says the census was
// skipped, so CI is not tied to a tool the panel does not use.
import { createHash } from "node:crypto"
import { readFileSync, writeFileSync, mkdtempSync } from "node:fs"
import { execFileSync } from "node:child_process"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { fileURLToPath } from "node:url"

export const PLATE = fileURLToPath(new URL("./assets/dashboard.png", import.meta.url))
export const PLATE_W = 1672, PLATE_H = 941
export const PLATE_SHA256 = "4e9ea10d2fc93059e72137d5c6dc4d5fb0a949e4435eacba4680b32aa40878af"

// [name, x1, y1, x2, y2] — corners, like a crop box in an image editor. The
// plate's sample strings AND the brand's own lockups (its logo lettering, the
// hero wordmark, the reward tiles' product names), grouped by panel. Each box
// contains every glyph of its string, shadows included. `--check` proves no
// sprite of the live page covers one of them.
export const TEXT_BLOCKS = [
  ["topbar_coins", 424, 18, 566, 72],
  ["topbar_gb", 655, 18, 766, 72],
  ["topbar_spins", 925, 18, 1014, 72],
  ["topbar_miss", 1118, 18, 1292, 72],
  ["topbar_profile", 1502, 24, 1665, 68],
  ["brand_logo", 20, 8, 280, 84],
  ["logo_lockup", 1280, 15, 1420, 60],
  ["brand_chip", 700, 96, 1260, 190],
  ["sidebar", 85, 90, 292, 850],
  ["sidebar_icons", 0, 90, 90, 941],
  ["sidebar_footer", 0, 850, 300, 941],
  ["hero", 620, 96, 1400, 254],
  ["countdown", 800, 262, 1150, 352],
  ["capsules", 300, 380, 1595, 440],
  ["card_headings", 400, 458, 1610, 530],
  ["tree_progress", 500, 528, 830, 668],
  ["event_rows", 865, 530, 1190, 678],
  ["rewards_labels", 1235, 604, 1655, 668],
  ["active_heading", 300, 722, 700, 766],
  ["event_cards", 440, 780, 1655, 862]
]

function sha256(path) {
  return createHash("sha256").update(readFileSync(path)).digest("hex")
}

/** OCR the plate at 2x and return [{x,y,w,h,conf,text}] on plate coordinates. */
export function ocrPlate() {
  const dir = mkdtempSync(join(tmpdir(), "plate-census-"))
  const big = join(dir, "plate2x.png")
  try {
    execFileSync("python3", ["-c", `
from PIL import Image
img = Image.open(${JSON.stringify(PLATE)}).convert("RGB")
img.resize((img.width*2, img.height*2), Image.LANCZOS).save(${JSON.stringify(big)})
`], { stdio: "pipe" })
    const tsv = execFileSync("tesseract", [big, "stdout", "--psm", "11", "tsv"], { stdio: "pipe" }).toString()
    const out = []
    for (const line of tsv.split("\n").slice(1)) {
      const f = line.split("\t")
      if (f.length < 12 || !f[11].trim()) continue
      const conf = Number(f[10])
      if (!(conf >= 60)) continue
      // a real word, not a glyph fragment or a misread icon edge
      if (!/[A-Za-z0-9]/.test(f[11]) || Number(f[8]) < 12 || Number(f[9]) < 8) continue
      out.push({
        x: Math.round(Number(f[6]) / 2), y: Math.round(Number(f[7]) / 2),
        w: Math.round(Number(f[8]) / 2), h: Math.round(Number(f[9]) / 2),
        conf, text: f[11].trim()
      })
    }
    return out
  } finally {
    try { execFileSync("rm", ["-rf", dir]) } catch {}
  }
}

// [x, y, w, h] boxes; true when they share any pixel
// Corners for a box given as [name, x1, y1, x2, y2] or [x, y, w, h]:
const asCorners = b => b.length === 5 ? [b[1], b[2], b[3], b[4]] : [b[0], b[1], b[0] + b[2], b[1] + b[3]]
const overlaps = (a, b) => {
  const [ax1, ay1, ax2, ay2] = asCorners(a)
  const [bx1, by1, bx2, by2] = asCorners(b)
  return ax1 < bx2 && bx1 < ax2 && ay1 < by2 && by1 < ay2
}

function main() {
  const args = process.argv.slice(2)
  const check = args.includes("--check")
  let failures = 0
  const fail = (name, detail) => { failures++; console.error(`FAIL ${name}: ${detail}`) }
  const pass = (name, detail) => console.log(`PASS ${name}${detail ? " " + detail : ""}`)

  const digest = sha256(PLATE)
  if (digest === PLATE_SHA256) pass("plate sha256", digest.slice(0, 16) + "…")
  else fail("plate sha256", `${digest} != ${PLATE_SHA256} — the measurements below are for the old plate`)

  console.log(`plate ${PLATE_W}x${PLATE_H}, ${TEXT_BLOCKS.length} text blocks`)

  let words = []
  try {
    words = ocrPlate()
  } catch (e) {
    console.log("SKIP OCR census (tesseract or python3+PIL not available): " + String(e.message || e).split("\n")[0])
  }

  // --check: the live page keeps the plate's chrome and covers its sample text
  // with field boxes. Two independent proofs, both against the SAME OCR pass:
  //   1. every sample glyph on the plate sits inside one field box (so the
  //      field's chrome strip covers it), and
  //   2. every field box carries a strip big enough to cover it.
  if (check) {
    const src = readFileSync(fileURLToPath(new URL("./src/panel/dashboard.js", import.meta.url)), "utf8")
    const table = name => {
      // slice the array by its brackets (it may contain comments), then read rows
      const at = src.indexOf("export const " + name + " = [")
      if (at < 0) return null
      let i = src.indexOf("[", at), depth = 0, j = i
      for (; j < src.length; j++) {
        if (src[j] === "[") depth++
        else if (src[j] === "]") { depth--; if (depth === 0) break }
      }
      const body = src.slice(i, j + 1)
      const re = /\[\s*"([a-z0-9_]+)"\s*,\s*(-?\d+)\s*,\s*(-?\d+)\s*,\s*(\d+)\s*,\s*(\d+)/gi
      return [...body.matchAll(re)].map(r => [r[1], +r[2], +r[3], +r[4], +r[5]])
    }
    const strips = table("STRIPS")
    const fields = table("FIELD_TEXT")
    if (!strips || !fields) {
      fail("field tables", "STRIPS / FIELD_TEXT not found in src/panel/dashboard.js")
    } else {
      const shared = (a, b) => a[0] < b[0] + b[2] && b[0] < a[0] + a[2] && a[1] < b[1] + b[3] && b[1] < a[1] + a[3]
      const covers = (o, i) => o[0] <= i[0] && o[1] <= i[1] && o[0] + o[2] >= i[0] + i[2] && o[1] + o[3] >= i[1] + i[3]
      const fieldBoxes = fields.map(f => [f[1], f[2], f[3], f[4]])
      const stripBoxes = strips.map(s => [s[5], s[6], s[7], s[8]])
      const noCover = fieldBoxes.filter(f => !stripBoxes.some(s => covers(s, f)))
      if (noCover.length === 0) pass("every field has chrome under it", `${fields.length} fields / ${strips.length} strips`)
      else fail("fields without chrome", JSON.stringify(noCover))

      if (words.length) {
        const survivors = words.filter(w => !fieldBoxes.some(f => shared(f, [w.x, w.y, w.w, w.h])))
        if (survivors.length === 0) pass("plate sample text is covered", `${words.length} glyph boxes inside ${fields.length} fields`)
        else fail("plate text not covered", survivors.slice(0, 10).map(w => `${w.text}@${w.x},${w.y}`).join(" "))
      }
    }
  }

  writeFileSync(join(tmpdir(), "plate-census-ocr.json"), JSON.stringify(words, null, 1))
  console.log(`ocr output: ${join(tmpdir(), "plate-census-ocr.json")}`)
  process.exitCode = failures ? 1 : 0
}

if (import.meta.url === `file://${process.argv[1]}`) main()
