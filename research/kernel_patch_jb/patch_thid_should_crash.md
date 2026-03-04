# B20 `patch_thid_should_crash`

## Source code
- File: `scripts/patchers/kernel_jb_patch_thid_crash.py`
- Method: `KernelJBPatchThidCrashMixin.patch_thid_should_crash`
- Code path:
  1. `_resolve_symbol("_thid_should_crash")`
  2. fallback: `find_string("thid_should_crash")` + scan nearby `sysctl_oid`-like data entries
  3. validate candidate pointer is in DATA/DATA_CONST and current value is small non-zero int
  4. `emit(target, 0x00000000)` zero out flag

## Expected outcome
- Disable crash behavior controlled by `_thid_should_crash` flag.

## Target
- Global data variable (not code) backing the `thid_should_crash` sysctl path.

## Trace call stack (IDA)
- data/control path:
  - `sub_FFFFFE0007B07B08`
  - `sub_FFFFFE0007B07ED4`
  - `sub_FFFFFE0007B08178`
  - global `0xFFFFFE0007682B50` (`_thid_should_crash` backing int)
- sysctl metadata path:
  - string `0xFFFFFE0009790BC0` (`"thid_should_crash"`)
  - nearby sysctl data xref `0xFFFFFE0009790BD8`
  - low32 pointer resolves to file offset `0x67EB50`

## IDA MCP evidence
- String: `0xfffffe0009790bc0` (`"thid_should_crash"`)
- data xref nearby: `0xfffffe0009790bd8`
- target global: `0xfffffe0007682b50` (file offset `0x67EB50`)

## Validation
- `patch_thid_should_crash` emits exactly 1 patch at `0x67EB50`.
- Runtime regression check: PASS.

## Risk
- Directly mutating global crash-control flags can hide error paths expected during diagnostics.
