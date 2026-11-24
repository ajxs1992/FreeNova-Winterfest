# Art rule — the references are the layout; generated art is allowed for NEW pieces

> **2026-11-23, owner, superseding the earlier absolute ban:** *"You can use /imagine
> to make icons or whatever you want."*
>
> What still holds: **the mockups are the layout, and anything the mockup already
> shows must be reproduced from the mockup** — never a redrawn or "improved" version
> of something the owner already gave us. What is now allowed: **anything the mockups
> do not contain** — a badge, a medal, a title, a rarity flourish, a new ornament, an
> achievement icon — may be generated with `/imagine`.

## The rule
1. **Anything the reference contains is cut from the reference** (`docs/design/refs/winterfest/`),
   at native pixel size. Never upscale, never recolour, never "improve", never redraw
   what the owner already drew.
2. **Anything the reference does NOT contain may be generated** with
   `~/.local/bin/ckffai-image` (`/imagine`) — icons, badges, medals, ornaments, titles,
   frames. Generated art is only for **new** pieces, never a replacement for a plate
   region, and it must be listed in `web-panel/assets/generated/MANIFEST.json` with its
   prompt and purpose so provenance is never lost.
3. **Consistency gate for generated pieces**: same palette as the plates (base `#0b1030`,
   card `#0d1430`, border `#2a3d6e`, gold `#f5c451`, red `#c00000`, green `#3fbf6f`, ice
   `#4070c0`), thick soft outline, optical fill 0.70 ± 0.02 on a 256×256 transparent
   canvas, and a contact sheet reviewed at 24/32/64 px before anything ships.
3. **The layout follows the reference**, because the art now literally *is* the
   reference: an element gets the same box the mockup gives it.
4. Code-drawn things stay code: borders, shadows, gradients, progress bars, tab
   underlines, the wheel's sectors, check marks. The rule is about *pictures*.
5. Every cut is recorded in `web-panel/assets/winter/ref/MANIFEST.json` with its
   source file and x/y/w/h, so any piece can be traced back to the plate it came
   from.

## Generated assets: the earlier set stays retired
`wf-hero.png`, `wf-santa.png`, `wf-tree.png`, `advent-house-a/b.png`,
`advent-gift.png`, `advent-pass.png` and `icons/*.png` were generated **as replacements
for things the plates already contain**, which is still forbidden. They stay unused.
New generated pieces live under `web-panel/assets/generated/` with a manifest, and are
never named like a plate region.

## Tooling
`tools/art/slice_refs.py` — the only art tool. `--list` prints the region table,
`--check` verifies every region fits inside its source image.
