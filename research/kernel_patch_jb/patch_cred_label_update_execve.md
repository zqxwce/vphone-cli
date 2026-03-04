# C21 `patch_cred_label_update_execve`

## Source code
- File: `scripts/patchers/kernel_jb_patch_cred_label.py`
- Method: `KernelJBPatchCredLabelMixin.patch_cred_label_update_execve`
- Locator now uses strict validation:
  1. AMFI kill-path string cluster (`"AMFI: hook..execve() killing"` and related messages)
  2. candidate must contain arg9/cs_flags access shape (`ldr x26,[x29,...]`, `ldr/str w*,[x26]`)
  3. return site must be real epilogue return (must see `ldp x29,x30` + `add sp,sp,#...` before `retab`)
- Patch action:
  - inject cs_flags shellcode into cave
  - patch validated return site to `b cave`

## Expected outcome
- Force permissive credential/code-signing flags during execve cred-label update.

## Target
- Return edge of `_cred_label_update_execve`-related function (redirect to cave).

## Trace call stack (IDA)
- dispatch chain:
  - `sub_FFFFFE0008640624`
  - `sub_FFFFFE0008640718`
  - `sub_FFFFFE000863FC6C` (target function; contains kill strings + cs_flags writes)
- related AMFI branch in same dispatch region:
  - `sub_FFFFFE0008640718` also references `sub_FFFFFE0008641924`

## IDA MCP evidence
- kill anchor string: `0xFFFFFE00071F71C2`
- kill-string ref inside target function: `0xFFFFFE000863FCFC`
- validated target function: `0xFFFFFE000863FC6C`
- validated return site: `0xFFFFFE000864011C`
- cave branch after fix: `0x163C11C -> 0xAB0F00`
- old wrong site avoided: `0x163BC64` (previously in `sub_FFFFFE000863FB24`)

## Validation
- `patch_cred_label_update_execve` now emits 9 patches.
- branch patch is at `0x163C11C` (not the old wrong `0x163BC64`).
- targeted regression check: PASS.

## Risk
- This is a high-impact shellcode redirect patch; wrong cave/return resolution can panic.
- Direct cs_flags manipulation changes trust semantics globally for targeted execve paths.
