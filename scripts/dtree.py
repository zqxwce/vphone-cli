#!/usr/bin/env python3
"""Patch DeviceTree IM4P with a fixed property set."""

import argparse
import sys
from dataclasses import dataclass, field
from pathlib import Path

from pyimg4 import IM4P


PATCHES = [
    {
        "node_path": ["device-tree"],
        "prop": "serial-number",
        "length": 12,
        "flags": 0,
        "kind": "string",
        "value": "vphone-1337",
    },
    {
        "node_path": ["device-tree", "buttons"],
        "prop": "home-button-type",
        "length": 4,
        "flags": 0,
        "kind": "int",
        "value": 2,
    },
    {
        "node_path": ["device-tree", "product"],
        "prop": "artwork-device-subtype",
        "length": 4,
        "flags": 0,
        "kind": "int",
        "value": 2556,
    },
    {
        "node_path": ["device-tree", "product"],
        "prop": "island-notch-location",
        "length": 4,
        "flags": 0,
        "kind": "int",
        "value": 144,
    },
]


@dataclass
class DTProperty:
    name: str
    length: int
    flags: int
    value: bytes


@dataclass
class DTNode:
    properties: list[DTProperty] = field(default_factory=list)
    children: list["DTNode"] = field(default_factory=list)


def _align4(n: int) -> int:
    return (n + 3) & ~3


def _decode_cstr(data: bytes) -> str:
    return data.split(b"\x00", 1)[0].decode("utf-8", errors="ignore")


def _encode_name(name: str) -> bytes:
    raw = name.encode("ascii")
    if len(raw) >= 32:
        raise RuntimeError(f"property name too long: {name}")
    return raw + (b"\x00" * (32 - len(raw)))


def _parse_node(blob: bytes, offset: int) -> tuple[DTNode, int]:
    if offset + 8 > len(blob):
        raise RuntimeError("truncated node header")

    n_props = int.from_bytes(blob[offset : offset + 4], "little")
    n_children = int.from_bytes(blob[offset + 4 : offset + 8], "little")
    offset += 8

    node = DTNode()

    for _ in range(n_props):
        if offset + 36 > len(blob):
            raise RuntimeError("truncated property header")

        name = _decode_cstr(blob[offset : offset + 32])
        length = int.from_bytes(blob[offset + 32 : offset + 34], "little")
        flags = int.from_bytes(blob[offset + 34 : offset + 36], "little")
        offset += 36

        if offset + length > len(blob):
            raise RuntimeError(f"truncated property value: {name}")

        value = blob[offset : offset + length]
        offset += _align4(length)
        node.properties.append(DTProperty(name=name, length=length, flags=flags, value=value))

    for _ in range(n_children):
        child, offset = _parse_node(blob, offset)
        node.children.append(child)

    return node, offset


def _parse_payload(blob: bytes) -> DTNode:
    root, end = _parse_node(blob, 0)
    if end != len(blob):
        raise RuntimeError(f"unexpected trailing payload bytes: {len(blob) - end}")
    return root


def _serialize_node(node: DTNode) -> bytes:
    out = bytearray()
    out += len(node.properties).to_bytes(4, "little")
    out += len(node.children).to_bytes(4, "little")

    for prop in node.properties:
        out += _encode_name(prop.name)
        out += int(prop.length & 0xFFFF).to_bytes(2, "little")
        out += int(prop.flags & 0xFFFF).to_bytes(2, "little")
        out += prop.value

        pad = _align4(prop.length) - prop.length
        if pad:
            out += b"\x00" * pad

    for child in node.children:
        out += _serialize_node(child)

    return bytes(out)


def _get_prop(node: DTNode, prop_name: str) -> DTProperty:
    for prop in node.properties:
        if prop.name == prop_name:
            return prop
    raise RuntimeError(f"missing property: {prop_name}")


def _node_name(node: DTNode) -> str:
    for prop in node.properties:
        if prop.name == "name":
            return _decode_cstr(prop.value)
    return ""


def _find_child(node: DTNode, child_name: str) -> DTNode:
    for child in node.children:
        if _node_name(child) == child_name:
            return child
    raise RuntimeError(f"missing child node: {child_name}")


