# C24 `patch_kcall10`

## Status: NOT_BOOT (timeout, no panic)

## How the patch works
- Source: `scripts/patchers/kernel_jb_patch_kcall10.py`.
- Locator strategy:
  1. Resolve `_nosys` (symbol or `mov w0,#0x4e; ret` pattern).
  2. Scan DATA segments for `sysent` table signature (entry decoding points to `_nosys`).
  3. Compute `sysent[439]` (`SYS_kas_info`) entry offset.
- Patch action:
  - Inject `kcall10` shellcode in code cave (argument marshalling + `blr x16` + result write-back).
  - Rewrite `sysent[439]` fields:
    - `sy_call` -> cave VA
    - `sy_munge32` -> `_munge_wwwwwwww` (if resolved)
    - return type + arg metadata.

## Patcher output
```
_nosys found
sysent table at file offset 0x73E078
Shellcode at file offset 0x00AB1720 (VA 0xFFFFFE0007AB5720)
sysent[439] at file offset 0x007409A0 (VA 0xFFFFFE00077449A0)
35 patches emitted (32 shellcode + 3 sysent fields)
Note: _munge_wwwwwwww NOT found — sy_munge32 field not patched
```

## Root cause analysis (in progress)

### Primary suspect: chained fixup pointer format mismatch

The sysent table lives in a DATA segment. On arm64e kernelcaches, DATA segment
pointers use **chained fixup encoding**, not raw virtual addresses:

- **Auth rebase** (bit63=1): `file_offset = bits[31:0]`, plus diversity/key metadata
- **Non-auth rebase** (bit63=0): `VA = (bits[50:43] << 56) | bits[42:0]`

The patcher writes `struct.pack("<Q", cave_va)` — a raw 8-byte VA — to `sysent[439].sy_call`.
This is **not valid chained fixup format**. The kernel's pointer fixup chain will either:

1. Misinterpret the raw VA as a chained pointer and decode it to a wrong address
2. Break the fixup chain, corrupting subsequent sysent entries
3. The pointer simply won't be resolved, leaving a garbage function pointer

This explains the NOT_BOOT (timeout) behavior — no panic because the corrupted
pointer is never dereferenced during early boot (syscall 439 is not called during
init), but the fixup chain corruption may silently break other syscall entries,
preventing the system from booting properly.

### Fix approach (TODO)

1. **Read raw bytes at sysent[0] and sysent[439]** via IDA MCP to confirm the
   chained fixup pointer format (auth vs non-auth rebase)
2. **Implement `_encode_chained_ptr()`** that produces the correct encoding:
   - For auth rebase: set bit63=1, encode file offset in bits[31:0], set
     appropriate key/diversity fields
   - For non-auth rebase: encode VA with high8 bits in [50:43] and low43 in [42:0]
3. **Use encoded pointer** when writing `sy_call` and `sy_munge32`
4. **Verify the fixup chain** — sysent entries may be part of a linked chain
   where each entry's `next` field points to the next pointer to fix up.
   Breaking this chain corrupts all subsequent entries.

### Secondary concerns

- **Missing `_munge_wwwwwwww`**: The symbol wasn't found. Without the correct
  munge function, the kernel may not properly marshal syscall arguments from
  userspace. This may cause a panic when the syscall is actually invoked.
- **Code cave in __TEXT_EXEC**: The shellcode is placed at 0xAB1720 in __TEXT_EXEC.
  Need to verify this region is executable at runtime (KTRR/CTRR may lock it).
- **BLR x16 in shellcode**: The shellcode uses `BLR X16` (raw encoding
  `0xD63F0200`). On PAC-enabled kernels, this may need to be `BLRAAZ X16` or
  similar authenticated branch to avoid PAC traps.

### Sysent table structure
```
struct sysent {
    sy_call_t   *sy_call;        // +0:  function pointer (8 bytes)
    munge_t     *sy_arg_munge32; // +8:  argument munge function (8 bytes)
    int32_t      sy_return_type; // +16: return type (4 bytes)
    int16_t      sy_narg;        // +20: number of arguments (2 bytes)
    uint16_t     sy_arg_bytes;   // +22: argument byte count (2 bytes)
};  // total: 24 bytes per entry
```

### Key addresses
- sysent table: file 0x73E078, VA 0xFFFFFE0007742078
- sysent[439]: file 0x7409A0, VA 0xFFFFFE00077449A0
- Code cave: file 0xAB1720, VA 0xFFFFFE0007AB5720
- _nosys: found by pattern match

## Expected outcome
- Replace syscall 439 handler with arbitrary 10-arg kernel call trampoline behavior.

## Risk
- Syscall table rewrite is extremely invasive; wrong pointer encoding breaks
  the fixup chain and can silently corrupt many syscall handlers.
- BLR without PAC authentication may cause kernel traps.
