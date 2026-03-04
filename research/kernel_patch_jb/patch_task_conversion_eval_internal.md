# A3 `patch_task_conversion_eval_internal`

## 1) How the Patch Is Applied
- Source implementation: `scripts/patchers/kernel_jb_patch_task_conversion.py`
- Match strategy: pure instruction-semantic matching (no string anchor):
  - `ldr Xn, [Xn]`
  - `cmp Xn, x0`
  - `b.eq ...`
  - `cmp Xn, x1`
  - `b.eq ...`
- Rewrite: change `cmp Xn, x0` to `cmp xzr, xzr` (identity compare, effectively making the equal-path reachable unconditionally).
- Hardening status (2026-03-05):
  - Fast matcher is now fail-closed by default.
  - Slow capstone fallback is disabled unless explicitly enabled with:
    - `VPHONE_TASK_CONV_ALLOW_SLOW_FALLBACK=1`
  - Additional context fingerprint checks are required before accepting a candidate:
    - `ADRP Xn` + `LDR Xn, [Xn,#imm]` preamble
    - `CMP Xn,X0 ; B.EQ ; CMP Xn,X1 ; B.EQ`
    - post-sequence shape: `mov x19,x0 ; mov x0,x1 ; bl ... ; cbz/cbnz w0`
    - both `b.eq` targets must be forward and nearby (<= 0x200 bytes)

## 2) Expected Behavior
- Relax the internal guard in task conversion so later comparison branches are more likely to take the allow path.

## 3) Target
- Target logic: core identity/relationship check point inside `_task_conversion_eval_internal`.
- Security objective: reduce task-conversion denial rate to support task-related privilege escalation chains.

## 4) IDA MCP Binary Evidence
- Validation target:
  - runtime patch test input: `vm/iPhone17,3_26.1_23B85_Restore/kernelcache.research.vphone600`
  - IDA DB: `/Users/qaq/Desktop/kernelcache.research.vphone600.macho`
- Current method result (`patch_task_conversion_eval_internal`): **1 unique hit**
  - patch site: `0xfffffe0007b05194` (`cmp x9, x0` -> `cmp xzr, xzr`)
- Confirmed motif around the site:
  - `ldr x9, [off_FFFFFE0007785F48]`
  - `cmp x9, x0`
  - `b.eq loc_FFFFFE0007B051D0`
  - `cmp x9, x1`
  - `b.eq loc_FFFFFE0007B051CC`
- Effect on control flow:
  - after patch, first `b.eq` is always taken, forcing the function into the allow/zero-return path at `loc_FFFFFE0007B051D0`.
- Function-level context:
  - containing function: `sub_FFFFFE0007B050C8`
  - includes `ipc_tt.c` assert/panic strings (`"Just like pineapple on pizza, this task/thread port doesn't belong here..."`)
  - this context matches task/thread conversion policy checks.

## 5) Source-Code Trace (Current Matcher)
- Entry: `patch_task_conversion_eval_internal()`
  - calls `_collect_candidates_fast(kern_text_start, kern_text_end)`
  - requires exactly one candidate; otherwise fail (unless slow fallback env flag is set)
  - emits one patch: `cmp xzr,xzr`
- Fast matcher trace (`_collect_candidates_fast`):
  - candidate seed: `cmp Xn, x0`
  - verifies:
    - previous instruction is `ldr Xn, [Xn,#imm]`
    - next pattern is `b.eq ; cmp Xn,x1 ; b.eq`
    - `_is_candidate_context_safe(off, cmp_reg)` passes
- Context safety (`_is_candidate_context_safe`):
  - checks `off-8` is `ADRP Xn,...` with same `Xn`
  - checks `off+16/20` are `mov x19,x0 ; mov x0,x1`
  - checks `off+24` is `BL`
  - checks `off+28` is `CBZ/CBNZ W0,...`
  - decodes both `b.eq` targets and requires them to be forward short jumps

## 6) IDA Pseudocode / Control-Flow Trace
- Containing function: `sub_FFFFFE0007B050C8`
- Relevant pre-patch slice:
  - `LDR X9, [off_FFFFFE0007785F48]`
  - `CMP X9, X0`
  - `B.EQ loc_FFFFFE0007B051D0`
  - `CMP X9, X1`
  - `B.EQ loc_FFFFFE0007B051CC`
  - `MOV X19, X0 ; MOV X0, X1 ; BL sub_FFFFFE0007B3DFDC ; CBZ W0,...`
- Patch site:
  - `0xfffffe0007b05194`: `cmp x9, x0` -> `cmp xzr, xzr`
- Post-patch effect:
  - first `B.EQ` becomes unconditional in practice, taking `loc_FFFFFE0007B051D0` allow/zero-return path and skipping downstream denial checks.

## 7) Risks and Side Effects
- This kind of `cmp` short-circuit affects task security boundaries. If the hit point is wrong, it can cause permission-model corruption or panic.

## 8) Assessment
- On `kernelcache.research.vphone600`, A3 is now uniquely resolved and patchable.
- Confidence: **high** for site correctness on current build; operational risk remains high because this is a core task-conversion gate.
