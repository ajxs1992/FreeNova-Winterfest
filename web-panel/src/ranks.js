// Authoritative rank ladder — keep in lockstep with
// configs/rank_system_ultimate.ini [Ranks]. rank_id is 1-based
// (RSU RANK_ID / CalculateRank). HUD and AMXX read the same INI.

export const RANKS = [
  "Unranked",
  "Silver I",
  "Silver II",
  "Silver III",
  "Silver IV",
  "Silver Elite",
  "Silver Elite Master",
  "Gold Nova I",
  "Gold Nova II",
  "Gold Nova III",
  "Gold Nova Master",
  "Master Guardian",
  "Master Guardian II",
  "Master Guardian Elite",
  "Distinguished Master Guardian",
  "Legendary Eagle",
  "Legendary Eagle Master",
  "Supreme Master First Class",
  "Global Elite"
]

export const RANK_XP = [
  0, 2816, 3730, 4207, 4698, 4999, 5622, 6492, 7416, 8376, 9348,
  9999, 10894, 12013, 13088, 14187, 15495, 18006, 30000
]

export function rankName(id) {
  const n = Math.min(Math.max(parseInt(id, 10) || 1, 1), RANKS.length)
  return RANKS[n - 1]
}

export function rankProgress(curXp, rankId) {
  const xp = Number.isFinite(+curXp) ? +curXp : 0
  const curIdx = Math.min(Math.max(parseInt(rankId, 10) || 1, 1), RANKS.length) - 1
  const nextIdx = Math.min(curIdx + 1, RANKS.length - 1)
  const baseReq = RANK_XP[curIdx]
  const nextReq = RANK_XP[nextIdx]
  const isMax = curIdx >= RANKS.length - 1 || xp >= RANK_XP[RANK_XP.length - 1]
  const span = Math.max(1, nextReq - baseReq)
  const earned = Math.max(0, xp - baseReq)
  const remaining = Math.max(0, nextReq - xp)
  const progressPct = isMax ? 100 : Math.min(100, Math.max(0, Math.round((earned / span) * 100)))
  return {
    curName: RANKS[curIdx],
    nextName: RANKS[nextIdx],
    isMax,
    baseReq,
    nextReq,
    earned,
    remaining,
    progressPct
  }
}
