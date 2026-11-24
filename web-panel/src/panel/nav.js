// The Winterfest panel's and every page's left rail and top bar DATA
// (docs/design/refs/winterfest/02-profile.png and every other plate draw the same
// chrome). This module is DATA, not layout: each page decides where the rail sits
// and how big it is. The rail is the plate's own list, in the plate's own order
// and with the plate's own one-line descriptions.
//
//   href      the route the plate's entry opens. The panel route table
//             (src/index.js, the /panel alias block) maps /panel/<key>.
//   label     the plate's title, verbatim.
//   sub       the plate's subtitle, verbatim.
//   badge     what the entry shows at its right in the plate (#, number).
//
// A group header (PLAYER, PROGRESSION, …) is a row with no href: the page draws
// it as the plate does, a rule and a title, and never as a link.
export const NAV_GROUPS = Object.freeze([
  { title: "Player", items: [
    { key: "dashboard", label: "Dashboard", sub: "Winterfest overview & countdown", icon: "house" },
    { key: "profile",   label: "Profile",   sub: "Christmas frames, badges & tree", icon: "id" },
    { key: "rankstats", label: "Rankstats", sub: "Festive statistics", icon: "chart" },
    { key: "top15",     label: "Top 15",    sub: "Christmas leaderboard", icon: "trophy" }
  ] },
  { title: "Progression", items: [
    { key: "battlepass", label: "Battle Pass", sub: "Christmas reward tracks", icon: "pass" },
    { key: "missions",   label: "Missions",    sub: "Christmas quests", icon: "clip" },
    { key: "achievements", label: "Achievements", sub: "Seasonal medals", icon: "medal" },
    { key: "levels",     label: "Levels",      sub: "Progress & rewards", icon: "up" }
  ] },
  { title: "Events & Activities", items: [
    { key: "events",    label: "Events",       sub: "Christmas event calendar", icon: "cal" },
    { key: "advent",    label: "Advent Calendar", sub: "Advent calendar (24 days)", icon: "gift" },
    { key: "spin",      label: "Spin Wheel",   sub: "Win coins, gingerbread & rewards", icon: "spin" }
  ] },
  { title: "Rewards & Management", items: [
    { key: "vip",   label: "VIP",   sub: "Christmas VIP cosmetics", icon: "crown" },
    { key: "shop",  label: "Shop",  sub: "Christmas-themed shop", icon: "key" },
    { key: "admin", label: "Admin Panel", sub: "Event management & settings", icon: "cog" }
  ] }
])

/** Flat list of the entries that are real links (the group headers are not). */
export const NAV_ROUTES = Object.freeze(NAV_GROUPS.flatMap(g => g.items.map(i => ({ ...i, group: g.title }))))

/** The route of one nav key, or "" when the plate has no such entry. */
export function navHref(key) {
  const e = NAV_ROUTES.find(r => r.key === key)
  return e ? "/panel/" + e.key : ""
}
