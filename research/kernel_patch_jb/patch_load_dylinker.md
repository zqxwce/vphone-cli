# B16 `patch_load_dylinker`

## How the patch works
- Source: `scripts/patchers/kernel_jb_patch_load_dylinker.py`.
- Locator strategy:
  1. Try symbol `_load_dylinker`.
  2. Fallback anchor: locate function referencing string `"/usr/lib/dyld"` in kernel `__text`.
  3. In that function, find gate sequence:
     - `bl <check>`
     - `cbz w0, <allow>`
     - `mov w0, #2` (deny path)
- Patch action:
  - Replace the `bl <check>` with unconditional `b <allow>`.

## Expected outcome
- Skip dyld policy rejection branch and force allow path for this gate.

## Target
- Dyld policy gate in load-dylinker path.

## IDA MCP evidence (current state)
- `"/usr/lib/dyld"` anchor: `0xfffffe00070899e3`.
- Anchor function: `0xfffffe000805699c` (`foff 0x105299C`).
- Patch site: `0xfffffe0008056a28` (`foff 0x1052A28`):
  - before: `bl ... ; cbz w0, <allow> ; mov w0, #2`
  - after: `b <allow>`

## Risk
- Dyld policy bypass is security-sensitive and can widen executable loading surface.
