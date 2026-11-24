import { normalizeTheme, DEFAULT_THEME } from "./theme.js"

const KEY = "top15_theme"

export async function loadTheme(env) {
  if (!env || !env.DB) return { ...DEFAULT_THEME }
  try {
    const row = await env.DB.prepare(`SELECT json FROM catalog WHERE key = ?1`).bind(KEY).first()
    if (row && row.json) return normalizeTheme(JSON.parse(row.json))
  } catch {}
  return { ...DEFAULT_THEME }
}

export async function saveTheme(env, theme) {
  const next = normalizeTheme(theme)
  const now = Math.floor(Date.now() / 1000)
  await env.DB.prepare(
    `INSERT INTO catalog (key, version, json, updated_at) VALUES (?1, 1, ?2, ?3)
     ON CONFLICT(key) DO UPDATE SET json = excluded.json, version = catalog.version + 1, updated_at = excluded.updated_at`
  ).bind(KEY, JSON.stringify(next), now).run()
  return next
}

export async function resetTheme(env) {
  return saveTheme(env, DEFAULT_THEME)
}
