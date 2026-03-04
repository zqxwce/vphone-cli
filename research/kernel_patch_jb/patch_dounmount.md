# B12 `patch_dounmount`

## How the patch works
- Source: `scripts/patchers/kernel_jb_patch_dounmount.py`.
- Locator strategy:
  1. Try symbol `_dounmount`.
  2. Fallback anchor string `"dounmount:"` and inspect call targets.
  3. Match sequence `mov w1,#0` + `mov x2,#0` + `bl ...` (MAC check pattern).
- Patch action:
  - NOP the matched `BL` MAC-check call.

## Expected outcome
- Suppress unmount MAC check path and continue unmount operation.

## Target
- MAC authorization call site in `_dounmount` path.

## IDA MCP evidence
- String: `0xfffffe000705661c` (`"dounmount: no coveredvp ..."`)
- xref: `0xfffffe0007cac34c`
- containing function start: `0xfffffe0007cabaec`

## 2026-03-05 re-validation (current kernel in IDA)
- `_dounmount` symbol is not present in this image.
- String-anchor path resolves to `sub_FFFFFE0007CABAEC` (`0xfffffe0007cabaec`), but:
  - scanning this function's BL callees does not find the expected
    `mov w1,#0; mov x2,#0; bl ...` pattern.
- Patcher therefore falls through to broad scan:
  - scans whole `kern_text` for short PAC functions with that mov/mov/bl shape.
  - first match appears at:
    - function `0xfffffe0007ad3b44`
    - patch site `0xfffffe0007ad3bac` (`BL sub_FFFFFE0007ADB154`)
- This first broad-scan hit is not tied to the `_dounmount` call path.

## Impact assessment
- Current B12 implementation is unreliable on this kernel build and can patch unrelated code.
- This is a high-risk false-positive patch pattern; even if not the direct APFS mount-phase-1 trigger,
  it can introduce unrelated kernel instability/regressions.

## Fix applied (2026-03-05)
- `scripts/patchers/kernel_jb_patch_dounmount.py` removed broad kern_text fallback scanning.
- Matching is now strict:
  1. `_dounmount` symbol path, or
  2. function containing `dounmount:` string anchor, with in-function pattern match only.
- If strict pattern is not found, patch method now fails closed (no patch emitted).

## Source Code Trace (Scanner)
- Entrypoint:
  - `KernelJBPatcher.find_all()` -> `patch_dounmount()`
- Method path (current implementation):
  1. `_resolve_symbol("_dounmount")` (if present, scan function body)
  2. fallback: `find_string("dounmount:")` -> `find_string_refs()` -> `find_function_start()`
  3. strict in-function matcher `_find_mac_check_bl(start,end)` for:
     - `mov w1,#0 ; mov x2,#0 ; bl ...` (or swapped `x2/w1`)
  4. patch emit:
     - `asm("nop")` + capstone decode assert
     - `emit(result, nop, "NOP [_dounmount MAC check]")`
- Safety behavior:
  - no broad kern_text sweep; unresolved case is fail-closed (`False`, no emit).
- Kernel pseudocode trace at patched check (`sub_FFFFFE0007CABAEC`):
  - `... unmount teardown path ...`
  - `sub_FFFFFE0007C81734(v7);`
  - `sub_FFFFFE0007C9FDBC(0, 16, 0);`  <- patched BL site
  - `... continue state/flag cleanup ...`

## Runtime Trace (IDA, research kernel)
- Scanner target:
  - `kernelcache.research.vphone600` (sha256 `b7fa45e93debe4d27cd3b59d74823223864fd15b1f7eb460eb0d9f709109edac`)
- Anchor/function:
  - string `0xFFFFFE000705661C` -> function `sub_FFFFFE0007CABAEC`
- Observed callers of `sub_FFFFFE0007CABAEC`:
  - `sub_FFFFFE0007C99124`
  - `sub_FFFFFE0007C9F968`
  - `sub_FFFFFE0007CAB938`
  - `sub_FFFFFE0007CAC358`
- no-emit scan hit:
  - `off=0x00CA81FC`, `va=0xFFFFFE0007CAC1FC`, `bytes=1f2003d5`
  - instruction at site before patch: `BL sub_FFFFFE0007C9FDBC`

## Trace Call Stack (IDA)
- Static caller set into `_dounmount` function body:
  - `sub_FFFFFE0007C99124` -> `sub_FFFFFE0007CABAEC`
  - `sub_FFFFFE0007C9F968` -> `sub_FFFFFE0007CABAEC`
  - `sub_FFFFFE0007CAB938` -> `sub_FFFFFE0007CABAEC`
  - `sub_FFFFFE0007CAC358` -> `sub_FFFFFE0007CABAEC`
- In-function local call path around patched site:
  - `sub_FFFFFE0007CABAEC` -> `sub_FFFFFE0007C81734` -> `BL sub_FFFFFE0007C9FDBC` [patched to NOP]

## Risk
- Can bypass policy enforcement around unmount operations.