def _resolve_node(root: DTNode, node_path: list[str]) -> DTNode:
    if not node_path or node_path[0] != "device-tree":
        raise RuntimeError(f"invalid path: {node_path}")
    node = root
    for name in node_path[1:]:
        node = _find_child(node, name)
    return node


def _encode_fixed_string(text: str, length: int) -> bytes:
    raw = text.encode("utf-8") + b"\x00"
    if len(raw) > length:
        return raw[:length]
    return raw + (b"\x00" * (length - len(raw)))


def _encode_int(value: int, length: int) -> bytes:
    if length not in (1, 2, 4, 8):
        raise RuntimeError(f"unsupported integer length: {length}")
    return int(value).to_bytes(length, "little", signed=False)


def _apply_patches(root: DTNode) -> None:
    for patch in PATCHES:
        node = _resolve_node(root, patch["node_path"])
        prop = _get_prop(node, patch["prop"])

        prop.length = int(patch["length"])
        prop.flags = int(patch["flags"])

        if patch["kind"] == "string":
            prop.value = _encode_fixed_string(str(patch["value"]), prop.length)
        elif patch["kind"] == "int":
            prop.value = _encode_int(int(patch["value"]), prop.length)
        else:
            raise RuntimeError(f"unsupported patch kind: {patch['kind']}")


def patch_device_tree_payload(payload: bytes | bytearray) -> bytes:
    root = _parse_payload(bytes(payload))
    _apply_patches(root)
    return _serialize_node(root)


def _load_input_payload(input_path: Path) -> bytes:
    if input_path.suffix.lower() == ".dtb":
        return input_path.read_bytes()
    if input_path.suffix.lower() != ".im4p":
        raise RuntimeError("input must be .im4p or .dtb")

    raw = input_path.read_bytes()
    im4p = IM4P(raw)
    if im4p.payload.compression:
        im4p.payload.decompress()
    return bytes(im4p.payload.data)


def _der_len(length: int) -> bytes:
    if length < 0:
        raise RuntimeError("negative DER length")
    if length < 0x80:
        return bytes([length])

    raw = bytearray()
    while length:
        raw.append(length & 0xFF)
        length >>= 8
    raw.reverse()
    return bytes([0x80 | len(raw)]) + bytes(raw)


def _der_tlv(tag: int, value: bytes) -> bytes:
    return bytes([tag]) + _der_len(len(value)) + value


def _build_im4p_der(fourcc: str, description: bytes, payload: bytes) -> bytes:
    if len(fourcc) != 4:
        raise RuntimeError(f"invalid IM4P fourcc: {fourcc!r}")
    if len(description) == 0:
        description = b""

    body = bytearray()
    body += _der_tlv(0x16, b"IM4P")  # IA5String
    body += _der_tlv(0x16, fourcc.encode("ascii"))  # IA5String
    body += _der_tlv(0x16, description)  # IA5String
    body += _der_tlv(0x04, payload)  # OCTET STRING
    return _der_tlv(0x30, bytes(body))  # SEQUENCE


def patch_dtree_file(
    input_file: str | Path,
    output_file: str | Path,
) -> Path:
    input_path = Path(input_file).expanduser().resolve()
    output_path = Path(output_file).expanduser().resolve()

    output_path.parent.mkdir(parents=True, exist_ok=True)

    payload = _load_input_payload(input_path)
    patched_payload = patch_device_tree_payload(payload)

    output_path.write_bytes(_build_im4p_der("dtre", b"", patched_payload))

    return output_path


def main() -> int:
    parser = argparse.ArgumentParser(description="Patch DeviceTree IM4P with fixed values")
    parser.add_argument("input", help="Path to DeviceTree .im4p or .dtb")
    parser.add_argument("output", help="Output DeviceTree .im4p")
    args = parser.parse_args()

    output_path = patch_dtree_file(
        input_file=args.input,
        output_file=args.output,
    )
    print(f"[+] wrote: {output_path}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as exc:
        print(f"[!] {exc}", file=sys.stderr)
        raise SystemExit(1)
