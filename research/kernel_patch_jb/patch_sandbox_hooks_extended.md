# A4 `patch_sandbox_hooks_extended`

## 1) How the Patch Is Applied
- Source implementation: `scripts/patchers/kernel_jb_patch_sandbox_extended.py`
- Match strategy:
  - Use `Seatbelt sandbox policy` plus sandbox-related structures to locate `mac_policy_conf`.
  - From `mpc_ops`, obtain the sandbox `mac_policy_ops` table.
  - Read hook function pointers by a fixed index list (245, 249, 250, ... 316).
- Rewrite: write 2 instructions at each matched hook entry:
  - `mov x0, #0`
  - `ret`

## 2) Expected Behavior
- Force many sandbox MAC hooks to return success, expanding allow coverage for file/process operations in the jailbreak environment.

## 3) Target
- Target object: extended sandbox hooks in `mac_policy_ops` (vnode/proc and related check points).
- Security objective: move from point bypasses to bulk policy allow.

## 4) IDA MCP Binary Evidence
- `Seatbelt sandbox policy` string hit: `0xfffffe00075fd493`
- Xref points to the policy-structure region: `0xfffffe0007a58430` (data reference)
- Script logic uses this structure to recover the `ops` table and patch hook entries in bulk (not a single-address patch).

## 5) 2026-03-05 Re-Validation (Research Kernel + IDA)
- Validation target:
  - runtime patch test input: `vm/iPhone17,3_26.1_23B85_Restore/kernelcache.research.vphone600`
  - IDA DB: `/Users/qaq/Desktop/kernelcache.research.vphone600.macho`
- `mac_policy_conf` resolution (current build):
  - `mac_policy_conf` at `0xfffffe0007a58428` (foff `0xA54428`)
  - `mpc_ops` pointer -> `0xfffffe0007a58488` (foff `0xA54488`)
- Current method result (`patch_sandbox_hooks_extended`):
  - **26 hook entries resolved**
  - **52 low-level writes** (`mov x0,#0` + `ret` for each hook)
- Entry quality checks:
  - all 26 decoded `ops[index]` addresses land inside Sandbox text range
  - all 26 entries begin at valid function entries (`pacibsp`, then prologue `stp ...`)
  - sample entries:
    - idx 245 `vnode_check_getattr` -> `0xfffffe00093a4020`
    - idx 258 `vnode_check_exec` -> `0xfffffe00093bc054`
    - idx 316 `vnode_check_fsgetpath` -> `0xfffffe000939ea28`

## 6) Risks and Side Effects
- Very wide coverage, with a high chance of cross-subsystem side effects (filesystem, process, exec paths).
- If indices do not match the target build, the patch may hit wrong functions and trigger panic.

## 7) Assessment
- On `kernelcache.research.vphone600`, A4 index-to-function mapping is structurally consistent (valid `mac_policy_conf` -> `mpc_ops` -> function-entry targets).
- Confidence: **high** for current build mapping correctness.
