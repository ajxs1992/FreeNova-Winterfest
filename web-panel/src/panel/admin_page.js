import { handleAdmin } from "../admin.js"

/**
 * The Admin Panel page (/panel/admin).
 *
 * It is NOT a second admin surface: it hands the request to the one handler that
 * already owns the admin auth - its session cookie, its CSRF token and its POST
 * routes. A visitor with no session gets that handler's login page / 403, never
 * a panel page, so this route cannot become a way around the existing gate.
 * `/admin?s=<section>` is the same handler, so both URLs always agree.
 */
export async function pageAdminPanel(request, env, url) {
  const path = (url && url.pathname) || "/panel/admin"
  if (path !== "/panel/admin") return handleAdmin(request, env)
  // Rewrite only the path: cookies, CSRF and POSTs are all the handler's own.
  const inner = new URL(request.url)
  inner.pathname = "/admin"
  return handleAdmin(new Request(inner, request), env)
}
