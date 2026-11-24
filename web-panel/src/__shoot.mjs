// Drive a page in headless Chrome over CDP at each MOTD size and report the fit:
// the scale the page used, the letterbox on each side, and whether anything
// scrolls. Saves one screenshot per size.
//
//   node __shoot.mjs <url> <outdir> <prefix> [WxH ...]
//
// This is a developer tool, not part of the Worker: no dependency is added
// (Node's own WebSocket is enough), and nothing imports it.
import { spawn } from "node:child_process"
import { writeFileSync, mkdirSync } from "node:fs"

const [src, outdir, prefix = "shot", ...sizesArg] = process.argv.slice(2)
const SIZES = sizesArg.length
  ? sizesArg.map(s => s.split("x").map(Number))
  : [[640, 480], [800, 600], [1024, 768], [1152, 864], [1280, 1024], [1366, 768], [1920, 1080]]
const W = 1672, H = 941
if (outdir) mkdirSync(outdir, { recursive: true })

const PROBE = `(() => {
  const d = document.documentElement, b = document.body
  const st = document.getElementById('stage')
  const r = st ? st.getBoundingClientRect() : null
  return {
    iw: innerWidth, ih: innerHeight,
    scrollW: d.scrollWidth, scrollH: d.scrollHeight,
    bodyScrollW: b.scrollWidth, bodyScrollH: b.scrollHeight,
    rect: r ? { x: r.x, y: r.y, w: r.width, h: r.height } : null,
    dataScale: st ? st.getAttribute('data-scale') : null
  }
})()`

const port = 9331 + Math.floor(Math.random() * 400)
const chrome = spawn("brave", [
  "--headless=new", "--no-sandbox", "--disable-gpu", "--hide-scrollbars",
  `--remote-debugging-port=${port}`, `--user-data-dir=/tmp/cdp-${port}-${Date.now()}`, "about:blank"
], { stdio: "ignore" })

const sleep = ms => new Promise(r => setTimeout(r, ms))

async function target() {
  for (let i = 0; i < 120; i++) {
    try {
      const tabs = await (await fetch(`http://127.0.0.1:${port}/json`)).json()
      const page = tabs.find(t => t.type === "page")
      if (page) return page
    } catch {}
    await sleep(100)
  }
  throw new Error("no CDP target")
}

const ws = new WebSocket((await target()).webSocketDebuggerUrl)
await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej })
let id = 0
const pending = new Map()
ws.onmessage = ev => {
  const msg = JSON.parse(ev.data)
  if (msg.id && pending.has(msg.id)) {
    pending.get(msg.id)(msg.result || {})
    pending.delete(msg.id)
  }
}
const call = (method, params = {}) => new Promise(res => {
  id++
  pending.set(id, res)
  ws.send(JSON.stringify({ id, method, params }))
})

await call("Page.enable")
const rows = []
for (const [w, h] of SIZES) {
  await call("Emulation.setDeviceMetricsOverride", { width: w, height: h, deviceScaleFactor: 1, mobile: false })
  await call("Page.navigate", { url: src })
  await sleep(900)
  // web fonts and the plate: give the page its two animation frames
  await call("Runtime.evaluate", { expression: "new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)))", awaitPromise: true })
  const { result } = await call("Runtime.evaluate", { expression: PROBE, returnByValue: true })
  const v = result.value, rect = v.rect || {}
  const scale = rect.w / W
  const scrollbar = v.scrollW > v.iw || v.scrollH > v.ih
  rows.push({
    size: `${w}x${h}`, scale: +scale.toFixed(4), dataScale: v.dataScale,
    plate: `${rect.w.toFixed(1)}x${rect.h.toFixed(1)}`,
    letterbox: `x=${rect.x.toFixed(1)}/${(v.iw - rect.x - rect.w).toFixed(1)} y=${rect.y.toFixed(1)}/${(v.ih - rect.y - rect.h).toFixed(1)}`,
    scroll: `scroll ${v.scrollW}x${v.scrollH} vs viewport ${v.iw}x${v.ih}`,
    scrollbar
  })
  if (outdir) {
    const shot = await call("Page.captureScreenshot", { format: "png" })
    writeFileSync(`${outdir}/${prefix}-${w}x${h}.png`, Buffer.from(shot.data, "base64"))
  }
}
ws.close()
chrome.kill("SIGKILL")
console.log(JSON.stringify(rows, null, 1))
const bad = rows.filter(r => r.scrollbar)
console.log(bad.length ? `SCROLLBARS ON: ${bad.map(b => b.size).join(", ")}` : "NO SCROLLBARS AT ANY SIZE")
