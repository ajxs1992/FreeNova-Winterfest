// FreeNova panel — the road of the advent calendar: the winding path the plate
// draws, turned into a list of house positions the page can build from ONE tile.
//
// The plate (assets/plates/11-advent.png) paints its own road with "Nov 18"..
// "Nov 24" on it, one house per stop, and the stops alternate along a path that
// bends back on itself. Redrawing that road by hand would mean repainting sky,
// ground and snow; instead the page paints the plate WITHOUT that band (the
// band's sky is cut from a clean part of the same plate) and lays the plate's
// OWN house art, scaled down, along the same kind of path:
//
//   house_house   the front-facing cottage (plate 470,455 190x150)
//   house_chalet  the gabled chalet       (plate 950,215 205x160)
//
// Every stop is a day: 24 of them, in reading order (the plate's path runs
// right-to-left on its top leg and left-to-right below it, so the page walks
// top-left -> top-right -> down -> bottom-right -> bottom-left, which is how a
// calendar is read).
export const ROAD = {
  // The band the plate paints its own road in, and the clean sky that replaces
  // it: a slice of the hero's empty upper-left sky, stretched.
  x0: 296, y0: 208, x1: 1230, y1: 780,
  sky: { x: 330, y: 250, w: 120, h: 40 }
}

// The house tiles, in plate coordinates: [key, srcX, srcY, srcW, srcH, drawW,
// drawH]. The draw size is the plate's own art, scaled down so two straddle the
// road without overlapping each other.
export const HOUSES = [
  ["chalet", 947, 212, 210, 168, 96, 78],
  ["cottage", 466, 452, 196, 150, 88, 68],
  ["lodge", 300, 300, 150, 150, 96, 70],
  ["cabin", 640, 390, 160, 140, 80, 60]
]

// One stop per day. x/y are the CENTRE of the house on the stage; `w` is the
// drawn width (the plate's own, scaled). The first leg climbs to the right, the
// second comes back to the left, which is what makes the walk read as a road.
const LEGS = [
  // leg 1: bottom-left up to the right (days 1..8)
  [344, 700, 0.86], [420, 676, 0.86], [496, 650, 0.86], [572, 626, 0.86],
  [652, 604, 0.86], [736, 586, 0.86], [824, 572, 0.86], [914, 560, 0.90],
  // leg 2: crest, then down the right (days 9..14)
  [1004, 520, 0.90], [1076, 470, 0.90], [1130, 418, 0.90], [1160, 362, 0.86],
  [1150, 308, 0.86], [1104, 270, 0.86],
  // leg 3: the top row, right to left (days 15..20)
  [1016, 250, 0.86], [920, 250, 0.86], [824, 250, 0.86], [728, 250, 0.86],
  [632, 250, 0.86], [536, 250, 0.86],
  // leg 4: down the left side and along the bottom (days 21..24)
  [452, 300, 0.86], [392, 366, 0.86], [366, 440, 0.86], [400, 512, 0.86]
]

export const STOPS = LEGS.map(([x, y, s], i) => ({
  day: i + 1,
  x, y, s,
  // alternate the two fronts so the road does not look like a factory
  house: i % 3 === 0 ? "chalet" : (i % 3 === 1 ? "cottage" : "lodge")
}))

/** The house a stop draws with, as [key, x, y, w, h] from HOUSES. */
export function houseFor(key) {
  return HOUSES.find(h => h[0] === key) || HOUSES[1]
}

/** CSS for the road's sky cover and the four house tiles (background slices). */
export function roadCss(plate) {
  const { sky } = ROAD
  const css = [`#road_sky{position:absolute;left:${ROAD.x0}px;top:${ROAD.y0}px;` +
    `width:${ROAD.x1 - ROAD.x0}px;height:${ROAD.y1 - ROAD.y0}px;background-image:url(${plate});` +
    `background-repeat:no-repeat;background-position:-${sky.x}px -${sky.y}px;` +
    `background-size:${sky.w}px ${sky.h}px}`]
  for (const [k, x, y, w, h] of HOUSES)
    css.push(`.house-${k}{background-image:url(${plate});background-repeat:no-repeat;` +
      `background-position:-${x}px -${y}px;background-size:${w}px ${h}px}`)
  return css.join("\n")
}

/**
 * The road under the stops: one soft band down each leg, drawn from the plate's
 * own snow colour so it never looks like a line somebody typed. It is a shadow
 * under the houses, not a second road.
 */
export function roadPathCss() {
  return `#road_path{position:absolute;left:300px;top:214px;width:930px;height:566px;
  background:
    radial-gradient(220px 90px at 12% 86%, rgba(206,226,255,.30), transparent 70%),
    radial-gradient(300px 110px at 45% 72%, rgba(206,226,255,.26), transparent 70%),
    radial-gradient(260px 110px at 80% 55%, rgba(206,226,255,.24), transparent 70%),
    radial-gradient(240px 90px at 96% 22%, rgba(206,226,255,.20), transparent 70%),
    radial-gradient(420px 80px at 62% 8%, rgba(206,226,255,.18), transparent 70%),
    radial-gradient(300px 120px at 12% 34%, rgba(206,226,255,.14), transparent 70%);
  filter:blur(1px);pointer-events:none}`
}
