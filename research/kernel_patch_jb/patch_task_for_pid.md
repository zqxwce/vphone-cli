# B15 `patch_task_for_pid`

## How the patch works
- Source: `scripts/patchers/kernel_jb_patch_task_for_pid.py`.
- Locator strategy:
  1. Try symbol `_task_for_pid`.
  2. Otherwise scan for a trap-like function profile:
     - no direct BL callers,
     - multiple `ldadda`,
     - repeated `ldr wN, [xN, #0x490]` + `str wN, [xN, #0xc]`,
     - `movk ..., #0xc8a2`,
     - BL to high-caller target.
  3. If multiple candidates match, prefer function(s) that have chained pointer references from `__DATA_CONST`/`__DATA` (trap-table style reference), and reject ambiguous ties.
- Patch action:
  - NOP the second `ldr ... #0x490` (target proc security copy).

## Expected outcome
- Skip copying restrictive proc_ro security state in task_for_pid path.

## Target
- Security-copy instruction sequence in `_task_for_pid` internals.

## IDA MCP evidence (current state)
- Research kernel selected function: `0xfffffe0008003718` (`foff 0xFFF718`), patch site `0xfffffe000800383c` (`foff 0xFFF83C`).
- Secondary structural match also exists at `0xfffffe000800477c` (`foff 0x100077C`) but has no data-pointer table refs and is rejected.
- The selected function has a data xref at `0xfffffe00077363a8`, consistent with indirect dispatch table usage.

## Risk
- task_for_pid hardening bypass is high-impact and can enable broader task-port access.
