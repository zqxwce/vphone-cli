# B11 `patch_mac_mount`

## How the patch works
- Source: `scripts/patchers/kernel_jb_patch_mac_mount.py`.
- Locator strategy:
  1. Try symbols `___mac_mount` / `__mac_mount`.
  2. Fallback anchor string `"mount_common()"`, then inspect BL targets for MAC-check shape.
- Patch action:
  - NOP the deny branch (`CBNZ w0, ...`) at strict MAC-check site.
  - Optional companion write: `mov x8, xzr` when nearby policy-state setup is present.

## Expected outcome
- Bypass MAC mount decision path so mount flow keeps going.

## Target
- MAC policy check branch sequence in `___mac_mount`-related path.

## IDA MCP evidence
- String: `0xfffffe0007056a9d` (`"mount_common(): ..."`)
- xref: `0xfffffe0007ca8de0`
- containing function start: `0xfffffe0007ca7868`

## 2026-03-05 re-validation (current kernel in IDA)
- Symbol lookup for `___mac_mount` / `__mac_mount` fails on this image.
- Fallback resolver selects callee `0xfffffe0007ca8e08` from `mount_common` path
  (`0xfffffe0007ca79f4 -> BL 0xfffffe0007ca8e08`).
- Matched patch site:
  - `0xfffffe0007ca8ea8`: `BL sub_FFFFFE0007CCD1B4`
  - `0xfffffe0007ca8eac`: `CBNZ W0, ...`
  - branch target sets `W0 = 1` and returns error.
- Critical behavior:
  - Patch currently NOPs only the `BL` at `0xfffffe0007ca8ea8`.
  - `W0` is then taken from prior register state (`MOV X0, X19` at `0xfffffe0007ca8ea0`),
    so `CBNZ W0` is almost always true.
  - Net effect is forcing error path (`W0=1`) instead of bypassing it.
- `mov x8, xzr` companion patch is not found at this site on this kernel, so only the risky NOP is applied.

## Impact assessment
- High confidence this can directly create mount failures in normal mount flow
  (including early boot mount paths), because it deterministically pushes this check to an error return.

## Fix applied (2026-03-05)
- `scripts/patchers/kernel_jb_patch_mac_mount.py` now patches the deny branch
  (`CBNZ w0`) instead of NOP'ing the preceding `BL`.
- Fallback resolution remains mount_common-anchored, but branch selection is now
  gated by an error-return check (`branch target writes non-zero to w0/x0`) to reduce false hits.
- Legacy `mov x8,xzr` tweak remains optional and only applies when such state write exists nearby.

## Source Code Trace (Scanner)
- Entrypoint:
  - `KernelJBPatcher.find_all()` -> `patch_mac_mount()`
- Method path (current implementation):
  1. `_resolve_symbol("___mac_mount"/"__mac_mount")`
  2. fallback: `find_string("mount_common()")` -> `find_string_refs()` -> `find_function_start()`
  3. traverse mount_common BL targets, run `_find_mac_deny_site(..., require_error_return=True)`
  4. patch emit:
     - `asm("nop")` + capstone decode assert
     - `emit(cb_off, nop, "NOP [___mac_mount deny branch]")`
  5. optional:
     - `asm("mov x8, xzr")` + capstone decode assert
     - emit companion state write if present
- Kernel pseudocode trace at patched check (`sub_FFFFFE0007CA8E08`):
  - `if ((a5 & 1) == 0) {`
  - `  if (sub_FFFFFE0007CCD1B4(a1, &ctx, a2) || mismatch) return 1;`
  - `}`
  - `... continue mount flow ...`

## Runtime Trace (IDA, research kernel)
- Scanner target:
  - `kernelcache.research.vphone600` (sha256 `b7fa45e93debe4d27cd3b59d74823223864fd15b1f7eb460eb0d9f709109edac`)
- no-emit scan hit:
  - `off=0x00CA4EAC`, `va=0xFFFFFE0007CA8EAC`, `bytes=1f2003d5`

## Trace Call Stack (IDA)
- Static caller chain into patched function:
  - `sub_FFFFFE0007CA9B38` -> `sub_FFFFFE0007CA7868` -> `sub_FFFFFE0007CA8E08`
- In-function branch path:
  - `0xFFFFFE0007CA8EA8` (`BL sub_FFFFFE0007CCD1B4`)
  - `0xFFFFFE0007CA8EAC` (`CBNZ W0, loc_FFFFFE0007CA8EC8`) [patched]
  - `0xFFFFFE0007CA8EC8` (`MOV W0, #1`) [deny/error return]

## Risk
- Mount authorization bypass can weaken filesystem integrity assumptions.
