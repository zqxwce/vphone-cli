#!/usr/bin/env python3
"""DSC patches (MediaExperience, chunk .17) enabling custom-VirtualAudio adoption by vaem.

FigVAEndpointManagerCreate's whole VA-init success hinges on: getPlugin -> vain query
on gCMSM+116 -> `orr w8, rc, vain_out; cbz w8, "VA initialization ended"(success)`.
On iOS gCMSM+116 resolves the built-in STUB and vain is HAL-intercepted (can't route
to our plugin), so it fails. Two 1-instruction patches fix it, with the plugin seeding
gCMSM+116 = OUR plugin id (owns device VirtualAudioDevice_Default) before re-invoking:

  P1 @ 0x1b347855c: bl _AudioObjectGetPropertyData ('pibi') -> mov w0,#0
     Stops the 'pibi' lookup clobbering gCMSM+116 (so our seed survives) and makes the
     following `cbnz w0,fail` fall through to `ldr w8,[gCMSM+116]; cbnz w8,success`.
  P2 @ 0x1b3477598: orr w8,w0,w8 -> mov w8,#0
     Forces the vain-query check to pass, so VA init succeeds referencing our seeded
     plugin (48) -> endpoint manager initialized against OUR device.

Boot-safe: at boot gCMSM+116=0 (unseeded) -> P1's cbnz w8 fails -> vaem bails cleanly
(P2 only matters once the plugin re-invokes with the seed set).

Gate already satisfied by FeatureFlags plists (run_hybrid_hal + startup_sequence_change).
Only chunk .17 is modified; reattest the patched pages.
"""
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from cfw_asm import asm                              # noqa: E402
from cfw_dsc_chunks import DSCChunks                 # noqa: E402
from cfw_dsc_codesign import reattest_modified_pages # noqa: E402

PATCHES = [
    # (vma, expected_orig_bytes, new_asm)
    (0x1B347855C, bytes([0x05, 0xFC, 0x5F, 0x95]), asm("mov w0, #0")),  # NOP 'pibi'
    (0x1B3477598, bytes([0x08, 0x00, 0x08, 0x2A]), asm("mov w8, #0")),  # force vain-check pass
    # P3 @ 0x1B33AE3CC: in _MXEndpointDescriptorCopyAvailableRouteDescriptorsFromEndpoints the
    # per-entry gate `cbz w0, skip` (after FigCFArrayContainsValue(filter, entry["Endpoint"]))
    # drops any endpoint whose "Endpoint" isn't in the connected/pickable filter (empty on this
    # codec-less VM). NOP it so EVERY {Endpoint,RouteDescriptor} entry with a RouteDescriptor is
    # converted regardless of the filter -> our swizzle-injected endpoints become route descriptors.
    # Boot-safe: at boot the endpoint array is empty so the loop body never runs.
    (0x1B33AE3CC, bytes([0xA0, 0x01, 0x00, 0x34]), asm("nop")),         # NOP route-descriptor filter-reject
]


def patch_vaem_in_dsc(chunks_dir, *, dry_run=False):
    chunks = DSCChunks(chunks_dir)
    vmas = []
    for vma, orig, new in PATCHES:
        cur = chunks.read_at_vma(vma, 4)
        if cur != orig:
            raise RuntimeError(f"site {vma:#x} = {cur.hex()} != expected {orig.hex()}")
        print(f"[vaem] {vma:#x}: {cur.hex()} -> {new.hex()}")
        vmas.append((vma, new))
    if dry_run:
        return
    for vma, new in vmas:
        chunks.write_at_vma(vma, new)
    reattest_modified_pages(chunks, [v for v, _ in vmas], dry_run=False)
    print("[vaem] patched + reattested (chunk .17)")


if __name__ == "__main__":
    patch_vaem_in_dsc(sys.argv[1], dry_run=("--apply" not in sys.argv))
