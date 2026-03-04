# B17 `patch_shared_region_map`

## How the patch works
- Source: `scripts/patchers/kernel_jb_patch_shared_region.py`.
- Locator strategy:
  1. Try symbol `_shared_region_map_and_slide_setup`.
  2. Fallback string anchor: `/private/preboot/Cryptexes`.
  3. Find `cbnz w0, <fail>` immediately following Cryptexes path call.
  4. Find `cmp <reg>, <reg>` + `b.ne <fail>` that branches to the same fail target.
- Patch action:
  - Rewrite compare to `cmp x0, x0`.

## Expected outcome
- Force compare result toward equality path, weakening rejection branch behavior.

## Target
- Shared region setup guard in `_shared_region_map_and_slide_setup` path.

## IDA MCP evidence
- Anchor string: `0xfffffe000708c481` (`/private/preboot/Cryptexes`)
- xref: `0xfffffe00080769dc`
- containing function start: `0xfffffe0008076260`
- selected patch site: `0xfffffe0008076a88` (`foff 0x1072A88`)
  - instruction pair: `cmp x8, x16` + `b.ne 0xfffffe0008076d84`
  - tied to Cryptexes fail target, not the function epilogue stack-canary compare.

## Risk
- Shared-region mapping checks influence process memory layout/security assumptions.
