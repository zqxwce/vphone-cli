# B18 `patch_nvram_verify_permission`

## How the patch works
- Source: `scripts/patchers/kernel_jb_patch_nvram.py`.
- Locator strategy:
  1. Try NVRAM verifyPermission symbol.
  2. Fallback string anchor `krn.` and scan backward from its load site for nearby `tbz/tbnz` guard.
  3. Secondary fallback: entitlement string `com.apple.private.iokit.nvram-write-access`.
- Patch action:
  - NOP selected `tbz/tbnz` permission guard.

## Expected outcome
- Bypass NVRAM permission gating in verifyPermission path.

## Target
- Bit-test branch enforcing write permission policy in IONVRAM permission checks.

## IDA MCP evidence
- `krn.` anchor string (exact C-string used by patch path): `0xfffffe00070a2770`
  - xref: `0xfffffe000823803c`
- entitlement anchor string: `0xfffffe00070a238f`
  - xref: `0xfffffe000823810c` (function start `0xfffffe0008237ee8`)

## 2026-03-05 re-validation (research kernel, no-emit + IDA)
- scanner target:
  - `kernelcache.research.vphone600` payload sha256:
    `b6846048f3a60eab5f360fcc0f3dcb5198aa0476c86fb06eb42f6267cdbfcae0`
- no-emit scan hit:
  - `off=0x01234034`, `va=0xFFFFFE0008238034`, `bytes=1f2003d5`
  - pre-patch instruction: `TBNZ W24, #2, loc_FFFFFE00082382E0`
- semantic check:
  - patched function `sub_FFFFFE0008237EE8` contains direct checks for:
    - `"krn."` prefix
    - `"com.apple.private.iokit.nvram-write-access"`
    - `"com.apple.private.iokit.nvram-read-access"`
  - this confirms the hit is inside NVRAM permission verification flow (not unrelated helper).

## Source Code Trace (Scanner)
- Entrypoint:
  - `KernelJBPatcher.find_all()` -> `patch_nvram_verify_permission()`
- Method path (current implementation):
  1. `_resolve_symbol("__ZL16verifyPermission16IONVRAMOperationPKhPKcb")`
  2. fallback anchor: `find_string("krn.")` -> `find_string_refs()` -> `find_function_start()`
  3. secondary fallback anchor:
     `find_string("com.apple.private.iokit.nvram-write-access")`
  4. branch selection:
     - preferred: backward search from `krn.` xref for nearby `tbz/tbnz`
     - fallback: first `tbz/tbnz` in selected function
  5. patch emit:
     - `emit(off, NOP, "NOP [verifyPermission NVRAM]")`

## Runtime Trace (IDA, research kernel)
- function: `sub_FFFFFE0008237EE8`
- local branch path around patched site:
  - `0xFFFFFE000823802C`: `CMP X0, X25`
  - `0xFFFFFE0008238030`: `CSET W28, EQ`
  - `0xFFFFFE0008238034`: `TBNZ W24, #2, loc_FFFFFE00082382E0` [patched]
  - `0xFFFFFE000823803C`: `ADRL X1, "krn."`
  - `0xFFFFFE000823810C`: entitlement string load for NVRAM write access

## Trace Call Stack (IDA)
- direct callers of `sub_FFFFFE0008237EE8` include:
  - `sub_FFFFFE0008237514`
  - `sub_FFFFFE0008237D80`
  - `sub_FFFFFE0008238A24`
  - `sub_FFFFFE00082392EC`
  - `sub_FFFFFE000823AC60`
  - `sub_FFFFFE000823E97C`
  - `sub_FFFFFE0008244278`

## Status
- **Working for now** on current research kernel.

## Risk
- NVRAM permission bypass can enable persistent config tampering.
