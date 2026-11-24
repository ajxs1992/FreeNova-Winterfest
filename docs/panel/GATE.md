# The gate, and where the suite stands

## Running it

```bash
cd web-panel && node test_harness.mjs        # the panel suite
bash tools/compile-plugins.sh                # every plugin (needs Docker, i386 image)
python3 tools/lint-plugins.py                # 156 files, 0 errors
```

## Result at this commit — the real numbers, not a claim

```
compile   155 compiled / 0 failed
lint      0 errors, 43 allowed findings
suite     344 passed / 26 failed
```

## The 26 failures, sorted by cause

### Environment — not code (4)
- **advent (~4)**: the tests run against the real clock, so today (before 1 December) the
  claims are refused by design. The suite needs a frozen clock; the product behaviour is
  correct.

### Real, and worth fixing (the rest)
| group | failures | what it is |
| --- | --- | --- |
| **battlepass** (5) | claim POST answers **405**, nothing lands in `winter_actions` | a route/logic bug: the claim form is posted to a method the router does not accept |
| **layout** (8) | dashboard fields off their chrome (3), battlepass strips (2), rankstats/top15/profile fail the JS-scaling check (3) | the pages render, but the fixed-stage scaling is not implemented in JS, and some field boxes sit outside their plate chrome |
| **shop** (2) | `applying the purchase pays it once`, `a second apply changes nothing` | the catalogue is now seeded (see below), but `applyAction` returns a different balance than the test expects — looks like a ledger/state mismatch on the buy path |
| **asset** (1) | `/i/logo_mark.png` → 404 | a hub link that points at an asset not in this repo |
| **pull/ack** (3) | the signed pull, the ack, and the advent seed they depend on | all three follow from the advent date window; they will pass inside December or with a frozen clock |

## What the export had wrong, and what that teaches

The first export **could not load the suite at all**: `test_harness.mjs:63` imports
`./test_plate_census.mjs`, which was git-untracked, so a stub had to be written to run it.
It was also missing `seed_shop_catalog.sql`, which `server_local.mjs` applies on boot — so a
fresh checkout had an empty shop shelf and every shop test failed for a reason that had
nothing to do with the shop.

Both are in this repo now. The lesson worth keeping: **the suite's inputs must be tracked**,
or a clone cannot reproduce a green run.
