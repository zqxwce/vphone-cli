# B19 `patch_io_secure_bsd_root`

## How the patch works
- Source: `scripts/patchers/kernel_jb_patch_secure_root.py`.
- Locator strategy:
  1. Try symbol `_IOSecureBSDRoot`.
  2. Fallback requires function candidates that reference both `SecureRootName` and `SecureRoot`.
  3. In target function, locate strict policy branch shape:
     `BL*` + `CBZ/CBNZ W0` with forward in-function target (exclude epilogue guards).
- Patch action:
  - Compile unconditional branch via keystone (`asm("b #delta")`) and capstone-assert decode.

## Expected outcome
- Always take the forward branch and skip selected secure-root check path.

## Target
- Security decision branch inside `_IOSecureBSDRoot` flow.

## IDA MCP evidence
- `SecureRootName` occurrences:
  - `0xfffffe00070a66a5` -> xref `0xfffffe000828f444` -> function start `0xfffffe000828f42c`
  - `0xfffffe0007108f2d` -> xref `0xfffffe000836624c` -> function start `0xfffffe0008366008`
- Patch script uses first successful function resolution in scan order.

## 2026-03-05 re-validation (current kernel in IDA)
- `_IOSecureBSDRoot` symbol is not present in this image.
- Fallback picks first `SecureRootName` reference function:
  - selected function: `0xfffffe000828f42c`.
- In this selected function, first forward conditional is:
  - `0xfffffe000828f5b0`: `TBZ X16, #0x3E, 0xfffffe000828f5b8`.
- This branch is in the epilogue integrity check sequence (`AUTIBSP` + break guard),
  not the SecureRoot authorization decision logic.
- Current patch rule (`first forward cbz/cbnz/tbz/tbnz`) rewrites this site to unconditional `B`,
  which effectively disables that guard path instead of changing SecureRoot policy behavior.
- The other `SecureRootName` function (`0xfffffe0008366008`) contains the actual
  `"SecureRoot"` / `"SecureRootName"` property handling logic, but current resolver never reaches it.

## Impact assessment
- B19 is currently ineffective for intended SecureRoot bypass purpose on this kernel build.
- It weakens hardening checks while leaving core SecureRoot decision flow largely untouched.

## Fix applied (2026-03-05)
- `scripts/patchers/kernel_jb_patch_secure_root.py` now requires stripped-kernel fallback
  function candidates to reference both `SecureRoot` and `SecureRootName`.
- Branch selection changed from “first forward conditional” to strict policy-shape match:
  - `BL*` followed by `CBZ/CBNZ W0`,
  - forward in-function target,
  - excludes epilogue guard regions (`AUTIBSP`/`BRK` vicinity).
- On current IDA image this resolves to function `0xfffffe0008366008` and first strict
  site `0xfffffe0008366090` (`CBZ W0, ...`), avoiding the previous `0xfffffe000828f5b0` guard patch.

## Source Code Trace (Scanner)
- Entrypoint:
  - `KernelJBPatcher.find_all()` -> `patch_io_secure_bsd_root()`
- Method path (current implementation):
  1. `_resolve_symbol("_IOSecureBSDRoot")`
  2. fallback resolver:
     - `_functions_referencing_string("SecureRootName")`
     - `_functions_referencing_string("SecureRoot")`
     - intersection -> deterministic `min(common)`
  3. `_find_secure_root_branch_site(func_start, func_end)`:
     - require `BL*` immediately before `CBZ/CBNZ W0`
     - require forward in-function target
     - reject epilogue guard regions (`AUTIBSP`/`BRK` vicinity)
  4. `_compile_branch_checked(off,target)`:
     - `asm("b #delta")`
     - capstone decode assert (`mnemonic == b`, immediate == delta)
     - `emit(...)`
- Kernel pseudocode trace (`sub_FFFFFE0008366008`):
  - `if (a2->matches("SecureRoot")) {`
  - `  if (callback(a2, "SecureRoot") == 0) goto loc_...6234;`  <- `CBZ W0` patched to unconditional `B`
  - `  ... SecureRoot callback / result path ...`
  - `}`
  - `if (a2->matches("SecureRootName")) { ... name-based verification path ... }`

## Runtime Trace (IDA, research kernel)
- Scanner target:
  - `kernelcache.research.vphone600` (sha256 `b7fa45e93debe4d27cd3b59d74823223864fd15b1f7eb460eb0d9f709109edac`)
- Runtime dispatch context:
  - selected function `sub_FFFFFE0008366008` (AppleARMPlatform `__text`)
  - function has data xrefs at `0xFFFFFE00077C25C0`, `0xFFFFFE00078DF0B8` (vtable/dispatch context)
- Strict branch site:
  - `0xFFFFFE000836608C`: `BLRAA ...`
  - `0xFFFFFE0008366090`: `CBZ W0, loc_FFFFFE0008366234` (patched)
- no-emit scan hit:
  - `off=0x01362090`, `va=0xFFFFFE0008366090`, `bytes=69000014` (`b #0x1A4`)

## Trace Call Stack (IDA)
- This site is reached via virtual dispatch (no direct static `BL` xref).
- Dispatch evidence:
  - function `sub_FFFFFE0008366008` is referenced as data (vtable/dispatch slots):
    - `0xFFFFFE00077C25C0`
    - `0xFFFFFE00078DF0B8`
- In-function local branch path:
  - `0xFFFFFE000836608C`: `BLRAA ...` (callback / policy probe)
  - `0xFFFFFE0008366090`: `CBZ W0, loc_FFFFFE0008366234` [patched to `B #0x1A4`]
  - target block starts at `0xFFFFFE0008366234` and continues into SecureRootName handling path

## Risk
- Secure-root checks are trust anchors; forcing the branch can weaken platform integrity assumptions.
