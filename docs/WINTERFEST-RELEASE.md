# Winterfest release discipline (owner instruction, 2026-11-22)

> "We add all the Christmas stuff to a backup and to a local server, we run
> everything locally. We don't change anything in the Classic servers' source
> codes yet. We hold everything in a secure backup until we get to a stable
> version with everything tested."

## The rule
**Nothing Winterfest goes to a live host until it has passed the full gate and the
owner says go.** The Classic servers keep running the build documented in
`docs/DEPLOY-plugins.md` §9 (70 plugins, verified 137/0 tree, no Winterfest
plugins loaded). No mapcycle, config, plugin or panel change from this work lands
there by accident.

## Where the work lives
| thing | where |
| --- | --- |
| working branch | `winterfest` (pushed; `main` is the production line) |
| draft tag | `wf-2026-draft-1` (annotated, pushed) |
| full-history bundle | `~/.local/share/freenova-backups/winterfest-<stamp>.bundle` + `SHA256SUMS.txt` |
| references + assets | committed (`docs/design/refs/**`, `thirdparty/winterfest-assets/**`) so the bundle carries them |
| local environment | `scripts/wf-local.sh` (built by the local-server workstream) |

## The gate before any deploy
1. `tools/compile-plugins.sh` → 0 failed; `tools/lint-plugins.py` → 0 errors.
2. Local full-stack boot green (`RESULT ok`, no runtime errors) with the Winterfest
   plugins loaded.
3. The Winterfest harness scenario green (idempotency, advent windows, premium
   gate, presents per map, standalone-safe).
4. Panel suite green (367 baseline + Winterfest checks) and every `/v2` page
   screenshotted against its reference.
5. Live-parity check: the deploy tool reports only the intended files differ.
6. Owner sign-off, then deploy with `season.enabled 0` first, verify, then open
   the season.

## Making a new secure backup
```sh
git bundle create ~/.local/share/freenova-backups/winterfest-$(date +%Y%m%d-%H%M).bundle --all
sha256sum ~/.local/share/freenova-backups/winterfest-*.bundle
```
The bundle plus its checksum is the offline copy; the branch and tag on the
private GitHub repo are the online copy. Both, or it is not "secure".
