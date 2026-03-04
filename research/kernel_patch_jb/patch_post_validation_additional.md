# B5 `patch_post_validation_additional`

## 1) How the Patch Is Applied
- Source implementation: `scripts/patchers/kernel_jb_patch_post_validation.py`
- Match strategy:
  - Anchor string: `AMFI: code signature validation failed`
  - Find callers that reference this string, then walk their `BL` callees.
  - In the callee, locate `cmp w0, #imm` + `b.ne` patterns with a nearby preceding `bl`.
- Rewrite: change `cmp w0, #imm` to `cmp w0, w0`.

## 2) Expected Behavior
- Convert a postValidation failure comparison into an identity comparison, so `b.ne` loses its original reject semantics.

## 3) Target
- Target logic: additional reject path in AMFI code-sign post validation.
- Security objective: reduce forced rejection after signature-validation failure.

## 4) IDA MCP Binary Evidence
- String: `0xfffffe00071f80bf` `"AMFI: code signature validation failed.\n"`
- Xrefs (same function):
  - `0xfffffe0008642290`
  - `0xfffffe0008642bf0`
  - `0xfffffe0008642e98`
- Corresponding function start: `0xfffffe0008641924`

## 5) 2026-03-05 Re-Validation (Research Kernel + IDA)
- Validation target:
  - runtime patch test input: `vm/iPhone17,3_26.1_23B85_Restore/kernelcache.research.vphone600`
  - IDA DB: `/Users/qaq/Desktop/kernelcache.research.vphone600.macho`
- Current method result (`patch_post_validation_additional`): **1 unique hit**
  - patch site: `0xfffffe00086445ac`
  - rewrite: `cmp w0, #2` -> `cmp w0, w0`
- Call-site and branch context in callee `sub_FFFFFE0008644564`:
  - `0xfffffe00086445a8`: `bl sub_FFFFFE0007F828F4`
  - `0xfffffe00086445ac`: `cmp w0, #2` (target compare)
  - `0xfffffe00086445b0`: `b.ne loc_FFFFFE000864466C`
  - branch target logs `"Hash type is not SHA256 (%u) but %u"` and converges into reject/log path.
- Practical effect:
  - patched compare makes `b.ne` unreachable, so this hash-type reject branch is neutralized.
- IDA alignment note:
  - current IDA DB already shows patched bytes at this site (`cmp w0,w0`), but raw research kernel bytes are `cmp w0,#2`.
  - patch correctness was validated against raw `kernelcache.research.vphone600` bytes, then control flow was checked in IDA.

## 6) Risks and Side Effects
- Turns a post-validation error-convergence condition into one that effectively never triggers rejection.

## 7) Assessment
- On `kernelcache.research.vphone600`, B5 is uniquely located and semantically aligned with the intended post-validation bypass.
- Confidence: **high** for current build.
