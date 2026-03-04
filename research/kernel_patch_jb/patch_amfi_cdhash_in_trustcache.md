# A1 `patch_amfi_cdhash_in_trustcache`

## 1) How the Patch Is Applied
- Source implementation: `scripts/patchers/kernel_jb_patch_amfi_trustcache.py`
- Match strategy: no string anchor; uses an AMFI function semantic sequence match (`mov x19, x2` -> `stp xzr,xzr,[sp,...]` -> `mov x2, sp` -> `bl` -> `mov x20, x0` -> `cbnz w0` -> `cbz x19`).
- Rewrite: replace the first 4 instructions at function entry with a stub:
  1. `mov x0, #1`
  2. `cbz x2, +8`
  3. `str x0, [x2]`
  4. `ret`

## 2) Expected Behavior
- Always report "CDHash is in trustcache" as true (return `1`).
- If the caller passes an out parameter (`x2` is non-null), write the same result back to the out pointer.

## 3) Target
- Target function logic: AMFI trustcache membership check (script label: `AMFIIsCDHashInTrustCache`).
- Security objective: bypass AMFI's key gate that verifies whether a signing hash is trusted.

## 4) IDA MCP Binary Evidence
- IDB: `/Users/qaq/Desktop/kernelcache.research.vphone600.macho`
- imagebase: `0xfffffe0007004000`
- An IDA semantic-sequence scan (same signature as the script) found 1 hit in the AMFI area:
  - Function entry: `0xfffffe0008637880`
- This function is called by multiple AMFI paths (sample xrefs):
  - `0xfffffe0008635de4`
  - `0xfffffe000863e554`
  - `0xfffffe0008641e0c`
  - `0xfffffe00086432dc`

## 5) Risks and Side Effects
- Forces all CDHash trust decisions to allow, which is highly intrusive.
- If callers rely on the failure path for cleanup or auditing, this patch short-circuits that behavior.

## 6) 2026-03-05 Re-Validation (Research Kernel + IDA)
- Validation target:
  - runtime patch test input: `vm/iPhone17,3_26.1_23B85_Restore/kernelcache.research.vphone600`
  - IDA DB: `/Users/qaq/Desktop/kernelcache.research.vphone600.macho`
- Current method result (`patch_amfi_cdhash_in_trustcache`): **1 unique hit**, 4 writes:
  - `0xfffffe0008637880` `mov x0, #1`
  - `0xfffffe0008637884` `cbz x2, +8`
  - `0xfffffe0008637888` `str x0, [x2]`
  - `0xfffffe000863788c` `ret`
- IDA confirms this is the AMFI trustcache check body (the short function at `0xfffffe0008637880`):
  - prologue stores `x19 = x2` (out param)
  - calls helper (`bl sub_FFFFFE0007FFCA08`)
  - on success, updates out param and returns `v4 == 0`
- Call-site evidence:
  - xrefs to `0xfffffe0008637880`: 12 sites in AMFI paths
  - common call shape is `mov w0,#(1|2|3)` + `mov x1,...` + `mov x2,...` + `bl 0x8637880` then branch on `w0`
- Accuracy note:
  - nearby wrapper `sub_FFFFFE00086377A8` ends with a tail path into this function, but patch target is the real callee entry at `0xfffffe0008637880` (not the wrapper).

## 7) Assessment
- On `kernelcache.research.vphone600`, A1 locator and patch site are consistent and executable.
- Confidence: **high** (single unique body match + multi-site AMFI caller confirmation).
